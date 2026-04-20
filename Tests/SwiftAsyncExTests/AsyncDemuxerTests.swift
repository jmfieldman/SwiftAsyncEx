//
//  AsyncDemuxerTests.swift
//  Copyright © 2026 Jason Fieldman.
//

import XCTest

@testable import SwiftAsyncEx

final class AsyncDemuxerTests: XCTestCase {
    // MARK: - AsyncDemuxer (non-throwing)

    func testSingleExecuteReturnsValue() async {
        let demuxer = AsyncDemuxer<Int> { 42 }
        let v = await demuxer.execute()
        XCTAssertEqual(v, 42)
    }

    func testConcurrentExecutesCoalesceIntoOneWorkInvocation() async {
        let counter = DemuxerCounter()
        let gate = DemuxerAsyncGate()
        // The work blocks on the gate so the shared task can't drain until
        // every concurrent caller has attached. Otherwise, an eager shared
        // task could complete before slow-to-schedule callers attach, and
        // those callers would start a fresh execution — giving counter > 1
        // and masking the coalesce check as a scheduling race.
        let demuxer = AsyncDemuxer<Int> {
            counter.increment()
            await gate.wait()
            return 7
        }

        let group = Task {
            await withTaskGroup(of: Int.self) { group in
                for _ in 0..<20 {
                    group.addTask { await demuxer.execute() }
                }
                var collected: [Int] = []
                for await r in group { collected.append(r) }
                return collected
            }
        }

        // Give every task-group member a chance to attach as a waiter
        // before we unblock the shared execution.
        for _ in 0..<100 { await Task<Never, Never>.yield() }
        await gate.open()

        let results = await group.value
        XCTAssertEqual(results.count, 20)
        XCTAssertTrue(results.allSatisfy { $0 == 7 })
        XCTAssertEqual(counter.value, 1, "work must run exactly once for the coalesced batch")
    }

    func testSubsequentExecuteAfterCompletionStartsFreshWork() async {
        let counter = DemuxerCounter()
        let demuxer = AsyncDemuxer<Int> {
            counter.increment()
            return 1
        }
        _ = await demuxer.execute()
        _ = await demuxer.execute()
        _ = await demuxer.execute()
        XCTAssertEqual(counter.value, 3)
    }

    // MARK: - ThrowingAsyncDemuxer

    func testThrowingSingleExecuteReturnsValue() async throws {
        let demuxer = ThrowingAsyncDemuxer<Int> { 11 }
        let v = try await demuxer.execute()
        XCTAssertEqual(v, 11)
    }

    func testThrowingErrorFansOutToAllWaiters() async {
        let counter = DemuxerCounter()
        let gate = DemuxerAsyncGate()
        let demuxer = ThrowingAsyncDemuxer<Int> {
            counter.increment()
            await gate.wait()
            throw DemuxerTestError.boom
        }

        let group = Task {
            await withTaskGroup(of: Bool.self) { group in
                for _ in 0..<10 {
                    group.addTask {
                        do {
                            _ = try await demuxer.execute()
                            return false
                        } catch let error as DemuxerTestError where error == .boom {
                            return true
                        } catch {
                            return false
                        }
                    }
                }
                var count = 0
                for await ok in group where ok { count += 1 }
                return count
            }
        }

        for _ in 0..<100 { await Task<Never, Never>.yield() }
        await gate.open()

        let errorCount = await group.value
        XCTAssertEqual(errorCount, 10)
        XCTAssertEqual(counter.value, 1)
    }

    func testThrowingSubsequentExecuteAfterCompletionStartsFreshWork() async throws {
        let counter = DemuxerCounter()
        let demuxer = ThrowingAsyncDemuxer<Int> {
            counter.increment()
            return 1
        }
        _ = try await demuxer.execute()
        _ = try await demuxer.execute()
        XCTAssertEqual(counter.value, 2)
    }

    // MARK: - Cancellation

    func testThrowingCancellingOneWaiterDoesNotAffectOthers() async throws {
        let gate = DemuxerAsyncGate()
        let counter = DemuxerCounter()
        let demuxer = ThrowingAsyncDemuxer<Int> {
            counter.increment()
            await gate.wait()
            return 99
        }

        // Waiter that will be cancelled.
        let cancellable = Task {
            do {
                _ = try await demuxer.execute()
                return "completed"
            } catch is CancellationError {
                return "cancelled"
            } catch {
                return "other-error"
            }
        }

        // Waiter that will be allowed to complete.
        let normal = Task {
            do {
                return try await demuxer.execute()
            } catch {
                return -1
            }
        }

        // Let both waiters register.
        for _ in 0..<10 { await Task<Never, Never>.yield() }

        cancellable.cancel()

        // Give the cancellation handler a chance to run.
        for _ in 0..<10 { await Task<Never, Never>.yield() }

        // Release the work so the normal waiter completes.
        await gate.open()

        let cancelledResult = await cancellable.value
        let normalResult = await normal.value
        XCTAssertEqual(cancelledResult, "cancelled")
        XCTAssertEqual(normalResult, 99)
        XCTAssertEqual(counter.value, 1)
    }

    func testThrowingAllWaitersCancelledAllowsFreshExecution() async throws {
        let gate = DemuxerAsyncGate()
        let counter = DemuxerCounter()
        let demuxer = ThrowingAsyncDemuxer<Int> {
            counter.increment()
            await gate.wait()
            return 1
        }

        let a = Task { try? await demuxer.execute() }
        let b = Task { try? await demuxer.execute() }

        for _ in 0..<10 { await Task<Never, Never>.yield() }
        a.cancel()
        b.cancel()

        // Let cancellations land; the shared task is still waiting on gate.
        for _ in 0..<10 { await Task<Never, Never>.yield() }

        // Release so the first shared task drains (to no waiters).
        await gate.open()
        _ = await a.value
        _ = await b.value

        // A fresh execute should start a new work invocation.
        await gate.reset()
        let fresh = Task {
            try? await demuxer.execute()
        }
        for _ in 0..<5 { await Task<Never, Never>.yield() }
        await gate.open()
        _ = await fresh.value
        XCTAssertEqual(counter.value, 2)
    }
}

// MARK: - Helpers

final class DemuxerCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.withLock { _value } }
    func increment() { lock.withLock { _value += 1 } }
}

/// An async gate that blocks `wait()` callers until `open()` is invoked.
/// Safe to call from any isolation context.
final class DemuxerAsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { cont in
            let resumeNow = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiters.append(cont)
                return false
            }
            if resumeNow { cont.resume() }
        }
    }

    func open() async {
        let toResume: [CheckedContinuation<Void, Never>] = lock.withLock {
            isOpen = true
            let w = waiters
            waiters = []
            return w
        }
        for c in toResume { c.resume() }
    }

    func reset() async {
        lock.withLock { isOpen = false }
    }
}

enum DemuxerTestError: Error, Equatable {
    case boom
}
