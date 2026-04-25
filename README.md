# SwiftAsyncEx

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
- **Vending observable state as a read-only handle.** Exposing a value so consumers can observe it but not mutate it, without coupling their interface to your concrete producer type. The internal-`MutableProperty` / public-`Property` pattern — the observable-era analog of `CurrentValueSubject` + `eraseToAnyPublisher`.
- **Single persistent values backed by `UserDefaults`, a file, or the keychain.** Most apps have a long tail of "one Codable thing we need to survive relaunch" values that do not warrant SwiftData. A read/write reference with a pluggable storage engine, error reporting as observable state, and participation in Observation tracking handles them uniformly.

These are small things. The point of the rewrite-to-structured-concurrency story is that you **stopped needing most of the old machinery**. SwiftAsyncEx is the short list of what is left.

## Contents

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

A `@MainActor` helper for "only one at a time" async work. The work closure is bound at construction; `run(_:)` fires it and awaits its output. While a task is in flight, further calls to `run(_:)` throw `SerialTask.AlreadyExecuting`. An observable `isExecuting` flag is exposed for UI binding, and `cancel()` tears down the in-flight task.

The underlying `Task` is an implementation detail — callers interact only through `run(_:)`, `fire(_:)`, and `cancel()`.

#### `run(_:) async throws -> Output`

Awaits the work and returns its output. Throws:

- `SerialTask.AlreadyExecuting` — a task is already in flight.
- `SerialTask.OwnerDeallocated` — the `weak(_:)` factory's owner has been deallocated. Not thrown by the plain initializer or by `weak(_:default:)`.
- `CancellationError` — the caller's task was cancelled, or `cancel()` was invoked externally while this run was in flight.
- Any error thrown by the bound work closure itself.

The work closure is typed `@MainActor (Input) async throws -> Output`. Non-throwing closures are accepted unchanged — a non-throwing closure is a subtype of a throwing one, so existing call sites keep compiling. Errors thrown by the work surface at `run(_:)` alongside the control errors above, so a single typed `catch` can distinguish them:

```swift
do {
    let result = try await loader.run()
    // ...
} catch is SerialTask<Void, Value>.AlreadyExecuting {
    // skipped — another run in flight
} catch let error as MyDomainError {
    // work failed with a domain error
}
```

The `try?` idiom collapses **every** error path to `nil` — control errors and work-thrown errors alike:

```swift
if let result = try? await loader.run() {
    // work executed and produced `result`
}
```

Caller cancellation propagates into the work closure: cancelling the awaiting task cancels the inner work via `withTaskCancellationHandler`.

#### `fire(_:)`

A synchronous, non-throwing, Void-returning wrapper that spawns a Task, awaits `run(_:)`, and swallows every outcome — `AlreadyExecuting`, `OwnerDeallocated`, `CancellationError`, and any error thrown by the work closure. Designed for SwiftUI call sites — button actions, `.onAppear`, etc. — where the surrounding context is not `async` and the caller only wants the side effect to happen if it can:

```swift
@MainActor @Observable
final class SaveButtonModel {
    private lazy var saveTask = SerialTask.weak(self) { `self` in
        await self.performSave()
    }
    var isSaving: Bool { saveTask.isExecuting }

    func tap() { saveTask.fire() }
}
```

#### `weak(_:)` / `weak(_:default:)` factories

Both capture `owner` weakly and pass the non-nil owner into the work closure (so the body can shadow-rebind it as `self` and read naturally). They differ in how they handle a deallocated owner:

- **`weak(_:)`** — `run(_:)` throws `SerialTask.OwnerDeallocated`. Use for work with no meaningful fallback value; `fire(_:)` swallows the throw, and `try? await run(_:)` collapses to `nil`.
- **`weak(_:default:)`** — `run(_:)` returns the provided default value instead. Use when the caller needs a guaranteed `Output` regardless of owner lifetime. The default only substitutes for owner deallocation — errors thrown by the work closure are re-thrown unchanged so the caller can still distinguish "owner gone" (default returned) from "work failed" (error thrown).

```swift
// Void-output — typical UI fire-and-forget:
let save = SerialTask.weak(self) { `self` in
    await self.performSave()
}

// Non-Void output with a fallback:
let fetchCount = SerialTask<Void, Int>.weak(self, default: 0) { `self` in
    await self.currentCount()
}

// Parameterized:
let saveItem = SerialTask<Item, Void>.weak(self) { `self`, item in
    await self.save(item)
}
```

#### Skip semantics

While a task is in flight, further `run(_:)` calls throw `AlreadyExecuting` immediately — not queued, not coalesced, not replace-in-flight. "Replace the current work" is available explicitly via `cancel()` + `run(_:)`.

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

### `PropertyProtocol<Value>` / `MutableProperty<Value>` / `Property<Value>`

