//
//  VariableDeclSyntax+Extensions.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 09.03.26.
//

import Foundation
import SwiftSyntax

extension VariableDeclSyntax {
    var isMutable: Bool {
        guard
            bindingSpecifier.text == "var",
            attributes.isEmpty,
            bindings.count == 1,
            let binding = bindings.first,
            binding.accessorBlock == nil,
            let _ = binding.pattern.as(IdentifierPatternSyntax.self)
        else {
            return false
        }
        return true
    }
}
