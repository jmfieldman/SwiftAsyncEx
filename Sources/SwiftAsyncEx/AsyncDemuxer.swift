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
