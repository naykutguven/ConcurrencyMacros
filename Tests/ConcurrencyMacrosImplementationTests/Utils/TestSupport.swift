//
//  TestSupport.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 12.03.26.
//

import SwiftDiagnostics
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import Testing

enum TestSupport {
    static func firstAttributedFunction(in source: String) throws -> FunctionDeclSyntax {
        let sourceFile = Parser.parse(source: source)

        for statement in sourceFile.statements {
            if let function = statement.item.as(FunctionDeclSyntax.self),
               function.attributes.first?.as(AttributeSyntax.self) != nil
            {
                return function
            }

            if let actor = statement.item.as(ActorDeclSyntax.self),
               let function = actor.memberBlock.members
                   .compactMap({ $0.decl.as(FunctionDeclSyntax.self) })
                   .first(where: { $0.attributes.first?.as(AttributeSyntax.self) != nil })
            {
                return function
            }

            if let structure = statement.item.as(StructDeclSyntax.self),
               let function = structure.memberBlock.members
                   .compactMap({ $0.decl.as(FunctionDeclSyntax.self) })
                   .first(where: { $0.attributes.first?.as(AttributeSyntax.self) != nil })
            {
                return function
            }

            if let ext = statement.item.as(ExtensionDeclSyntax.self),
               let function = ext.memberBlock.members
                   .compactMap({ $0.decl.as(FunctionDeclSyntax.self) })
                   .first(where: { $0.attributes.first?.as(AttributeSyntax.self) != nil })
            {
                return function
            }
        }

        Issue.record("Expected source to include an attributed function declaration: \(source)")
        throw Failure()
    }

    static func firstAttribute(in function: FunctionDeclSyntax) throws -> AttributeSyntax {
        try #require(
            function.attributes.first?.as(AttributeSyntax.self),
            "Expected function to contain an attribute"
        )
    }

    static func parseMacroExpression(_ source: String) throws -> MacroExpansionExprSyntax {
        let sourceFile = Parser.parse(source: source)
        let statement = try #require(
            sourceFile.statements.first,
            "Expected source to contain at least one statement: \(source)"
        )
        let expression = try #require(
            statement.item.as(ExprSyntax.self),
            "Expected first statement to be an expression: \(source)"
        )
        return try #require(
            expression.as(MacroExpansionExprSyntax.self),
            "Expected first expression to be a macro expansion: \(source)"
        )
    }

    static func assertDiagnosticsError(
        from macroExpression: MacroExpansionExprSyntax,
        expectedMessage: String,
        expectedID: MessageID,
        expand: (MacroExpansionExprSyntax) throws -> ExprSyntax
    ) {
        do {
            _ = try expand(macroExpression)
            Issue.record("Expected diagnostics error to be thrown")
        } catch let error as DiagnosticsError {
            guard let diagnostic = error.diagnostics.first else {
                Issue.record("Expected at least one diagnostic")
                return
            }

            #expect(diagnostic.message == expectedMessage)
            #expect(diagnostic.diagMessage.severity == .error)
            #expect(diagnostic.diagMessage.diagnosticID == expectedID)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    struct Failure: Error {}
}
