//
//  PersistentPropertyKeyTests.swift
//  Copyright © 2026 Jason Fieldman.
//

import XCTest

@testable import SwiftAsyncEx

final class PersistentPropertyKeyTests: XCTestCase {
    // MARK: - Identity

    func testEqualKeys() {
        let a = PersistentPropertyKey(key: "foo")
        let b = PersistentPropertyKey(key: "foo")
        XCTAssertEqual(a, b)
    }

    func testDifferentKeysNotEqual() {
        let a = PersistentPropertyKey(key: "foo")
        let b = PersistentPropertyKey(key: "bar")
        XCTAssertNotEqual(a, b)
    }

    func testSubKeyDistinguishesKeys() {
        let a = PersistentPropertyKey(key: "foo")
        let b = PersistentPropertyKey(key: "foo", subKey: "bar")
        XCTAssertNotEqual(a, b)
    }

    func testEqualSubKeys() {
        let a = PersistentPropertyKey(key: "foo", subKey: "bar")
        let b = PersistentPropertyKey(key: "foo", subKey: "bar")
        XCTAssertEqual(a, b)
    }

    // MARK: - Sanitization

    func testSanitizeReplacesFilesystemIllegalChars() {
        let k = PersistentPropertyKey(key: "foo/bar?baz:qux")
        XCTAssertEqual(k.sanitizedIndex, "foo_bar_baz_qux")
    }

    func testSanitizeReplacesWhitespace() {
        let k = PersistentPropertyKey(key: "hello world\ttab\nline")
        XCTAssertEqual(k.sanitizedIndex, "hello_world_tab_line")
    }

    func testSanitizeReplacesComma() {
        // Commas are reserved as the separator between key and subKey, so they
        // are sanitized out of each component individually.
        let k = PersistentPropertyKey(key: "foo,bar")
        XCTAssertEqual(k.sanitizedIndex, "foo_bar")
    }

    func testSanitizedIndexWithSubKeyUsesComma() {
        let k = PersistentPropertyKey(key: "foo", subKey: "bar")
        XCTAssertEqual(k.sanitizedIndex, "foo,bar")
    }

    func testSanitizedIndexStable() {
        let a = PersistentPropertyKey(key: "foo/bar", subKey: "baz qux")
        let b = PersistentPropertyKey(key: "foo/bar", subKey: "baz qux")
        XCTAssertEqual(a.sanitizedIndex, b.sanitizedIndex)
    }

    func testSanitizationDoesNotCollideAcrossKeyAndSubKey() {
        // Because "," is sanitized out of each component, "foo,bar" with no
        // subKey produces "foo_bar"; "foo" with subKey "bar" produces
        // "foo,bar". They must not collide.
        let a = PersistentPropertyKey(key: "foo,bar")
        let b = PersistentPropertyKey(key: "foo", subKey: "bar")
        XCTAssertNotEqual(a.sanitizedIndex, b.sanitizedIndex)
    }

    // MARK: - CustomStringConvertible input

    func testCustomStringConvertibleKey() {
        let k = PersistentPropertyKey(key: 42)
        XCTAssertEqual(k.key, "42")
        XCTAssertEqual(k.sanitizedIndex, "42")
    }
}
