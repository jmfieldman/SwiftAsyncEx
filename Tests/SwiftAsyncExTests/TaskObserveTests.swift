//
//  TaskObserveTests.swift
//  Copyright © 2026 Jason Fieldman.
//

import Observation
import XCTest

@testable import SwiftAsyncEx

@Observable
@MainActor
private final class TestModel {
    var count: Int = 0
    var name: String = ""
}

// Non-Equatable observed type (reference types aren't Equatable by default).
@MainActor
private final class Payload {
    var tag: String
    init(_ tag: String) { self.tag = tag }
}

@Observable
@MainActor
private final class PayloadHolder {
    var payload: Payload = Payload("initial")
}

@MainActor
final class TaskObserveTests: XCTestCase {
    // MARK: - Initial emission

    func testEmitsInitialValueByDefault() async {
        let model = TestModel()
        model.count = 5
        let (stream, cont) = AsyncStream<Int>.makeStream()

        let task = Task.observe(expression: { model.count }) { new in
            cont.yield(new)
        }

        var iter = stream.makeAsyncIterator()
        let first = await iter.next()
        XCTAssertEqual(first, 5)

        task.cancel()
        cont.finish()
    }

    func testSkipsInitialWhenEmitInitialFalse() async {
        let model = TestModel()
        model.count = 5
        let fireCount = FireCounter()

        let task = Task.observe(emitInitial: false, expression: { model.count }) { _ in
            fireCount.increment()
        }

        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(fireCount.value, 0)

        task.cancel()
        await task.value
    }

    // MARK: - Firing on change

    func testFiresOnEachSequentialChange() async {
        let model = TestModel()
        let (stream, cont) = AsyncStream<Int>.makeStream()

        let task = Task.observe(emitInitial: false, expression: { model.count }) { new in
            cont.yield(new)
        }

        await Task.yield()

        var iter = stream.makeAsyncIterator()

        model.count = 1
        let v1 = await iter.next()
        XCTAssertEqual(v1, 1)

        model.count = 2
        let v2 = await iter.next()
        XCTAssertEqual(v2, 2)

        model.count = 3
        let v3 = await iter.next()
        XCTAssertEqual(v3, 3)

        task.cancel()
        cont.finish()
    }

    // MARK: - Deduplication (Equatable overload)

    func testDedupsEqualValuesByDefault() async {
        let model = TestModel()
        let (stream, cont) = AsyncStream<Int>.makeStream()

        let task = Task.observe(emitInitial: false, expression: { model.count }) { new in
            cont.yield(new)
        }

        await Task.yield()

        var iter = stream.makeAsyncIterator()

        model.count = 1
        let v1 = await iter.next()
        XCTAssertEqual(v1, 1)

        // willSet fires on each assignment, but the equality check should
        // suppress the perform callback.
        model.count = 1
        model.count = 1

        model.count = 2
        let v2 = await iter.next()
        XCTAssertEqual(v2, 2)

        task.cancel()
        cont.finish()
    }

    func testEmitsEveryChangeWhenRemoveDuplicatesFalse() async {
        // Smoke-test the dedup-off code path. Note: Swift Observation filters
        // same-value writes at the runtime level (an assignment of an equal
        // value does not trigger `onChange`), so there is no observable
        // difference between `removeDuplicates: true` and `false` for direct
        // stored properties. The flag matters for composed/projected
        // expressions where two distinct writes produce equal projected
        // values — those still fire Observation but can be deduped at the
        // pump. Here we just verify the flag doesn't break the happy path.
        let model = TestModel()
        let (stream, cont) = AsyncStream<Int>.makeStream()

        let task = Task.observe(
            emitInitial: true,
            removeDuplicates: false,
            expression: { model.count }
        ) { new in
            cont.yield(new)
        }

        var iter = stream.makeAsyncIterator()
        let v0 = await iter.next()
        XCTAssertEqual(v0, 0)

        model.count = 1
        let v1 = await iter.next()
        XCTAssertEqual(v1, 1)

        task.cancel()
        cont.finish()
    }

    // MARK: - Custom comparator (non-Equatable expression)

    func testCustomComparatorOnNonEquatableType() async {
        let holder = PayloadHolder()
        let (stream, cont) = AsyncStream<String>.makeStream()

        // Dedup by tag: equal tags suppress delivery.
        let task = Task.observe(
            emitInitial: false,
            removeDuplicates: { $0.tag == $1.tag },
            expression: { holder.payload }
        ) { payload in
            cont.yield(payload.tag)
        }

        await Task.yield()
        var iter = stream.makeAsyncIterator()

        holder.payload = Payload("a")
        let v1 = await iter.next()
        XCTAssertEqual(v1, "a")

        // New instance, same tag — should be suppressed.
        holder.payload = Payload("a")
        // Distinct tag — should fire.
        holder.payload = Payload("b")
        let v2 = await iter.next()
        XCTAssertEqual(v2, "b")

        task.cancel()
        cont.finish()
    }

    // MARK: - Non-Equatable overload fires on every change

    func testNonEquatableOverloadEmitsEveryChange() async {
        let holder = PayloadHolder()
        let (stream, cont) = AsyncStream<String>.makeStream()

        let task = Task.observe(
            emitInitial: false,
            expression: { holder.payload }
        ) { payload in
            cont.yield(payload.tag)
        }

        await Task.yield()
        var iter = stream.makeAsyncIterator()

        holder.payload = Payload("a")
        let v1 = await iter.next()
        XCTAssertEqual(v1, "a")
        holder.payload = Payload("a")
        let v2 = await iter.next()
        XCTAssertEqual(v2, "a")

        task.cancel()
        cont.finish()
    }

