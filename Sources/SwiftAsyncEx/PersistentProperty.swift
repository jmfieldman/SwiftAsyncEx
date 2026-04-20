//
//  PersistentProperty.swift
//  Copyright © 2026 Jason Fieldman.
//

import Foundation
import Observation

// MARK: - Storage engine protocol

/// A pluggable backing store for `PersistentProperty`. Implementations are
/// responsible for turning a `(key, value)` pair into persisted bytes and
/// turning those bytes back into a typed value on retrieval.
///
/// Implementations are `Sendable` and are expected to be safe to call from
/// any isolation context (they run inside a detached task, off the main
/// thread, when invoked by `PersistentProperty`).
public protocol PersistentPropertyStorageEngine: Sendable {
    /// Persist `value` under `key`. May throw on encode / I/O failure.
    func store(value: some Codable & Sendable, key: PersistentPropertyKey) throws

    /// Retrieve the value previously stored under `key`, or `nil` if no
    /// value has been persisted. May throw on decode / I/O failure.
    func retrieve<T: Codable & Sendable>(key: PersistentPropertyKey) throws -> T?
}

// MARK: - Key

/// A structured key for `PersistentProperty`. The `key` + optional `subKey`
/// make up the logical identity; `sanitizedIndex` is a derived
/// filesystem / keychain-safe representation that concrete engines can use
/// verbatim as filenames or account identifiers.
public struct PersistentPropertyKey: Hashable, Sendable {
    public let key: String
    public let subKey: String?
    public let sanitizedIndex: String

    private static let illegalCharacters: CharacterSet =
        CharacterSet(charactersIn: "/\\?%*:|\"<>,")
        .union(.whitespacesAndNewlines)
        .union(.illegalCharacters)
        .union(.controlCharacters)

    public init(key: CustomStringConvertible, subKey: CustomStringConvertible? = nil) {
        let rawKey = key.description
        let rawSubKey = subKey?.description
        self.key = rawKey
        self.subKey = rawSubKey
        let sanitizedKey = Self.sanitize(rawKey)
        if let rawSubKey {
            self.sanitizedIndex = sanitizedKey + "," + Self.sanitize(rawSubKey)
        } else {
            self.sanitizedIndex = sanitizedKey
        }
    }

    private static func sanitize(_ s: String) -> String {
        s.unicodeScalars
            .map { illegalCharacters.contains($0) ? "_" : String($0) }
            .joined()
    }
}

// MARK: - PersistentProperty

/// An `@Observable` reference to a single `Codable` value, backed by a
/// pluggable `PersistentPropertyStorageEngine`. Reads and writes are
/// synchronous; writes are flushed to the engine asynchronously on a
/// detached task so the main thread is never blocked by storage I/O.
///
/// Storage errors surface through the observable `error` property rather
/// than throwing from the setter, so UI can bind to failure state.
///
/// Flushes are serialized — consecutive writes store to the engine in
/// order, so the on-disk value never lags behind or reorders.
@Observable
@MainActor
public final class PersistentProperty<Value: Codable & Sendable> {
    /// The current value. Reading registers observation tracking; writing
    /// updates the in-memory value synchronously and schedules a flush to
    /// the underlying engine.
    public var value: Value {
        didSet { scheduleFlush(value) }
    }

    /// The most recent storage error, or `nil` if no error has occurred.
    /// Set on failed retrieve during init, and on failed store after any
    /// write. Never cleared automatically.
    public private(set) var error: Error?

    @ObservationIgnored private let engine: any PersistentPropertyStorageEngine
    @ObservationIgnored private let key: PersistentPropertyKey
    @ObservationIgnored private var lastFlushTask: Task<Void, Never>?

    /// Construct a `PersistentProperty` backed by the given storage engine.
    /// Attempts a synchronous retrieve during init; if retrieve throws, the
    /// thrown error is recorded on `error` and `value` falls back to
    /// `defaultValue`.
    public init(
        storageEngine: any PersistentPropertyStorageEngine,
        key: PersistentPropertyKey,
        defaultValue: Value
    ) {
        self.engine = storageEngine
        self.key = key
        var initialValue = defaultValue
        var initialError: Error?
        do {
            if let retrieved: Value = try storageEngine.retrieve(key: key) {
                initialValue = retrieved
            }
        } catch {
            initialError = error
        }
        self.value = initialValue
        self.error = initialError
    }

    /// Convenience initializer accepting a plain string-like key.
    public convenience init(
        storageEngine: any PersistentPropertyStorageEngine,
        key: CustomStringConvertible,
        defaultValue: Value
    ) {
        self.init(
            storageEngine: storageEngine,
            key: PersistentPropertyKey(key: key),
            defaultValue: defaultValue
        )
    }

    /// Atomic in-place mutation. The closure receives the current value
    /// by `inout`; the final value is written back through the setter so
    /// observation fires and a flush is scheduled.
    public func modify(_ block: (inout Value) -> Void) {
        var copy = value
        block(&copy)
        value = copy
    }

    /// Wait for any pending flush (and everything chained ahead of it) to
    /// complete. Useful before tearing down an owner when you want to be
    /// sure the last write has actually landed on disk, and in tests.
    public func awaitPendingFlush() async {
        await lastFlushTask?.value
    }

    /// Set the value from any isolation context. Hops to MainActor internally
    /// so call sites in background tasks don't need `await MainActor.run { ... }`
    /// ceremony. Sequential `await property.set(_:)` calls from a single task
    /// land in call order.
    public nonisolated func set(_ newValue: Value) async {
        await MainActor.run { self.value = newValue }
    }

    /// Read the value from any isolation context. Hops to MainActor internally.
    public nonisolated func read() async -> Value {
        await MainActor.run { self.value }
    }

    // MARK: - Flush machinery

    /// Schedule a flush of `newValue` to the engine. Flushes are chained via
    /// `await previous?.value` so stores hit the engine in caller order;
    /// the task is detached so engine I/O runs off the main thread.
    private func scheduleFlush(_ newValue: Value) {
        let engine = self.engine
        let key = self.key
        let previous = lastFlushTask
        lastFlushTask = Task.detached { [weak self] in
            await previous?.value
            do {
                try engine.store(value: newValue, key: key)
            } catch {
                await self?.setError(error)
            }
        }
    }

    private func setError(_ error: Error) {
        self.error = error
    }
}
