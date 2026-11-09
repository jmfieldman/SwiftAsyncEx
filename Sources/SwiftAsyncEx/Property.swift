//
//  Property.swift
//  Copyright © 2026 Jason Fieldman.
//

import Foundation
import Observation

/// Use post-mutation observation where the runtime provides it. The package
/// keeps its existing deployment targets, so older OS versions fall back to
/// Observation's original willSet callback.
@MainActor
private func trackedPropertyRead<Value>(
    _ read: @MainActor () -> Value,
    handler: PropertyObservationHandler
) -> Value {
    if #available(iOS 27, macOS 27, tvOS 27, watchOS 27, visionOS 27, *) {
        return withObservationTracking(options: [.didSet], read, onChange: { [weak handler] _ in
            handler?.valueDidCommit()
        })
    }
    return withObservationTracking(read, onChange: { [weak handler] in
        handler?.valueWillCommit()
    })
}

/// The Property owns its refresh handler. Observation callbacks hold this
/// box weakly, avoiding a source -> callback -> source retain cycle.
private final class PropertyObservationHandler: @unchecked Sendable {
    private let lock = NSLock()
    private var refresh: (@MainActor @Sendable () -> Void)?
    private var changePending = false
    private var refreshQueued = false

    @MainActor
    func install(_ refresh: @escaping @MainActor @Sendable () -> Void) {
        let fireNow = lock.withLock {
            self.refresh = refresh
            let pending = changePending
            changePending = false
            return pending
        }
        if fireNow { refresh() }
    }

    /// The source has committed. Refresh synchronously on the main thread, so
    /// the new value is visible before the source setter returns.
    func valueDidCommit() {
        if Thread.isMainThread {
            MainActor.assumeIsolated { runRefresh() }
        } else {
            queueRefresh(yieldFirst: false)
        }
    }

    /// The source is about to commit. Let the setter finish before reading.
    func valueWillCommit() {
        queueRefresh(yieldFirst: true)
    }

    /// Queue at most one refresh at a time. Dropping a change while one is
    /// queued is safe, because that refresh hasn't read the source yet.
    private func queueRefresh(yieldFirst: Bool) {
        let shouldQueue = lock.withLock {
            if refreshQueued { return false }
            refreshQueued = true
            return true
        }
        guard shouldQueue else { return }
        Task { @MainActor [weak self] in
            if yieldFirst { await Task<Never, Never>.yield() }
            guard let self else { return }
            self.lock.withLock { self.refreshQueued = false }
            self.runRefresh()
        }
    }

    @MainActor
    private func runRefresh() {
        let callback: (@MainActor @Sendable () -> Void)? = lock.withLock {
            if refresh == nil { changePending = true }
            return refresh
        }
        callback?()
    }
}

/// A read-only observable handle over a value. Hand one of these out when a
/// consumer should be able to observe your value but not mutate it, and
/// should not need to hold onto your concrete producer type.
///
/// Construct via one of:
///
/// - `Property.constant(_:)` — a fixed value that never changes.
/// - `Property(mirroring:)` — mirror another `PropertyProtocol` (the common
///   "wrap my internal `MutableProperty` and vend a read-only handle" case).
/// - `Property(tracking:)` — derive from an Observation-tracked closure; the
///   closure may read any `@Observable` state and the Property updates when
///   that state changes.
/// - `Property(initial:from:)` — seed an initial value and then follow an
///   `AsyncSequence`.
///
/// Mirror- and tracking-mode properties always settle on the latest value of
/// their source. A burst of writes may be delivered as just its final value,
/// and a new value that is equal to the current one (for `Equatable` values)
/// is not published. On OS 27 and later, main-thread mutations propagate
/// synchronously after the source commits. Other mutations are refreshed on
/// the main actor.
@Observable
@MainActor
public final class Property<Value: Sendable>: PropertyProtocol {
    /// The current value.
    public private(set) var value: Value

    @ObservationIgnored
    private var observationHandler: PropertyObservationHandler?

    // MARK: - Constant

    /// A `Property` whose value never changes. Spawns no pump task.
    public static func constant(_ value: Value) -> Property<Value> {
        Property(_constant: value)
    }

