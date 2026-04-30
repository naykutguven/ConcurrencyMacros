//
//  ConcurrencyMacros.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 09.03.26.
//

import ConcurrencyMacrosRuntime

/// Expands on classes to synthesize a lock-backed internal state and lock helpers.
@attached(member, names: named(_state), named(_State), named(inLock))
@attached(memberAttribute)
public macro ThreadSafe() = #externalMacro(
    module: "ConcurrencyMacrosImplementation",
    type: "ThreadSafeMacro"
)

/// Rewrites initializer bodies so stored-property assignments populate synthesized lock state.
@attached(body)
public macro ThreadSafeInitializer(_ params: [String: Any]) = #externalMacro(
  module: "ConcurrencyMacrosImplementation",
  type: "ThreadSafeInitializerMacro"
)

/// Replaces mutable stored properties with lock-backed accessor implementations.
@attached(accessor)
public macro ThreadSafeProperty() = #externalMacro(
    module: "ConcurrencyMacrosImplementation",
    type: "ThreadSafePropertyMacro"
)

/// Deduplicates concurrent in-flight actor method work by key.
///
/// - Parameters:
///   - key: Expression used as the single-flight key. Key closures are evaluated exactly once per invocation.
///   - using: Optional explicit store expression resolvable from declaration scope
///            (for example a top-level or static store symbol).
///            If omitted, a per-method store is synthesized.
///   - policy: Cancellation policy applied when waiters cancel.
///
/// - Important: `@SingleFlightActor` only deduplicates concurrent in-flight invocations. It does not cache
///   success or failure after completion.
/// - Important: v1 scope is actor instance methods declared in nominal actor types. Extensions,
///   `nonisolated`, `static`, and `class` methods are rejected.
/// - Important: `using:` must reference an existing store value (identifier/member access), not a
///   key-path or call expression.
/// - Important: generated wrappers enforce `Sendable` for the evaluated key and forwarded parameters.
@attached(body)
@attached(peer, names: arbitrary)
public macro SingleFlightActor(
    key: Any,
    using: Any? = nil,
    policy: SingleFlightCancellationPolicy = .cancelWhenNoWaiters
) = #externalMacro(
    module: "ConcurrencyMacrosImplementation",
    type: "SingleFlightActorMacro"
)

/// Deduplicates concurrent in-flight class method work by key.
///
/// - Parameters:
///   - key: Expression used as the single-flight key. Key closures are evaluated exactly once per invocation.
///   - using: Explicit store expression resolvable from declaration scope.
///   - policy: Cancellation policy applied when waiters cancel.
///
/// - Important: `@SingleFlightClass` only deduplicates concurrent in-flight invocations. It does not cache
///   success or failure after completion.
/// - Important: v1 scope is nominal class instance methods only. Extensions, `static`, and `class` methods
///   are rejected.
/// - Important: the enclosing class must be declared `final` and explicitly conform to checked `Sendable`.
///   `@unchecked Sendable` is rejected in v1.
/// - Important: `using:` is required and must reference an existing store value (identifier/member access),
///   not a key-path or call expression.
/// - Important: generated wrappers enforce `Sendable` for `self`, the evaluated key, and forwarded parameters.
@attached(body)
@attached(peer, names: arbitrary)
public macro SingleFlightClass(
    key: Any,
    using: Any,
    policy: SingleFlightCancellationPolicy = .cancelWhenNoWaiters
) = #externalMacro(
    module: "ConcurrencyMacrosImplementation",
    type: "SingleFlightClassMacro"
)

/// Generates stream-returning wrapper methods for callback-registration APIs.
///
/// - Parameters:
///   - as: Generated stream wrapper method name.
///   - event: Callback selector producing stream events.
///   - failure: Optional callback selector producing stream failures.
///   - completion: Optional callback selector signaling stream completion.
///   - cancel: Cancellation strategy used on stream termination.
///   - buffering: Stream buffering policy.
///   - safety: Sendability enforcement mode.
///
/// - Important: v1 supports nominal type instance methods only. Extension methods are rejected.
/// - Important: Source methods must be synchronous registration APIs (non-`async`, non-`throws`).
@attached(body)
@attached(peer, names: arbitrary)
public macro StreamBridge(
    as: StaticString,
    event: StreamBridgeSelector,
    failure: StreamBridgeFailureSelector? = nil,
    completion: StreamBridgeSelector? = nil,
    cancel: StreamBridgeCancellation = .none,
    buffering: StreamBridgeBuffering = .unbounded,
    safety: StreamBridgeSafety = .strict
) = #externalMacro(
    module: "ConcurrencyMacrosImplementation",
    type: "StreamBridgeMacro"
)

/// Declares default stream-bridge options for methods in a nominal type.
///
/// Method-level `@StreamBridge` arguments override these defaults.
@attached(member, names: arbitrary)
public macro StreamBridgeDefaults(
    cancel: StreamBridgeCancellation = .none,
    buffering: StreamBridgeBuffering = .unbounded,
    safety: StreamBridgeSafety = .strict
) = #externalMacro(
    module: "ConcurrencyMacrosImplementation",
    type: "StreamBridgeDefaultsMacro"
)

