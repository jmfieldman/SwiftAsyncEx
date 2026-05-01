//
//  PropertyTests.swift
//  Copyright © 2026 Jason Fieldman.
//

import XCTest

@testable import SwiftAsyncEx

@MainActor
final class PropertyTests: XCTestCase {
    // MARK: - Constant

    func testConstantValue() {
        let p = Property.constant(42)
        XCTAssertEqual(p.value, 42)
    }

    // MARK: - Mirroring

    func testMirroringReflectsInitialValue() {
        let source = MutableProperty("hello")
        let p = Property(mirroring: source)
        XCTAssertEqual(p.value, "hello")
    }

    func testMirroringUpdatesWhenSourceChanges() async {
        let source = MutableProperty(0)
        let p = Property(mirroring: source)

        source.value = 1
        try? await waitForValue(p, equalTo: 1)
        XCTAssertEqual(p.value, 1)

        source.value = 2
        try? await waitForValue(p, equalTo: 2)
        XCTAssertEqual(p.value, 2)
    }

    func testMirroringReadOnlyFromConsumerPerspective() {
        let source = MutableProperty(10)
        let p: any PropertyProtocol<Int> = Property(mirroring: source)
        // Consumer can only read; no set exists on PropertyProtocol.
        XCTAssertEqual(p.value, 10)
    }

    func testMirroringKeepsSourceAlive() async {
        // Mirror a source that goes out of the outer scope; the Property's
        // pump closure should keep it alive and continue receiving updates.
        let p: Property<Int>
        let sourceRef: MutableProperty<Int>
        do {
            let source = MutableProperty(1)
            sourceRef = source
            p = Property(mirroring: source)
        }
        sourceRef.value = 99
        try? await waitForValue(p, equalTo: 99)
        XCTAssertEqual(p.value, 99)
    }

    // MARK: - Tracking closure

    func testTrackingClosureInitialValue() {
        let a = MutableProperty(2)
        let b = MutableProperty(3)
        let sum = Property(tracking: { a.value + b.value })
        XCTAssertEqual(sum.value, 5)
    }

    func testTrackingClosureUpdatesOnChange() async {
        let a = MutableProperty(1)
        let b = MutableProperty(10)
        let sum = Property(tracking: { a.value + b.value })

        a.value = 5
        try? await waitForValue(sum, equalTo: 15)
        XCTAssertEqual(sum.value, 15)

        b.value = 100
        try? await waitForValue(sum, equalTo: 105)
        XCTAssertEqual(sum.value, 105)
    }

    // MARK: - AsyncSequence init

    func testInitFromAsyncSequence() async {
        let (stream, cont) = AsyncStream<Int>.makeStream()
        let p = Property(initial: 0, from: stream)
        XCTAssertEqual(p.value, 0)

        cont.yield(1)
        try? await waitForValue(p, equalTo: 1)
        XCTAssertEqual(p.value, 1)

        cont.yield(42)
        try? await waitForValue(p, equalTo: 42)
        XCTAssertEqual(p.value, 42)

        cont.finish()
    }

    // MARK: - AsyncSequence init (Optional lift)

    func testInitFromAsyncSequenceOptionalStartsNil() {
        let (stream, _) = AsyncStream<Int>.makeStream()
        let p: Property<Int?> = Property(from: stream)
        XCTAssertNil(p.value)
    }

    func testInitFromAsyncSequenceOptionalUpdates() async {
        let (stream, cont) = AsyncStream<Int>.makeStream()
        let p: Property<Int?> = Property(from: stream)
        XCTAssertNil(p.value)

        cont.yield(7)
        try? await waitForValue(p, equalTo: 7)
        XCTAssertEqual(p.value, 7)

        cont.yield(13)
        try? await waitForValue(p, equalTo: 13)
        XCTAssertEqual(p.value, 13)

        cont.finish()
    }

    // MARK: - asAsyncSequence

    func testAsAsyncSequenceYieldsInitialValue() async {
        let source = MutableProperty(100)
        let stream = source.asAsyncSequence()
        var iter = stream.makeAsyncIterator()
        let first = await iter.next()
        XCTAssertEqual(first, 100)
    }

    func testAsAsyncSequenceYieldsOnChange() async {
        let source = MutableProperty(0)
        let stream = source.asAsyncSequence()
        var iter = stream.makeAsyncIterator()
        // Consume initial.
        _ = await iter.next()

        Task { @MainActor in
            source.value = 1
        }
        let v1 = await iter.next()
        XCTAssertEqual(v1, 1)

        Task { @MainActor in
            source.value = 2
        }
        let v2 = await iter.next()
        XCTAssertEqual(v2, 2)
    }

    // MARK: - Utilities

    /// Spin the main actor (via `Task.yield`) until `property.value == target`
    /// or a modest attempt limit is reached. The one-tick pump lag means a
    /// single yield is not always enough.
    @MainActor
    private func waitForValue<Value: Equatable & Sendable>(
        _ property: Property<Value>,
        equalTo target: Value,
        maxYields: Int = 20
    ) async throws {
        for _ in 0..<maxYields {
            if property.value == target { return }
            await Task<Never, Never>.yield()
        }
        if property.value != target {
            throw NSError(
                domain: "PropertyTestsTimeout",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Property did not reach \(target); last value = \(property.value)"]
            )
        }
    }
}
