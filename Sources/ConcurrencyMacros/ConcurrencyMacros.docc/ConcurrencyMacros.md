# ``ConcurrencyMacros``

Production-oriented Swift Concurrency macros for thread-safe state, single-flight request coalescing, callback-to-stream bridging, timeout/retry control, and bounded concurrent collection operations.

## Overview

`ConcurrencyMacros` focuses on high-value concurrency patterns that are easy to misuse or duplicate by hand. The package exposes attached and freestanding macros with explicit scope boundaries and safety constraints.

Macro families:

- Thread safety: ``ThreadSafe()``, plus helper support from ``ThreadSafeInitializer(_:)`` and ``ThreadSafeProperty()``.
- Single flight: ``SingleFlightActor(key:using:policy:)`` and ``SingleFlightClass(key:using:policy:)``.
- Stream bridging: ``StreamBridge(as:event:failure:completion:cancel:buffering:safety:)`` with optional defaults and token helpers.
- Execution control: ``withTimeout(_:operation:)`` and ``retrying(max:backoff:jitter:operation:)``.
- Concurrent collections: ``concurrentMap(_:limit:transform:)-2ibki``, ``concurrentCompactMap(_:limit:transform:)-8aeps``, ``concurrentFlatMap(_:limit:transform:)-1n14``, and ``concurrentForEach(_:limit:operation:)-5uivq``.

## Quick Start

```swift
import ConcurrencyMacros
import Foundation

actor AvatarService {
    @SingleFlightActor(key: { (userID: UUID) in userID })
    func avatar(for userID: UUID) async throws -> Data {
        try await #withTimeout(.seconds(5)) {
            try await #retrying(
                max: 2,
                backoff: .exponential(initial: .milliseconds(200), multiplier: 2, maxDelay: .seconds(2)),
                jitter: .full
            ) {
                try await api.fetchAvatar(for: userID)
            }
        }
    }
}

func loadAvatars(ids: [UUID], service: AvatarService) async throws -> [Data] {
    try await #concurrentMap(ids, limit: .fixed(4)) { id in
        try await service.avatar(for: id)
    }
}
```

## ThreadSafe()

### What it does

Synthesizes lock-backed internal state and member rewrites so mutable stored properties are accessed through generated lock-backed accessors.

### When to use

Use when you need synchronous mutable class APIs with consistent locking during Swift Concurrency migration or shared-state hardening.

### Example

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

### Safety Notes

- Intended for class declarations.
- When the class has no initializer, mutable stored properties must have defaults.
- Rewrites apply to mutable stored properties and designated initializers; convenience initializers are not rewritten.
- Generated state is lock-backed and represented through synthesized members (`_state`, `_State`, `inLock`).

## SingleFlightActor(key:using:policy:)

### What it does

Coalesces concurrent in-flight actor instance method invocations by key so waiters share one leader operation.

### When to use

Use for actor-isolated async work where duplicate concurrent calls for the same key should not execute duplicate upstream work.

### Example

```swift
import ConcurrencyMacros

actor ProfileService {
    @SingleFlightActor(key: { (userID: Int) in userID })
    func profile(userID: Int) async throws -> Profile {
        try await api.fetchProfile(id: userID)
    }
}
```

### Safety Notes

- Deduplication is in-flight only; there is no post-completion success/failure cache.
- Currently supports nominal actor instance methods only; extensions, `static`, `class`, and `nonisolated` methods are rejected.
- Method must be `async`; typed throws, generic methods, opaque `some` return types, and unsupported parameter forms are rejected.
- `key:` is required and string-literal keys are rejected.
- `using:` is optional, but if provided must reference an existing store value (identifier/member access), not key-paths or call expressions.
- Generated wrappers enforce `Sendable` for evaluated key and forwarded parameters.

## SingleFlightClass(key:using:policy:)

### What it does

Coalesces concurrent in-flight class instance method invocations by key using an explicit single-flight store.

### When to use

Use when single-flight behavior is needed in reference-type services that are not actors.

### Example

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

### Safety Notes

- Deduplication is in-flight only; there is no post-completion success/failure cache.
- `using:` is required and must reference an existing store value (identifier/member access).
- Currently supports nominal class instance methods only; extensions, `static`, and `class` methods are rejected.
- Enclosing class must be `final` and explicitly conform to checked `Sendable`; `@unchecked Sendable` is rejected.
- Method must be `async`; typed throws, generic methods, opaque `some` return types, and unsupported parameter forms are rejected.
- Generated wrappers enforce `Sendable` for `self`, evaluated key, and forwarded parameters.

## StreamBridge(as:event:failure:completion:cancel:buffering:safety:)

### What it does

Generates stream-returning wrappers from callback registration methods, producing `AsyncStream` or `AsyncThrowingStream` based on selected callbacks.

### When to use

Use to bridge callback-based observation APIs into structured stream consumption.

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

### Safety Notes

- Currently supports nominal actor/class instance methods only; extensions and `static`/`class` methods are rejected.
- Source registration method must be synchronous and non-throwing.
- Event callback must have one parameter and return `Void`.
- If configured, failure callback must have one parameter and return `Void`; completion callback must have zero parameters and return `Void`.
- Callback selectors must refer to distinct parameters.
- Under `.strict` safety, selected callbacks must be `@Sendable`; for class owners, explicit checked `Sendable` conformance is required and `@unchecked Sendable` is rejected.
- Cancellation strategies other than `.none` require non-`Void` token return types.
- `.tokenMethod` does not currently support optional token return types.
- `.ownerMethod` cancellation is not currently supported on actor methods.

## withTimeout(_:operation:)

### What it does

Executes an async operation with timeout enforcement.

### When to use

Use for operations that must fail fast if they exceed a deadline.

### Example

