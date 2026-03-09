//
//  ConcurrencyMacros.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 09.03.26.
//

@attached(member, names: named(_internalState), named(_InternalState), named(inLock))
@attached(memberAttribute)
public macro ThreadSafe() = #externalMacro(
    module: "ConcurrencyMacrosPlugin",
    type: "ThreadSafeMacro"
)

@attached(body)
public macro ThreadSafeInitializer(_ params: [String: Any]) = #externalMacro(
  module: "ConcurrencyMacrosPlugin",
  type: "ThreadSafeInitializerMacro"
)

@attached(accessor)
public macro ThreadSafeProperty() = #externalMacro(
    module: "ConcurrencyMacrosPlugin",
    type: "ThreadSafePropertyMacro"
)
