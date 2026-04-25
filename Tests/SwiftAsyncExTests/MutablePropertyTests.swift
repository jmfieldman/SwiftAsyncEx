//
//  MutablePropertyTests.swift
//  Copyright © 2026 Jason Fieldman.
//

import XCTest

@testable import SwiftAsyncEx

@MainActor
final class MutablePropertyTests: XCTestCase {
    // MARK: - Basics

    func testInitialValue() {
        let p = MutableProperty(42)
        XCTAssertEqual(p.value, 42)
    }

    func testWriteUpdatesValue() {
        let p = MutableProperty(0)
        p.value = 7
        XCTAssertEqual(p.value, 7)
    }

    func testModifyMutatesInPlace() {
        let p = MutableProperty<[Int]>([])
        p.modify { $0.append(1) }
        p.modify { $0.append(2) }
        p.modify { $0.append(3) }
        XCTAssertEqual(p.value, [1, 2, 3])
    }

    // MARK: - Observation

    func testValueChangesAreObservable() async {
        let p = MutableProperty(0)
        let (stream, cont) = AsyncStream<Int>.makeStream()
        let obs = Task.observe(emitInitial: false, expression: { p.value }) { v in cont.yield(v) }
        await Task<Never, Never>.yield()

        p.value = 1
        var iter = stream.makeAsyncIterator()
        let v1 = await iter.next()
        XCTAssertEqual(v1, 1)

        p.value = 2
        let v2 = await iter.next()
        XCTAssertEqual(v2, 2)

        obs.cancel()
        cont.finish()
    }

    // MARK: - Cross-actor helpers

    nonisolated func testSetFromBackgroundTask() async {
        let p = await MainActor.run { MutableProperty(0) }
        await Task.detached {
            await p.set(99)
        }.value
        let v = await MainActor.run { p.value }
        XCTAssertEqual(v, 99)
    }

    nonisolated func testReadFromBackgroundTask() async {
        let p = await MainActor.run { MutableProperty(7) }
        let v = await Task.detached {
            await p.read()
        }.value
        XCTAssertEqual(v, 7)
    }

    nonisolated func testSequentialSetsFromBackgroundArriveInOrder() async {
        let p = await MainActor.run { MutableProperty(0) }
        await Task.detached {
            await p.set(1)
            await p.set(2)
            await p.set(3)
        }.value
        let v = await MainActor.run { p.value }
        XCTAssertEqual(v, 3)
    }

    // MARK: - Protocol usage

    func testConformsToMutablePropertyProtocol() {
        let p: any MutablePropertyProtocol<Int> = MutableProperty(5)
        XCTAssertEqual(p.value, 5)
        p.value = 10
        XCTAssertEqual(p.value, 10)
    }

    func testConformsToPropertyProtocol() {
        let p: any PropertyProtocol<String> = MutableProperty("hi")
        XCTAssertEqual(p.value, "hi")
    }
}
