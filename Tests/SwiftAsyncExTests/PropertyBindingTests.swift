//
//  PropertyBindingTests.swift
//  Copyright © 2026 Jason Fieldman.
//

import XCTest

@testable import SwiftAsyncEx

@MainActor
final class PropertyBindingTests: XCTestCase {
    // MARK: - AsyncSequence source

    func testBindFromAsyncSequence() async {
        let dest = MutableProperty(0)
        let (stream, cont) = AsyncStream<Int>.makeStream()
        let task = dest <~ stream

        cont.yield(1)
        try? await waitForValue(dest, equalTo: 1)
        XCTAssertEqual(dest.value, 1)

        cont.yield(2)
        try? await waitForValue(dest, equalTo: 2)
        XCTAssertEqual(dest.value, 2)

        cont.finish()
        _ = await task.value
    }

    func testBindFromAsyncSequenceIsCancellable() async {
        let dest = MutableProperty(0)
        let (stream, cont) = AsyncStream<Int>.makeStream()
        let task = dest <~ stream

        cont.yield(1)
        try? await waitForValue(dest, equalTo: 1)

        task.cancel()
        _ = await task.value

        // After cancel, further yields should not affect dest.
        cont.yield(999)
        // Give the (now-cancelled) pump a chance to (not) run.
        for _ in 0 ..< 10 { await Task<Never, Never>.yield() }
        XCTAssertEqual(dest.value, 1)
        cont.finish()
    }

    // MARK: - Property source

    func testBindFromProperty() async {
        let source = MutableProperty(10)
        let dest = MutableProperty(0)
        _ = dest <~ source

        // Initial value should propagate.
        try? await waitForValue(dest, equalTo: 10)
        XCTAssertEqual(dest.value, 10)

        source.value = 20
        try? await waitForValue(dest, equalTo: 20)
        XCTAssertEqual(dest.value, 20)

        source.value = 30
        try? await waitForValue(dest, equalTo: 30)
        XCTAssertEqual(dest.value, 30)
    }

    // MARK: - PersistentProperty destination

    func testBindIntoPersistentProperty() async {
        let engine = InMemoryStorageEngine()
        let p = PersistentProperty(storageEngine: engine, key: "k", defaultValue: 0)
        let (stream, cont) = AsyncStream<Int>.makeStream()
        let task = p <~ stream

        cont.yield(42)
        try? await waitForPersistentValue(p, equalTo: 42)
        XCTAssertEqual(p.value, 42)

        cont.finish()
        _ = await task.value
        await p.awaitPendingFlush()

        let stored: Int? = try? engine.retrieve(key: .init(key: "k"))
        XCTAssertEqual(stored, 42)
    }

    // MARK: - Utilities

    @MainActor
    private func waitForValue<Value: Equatable & Sendable>(
        _ property: MutableProperty<Value>,
        equalTo target: Value,
        maxYields: Int = 20
    ) async throws {
        for _ in 0 ..< maxYields {
            if property.value == target { return }
            await Task<Never, Never>.yield()
        }
        if property.value != target {
            throw NSError(
                domain: "BindingTestsTimeout",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Property did not reach \(target); last value = \(property.value)"]
            )
        }
    }

    @MainActor
    private func waitForPersistentValue<Value: Equatable & Sendable>(
        _ property: PersistentProperty<Value>,
        equalTo target: Value,
        maxYields: Int = 20
    ) async throws {
        for _ in 0 ..< maxYields {
            if property.value == target { return }
            await Task<Never, Never>.yield()
        }
        if property.value != target {
            throw NSError(
                domain: "BindingTestsTimeout",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Persistent did not reach \(target); last value = \(property.value)"]
            )
        }
    }
}
