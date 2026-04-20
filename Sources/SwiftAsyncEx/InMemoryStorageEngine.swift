//
//  InMemoryStorageEngine.swift
//  Copyright © 2026 Jason Fieldman.
//

import Foundation

/// A `PersistentPropertyStorageEngine` that keeps values in memory only.
/// Useful as a test double and for any use case where "persistence within a
/// single process" is the right scope.
///
/// Values are JSON-encoded on store and decoded on retrieve, matching the
/// on-disk engines' round-trip semantics — so behavior (including Codable
/// failures) mirrors what production engines would see.
public final class InMemoryStorageEngine: PersistentPropertyStorageEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    public init() {}

    public func store(value: some Codable & Sendable, key: PersistentPropertyKey) throws {
        let data = try JSONEncoder().encode(CodableBox(value: value))
        lock.withLock {
            storage[key.sanitizedIndex] = data
        }
    }

    public func retrieve<T: Codable & Sendable>(key: PersistentPropertyKey) throws -> T? {
        let data: Data? = lock.withLock { storage[key.sanitizedIndex] }
        guard let data else { return nil }
        return try JSONDecoder().decode(CodableBox<T>.self, from: data).value
    }

    /// Remove every stored value. Intended primarily for tests.
    public func wipe() {
        lock.withLock { storage.removeAll() }
    }

    /// Remove a single value by key. Returns `true` if a value was present
    /// and removed.
    @discardableResult
    public func remove(key: PersistentPropertyKey) -> Bool {
        lock.withLock {
            storage.removeValue(forKey: key.sanitizedIndex) != nil
        }
    }

    /// Wraps the encoded value in a container so JSON primitives (e.g. `Int`,
    /// `String`) round-trip safely regardless of any future changes to
    /// JSONEncoder/Decoder top-level handling.
    private struct CodableBox<T: Codable>: Codable {
        let value: T
    }
}
