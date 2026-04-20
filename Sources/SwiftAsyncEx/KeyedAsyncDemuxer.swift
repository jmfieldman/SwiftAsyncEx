//
//  KeyedAsyncDemuxer.swift
//  Copyright © 2026 Jason Fieldman.
//

import Foundation

// MARK: - KeyedAsyncDemuxer (non-throwing)

/// Single-flight coalescing keyed by an input. Concurrent callers with the
/// same key share a single underlying task; callers with different keys run
/// independently in parallel. Once a key's work completes, subsequent
/// `execute(key:)` calls for that key start a fresh execution.
///
/// Typical uses: per-URL image loads, per-ID fetches, any pattern where
/// "the same underlying work should not run twice concurrently, but
/// different inputs are independent."
public final class KeyedAsyncDemuxer<Key: Hashable & Sendable, Output: Sendable>:
    @unchecked
    Sendable
{
    private let factory: @Sendable (Key) async -> Output
    private let lock = NSLock()
    private var waiters: [Key: [CheckedContinuation<Output, Never>]] = [:]
    private var activeTasks: [Key: Task<Void, Never>] = [:]

    public init(_ factory: @escaping @Sendable (Key) async -> Output) {
        self.factory = factory
    }

    public func execute(key: Key) async -> Output {
        await withCheckedContinuation { (cont: CheckedContinuation<Output, Never>) in
            lock.withLock {
                waiters[key, default: []].append(cont)
                if activeTasks[key] == nil {
                    activeTasks[key] = Task { [self] in
                        await self.runWork(key: key)
                    }
                }
            }
        }
    }

    private func runWork(key: Key) async {
        let result = await factory(key)
        let pending: [CheckedContinuation<Output, Never>] = lock.withLock {
            let p = waiters.removeValue(forKey: key) ?? []
            activeTasks.removeValue(forKey: key)
            return p
        }
        for cont in pending {
            cont.resume(returning: result)
        }
    }
}

// MARK: - ThrowingKeyedAsyncDemuxer

/// Like `KeyedAsyncDemuxer`, but for work that may throw. Errors fan out
/// to every waiter on the current execution *for that key*; per-waiter
/// cancellation is honored independently.
public final class ThrowingKeyedAsyncDemuxer<Key: Hashable & Sendable, Output: Sendable>:
    @unchecked Sendable
{
    private let factory: @Sendable (Key) async throws -> Output
    private let lock = NSLock()
    private var waiters: [Key: [(UUID, CheckedContinuation<Output, any Error>)]] = [:]
    private var activeTasks: [Key: Task<Void, Never>] = [:]

    public init(_ factory: @escaping @Sendable (Key) async throws -> Output) {
        self.factory = factory
    }

    public func execute(key: Key) async throws -> Output {
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation {
                (cont: CheckedContinuation<Output, any Error>) in
                lock.withLock {
                    waiters[key, default: []].append((id, cont))
                    if activeTasks[key] == nil {
                        activeTasks[key] = Task { [self] in
                            await self.runWork(key: key)
                        }
                    }
                }
            }
        } onCancel: {
            lock.withLock {
                guard var list = waiters[key] else { return }
                if let idx = list.firstIndex(where: { $0.0 == id }) {
                    let (_, cont) = list.remove(at: idx)
                    if list.isEmpty {
                        waiters.removeValue(forKey: key)
                    } else {
                        waiters[key] = list
                    }
                    cont.resume(throwing: CancellationError())
                }
            }
        }
    }

    private func runWork(key: Key) async {
        let outcome: Result<Output, any Error>
        do {
            outcome = .success(try await factory(key))
        } catch {
            outcome = .failure(error)
        }
        let pending: [(UUID, CheckedContinuation<Output, any Error>)] = lock.withLock {
            let p = waiters.removeValue(forKey: key) ?? []
            activeTasks.removeValue(forKey: key)
            return p
        }
        for (_, cont) in pending {
            cont.resume(with: outcome)
        }
    }
}
