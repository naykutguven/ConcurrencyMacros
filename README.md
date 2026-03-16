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

## Quick Start

Start with these flagship macros in most apps:

- `@ThreadSafe`: lock-backed mutable state with practical checked `Sendable` adoption for `final` classes.
- `@SingleFlightActor`: deduplicate in-flight actor work by key.
- `#withTimeout`: enforce a hard deadline for async operations.
- `#retrying`: recover from transient failures with explicit retry policy.
- `#concurrentMap`: run bounded concurrent fan-out while preserving input order.

```swift
import ConcurrencyMacros
import Foundation

struct Avatar: Sendable {
    let data: Data
}

protocol AvatarAPI: Sendable {
    func fetchAvatar(for userID: UUID) async throws -> Avatar
}

@ThreadSafe
final class AvatarCache: Sendable {
    var values: [UUID: Avatar] = [:]
}

actor AvatarService {
    private let api: AvatarAPI
    private let cache = AvatarCache()

    init(api: AvatarAPI) {
        self.api = api
    }

    @SingleFlightActor(key: { (userID: UUID) in userID })
    func avatar(for userID: UUID) async throws -> Avatar {
        if let cached = cache.values[userID] {
            return cached
        }

        let fetched = try await #withTimeout(.seconds(5)) {
            try await #retrying(
                max: 2,
                backoff: .exponential(initial: .milliseconds(200), multiplier: 2, maxDelay: .seconds(2)),
                jitter: .full
            ) {
                try await api.fetchAvatar(for: userID)
            }
        }

        cache.values[userID] = fetched
        return fetched
    }
}

func loadAvatars(userIDs: [UUID], service: AvatarService) async throws -> [Avatar] {
    try await #concurrentMap(userIDs, limit: .fixed(4)) { id in
        try await service.avatar(for: id)
    }
}
```

### Optional: Stream Bridging Path

If you integrate callback-first SDKs, add `@StreamBridge` as a companion flagship macro:

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

func consume(client: PriceFeedClient) async {
    for await tick in client.priceStream(symbol: "AAPL") {
        print(tick)
    }
}
```

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

### What it does

`@ThreadSafe` synthesizes lock-backed internal state and redirects mutable stored-property access through generated accessors.
It also makes adopting checked `Sendable` on stateful classes more practical by centralizing mutable state behind a synchronized, `Sendable` internal model.

### When to use

Use it when you need synchronous read/write APIs on shared mutable class state while preserving consistent lock semantics.

<details open><summary>Example</summary>

```swift
import ConcurrencyMacros

@ThreadSafe
final class SessionStore {
    var sessionsByID: [String: Session] = [:]
    var activeUserID: String?

    func upsert(_ session: Session) {
        sessionsByID[session.id] = session
    }
}
```

</details>

### Safety notes

- Intended for class declarations.
- When a class has no initializer, each mutable stored property must have a default value.
- Rewriting is applied to mutable stored properties and designated initializers; convenience initializers are not rewritten.
- The generated state container is lock-backed and `Sendable`.

## `@SingleFlightActor`

### What it does

`@SingleFlightActor` rewrites an actor instance method so concurrent calls with the same key share one in-flight operation.

### When to use

Use it for expensive actor-isolated async operations where duplicate concurrent requests should coalesce.

<details open><summary>Example</summary>

```swift
import ConcurrencyMacros

actor ProfileService {
    @SingleFlightActor(key: { (userID: Int) in userID })
    func profile(userID: Int) async throws -> Profile {
        try await api.fetchProfile(id: userID)
    }
}
```

</details>

### Safety notes

- Deduplication is in-flight only; results are not cached after completion.
- Currently supported only on nominal actor instance methods (not extensions, `static`, `class`, or `nonisolated` methods).
- Method must be `async`; typed throws, generic methods, opaque `some` returns, and unsupported parameter forms (for example `inout`) are rejected.
- `key:` is required and cannot be a string literal.
- `using:` is optional, but if provided it must reference an existing store value (identifier/member access), not key paths or call expressions.
- Generated wrappers enforce `Sendable` for the evaluated key and forwarded parameters.

## `@SingleFlightClass`

### What it does

`@SingleFlightClass` rewrites a class instance method so concurrent calls with the same key share one in-flight operation via an explicit store.

### When to use

Use it when request coalescing is needed in reference-type services that cannot be actors.

<details open><summary>Example</summary>

```swift
import ConcurrencyMacros

final class ProfileService: Sendable {
    private static let sharedFlights = ThrowingSingleFlightStore<Profile>()

