//
//  TaskBag.swift
//  Copyright © 2026 Jason Fieldman.
//

import Foundation
import ObjectiveC

/// A bag that holds references to in-flight `Task`s and cancels them when it
/// is deallocated. Fills the role that `Set<AnyCancellable>` plays for Combine.
///
/// `Task` does not auto-cancel on reference drop the way `AnyCancellable` does,
/// so this helper cancels bound tasks actively on `deinit` (and on
/// `cancelAll()`). Bound tasks are pruned from the bag on completion, so
/// long-lived bags do not accumulate dead entries.
///
/// Thread-safe: tasks may be inserted and removed from any isolation context.
public final class TaskBag: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [UUID: @Sendable () -> Void] = [:]

    public init() {}

    deinit {
        cancelAll()
    }

    public var count: Int {
        lock.withLock { entries.count }
    }

    public var isEmpty: Bool {
        lock.withLock { entries.isEmpty }
    }

    /// Bind a pre-existing task to this bag. The task is cancelled if the bag
    /// is deallocated or `cancelAll()` is called before the task completes,
    /// and the task is pruned from the bag once it finishes.
    public func insert<Success: Sendable, Failure: Error>(_ task: Task<Success, Failure>) {
        let id = UUID()
        lock.withLock {
            entries[id] = { task.cancel() }
        }
        Task { [weak self] in
            _ = await task.result
            self?.remove(id)
        }
    }

    /// Cancel every currently-bound task and clear the bag.
    public func cancelAll() {
        let cancels: [@Sendable () -> Void] = lock.withLock {
            let values = Array(entries.values)
            entries.removeAll()
            return values
        }
        for cancel in cancels {
            cancel()
        }
    }

    // MARK: - Internal primitives used by `Task.bound(to:)`

    /// Insert a cancel closure directly. Used by `Task.bound(to:)`, where
    /// pruning is handled inside the wrapped task operation instead of via an
    /// observer (avoids a `Success: Sendable` requirement on the operation
    /// result, and avoids a double allocation for the observer task).
    internal func insertRaw(id: UUID, cancel: @escaping @Sendable () -> Void) {
        lock.withLock {
            entries[id] = cancel
        }
    }

    internal func remove(_ id: UUID) {
        lock.withLock {
            _ = entries.removeValue(forKey: id)
        }
    }
}

// MARK: - Associated-object binding to arbitrary AnyObject owners

/// Storage key for the per-owner TaskBag association. The address of this
/// variable is used as the key to `objc_setAssociatedObject`; it is intentionally
/// file-private.
private nonisolated(unsafe) var kAssociatedTaskBagKey: UInt8 = 0

extension TaskBag {
    /// Return (creating on first access) the `TaskBag` associated with `owner`
    /// via the Objective-C runtime's associated objects. When `owner` is
    /// deallocated, its associations — including this bag — are released; the
    /// bag's `deinit` then cancels any still-bound tasks.
    ///
    /// Intended for internal use by `Task.bound(to: AnyObject)` and
    /// `task.bind(to: AnyObject)`; exposed `internal` for testability.
    internal static func associated(with owner: AnyObject) -> TaskBag {
        objc_sync_enter(owner)
        defer { objc_sync_exit(owner) }

        if let bag = objc_getAssociatedObject(owner, &kAssociatedTaskBagKey) as? TaskBag {
            return bag
        }
        let bag = TaskBag()
        objc_setAssociatedObject(owner, &kAssociatedTaskBagKey, bag, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return bag
    }
}

// MARK: - Cancellation token for the create-and-bind race

/// Private helper used by `Task.bound(to:)` to bridge the window between
/// inserting the cancel entry into the bag and assigning the newly-created
/// `Task` to the entry. If `cancel()` is invoked before `setTask(_:)` (e.g.,
/// a concurrent `cancelAll()` on the bag), cancellation intent is recorded and
/// applied as soon as the task is wired up.
internal final class TaskCancelToken<Success, Failure: Error>: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Success, Failure>?
    private var cancelPending = false

    func setTask(_ task: Task<Success, Failure>) {
        lock.withLock {
            self.task = task
            if cancelPending { task.cancel() }
        }
    }

    func cancel() {
        lock.withLock {
            cancelPending = true
            task?.cancel()
        }
    }
}
