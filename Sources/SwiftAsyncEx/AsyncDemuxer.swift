//
//  AsyncDemuxer.swift
//  Copyright © 2026 Jason Fieldman.
//

import Foundation

// MARK: - AsyncDemuxer (non-throwing)

/// Single-flight coalescing for a parameterless async operation.
///
/// Multiple concurrent callers of `execute()` share one underlying task;
/// each caller receives the same result when the work completes. When no
/// callers are waiting and the value is requested again, a fresh execution
/// begins.
///
/// Useful for "refresh current profile", "load app config", and similar
/// idempotent fetches where you never want two concurrent in-flight copies
/// but also never want to cache a stale result.
public final class AsyncDemuxer<Output: Sendable>: @unchecked Sendable {
    private let work: @Sendable () async -> Output
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Output, Never>] = []
    private var currentTask: Task<Void, Never>?

    /// The number of callers attached to the current execution. Exposed
    /// `internal` so tests can synchronize on attachment.
    internal var waiterCount: Int {
        lock.withLock { waiters.count }
    }

    public init(_ work: @escaping @Sendable () async -> Output) {
        self.work = work
    }

    public func execute() async -> Output {
        await withCheckedContinuation { (cont: CheckedContinuation<Output, Never>) in
            lock.withLock {
                waiters.append(cont)
                if currentTask == nil {
                    currentTask = Task { [self] in
                        await self.runWork()
                    }
                }
            }
        }
    }

    private func runWork() async {
        let result = await work()
        let pending: [CheckedContinuation<Output, Never>] = lock.withLock {
            let p = waiters
            waiters = []
            currentTask = nil
            return p
        }
        for cont in pending {
            cont.resume(returning: result)
        }
    }
}

// MARK: - ThrowingAsyncDemuxer

/// Like `AsyncDemuxer`, but for work that may throw. Errors are fanned out
/// to every waiter on the current execution; per-waiter cancellation is
/// honored independently — cancelling one awaiter throws `CancellationError`
/// for it while leaving the shared task (and other waiters) intact.
public final class ThrowingAsyncDemuxer<Output: Sendable>: @unchecked Sendable {
    private let work: @Sendable () async throws -> Output
    private let lock = NSLock()
    private var waiters: [(UUID, CheckedContinuation<Output, any Error>)] = []
    private var currentTask: Task<Void, Never>?

    /// The number of callers attached to the current execution. Exposed
    /// `internal` so tests can synchronize on attachment.
    internal var waiterCount: Int {
        lock.withLock { waiters.count }
    }

    /// Whether a shared execution is in flight. Exposed `internal` so tests
    /// can synchronize on completion.
    internal var isExecuting: Bool {
        lock.withLock { currentTask != nil }
    }

    public init(_ work: @escaping @Sendable () async throws -> Output) {
        self.work = work
    }

    public func execute() async throws -> Output {
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation {
                (cont: CheckedContinuation<Output, any Error>) in
                lock.withLock {
                    // A cancel that landed before this point found nothing
                    // for `onCancel` to remove, so honor it here. Any later
                    // cancel runs `onCancel` after this lock is released,
                    // and finds the waiter.
                    if Task.isCancelled {
                        cont.resume(throwing: CancellationError())
                        return
                    }
                    waiters.append((id, cont))
                    if currentTask == nil {
                        currentTask = Task { [self] in
                            await self.runWork()
                        }
                    }
                }
            }
        } onCancel: {
            lock.withLock {
                if let idx = waiters.firstIndex(where: { $0.0 == id }) {
                    let (_, cont) = waiters.remove(at: idx)
                    cont.resume(throwing: CancellationError())
                }
            }
        }
    }

    private func runWork() async {
        let outcome: Result<Output, any Error>
        do {
            outcome = .success(try await work())
        } catch {
            outcome = .failure(error)
        }
        let pending: [(UUID, CheckedContinuation<Output, any Error>)] = lock.withLock {
            let p = waiters
            waiters = []
            currentTask = nil
            return p
        }
        for (_, cont) in pending {
            cont.resume(with: outcome)
        }
    }
}
