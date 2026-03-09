//
//  TypeSyntax+Extensions.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 09.03.26.
//

import Foundation
import SwiftSyntax

extension TypeSyntax {
    var defaultValueForOptional: String? {
        guard self.as(OptionalTypeSyntax.self) != nil else {
            return nil
        }
        return "nil"
    }
}
