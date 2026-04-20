//
//  UserDefaultsStorageEngineTests.swift
//  Copyright © 2026 Jason Fieldman.
//

import XCTest

@testable import SwiftAsyncEx

final class UserDefaultsStorageEngineTests: XCTestCase {
    private struct Nested: Codable, Equatable, Sendable {
        let id: Int
        let name: String
    }

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var engine: UserDefaultsStorageEngine!

    override func setUp() {
        super.setUp()
        suiteName = "com.swiftasyncex.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        engine = UserDefaultsStorageEngine(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Round-trip

    func testStoreAndRetrieveInt() throws {
        let key = PersistentPropertyKey(key: "k")
        try engine.store(value: 42, key: key)
        let v: Int? = try engine.retrieve(key: key)
        XCTAssertEqual(v, 42)
    }

    func testStoreAndRetrieveString() throws {
        let key = PersistentPropertyKey(key: "k")
        try engine.store(value: "hello", key: key)
        let v: String? = try engine.retrieve(key: key)
        XCTAssertEqual(v, "hello")
    }

    func testStoreAndRetrieveStruct() throws {
        let key = PersistentPropertyKey(key: "n")
        let original = Nested(id: 3, name: "x")
        try engine.store(value: original, key: key)
        let got: Nested? = try engine.retrieve(key: key)
        XCTAssertEqual(got, original)
    }

    func testStoreAndRetrieveArray() throws {
        let key = PersistentPropertyKey(key: "a")
        try engine.store(value: [1, 2, 3], key: key)
        let got: [Int]? = try engine.retrieve(key: key)
        XCTAssertEqual(got, [1, 2, 3])
    }

    func testStoreAndRetrieveOptional() throws {
        let key = PersistentPropertyKey(key: "o")
        let value: String? = "present"
        try engine.store(value: value, key: key)
        let got: String?? = try engine.retrieve(key: key)
        XCTAssertEqual(got, .some("present"))
    }

    func testStoreAndRetrieveOptionalNil() throws {
        let key = PersistentPropertyKey(key: "o")
        let value: String? = nil
        try engine.store(value: value, key: key)
        let got: String?? = try engine.retrieve(key: key)
        XCTAssertEqual(got, .some(nil))
    }

    // MARK: - Missing / overwrite / isolation

    func testRetrieveMissingKeyReturnsNil() throws {
        let got: Int? = try engine.retrieve(key: .init(key: "missing"))
        XCTAssertNil(got)
    }

    func testStoreOverwrites() throws {
        let key = PersistentPropertyKey(key: "k")
        try engine.store(value: 1, key: key)
        try engine.store(value: 2, key: key)
        let got: Int? = try engine.retrieve(key: key)
        XCTAssertEqual(got, 2)
    }

    func testDifferentKeysDontCollide() throws {
        try engine.store(value: 1, key: .init(key: "a"))
        try engine.store(value: 2, key: .init(key: "b"))
        let a: Int? = try engine.retrieve(key: .init(key: "a"))
        let b: Int? = try engine.retrieve(key: .init(key: "b"))
        XCTAssertEqual(a, 1)
        XCTAssertEqual(b, 2)
    }

    func testSubKeyDistinguishesFromBase() throws {
        try engine.store(value: 1, key: .init(key: "foo"))
        try engine.store(value: 2, key: .init(key: "foo", subKey: "bar"))
        let base: Int? = try engine.retrieve(key: .init(key: "foo"))
        let sub: Int? = try engine.retrieve(key: .init(key: "foo", subKey: "bar"))
        XCTAssertEqual(base, 1)
        XCTAssertEqual(sub, 2)
    }

    // MARK: - Remove

    func testRemoveClearsValue() throws {
        let key = PersistentPropertyKey(key: "k")
        try engine.store(value: 99, key: key)
        engine.remove(key: key)
        let got: Int? = try engine.retrieve(key: key)
        XCTAssertNil(got)
    }

    func testRemoveMissingKeyIsNoOp() {
        engine.remove(key: .init(key: "ghost"))
        // No assertion needed — just shouldn't crash.
    }

    // MARK: - Type mismatch

    func testRetrievingWrongTypeThrows() throws {
        let key = PersistentPropertyKey(key: "k")
        try engine.store(value: "string", key: key)
        XCTAssertThrowsError(try engine.retrieve(key: key) as Int?)
    }

    // MARK: - PersistentProperty integration

    func testIntegratesWithPersistentProperty() async throws {
        let key = PersistentPropertyKey(key: "integrated")
        // Seed a value so init picks it up.
        try engine.store(value: 7, key: key)

        await MainActor.run {
            let p = PersistentProperty(
                storageEngine: engine,
                key: key,
                defaultValue: 0
            )
            XCTAssertEqual(p.value, 7)
            p.value = 11
            Task {
                await p.awaitPendingFlush()
            }
        }

        // Give the flush time to land.
        for _ in 0..<50 {
            if (try? engine.retrieve(key: key) as Int?) == 11 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let got: Int? = try engine.retrieve(key: key)
        XCTAssertEqual(got, 11)
    }
}
