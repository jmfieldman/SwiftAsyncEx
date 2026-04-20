# SwiftAsyncEx

> **Status:** early / pre-1.0. API is likely to shift as patterns settle.

SwiftAsyncEx is a small library of ergonomic helpers around Swift **Structured Concurrency** and the **Observation** framework. It is the set of pieces you tend to write once per project when you commit to `async`/`await`, `AsyncSequence`, `@Observable`, and SwiftUI — extracted into one place so you do not write them again.

The library is intentionally narrow. It does not try to be a reactive framework, it does not introduce a new stream type, and it does not wrap `Task`. It fills the gaps that show up when you lean on the built-in primitives for a real app.

## Why this exists

Swift 5.5+ gave us structured concurrency; the Observation framework (iOS 17+) gave us a synchronous read-tracking model for UI. Together they remove the need for most of what reactive libraries (Combine, Combine-style extensions, ReactiveSwift, etc.) provided — `Future`s become `async throws -> T`, streams become `AsyncSequence`, `CurrentValueSubject` + derived-value chains become `@Observable` classes with computed properties, and observing a value becomes `withObservationTracking`.

That story is real but not complete. A handful of patterns recur often enough, and with sharp enough footguns, that every project re-invents them. This library standardizes them:

- **Reacting to `@Observable` state changes outside of SwiftUI.** `withObservationTracking`'s `onChange` fires once per registration (you have to re-arm) and fires on `willSet` (you have to yield before reading the new value). Both footguns belong behind one helper.
- **Single-flight async work.** Multiple callers ask for the same thing at the same time and only one should actually do the work; all of them get the result. The standard library has no direct primitive for this.
- **Binding a `Task`'s lifetime to an owning object.** Structured concurrency cancels child tasks when their scope ends, but the common UI pattern — work kicked off from a synchronous event that should be bounded by a view model's or manager's lifetime — has no built-in analog. A plain `Task` outlives every reference to it. A bag + `bind(to:)` pattern (the `Set<AnyCancellable>` equivalent for `Task`) covers this.
- **"Only one at a time" UI actions.** Tap-spam protection on buttons that kick off `async` work, with an `isExecuting` flag the view can bind to. Easy to hand-roll per site, tedious to hand-roll everywhere, and subtly wrong when you do.
- **Loading state as a first-class type.** Distinguishing "haven't started," "loading," "loaded(value)," and "failed(error)" is common enough to deserve a shared enum rather than four scattered `Bool`s.
- **Single persistent values backed by `UserDefaults`, a file, or the keychain.** Most apps have a long tail of "one Codable thing we need to survive relaunch" values that do not warrant SwiftData. A read/write reference with a pluggable storage engine, error reporting as observable state, and participation in Observation tracking handles them uniformly.

These are small things. The point of the rewrite-to-structured-concurrency story is that you **stopped needing most of the old machinery**. SwiftAsyncEx is the short list of what is left.

## Planned contents

These are the pieces this library intends to ship. Some are scaffolded, some are not yet written; this README precedes the implementation.

### `Task.onChange(of:perform:) -> Task<Void, Never>`

An Observation-tracking helper that spawns a task which calls `perform` every time the value returned by the tracked expression changes. Hides the re-arm loop and the `willSet` / `Task.yield()` ordering problem.

