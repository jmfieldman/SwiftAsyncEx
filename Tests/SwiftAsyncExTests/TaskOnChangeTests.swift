//
//  TaskOnChangeTests.swift
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

@MainActor
final class TaskOnChangeTests: XCTestCase {
    // MARK: - Basic firing

    func testFiresOnChange() async {
        let model = TestModel()
        let (stream, cont) = AsyncStream<Int>.makeStream()

        let task = Task.onChange(of: { model.count }) { new in
            cont.yield(new)
        }

        // Let the onChange loop register its observer.
        await Task.yield()

        model.count = 42

        var iter = stream.makeAsyncIterator()
        let received = await iter.next()
        XCTAssertEqual(received, 42)

        task.cancel()
        cont.finish()
    }

    func testFiresOnEachSequentialChange() async {
        let model = TestModel()
        let (stream, cont) = AsyncStream<Int>.makeStream()

        let task = Task.onChange(of: { model.count }) { new in
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

    // MARK: - Does not fire on setup

    func testDoesNotFireInitially() async {
        let model = TestModel()
        let fireCount = FireCounter()

        let task = Task.onChange(of: { model.count }) { _ in
            fireCount.increment()
        }

        // Let the task have plenty of time to set up and potentially fire.
        for _ in 0..<20 { await Task.yield() }

        task.cancel()
        await task.value

        XCTAssertEqual(fireCount.value, 0)
    }

    // MARK: - Deduplication of equal values

    func testDoesNotFireForEqualValues() async {
        let model = TestModel()
        let (stream, cont) = AsyncStream<Int>.makeStream()

        let task = Task.onChange(of: { model.count }) { new in
            cont.yield(new)
        }

        await Task.yield()

        var iter = stream.makeAsyncIterator()

        // Transition 0 -> 1 fires.
        model.count = 1
        let v1 = await iter.next()
        XCTAssertEqual(v1, 1)

        // Assignments of the same value still trigger willSet, but the
        // post-yield comparison against `last` should suppress perform.
        model.count = 1
        model.count = 1

        // A subsequent distinct value must still fire normally.
        model.count = 2
        let v2 = await iter.next()
        XCTAssertEqual(v2, 2)

        task.cancel()
        cont.finish()
    }

    // MARK: - Tracking across multiple properties via the expression

    func testFiresWhenAnyTrackedPropertyChanges() async {
        let model = TestModel()
        let (stream, cont) = AsyncStream<String>.makeStream()

        let task = Task.onChange(of: { "\(model.count):\(model.name)" }) { new in
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
        let task = Task.onChange(of: { model.count }) { _ in }

        // Let the loop enter its observation-wait.
        await Task.yield()

        task.cancel()

        // If cancellation does not unblock the continuation, this awaits forever.
        await task.value
    }

    func testCancelStopsFurtherFiring() async {
        let model = TestModel()
        let fireCount = FireCounter()

        let task = Task.onChange(of: { model.count }) { _ in
            fireCount.increment()
        }

        await Task.yield()

        model.count = 1
        // Wait for the first fire.
        for _ in 0..<50 {
            if fireCount.value == 1 { break }
            await Task.yield()
        }
        XCTAssertEqual(fireCount.value, 1)

        task.cancel()
        await task.value

        // Further mutations should not trigger.
        model.count = 2
        model.count = 3
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(fireCount.value, 1)
    }

    // MARK: - Integration with TaskBag

    func testBindsToTaskBag() async {
        let model = TestModel()
        let bag = TaskBag()
        let (stream, cont) = AsyncStream<Int>.makeStream()

        Task.onChange(of: { model.count }) { new in
            cont.yield(new)
        }.bind(to: bag)

        await Task.yield()

        model.count = 11
        var iter = stream.makeAsyncIterator()
        let received = await iter.next()
        XCTAssertEqual(received, 11)

        XCTAssertEqual(bag.count, 1)
        bag.cancelAll()
        cont.finish()
    }
}

// MARK: - Helpers

@MainActor
private final class FireCounter {
    private(set) var value: Int = 0
    func increment() { value += 1 }
}