    private init(_constant value: Value) {
        self.value = value
    }

    // MARK: - Mirror another PropertyProtocol

    /// Mirror another observable property. Changes to `source` propagate to
    /// this Property; this Property is read-only to its consumers regardless
    /// of whether `source` is mutable.
    ///
    /// The mirror holds `source` strongly for the duration of its own
    /// lifetime, so `source` stays alive as long as consumers hold this
    /// Property.
    public convenience init(mirroring source: some PropertyProtocol<Value>) {
        self.init(tracking: { source.value })
    }

    // MARK: - Track an Observation-reading closure

    /// Derive a `Property` from a closure that reads `@Observable` state.
    /// The closure is evaluated synchronously for the initial value, then
    /// re-evaluated each time any `@Observable` state it reads changes. It may
    /// run more than once per change, so keep it cheap and free of side
    /// effects.
    ///
    /// Universal form for projections that need to escape their producer's
    /// class identity — equivalent to `map` / `combineLatest` / keyPath
    /// projection collapsed into one init. For derivations that *don't* need
    /// to be a separate handle, a computed property on a containing
    /// `@Observable` is strictly better.
    public init(tracking closure: @escaping @MainActor @Sendable () -> Value) {
        let handler = PropertyObservationHandler()
        // Read again after arming: a write between the tracked read and the
        // observation being installed would otherwise go unnoticed.
        _ = trackedPropertyRead(closure, handler: handler)
        self.value = closure()
        self.observationHandler = handler
        installRefreshHandler(handler, read: closure)
    }

    // MARK: - Initial value + AsyncSequence

    /// Seed with `initial`, then update from `source` as elements arrive.
    /// Useful for bridging `AsyncChannel`, `AsyncStream`, `NotificationCenter`
    /// notifications, Combine's `.values`, or any other `AsyncSequence` into
    /// an observable property.
    ///
    /// If `source` terminates (by finishing or throwing), the pump simply
    /// stops; the last-seen value remains. Thrown errors are not surfaced.
    public init<S: AsyncSequence & Sendable>(
        initial: Value,
        from source: S
    ) where S.Element == Value {
        self.value = initial
        Task.bound(to: self) { @MainActor [weak self] in
            await pumpOnMainActor(source) { [weak self] element in
                self?.value = element
            }
        }
    }

    /// Seed with `nil`, then update from `source` as elements arrive, lifting
    /// each into `Optional`. Convenience for the common case of bridging an
    /// `AsyncSequence<T>` into a `Property<T?>` without an initial value.
    ///
    /// If `source` terminates (by finishing or throwing), the pump simply
    /// stops; the last-seen value remains. Thrown errors are not surfaced.
    public init<S: AsyncSequence & Sendable, Element: Sendable>(
        from source: S
    ) where S.Element == Element, Value == Element? {
        self.value = nil
        Task.bound(to: self) { @MainActor [weak self] in
            await pumpOnMainActor(source) { [weak self] element in
                self?.value = element
            }
        }
    }

    // MARK: - Observation refresh

    private func installRefreshHandler(
        _ handler: PropertyObservationHandler,
        read: @escaping @MainActor @Sendable () -> Value
    ) {
        handler.install { [weak self, weak handler] in
            guard let self, let handler else { return }
            self.refreshAndRearm(using: handler, read: read)
        }
    }

    /// Install the next observation, then read and publish. Observation only
    /// reports writes made after it is installed, so the read must come after:
    /// any earlier write is seen by the read, and any later one fires again.
    ///
    /// A write can be both, which is why equal values aren't published again.
    /// Values that aren't `Equatable` can't be compared, so a write from off
    /// the main thread can rarely publish twice. Main-thread writes can't
    /// interleave with this method, so they always publish once.
    private func refreshAndRearm(
        using handler: PropertyObservationHandler,
        read: @escaping @MainActor @Sendable () -> Value
    ) {
        _ = trackedPropertyRead(read, handler: handler)
        let latest = read()
        if !propertyValuesEqual(value, latest) {
            value = latest
        }
    }
}