Read/write observable-value handles built for a specific job: **vending an observable `T` to a consumer without coupling them to your producer type**. The internal-mutable / public-readonly pattern that `CurrentValueSubject` + `eraseToAnyPublisher` covered in the Combine era, re-expressed for `@Observable`.

The common pattern:

```swift
public protocol UnreadCountSource: Observable {
    var unreadCount: any PropertyProtocol<Int> { get }
}

@MainActor @Observable
final class InboxManager: UnreadCountSource {
    private let _unread = MutableProperty(0)
    let unreadCount: any PropertyProtocol<Int>

    init() {
        self.unreadCount = Property(mirroring: _unread)
    }

    func markRead() { _unread.modify { $0 -= 1 } }
}
```

The consumer's interface is `any PropertyProtocol<Int>` — any class that can project its state into an observable `Int` can satisfy it. The consumer cannot cast back to `MutableProperty<Int>` and write: `Property<T>` is a distinct concrete type with no setter, so the read-only guarantee is structural, not a convention.

#### `MutableProperty<Value>`

An `@Observable @MainActor` single-value box. Read and write through `.value`; use `modify(_:)` for atomic in-place mutation of collection / struct values. Cross-actor `set(_:) async` / `read() async` helpers let background tasks update the value without `await MainActor.run { ... }` ceremony at the call site.

#### `Property<Value>` constructors

- `Property.constant(_:)` — fixed value, no pump.
- `Property(mirroring:)` — wrap any `PropertyProtocol<T>` (a `MutableProperty`, `PersistentProperty`, or another `Property`) as a read-only handle. The common vending case.
- `Property(tracking: { ... })` — derive a value from a closure that reads `@Observable` state. Updates when any state the closure reads changes. The general-purpose `map` / `combineLatest` / keyPath-projection constructor collapsed into one Observation-tracked closure.
- `Property(initial: T, from: seq)` — seed a value, then follow an `AsyncSequence<T>`. Bridges `AsyncChannel`, `AsyncStream`, `NotificationCenter.notifications(...)`, Combine's `.values`, and anything else that adopts `AsyncSequence`.

