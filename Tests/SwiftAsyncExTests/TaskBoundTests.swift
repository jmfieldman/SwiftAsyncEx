//
//  TaskBoundTests.swift
//  Copyright © 2026 Jason Fieldman.
//

import XCTest

@testable import SwiftAsyncEx

final class TaskBoundTests: XCTestCase {
    // Shared test owner. Kept outside test methods so captures don't
    // accidentally extend its lifetime.
    private final class Owner {}

    // MARK: - Task.bound(to: TaskBag) — non-throwing

    func testBoundToBagRunsTaskAndReturnsValue() async {
        let bag = TaskBag()
        let value = await Task.bound(to: bag) { 42 }.value
        XCTAssertEqual(value, 42)
    }

    func testBoundToBagIsPrunedOnCompletion() async {
        let bag = TaskBag()
        let task = Task.bound(to: bag) { "ok" }
        XCTAssertEqual(bag.count, 1)
        _ = await task.value
        // Pruning happens inside the wrapped operation's defer, so by the
        // time the value resolves, the entry is already removed.
        XCTAssertEqual(bag.count, 0)
    }

    func testBoundToBagIsCancelledWhenBagDeallocs() async {
        let task: Task<String, Never> = {
            let bag: TaskBag? = TaskBag()
            let t = Task.bound(to: bag!) { () -> String in
                while !Task.isCancelled {
                    await Task.yield()
                }
                return "cancelled"
            }
            _ = bag
            return t
        }()
        let result = await task.value
        XCTAssertEqual(result, "cancelled")
    }

    func testBoundToBagIsCancelledByCancelAll() async {
        let bag = TaskBag()
        let task = Task.bound(to: bag) { () -> String in
            while !Task.isCancelled {
                await Task.yield()
            }
            return "cancelled"
        }
        bag.cancelAll()
        let result = await task.value
        XCTAssertEqual(result, "cancelled")
    }

    // MARK: - Task.bound(to: AnyObject)

    func testBoundToOwnerRunsTaskAndReturnsValue() async {
        let owner = Owner()
        let value = await Task.bound(to: owner) { 7 }.value
        XCTAssertEqual(value, 7)
    }

    func testBoundToOwnerIsCancelledWhenOwnerDeallocs() async {
        let task: Task<String, Never> = {
            var owner: Owner? = Owner()
            let t = Task.bound(to: owner!) { () -> String in
                while !Task.isCancelled {
                    await Task.yield()
                }
                return "cancelled"
            }
            owner = nil
            return t
        }()
        let result = await task.value
        XCTAssertEqual(result, "cancelled")
    }

    func testBoundToSameOwnerReusesBag() {
        let owner = Owner()
        let bagA = TaskBag.associated(with: owner)
        let bagB = TaskBag.associated(with: owner)
        XCTAssertTrue(bagA === bagB)
    }

    // MARK: - Throwing variant

    private enum TestError: Error, Equatable { case boom }

    func testBoundThrowingVariantReturnsValue() async throws {
        let bag = TaskBag()
        let t: Task<Int, any Error> = Task.bound(to: bag) { 11 }
        let v = try await t.value
        XCTAssertEqual(v, 11)
    }

    func testBoundThrowingVariantThrows() async {
        let bag = TaskBag()
        let t: Task<Int, any Error> = Task.bound(to: bag) {
            throw TestError.boom
        }
        do {
            _ = try await t.value
            XCTFail("Expected throw")
        } catch let error as TestError {
            XCTAssertEqual(error, .boom)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testBoundThrowingIsCancelledByCancelAll() async {
        let bag = TaskBag()
        let t: Task<String, any Error> = Task.bound(to: bag) {
            while !Task.isCancelled {
                await Task.yield()
            }
            throw CancellationError()
        }
        bag.cancelAll()
        do {
            _ = try await t.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Post-hoc task.bind(to:)

    func testPostHocBindToBag() async {
        let bag = TaskBag()
        let t = Task { () -> String in
            while !Task.isCancelled {
                await Task.yield()
            }
            return "cancelled"
        }
        let returned = t.bind(to: bag)
        XCTAssertEqual(bag.count, 1)
        // `bind(to:)` returns the same underlying task value.
        XCTAssertEqual(returned, t)
        bag.cancelAll()
        let result = await t.value
        XCTAssertEqual(result, "cancelled")
    }

    func testPostHocBindToOwnerCancelsOnDealloc() async {
        let task: Task<String, Never> = {
            var owner: Owner? = Owner()
            let t = Task<String, Never> { () -> String in
                while !Task.isCancelled {
                    await Task.yield()
                }
                return "cancelled"
            }
            t.bind(to: owner!)
            owner = nil
            return t
        }()
        let result = await task.value
        XCTAssertEqual(result, "cancelled")
    }

    func testPostHocBindIsChainable() async {
        let bag = TaskBag()
        let value = await Task { 99 }.bind(to: bag).value
        XCTAssertEqual(value, 99)
    }
}
