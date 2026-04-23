//
//  PersistentPropertyTests.swift
//  Copyright © 2026 Jason Fieldman.
//

import XCTest

@testable import SwiftAsyncEx

@MainActor
final class PersistentPropertyTests: XCTestCase {
    // MARK: - Initialization

    func testInitWithNoStoredValueUsesDefault() {
        let engine = InMemoryStorageEngine()
        let p = PersistentProperty(
            storageEngine: engine,
            key: PersistentPropertyKey(key: "k"),
            defaultValue: 42
        )
        XCTAssertEqual(p.value, 42)
        XCTAssertNil(p.error)
    }

    func testInitLoadsStoredValue() throws {
        let engine = InMemoryStorageEngine()
        try engine.store(value: 99, key: .init(key: "k"))
        let p = PersistentProperty(
            storageEngine: engine,
            key: PersistentPropertyKey(key: "k"),
            defaultValue: 0
        )
        XCTAssertEqual(p.value, 99)
        XCTAssertNil(p.error)
    }

    func testInitRecordsRetrieveError() {
        let engine = FailingEngine()
        engine.shouldFailRetrieve = true
        let p = PersistentProperty(
            storageEngine: engine,
            key: PersistentPropertyKey(key: "k"),
            defaultValue: "fallback"
        )
        XCTAssertEqual(p.value, "fallback")
        XCTAssertNotNil(p.error)
        XCTAssertEqual(p.error as? FailingEngine.TestError, .retrieveFailed)
    }

    func testConvenienceInitAcceptsStringKey() throws {
        let engine = InMemoryStorageEngine()
        try engine.store(value: "hi", key: .init(key: "greeting"))
        let p = PersistentProperty(
            storageEngine: engine,
            key: "greeting",
            defaultValue: "default"
        )
        XCTAssertEqual(p.value, "hi")
    }

    // MARK: - Writes flush to engine

    func testWriteFlushesToEngine() async throws {
        let engine = InMemoryStorageEngine()
        let p = PersistentProperty(
            storageEngine: engine,
            key: "k",
            defaultValue: 0
        )
        p.value = 7
        await p.awaitPendingFlush()
        let stored: Int? = try engine.retrieve(key: .init(key: "k"))
        XCTAssertEqual(stored, 7)
    }

    func testSequentialWritesFlushInOrder() async {
        let engine = RecordingEngine()
        let p = PersistentProperty(
            storageEngine: engine,
            key: "k",
            defaultValue: 0
        )
        p.value = 1
        p.value = 2
        p.value = 3
        await p.awaitPendingFlush()
        XCTAssertEqual(engine.storedInts(for: "k"), [1, 2, 3])
    }

    func testModifyFlushes() async throws {
        let engine = InMemoryStorageEngine()
        let p = PersistentProperty<[Int]>(
            storageEngine: engine,
            key: "list",
            defaultValue: []
        )
        p.modify { $0.append(10) }
        p.modify { $0.append(20) }
        await p.awaitPendingFlush()
        let stored: [Int]? = try engine.retrieve(key: .init(key: "list"))
        XCTAssertEqual(stored, [10, 20])
    }

    // MARK: - Error surface on store failure

    func testStoreErrorSetsErrorProperty() async {
        let engine = FailingEngine()
        engine.shouldFailStore = true
        let p = PersistentProperty(
            storageEngine: engine,
            key: "k",
            defaultValue: 0
        )
        p.value = 1
        await p.awaitPendingFlush()
        XCTAssertEqual(p.error as? FailingEngine.TestError, .storeFailed)
    }

    // MARK: - Observation

    func testValueChangesAreObservable() async {
        let engine = InMemoryStorageEngine()
        let p = PersistentProperty(
            storageEngine: engine,
            key: "k",
            defaultValue: 0
        )
        let (stream, cont) = AsyncStream<Int>.makeStream()
        let obs = Task.observe(of: { p.value }, emitInitial: false) { v in cont.yield(v) }
        await Task<Never, Never>.yield()

        p.value = 10
        var iter = stream.makeAsyncIterator()
        let v1 = await iter.next()
        XCTAssertEqual(v1, 10)

        p.value = 20
        let v2 = await iter.next()
        XCTAssertEqual(v2, 20)

        obs.cancel()
        cont.finish()
    }

    func testErrorChangesAreObservable() async {
        let engine = FailingEngine()
        engine.shouldFailStore = true
        let p = PersistentProperty(
            storageEngine: engine,
            key: "k",
            defaultValue: 0
        )
        let (stream, cont) = AsyncStream<Bool>.makeStream()
        // Observe whether the error is non-nil.
        let obs = Task.observe(of: { p.error != nil }, emitInitial: false) { hasError in
            cont.yield(hasError)
        }
        await Task<Never, Never>.yield()

        p.value = 99
        var iter = stream.makeAsyncIterator()
        let got = await iter.next()
        XCTAssertEqual(got, true)

        obs.cancel()
        cont.finish()
    }

    // MARK: - Background-task ergonomics

