//
//  Property.swift
//  Copyright © 2026 Jason Fieldman.
//

import Foundation
import Observation

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
/// Mirror- and tracking-mode updates lag the source by one runloop tick
/// (Observation's `onChange` fires on `willSet`; the internal pump yields
/// before re-reading so the committed value is the one propagated).
@Observable
@MainActor
public final class Property<Value: Sendable>: PropertyProtocol {
    /// The current value.
    public private(set) var value: Value

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
        self.value = source.value
        startObservationPump { source.value }
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
        self.value = closure()
        startObservationPump(closure)
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

    // MARK: - Internal pump

    /// Spawn an observation-tracking pump bound to this Property's lifetime.
    /// `read` is invoked under `withObservationTracking`, so any `@Observable`
    /// state it accesses is tracked; on change, `self.value` is updated to
    /// the new reading.
    private func startObservationPump(_ read: @escaping @MainActor () -> Value) {
        Task.bound(to: self) { @MainActor [weak self] in
            while !Task<Never, Never>.isCancelled {
                let box = ObservationContinuationBox()

                // Arm observation and sync to the current value. The strong
                // `self` reference is scoped to this closure so it is
                // released before the `await` below — otherwise the pump
                // body would keep `self` alive indefinitely and break
                // lifetime-bound cancellation.
                let armed: Bool = {
                    guard let strong = self else { return false }
                    strong.value = read()
                    withObservationTracking {
                        _ = read()
                    } onChange: {
                        box.resume()
                    }
                    return true
                }()
                guard armed else { break }

                await withTaskCancellationHandler {
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        box.setContinuation(cont)
                    }
                } onCancel: {
                    box.resume()
                }

                if Task<Never, Never>.isCancelled { break }
                // Let the source's willSet commit before the next iteration
                // reads the new value.
                await Task<Never, Never>.yield()
            }
        }
    }
}
