//
//  ConcurrencyMacrosPlugin.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 09.03.26.
//

import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct ConcurrencyMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        ThreadSafePropertyMacro.self
    ]
}
