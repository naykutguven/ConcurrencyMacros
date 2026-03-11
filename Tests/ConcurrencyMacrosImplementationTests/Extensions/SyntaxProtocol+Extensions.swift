//
//  SyntaxProtocol+Extensions.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 09.03.26.
//

import SwiftSyntax

/// Syntax formatting helpers used by snapshot-style assertions.
extension SyntaxProtocol {
    /// Returns the syntax description with all whitespace removed.
    var nonWhitespaceDescription: String {
        description.filter { !$0.isWhitespace }
    }
}
