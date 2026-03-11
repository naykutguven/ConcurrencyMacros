//
//  AttributeSyntax+Extensions.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 09.03.26.
//

import SwiftSyntax
import Testing

/// Attribute helpers used by macro tests.
extension AttributeSyntax {
    /// Returns the identifier attribute name when the attribute is represented as an identifier type.
    var identifierTypeName: String? {
        attributeName.as(IdentifierTypeSyntax.self)?.name.text
    }

    /// Returns a normalized description for the first argument expression.
    ///
    /// - Returns: The non-whitespace description of the first argument expression.
    func singleArgumentExpressionDescription() throws -> String {
        let arguments = try #require(
            self.arguments?.as(LabeledExprListSyntax.self),
            "Expected attribute to have one argument"
        )
        let expression = try #require(
            arguments.first?.expression,
            "Expected attribute to include one argument expression"
        )
        return expression.nonWhitespaceDescription
    }
}
