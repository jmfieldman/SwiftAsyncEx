//
//  SerialTaskTests.swift
//  Copyright © 2026 Jason Fieldman.
//

import Observation
import XCTest

@testable import SwiftAsyncEx

@MainActor
final class SerialTaskTests: XCTestCase {
    // MARK: - Basic state transitions

    func testFreshTaskIsNotExecuting() {
        let t = SerialTask<Void, Void> {}
        XCTAssertFalse(t.isExecuting)
    }

    func testRunFlipsIsExecutingAndBacksOff() async {
        let t = SerialTask<Void, Void> {
            await Task<Never, Never>.yield()
        }
        let handle = t.run()
        XCTAssertNotNil(handle)
        XCTAssertTrue(t.isExecuting)
        _ = await handle?.value
        XCTAssertFalse(t.isExecuting)
    }

    // MARK: - Serial skip semantics

    func testRunSkipsWhileInFlight() async {
        let gate = Gate()
        let t = SerialTask<Void, Void> {
            await gate.wait()
        }
        let h1 = t.run()
        XCTAssertNotNil(h1)
        let h2 = t.run()
        XCTAssertNil(h2)
        let h3 = t.run()
        XCTAssertNil(h3)
        gate.open()
        _ = await h1?.value
        XCTAssertFalse(t.isExecuting)
    }

    func testRunDoesNotDuplicateWorkWhileInFlight() async {
        let gate = Gate()
        let counter = Counter()
        let t = SerialTask<Void, Void> {
            counter.increment()
            await gate.wait()
        }
        let h1 = t.run()
        // Let the task start executing so counter increments.
        await Task<Never, Never>.yield()
        _ = t.run()  // Should be skipped.
        _ = t.run()  // Should be skipped.
        gate.open()
        _ = await h1?.value
        XCTAssertEqual(counter.value, 1)
    }

    // MARK: - Cancellation

    func testCancelResetsIsExecuting() {
        let gate = Gate()
        let t = SerialTask<Void, Void> {
            await gate.wait()
        }
        _ = t.run()
        XCTAssertTrue(t.isExecuting)
        t.cancel()
        XCTAssertFalse(t.isExecuting)
        gate.open()  // Release any lingering awaiters.
    }

    func testCancelAllowsFreshRun() async {
        let gate = Gate()
        let t = SerialTask<Void, Void> {
            await gate.wait()
        }
        _ = t.run()
        XCTAssertTrue(t.isExecuting)

        t.cancel()
        XCTAssertFalse(t.isExecuting)

        // A new run() should succeed even though the cancelled task may
        // still be cooperatively draining.
        let h2 = t.run()
        XCTAssertNotNil(h2)
        XCTAssertTrue(t.isExecuting)

        t.cancel()
        gate.open()
    }

    func testStaleTaskDoesNotFlipIsExecutingForNewRun() async {
        // Long-running work for the first run; cancel, start a second run
        // with its own gate. The old task must not flip isExecuting when
        // it eventually completes.
        let gate1 = Gate()
        let gate2 = Gate()
        let whichGate = GateSelector(gate1: gate1, gate2: gate2)

        let t = SerialTask<Void, Void> {
            let g = whichGate.next()
            await g.wait()
        }

        _ = t.run()  // consumes gate1
        t.cancel()  // the stale task is still draining, waiting on gate1

        let h2 = t.run()  // consumes gate2
        XCTAssertTrue(t.isExecuting)

        // Release the stale task first. Its post-work handler should
        // detect generation mismatch and NOT flip isExecuting to false.
        gate1.open()
        await Task<Never, Never>.yield()
        await Task<Never, Never>.yield()
        XCTAssertTrue(t.isExecuting, "Stale task's completion must not flip state for the new run")

        // Now release the new task; it should flip correctly.
        gate2.open()
        _ = await h2?.value
        XCTAssertFalse(t.isExecuting)
    }

    // MARK: - Non-Void input / output

    func testNonVoidInput() async {
        let received = Counter()
        let t = SerialTask<Int, Void> { input in
            received.value = input
        }
        let h = t.run(42)
        _ = await h?.value
        XCTAssertEqual(received.value, 42)
    }

    func testNonVoidOutput() async {
        let t = SerialTask<Void, Int> { 99 }
        let h = t.run()
        let value = await h?.value
        XCTAssertEqual(value, 99)
    }

    // MARK: - weak(_:) factory

    func testWeakFactoryRunsWhenOwnerAlive() async {
        let owner = WeakTestOwner()
        let t = SerialTask.weak(owner) { `self` in
            self.saves += 1
        }
        let h = t.run()
        _ = await h?.value
        XCTAssertEqual(owner.saves, 1)
    }

    func testWeakFactorySkipsWhenOwnerDeallocated() {
        // Build a SerialTask that weakly holds an owner, then drop the
        // owner. run() must return nil and leave isExecuting false.
        let t: SerialTask<Void, Void> = {
            var owner: WeakTestOwner? = WeakTestOwner()
            let t = SerialTask.weak(owner!) { `self` in
                self.saves += 1
            }
            owner = nil
            return t
        }()
        let h = t.run()
        XCTAssertNil(h)
        XCTAssertFalse(t.isExecuting)
    }

    func testWeakFactoryWithInput() async {
        let owner = WeakTestOwner()
        let t = SerialTask<Int, Void>.weak(owner) { `self`, input in
            self.saves += input
        }
        _ = await t.run(5)?.value
        XCTAssertEqual(owner.saves, 5)
    }

    // MARK: - Observation tracking

    func testIsExecutingIsObservable() async {
        let gate = Gate()
        let t = SerialTask<Void, Void> {
            await gate.wait()
        }
        let (stream, cont) = AsyncStream<Bool>.makeStream()
        let obs = Task.onChange(of: { t.isExecuting }) { value in
            cont.yield(value)
        }

        await Task<Never, Never>.yield()

        _ = t.run()
        var iter = stream.makeAsyncIterator()
        let first = await iter.next()
        XCTAssertEqual(first, true)

        gate.open()
        let second = await iter.next()
        XCTAssertEqual(second, false)

        obs.cancel()
        cont.finish()
    }
}

// MARK: - Helpers

@MainActor
private final class Gate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { cont in
            continuations.append(cont)
        }
    }

    func open() {
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        for c in pending { c.resume() }
    }
}

@MainActor
private final class GateSelector {
    private let gates: [Gate]
    private var index = 0
    init(gate1: Gate, gate2: Gate) { gates = [gate1, gate2] }
    func next() -> Gate {
        let g = gates[index]
        index += 1
        return g
    }
}

@MainActor
private final class Counter {
    var value: Int = 0
    func increment() { value += 1 }
}

@Observable
@MainActor
private final class WeakTestOwner {
    var saves: Int = 0
}
