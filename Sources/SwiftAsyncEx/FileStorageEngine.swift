//
//  FileStorageEngine.swift
//  Copyright © 2026 Jason Fieldman.
//

import Foundation

/// A `PersistentPropertyStorageEngine` that persists each value as a single
/// JSON-encoded file on disk. Writes are atomic; reads return `nil` for
/// missing files, throw on decode failure.
///
/// Files live under a scoped `rootDirectoryUrl`. Use the convenience
/// initializer to place the directory under Documents / Caches / Temporary
/// / an App Group container; or pass an explicit URL.
public final class FileStorageEngine: PersistentPropertyStorageEngine, @unchecked Sendable {
    /// Well-known base directories for the `rootDirectory:` convenience init.
    public enum RootDirectory: Sendable {
        case documents
        case caches
        case temporary
        case appGroup(String)
    }

    public enum StorageError: Error {
        /// The selected root directory could not be located (typically
        /// `.appGroup` with an unconfigured entitlement).
        case noRootDirectory
        /// `FileManager` failed to create or reach the root directory.
        case unableToCreateDirectory(Error)
        /// Encoding `Codable` → JSON failed.
        case encodeError(Error)
        /// Decoding JSON → `Codable` failed.
        case decodeError(Error)
        /// Writing to disk failed.
        case writeError(Error)
        /// Reading from disk failed.
        case readError(Error)
    }

    public let rootDirectoryUrl: URL

    /// Construct an engine whose values live under `rootDirectoryUrl`. The
    /// directory is created (with intermediates) if it doesn't exist.
    public init(rootDirectoryUrl: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: rootDirectoryUrl,
                withIntermediateDirectories: true
            )
        } catch {
            throw StorageError.unableToCreateDirectory(error)
        }
        self.rootDirectoryUrl = rootDirectoryUrl
    }

    /// Convenience initializer that places the root directory under a
    /// well-known location. `subpath`, when provided, is appended to scope
    /// this engine's files to a subfolder (recommended — avoids mingling
    /// with unrelated files at the root).
    public convenience init(rootDirectory: RootDirectory, subpath: String? = nil) throws {
        let base: URL? =
            switch rootDirectory {
            case .documents:
                FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            case .caches:
                FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            case .temporary:
                URL(fileURLWithPath: NSTemporaryDirectory())
            case let .appGroup(identifier):
                FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
            }
        guard let base else {
            throw StorageError.noRootDirectory
        }
        let scoped = subpath.map { base.appendingPathComponent($0) } ?? base
        try self.init(rootDirectoryUrl: scoped)
    }

    public func store(value: some Codable & Sendable, key: PersistentPropertyKey) throws {
        let fileURL = rootDirectoryUrl.appendingPathComponent(key.sanitizedIndex)
        let data: Data
        do {
            data = try JSONEncoder().encode(CodableBox(value: value))
        } catch {
            throw StorageError.encodeError(error)
        }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw StorageError.writeError(error)
        }
    }

    public func retrieve<T: Codable & Sendable>(key: PersistentPropertyKey) throws -> T? {
        let fileURL = rootDirectoryUrl.appendingPathComponent(key.sanitizedIndex)
        guard FileManager.default.isReadableFile(atPath: fileURL.path) else {
            return nil
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw StorageError.readError(error)
        }
        do {
            return try JSONDecoder().decode(CodableBox<T>.self, from: data).value
        } catch {
            throw StorageError.decodeError(error)
        }
    }

    /// Remove the file backing `key`, if it exists.
    public func remove(key: PersistentPropertyKey) throws {
        let fileURL = rootDirectoryUrl.appendingPathComponent(key.sanitizedIndex)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    /// Remove every file under the root directory, recreating the directory
    /// empty. Safe because the engine's root is scoped to this engine's use.
    public func wipeDirectory() throws {
        try FileManager.default.removeItem(at: rootDirectoryUrl)
        try FileManager.default.createDirectory(
            at: rootDirectoryUrl,
            withIntermediateDirectories: true
        )
    }

    private struct CodableBox<T: Codable>: Codable {
        let value: T
    }
}
