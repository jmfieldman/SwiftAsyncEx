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
    onChange: @escaping @Sendable () -> Void
) -> Value {
    if #available(iOS 27, macOS 27, tvOS 27, watchOS 27, *) {
        return withObservationTracking(options: [.didSet], read, onChange: { _ in
            onChange()
        })
    }
    return withObservationTracking(read, onChange: {
        // The legacy callback is willSet. Let the setter commit before
        // reading and publishing the new value.
        Task { @MainActor in
            await Task<Never, Never>.yield()
            onChange()
        }
    })
}

/// The Property owns its refresh handler. Observation callbacks hold this
/// box weakly, avoiding a source -> callback -> source retain cycle.
private final class PropertyObservationHandler: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?
    private var changePending = false

    func install(_ handler: @escaping @Sendable () -> Void) {
        let fireNow = lock.withLock {
            self.handler = handler
            let pending = changePending
            changePending = false
            return pending
        }
        if fireNow { handler() }
    }

    func fire() {
        let callback: (@Sendable () -> Void)? = lock.withLock {
            guard let handler else {
                changePending = true
                return nil
            }
            return handler
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
/// On supported runtimes, main-thread mirror- and tracking-mode mutations
/// propagate synchronously after the source commits. Other mutations are
/// refreshed on the main actor.
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
    public init(mirroring source: some PropertyProtocol<Value>) {
        let read: @MainActor @Sendable () -> Value = { source.value }
        let handler = PropertyObservationHandler()
        self.value = trackedPropertyRead(read, onChange: { [weak handler] in
            handler?.fire()
        })
        self.observationHandler = handler
        installRefreshHandler(handler, read: read)
    }

    // MARK: - Track an Observation-reading closure

    /// Derive a `Property` from a closure that reads `@Observable` state.
    /// The closure is evaluated once synchronously for the initial value,
    /// then re-evaluated each time any `@Observable` state it reads changes.
    ///
    /// Universal form for projections that need to escape their producer's
    /// class identity — equivalent to `map` / `combineLatest` / keyPath
    /// projection collapsed into one init. For derivations that *don't* need
    /// to be a separate handle, a computed property on a containing
    /// `@Observable` is strictly better.
    public init(tracking closure: @escaping @MainActor @Sendable () -> Value) {
        let handler = PropertyObservationHandler()
        self.value = trackedPropertyRead(closure, onChange: { [weak handler] in
            handler?.fire()
        })
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
            do {
                for try await element in source {
                    self?.value = element
                }
            } catch {
                // Source terminated with error; pump stops.
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
            do {
                for try await element in source {
                    self?.value = element
                }
            } catch {
                // Source terminated with error; pump stops.
            }
        }
    }

    // MARK: - Observation refresh

    private func installRefreshHandler(
        _ handler: PropertyObservationHandler,
        read: @escaping @MainActor @Sendable () -> Value
    ) {
        handler.install { [weak self, weak handler] in
            guard let handler else { return }
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self?.refreshAndRearm(using: handler, read: read)
                }
            } else {
                Task { @MainActor [weak self, weak handler] in
                    guard let self, let handler else { return }
                    self.refreshAndRearm(using: handler, read: read)
                }
            }
        }
    }

    /// Install the next observation before reading and publishing. A main
    /// thread `.didSet` callback reaches this synchronously, before the
    /// source setter returns.
    private func refreshAndRearm(
        using handler: PropertyObservationHandler,
        read: @escaping @MainActor @Sendable () -> Value
    ) {
        let currentValue = trackedPropertyRead(read, onChange: { [weak handler] in
            handler?.fire()
        })
        value = currentValue
    }
}