```swift
import ConcurrencyMacros

let payload = try await #withTimeout(.seconds(3)) {
    try await api.fetchPayload(id: requestID)
}
```

### Safety Notes

- Invocation requires an unlabeled duration as the first argument.
- Operation must be supplied exactly once: trailing closure or `operation:` argument.
- Additional trailing closures are rejected.
- The operation is transferred into a timeout task; non-`Sendable` captures are accepted when they are not used after the call.
- Timeout is enforced by requesting cooperative cancellation; `withTimeout` throws the timeout error without awaiting the operation task's completion, and non-cancel-cooperative work may continue running after the timeout error is thrown.
- Non-positive durations fail with timeout at runtime.

## retrying(max:backoff:jitter:operation:)

### What it does

Retries an async throwing operation using explicit retry count, backoff strategy, and jitter strategy.

### When to use

Use for transient failures where bounded retries are desirable.

### Example

```swift
import ConcurrencyMacros

let value = try await #retrying(
    max: 3,
    backoff: .exponential(initial: .milliseconds(200), multiplier: 2, maxDelay: .seconds(2)),
    jitter: .full
) {
    try await api.upload(data)
}
```

### Safety Notes

- `max:`, `backoff:`, and `jitter:` are required labeled arguments.
- Operation must be supplied exactly once: trailing closure or `operation:` argument.
- Additional trailing closures are rejected.
- Invalid retry configuration throws ``RetryConfigurationError`` at runtime.
- After retry budget is exhausted, the operation’s last thrown error is rethrown.
- External cancellation is propagated.

## concurrentMap(_:limit:transform:)

### What it does

Concurrently transforms collection elements while preserving input order.

### When to use

Use for async batch transforms where output ordering must match source ordering.

### Example

```swift
import ConcurrencyMacros

let metadata = try await #concurrentMap(urls, limit: .fixed(6)) { url in
    try await api.fetchMetadata(for: url)
}
```

### Safety Notes

- First argument is required input collection and must be unlabeled.
- `limit:` is optional and uses ``ConcurrencyLimit``; `.fixed` values are clamped to at least `1`.
- ``ConcurrencyLimit`` `.default` resolves to `max(1, activeProcessorCount - 1)`.
- Output ordering is stable and matches input ordering.
- Throwing transforms throw the first error and cancel remaining in-flight work.

## concurrentCompactMap(_:limit:transform:)

### What it does

Concurrently transforms collection elements, discarding `nil` outputs while preserving ordering of retained values.

### When to use

Use when each input may produce an optional result and final output should contain only non-`nil` values.

### Example

```swift
import ConcurrencyMacros

let avatars = try await #concurrentCompactMap(users, limit: .fixed(4)) { user in
    try await avatarService.fetchAvatar(for: user.id)
}
```

### Safety Notes

- First argument is required input collection and must be unlabeled.
- `limit:` is optional and uses ``ConcurrencyLimit`` semantics.
- `nil` values are removed from the final output.
- Throwing transforms throw the first error and cancel remaining in-flight work.
- Ordering of retained values follows input ordering.

## concurrentFlatMap(_:limit:transform:)

### What it does

Concurrently transforms collection elements into child sequences, then flattens those segments.

### When to use

Use for fan-out transforms where each input yields multiple outputs.

### Example

```swift
import ConcurrencyMacros

let results = try await #concurrentFlatMap(providers, limit: .fixed(3)) { provider in
    try await provider.search(query: "swift")
}
```

### Safety Notes

- First argument is required input collection and must be unlabeled.
- `limit:` is optional and uses ``ConcurrencyLimit`` semantics.
- Flattening preserves outer input order; each segment preserves its own element order.
- Throwing transforms throw the first error and cancel remaining in-flight work.

## concurrentForEach(_:limit:operation:)

### What it does

Concurrently executes side-effectful operations for each collection element.

### When to use

Use when you need bounded fan-out side effects and no collected output array.

### Example

```swift
import ConcurrencyMacros

try await #concurrentForEach(files, limit: .fixed(3)) { file in
    try await uploader.upload(file)
}
```

### Safety Notes

- First argument is required input collection and must be unlabeled.
- `limit:` is optional and uses ``ConcurrencyLimit`` semantics.
- No aggregate result is returned.
- Throwing operations throw the first error and cancel remaining in-flight work.

## Support Macros

The following macros are helper/support APIs and are documented here without inline examples:

- ``ThreadSafeInitializer(_:)``: initializer-body rewrite helper used by ``ThreadSafe()``.
- ``ThreadSafeProperty()``: accessor rewrite helper used by ``ThreadSafe()``.
- ``StreamBridgeDefaults(cancel:buffering:safety:)``: default stream-bridge options for enclosing nominal types.
- ``StreamToken(cancelMethod:)``: synthesizes ``StreamBridgeTokenCancellable`` conformance for token types.

## Topics

### Thread Safety

- ``ThreadSafe()``
- ``ThreadSafeInitializer(_:)``
- ``ThreadSafeProperty()``

### Single Flight

- ``SingleFlightActor(key:using:policy:)``
- ``SingleFlightClass(key:using:policy:)``

### Stream Bridging

- ``StreamBridge(as:event:failure:completion:cancel:buffering:safety:)``
- ``StreamBridgeDefaults(cancel:buffering:safety:)``
- ``StreamToken(cancelMethod:)``

### Execution Control

- ``withTimeout(_:operation:)``
- ``retrying(max:backoff:jitter:operation:)``

### Concurrent Collections

- ``concurrentMap(_:limit:transform:)-2ibki``
- ``concurrentCompactMap(_:limit:transform:)-8aeps``
- ``concurrentFlatMap(_:limit:transform:)-1n14``
- ``concurrentForEach(_:limit:operation:)-5uivq``
