//
//  MutableProperty.swift
//  Copyright © 2026 Jason Fieldman.
//

import Foundation
import Observation

/// A single-value `@Observable` box. Reads and writes are synchronous; writes
/// fire Observation tracking so SwiftUI / `withObservationTracking` /
/// `Task.onChange` see the change.
///
/// Use this when you need to pass a mutable observable value around between
/// objects as a standalone reference — the analog of declaring a
/// `@Observable` class with a single `var` field every time you need one.
///
/// For read-only vending to consumers, wrap a `MutableProperty` in a
/// `Property(mirroring:)` so the consumer interface can be the protocol
/// `any PropertyProtocol<Value>` without coupling to your concrete type.
@Observable
@MainActor
public final class MutableProperty<Value: Sendable>: MutablePropertyProtocol {
    /// The current value. Reading registers Observation tracking; writing
    /// fires observers.
    public var value: Value

    /// Construct a `MutableProperty` with an initial value.
    public init(_ value: Value) {
        self.value = value
    }

    /// Atomic in-place mutation. The closure receives the current value by
    /// `inout`; the final value is written back through the setter so
    /// Observation fires once.
    public func modify(_ block: (inout Value) -> Void) {
        var copy = value
        block(&copy)
        value = copy
    }
}
