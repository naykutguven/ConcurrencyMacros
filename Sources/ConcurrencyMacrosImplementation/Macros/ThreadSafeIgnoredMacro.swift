//
//  ThreadSafeIgnoredMacro.swift
//  ConcurrencyMacros
//

import SwiftSyntax
import SwiftSyntaxMacros

/// Marker macro used by `@ThreadSafe` stored-property extraction.
public struct ThreadSafeIgnoredMacro: PeerMacro {
    public static func expansion(
        of _: AttributeSyntax,
        providingPeersOf _: some DeclSyntaxProtocol,
        in _: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}
