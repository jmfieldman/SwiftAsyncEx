//
//  KeychainStorageEngine.swift
//  Copyright © 2026 Jason Fieldman.
//

import Foundation
import Security

/// A `PersistentPropertyStorageEngine` backed by the system Keychain
/// (`kSecClassGenericPassword` items).
///
/// Items are identified by a fixed `service` string plus the key's
/// `sanitizedIndex` as the account. An optional `accessGroup` allows
/// sharing across apps (requires a `keychain-access-groups` entitlement
/// with a matching group); `synchronized` toggles iCloud Keychain sync.
///
/// Errors from `Security.framework` surface as
/// `StorageError.securityError(OSStatus)` so callers can inspect the
/// status code if needed.
public final class KeychainStorageEngine: PersistentPropertyStorageEngine, @unchecked Sendable {
    public enum StorageError: Error {
        /// The underlying `Security.framework` call returned a non-success
        /// status. The raw `OSStatus` is preserved for inspection.
        case securityError(OSStatus)
        /// JSON encoding of the value failed.
        case encodeError(Error)
        /// JSON decoding of the stored data failed.
        case decodeError(Error)
        /// A successful query returned something other than the expected
        /// `Data` payload.
        case unexpectedData
    }

    public let service: String
    public let accessGroup: String?
    public let synchronized: Bool

    /// Construct a Keychain-backed engine.
    ///
    /// - Parameters:
    ///   - service: A string that scopes this engine's items. Typically
    ///     something like `"\(bundleID).\(environment)"`.
    ///   - accessGroup: Optional keychain access group for cross-app
    ///     sharing. Must match an entry in the host app's
    ///     `keychain-access-groups` entitlement and be prefixed with the
    ///     team's 10-character `AppIdentifierPrefix`.
    ///   - synchronized: If `true`, items are synchronized via iCloud
    ///     Keychain. Requires appropriate entitlements on the host app.
    public init(service: String, accessGroup: String? = nil, synchronized: Bool = false) {
        self.service = service
        self.accessGroup = accessGroup
        self.synchronized = synchronized
    }

    public func store(value: some Codable & Sendable, key: PersistentPropertyKey) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(CodableBox(value: value))
        } catch {
            throw StorageError.encodeError(error)
        }

        var addQuery = baseQuery(key: key)
        addQuery[kSecValueData as String] = data

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let updateStatus = SecItemUpdate(
                baseQuery(key: key) as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            if updateStatus != errSecSuccess {
                throw StorageError.securityError(updateStatus)
            }
        default:
            throw StorageError.securityError(addStatus)
        }
    }

    public func retrieve<T: Codable & Sendable>(key: PersistentPropertyKey) throws -> T? {
        var query = baseQuery(key: key)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw StorageError.unexpectedData
            }
            do {
                return try JSONDecoder().decode(CodableBox<T>.self, from: data).value
            } catch {
                throw StorageError.decodeError(error)
            }
        case errSecItemNotFound:
            return nil
        default:
            throw StorageError.securityError(status)
        }
    }

    /// Remove a single item by key. No-op if no item exists; throws on any
    /// other non-success status from `SecItemDelete`.
    public func remove(key: PersistentPropertyKey) throws {
        let status = SecItemDelete(baseQuery(key: key) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw StorageError.securityError(status)
        }
    }

    /// Remove every item stored under this engine's `service` (and
    /// `accessGroup`, if any), regardless of sync state. Useful on logout
    /// and in tests.
    ///
    /// On macOS, `SecItemDelete` only removes a single matching item per
    /// call against the legacy file-based keychain, so the implementation
    /// loops until no more matches remain.
    public func wipe() throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            // Sweep both synchronized and non-synchronized items under
            // this service so a toggle of `synchronized` doesn't leave
            // stale items behind.
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        while true {
            let status = SecItemDelete(query as CFDictionary)
            switch status {
            case errSecSuccess:
                continue
            case errSecItemNotFound:
                return
            default:
                throw StorageError.securityError(status)
            }
        }
    }

    private func baseQuery(key: PersistentPropertyKey) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.sanitizedIndex,
            kSecAttrSynchronizable as String: synchronized,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private struct CodableBox<T: Codable>: Codable {
        let value: T
    }
}
