//
//  ConcurrencyMacrosPlugin.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 09.03.26.
//

import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
/// Registers macro implementations exported by the plugin target.
struct ConcurrencyMacrosPlugin: CompilerPlugin {
    /// Macro types provided by this compiler plugin.
    let providingMacros: [Macro.Type] = [
        ThreadSafeMacro.self,
        ThreadSafeInitializerMacro.self,
        ThreadSafePropertyMacro.self,
        SingleFlightActorMacro.self,
        SingleFlightClassMacro.self,
        WithTimeoutMacro.self,
        RetryingMacro.self,
        ConcurrentMapMacro.self,
        ConcurrentCompactMapMacro.self,
        ConcurrentForEachMacro.self,
        ConcurrentFlatMapMacro.self
    ]
}
