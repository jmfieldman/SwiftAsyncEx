//
//  Task+Observe.swift
//  Copyright © 2026 Jason Fieldman.
//

import Foundation
import Observation

extension Task where Success == Void, Failure == Never {
    // MARK: - Closure expression, Equatable (auto-dedup)

    /// Spawn a MainActor task that fires `perform` with the current value of
    /// `expression`, and again each time it changes.
    ///
    /// The expression is evaluated under `withObservationTracking`, so any
    /// `@Observable` state it reads is tracked. `@Observable` properties of a
    /// concrete `Equatable` type filter same-value writes, but generic ones
    /// such as `MutableProperty<Int>` don't, and composed expressions (e.g.
    /// `"\(a):\(b)"`) can produce the same value from different writes.
    /// `removeDuplicates` filters all of those here.
    ///
    /// The observer always settles on the latest value, including when writes
    /// land while `perform` is running, but it isn't a log of every write: a
    /// burst of writes may arrive as just its final value.
    ///
    /// - Parameters:
    ///   - emitInitial: When `true` (default), `perform` runs once with the
    ///     initial value before the observation loop starts.
    ///   - removeDuplicates: When `true`, consecutive projected values equal
    ///     by `==` are suppressed. Omit it to get this behavior.
    ///   - bindTo: If non-nil, the returned task is bound to the owner's
    ///     associated `TaskBag` (or directly to a passed `TaskBag`) and
    ///     cancelled when that owner deallocates.
    ///   - expression: The value to observe. Every `@Observable` property read
    ///     inside registers tracking.
    ///   - perform: Called on MainActor for each qualifying value.
    /// - Returns: The spawned task, cancellable or bindable post-hoc.
    @MainActor
    @discardableResult
    public static func observe<T: Equatable>(
        emitInitial: Bool = true,
        removeDuplicates: Bool,
        bindTo: AnyObject? = nil,
        expression: @escaping @MainActor () -> T,
        perform: @escaping @MainActor (T) async -> Void
    ) -> Task<Void, Never> {
        let isDuplicate: ((T, T) -> Bool)? = removeDuplicates ? { $0 == $1 } : nil
        return observeImpl(
            expression: { expression() },
            emitInitial: emitInitial,
            isDuplicate: isDuplicate,
            bindTo: bindTo,
            perform: perform
        )
    }

    /// As above, with `removeDuplicates` on. This is a separate overload, not
    /// a default argument, because Swift prefers the overload with fewer
    /// defaulted arguments: a default here would send every call that omits
    /// it to the non-Equatable overload, which can't deduplicate.
    @MainActor
    @discardableResult
    public static func observe<T: Equatable>(
        emitInitial: Bool = true,
        bindTo: AnyObject? = nil,
        expression: @escaping @MainActor () -> T,
        perform: @escaping @MainActor (T) async -> Void
    ) -> Task<Void, Never> {
        observe(
            emitInitial: emitInitial,
            removeDuplicates: true,
            bindTo: bindTo,
            expression: expression,
            perform: perform
        )
    }

    // MARK: - Closure expression, non-Equatable

    /// Spawn a MainActor observer for a non-Equatable expression. Every
    /// tracked change fires `perform`; dedup is not possible without a
    /// comparator.
    @MainActor
    @discardableResult
    public static func observe<T>(
        emitInitial: Bool = true,
        bindTo: AnyObject? = nil,
        expression: @escaping @MainActor () -> T,
        perform: @escaping @MainActor (T) async -> Void
    ) -> Task<Void, Never> {
        observeImpl(
            expression: { expression() },
            emitInitial: emitInitial,
            isDuplicate: nil,
            bindTo: bindTo,
            perform: perform
        )
    }

    // MARK: - Closure expression, custom comparator

    /// Spawn a MainActor observer using a caller-supplied equality predicate.
    /// Useful when `T` isn't Equatable, or when dedup should consider only a
    /// subset of fields.
    @MainActor
    @discardableResult
    public static func observe<T>(
        emitInitial: Bool = true,
        removeDuplicates isDuplicate: @escaping (T, T) -> Bool,
        bindTo: AnyObject? = nil,
        expression: @escaping @MainActor () -> T,
        perform: @escaping @MainActor (T) async -> Void
    ) -> Task<Void, Never> {
        observeImpl(
            expression: { expression() },
            emitInitial: emitInitial,
            isDuplicate: isDuplicate,
            bindTo: bindTo,
            perform: perform
        )
    }