    @SingleFlightClass(key: { (userID: Int) in userID }, using: Self.sharedFlights)
    func profile(userID: Int) async throws -> Profile {
        try await api.fetchProfile(id: userID)
    }
}
```

</details>

### Safety notes

- Deduplication is in-flight only; results are not cached after completion.
- `using:` is required and must reference an existing store value (identifier/member access).
- Currently supported only on nominal class instance methods (not extensions, `static`, or `class` methods).
- Enclosing class must be `final` and explicitly conform to checked `Sendable`; `@unchecked Sendable` is rejected.
- Method must be `async`; typed throws, generic methods, opaque `some` returns, and unsupported parameter forms are rejected.
- Generated wrappers enforce `Sendable` for `self`, evaluated key, and forwarded parameters.

## `@StreamBridge`

### What it does

`@StreamBridge` generates a stream-returning wrapper from a callback registration method, producing `AsyncStream` or `AsyncThrowingStream` based on selected callbacks.

### When to use

Use it when bridging callback-based SDK observation APIs to structured async stream consumption.

<details open><summary>Example</summary>

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

</details>

### Safety notes

- Currently supported on nominal actor/class instance methods only (not extensions, `static`, `class`, or generic methods).
- Source registration method must be synchronous and non-throwing.
- Event callback must take exactly one parameter and return `Void`.
- If configured, failure callback must take one parameter and return `Void`; completion callback must take zero parameters and return `Void`.
- Callback selectors must refer to distinct parameters.
- Under default `.strict` safety, class owners must explicitly conform to checked `Sendable` and selected callbacks must be `@Sendable`.
- Cancellation strategies other than `.none` require non-`Void` token return types.
- `.tokenMethod` does not currently support optional token return types.
- `.ownerMethod` cancellation is not currently supported for actor methods.

## `#withTimeout`

### What it does

`#withTimeout` runs an async operation with a deadline and throws on timeout.

### When to use

Use it around operations that must not wait indefinitely (for example network requests or remote IPC calls).

<details open><summary>Example</summary>

```swift
import ConcurrencyMacros

let payload = try await #withTimeout(.seconds(3)) {
    try await api.fetchPayload(id: requestID)
}
```

</details>

### Safety notes

- Invocation requires an unlabeled duration argument as the first parameter.
- Provide the operation either as trailing closure or `operation:`, but not both.
- Timeout enforcement is based on structured cancellation. Non-cooperative operations may overrun while cancellation unwinds.
- Non-positive durations immediately result in timeout at runtime.

## `#retrying`

### What it does

`#retrying` retries an async throwing operation using explicit retry count, backoff, and jitter policy.

### When to use

Use it for transient failures where bounded retries improve success rate without hiding persistent errors.

<details open><summary>Example</summary>

```swift
import ConcurrencyMacros

let receipt = try await #retrying(
    max: 3,
    backoff: .exponential(initial: .milliseconds(200), multiplier: 2, maxDelay: .seconds(2)),
    jitter: .full
) {
    try await api.upload(data)
}
```

</details>

### Safety notes

- `max:`, `backoff:`, and `jitter:` are required labeled arguments.
- Provide the operation either as trailing closure or `operation:`, but not both.
- Invalid retry configuration throws `RetryConfigurationError` at runtime.
- Throwing variant rethrows the last operation error after retry budget is exhausted.
- External cancellation is propagated.

## `#concurrentMap`

### What it does

`#concurrentMap` runs async transforms concurrently with a configurable in-flight limit and preserves input ordering.

### When to use

Use it for batch fetch/transform pipelines where order must match source input.

<details open><summary>Example</summary>

```swift
import ConcurrencyMacros

let metadata = try await #concurrentMap(urls, limit: .fixed(6)) { url in
    try await api.fetchMetadata(for: url)
}
```

</details>

### Safety notes

- First argument must be the input collection and must be unlabeled.
- `limit:` uses `ConcurrencyLimit`; `.fixed` is clamped to at least `1`.
- `.default` resolves to `max(1, activeProcessorCount - 1)`.
- Output order is stable and matches input order.
- Throwing transform variant throws the first error and cancels remaining in-flight work.

## `#concurrentCompactMap`

### What it does

`#concurrentCompactMap` runs async transforms concurrently, drops `nil` results, and preserves ordering among retained elements.

### When to use

Use it when each input may or may not yield a value, and output should contain only successful non-`nil` results.

<details open><summary>Example</summary>

```swift
import ConcurrencyMacros

let avatars = try await #concurrentCompactMap(users, limit: .fixed(4)) { user in
    try await avatarService.fetchAvatar(for: user.id)
}
```

</details>

### Safety notes

- Uses the same invocation and limit semantics as `#concurrentMap`.
- `nil` transform outputs are removed from the final array.
- Throwing transform variant throws the first error and cancels remaining in-flight work.
- Ordering of retained values follows input order.

## `#concurrentFlatMap`

### What it does

`#concurrentFlatMap` runs async transforms concurrently where each transform returns a sequence, then flattens segments.

### When to use

Use it when each input fan-outs to multiple outputs and you need a single flattened result.

<details open><summary>Example</summary>

```swift
import ConcurrencyMacros

let results = try await #concurrentFlatMap(providers, limit: .fixed(3)) { provider in
    try await provider.search(query: "swift")
}
```

</details>

### Safety notes

- Uses the same invocation and limit semantics as `#concurrentMap`.
- Outer ordering is preserved by input element; each returned segment preserves its own internal ordering.
- Throwing transform variant throws the first error and cancels remaining in-flight work.

## `#concurrentForEach`

### What it does

`#concurrentForEach` runs async side-effect operations concurrently with bounded in-flight work and no collected return array.

### When to use

Use it for side-effect workflows such as uploads, invalidations, or fan-out notifications.

<details open><summary>Example</summary>

```swift
import ConcurrencyMacros

try await #concurrentForEach(files, limit: .fixed(3)) { file in
    try await uploader.upload(file)
}
```

</details>

### Safety notes

- Uses the same invocation and limit semantics as other concurrent collection macros.
- No aggregate result is returned.
- Throwing operation variant throws the first error and cancels remaining in-flight work.

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
