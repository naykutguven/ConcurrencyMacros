//
//  ConcurrencyMacros.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 09.03.26.
//

@attached(accessor)
public macro ThreadSafeProperty() = #externalMacro(module: "ConcurrencyMacrosPlugin", type: "ThreadSafePropertyMacro")
