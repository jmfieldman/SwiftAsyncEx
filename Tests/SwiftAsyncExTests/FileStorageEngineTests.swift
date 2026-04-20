//
//  FileStorageEngineTests.swift
//  Copyright © 2026 Jason Fieldman.
//

import XCTest

@testable import SwiftAsyncEx

final class FileStorageEngineTests: XCTestCase {
    private struct Nested: Codable, Equatable, Sendable {
        let id: Int
        let name: String
    }

    private var tempDir: URL!
    private var engine: FileStorageEngine!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftasyncex-tests-\(UUID().uuidString)")
        engine = try FileStorageEngine(rootDirectoryUrl: tempDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    // MARK: - Init

    func testInitCreatesDirectory() {
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    func testRootDirectoryConvenienceInitWithSubpath() throws {
        let subpath = "swiftasyncex-tests-\(UUID().uuidString)"
        let e = try FileStorageEngine(rootDirectory: .temporary, subpath: subpath)
        XCTAssertTrue(e.rootDirectoryUrl.path.hasSuffix(subpath))
        try? FileManager.default.removeItem(at: e.rootDirectoryUrl)
    }

    // MARK: - Round-trip

    func testStoreAndRetrieveInt() throws {
        let key = PersistentPropertyKey(key: "k")
        try engine.store(value: 42, key: key)
        let got: Int? = try engine.retrieve(key: key)
        XCTAssertEqual(got, 42)
    }

    func testStoreAndRetrieveString() throws {
        let key = PersistentPropertyKey(key: "k")
        try engine.store(value: "hello", key: key)
        let got: String? = try engine.retrieve(key: key)
        XCTAssertEqual(got, "hello")
    }

    func testStoreAndRetrieveStruct() throws {
        let key = PersistentPropertyKey(key: "n")
        let original = Nested(id: 9, name: "yes")
        try engine.store(value: original, key: key)
        let got: Nested? = try engine.retrieve(key: key)
        XCTAssertEqual(got, original)
    }

    func testStoreAndRetrieveArray() throws {
        let key = PersistentPropertyKey(key: "a")
        try engine.store(value: ["a", "b", "c"], key: key)
        let got: [String]? = try engine.retrieve(key: key)
        XCTAssertEqual(got, ["a", "b", "c"])
    }

    func testStoreAndRetrieveOptional() throws {
        let key = PersistentPropertyKey(key: "o")
        let v: Int? = 5
        try engine.store(value: v, key: key)
        let got: Int?? = try engine.retrieve(key: key)
        XCTAssertEqual(got, .some(5))
    }

    func testStoreAndRetrieveOptionalNil() throws {
        let key = PersistentPropertyKey(key: "o")
        let v: Int? = nil
        try engine.store(value: v, key: key)
        let got: Int?? = try engine.retrieve(key: key)
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

    // MARK: - Sanitization in filenames

    func testIllegalCharKeyWritesSanitizedFilename() throws {
        let key = PersistentPropertyKey(key: "a/b?c:d")
        try engine.store(value: 1, key: key)
        let fileURL = tempDir.appendingPathComponent("a_b_c_d")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    // MARK: - Atomicity (observable via file presence)

    func testWriteIsAtomic() throws {
        let key = PersistentPropertyKey(key: "atomic")
        try engine.store(value: "v", key: key)
        // After an atomic write, the file exists at the final path (no
        // lingering temp file path).
        let fileURL = tempDir.appendingPathComponent("atomic")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    // MARK: - Remove / wipe

    func testRemoveDeletesFile() throws {
        let key = PersistentPropertyKey(key: "k")
        try engine.store(value: 1, key: key)
        try engine.remove(key: key)
        let got: Int? = try engine.retrieve(key: key)
        XCTAssertNil(got)
    }

    func testRemoveMissingKeyIsNoOp() {
        XCTAssertNoThrow(try engine.remove(key: .init(key: "ghost")))
    }

    func testWipeDirectoryClearsAllFiles() throws {
        try engine.store(value: 1, key: .init(key: "a"))
        try engine.store(value: 2, key: .init(key: "b"))
        try engine.wipeDirectory()
        let a: Int? = try engine.retrieve(key: .init(key: "a"))
        let b: Int? = try engine.retrieve(key: .init(key: "b"))
        XCTAssertNil(a)
        XCTAssertNil(b)
    }

    // MARK: - Decode error

    func testCorruptFileThrowsDecodeError() throws {
        let key = PersistentPropertyKey(key: "bad")
        let fileURL = tempDir.appendingPathComponent("bad")
        try Data("not json".utf8).write(to: fileURL)
        do {
            let _: Int? = try engine.retrieve(key: key)
            XCTFail("expected decode error")
        } catch let error as FileStorageEngine.StorageError {
            if case .decodeError = error {
                // expected
            } else {
                XCTFail("expected .decodeError, got \(error)")
            }
        }
    }

    // MARK: - PersistentProperty integration

    func testIntegratesWithPersistentProperty() async throws {
        let p = await MainActor.run {
            PersistentProperty(
                storageEngine: engine,
                key: "k",
                defaultValue: 0
            )
        }
        await MainActor.run {
            p.value = 123
        }
        await p.awaitPendingFlush()
        let got: Int? = try engine.retrieve(key: .init(key: "k"))
        XCTAssertEqual(got, 123)
    }

    func testPersistentPropertyRoundtripsThroughRestart() async throws {
        let key = PersistentPropertyKey(key: "k")
        do {
            let p = await MainActor.run {
                PersistentProperty(
                    storageEngine: engine,
                    key: key,
                    defaultValue: "empty"
                )
            }
            await MainActor.run { p.value = "persisted" }
            await p.awaitPendingFlush()
        }
        // "Restart": fresh PersistentProperty reading same engine/key.
        let p2 = await MainActor.run {
            PersistentProperty(
                storageEngine: engine,
                key: key,
                defaultValue: "empty"
            )
        }
        let v = await MainActor.run { p2.value }
        XCTAssertEqual(v, "persisted")
    }
}
