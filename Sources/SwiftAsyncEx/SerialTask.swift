//
//  SerialTask.swift
//  Copyright © 2026 Jason Fieldman.
//

import Foundation
import Observation

/// A MainActor helper for "only one at a time" async work. The work closure
/// is bound at construction; `run(_:)` fires it. While a task is in flight,
/// further calls to `run(_:)` are skipped and return `nil`.
///
/// `isExecuting` is observable — SwiftUI views and `Task.observe(of:)`
/// consumers can bind to it directly.
@Observable
@MainActor
public final class SerialTask<Input, Output: Sendable> {
    /// True while a task is currently in flight.
    public private(set) var isExecuting: Bool = false

    @ObservationIgnored private let work: @MainActor (Input) async -> Output
    @ObservationIgnored private let ownerAlive: @MainActor () -> Bool
    @ObservationIgnored private var currentTask: Task<Output, Never>?
    /// Bumped on every `run(_:)` and every `cancel()`. Used by completing
    /// tasks to decide whether their post-work state flip is still relevant;
    /// a cancelled-then-restarted task must not flip `isExecuting` for the
    /// new run when the old tail eventually completes.
    @ObservationIgnored private var currentGeneration: UInt64 = 0

    public init(_ work: @escaping @MainActor (Input) async -> Output) {
        self.work = work
        self.ownerAlive = { true }
    }

    /// Internal initializer for factory helpers (e.g. `weak(_:)`) that need
    /// to inject an owner-alive predicate.
    internal init(
        work: @escaping @MainActor (Input) async -> Output,
        ownerAlive: @escaping @MainActor () -> Bool
    ) {
        self.work = work
        self.ownerAlive = ownerAlive
    }

    /// Kick off the task. Returns the underlying `Task<Output, Never>` if
    /// the work started, or `nil` if skipped — either because a task is
    /// already in flight, or because a `weak(_:)` factory's owner has been
    /// deallocated.
    @discardableResult
    public func run(_ input: Input) -> Task<Output, Never>? {
        guard !isExecuting else { return nil }
        guard ownerAlive() else { return nil }
        isExecuting = true
        currentGeneration &+= 1
        let myGeneration = currentGeneration
        let task = Task<Output, Never> { [self] in
            let result = await self.work(input)
            if self.currentGeneration == myGeneration {
                self.isExecuting = false
                self.currentTask = nil
            }
            return result
        }
        currentTask = task
        return task
    }

    /// Cancel the in-flight task (if any). `isExecuting` flips to `false`
    /// immediately so a subsequent `run(_:)` can start a fresh task even
    /// while the cancelled task is still cooperatively draining.
    public func cancel() {
        currentGeneration &+= 1
        currentTask?.cancel()
        isExecuting = false
        currentTask = nil
    }
}

// MARK: - Void-Input conveniences

public extension SerialTask where Input == Void {
    convenience init(_ work: @escaping @MainActor () async -> Output) {
        self.init({ _ in await work() })
    }

    @discardableResult
    func run() -> Task<Output, Never>? {
        run(())
    }
}

// MARK: - weak(_:) factories (Void-Output only)

public extension SerialTask where Output == Void {
    /// Create a `SerialTask` whose work closure holds a weak reference to
    /// `owner`. The non-nil owner is passed into the work closure on each
    /// `run(_:)`; if the owner has been deallocated, `run(_:)` is skipped
    /// and returns `nil`.
    static func weak<Owner: AnyObject>(
        _ owner: Owner,
        _ work: @escaping @MainActor (Owner, Input) async -> Void
    ) -> SerialTask<Input, Void> {
        SerialTask<Input, Void>(
            work: { [weak owner] input in
                guard let owner else { return }
                await work(owner, input)
            },
            ownerAlive: { [weak owner] in owner != nil }
        )
    }
}

public extension SerialTask where Input == Void, Output == Void {
    /// `weak(_:)` convenience for the common Void-input, Void-output case.
    static func weak<Owner: AnyObject>(
        _ owner: Owner,
        _ work: @escaping @MainActor (Owner) async -> Void
    ) -> SerialTask<Void, Void> {
        SerialTask<Void, Void>(
            work: { [weak owner] _ in
                guard let owner else { return }
                await work(owner)
            },
            ownerAlive: { [weak owner] in owner != nil }
        )
    }
}