    // MARK: - KeyPath, Equatable

    /// Observe a keypath on an `@Observable` root. The root is held weakly
    /// so the observer doesn't retain it, but Observation tracks property
    /// writes rather than object lifecycle — if the root deallocates without
    /// a subsequent tracked write, the observer parks until cancelled (via
    /// `bindTo:`, `task.cancel()`, or its bound `TaskBag`).
    @MainActor
    @discardableResult
    public static func observe<Root: AnyObject & Observable, T: Equatable>(
        _ keyPath: KeyPath<Root, T>,
        on root: Root,
        emitInitial: Bool = true,
        removeDuplicates: Bool,
        bindTo: AnyObject? = nil,
        perform: @escaping @MainActor (T) async -> Void
    ) -> Task<Void, Never> {
        let isDuplicate: ((T, T) -> Bool)? = removeDuplicates ? { $0 == $1 } : nil
        return observeImpl(
            expression: { [weak root] in root.map { $0[keyPath: keyPath] } },
            emitInitial: emitInitial,
            isDuplicate: isDuplicate,
            bindTo: bindTo,
            perform: perform
        )
    }

    /// As above, with `removeDuplicates` on. See the closure-expression
    /// overload for why this isn't a default argument.
    @MainActor
    @discardableResult
    public static func observe<Root: AnyObject & Observable, T: Equatable>(
        _ keyPath: KeyPath<Root, T>,
        on root: Root,
        emitInitial: Bool = true,
        bindTo: AnyObject? = nil,
        perform: @escaping @MainActor (T) async -> Void
    ) -> Task<Void, Never> {
        observe(
            keyPath,
            on: root,
            emitInitial: emitInitial,
            removeDuplicates: true,
            bindTo: bindTo,
            perform: perform
        )
    }

    // MARK: - KeyPath, non-Equatable

    /// Observe a keypath on an `@Observable` root for a non-Equatable value.
    /// Every tracked change fires `perform`.
    @MainActor
    @discardableResult
    public static func observe<Root: AnyObject & Observable, T>(
        _ keyPath: KeyPath<Root, T>,
        on root: Root,
        emitInitial: Bool = true,
        bindTo: AnyObject? = nil,
        perform: @escaping @MainActor (T) async -> Void
    ) -> Task<Void, Never> {
        observeImpl(
            expression: { [weak root] in root.map { $0[keyPath: keyPath] } },
            emitInitial: emitInitial,
            isDuplicate: nil,
            bindTo: bindTo,
            perform: perform
        )
    }

    // MARK: - Internal pump

    /// Shared observation pump. `expression` returns `nil` to signal that the
    /// underlying subject is gone (e.g. a weak root was deallocated) and the
    /// loop should exit cleanly.
    @MainActor
    private static func observeImpl<T>(
        expression: @escaping @MainActor () -> T?,
        emitInitial: Bool,
        isDuplicate: ((T, T) -> Bool)?,
        bindTo: AnyObject?,
        perform: @escaping @MainActor (T) async -> Void
    ) -> Task<Void, Never> {
        let task = Task { @MainActor in
            var last: T?
            var isFirstValue = true

            while !Task<Never, Never>.isCancelled {
                // Arm before `perform`, so that a write made while `perform`
                // is suspended resumes the box and is picked up below.
                let box = ObservationContinuationBox()
                var subjectAlive = true
                withObservationTracking {
                    if expression() == nil { subjectAlive = false }
                } onChange: {
                    box.resume()
                }
                guard subjectAlive else { break }

                // Read after arming: a write made before the observation was
                // installed is seen here, and any later one resumes the box.
                guard let value = expression() else { break }

                let shouldPerform: Bool
                if isFirstValue {
                    shouldPerform = emitInitial
                    isFirstValue = false
                } else if let isDuplicate, let last, isDuplicate(last, value) {
                    shouldPerform = false
                } else {
                    shouldPerform = true
                }
                last = value

                if shouldPerform {
                    await perform(value)
                    if Task<Never, Never>.isCancelled { break }
                }

                await withTaskCancellationHandler {
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        box.setContinuation(cont)
                    }
                } onCancel: {
                    box.resume()
                }

                if Task<Never, Never>.isCancelled { break }
                // `withObservationTracking` fires on `willSet`; yield so the
                // setter's actual commit happens before we re-read the value.
                await Task<Never, Never>.yield()
            }
        }

        if let bindTo { return task.bind(to: bindTo) }
        return task
    }
}
