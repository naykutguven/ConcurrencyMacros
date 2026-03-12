//
//  ConcurrencyMacros.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 09.03.26.
//

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
