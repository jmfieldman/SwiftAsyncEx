//
//  LoadableResultTests.swift
//  Copyright © 2026 Jason Fieldman.
//

import XCTest

@testable import SwiftAsyncEx

final class LoadableResultTests: XCTestCase {
    private enum TestError: Error, Equatable, Hashable, Sendable {
        case something
        case other
    }

    private enum MappedError: Error, Equatable {
        case wrapped
    }

    // MARK: - Case predicates

    func testIsIdle() {
        XCTAssertTrue(LoadableResult<Int, TestError>.idle.isIdle)
        XCTAssertFalse(LoadableResult<Int, TestError>.loading.isIdle)
        XCTAssertFalse(LoadableResult<Int, TestError>.loaded(1).isIdle)
        XCTAssertFalse(LoadableResult<Int, TestError>.failed(.something).isIdle)
    }

    func testIsLoading() {
        XCTAssertFalse(LoadableResult<Int, TestError>.idle.isLoading)
        XCTAssertTrue(LoadableResult<Int, TestError>.loading.isLoading)
        XCTAssertFalse(LoadableResult<Int, TestError>.loaded(1).isLoading)
        XCTAssertFalse(LoadableResult<Int, TestError>.failed(.something).isLoading)
    }

    func testIsLoaded() {
        XCTAssertFalse(LoadableResult<Int, TestError>.idle.isLoaded)
        XCTAssertFalse(LoadableResult<Int, TestError>.loading.isLoaded)
        XCTAssertTrue(LoadableResult<Int, TestError>.loaded(1).isLoaded)
        XCTAssertFalse(LoadableResult<Int, TestError>.failed(.something).isLoaded)
    }

    func testIsFailed() {
        XCTAssertFalse(LoadableResult<Int, TestError>.idle.isFailed)
        XCTAssertFalse(LoadableResult<Int, TestError>.loading.isFailed)
        XCTAssertFalse(LoadableResult<Int, TestError>.loaded(1).isFailed)
        XCTAssertTrue(LoadableResult<Int, TestError>.failed(.something).isFailed)
    }

    // MARK: - Value / Error extraction

    func testValueIsNonNilOnlyForLoaded() {
        XCTAssertNil(LoadableResult<Int, TestError>.idle.value)
        XCTAssertNil(LoadableResult<Int, TestError>.loading.value)
        XCTAssertEqual(LoadableResult<Int, TestError>.loaded(42).value, 42)
        XCTAssertNil(LoadableResult<Int, TestError>.failed(.something).value)
    }

    func testErrorIsNonNilOnlyForFailed() {
        XCTAssertNil(LoadableResult<Int, TestError>.idle.error)
        XCTAssertNil(LoadableResult<Int, TestError>.loading.error)
        XCTAssertNil(LoadableResult<Int, TestError>.loaded(42).error)
        XCTAssertEqual(LoadableResult<Int, TestError>.failed(.something).error, .something)
    }

    // MARK: - map

    func testMapTransformsLoadedOnly() {
        let idle: LoadableResult<Int, TestError> = .idle
        let loading: LoadableResult<Int, TestError> = .loading
        let loaded: LoadableResult<Int, TestError> = .loaded(3)
        let failed: LoadableResult<Int, TestError> = .failed(.something)

        XCTAssertEqual(idle.map { $0 * 2 }, .idle)
        XCTAssertEqual(loading.map { $0 * 2 }, .loading)
        XCTAssertEqual(loaded.map { $0 * 2 }, .loaded(6))
        XCTAssertEqual(failed.map { $0 * 2 }, .failed(.something))
    }

    func testMapChangesValueType() {
        let loaded: LoadableResult<Int, TestError> = .loaded(7)
        let stringified: LoadableResult<String, TestError> = loaded.map(String.init)
        XCTAssertEqual(stringified, .loaded("7"))
    }

    // MARK: - mapError

    func testMapErrorTransformsFailedOnly() {
        let idle: LoadableResult<Int, TestError> = .idle
        let loading: LoadableResult<Int, TestError> = .loading
        let loaded: LoadableResult<Int, TestError> = .loaded(3)
        let failed: LoadableResult<Int, TestError> = .failed(.something)

        XCTAssertEqual(idle.mapError { _ in MappedError.wrapped }, .idle)
        XCTAssertEqual(loading.mapError { _ in MappedError.wrapped }, .loading)
        XCTAssertEqual(loaded.mapError { _ in MappedError.wrapped }, .loaded(3))
        XCTAssertEqual(failed.mapError { _ in MappedError.wrapped }, .failed(.wrapped))
    }

    // MARK: - Equatable

    func testEquatableDistinguishesCasesAndPayloads() {
        XCTAssertEqual(LoadableResult<Int, TestError>.idle, .idle)
        XCTAssertEqual(LoadableResult<Int, TestError>.loading, .loading)
        XCTAssertEqual(LoadableResult<Int, TestError>.loaded(1), .loaded(1))
        XCTAssertNotEqual(LoadableResult<Int, TestError>.loaded(1), .loaded(2))
        XCTAssertEqual(LoadableResult<Int, TestError>.failed(.something), .failed(.something))
        XCTAssertNotEqual(LoadableResult<Int, TestError>.failed(.something), .failed(.other))
        XCTAssertNotEqual(LoadableResult<Int, TestError>.idle, .loading)
        XCTAssertNotEqual(LoadableResult<Int, TestError>.loading, .loaded(1))
    }

    // MARK: - Hashable

    func testHashableCollapsesEqualValues() {
        var set: Set<LoadableResult<Int, TestError>> = []
        set.insert(.idle)
        set.insert(.idle)
        set.insert(.loading)
        set.insert(.loaded(1))
        set.insert(.loaded(1))
        set.insert(.loaded(2))
        set.insert(.failed(.something))
        XCTAssertEqual(set.count, 5)
    }

    // MARK: - Sendable

    func testSendableCrossesTaskBoundary() async {
        let value: LoadableResult<Int, TestError> = .loaded(5)
        let result = await Task { value }.value
        XCTAssertEqual(result, .loaded(5))
    }
}