/// Synthesizes `StreamBridgeTokenCancellable` conformance for token types.
///
/// - Parameter cancelMethod: Method invoked by `cancelStreamBridgeToken()`.
@attached(extension, conformances: StreamBridgeTokenCancellable, names: named(cancelStreamBridgeToken))
public macro StreamToken(cancelMethod: StaticString) = #externalMacro(
    module: "ConcurrencyMacrosImplementation",
    type: "StreamTokenMacro"
)

/// Runs an async operation with a timeout duration.
///
/// Supports either a trailing closure or an explicit `operation:` argument closure.
/// Use the unlabeled `Duration` form for relative timeouts, or `until:` for an absolute
/// `ContinuousClock.Instant` deadline.
/// The operation is transferred into a timeout-managed task, so non-`Sendable` captures are allowed
/// when the compiler can prove they are not accessed after the call.
/// - Important: Timeout is enforced by canceling the operation task when the duration elapses.
///   The timed-out operation is not awaited after cancellation, so if it does not cooperate with
///   cancellation it may continue running after the timeout is reported.
@freestanding(expression)
public macro withTimeout<T: Sendable>(
    _ duration: Duration,
    tolerance: Duration? = nil,
    operation: sending @escaping @isolated(any) () async throws -> T
) -> T = #externalMacro(
    module: "ConcurrencyMacrosImplementation",
    type: "WithTimeoutMacro"
)

/// Runs an async operation with a timeout duration measured by `clock`.
@freestanding(expression)
public macro withTimeout<T: Sendable, C: Clock>(
    _ duration: Duration,
    tolerance: Duration? = nil,
    clock: C,
    operation: sending @escaping @isolated(any) () async throws -> T
) -> T = #externalMacro(
    module: "ConcurrencyMacrosImplementation",
    type: "WithTimeoutMacro"
)

/// Runs an async operation with an absolute continuous-clock timeout deadline.
///
/// This keeps `#withTimeout` fail-fast behavior while allowing callers to compute one deadline
/// and pass it through nested operations without accumulating duration drift.
@freestanding(expression)
public macro withTimeout<T: Sendable>(
    until deadline: ContinuousClock.Instant,
    tolerance: Duration? = nil,
    operation: sending @escaping @isolated(any) () async throws -> T
) -> T = #externalMacro(
    module: "ConcurrencyMacrosImplementation",
    type: "WithTimeoutMacro"
)

/// Runs an async operation with an absolute timeout deadline interpreted by `clock`.
@freestanding(expression)
public macro withTimeout<T: Sendable, C: Clock>(
    until deadline: C.Instant,
    tolerance: Duration? = nil,
    clock: C,
    operation: sending @escaping @isolated(any) () async throws -> T
) -> T = #externalMacro(
    module: "ConcurrencyMacrosImplementation",
    type: "WithTimeoutMacro"
)

/// Retries a throwing async operation with configurable backoff and jitter.
///
/// Supports either a trailing closure or an explicit `operation:` argument closure.
///
/// - Parameters:
///   - max: Maximum number of retries after the initial attempt.
///   - backoff: Backoff strategy controlling delay between retries.
///   - jitter: Jitter strategy applied on top of backoff delay.
///   - operation: Throwing async operation to execute.
/// - Returns: The operation result.
/// - Throws: `RetryConfigurationError` for invalid retry configuration, operation-thrown errors,
///   or external cancellation.
@freestanding(expression)
public macro retrying<T>(
    max: Int,
    backoff: RetryBackoff,
    jitter: RetryJitter,
    operation: @escaping () async throws -> T
) -> T = #externalMacro(
    module: "ConcurrencyMacrosImplementation",
    type: "RetryingMacro"
)

/// Concurrently transforms collection elements while preserving input order.
///
/// Supports either a trailing closure or an explicit `transform:` argument closure.
///
/// - Parameters:
///   - input: The collection to transform.
///   - limit: Maximum number of in-flight child tasks at a time.
///   - transform: Async non-throwing transform applied to each element.
/// - Returns: A transformed array ordered like `input`.
@freestanding(expression)
public macro concurrentMap<Input: Collection, Output: Sendable>(
    _ input: Input,
    limit: ConcurrencyLimit = .default,
    transform: @escaping @Sendable (Input.Element) async -> Output
) -> [Output] = #externalMacro(
    module: "ConcurrencyMacrosImplementation",
    type: "ConcurrentMapMacro"
)

/// Concurrently transforms collection elements while preserving input order.
///
/// Supports either a trailing closure or an explicit `transform:` argument closure.
///
/// - Parameters:
///   - input: The collection to transform.
///   - limit: Maximum number of in-flight child tasks at a time.
///   - transform: Async throwing transform applied to each element.
/// - Returns: A transformed array ordered like `input`.
/// - Throws: The first error thrown by `transform`.
@freestanding(expression)
public macro concurrentMap<Input: Collection, Output: Sendable>(
    _ input: Input,
    limit: ConcurrencyLimit = .default,
    transform: @escaping @Sendable (Input.Element) async throws -> Output
) -> [Output] = #externalMacro(
    module: "ConcurrencyMacrosImplementation",
    type: "ConcurrentMapMacro"
)

