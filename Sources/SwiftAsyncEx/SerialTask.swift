//
//  SerialTask.swift
//  Copyright © 2026 Jason Fieldman.
//

import Foundation
import Observation

/// A MainActor helper for "only one at a time" async work. The work closure
/// is bound at construction; `run(_:)` fires it and awaits its output.
/// While a task is in flight, further calls to `run(_:)` throw
/// `SerialTask.AlreadyExecuting`.
///
/// `isExecuting` is observable — SwiftUI views and `Task.observe(expression:)`
/// consumers can bind to it directly.
///
/// The underlying `Task` is an implementation detail; callers interact only
/// through `run(_:)`, `fire(_:)`, and `cancel()`.
@Observable
@MainActor
public final class SerialTask<Input, Output: Sendable>: Sendable {
    /// Thrown by `run(_:)` when a task is already in flight.
    public struct AlreadyExecuting: Error, Sendable {}

    /// Thrown by `run(_:)` when a `weak(_:)` factory's owner has been
    /// deallocated. Not thrown by the plain initializer or by
    /// `weak(_:default:)`, which substitutes the default value instead.
    public struct OwnerDeallocated: Error, Sendable {}

    /// True while a task is currently in flight.
    public private(set) var isExecuting: Bool = false

    @ObservationIgnored private let work: @MainActor (Input) async throws -> Output
    @ObservationIgnored private let ownerAlive: @MainActor () -> Bool
    @ObservationIgnored private var currentTask: Task<Output, Error>?
    /// Bumped on every `run(_:)` and every `cancel()`. Used by completing
    /// tasks to decide whether their post-work state flip is still relevant;
    /// a cancelled-then-restarted task must not flip `isExecuting` for the
    /// new run when the old tail eventually completes.
    @ObservationIgnored private var currentGeneration: UInt64 = 0

    public init(_ work: @escaping @MainActor (Input) async throws -> Output) {
        self.work = work
        self.ownerAlive = { true }
    }

    /// Internal initializer for factory helpers (e.g. `weak(_:)`) that need
    /// to inject an owner-alive predicate alongside the work closure.
    internal init(
        work: @escaping @MainActor (Input) async throws -> Output,
        ownerAlive: @escaping @MainActor () -> Bool
    ) {
        self.work = work
        self.ownerAlive = ownerAlive
    }

