//
//  ThreadSafeMethodMacro.swift
//  ConcurrencyMacros
//

import SwiftSyntax
import SwiftSyntaxMacros

/// Temporary pass-through shell for the `@ThreadSafe` redesign.
///
/// Task 7 adds the lock-wrapping rewrite.
public struct ThreadSafeMethodMacro: BodyMacro {
    public static func expansion(
        of _: AttributeSyntax,
        providingBodyFor declaration: some DeclSyntaxProtocol & WithOptionalCodeBlockSyntax,
        in _: some MacroExpansionContext
    ) throws -> [CodeBlockItemSyntax] {
        declaration.body?.statements.compactMap { CodeBlockItemSyntax($0) } ?? []
    }
}
