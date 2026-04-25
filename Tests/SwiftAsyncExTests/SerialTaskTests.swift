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

    func testRunReturnsOutputAndClearsIsExecuting() async throws {
        let t = SerialTask<Void, Int> {
            await Task<Never, Never>.yield()
            return 7
        }
        let value = try await t.run()
        XCTAssertEqual(value, 7)
        XCTAssertFalse(t.isExecuting)
    }

    func testIsExecutingTrueWhileWorkIsInFlight() async throws {
        let gate = Gate()
        let t = SerialTask<Void, Void> {
            await gate.wait()
        }
        let runTask = Task { try await t.run() }
        // Let run() pass its guards and flip isExecuting.
        await Task<Never, Never>.yield()
        XCTAssertTrue(t.isExecuting)
        gate.open()
        _ = try await runTask.value
        XCTAssertFalse(t.isExecuting)
    }

    // MARK: - Serial skip semantics

    func testSecondRunThrowsAlreadyExecuting() async throws {
        let gate = Gate()
        let t = SerialTask<Void, Void> {
            await gate.wait()
        }
        let first = Task { try await t.run() }
        await Task<Never, Never>.yield()
        XCTAssertTrue(t.isExecuting)

        do {
            try await t.run()
            XCTFail("Expected AlreadyExecuting to throw")
        } catch is SerialTask<Void, Void>.AlreadyExecuting {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        gate.open()
        _ = try await first.value
    }

    func testTryQuestionMarkCollapsesToNil() async {
        let gate = Gate()
        let t = SerialTask<Void, Int> {
            await gate.wait()
            return 99
        }
        let first = Task { try await t.run() }
        await Task<Never, Never>.yield()

        // try? converts both AlreadyExecuting and OwnerDeallocated to nil.
        let skipped: Int? = try? await t.run()
        XCTAssertNil(skipped)

        gate.open()
        let firstResult = try? await first.value
        XCTAssertEqual(firstResult, 99)
    }

    func testRunDoesNotDuplicateWorkWhileInFlight() async throws {
        let gate = Gate()
        let counter = Counter()
        let t = SerialTask<Void, Void> {
            counter.increment()
            await gate.wait()
        }
        let first = Task { try await t.run() }
        // Let the task start executing so counter increments.
        await Task<Never, Never>.yield()

        let second: Void? = try? await t.run()
        let third: Void? = try? await t.run()
        XCTAssertNil(second)
        XCTAssertNil(third)

        gate.open()
        _ = try await first.value
        XCTAssertEqual(counter.value, 1)
    }

    // MARK: - Non-Void input / output

    func testNonVoidInput() async throws {
        let received = Counter()
        let t = SerialTask<Int, Void> { input in
            received.value = input
        }
        try await t.run(42)
        XCTAssertEqual(received.value, 42)
    }

    func testNonVoidOutput() async throws {
        let t = SerialTask<Void, Int> { 99 }
        let value = try await t.run()
        XCTAssertEqual(value, 99)
    }

    // MARK: - cancel()

    func testCancelResetsIsExecuting() async {
        let gate = Gate()
        let t = SerialTask<Void, Void> {
            await gate.wait()
        }
        let runTask = Task { try await t.run() }
        await Task<Never, Never>.yield()
        XCTAssertTrue(t.isExecuting)

        t.cancel()
        XCTAssertFalse(t.isExecuting)

        gate.open()
        // The cancelled run must throw CancellationError.
        do {
            _ = try await runTask.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCancelAllowsFreshRun() async throws {
        let gate = Gate()
        let t = SerialTask<Void, Int> {
            await gate.wait()
            return 1
        }
        let first = Task { try await t.run() }
        await Task<Never, Never>.yield()
        XCTAssertTrue(t.isExecuting)

        t.cancel()
        XCTAssertFalse(t.isExecuting)

        // A new run should succeed even while the cancelled task's tail
        // is still draining.
        let second = Task { try await t.run() }
        await Task<Never, Never>.yield()
        XCTAssertTrue(t.isExecuting)

        gate.open()
        // First is displaced -> CancellationError; second completes.
        do {
            _ = try await first.value
            XCTFail("Expected CancellationError for displaced run")
        } catch is CancellationError {
            // expected
        }
        let secondValue = try await second.value
        XCTAssertEqual(secondValue, 1)
        XCTAssertFalse(t.isExecuting)
    }

    func testStaleTaskDoesNotFlipIsExecutingForNewRun() async throws {
        let gate1 = Gate()
        let gate2 = Gate()
        let whichGate = GateSelector(gate1: gate1, gate2: gate2)

        let t = SerialTask<Void, Void> {
            let g = whichGate.next()
            await g.wait()
        }

        let first = Task { try await t.run() } // consumes gate1
        await Task<Never, Never>.yield()
        t.cancel() // stale task still draining

        let second = Task { try await t.run() } // consumes gate2
        await Task<Never, Never>.yield()
        XCTAssertTrue(t.isExecuting)

        // Release the stale task first; its post-work handler must detect
        // generation mismatch and NOT flip isExecuting.
        gate1.open()
        await Task<Never, Never>.yield()
        await Task<Never, Never>.yield()
        XCTAssertTrue(t.isExecuting, "Stale task's completion must not flip state for the new run")

        gate2.open()
        _ = try await second.value
        XCTAssertFalse(t.isExecuting)

        // First must have thrown CancellationError.
        do {
            _ = try await first.value
            XCTFail("Expected CancellationError for stale run")
        } catch is CancellationError {
            // expected
        }
    }

    // MARK: - Caller cancellation propagation

    func testCallerCancellationPropagatesToWork() async {
        let gate = Gate()
        let observedCancel = Counter()
        let t = SerialTask<Void, Void> {
            await withTaskCancellationHandler {
                await gate.wait()
            } onCancel: {
                Task { @MainActor in observedCancel.increment() }
            }
        }

        let runTask = Task { try await t.run() }
        await Task<Never, Never>.yield()
        XCTAssertTrue(t.isExecuting)

        runTask.cancel()

        // The onCancel handler spawns a fresh `Task { @MainActor in ... }`
        // to do its increment, so a fixed number of yields can't guarantee
        // it lands before we assert. Poll until it does (capped) instead.
        await waitUntil { observedCancel.value >= 1 }
        XCTAssertGreaterThanOrEqual(observedCancel.value, 1)

        gate.open()
        do {
            _ = try await runTask.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - fire()

    func testFireExecutesWork() async {
        let gate = Gate()
        let counter = Counter()
        let t = SerialTask<Void, Void> {
            counter.increment()
            await gate.wait()
        }
        t.fire()
        // Wait for the work body itself to execute, not just isExecuting —
        // the latter flips before the inner work Task is scheduled.
        await waitUntil { counter.value == 1 }
        XCTAssertTrue(t.isExecuting)
        XCTAssertEqual(counter.value, 1)
        gate.open()
        await waitUntil { !t.isExecuting }
    }

    func testFireSwallowsAlreadyExecuting() async {
        let gate = Gate()
        let counter = Counter()
        let t = SerialTask<Void, Void> {
            counter.increment()
            await gate.wait()
        }
        t.fire()
        await waitUntil { counter.value == 1 }

        // Second fire should be a no-op (AlreadyExecuting swallowed).
        t.fire()
        t.fire()
        await Task<Never, Never>.yield()
        await Task<Never, Never>.yield()
        XCTAssertEqual(counter.value, 1)

        gate.open()
        await waitUntil { !t.isExecuting }
    }

    func testFireWithInput() async {
        let received = Counter()
        let t = SerialTask<Int, Void> { input in
            received.value = input
        }
        t.fire(123)
        await waitUntil { received.value == 123 }
        XCTAssertEqual(received.value, 123)
    }

    // MARK: - weak(_:) — throws OwnerDeallocated

    func testWeakFactoryRunsWhenOwnerAlive() async throws {
        let owner = WeakTestOwner()
        let t = SerialTask.weak(owner) { `self` in
            self.saves += 1
        }
        try await t.run()
        XCTAssertEqual(owner.saves, 1)
    }

    func testWeakFactoryThrowsWhenOwnerDeallocated() async {
        let t: SerialTask<Void, Void> = {
            var owner: WeakTestOwner? = WeakTestOwner()
            let t = SerialTask.weak(owner!) { `self` in
                self.saves += 1
            }
            owner = nil
            return t
        }()
        do {
            try await t.run()
            XCTFail("Expected OwnerDeallocated")
        } catch is SerialTask<Void, Void>.OwnerDeallocated {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertFalse(t.isExecuting)
    }

    func testWeakFactoryWithInput() async throws {
        let owner = WeakTestOwner()
        let t = SerialTask<Int, Void>.weak(owner) { `self`, input in
            self.saves += input
        }
        try await t.run(5)
        XCTAssertEqual(owner.saves, 5)
    }

    func testWeakFactoryWithNonVoidOutput() async throws {
        let owner = WeakTestOwner()
        let t = SerialTask<Void, Int>.weak(owner) { `self` in
            self.saves += 1
            return self.saves
        }
        let result = try await t.run()
        XCTAssertEqual(result, 1)
    }

    // MARK: - weak(_:default:) — substitutes default

    func testWeakWithDefaultRunsWhenOwnerAlive() async throws {
        let owner = WeakTestOwner()
        let t = SerialTask<Void, Int>.weak(owner, default: -1) { `self` in
            self.saves += 1
            return self.saves
        }
        let result = try await t.run()
        XCTAssertEqual(result, 1)
    }

    func testWeakWithDefaultReturnsDefaultWhenOwnerDeallocated() async throws {
        let t: SerialTask<Void, Int> = {
            var owner: WeakTestOwner? = WeakTestOwner()
            let t = SerialTask<Void, Int>.weak(owner!, default: -1) { `self` in
                self.saves += 1
                return self.saves
            }
            owner = nil
            return t
        }()
        let result = try await t.run()
        XCTAssertEqual(result, -1)
        XCTAssertFalse(t.isExecuting)
    }

    func testWeakWithDefaultAndInput() async throws {
        let t: SerialTask<Int, String> = {
            var owner: WeakTestOwner? = WeakTestOwner()
            let t = SerialTask<Int, String>.weak(owner!, default: "fallback") { _, _ in
                "real"
            }
            owner = nil
            return t
        }()
        let result = try await t.run(42)
        XCTAssertEqual(result, "fallback")
    }

    // MARK: - Throwing work

    func testThrowingWorkSuccessPath() async throws {
        // A work closure declared as `throws` that does not actually throw
        // behaves identically to a non-throwing closure.
        let t = SerialTask<Void, Int> {
            if false { throw TestError(code: 0) }
            return 42
        }
        let value = try await t.run()
        XCTAssertEqual(value, 42)
        XCTAssertFalse(t.isExecuting)
    }

    func testThrowingWorkPropagatesErrorAndClearsIsExecuting() async {
        let t = SerialTask<Void, Int> {
            throw TestError(code: 7)
        }
        do {
            _ = try await t.run()
            XCTFail("Expected TestError")
        } catch let error as TestError {
            XCTAssertEqual(error.code, 7)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertFalse(t.isExecuting)
    }

    func testThrowingWorkAllowsSubsequentRun() async throws {
        // A failing run must not poison the task — the state machine
        // resets and a subsequent run() proceeds as if nothing happened.
        let counter = Counter()
        let t = SerialTask<Void, Int> {
            counter.increment()
            if counter.value == 1 { throw TestError(code: 1) }
            return counter.value
        }
        do {
            _ = try await t.run()
            XCTFail("Expected TestError on first run")
        } catch is TestError {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertFalse(t.isExecuting)

        let value = try await t.run()
        XCTAssertEqual(value, 2)
        XCTAssertFalse(t.isExecuting)
    }

    func testThrowingWorkWithInput() async {
        let t = SerialTask<Int, Int> { input in
            if input < 0 { throw TestError(code: input) }
            return input * 2
        }
        do {
            _ = try await t.run(-3)
            XCTFail("Expected TestError")
        } catch let error as TestError {
            XCTAssertEqual(error.code, -3)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSecondRunThrowsAlreadyExecutingWhileThrowingWorkInFlight() async throws {
        // Serial-skip semantics must hold even when the in-flight work is
        // on a path that will eventually throw.
        let gate = Gate()
        let t = SerialTask<Void, Void> {
            await gate.wait()
            throw TestError(code: 0)
        }
        let first = Task { try await t.run() }
        await Task<Never, Never>.yield()
        XCTAssertTrue(t.isExecuting)

        do {
            try await t.run()
            XCTFail("Expected AlreadyExecuting")
        } catch is SerialTask<Void, Void>.AlreadyExecuting {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        gate.open()
        do {
            _ = try await first.value
            XCTFail("Expected TestError from first run")
        } catch is TestError {
            // expected
        } catch {
            XCTFail("Unexpected error from first run: \(error)")
        }
        XCTAssertFalse(t.isExecuting)
    }

    func testFireSwallowsWorkError() async {
        // `fire()` is contracted to swallow every outcome. That contract
        // must cover errors thrown by the work closure as well as the
        // task's own control errors.
        let attempts = Counter()
        let t = SerialTask<Void, Void> {
            attempts.increment()
            throw TestError(code: 1)
        }
        t.fire()
        await waitUntil { attempts.value == 1 }
        await waitUntil { !t.isExecuting }
        XCTAssertEqual(attempts.value, 1)
        XCTAssertFalse(t.isExecuting)
    }

    func testNonThrowingClosureAcceptedByThrowingInit() async throws {
        // The public init accepts `async throws -> Output`; passing a
        // non-throwing closure literal must continue to compile and run
        // because non-throwing is a subtype of throwing.
        let t = SerialTask<Void, Int> { 9 }
        let value = try await t.run()
        XCTAssertEqual(value, 9)
    }

    func testVoidConvenienceInitAcceptsThrowingWork() async {
        // The Input == Void convenience init's closure signature is
        // `() async throws -> Output`.
        let t = SerialTask<Void, Int> {
            throw TestError(code: 5)
        }
        do {
            _ = try await t.run()
            XCTFail("Expected TestError")
        } catch let error as TestError {
            XCTAssertEqual(error.code, 5)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - weak(_:) with throwing work

    func testWeakFactoryPropagatesWorkError() async {
        let owner = WeakTestOwner()
        let t = SerialTask<Void, Void>.weak(owner) { `self` in
            self.saves += 1
            throw TestError(code: 42)
        }
        do {
            try await t.run()
            XCTFail("Expected TestError")
        } catch let error as TestError {
            XCTAssertEqual(error.code, 42)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(owner.saves, 1)
        XCTAssertFalse(t.isExecuting)
    }

    func testWeakWithDefaultPropagatesWorkErrorWhenOwnerAlive() async {
        // `default:` substitutes only for owner-deallocation. When the
        // owner is alive and the work closure throws, the error is
        // surfaced unchanged.
        let owner = WeakTestOwner()
        let t = SerialTask<Void, Int>.weak(owner, default: -1) { `self` in
            self.saves += 1
            throw TestError(code: 99)
        }
        do {
            _ = try await t.run()
            XCTFail("Expected TestError")
        } catch let error as TestError {
            XCTAssertEqual(error.code, 99)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(owner.saves, 1)
        XCTAssertFalse(t.isExecuting)
    }

    func testWeakWithDefaultShortCircuitsBeforeThrowingWorkRunsWhenOwnerDeallocated() async throws {
        // Owner deallocation substitutes the default value without
        // invoking the work closure, even if the work would have thrown.
        let t: SerialTask<Void, Int> = {
            var owner: WeakTestOwner? = WeakTestOwner()
            let t = SerialTask<Void, Int>.weak(owner!, default: -1) { _ in
                XCTFail("work must not run after owner dealloc")
                throw TestError(code: 0)
            }
            owner = nil
            return t
        }()
        let result = try await t.run()
        XCTAssertEqual(result, -1)
        XCTAssertFalse(t.isExecuting)
    }

    // MARK: - Observation tracking

    func testIsExecutingIsObservable() async {
        let gate = Gate()
        let t = SerialTask<Void, Void> {
            await gate.wait()
        }
        let (stream, cont) = AsyncStream<Bool>.makeStream()
        let obs = Task.observe(emitInitial: false, expression: { t.isExecuting }) { value in
            cont.yield(value)
        }

        await Task<Never, Never>.yield()

        t.fire()
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

private struct TestError: Error, Equatable {
    let code: Int
}

@MainActor
private func waitUntil(
    maxYields: Int = 200,
    _ condition: @MainActor () -> Bool
) async {
    for _ in 0 ..< maxYields {
        if condition() { return }
        await Task<Never, Never>.yield()
    }
}
