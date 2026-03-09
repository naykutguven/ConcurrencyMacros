//
//  DeclGroupSyntax+Extensions.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 09.03.26.
//

import SwiftSyntax
import Testing

/// Declaration-group helpers used by macro tests.
extension DeclGroupSyntax {
    /// Returns the member declaration at the given zero-based index.
    ///
    /// - Parameter index: Zero-based member index in `memberBlock.members`.
    /// - Returns: The member declaration at `index`.
    func memberDecl(at index: Int) throws -> DeclSyntax {
        let memberDecl = try #require(
            memberBlock.members.dropFirst(index).first?.decl,
            "Expected declaration to contain a member at index \(index): \(self)"
        )
        return DeclSyntax(memberDecl)
    }
}
