//
//  ThreadSafePropertyMacro.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 09.03.26.
//

import SwiftSyntaxMacros
import SwiftSyntax

/// Expands a mutable stored property into lock-backed accessors.
public struct ThreadSafePropertyMacro: AccessorMacro {
    private enum Constant {
        static let storageName = "_threadSafeStorage"
    }

    /// Produces accessor declarations that route reads and writes through internal storage.
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
            AccessorDeclSyntax(stringLiteral: "get { \(Constant.storageName).read(\\.\(identifier)) }"),
            AccessorDeclSyntax(stringLiteral: "set { \(Constant.storageName).write(\\.\(identifier), newValue) }"),
            AccessorDeclSyntax(stringLiteral: "_modify { yield &\(Constant.storageName)[modifying: \\.\(identifier)] }"),
        ]
    }
}