    /// Kick off the task and await its output.
    ///
    /// Throws:
    /// - `SerialTask.AlreadyExecuting` if a task is already in flight.
    /// - `SerialTask.OwnerDeallocated` (weak variant without default) if the
    ///   owner has been deallocated.
    /// - `CancellationError` if the caller's task is cancelled, or if
    ///   `cancel()` is invoked externally while this run is in flight.
    /// - Any error thrown by the bound work closure.
    @discardableResult
    public func run(_ input: Input) async throws -> Output {
        guard !isExecuting else { throw AlreadyExecuting() }
        guard ownerAlive() else { throw OwnerDeallocated() }
        isExecuting = true
        currentGeneration &+= 1
        let myGeneration = currentGeneration

        let task = Task<Output, Error> { [work] in
            try await work(input)
        }
        currentTask = task

        return try await withTaskCancellationHandler {
            do {
                let result = try await task.value
                guard self.currentGeneration == myGeneration else {
                    // This run was displaced by an external cancel() or a
                    // subsequent run(_:). Do not touch shared state.
                    throw CancellationError()
                }
                self.isExecuting = false
                self.currentTask = nil
                try Task.checkCancellation()
                return result
            } catch {
                if self.currentGeneration == myGeneration {
                    self.isExecuting = false
                    self.currentTask = nil
                }
                throw error
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Fire-and-forget. Wraps `run(_:)` in a detached-from-caller `Task` and
    /// swallows every outcome — including `AlreadyExecuting`,
    /// `OwnerDeallocated`, and `CancellationError`. Useful at SwiftUI call
    /// sites (button actions, `onAppear`) where the surrounding context is
    /// not `async`.
    public func fire(_ input: Input) {
        Task { try? await self.run(input) }
    }

    /// Cancel the in-flight task (if any). `isExecuting` flips to `false`
    /// immediately so a subsequent `run(_:)` can start a fresh task even
    /// while the cancelled task is still cooperatively draining. Any
    /// `run(_:)` awaiter for the cancelled task observes `CancellationError`.
    public func cancel() {
        currentGeneration &+= 1
        currentTask?.cancel()
        isExecuting = false
        currentTask = nil
    }
}

// MARK: - Void-Input conveniences

public extension SerialTask where Input == Void {
    convenience init(_ work: @escaping @MainActor () async throws -> Output) {
        self.init({ _ in try await work() })
    }

    @discardableResult
    func run() async throws -> Output {
        try await run(())
    }

    func fire() {
        fire(())
    }
}

// MARK: - weak(_:) factories

public extension SerialTask {
    /// Create a `SerialTask` whose work closure holds a weak reference to
    /// `owner`. The non-nil owner is passed into the work closure on each
    /// `run(_:)`; if the owner has been deallocated, `run(_:)` throws
    /// `SerialTask.OwnerDeallocated`.
    static func weak<Owner: AnyObject>(
        _ owner: Owner,
        _ work: @escaping @MainActor (Owner, Input) async throws -> Output
    ) -> SerialTask<Input, Output> {
        SerialTask<Input, Output>(
            work: { [weak owner] input in
                guard let owner else { throw SerialTask<Input, Output>.OwnerDeallocated() }
                return try await work(owner, input)
            },
            ownerAlive: { [weak owner] in owner != nil }
        )
    }

    /// Create a `SerialTask` whose work closure holds a weak reference to
    /// `owner`. If the owner has been deallocated, `run(_:)` returns
    /// `defaultValue` instead of throwing. Errors thrown by the work closure
    /// itself are propagated unchanged — the default only substitutes for
    /// owner deallocation.
    static func weak<Owner: AnyObject>(
        _ owner: Owner,
        default defaultValue: Output,
        _ work: @escaping @MainActor (Owner, Input) async throws -> Output
    ) -> SerialTask<Input, Output> {
        SerialTask<Input, Output>(
            work: { [weak owner] input in
                guard let owner else { return defaultValue }
                return try await work(owner, input)
            },
            ownerAlive: { true }
        )
    }

    /// Create a `SerialTask` whose work closure holds a weak reference to
    /// `owner`, for an `Optional` output. If the owner has been deallocated,
    /// `run(_:)` returns `nil` instead of throwing. Errors thrown by the work
    /// closure itself are propagated unchanged.
    static func weak<Owner: AnyObject, Wrapped>(
        _ owner: Owner,
        _ work: @escaping @MainActor (Owner, Input) async throws -> Output
    ) -> SerialTask<Input, Output> where Output == Wrapped? {
        SerialTask<Input, Output>(
            work: { [weak owner] input in
                guard let owner else { return nil }
                return try await work(owner, input)
            },
            ownerAlive: { true }
        )
    }
}

public extension SerialTask where Input == Void {
    /// Void-input `weak(_:)` convenience.
    static func weak<Owner: AnyObject>(
        _ owner: Owner,
        _ work: @escaping @MainActor (Owner) async throws -> Output
    ) -> SerialTask<Void, Output> {
        SerialTask<Void, Output>(
            work: { [weak owner] _ in
                guard let owner else { throw SerialTask<Void, Output>.OwnerDeallocated() }
                return try await work(owner)
            },
            ownerAlive: { [weak owner] in owner != nil }
        )
    }

    /// Void-input `weak(_:default:)` convenience.
    static func weak<Owner: AnyObject>(
        _ owner: Owner,
        default defaultValue: Output,
        _ work: @escaping @MainActor (Owner) async throws -> Output
    ) -> SerialTask<Void, Output> {
        SerialTask<Void, Output>(
            work: { [weak owner] _ in
                guard let owner else { return defaultValue }
                return try await work(owner)
            },
            ownerAlive: { true }
        )
    }

    /// Void-input convenience for the `Optional`-output `weak(_:)` overload.
    /// If the owner has been deallocated, `run()` returns `nil` instead of
    /// throwing.
    static func weak<Owner: AnyObject, Wrapped>(
        _ owner: Owner,
        _ work: @escaping @MainActor (Owner) async throws -> Output
    ) -> SerialTask<Void, Output> where Output == Wrapped? {
        SerialTask<Void, Output>(
            work: { [weak owner] _ in
                guard let owner else { return nil }
                return try await work(owner)
            },
            ownerAlive: { true }
        )
    }
}