    // MARK: - KeyPath overloads

    func testKeyPathOverloadEmitsInitialAndChanges() async {
        let model = TestModel()
        model.count = 10
        let (stream, cont) = AsyncStream<Int>.makeStream()

        let task = Task.observe(\.count, on: model) { new in
            cont.yield(new)
        }

        var iter = stream.makeAsyncIterator()
        let v1 = await iter.next()
        XCTAssertEqual(v1, 10)

        model.count = 11
        let v2 = await iter.next()
        XCTAssertEqual(v2, 11)

        task.cancel()
        cont.finish()
    }

    func testKeyPathObserverDoesNotRetainRoot() async {
        var holder: TestModel? = TestModel()
        weak let weakHolder = holder

        let task = Task.observe(\.count, on: holder!, emitInitial: false) { _ in }

        await Task.yield()

        // Drop the strong reference. Because the observer captures the root
        // weakly, this must be sufficient for the model to deallocate — the
        // observer itself won't auto-terminate (Observation tracks writes, not
        // object lifecycle), but it also must not keep the root alive.
        holder = nil
        for _ in 0..<50 {
            if weakHolder == nil { break }
            await Task.yield()
        }

        XCTAssertNil(weakHolder, "KeyPath observer must not retain its root")

        task.cancel()
        await task.value
    }

    // MARK: - Tracking across multiple properties

    func testFiresWhenAnyTrackedPropertyChanges() async {
        let model = TestModel()
        let (stream, cont) = AsyncStream<String>.makeStream()

        let task = Task.observe(
            emitInitial: false,
            expression: { "\(model.count):\(model.name)" }
        ) { new in
            cont.yield(new)
        }

        await Task.yield()
        var iter = stream.makeAsyncIterator()

        model.count = 7
        let v1 = await iter.next()
        XCTAssertEqual(v1, "7:")

        model.name = "hello"
        let v2 = await iter.next()
        XCTAssertEqual(v2, "7:hello")

        task.cancel()
        cont.finish()
    }

    // MARK: - Cancellation

    func testCancelReturnsEvenWithoutMutation() async {
        let model = TestModel()
        let task = Task.observe(emitInitial: false, expression: { model.count }) { _ in }

        await Task.yield()
        task.cancel()
        // If cancellation does not unblock the continuation, this hangs.
        await task.value
    }

    func testCancelStopsFurtherFiring() async {
        let model = TestModel()
        let fireCount = FireCounter()

        let task = Task.observe(emitInitial: false, expression: { model.count }) { _ in
            fireCount.increment()
        }

        await Task.yield()

        model.count = 1
        for _ in 0..<50 {
            if fireCount.value == 1 { break }
            await Task.yield()
        }
        XCTAssertEqual(fireCount.value, 1)

        task.cancel()
        await task.value

        model.count = 2
        model.count = 3
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(fireCount.value, 1)
    }

    // MARK: - bindTo

    func testBindToOwnerCancelsWhenOwnerDeallocates() async {
        let model = TestModel()
        let fireCount = FireCounter()

        var owner: OwnerBox? = OwnerBox()
        weak let weakOwner = owner

        let task = Task.observe(
            emitInitial: false,
            bindTo: owner,
            expression: { model.count }
        ) { _ in
            fireCount.increment()
        }

        await Task.yield()
        model.count = 1
        for _ in 0..<50 {
            if fireCount.value == 1 { break }
            await Task.yield()
        }
        XCTAssertEqual(fireCount.value, 1)

        owner = nil
        // Owner's associated TaskBag releases on deinit and cancels the task.
        for _ in 0..<50 {
            if weakOwner == nil && task.isCancelled { break }
            await Task.yield()
        }
        XCTAssertNil(weakOwner)

        model.count = 2
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(fireCount.value, 1)
    }

    func testBindToBagStillReturnsCancellableTask() async {
        let model = TestModel()
        let bag = TaskBag()
        let (stream, cont) = AsyncStream<Int>.makeStream()

        Task.observe(
            emitInitial: false,
            bindTo: bag,
            expression: { model.count }
        ) { new in
            cont.yield(new)
        }

        await Task.yield()

        model.count = 11
        var iter = stream.makeAsyncIterator()
        let received = await iter.next()
        XCTAssertEqual(received, 11)

        XCTAssertEqual(bag.count, 1)
        bag.cancelAll()
        cont.finish()
    }

    // MARK: - Overload resolution

    // Compiles-only check: when T is Equatable, the Equatable overload is
    // selected (the call uses removeDuplicates: Bool, which only exists on
    // that overload). If the non-Equatable overload were picked instead,
    // this line would fail to compile.
    func testEquatableOverloadResolvesForEquatableT() async {
        let model = TestModel()
        let task = Task.observe(
            emitInitial: false,
            removeDuplicates: false,
            expression: { model.count }
        ) { _ in }
        task.cancel()
    }
}

// MARK: - Helpers

@MainActor
private final class FireCounter {
    private(set) var value: Int = 0
    func increment() { value += 1 }
}

@MainActor
private final class OwnerBox {}
