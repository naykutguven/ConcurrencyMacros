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

/// Runs an async operation with a timeout duration.
///
/// Supports either a trailing closure or an explicit `operation:` argument closure.
/// - Important: Timeout is enforced via structured cancellation, so non-cancel-cooperative operations
/// may exceed the requested duration while child tasks unwind.
@freestanding(expression)
public macro withTimeout<T: Sendable>(
    _ duration: Duration,
    operation: @escaping @Sendable () async throws -> T
) -> T = #externalMacro(
    module: "ConcurrencyMacrosImplementation",
    type: "WithTimeoutMacro"
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
public macro concurrentFlatMap<Input: Collection, Segment: Sequence>(
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
public macro concurrentFlatMap<Input: Collection, Segment: Sequence>(
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
