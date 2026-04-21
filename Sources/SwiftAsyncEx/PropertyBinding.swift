//
//  PropertyBinding.swift
//  Copyright © 2026 Jason Fieldman.
//

import Foundation

// MARK: - `<~` operator

precedencegroup PropertyBindingPrecedence {
    associativity: right
    higherThan: AssignmentPrecedence
}

/// Binding operator: pump values from a source into a writable property.
infix operator <~ : PropertyBindingPrecedence

// MARK: - MutableProperty ← AsyncSequence

/// Bind `dest` to `source`: every element produced by `source` is assigned
/// to `dest.value`. The pump runs on the MainActor.
///
/// The returned task is auto-bound to `dest`'s lifetime via `Task.bound(to:)`,
/// so the binding stops when `dest` is deallocated. Callers may also capture
/// the task and call `.cancel()` explicitly to tear the binding down early.
///
/// If `source` terminates (finishes or throws), the pump simply stops; the
/// last-written value remains on `dest`. Thrown errors are swallowed.
@MainActor
@discardableResult
public func <~ <P: MutablePropertyProtocol, S: AsyncSequence & Sendable>(
    dest: P,
    source: S
) -> Task<Void, Never> where S.Element == P.Value {
    Task.bound(to: dest) { @MainActor [weak dest] in
        do {
            for try await element in source {
                dest?.value = element
            }
        } catch {
            // Source terminated with error; binding stops.
        }
    }
}

// MARK: - MutableProperty ← PropertyProtocol

/// Bind `dest` to `source`: `dest.value` follows `source.value`, including
/// the current value at binding time. See the `AsyncSequence` overload for
/// lifetime and cancellation semantics.
@MainActor
@discardableResult
public func <~ <P: MutablePropertyProtocol, Q: PropertyProtocol>(
    dest: P,
    source: Q
) -> Task<Void, Never> where P.Value == Q.Value {
    dest <~ source.asAsyncSequence()
}
