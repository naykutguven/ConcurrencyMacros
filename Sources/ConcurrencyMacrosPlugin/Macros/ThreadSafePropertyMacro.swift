//
//  ThreadSafePropertyMacro.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 09.03.26.
//

import SwiftSyntaxMacros
import SwiftSyntax

/// Expands a mutable stored property into lock-backed `get` and `set` accessors.
public struct ThreadSafePropertyMacro: AccessorMacro {
    private enum Constant {
        static let internalStateName = "_internalState"
    }

    /// Produces accessor declarations that route reads and writes through the internal mutex state.
    public static func expansion(
        of _: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in _: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        guard
            let property = declaration.as(VariableDeclSyntax.self),
            let identifier = property.bindings.first?.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
        else {
            return []
        }

        return [
            AccessorDeclSyntax(stringLiteral: "get { \(Constant.internalStateName).value.\(identifier) }"),
            AccessorDeclSyntax(stringLiteral: "set { _ = \(Constant.internalStateName).set(\\.\(identifier), to: newValue) }"),
        ]
    }
}
