//
//  Task+OnChange.swift
//  Copyright © 2026 Jason Fieldman.
//

import Foundation
import Observation

extension Task where Success == Void, Failure == Never {
    /// Spawn a MainActor task that fires `perform` each time the value
    /// returned by `expression` changes.
    ///
    /// The expression is evaluated under `withObservationTracking`, so any
    /// `@Observable` state it reads is tracked. `perform` is invoked only when
    /// the new value differs from the previous one (via `Equatable`). The
    /// initial value is *not* fired — callers that want a first-run side
    /// effect should invoke it explicitly.
    ///
    /// The returned task is cancellable and can be bound to a `TaskBag` or
    /// owner via `.bind(to:)`. Cancellation unblocks the task even if no
    /// further observation changes arrive.
    @MainActor
    @discardableResult
    public static func onChange<T: Equatable>(
        of expression: @escaping @MainActor () -> T,
        perform: @escaping @MainActor (T) async -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor in
            var last = expression()
            while !Task<Never, Never>.isCancelled {
                let box = OnChangeContinuationBox()
                await withTaskCancellationHandler {
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        box.setContinuation(cont)
                        withObservationTracking {
                            _ = expression()
                        } onChange: {
                            box.resume()
                        }
                    }
                } onCancel: {
                    box.resume()
                }
                if Task<Never, Never>.isCancelled { break }
                // `withObservationTracking` fires on `willSet`; yield so the
                // setter's actual commit happens before we re-read the value.
                await Task<Never, Never>.yield()
                let new = expression()
                guard new != last else { continue }
                last = new
                await perform(new)
            }
        }
    }
}

/// Coordinates between `withObservationTracking`'s one-shot `onChange`
/// callback and `withTaskCancellationHandler`'s `onCancel` handler so that
/// exactly one of them resumes the continuation. Handles the case where
/// cancellation arrives before the continuation has been installed.
private final class OnChangeContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var resumeRequested = false

    func setContinuation(_ c: CheckedContinuation<Void, Never>) {
        let resumeNow: Bool = lock.withLock {
            if resumeRequested { return true }
            continuation = c
            return false
        }
        if resumeNow { c.resume() }
    }

    func resume() {
        let c: CheckedContinuation<Void, Never>? = lock.withLock {
            guard !resumeRequested else { return nil }
            resumeRequested = true
            let taken = continuation
            continuation = nil
            return taken
        }
        c?.resume()
    }
}
