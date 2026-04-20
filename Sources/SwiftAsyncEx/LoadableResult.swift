//
//  LoadableResult.swift
//  Copyright © 2026 Jason Fieldman.
//

import Foundation

/// A four-state enum for async values that can be idle (not yet started),
/// loading, loaded with a value, or failed with an error.
///
/// The distinction between `.idle` and `.loading` matters when a UI needs
/// to show "haven't started yet" vs "currently fetching" — two states that
/// collapse into a single `Bool` lose that information.
public enum LoadableResult<T, E: Error> {
    case idle
    case loading
    case loaded(T)
    case failed(E)
}

public extension LoadableResult {
    var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var isLoaded: Bool {
        if case .loaded = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    /// The loaded value, or `nil` if not in the `.loaded` case.
    var value: T? {
        if case let .loaded(value) = self { return value }
        return nil
    }

    /// The failure error, or `nil` if not in the `.failed` case.
    var error: E? {
        if case let .failed(error) = self { return error }
        return nil
    }

    /// Transforms the payload of a `.loaded` result. All other cases are preserved.
    func map<U>(_ transform: (T) -> U) -> LoadableResult<U, E> {
        switch self {
        case .idle: .idle
        case .loading: .loading
        case let .loaded(value): .loaded(transform(value))
        case let .failed(error): .failed(error)
        }
    }

    /// Transforms the payload of a `.failed` result. All other cases are preserved.
    func mapError<F: Error>(_ transform: (E) -> F) -> LoadableResult<T, F> {
        switch self {
        case .idle: .idle
        case .loading: .loading
        case let .loaded(value): .loaded(value)
        case let .failed(error): .failed(transform(error))
        }
    }
}

extension LoadableResult: Sendable where T: Sendable, E: Sendable {}
extension LoadableResult: Equatable where T: Equatable, E: Equatable {}
extension LoadableResult: Hashable where T: Hashable, E: Hashable {}