Mirror- and tracking-mode updates lag source writes by one runloop tick (Observation's `onChange` fires on `willSet`; the internal pump yields before re-reading so the committed value is the one propagated). The pump is bound to the `Property`'s lifetime — when it deallocates, the pump is cancelled automatically.

#### Binding operator `<~`

Any `MutablePropertyProtocol` — `MutableProperty`, `PersistentProperty`, or your own conformer — accepts pumped values via `<~`:

```swift
let counter = MutableProperty(0)
counter <~ asyncSequence        // pump AsyncSequence elements into the property
counter <~ otherProperty        // mirror another PropertyProtocol
```

The returned `Task<Void, Never>` is auto-bound to the destination's lifetime; the binding stops when the destination deallocates. Capture the task and `.cancel()` to tear the binding down early.

#### Bridging back to `AsyncSequence`

`asAsyncSequence()` on any `PropertyProtocol` returns an `AsyncStream<Value>` that yields the current value immediately and then each subsequent change — useful for non-UI consumers that prefer `for await`:

```swift
for await count in inbox.unreadCount.asAsyncSequence() {
    await audit.record(count)
}
```

#### What is deliberately not here

No `map`, `combineLatest`, `flatMap`, `filter`, `removeDuplicates`, or other operators. Derivations that belong on your own `@Observable` are computed properties; derivations that must escape your class's type identity are `Property(tracking: { ... })`. One closure-based API covers both cleanly without inviting Combine-shaped operator chains.

### `PersistentProperty<Value: Codable & Sendable>`

A persistent, `@Observable @MainActor` reference to a single `Codable` value, backed by a pluggable storage engine. Constructed with a `storageEngine`, a `key`, and a `defaultValue`; read and written synchronously through `.value`. Writes update the in-memory value immediately, fire Observation tracking, and schedule an async flush to the backing engine on a detached task so the main thread is never blocked by storage I/O.

`PersistentProperty` conforms to `MutablePropertyProtocol<Value>` — it accepts `<~` bindings, can be wrapped in a `Property(mirroring:)` for read-only vending, and participates in any generic code written against the property protocols.

```swift
let onboarded = PersistentProperty(
    storageEngine: UserDefaultsStorageEngine(),
    key: "hasOnboarded",
    defaultValue: false
)

onboarded.value = true          // synchronous write; flush scheduled off-main
let seen = onboarded.value      // synchronous read
await onboarded.awaitPendingFlush()  // optional: wait for the flush to land
```

Flushes for a given property are serialized — consecutive writes reach the engine in caller order, so the on-disk value never reorders. Storage errors surface through an observable `error` property rather than throwing from the setter, so call sites stay ergonomic and UI can bind to failure state.

The intent is that instances are **held privately inside a containing `@Observable` class** and re-exposed to callers as computed properties that satisfy a public, read-only protocol surface:

```swift
public protocol AppPrefs: Observable {
    var hasOnboarded: Bool { get }
    var themeName: String { get }
}

@MainActor @Observable
final class AppPrefsImpl: AppPrefs {
    private let _hasOnboarded = PersistentProperty(
        storageEngine: UserDefaultsStorageEngine(),
        key: "hasOnboarded",
        defaultValue: false
    )
    private let _themeName = PersistentProperty(
        storageEngine: UserDefaultsStorageEngine(),
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

Keys are expressed as `PersistentPropertyKey` (main key + optional subkey, with automatic sanitization so the same key works across filesystem- and keychain-style engines); a `CustomStringConvertible` convenience overload accepts a plain string. An in-place `modify(_:)` helper is available for mutating collection / struct values.

#### Updating from a background task

Because `PersistentProperty` is `@MainActor`, writes from background contexts need to hop to the main actor. Two `nonisolated async` helpers let you do that without `await MainActor.run { ... }` ceremony at the call site:

```swift
Task.detached {
    let fetched = try await api.fetchProfile()
    await profile.set(fetched)      // one await, no MainActor.run
    let current = await profile.read()
}
```

Sequential `await property.set(_:)` calls from a single task land in call order; `read()` returns the current value after hopping to the main actor.

#### Storage engines

`PersistentPropertyStorageEngine` is the pluggability point — any `store` / `retrieve` backend implements it. The library ships with:

- **`UserDefaultsStorageEngine`** — wraps a `UserDefaults` instance (defaults to `.standard`; pass a suite-specific instance for scoping).
- **`FileStorageEngine`** — one JSON file per key with atomic writes, scoped to an explicit `URL` or a well-known directory (Documents / Caches / Temporary / App Group) with optional subpath.
- **`KeychainStorageEngine`** — `kSecClassGenericPassword` storage scoped by `service`, with optional `accessGroup` (entitlement-gated) and optional `synchronized` iCloud Keychain.
- **`InMemoryStorageEngine`** — ephemeral, test-friendly; JSON round-trip mirrors the on-disk engines' Codable semantics.

Additional engines are straightforward to implement against the protocol.

### `AsyncDemuxer<Output>` / `ThrowingAsyncDemuxer<Output>`

Single-flight coalescing for a **parameterless** async operation. Multiple concurrent callers that hit the demuxer while work is in flight all wait on the same underlying `Task`; when it resolves, every caller receives the same result. When no callers are waiting and the value is requested again, a fresh execution begins.

Two sibling types mirror Swift's `Task` / `TaskGroup` vs. `ThrowingTaskGroup` pattern: `AsyncDemuxer` for non-throwing work, `ThrowingAsyncDemuxer` for work that may fail.

```swift
let refresh = ThrowingAsyncDemuxer<Profile> {
    try await api.fetchProfile()
}

// Two concurrent callers → one network request, two results:
async let a = refresh.execute()
async let b = refresh.execute()
let (p1, p2) = try await (a, b)
```

The throwing variant handles per-waiter cancellation — cancelling one awaiter throws `CancellationError` for that caller while the shared task and other waiters continue unaffected.

Useful for "refresh current user," "load app config," and similar idempotent, unparameterized fetches.

### `KeyedAsyncDemuxer<Key, Output>` / `ThrowingKeyedAsyncDemuxer<Key, Output>`

The parameterized variants: one demuxer instance handles many keys, and concurrent callers for the same key share a single execution. Different keys run in parallel.

Constructed with a factory closure that produces the async work for a given key:

```swift
let images = ThrowingKeyedAsyncDemuxer<URL, UIImage> { url in
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
5. **`@MainActor` where state and UI meet, `Sendable` elsewhere.** Helpers that expose observable state or are typically held by a view model / manager — `Task.onChange`, `SerialTask`, `TaskBag`, `MutableProperty`, `Property`, `PersistentProperty` — are MainActor-bound. Purely data-layer helpers — `AsyncDemuxer`, `ThrowingAsyncDemuxer`, `KeyedAsyncDemuxer`, `ThrowingKeyedAsyncDemuxer`, and the `PersistentPropertyStorageEngine` implementations — are `Sendable` and actor-agnostic; they are safe to hold inside a MainActor container and to invoke from any isolation context.

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

Add via Swift Package Manager:

```swift
.package(url: "https://github.com/jmfieldman/SwiftAsyncEx.git", from: "1.1.0")
```

and depend on the `SwiftAsyncEx` product from your target.

## License

MIT.

## Contributing

Issues proposing additional helpers are welcome, but the bar is deliberately high: **"this exact pattern repeats everywhere and the boilerplate has a real footgun."** If it is just a convenience that wraps one line of `async` code, it probably does not belong here.