    nonisolated func testSetFromBackgroundTaskUpdatesValue() async {
        let engine = InMemoryStorageEngine()
        let p = await MainActor.run {
            PersistentProperty(storageEngine: engine, key: "k", defaultValue: 0)
        }
        await Task.detached {
            await p.set(42)
        }.value
        let v = await MainActor.run { p.value }
        XCTAssertEqual(v, 42)
    }

    nonisolated func testSetFromBackgroundFlushesToEngine() async throws {
        let engine = InMemoryStorageEngine()
        let p = await MainActor.run {
            PersistentProperty(storageEngine: engine, key: "k", defaultValue: 0)
        }
        await Task.detached {
            await p.set(99)
        }.value
        await p.awaitPendingFlush()
        let stored: Int? = try engine.retrieve(key: .init(key: "k"))
        XCTAssertEqual(stored, 99)
    }

    nonisolated func testReadFromBackgroundTaskReturnsCurrentValue() async {
        let engine = InMemoryStorageEngine()
        let p = await MainActor.run {
            PersistentProperty(storageEngine: engine, key: "k", defaultValue: 7)
        }
        let got = await Task.detached {
            await p.read()
        }.value
        XCTAssertEqual(got, 7)
    }

    nonisolated func testSequentialSetsFromBackgroundArriveInOrder() async {
        let engine = RecordingEngine()
        let p = await MainActor.run {
            PersistentProperty(storageEngine: engine, key: "k", defaultValue: 0)
        }
        await Task.detached {
            await p.set(1)
            await p.set(2)
            await p.set(3)
        }.value
        await p.awaitPendingFlush()
        XCTAssertEqual(engine.storedInts(for: "k"), [1, 2, 3])
    }

    nonisolated func testReadAfterSetObservesWrite() async {
        let engine = InMemoryStorageEngine()
        let p = await MainActor.run {
            PersistentProperty(storageEngine: engine, key: "k", defaultValue: 0)
        }
        let got = await Task.detached {
            await p.set(123)
            return await p.read()
        }.value
        XCTAssertEqual(got, 123)
    }

    // MARK: - Optional Value type

    func testOptionalValueType() async throws {
        let engine = InMemoryStorageEngine()
        let p = PersistentProperty<String?>(
            storageEngine: engine,
            key: "opt",
            defaultValue: nil
        )
        XCTAssertNil(p.value)

        p.value = "hello"
        await p.awaitPendingFlush()
        let stored: String?? = try engine.retrieve(key: .init(key: "opt"))
        XCTAssertEqual(stored, .some("hello"))

        p.value = nil
        await p.awaitPendingFlush()
        let stored2: String?? = try engine.retrieve(key: .init(key: "opt"))
        XCTAssertEqual(stored2, .some(nil))
    }
}

// MARK: - Test engines

private final class FailingEngine: PersistentPropertyStorageEngine, @unchecked Sendable {
    enum TestError: Error, Equatable {
        case storeFailed
        case retrieveFailed
    }

    private let lock = NSLock()
    private var _storage: [String: Data] = [:]
    private var _shouldFailStore = false
    private var _shouldFailRetrieve = false

    var shouldFailStore: Bool {
        get { lock.withLock { _shouldFailStore } }
        set { lock.withLock { _shouldFailStore = newValue } }
    }
    var shouldFailRetrieve: Bool {
        get { lock.withLock { _shouldFailRetrieve } }
        set { lock.withLock { _shouldFailRetrieve = newValue } }
    }

    func store(value: some Codable & Sendable, key: PersistentPropertyKey) throws {
        if shouldFailStore { throw TestError.storeFailed }
        let data = try JSONEncoder().encode(Box(value: value))
        lock.withLock { _storage[key.sanitizedIndex] = data }
    }

    func retrieve<T: Codable & Sendable>(key: PersistentPropertyKey) throws -> T? {
        if shouldFailRetrieve { throw TestError.retrieveFailed }
        let data: Data? = lock.withLock { _storage[key.sanitizedIndex] }
        guard let data else { return nil }
        return try JSONDecoder().decode(Box<T>.self, from: data).value
    }

    private struct Box<T: Codable>: Codable { let value: T }
}

private final class RecordingEngine: PersistentPropertyStorageEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(String, Data)] = []

    func store(value: some Codable & Sendable, key: PersistentPropertyKey) throws {
        let data = try JSONEncoder().encode(Box(value: value))
        lock.withLock { calls.append((key.sanitizedIndex, data)) }
    }

    func retrieve<T: Codable & Sendable>(key: PersistentPropertyKey) throws -> T? {
        let last = lock.withLock {
            calls.last(where: { $0.0 == key.sanitizedIndex })
        }
        guard let last else { return nil }
        return try JSONDecoder().decode(Box<T>.self, from: last.1).value
    }

    func storedInts(for sanitized: String) -> [Int] {
        lock.withLock {
            calls
                .filter { $0.0 == sanitized }
                .compactMap { try? JSONDecoder().decode(Box<Int>.self, from: $0.1).value }
        }
    }

    private struct Box<T: Codable>: Codable { let value: T }
}
