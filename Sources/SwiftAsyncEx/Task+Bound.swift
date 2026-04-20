//
//  Task+Bound.swift
//  Copyright © 2026 Jason Fieldman.
//

import Foundation

// MARK: - Create-and-bind: Task.bound(to:)

extension Task where Failure == Never {
    /// Spawn a task whose lifetime is bounded by the given `TaskBag`. When the
    /// bag is deallocated or `cancelAll()` is invoked, the task is cancelled.
    /// The task is pruned from the bag on completion.
    @discardableResult
    public static func bound(
        to bag: TaskBag,
        priority: TaskPriority? = nil,
        operation: @escaping @Sendable () async -> Success
    ) -> Task<Success, Never> where Success: Sendable {
        let id = UUID()
        let token = TaskCancelToken<Success, Never>()
        bag.insertRaw(id: id, cancel: { token.cancel() })
        let task = Task<Success, Never>(priority: priority) { [weak bag] in
            defer { bag?.remove(id) }
            return await operation()
        }
        token.setTask(task)
        return task
    }

    /// Spawn a task bounded by the lifetime of `owner`. When `owner` is
    /// deallocated, its associated `TaskBag` is released and the task is
    /// cancelled. The task is pruned on completion.
    @discardableResult
    public static func bound(
        to owner: AnyObject,
        priority: TaskPriority? = nil,
        operation: @escaping @Sendable () async -> Success
    ) -> Task<Success, Never> where Success: Sendable {
        Task.bound(to: TaskBag.associated(with: owner), priority: priority, operation: operation)
    }
}

extension Task where Failure == any Error {
    @discardableResult
    public static func bound(
        to bag: TaskBag,
        priority: TaskPriority? = nil,
        operation: @escaping @Sendable () async throws -> Success
    ) -> Task<Success, any Error> where Success: Sendable {
        let id = UUID()
        let token = TaskCancelToken<Success, any Error>()
        bag.insertRaw(id: id, cancel: { token.cancel() })
        let task = Task<Success, any Error>(priority: priority) { [weak bag] in
            defer { bag?.remove(id) }
            return try await operation()
        }
        token.setTask(task)
        return task
    }

    @discardableResult
    public static func bound(
        to owner: AnyObject,
        priority: TaskPriority? = nil,
        operation: @escaping @Sendable () async throws -> Success
    ) -> Task<Success, any Error> where Success: Sendable {
        Task.bound(to: TaskBag.associated(with: owner), priority: priority, operation: operation)
    }
}

// MARK: - Post-hoc binding: task.bind(to:)

extension Task where Success: Sendable {
    /// Bind this pre-existing task to `bag`. Returns self for chaining.
    @discardableResult
    public func bind(to bag: TaskBag) -> Task<Success, Failure> {
        bag.insert(self)
        return self
    }

    /// Bind this pre-existing task to the TaskBag associated with `owner`.
    /// Returns self for chaining.
    @discardableResult
    public func bind(to owner: AnyObject) -> Task<Success, Failure> {
        TaskBag.associated(with: owner).insert(self)
        return self
    }
}
