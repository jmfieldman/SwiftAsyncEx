//
//  PropertyProtocol.swift
//  Copyright © 2026 Jason Fieldman.
//

import Foundation
import Observation

// MARK: - PropertyProtocol

/// A read-only observable reference to a value. Reads register Observation
/// tracking, so consumers (SwiftUI, `withObservationTracking`, `Task.observe`)
/// re-evaluate when the value changes.
///
/// The protocol exists so producers can vend a value to consumers without
/// exposing their own concrete type or property names. A consumer accepts
/// `any PropertyProtocol<T>` and reads `.value`; any producer that can
/// project its state into an observable `T` can supply one — typically by
/// wrapping an internal `MutableProperty`/`PersistentProperty` in a
/// `Property(mirroring:)`.
@MainActor
public protocol PropertyProtocol<Value>: AnyObject, Observable, Sendable {
    associatedtype Value: Sendable
    /// The current value. Reading registers Observation tracking on the
    /// underlying storage, so observers react to subsequent changes.
    var value: Value { get }
}

// MARK: - MutablePropertyProtocol

/// A writable observable reference to a value. Refines `PropertyProtocol`
/// with a setter and an in-place `modify(_:)` helper.
@MainActor
public protocol MutablePropertyProtocol<Value>: PropertyProtocol {
    var value: Value { get set }
    /// Atomic in-place mutation. The closure receives the current value by
    /// `inout`; the final value is written back through the setter so
    /// Observation fires once.
    func modify(_ block: (inout Value) -> Void)
}

// MARK: - Cross-actor read / write helpers

extension PropertyProtocol {
    /// Read the value from any isolation context. Hops to MainActor internally
    /// so background callers don't need `await MainActor.run { ... }`.
    public nonisolated func read() async -> Value {
        await MainActor.run { self.value }
    }
}

extension MutablePropertyProtocol {
    /// Set the value from any isolation context. Hops to MainActor internally.
    /// Sequential `await property.set(_:)` calls from a single task land in
    /// call order.
    public nonisolated func set(_ newValue: Value) async {
        await MainActor.run { self.value = newValue }
    }

    /// Mutate the value from any isolation context. Hops to MainActor
    /// internally, then performs the read-modify-write without suspension so
    /// competing writes cannot interleave between the read and write.
    public nonisolated func update(_ block: @escaping @Sendable (inout Value) -> Void) async {
        await MainActor.run { self.modify(block) }
    }
}

// MARK: - AsyncSequence bridge

extension PropertyProtocol {
    /// An `AsyncStream` that yields the current value immediately, then yields
    /// on each subsequent change. Terminates when the stream's consumer
    /// cancels or when `self` is deallocated.
    ///
    /// Uses Observation tracking under the hood. Updates lag source writes by
    /// one runloop tick (`withObservationTracking`'s `onChange` fires on
    /// `willSet`; the pump yields before re-reading so the committed value is
    /// the one yielded).
    public nonisolated func asAsyncSequence() -> AsyncStream<Value> {
        AsyncStream<Value> { continuation in
            let task = Task.bound(to: self) { @MainActor [weak self] in
                guard let initial = self?.value else {
                    continuation.finish()
                    return
                }
                continuation.yield(initial)

                while !Task<Never, Never>.isCancelled {
                    let box = ObservationContinuationBox()

                    // Arm observation, scoped so the strong self reference is
                    // released before we enter the await.
                    let armed: Bool = {
                        guard let strong = self else { return false }
                        withObservationTracking {
                            _ = strong.value
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
                    // withObservationTracking fires on willSet; yield so the
                    // setter commits before we re-read.
                    await Task<Never, Never>.yield()
                    guard let nextValue = self?.value else { break }
                    continuation.yield(nextValue)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Observation continuation box

/// Coordinates between `withObservationTracking`'s one-shot `onChange`
/// callback and `withTaskCancellationHandler`'s `onCancel` handler so that
/// exactly one of them resumes the continuation. Handles the case where
/// cancellation arrives before the continuation has been installed.
///
/// Shared between the observation-pump loops in `asAsyncSequence()` and
/// `Property`'s internal mirror/tracking inits.
internal final class ObservationContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var resumeRequested = false

    func setContinuation(_ c: CheckedContinuation<Void, Never>) {
        let resumeNow: Bool = lock.withLock {
            if resumeRequested { return true }
            continuation = c
            return false
        }
        if resumeNow { c.resume() }
    }

    func resume() {
        let c: CheckedContinuation<Void, Never>? = lock.withLock {
            guard !resumeRequested else { return nil }
            resumeRequested = true
            let taken = continuation
            continuation = nil
            return taken
        }
        c?.resume()
    }
}
