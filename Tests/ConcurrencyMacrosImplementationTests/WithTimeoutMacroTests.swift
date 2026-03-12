//
//  WithTimeoutMacroTests.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 11.03.26.
//

import SwiftDiagnostics
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import Testing
@testable import ConcurrencyMacrosImplementation

@Suite("WithTimeoutMacro")
struct WithTimeoutMacroTests {
    @Test("Expands trailing-closure invocation to runtime helper call")
    func expandsTrailingClosureInvocation() throws {
        let macroExpression = try parseMacroExpression(
            """
            #withTimeout(.seconds(3)) {
                try await api.fetchProfile(id: userID)
            }
            """
        )

        let expanded = try WithTimeoutMacro.expansion(
            of: macroExpression,
            in: BasicMacroExpansionContext()
        )

        #expect(
            expanded.nonWhitespaceDescription
                == "ConcurrencyRuntime.withTimeout(.seconds(3)){tryawaitapi.fetchProfile(id:userID)}"
        )
    }

    @Test("Expands operation-argument invocation to runtime helper call")
    func expandsOperationArgumentInvocation() throws {
        let macroExpression = try parseMacroExpression(
            """
            #withTimeout(.seconds(3), operation: {
                try await api.fetchProfile(id: userID)
            })
            """
        )

        let expanded = try WithTimeoutMacro.expansion(
            of: macroExpression,
            in: BasicMacroExpansionContext()
        )

        #expect(
            expanded.nonWhitespaceDescription
                == "ConcurrencyRuntime.withTimeout(.seconds(3),operation:{tryawaitapi.fetchProfile(id:userID)})"
        )
    }

    @Test("Throws diagnostic when duration argument is missing")
    func throwsDiagnosticWhenDurationArgumentIsMissing() throws {
        let macroExpression = try parseMacroExpression(
            """
            #withTimeout {
                42
            }
            """
        )

        assertDiagnosticsError(
            from: macroExpression,
            expectedMessage: "'#withTimeout' requires a duration as its first argument.",
            expectedID: MessageID(domain: "WithTimeoutMacro", id: "missingDurationArgument")
        )
    }

    @Test("Throws diagnostic when duration argument is labeled")
    func throwsDiagnosticWhenDurationArgumentIsLabeled() throws {
        let macroExpression = try parseMacroExpression(
            """
            #withTimeout(duration: .seconds(3)) {
                42
            }
            """
        )

        assertDiagnosticsError(
            from: macroExpression,
            expectedMessage: "'#withTimeout' duration argument must be unlabeled.",
            expectedID: MessageID(domain: "WithTimeoutMacro", id: "durationMustBeUnlabeled")
        )
    }

    @Test("Throws diagnostic when invocation has too many arguments")
    func throwsDiagnosticWhenTooManyArgumentsAreProvided() throws {
        let macroExpression = try parseMacroExpression(
            """
            #withTimeout(.seconds(1), operation: { 1 }, operation: { 2 })
            """
        )

        assertDiagnosticsError(
            from: macroExpression,
            expectedMessage: "'#withTimeout' accepts at most one duration and one 'operation' argument.",
            expectedID: MessageID(domain: "WithTimeoutMacro", id: "tooManyArguments")
        )
    }

    @Test("Throws diagnostic when trailing closure and operation argument are both provided")
    func throwsDiagnosticWhenOperationIsSpecifiedTwice() throws {
        let macroExpression = try parseMacroExpression(
            """
            #withTimeout(.seconds(3), operation: {
                1
            }) {
                2
            }
            """
        )

        assertDiagnosticsError(
            from: macroExpression,
            expectedMessage: "'#withTimeout' operation must be provided either as trailing closure or 'operation:' argument, not both.",
            expectedID: MessageID(domain: "WithTimeoutMacro", id: "operationClosureSpecifiedTwice")
        )
    }

    @Test("Throws diagnostic when operation argument label is invalid")
    func throwsDiagnosticWhenOperationArgumentLabelIsInvalid() throws {
        let macroExpression = try parseMacroExpression(
            """
            #withTimeout(.seconds(3), work: {
                42
            })
            """
        )

        assertDiagnosticsError(
            from: macroExpression,
            expectedMessage: "'#withTimeout' second argument must be labeled 'operation:'.",
            expectedID: MessageID(domain: "WithTimeoutMacro", id: "invalidOperationArgumentLabel")
        )
    }

    @Test("Throws diagnostic when operation closure is missing")
    func throwsDiagnosticWhenOperationClosureIsMissing() throws {
        let macroExpression = try parseMacroExpression("#withTimeout(.seconds(3))")

        assertDiagnosticsError(
            from: macroExpression,
            expectedMessage: "'#withTimeout' requires an operation closure either as trailing closure or 'operation:' argument.",
            expectedID: MessageID(domain: "WithTimeoutMacro", id: "missingOperationClosure")
        )
    }

    @Test("Throws diagnostic when invocation includes additional trailing closures")
    func throwsDiagnosticWhenAdditionalTrailingClosuresAreProvided() throws {
        let macroExpression = try parseMacroExpression(
            """
            #withTimeout(.seconds(3)) {
                1
            } fallback: {
                2
            }
            """
        )

        assertDiagnosticsError(
            from: macroExpression,
            expectedMessage: "'#withTimeout' does not support additional trailing closures.",
            expectedID: MessageID(domain: "WithTimeoutMacro", id: "additionalTrailingClosuresNotSupported")
        )
    }
}

// MARK: - Private Helpers

private extension WithTimeoutMacroTests {
    /// Parses a freestanding macro expression from source text.
    ///
    /// - Parameter source: Source containing one top-level expression statement.
    /// - Returns: Parsed `MacroExpansionExprSyntax`.
    func parseMacroExpression(_ source: String) throws -> MacroExpansionExprSyntax {
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

    /// Asserts that `WithTimeoutMacro` expansion fails with one diagnostics error.
    ///
    /// - Parameters:
    ///   - macroExpression: Parsed macro expression.
    ///   - expectedMessage: Expected diagnostic text.
    ///   - expectedID: Expected stable diagnostic identifier.
    func assertDiagnosticsError(
        from macroExpression: MacroExpansionExprSyntax,
        expectedMessage: String,
        expectedID: MessageID
    ) {
        do {
            _ = try WithTimeoutMacro.expansion(
                of: macroExpression,
                in: BasicMacroExpansionContext()
            )
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
}
