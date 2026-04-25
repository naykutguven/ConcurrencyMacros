# ConcurrencyMacros

[![Swift 6.2+](https://img.shields.io/badge/Swift-6.2%2B-orange.svg)](#requirements)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%2017%2B%20%7C%20macOS%2014%2B%20%7C%20tvOS%2017%2B%20%7C%20watchOS%2010%2B-blue.svg)](#requirements)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](#license)

`ConcurrencyMacros` is a production-focused Swift Concurrency macro package for the patterns teams implement repeatedly: lock-backed shared state (with practical checked `Sendable` adoption), in-flight deduplication, callback-to-stream bridging, timeouts, retries, and bounded concurrent collection work.

The package keeps macro call sites small while routing behavior through explicit runtime helpers with documented safety constraints.

## Requirements

- Swift 6.2
- iOS 17+
- macOS 14+
- tvOS 17+
- watchOS 10+

## Installation

Add the package dependency in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/naykutguven/ConcurrencyMacros.git", from: "0.1.0")
]
```

Add the library product to your target:

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "ConcurrencyMacros", package: "ConcurrencyMacros")
    ]
)
```

## Why Macros?

Concurrency bugs usually come from patterns that look simple until every call site has to preserve the same locking, cancellation, deduplication, and ordering rules. `ConcurrencyMacros` keeps those rules explicit while removing the repeated hand-written machinery.

### Stop manually protecting shared state with locks every time

```swift
import os

final class SessionStore: Sendable {
    private struct State: Sendable {
        var sessionsByID: [String: Session] = [:]
        var activeUserID: String?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func upsert(_ session: Session) {
        state.withLock { state in
            state.sessionsByID[session.id] = session
        }
    }

    func session(id: String) -> Session? {
        state.withLock { state in
            state.sessionsByID[id]
        }
    }
}
```

### Use `@ThreadSafe` instead

```swift
import ConcurrencyMacros

@ThreadSafe
final class SessionStore: Sendable {
    var sessionsByID: [String: Session] = [:]
    var activeUserID: String?

    func upsert(_ session: Session) {
        inLock { state in
            state.sessionsByID[session.id] = session
        }
    }

    func session(id: String) -> Session? {
        inLock { state in
            state.sessionsByID[id]
        }
    }
}
```

The macro owns the lock-backed state model and keeps mutations going through one generated synchronization path.

### Stop hand-rolling in-flight task deduplication

```swift
actor ProfileService {
    private let api: ProfileAPI
    private var inFlightProfiles: [User.ID: Task<Profile, Error>] = [:]

    init(api: ProfileAPI) {
        self.api = api
    }

    func profile(for userID: User.ID) async throws -> Profile {
        if let task = inFlightProfiles[userID] {
            return try await task.value
        }

        let api = self.api
        let task = Task {
            try await api.fetchProfile(for: userID)
        }

        inFlightProfiles[userID] = task
        defer { inFlightProfiles[userID] = nil }

        return try await task.value
    }
}
```

### Use `@SingleFlightActor` instead

```swift
import ConcurrencyMacros

actor ProfileService {
    private let api: ProfileAPI

    init(api: ProfileAPI) {
        self.api = api
    }

    @SingleFlightActor(key: { (userID: User.ID) in userID })
    func profile(for userID: User.ID) async throws -> Profile {
        try await api.fetchProfile(for: userID)
    }
}
```

The macro keeps one leader operation per key and lets concurrent callers await the same in-flight result.

### Stop wiring timeout and retry loops by hand

```swift
struct RequestTimedOut: Error {}

func fetchReceipt(_ request: ReceiptRequest) async throws -> Receipt {
    var delay = Duration.milliseconds(200)

    for attempt in 0...2 {
        do {
            return try await withThrowingTaskGroup(of: Receipt.self) { group in
                group.addTask {
                    try await api.fetchReceipt(request)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(5))
                    throw RequestTimedOut()
                }

                let receipt = try await group.next()!
                group.cancelAll()
                return receipt
            }
        } catch {
            guard attempt < 2 else { throw error }
            try await Task.sleep(for: delay)
            delay = attempt == 0 ? .milliseconds(400) : .seconds(2)
        }
    }

    throw CancellationError()
}
```

### Use `#withTimeout` and `#retrying` instead

```swift
import ConcurrencyMacros

let receipt = try await #retrying(
    max: 2,
    backoff: .exponential(
        initial: .milliseconds(200),
        multiplier: 2,
        maxDelay: .seconds(2)
    ),
    jitter: .full
) {
    try await #withTimeout(.seconds(5)) {
        try await api.fetchReceipt(request)
    }
}
```

The retry policy and per-attempt timeout stay visible at the call site without hand-written control flow around every operation.

### Stop manually coordinating bounded task groups

```swift
struct Metadata: Sendable { ... }

actor MetadataClient {
    func fetchMetadata(for url: URL) async throws -> Metadata { ... }
}

func metadata(for urls: [URL], client: MetadataClient) async throws -> [Metadata] {
    var results = Array<Metadata?>(repeating: nil, count: urls.count)
    var iterator = urls.enumerated().makeIterator()

    try await withThrowingTaskGroup(of: (Int, Metadata).self) { group in
        for _ in 0..<min(4, urls.count) {
            guard let (index, url) = iterator.next() else { break }
            group.addTask {
                (index, try await client.fetchMetadata(for: url))
            }
        }

        while let (index, metadata) = try await group.next() {
            results[index] = metadata

            if let (nextIndex, nextURL) = iterator.next() {
                group.addTask {
                    (nextIndex, try await client.fetchMetadata(for: nextURL))
                }
            }
        }
    }

    return results.map { $0! }
}
```

### Use `#concurrentMap` instead

```swift
import ConcurrencyMacros

let metadata = try await #concurrentMap(urls, limit: .fixed(4)) { url in
    try await client.fetchMetadata(for: url)
}
```

The macro handles bounded fan-out, cancellation on failure, and stable output ordering.

## Macro Index

| Macro | Kind | Purpose | Applies To |
| --- | --- | --- | --- |
| `@ThreadSafe` | Attached (`member`, `memberAttribute`) | Synthesizes lock-backed state and rewrites mutable stored properties | Class declarations |
| `@ThreadSafeInitializer` | Attached (`body`) | Helper rewrite for initializer assignment staging | Initializers (helper/support) |
| `@ThreadSafeProperty` | Attached (`accessor`) | Helper rewrite for lock-backed property accessors | Mutable stored properties (helper/support) |
| `@SingleFlightActor` | Attached (`body`, `peer`) | Deduplicates in-flight actor method work by key | Actor instance methods |
| `@SingleFlightClass` | Attached (`body`, `peer`) | Deduplicates in-flight class method work by key | `final` class instance methods |
| `@StreamBridge` | Attached (`body`, `peer`) | Generates `AsyncStream` / `AsyncThrowingStream` wrappers from callback registration methods | Actor/class instance methods |
| `@StreamBridgeDefaults` | Attached (`member`) | Declares default stream-bridge options for a nominal type | Nominal types (helper/support) |
| `@StreamToken` | Attached (`extension`) | Synthesizes `StreamBridgeTokenCancellable` conformance | Class/struct/enum tokens (helper/support) |
| `#withTimeout` | Freestanding expression | Runs an async operation with timeout cancellation | Expressions |
| `#retrying` | Freestanding expression | Retries async throwing work with backoff and jitter | Expressions |
| `#concurrentMap` | Freestanding expression | Concurrent async map with stable output order | Expressions |
| `#concurrentCompactMap` | Freestanding expression | Concurrent async compact-map with stable output order | Expressions |
| `#concurrentFlatMap` | Freestanding expression | Concurrent async flat-map with stable outer ordering | Expressions |
| `#concurrentForEach` | Freestanding expression | Concurrent async side-effect execution | Expressions |

## `@ThreadSafe`

### What it replaces

Manual lock storage, private state containers, and repeated lock accessors for mutable class state.

### Use when

Use it for synchronous shared mutable state in `final` classes where callers need normal property or method APIs backed by consistent locking.

### Safety notes

- Intended for class declarations.
- When a class has no initializer, each mutable stored property must have a default value.
- Rewriting applies to mutable stored properties and designated initializers; convenience initializers are not rewritten.
- Use generated `inLock` for multi-property or read-modify-write operations that must be atomic.
- The generated state container is lock-backed and `Sendable`.

## `@SingleFlightActor`

### What it replaces

Actor-local dictionaries of in-flight `Task` values, cleanup paths, waiter handling, and duplicated cancellation policy decisions.

### Use when

Use it for expensive actor-isolated async work where concurrent calls with the same key should share one in-flight operation.

### Safety notes

- Deduplication is in-flight only; results are not cached after completion.
- Supported on nominal actor instance methods, not extensions, `static`, `class`, or `nonisolated` methods.
- The method must be `async`; typed throws, generic methods, opaque `some` returns, and unsupported parameter forms such as `inout` are rejected.
- `key:` is required and cannot be a string literal.
- `using:` is optional, but if provided it must reference an existing store value.
- Generated wrappers enforce `Sendable` for the evaluated key and forwarded parameters.

## `@SingleFlightClass`

### What it replaces

Hand-written request coalescing in reference-type services that cannot be actors.

### Use when

Use it when a `final` checked-`Sendable` class needs single-flight behavior around async instance methods.

### Safety notes

- Deduplication is in-flight only; results are not cached after completion.
- `using:` is required and must reference an existing store value.
- Supported on nominal class instance methods, not extensions, `static`, or `class` methods.
- The enclosing class must be `final` and explicitly conform to checked `Sendable`; `@unchecked Sendable` is rejected.
- Method must be `async`; typed throws, generic methods, opaque `some` returns, and unsupported parameter forms are rejected.
- Generated wrappers enforce `Sendable` for `self`, the evaluated key, and forwarded parameters.

## `@StreamBridge`

### What it replaces

Repeated `AsyncStream` or `AsyncThrowingStream` wrappers around callback-registration APIs, including termination and token-cancellation plumbing.

### Use when

Use it to expose callback-first SDK observation APIs as structured async streams.

### Example

```swift
import ConcurrencyMacros

final class PriceFeedClient: Sendable {
    @StreamBridge(
        as: "priceStream",
        event: .label("handler"),
        cancel: .ownerMethod("stopObserving"),
        buffering: .bufferingNewest(32),
        safety: .strict
    )
    func observePrice(
        symbol: String,
        handler: @escaping @Sendable (PriceTick) -> Void
    ) -> ObservationToken {
        sdk.observePrice(symbol: symbol, handler: handler)
    }

    func stopObserving(_ token: ObservationToken) {}
}
```

### Safety notes

- Supported on nominal actor/class instance methods, not extensions, `static`, `class`, or generic methods.
- Source registration methods must be synchronous and non-throwing.
- Event callbacks must take exactly one parameter and return `Void`.
- Failure callbacks, when configured, must take one parameter and return `Void`; completion callbacks must take zero parameters and return `Void`.
- Callback selectors must refer to distinct parameters.
- Under default `.strict` safety, class owners must explicitly conform to checked `Sendable` and selected callbacks must be `@Sendable`.
- Cancellation strategies other than `.none` require non-`Void` token return types.
- `.tokenMethod` does not currently support optional token return types.
- `.ownerMethod` cancellation is class-only in v1; actor methods must use another cancellation strategy or `.none`.

## `#withTimeout`

### What it replaces

Ad hoc racing between operation tasks and sleep tasks.

### Use when

Use it around async operations that must fail fast if they exceed a deadline.

### Safety notes

- The first argument is an unlabeled `Duration`.
- Provide the operation either as a trailing closure or `operation:`, but not both.
- Timeout enforcement uses structured cancellation; non-cooperative operations may overrun while cancellation unwinds.
- Non-positive durations immediately result in timeout at runtime.

## `#retrying`

### What it replaces

Repeated retry loops, backoff calculations, jitter handling, and final-error propagation.

### Use when

Use it for transient failures where bounded retries improve success rate without hiding persistent errors.

### Safety notes

- `max:`, `backoff:`, and `jitter:` are required labeled arguments.
- Provide the operation either as a trailing closure or `operation:`, but not both.
- Invalid retry configuration throws `RetryConfigurationError` at runtime.
- After retry budget is exhausted, the operation's last thrown error is rethrown.
- External cancellation is propagated.

## `#concurrentMap`

### What it replaces

Task-group fan-out code that manually tracks indices, limits in-flight work, preserves order, and cancels remaining work after failure.

### Use when

Use it for async batch transforms where output order must match input order.

### Safety notes

- The first argument is the input collection and must be unlabeled.
- `limit:` uses `ConcurrencyLimit`; `.fixed` is clamped to at least `1`.
- `.default` resolves to `max(1, activeProcessorCount - 1)`.
- Output order is stable and matches input order.
- Throwing transforms throw the first error and cancel remaining in-flight work.

## `#concurrentCompactMap`

### What it replaces

Concurrent optional transforms plus ordered `nil` filtering.

### Use when

Use it when each input may produce an optional result and the final output should contain only non-`nil` values.

### Safety notes

- Uses the same invocation and limit semantics as `#concurrentMap`.
- `nil` transform outputs are removed from the final array.
- Throwing transforms throw the first error and cancel remaining in-flight work.
- Ordering of retained values follows input order.

## `#concurrentFlatMap`

### What it replaces

Concurrent fan-out transforms where each input yields a sequence that must be flattened in stable outer order.

### Use when

Use it when each input can produce multiple outputs and callers need a single flattened result.

### Safety notes

- Uses the same invocation and limit semantics as `#concurrentMap`.
- Outer ordering follows input order; each returned segment preserves its own internal order.
- Throwing transforms throw the first error and cancel remaining in-flight work.

## `#concurrentForEach`

### What it replaces

Task-group loops for bounded concurrent side effects where no result array is needed.

### Use when

Use it for uploads, invalidations, notifications, and other async side-effect workflows.

### Safety notes

- Uses the same invocation and limit semantics as other concurrent collection macros.
- No aggregate result is returned.
- Throwing operations throw the first error and cancel remaining in-flight work.

## Support Macros

These macros are intentionally documented as support/helper APIs and are typically used by higher-level macros or infrastructure setup:

- `@ThreadSafeInitializer`: internal initializer-body rewrite helper used by `@ThreadSafe`.
- `@ThreadSafeProperty`: internal accessor rewrite helper used by `@ThreadSafe`.
- `@StreamBridgeDefaults`: declares per-type defaults for `@StreamBridge` (`cancel`, `buffering`, `safety`).
- `@StreamToken`: synthesizes `StreamBridgeTokenCancellable` conformance by mapping a token cancel method.

## Acknowledgements

- Special thanks to [Matt Massicotte](https://www.massicotte.org/) for talks and writing that helped shape this package's Swift Concurrency approach.
- `@ThreadSafe` was inspired by the `ThreadSafe` macro in [getcmd-dev/cmd](https://github.com/getcmd-dev/cmd/blob/8286081d3bb9c688efb151c2595df825996fa838/app/modules/macros/ThreadSafe/Macro/ThreadSafe.swift). The implementation in this package is independent.

## Contributing

Contributions are welcome through issues and pull requests.

Please include:

- a clear problem statement and behavior change summary,
- risk notes for concurrency and API compatibility,
- tests or reasoning that validate the change.

## License

MIT. See [LICENSE](LICENSE).
