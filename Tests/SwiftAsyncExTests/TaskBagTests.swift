//
//  TaskBagTests.swift
//  Copyright © 2026 Jason Fieldman.
//

import XCTest

@testable import SwiftAsyncEx

final class TaskBagTests: XCTestCase {
    // MARK: - Basic shape

    func testEmptyBagHasZeroCount() {
        let bag = TaskBag()
        XCTAssertEqual(bag.count, 0)
        XCTAssertTrue(bag.isEmpty)
    }

    func testInsertIncrementsCount() {
        let bag = TaskBag()
        let task = Task { [weak bag] in
            while !Task.isCancelled, bag != nil {
                await Task.yield()
            }
            return 1
        }
        bag.insert(task)
        XCTAssertEqual(bag.count, 1)
        XCTAssertFalse(bag.isEmpty)
        bag.cancelAll()
    }

    // MARK: - cancelAll

    func testCancelAllCancelsInsertedTasks() async {
        let bag = TaskBag()
        let task = Task { () -> String in
            while !Task.isCancelled {
                await Task.yield()
            }
            return "cancelled"
        }
        bag.insert(task)

        bag.cancelAll()

        let result = await task.value
        XCTAssertEqual(result, "cancelled")
        XCTAssertEqual(bag.count, 0)
    }

    // MARK: - deinit cancels tasks

    func testBagDeinitCancelsBoundTasks() async {
        // Build the task outside the optional-bag scope so we can keep
        // referencing it after the bag is gone.
        let task: Task<String, Never> = {
            let bag: TaskBag? = TaskBag()
            let t = Task { () -> String in
                while !Task.isCancelled {
                    await Task.yield()
                }
                return "cancelled"
            }
            bag!.insert(t)
            // Drop the only strong reference to the bag by returning from the
            // closure; the bag is released here and its `deinit` fires.
            _ = bag
            return t
        }()
        let result = await task.value
        XCTAssertEqual(result, "cancelled")
    }

    // MARK: - Pruning (post-hoc insert)

    func testTaskIsPrunedFromBagOnCompletion() async {
        let bag = TaskBag()
        let task = Task { "done" }
        bag.insert(task)
        XCTAssertEqual(bag.count, 1)

        _ = await task.value

        // Pruning happens via an observer Task; wait for it.
        for _ in 0..<200 {
            if bag.count == 0 { break }
            await Task.yield()
        }
        XCTAssertEqual(bag.count, 0)
    }

    // MARK: - Thread safety: concurrent inserts

    func testConcurrentInsertsAreThreadSafe() async {
        let bag = TaskBag()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    let t = Task<String, Never> { () -> String in
                        while !Task.isCancelled {
                            await Task.yield()
                        }
                        return "x"
                    }
                    bag.insert(t)
                }
            }
            await group.waitForAll()
        }
        XCTAssertEqual(bag.count, 50)
        bag.cancelAll()
    }
}
