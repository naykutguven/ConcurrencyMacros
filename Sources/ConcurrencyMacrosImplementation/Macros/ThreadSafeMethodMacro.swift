//
//  ThreadSafeMethodMacro.swift
//  ConcurrencyMacros
//

import SwiftSyntax
import SwiftSyntaxMacros

/// Rewrites synchronous instance method bodies to execute under `@ThreadSafe` storage.
public struct ThreadSafeMethodMacro: BodyMacro {
    public static func expansion(
        of _: AttributeSyntax,
        providingBodyFor declaration: some DeclSyntaxProtocol & WithOptionalCodeBlockSyntax,
        in _: some MacroExpansionContext
    ) throws -> [CodeBlockItemSyntax] {
        declaration.body?.statements.compactMap { CodeBlockItemSyntax($0) } ?? []
    }
}
