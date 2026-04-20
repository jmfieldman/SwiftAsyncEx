//
//  InMemoryStorageEngineTests.swift
//  Copyright © 2026 Jason Fieldman.
//

import XCTest

@testable import SwiftAsyncEx

final class InMemoryStorageEngineTests: XCTestCase {
    private struct Nested: Codable, Equatable, Sendable {
        let id: Int
        let name: String
    }

    // MARK: - Round-trip

    func testStoreAndRetrieveInt() throws {
        let engine = InMemoryStorageEngine()
        let key = PersistentPropertyKey(key: "int")
        try engine.store(value: 42, key: key)
        let got: Int? = try engine.retrieve(key: key)
        XCTAssertEqual(got, 42)
    }

    func testStoreAndRetrieveString() throws {
        let engine = InMemoryStorageEngine()
        let key = PersistentPropertyKey(key: "s")
        try engine.store(value: "hello", key: key)
        let got: String? = try engine.retrieve(key: key)
        XCTAssertEqual(got, "hello")
    }

    func testStoreAndRetrieveStruct() throws {
        let engine = InMemoryStorageEngine()
        let key = PersistentPropertyKey(key: "nested")
        let original = Nested(id: 7, name: "alpha")
        try engine.store(value: original, key: key)
        let got: Nested? = try engine.retrieve(key: key)
        XCTAssertEqual(got, original)
    }

    func testStoreAndRetrieveArray() throws {
        let engine = InMemoryStorageEngine()
        let key = PersistentPropertyKey(key: "arr")
        try engine.store(value: [1, 2, 3], key: key)
        let got: [Int]? = try engine.retrieve(key: key)
        XCTAssertEqual(got, [1, 2, 3])
    }

    func testStoreAndRetrieveOptional() throws {
        let engine = InMemoryStorageEngine()
        let key = PersistentPropertyKey(key: "opt")
        let value: String? = "present"
        try engine.store(value: value, key: key)
        let got: String?? = try engine.retrieve(key: key)
        XCTAssertEqual(got, .some("present"))
    }

    func testStoreAndRetrieveOptionalNil() throws {
        let engine = InMemoryStorageEngine()
        let key = PersistentPropertyKey(key: "optnil")
        let value: String? = nil
        try engine.store(value: value, key: key)
        let got: String?? = try engine.retrieve(key: key)
        XCTAssertEqual(got, .some(nil))  // stored "nil" value, not "absent"
    }

    // MARK: - Missing key

    func testRetrieveMissingKeyReturnsNil() throws {
        let engine = InMemoryStorageEngine()
        let got: Int? = try engine.retrieve(key: .init(key: "missing"))
        XCTAssertNil(got)
    }

    // MARK: - Overwrite

    func testStoreOverwritesPreviousValue() throws {
        let engine = InMemoryStorageEngine()
        let key = PersistentPropertyKey(key: "k")
        try engine.store(value: 1, key: key)
        try engine.store(value: 2, key: key)
        let got: Int? = try engine.retrieve(key: key)
        XCTAssertEqual(got, 2)
    }

    // MARK: - Key isolation

    func testDifferentKeysDontCollide() throws {
        let engine = InMemoryStorageEngine()
        try engine.store(value: 1, key: .init(key: "a"))
        try engine.store(value: 2, key: .init(key: "b"))
        let a: Int? = try engine.retrieve(key: .init(key: "a"))
        let b: Int? = try engine.retrieve(key: .init(key: "b"))
        XCTAssertEqual(a, 1)
        XCTAssertEqual(b, 2)
    }

    func testSubKeyDistinguishesFromBaseKey() throws {
        let engine = InMemoryStorageEngine()
        try engine.store(value: 1, key: .init(key: "foo"))
        try engine.store(value: 2, key: .init(key: "foo", subKey: "bar"))
        let base: Int? = try engine.retrieve(key: .init(key: "foo"))
        let sub: Int? = try engine.retrieve(key: .init(key: "foo", subKey: "bar"))
        XCTAssertEqual(base, 1)
        XCTAssertEqual(sub, 2)
    }

    // MARK: - Wipe / remove

    func testWipeClearsAll() throws {
        let engine = InMemoryStorageEngine()
        try engine.store(value: 1, key: .init(key: "a"))
        try engine.store(value: 2, key: .init(key: "b"))
        engine.wipe()
        let a: Int? = try engine.retrieve(key: .init(key: "a"))
        let b: Int? = try engine.retrieve(key: .init(key: "b"))
        XCTAssertNil(a)
        XCTAssertNil(b)
    }

    func testRemoveSingleKey() throws {
        let engine = InMemoryStorageEngine()
        try engine.store(value: 1, key: .init(key: "a"))
        try engine.store(value: 2, key: .init(key: "b"))
        let removed = engine.remove(key: .init(key: "a"))
        XCTAssertTrue(removed)
        let a: Int? = try engine.retrieve(key: .init(key: "a"))
        let b: Int? = try engine.retrieve(key: .init(key: "b"))
        XCTAssertNil(a)
        XCTAssertEqual(b, 2)
    }

    func testRemoveMissingKeyReturnsFalse() {
        let engine = InMemoryStorageEngine()
        XCTAssertFalse(engine.remove(key: .init(key: "ghost")))
    }

    // MARK: - Decode type mismatch

    func testRetrievingWrongTypeThrows() throws {
        let engine = InMemoryStorageEngine()
        let key = PersistentPropertyKey(key: "k")
        try engine.store(value: "a string", key: key)
        XCTAssertThrowsError(try engine.retrieve(key: key) as Int?)
    }

    // MARK: - Sendable across tasks

    func testEngineUsableFromDetachedTask() async throws {
        let engine = InMemoryStorageEngine()
        let key = PersistentPropertyKey(key: "k")
        await Task.detached {
            try? engine.store(value: 99, key: key)
        }.value
        let got: Int? = try engine.retrieve(key: key)
        XCTAssertEqual(got, 99)
    }
}
