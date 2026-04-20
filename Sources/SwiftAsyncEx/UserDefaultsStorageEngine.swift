//
//  UserDefaultsStorageEngine.swift
//  Copyright © 2026 Jason Fieldman.
//

import Foundation

/// A `PersistentPropertyStorageEngine` backed by a `UserDefaults` instance.
///
/// Values are JSON-encoded and stored as `Data` under the key's
/// `sanitizedIndex`. Reads / writes forward directly to `UserDefaults`,
/// which is thread-safe.
public final class UserDefaultsStorageEngine: PersistentPropertyStorageEngine, @unchecked Sendable {
    private let defaults: UserDefaults

    /// Construct an engine backed by the given `UserDefaults`. Defaults to
    /// `UserDefaults.standard`.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func store(value: some Codable & Sendable, key: PersistentPropertyKey) throws {
        let data = try JSONEncoder().encode(CodableBox(value: value))
        defaults.set(data, forKey: key.sanitizedIndex)
    }

    public func retrieve<T: Codable & Sendable>(key: PersistentPropertyKey) throws -> T? {
        guard let data = defaults.data(forKey: key.sanitizedIndex) else { return nil }
        return try JSONDecoder().decode(CodableBox<T>.self, from: data).value
    }

    /// Remove a stored value. No-op if the key isn't present.
    public func remove(key: PersistentPropertyKey) {
        defaults.removeObject(forKey: key.sanitizedIndex)
    }

    private struct CodableBox<T: Codable>: Codable {
        let value: T
    }
}