Exposed as a static factory on `Task` (consistent with `Task.bound(to:)` elsewhere in this library, and — pragmatically — avoids colliding with SwiftUI's `View.onChange(of:)` modifier in View-body scopes).

```swift
let task = Task.onChange(of: { manager.unreadCount }) { count in
    await badge.update(count)
}
// Cancel when you no longer want to observe:
task.cancel()
```

Useful for manager-to-manager reactions and for any non-SwiftUI consumer that wants to react to `@Observable` state. On iOS 26+ / macOS 26+ the system offers a native `Observations { … }` sequence that covers the same ground; where this library uses it internally it will be gated with `@available` and the iOS 17 path will keep working unchanged. Call sites can migrate mechanically when their deployment floor rises.

### `SerialTask<Input, Output>`

A `@MainActor` helper for "only one at a time" async work. The work closure is bound at construction; `run(_:)` fires it. While a task is in flight, further calls to `run(_:)` are skipped. An observable `isExecuting` flag is exposed for UI binding, and `cancel()` tears down the in-flight task.

`run(_:)` returns `Task<Output, Never>?` — `nil` when the call was skipped (either because one is already in flight, or because a weakly-held owner has been deallocated). Fire-and-forget callers ignore it; callers that want the value can `await task.run(input)?.value`. Void specializations collapse the input and/or output so they do not appear at call sites.

```swift
@MainActor @Observable
final class SaveButtonModel {
    private lazy var saveTask = SerialTask.weak(self) { `self` in
        await self.performSave()
    }
    var isSaving: Bool { saveTask.isExecuting }

    func tap() { saveTask.run() }
}
```

The `weak(_:)` convenience captures the owner weakly, passes the non-nil owner into the work closure (so the body can shadow-rebind it as `self` and read naturally), and skips execution if the owner has been deallocated.

A parameterized variant takes an input per call:

```swift
let saveItem = SerialTask<Item, Void>.weak(self) { `self`, item in
    await self.save(item)
}
saveItem.run(item)
```

Reach for this when the plain `guard !isSaving else { return }` pattern starts to repeat. Most screens do not need it.

### `TaskBag` / `Task.bound(to:)` / `task.bind(to:)`

A lifetime-binding helper for `Task`. Binds one or more tasks to an owning object; when the owner is deallocated, every bound task receives `.cancel()`. Fills the gap that `Set<AnyCancellable>` covers in Combine — `Task` does **not** auto-cancel when its references are dropped, so this is active behavior the helper adds rather than getting for free from `deinit`.

The primary create-and-bind form:

```swift
@MainActor @Observable
final class ListViewModel {
    func onAppear() {
        Task.bound(to: self, priority: .userInitiated) {
            await self.loadFirstPage()
        }
    }
}
```

The post-hoc form, for tasks constructed elsewhere:

```swift
let t = Task { await fetchThing() }
t.bind(to: self)
```

Both forms return the underlying `Task`, so callers can still `await` the result or call `cancel()` explicitly. Tasks are pruned from the bag on completion, so long-lived owners do not accumulate dead entries.

For callers who prefer explicit ownership to the associated-object trick, a plain `TaskBag` stored property is offered as an alternative:

```swift
@MainActor @Observable
final class CoordinatorModel {
    private let tasks = TaskBag()

    func start() {
        Task { await self.setup() }.bind(to: tasks)
    }
}
```

Both entry points share one implementation.

**Cooperative-cancellation caveat.** `Task.cancel()` sets a flag. A task body that never checks `Task.isCancelled` and never hits a cancellation-aware suspend will run to completion anyway. This is true of all `Task` usage in Swift; surfaced here because users arriving from `AnyCancellable` tend to expect "cancel = stops immediately."

### `LoadableResult<T, E: Error>`

```swift
public enum LoadableResult<T, E: Error> {
    case idle
    case loading
    case loaded(T)
    case failed(E)
}
```

The four-state enum for screens that need to distinguish "have not started" from "empty." Comes with convenience accessors (`value`, `error`, `isLoading`) and the usual `map` / `mapError`.

### `PersistentProperty<Value: Codable & Sendable>`

A persistent, Observation-compatible reference to a single Codable value, backed by a pluggable storage engine. Constructed with a `storageEngine`, a `key`, and a `defaultValue`; read and written through `.value`; participates in `@Observable` read-tracking when held by an `@Observable` container.

```swift
let onboarded = PersistentProperty(
    storageEngine: userDefaults,
    key: "hasOnboarded",
    defaultValue: false
)

onboarded.value = true          // synchronous write; flushed to the engine
let seen = onboarded.value      // synchronous read
```

Writes update the in-memory value immediately and are flushed to the backing engine; storage errors surface through an observable `error` property rather than throwing from the setter, so call sites stay ergonomic and UI can react to failures as state.

The intent is that instances are **held privately inside a containing `@Observable` class** and re-exposed to callers as computed properties that satisfy a public, read-only protocol surface:

```swift
public protocol AppPrefs: Observable {
    var hasOnboarded: Bool { get }
    var themeName: String { get }
}

@MainActor @Observable
final class AppPrefsImpl: AppPrefs {
    private let _hasOnboarded = PersistentProperty(
        storageEngine: UserDefaultsStorageEngine.standard,
        key: "hasOnboarded",
        defaultValue: false
    )
    private let _themeName = PersistentProperty(
        storageEngine: UserDefaultsStorageEngine.standard,
        key: "themeName",
        defaultValue: "system"
    )

    var hasOnboarded: Bool {
        get { _hasOnboarded.value }
        set { _hasOnboarded.value = newValue }
    }
    var themeName: String {
        get { _themeName.value }
        set { _themeName.value = newValue }
    }
}
```

Keys are expressed as `PersistentPropertyKey` (main key + optional subkey, with automatic sanitization so the same key works across filesystem- and keychain-style engines); a `CustomStringConvertible` convenience overload accepts a plain string.

#### Storage engines

`PersistentPropertyStorageEngine` is the pluggability point — any `store` / `retrieve` backend implements it. The library ships with:

- **`UserDefaultsStorageEngine`** — `.standard` or a named suite.
- **`FileStorageEngine`** — JSON-on-disk with atomic writes, scoped to a chosen directory (Documents / Caches / Temporary / App Group). Replaces the earlier "file-backed Codable store" idea as a first-class engine.
- **`KeychainStorageEngine`** — per-service, per-access-group keychain storage with optional iCloud synchronization.
- **`InMemoryStorageEngine`** — ephemeral, test-friendly.

Additional engines are straightforward to implement against the protocol.

### `AsyncDemuxer<Output: Sendable>`

Single-flight coalescing for a **parameterless** async operation. Multiple concurrent callers that hit the demuxer while work is in flight all wait on the same underlying `Task`; when it resolves, every caller receives the same result. When no callers are waiting and the value is requested again, a fresh execution begins.

```swift
let refresh = AsyncDemuxer<Profile> {
    try await api.fetchProfile()
}

// Two concurrent callers → one network request, two results:
async let a = refresh.execute()
async let b = refresh.execute()
let (p1, p2) = try await (a, b)
```

Useful for "refresh current user," "load app config," and similar idempotent, unparameterized fetches.

### `KeyedAsyncDemuxer<Key: Hashable, Output: Sendable>`

The parameterized variant: one demuxer instance handles many keys, and concurrent callers for the same key share a single execution. Different keys run in parallel.

Constructed with a factory closure that produces the async work for a given key:

```swift
let images = KeyedAsyncDemuxer<URL, UIImage> { url in
    try await ImageLoader.load(url)
}

let img = try await images.execute(key: url)
```

Intended for per-key caches, per-ID fetches, and any pattern where "the same underlying work should not run twice concurrently, but different inputs are independent." Conceptually analogous to the keyed-factory single-flight pattern familiar from pre-concurrency reactive libraries, re-expressed for `async`/`await`.

## Design principles

1. **Thin over clever.** Each helper is small, readable, and does one thing. If a helper grows an options bag, it is probably two helpers.
2. **No new paradigm.** The library does not introduce a stream type, a scheduler, or a reactive surface. Everything composes with plain `async`, `AsyncSequence`, `Task`, and `@Observable`.
3. **Migration-aware.** Anywhere Swift or Foundation is about to ship a replacement, the helper is designed so its call sites migrate mechanically when the deployment floor rises. `Task.onChange` is the clearest example — it will be deletable in favor of `Observations { … }`.
4. **iOS 17 is the floor.** The library compiles and runs on iOS 17 / macOS 14 / tvOS 17 / watchOS 10 using only APIs available at that floor. Any use of a newer API (for example the iOS 26 `Observations` sequence) is gated behind `@available` with a working fallback on the floor; no public API requires a higher OS than the package minimum.
5. **`@MainActor` by default where it matters.** UI-facing helpers (`Task.onChange`, `SerialTask`, `TaskBag`) are MainActor-bound. Data-layer helpers (`AsyncDemuxer`, `PersistentProperty` and its engines) are `Sendable` and actor-agnostic; they are safe to hold inside a MainActor container.
6. **Typed errors welcome.** Public async APIs use `async throws(E) -> T` where it reads cleanly; helpers that cannot pick an `E` stay generic.

## Non-goals

- Replacing Combine or any reactive framework. If you need multicasting, backpressure, or elaborate operator chains, this is not the library.
- A new `Task` type, executor, or scheduler.
- Cross-actor read-tracking. Observation is synchronous by design; patterns for bridging off-main state into a MainActor `@Observable` are a project concern, not a library one.
- Dependency-injection, navigation, persistence-at-scale, or anything above the "small glue" tier.

## Requirements

- Swift 5.9+
- **iOS 17 / macOS 14 / tvOS 17 / watchOS 10** — the Observation framework floor, and the only platform minimum this library targets.

The library is written against iOS 17 APIs. Newer OS features (e.g. the iOS 26 `Observations` async sequence) are used only behind `@available` checks with a fallback that works on the floor; no public entry point requires a higher OS than the package minimum. CI will build and test against the minimum.

## Installation

Once published, add via Swift Package Manager:

```swift
.package(url: "https://github.com/jmfieldman/SwiftAsyncEx.git", from: "0.1.0")
```

and depend on the `SwiftAsyncEx` product from your target.

## License

MIT. See `LICENSE` (to be added).

## Contributing

The library is in its shaping phase. Issues proposing additional helpers are welcome, but the bar is high: **"this exact pattern repeats everywhere and the boilerplate has a real footgun."** If it is just a convenience that wraps one line of `async` code, it probably does not belong here.
