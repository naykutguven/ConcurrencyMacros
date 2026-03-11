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
