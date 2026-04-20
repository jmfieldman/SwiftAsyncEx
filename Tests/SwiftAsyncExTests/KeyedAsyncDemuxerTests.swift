//
//  KeyedAsyncDemuxerTests.swift
//  Copyright © 2026 Jason Fieldman.
//

import XCTest

@testable import SwiftAsyncEx

final class KeyedAsyncDemuxerTests: XCTestCase {
    // MARK: - KeyedAsyncDemuxer (non-throwing)

    func testSingleExecuteForKeyReturnsValue() async {
        let demuxer = KeyedAsyncDemuxer<String, Int> { key in
            key.count
        }
        let v = await demuxer.execute(key: "hello")
        XCTAssertEqual(v, 5)
    }

    func testConcurrentExecutesForSameKeyCoalesce() async {
        let counter = DemuxerCounter()
        let gate = DemuxerAsyncGate()
        let demuxer = KeyedAsyncDemuxer<String, String> { key in
            counter.increment()
            await gate.wait()
            return key.uppercased()
        }

        let group = Task {
            await withTaskGroup(of: String.self) { group in
                for _ in 0..<20 {
                    group.addTask { await demuxer.execute(key: "abc") }
                }
                var collected: [String] = []
                for await r in group { collected.append(r) }
                return collected
            }
        }

        for _ in 0..<100 { await Task<Never, Never>.yield() }
        await gate.open()

        let results = await group.value
        XCTAssertEqual(results.count, 20)
        XCTAssertTrue(results.allSatisfy { $0 == "ABC" })
        XCTAssertEqual(counter.value, 1)
    }

    func testConcurrentExecutesForDifferentKeysRunInParallel() async {
        let callsPerKey = KeyedDemuxerCounter()
        let demuxer = KeyedAsyncDemuxer<String, String> { key in
            callsPerKey.increment(key: key)
            for _ in 0..<5 { await Task<Never, Never>.yield() }
            return key.uppercased()
        }

        async let a = demuxer.execute(key: "a")
        async let b = demuxer.execute(key: "b")
        async let c = demuxer.execute(key: "c")

        let (va, vb, vc) = await (a, b, c)
        XCTAssertEqual(va, "A")
        XCTAssertEqual(vb, "B")
        XCTAssertEqual(vc, "C")
        XCTAssertEqual(callsPerKey.value(for: "a"), 1)
        XCTAssertEqual(callsPerKey.value(for: "b"), 1)
        XCTAssertEqual(callsPerKey.value(for: "c"), 1)
    }

    func testSubsequentExecuteForSameKeyAfterCompletionStartsFreshWork() async {
        let counter = DemuxerCounter()
        let demuxer = KeyedAsyncDemuxer<String, Int> { _ in
            counter.increment()
            return 1
        }
        _ = await demuxer.execute(key: "k")
        _ = await demuxer.execute(key: "k")
        XCTAssertEqual(counter.value, 2)
    }

    // MARK: - ThrowingKeyedAsyncDemuxer

    func testThrowingKeyedSingleExecuteReturnsValue() async throws {
        let demuxer = ThrowingKeyedAsyncDemuxer<String, Int> { key in
            key.count
        }
        let v = try await demuxer.execute(key: "swift")
        XCTAssertEqual(v, 5)
    }

    func testThrowingKeyedErrorFansOutForSameKey() async {
        let counter = DemuxerCounter()
        let gate = DemuxerAsyncGate()
        let demuxer = ThrowingKeyedAsyncDemuxer<String, Int> { _ in
            counter.increment()
            await gate.wait()
            throw DemuxerTestError.boom
        }

        let group = Task {
            await withTaskGroup(of: Bool.self) { group in
                for _ in 0..<10 {
                    group.addTask {
                        do {
                            _ = try await demuxer.execute(key: "x")
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

    func testThrowingKeyedDifferentKeysRunIndependently() async throws {
        let callsPerKey = KeyedDemuxerCounter()
        let demuxer = ThrowingKeyedAsyncDemuxer<String, String> { key in
            callsPerKey.increment(key: key)
            if key == "bad" {
                throw DemuxerTestError.boom
            }
            return key
        }

        async let good = demuxer.execute(key: "good")
        async let bad = Task { try? await demuxer.execute(key: "bad") }.value

        let goodResult = try await good
        let badResult = await bad
        XCTAssertEqual(goodResult, "good")
        XCTAssertNil(badResult)
        XCTAssertEqual(callsPerKey.value(for: "good"), 1)
        XCTAssertEqual(callsPerKey.value(for: "bad"), 1)
    }

    func testThrowingKeyedCancellingOneWaiterDoesNotAffectOthers() async throws {
        let gate = DemuxerAsyncGate()
        let counter = DemuxerCounter()
        let demuxer = ThrowingKeyedAsyncDemuxer<String, Int> { _ in
            counter.increment()
            await gate.wait()
            return 77
        }

        let cancellable = Task {
            do {
                _ = try await demuxer.execute(key: "k")
                return "completed"
            } catch is CancellationError {
                return "cancelled"
            } catch {
                return "other"
            }
        }

        let normal = Task {
            do {
                return try await demuxer.execute(key: "k")
            } catch {
                return -1
            }
        }

        for _ in 0..<10 { await Task<Never, Never>.yield() }
        cancellable.cancel()
        for _ in 0..<10 { await Task<Never, Never>.yield() }
        await gate.open()

        let cancelledResult = await cancellable.value
        let normalResult = await normal.value
        XCTAssertEqual(cancelledResult, "cancelled")
        XCTAssertEqual(normalResult, 77)
        XCTAssertEqual(counter.value, 1)
    }
}

// MARK: - Helpers

private final class KeyedDemuxerCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func increment(key: String) {
        lock.withLock {
            counts[key, default: 0] += 1
        }
    }
    func value(for key: String) -> Int {
        lock.withLock { counts[key] ?? 0 }
    }
}
