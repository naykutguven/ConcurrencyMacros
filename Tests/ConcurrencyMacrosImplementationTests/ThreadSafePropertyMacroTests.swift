//
//  ThreadSafePropertyMacroTests.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 09.03.26.
//

import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import Testing
@testable import ConcurrencyMacrosImplementation

@Suite("ThreadSafePropertyMacro")
struct ThreadSafePropertyMacroTests {
    private var threadSafeAttribute: AttributeSyntax {
        AttributeSyntax(
            attributeName: IdentifierTypeSyntax(name: .identifier("ThreadSafeProperty"))
        )
    }

    @Test("Expands accessor pair for identifier pattern")
    func expandsAccessorPair() throws {
        let accessors = try expandAccessors(for: "var counter: Int")

        #expect(accessors.count == 2)
        #expect(accessors[0].nonWhitespaceDescription == "get{_state.value.counter}")
        #expect(accessors[1].nonWhitespaceDescription == "set{_=_state.set(\\.counter,to:newValue)}")
    }

    @Test("Uses first binding in a multi-binding declaration")
    func usesFirstBinding() throws {
        let accessors = try expandAccessors(for: "var first: Int, second: Int")

        #expect(accessors.count == 2)
        #expect(accessors[0].nonWhitespaceDescription == "get{_state.value.first}")
        #expect(accessors[1].nonWhitespaceDescription == "set{_=_state.set(\\.first,to:newValue)}")
    }

    @Test("Returns no accessors for non-variable declarations")
    func returnsNoAccessorsForNonVariableDeclaration() throws {
        let declaration = try firstDeclaration(in: "func performWork() {}")
        let accessors = try ThreadSafePropertyMacro.expansion(
            of: threadSafeAttribute,
            providingAccessorsOf: declaration,
            in: BasicMacroExpansionContext()
        )

        #expect(accessors.isEmpty)
    }

    @Test("Returns no accessors for non-identifier patterns")
    func returnsNoAccessorsForNonIdentifierPattern() throws {
        let accessors = try expandAccessors(for: "var (left, right): (Int, Int)")

        #expect(accessors.isEmpty)
    }
}

// MARK: - Private Helpers

private extension ThreadSafePropertyMacroTests {
    /// Expands property accessors for a declaration snippet.
    ///
    /// - Parameter declarationSource: A declaration source string to parse.
    /// - Returns: Accessors synthesized by `ThreadSafePropertyMacro`.
    func expandAccessors(for declarationSource: String) throws -> [AccessorDeclSyntax] {
        let declaration = try firstDeclaration(in: declarationSource)

        return try ThreadSafePropertyMacro.expansion(
            of: threadSafeAttribute,
            providingAccessorsOf: declaration,
            in: BasicMacroExpansionContext()
        )
    }

    /// Parses the first declaration from a Swift source snippet.
    ///
    /// - Parameter source: Source containing at least one declaration statement.
    /// - Returns: The first parsed declaration.
    func firstDeclaration(in source: String) throws -> DeclSyntax {
        let sourceFile = Parser.parse(source: source)
        let statement = try #require(
            sourceFile.statements.first,
            "Expected source to contain one statement: \(source)"
        )
        let declaration = try #require(
            statement.item.as(DeclSyntax.self),
            "Expected first statement to be a declaration: \(source)"
        )
        return declaration
    }
}
