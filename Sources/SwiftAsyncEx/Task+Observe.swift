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
    /// `@Observable` state it reads is tracked. Swift Observation only signals
    /// a tracked change when the underlying value actually differs from its
    /// previous value — same-value writes are filtered out by the runtime
    /// before they reach this observer. On top of that, `removeDuplicates`
    /// applies a second equality check when composed expressions (e.g.
    /// `"\(a):\(b)"`) might produce the same projected value across distinct
    /// underlying writes.
    ///
    /// - Parameters:
    ///   - expression: The value to observe. Every `@Observable` property read
    ///     inside registers tracking.
    ///   - emitInitial: When `true` (default), `perform` runs once with the
    ///     initial value before the observation loop starts.
    ///   - removeDuplicates: When `true` (default), consecutive projected
    ///     values equal by `==` are suppressed.
    ///   - bindTo: If non-nil, the returned task is bound to the owner's
    ///     associated `TaskBag` (or directly to a passed `TaskBag`) and
    ///     cancelled when that owner deallocates.
    ///   - perform: Called on MainActor for each qualifying value.
    /// - Returns: The spawned task, cancellable or bindable post-hoc.
    @MainActor
    @discardableResult
    public static func observe<T: Equatable>(
        of expression: @escaping @MainActor () -> T,
        emitInitial: Bool = true,
        removeDuplicates: Bool = true,
        bindTo: AnyObject? = nil,
        perform: @escaping @MainActor (T) async -> Void
    ) -> Task<Void, Never> {
        let isDuplicate: ((T, T) -> Bool)? = removeDuplicates ? { $0 == $1 } : nil
        return observeImpl(
            track: { expression() },
            emitInitial: emitInitial,
            isDuplicate: isDuplicate,
            bindTo: bindTo,
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
        of expression: @escaping @MainActor () -> T,
        emitInitial: Bool = true,
        bindTo: AnyObject? = nil,
        perform: @escaping @MainActor (T) async -> Void
    ) -> Task<Void, Never> {
        observeImpl(
            track: { expression() },
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
        of expression: @escaping @MainActor () -> T,
        emitInitial: Bool = true,
        removeDuplicates isDuplicate: @escaping (T, T) -> Bool,
        bindTo: AnyObject? = nil,
        perform: @escaping @MainActor (T) async -> Void
    ) -> Task<Void, Never> {
        observeImpl(
            track: { expression() },
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
        removeDuplicates: Bool = true,
        bindTo: AnyObject? = nil,
        perform: @escaping @MainActor (T) async -> Void
    ) -> Task<Void, Never> {
        let isDuplicate: ((T, T) -> Bool)? = removeDuplicates ? { $0 == $1 } : nil
        return observeImpl(
            track: { [weak root] in root.map { $0[keyPath: keyPath] } },
            emitInitial: emitInitial,
            isDuplicate: isDuplicate,
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
            track: { [weak root] in root.map { $0[keyPath: keyPath] } },
            emitInitial: emitInitial,
            isDuplicate: nil,
            bindTo: bindTo,
            perform: perform
        )
    }

    // MARK: - Internal pump

    /// Shared observation pump. `track` returns `nil` to signal that the
    /// underlying subject is gone (e.g. a weak root was deallocated) and the
    /// loop should exit cleanly.
    @MainActor
    private static func observeImpl<T>(
        track: @escaping @MainActor () -> T?,
        emitInitial: Bool,
        isDuplicate: ((T, T) -> Bool)?,
        bindTo: AnyObject?,
        perform: @escaping @MainActor (T) async -> Void
    ) -> Task<Void, Never> {
        let task = Task { @MainActor in
            guard var last = track() else { return }
            if emitInitial { await perform(last) }
            if Task<Never, Never>.isCancelled { return }

            while !Task<Never, Never>.isCancelled {
                let box = ObservationContinuationBox()
                var subjectAlive = true
                withObservationTracking {
                    if track() == nil { subjectAlive = false }
                } onChange: {
                    box.resume()
                }
                guard subjectAlive else { break }

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
                guard let new = track() else { break }
                if let isDuplicate, isDuplicate(last, new) { continue }
                last = new
                await perform(new)
            }
        }

        if let bindTo { return task.bind(to: bindTo) }
        return task
    }
}
