//
//  AsyncSequence+MainActorPump.swift
//  Copyright © 2026 Jason Fieldman.
//

/// Deliver each element of `source` to `receive` on the main actor, stopping
/// when `source` finishes or throws. Thrown errors are not surfaced.
///
/// `for await` in a main-actor context can only keep the iterator on the main
/// actor where `next(isolation:)` exists. Below those OS versions it calls the
/// nonisolated `next()`, which the compiler flags because the iterator's
/// conformance might be isolated. The fallback iterates from a nonisolated
/// context instead, where `next()` was already running.
@MainActor
func pumpOnMainActor<S: AsyncSequence & Sendable>(
    _ source: S,
    receive: @escaping @MainActor @Sendable (S.Element) -> Void
) async where S.Element: Sendable {
    do {
        if #available(iOS 18, macOS 15, tvOS 18, watchOS 11, visionOS 2, *) {
            var iterator = source.makeAsyncIterator()
            while let element = try await iterator.next(isolation: #isolation) {
                receive(element)
            }
        } else {
            try await pumpFromNonisolatedContext(source, receive: receive)
        }
    } catch {
        // Source terminated with error; pump stops.
    }
}

private nonisolated func pumpFromNonisolatedContext<S: AsyncSequence & Sendable>(
    _ source: S,
    receive: @escaping @MainActor @Sendable (S.Element) -> Void
) async throws where S.Element: Sendable {
    for try await element in source {
        await receive(element)
    }
}
