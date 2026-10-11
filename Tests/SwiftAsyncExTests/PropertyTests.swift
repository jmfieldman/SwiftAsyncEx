//
//  PropertyTests.swift
//  Copyright © 2026 Jason Fieldman.
//

import XCTest
import Observation

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

    func testMirroringUpdatesSynchronouslyOnMainThread() throws {
        guard #available(macOS 27, *) else {
            throw XCTSkip("Synchronous didSet propagation requires macOS 27")
        }

        let source = MutableProperty(0)
        let mirror = Property(mirroring: source)

        source.value = 1

        XCTAssertEqual(mirror.value, 1)
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

    func testTrackingClosureUpdatesSynchronouslyOnMainThread() throws {
        guard #available(macOS 27, *) else {
            throw XCTSkip("Synchronous didSet propagation requires macOS 27")
        }

        let source = MutableProperty(2)
        let doubled = Property(tracking: { source.value * 2 })

        source.value = 3

        XCTAssertEqual(doubled.value, 6)
    }

    func testTrackingClosureCatchesUpAfterRapidBackgroundMutations() async throws {
        let source = LockedObservableInt(0)
        let doubled = Property(tracking: { source.value * 2 })

        let backgroundWriter = Task.detached {
            for value in 1...500 {
                source.value = value
            }
        }

        // Interleave writes from MainActor while the detached writer is
        // producing changes. The source lock makes these reads and writes
        // safe regardless of which thread wins each individual write.
        for value in 501...550 {
            source.value = value
            if value.isMultiple(of: 5) {
                await Task<Never, Never>.yield()
            }
        }
        await backgroundWriter.value

        // Establish a deterministic final write after both writers finish.
        source.value = 999
        try await waitForValue(doubled, equalTo: 1_998)
        XCTAssertEqual(doubled.value, 1_998)
    }

    func testTrackingClosureReadsLatestValueAfterOffMainBurst() async throws {
        let source = LockedObservableInt(0)
        let projected = Property(tracking: { "value=\(source.value)" })

        let writer = Task.detached {
            source.value = 1
            source.value = 2
            source.value = 3
            source.value = 4
        }
        await writer.value

        try await waitForValue(projected, equalTo: "value=4")
        XCTAssertEqual(projected.value, "value=4")
    }

    func testTrackingClosureRebindsConditionalDependencyAcrossThreads() async throws {
        let selectedSource = LockedObservableInt(0)
        let firstSource = LockedObservableInt(10)
        let secondSource = LockedObservableInt(20)
        let selected = Property(tracking: {
            selectedSource.value == 0 ? firstSource.value : secondSource.value
        })

        let backgroundWriter = Task.detached {
            for value in 11...210 {
                firstSource.value = value
                secondSource.value = value * 2
            }
        }

        // Change which dependency the closure reads while the background
        // writer is updating both sources.
        selectedSource.value = 1
        await backgroundWriter.value
        secondSource.value = 999

        try await waitForValue(selected, equalTo: 999)
        XCTAssertEqual(selected.value, 999)
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

/// A small `Observable` source whose storage can safely be changed from both
/// MainActor and detached tasks. The lock protects the value; the registrar
/// reports accesses and mutations to Observation.
private final class LockedObservableInt: Observable, @unchecked Sendable {
    private let registrar = ObservationRegistrar()
    private let lock = NSLock()
    private var storedValue: Int

    init(_ value: Int) {
        storedValue = value
    }

    var value: Int {
        get {
            registrar.access(self, keyPath: \.value)
            return lock.withLock { storedValue }
        }
        set {
            registrar.withMutation(of: self, keyPath: \.value) {
                lock.withLock { storedValue = newValue }
            }
        }
    }
}
