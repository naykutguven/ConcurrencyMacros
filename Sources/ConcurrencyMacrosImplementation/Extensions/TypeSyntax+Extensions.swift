//
//  TypeSyntax+Extensions.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 09.03.26.
//

import Foundation
import SwiftSyntax

/// Type helpers used to synthesize fallback default values during macro expansion.
extension TypeSyntax {
    /// Returns a default literal for optional types and `nil` for non-optionals.
    var defaultValueForOptional: String? {
        guard self.as(OptionalTypeSyntax.self) != nil else {
            return nil
        }
        return "nil"
    }

    /// Returns a `nil` expression for optional types and `nil` for non-optionals.
    var defaultValueForOptionalExpr: ExprSyntax? {
        guard self.as(OptionalTypeSyntax.self) != nil else {
            return nil
        }
        return ExprSyntax(stringLiteral: "nil")
    }
}
