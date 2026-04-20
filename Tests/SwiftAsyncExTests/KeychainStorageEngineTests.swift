//
//  KeychainStorageEngineTests.swift
//  Copyright © 2026 Jason Fieldman.
//

import Security
import XCTest

@testable import SwiftAsyncEx

final class KeychainStorageEngineTests: XCTestCase {
    private struct Nested: Codable, Equatable, Sendable {
        let id: Int
        let name: String
    }

    private var service: String!
    private var engine: KeychainStorageEngine!

    override func setUpWithError() throws {
        try super.setUpWithError()
        service = "com.swiftasyncex.tests.\(UUID().uuidString)"

        // Preflight: some CI environments (particularly ones that run
        // tests without a login keychain) cannot access the keychain.
        // Probe once and skip the whole suite if that's the case.
        try Self.preflightKeychainOrSkip()

        engine = KeychainStorageEngine(service: service)
    }

    override func tearDownWithError() throws {
        try? engine?.wipe()
        try super.tearDownWithError()
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
        let original = Nested(id: 1, name: "z")
        try engine.store(value: original, key: key)
        let got: Nested? = try engine.retrieve(key: key)
        XCTAssertEqual(got, original)
    }

    func testStoreAndRetrieveOptional() throws {
        let key = PersistentPropertyKey(key: "o")
        let v: String? = "present"
        try engine.store(value: v, key: key)
        let got: String?? = try engine.retrieve(key: key)
        XCTAssertEqual(got, .some("present"))
    }

    func testStoreAndRetrieveOptionalNil() throws {
        let key = PersistentPropertyKey(key: "o")
        let v: String? = nil
        try engine.store(value: v, key: key)
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

    // MARK: - Service isolation

    func testServicesAreIsolated() throws {
        let other = KeychainStorageEngine(service: "com.swiftasyncex.tests.other.\(UUID().uuidString)")
        defer { try? other.wipe() }

        try engine.store(value: 1, key: .init(key: "k"))
        try other.store(value: 2, key: .init(key: "k"))

        let a: Int? = try engine.retrieve(key: .init(key: "k"))
        let b: Int? = try other.retrieve(key: .init(key: "k"))
        XCTAssertEqual(a, 1)
        XCTAssertEqual(b, 2)
    }

    // MARK: - Remove / wipe

    func testRemoveClearsValue() throws {
        let key = PersistentPropertyKey(key: "k")
        try engine.store(value: 5, key: key)
        try engine.remove(key: key)
        let got: Int? = try engine.retrieve(key: key)
        XCTAssertNil(got)
    }

    func testRemoveMissingKeyIsNoOp() {
        XCTAssertNoThrow(try engine.remove(key: .init(key: "ghost")))
    }

    func testWipeClearsAllItemsForService() throws {
        try engine.store(value: 1, key: .init(key: "a"))
        try engine.store(value: 2, key: .init(key: "b"))
        try engine.wipe()
        let a: Int? = try engine.retrieve(key: .init(key: "a"))
        let b: Int? = try engine.retrieve(key: .init(key: "b"))
        XCTAssertNil(a)
        XCTAssertNil(b)
    }

    // MARK: - Type mismatch

    func testRetrievingWrongTypeThrows() throws {
        let key = PersistentPropertyKey(key: "k")
        try engine.store(value: "a string", key: key)
        do {
            let _: Int? = try engine.retrieve(key: key)
            XCTFail("expected decode error")
        } catch let error as KeychainStorageEngine.StorageError {
            if case .decodeError = error {
                // expected
            } else {
                XCTFail("expected .decodeError, got \(error)")
            }
        }
    }

    // MARK: - PersistentProperty integration

    func testIntegratesWithPersistentProperty() async throws {
        let key = PersistentPropertyKey(key: "integrated")
        let p = await MainActor.run {
            PersistentProperty(
                storageEngine: engine,
                key: key,
                defaultValue: "empty"
            )
        }
        await MainActor.run { p.value = "keychain-backed" }
        await p.awaitPendingFlush()
        let got: String? = try engine.retrieve(key: key)
        XCTAssertEqual(got, "keychain-backed")
    }

    // MARK: - Preflight

    /// Attempt a trivial keychain operation. If the underlying
    /// `Security.framework` call reports a failure other than
    /// "item not found" (e.g. `errSecMissingEntitlement` in a sandboxed
    /// CI environment), skip all tests in this suite.
    private static func preflightKeychainOrSkip() throws {
        let probeService = "com.swiftasyncex.preflight.\(UUID().uuidString)"
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: probeService,
            kSecAttrAccount as String: "probe",
            kSecValueData as String: Data("x".utf8),
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: probeService,
        ]
        _ = SecItemDelete(deleteQuery as CFDictionary)

        if addStatus != errSecSuccess {
            throw XCTSkip("Keychain not accessible in this environment (OSStatus: \(addStatus))")
        }
    }
}