/// Concurrently transforms collection elements and drops `nil` outputs.
///
/// Supports either a trailing closure or an explicit `transform:` argument closure.
///
/// - Parameters:
///   - input: The collection to transform.
///   - limit: Maximum number of in-flight child tasks at a time.
///   - transform: Async non-throwing transform that may return `nil`.
/// - Returns: A compacted array ordered like `input`.
@freestanding(expression)
public macro concurrentCompactMap<Input: Collection, Output: Sendable>(
    _ input: Input,
    limit: ConcurrencyLimit = .default,
    transform: @escaping @Sendable (Input.Element) async -> Output?
) -> [Output] = #externalMacro(
    module: "ConcurrencyMacrosImplementation",
    type: "ConcurrentCompactMapMacro"
)

/// Concurrently transforms collection elements and drops `nil` outputs.
///
/// Supports either a trailing closure or an explicit `transform:` argument closure.
///
/// - Parameters:
///   - input: The collection to transform.
///   - limit: Maximum number of in-flight child tasks at a time.
///   - transform: Async throwing transform that may return `nil`.
/// - Returns: A compacted array ordered like `input`.
/// - Throws: The first error thrown by `transform`.
@freestanding(expression)
public macro concurrentCompactMap<Input: Collection, Output: Sendable>(
    _ input: Input,
    limit: ConcurrencyLimit = .default,
    transform: @escaping @Sendable (Input.Element) async throws -> Output?
) -> [Output] = #externalMacro(
    module: "ConcurrencyMacrosImplementation",
    type: "ConcurrentCompactMapMacro"
)

/// Concurrently transforms elements into child sequences and flattens the results.
///
/// Supports either a trailing closure or an explicit `transform:` argument closure.
///
/// - Parameters:
///   - input: The collection to transform.
///   - limit: Maximum number of in-flight child tasks at a time.
///   - transform: Async non-throwing transform returning a sequence per element.
/// - Returns: A flattened array preserving outer input ordering.
@freestanding(expression)
public macro concurrentFlatMap<Input: Collection, Segment: Sequence & Sendable>(
    _ input: Input,
    limit: ConcurrencyLimit = .default,
    transform: @escaping @Sendable (Input.Element) async -> Segment
) -> [Segment.Element] = #externalMacro(
    module: "ConcurrencyMacrosImplementation",
    type: "ConcurrentFlatMapMacro"
)

/// Concurrently transforms elements into child sequences and flattens the results.
///
/// Supports either a trailing closure or an explicit `transform:` argument closure.
///
/// - Parameters:
///   - input: The collection to transform.
///   - limit: Maximum number of in-flight child tasks at a time.
///   - transform: Async throwing transform returning a sequence per element.
/// - Returns: A flattened array preserving outer input ordering.
/// - Throws: The first error thrown by `transform`.
@freestanding(expression)
public macro concurrentFlatMap<Input: Collection, Segment: Sequence & Sendable>(
    _ input: Input,
    limit: ConcurrencyLimit = .default,
    transform: @escaping @Sendable (Input.Element) async throws -> Segment
) -> [Segment.Element] = #externalMacro(
    module: "ConcurrencyMacrosImplementation",
    type: "ConcurrentFlatMapMacro"
)

/// Concurrently runs side-effectful work for each collection element.
///
/// Supports either a trailing closure or an explicit `operation:` argument closure.
///
/// - Parameters:
///   - input: The collection whose elements should be processed.
///   - limit: Maximum number of in-flight child tasks at a time.
///   - operation: Async non-throwing operation executed per element.
@freestanding(expression)
public macro concurrentForEach<Input: Collection>(
    _ input: Input,
    limit: ConcurrencyLimit = .default,
    operation: @escaping @Sendable (Input.Element) async -> Void
) -> Void = #externalMacro(
    module: "ConcurrencyMacrosImplementation",
    type: "ConcurrentForEachMacro"
)

/// Concurrently runs side-effectful work for each collection element.
///
/// Supports either a trailing closure or an explicit `operation:` argument closure.
///
/// - Parameters:
///   - input: The collection whose elements should be processed.
///   - limit: Maximum number of in-flight child tasks at a time.
///   - operation: Async throwing operation executed per element.
/// - Throws: The first error thrown by `operation`.
@freestanding(expression)
public macro concurrentForEach<Input: Collection>(
    _ input: Input,
    limit: ConcurrencyLimit = .default,
    operation: @escaping @Sendable (Input.Element) async throws -> Void
) -> Void = #externalMacro(
    module: "ConcurrencyMacrosImplementation",
    type: "ConcurrentForEachMacro"
)
