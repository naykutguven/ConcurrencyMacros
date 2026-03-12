//
//  ConcurrentMapMacroTests.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 12.03.26.
//

import SwiftDiagnostics
import SwiftSyntaxMacroExpansion
import Testing
@testable import ConcurrencyMacrosImplementation

@Suite("ConcurrentMapMacro")
struct ConcurrentMapMacroTests {
    @Test("Expands trailing-closure invocation with explicit limit")
    func expandsTrailingClosureInvocationWithExplicitLimit() throws {
        let macroExpression = try TestSupport.parseMacroExpression(
            """
            #concurrentMap(urls, limit: 5) { url in
                try await api.fetchMetadata(for: url)
            }
            """
        )

        let expanded = try ConcurrentMapMacro.expansion(
            of: macroExpression,
            in: BasicMacroExpansionContext()
        )

        #expect(
            expanded.nonWhitespaceDescription
                == "ConcurrencyRuntime.concurrentMap(urls,limit:5){urlintryawaitapi.fetchMetadata(for:url)}"
        )
    }

    @Test("Expands labeled transform invocation and normalizes argument order")
    func expandsLabeledTransformInvocationAndNormalizesArgumentOrder() throws {
        let macroExpression = try TestSupport.parseMacroExpression(
            """
            #concurrentMap(urls, transform: { url in
                url.absoluteString
            }, limit: 2)
            """
        )

        let expanded = try ConcurrentMapMacro.expansion(
            of: macroExpression,
            in: BasicMacroExpansionContext()
        )

        #expect(
            expanded.nonWhitespaceDescription
                == "ConcurrencyRuntime.concurrentMap(urls,limit:2,transform:{urlinurl.absoluteString})"
        )
    }

    @Test("Throws diagnostic when sequence argument is missing")
    func throwsDiagnosticWhenSequenceArgumentIsMissing() throws {
        let macroExpression = try TestSupport.parseMacroExpression(
            """
            #concurrentMap {
                42
            }
            """
        )

        TestSupport.assertDiagnosticsError(
            from: macroExpression,
            expectedMessage: "'#concurrentMap' requires a sequence as its first argument.",
            expectedID: MessageID(domain: "ConcurrentMapMacro", id: "missingInputArgument"),
            expand: { expression in
                try ConcurrentMapMacro.expansion(
                    of: expression,
                    in: BasicMacroExpansionContext()
                )
            }
        )
    }

    @Test("Throws diagnostic when first argument is labeled")
    func throwsDiagnosticWhenFirstArgumentIsLabeled() throws {
        let macroExpression = try TestSupport.parseMacroExpression(
            """
            #concurrentMap(input: urls) { url in
                url
            }
            """
        )

        TestSupport.assertDiagnosticsError(
            from: macroExpression,
            expectedMessage: "'#concurrentMap' first argument must be unlabeled.",
            expectedID: MessageID(domain: "ConcurrentMapMacro", id: "inputMustBeUnlabeled"),
            expand: { expression in
                try ConcurrentMapMacro.expansion(
                    of: expression,
                    in: BasicMacroExpansionContext()
                )
            }
        )
    }

    @Test("Throws diagnostic when too many arguments are provided")
    func throwsDiagnosticWhenTooManyArgumentsAreProvided() throws {
        let macroExpression = try TestSupport.parseMacroExpression(
            """
            #concurrentMap(urls, limit: 1, transform: { $0 }, limit: 2)
            """
        )

        TestSupport.assertDiagnosticsError(
            from: macroExpression,
            expectedMessage: "'#concurrentMap' accepts at most one sequence argument, one 'limit:' argument, and one 'transform:' argument.",
            expectedID: MessageID(domain: "ConcurrentMapMacro", id: "tooManyArguments"),
            expand: { expression in
                try ConcurrentMapMacro.expansion(
                    of: expression,
                    in: BasicMacroExpansionContext()
                )
            }
        )
    }

    @Test("Throws diagnostic when additional trailing closures are provided")
    func throwsDiagnosticWhenAdditionalTrailingClosuresAreProvided() throws {
        let macroExpression = try TestSupport.parseMacroExpression(
            """
            #concurrentMap(urls) { url in
                url
            } fallback: {
                nil
            }
            """
        )

        TestSupport.assertDiagnosticsError(
            from: macroExpression,
            expectedMessage: "'#concurrentMap' does not support additional trailing closures.",
            expectedID: MessageID(domain: "ConcurrentMapMacro", id: "additionalTrailingClosuresNotSupported"),
            expand: { expression in
                try ConcurrentMapMacro.expansion(
                    of: expression,
                    in: BasicMacroExpansionContext()
                )
            }
        )
    }

    @Test("Throws diagnostic when additional arguments are unlabeled")
    func throwsDiagnosticWhenAdditionalArgumentsAreUnlabeled() throws {
        let macroExpression = try TestSupport.parseMacroExpression(
            """
            #concurrentMap(urls, { url in
                url
            })
            """
        )

        TestSupport.assertDiagnosticsError(
            from: macroExpression,
            expectedMessage: "'#concurrentMap' arguments after the first must be labeled.",
            expectedID: MessageID(domain: "ConcurrentMapMacro", id: "additionalArgumentsMustBeLabeled"),
            expand: { expression in
                try ConcurrentMapMacro.expansion(
                    of: expression,
                    in: BasicMacroExpansionContext()
                )
            }
        )
    }

    @Test("Throws diagnostic when argument label is invalid")
    func throwsDiagnosticWhenArgumentLabelIsInvalid() throws {
        let macroExpression = try TestSupport.parseMacroExpression(
            """
            #concurrentMap(urls, mode: .default) { url in
                url
            }
            """
        )

        TestSupport.assertDiagnosticsError(
            from: macroExpression,
            expectedMessage: "'#concurrentMap' arguments after the first must be labeled 'limit:' or 'transform:'.",
            expectedID: MessageID(domain: "ConcurrentMapMacro", id: "invalidArgumentLabel"),
            expand: { expression in
                try ConcurrentMapMacro.expansion(
                    of: expression,
                    in: BasicMacroExpansionContext()
                )
            }
        )
    }

    @Test("Throws diagnostic when limit argument is duplicated")
    func throwsDiagnosticWhenLimitArgumentIsDuplicated() throws {
        let macroExpression = try TestSupport.parseMacroExpression(
            """
            #concurrentMap(urls, limit: 1, limit: 2) { url in
                url
            }
            """
        )

        TestSupport.assertDiagnosticsError(
            from: macroExpression,
            expectedMessage: "'#concurrentMap' accepts at most one 'limit:' argument.",
            expectedID: MessageID(domain: "ConcurrentMapMacro", id: "duplicateLimitArgument"),
            expand: { expression in
                try ConcurrentMapMacro.expansion(
                    of: expression,
                    in: BasicMacroExpansionContext()
                )
            }
        )
    }

    @Test("Throws diagnostic when transform argument is duplicated")
    func throwsDiagnosticWhenTransformArgumentIsDuplicated() throws {
        let macroExpression = try TestSupport.parseMacroExpression(
            """
            #concurrentMap(urls, transform: { $0 }, transform: { $0 })
            """
        )

        TestSupport.assertDiagnosticsError(
            from: macroExpression,
            expectedMessage: "'#concurrentMap' accepts at most one 'transform:' argument.",
            expectedID: MessageID(domain: "ConcurrentMapMacro", id: "duplicateClosureArgument"),
            expand: { expression in
                try ConcurrentMapMacro.expansion(
                    of: expression,
                    in: BasicMacroExpansionContext()
                )
            }
        )
    }

    @Test("Throws diagnostic when transform is specified twice")
    func throwsDiagnosticWhenTransformIsSpecifiedTwice() throws {
        let macroExpression = try TestSupport.parseMacroExpression(
            """
            #concurrentMap(urls, transform: { $0 }) { url in
                url
            }
            """
        )

        TestSupport.assertDiagnosticsError(
            from: macroExpression,
            expectedMessage: "'#concurrentMap' transform must be provided either as trailing closure or 'transform:' argument, not both.",
            expectedID: MessageID(domain: "ConcurrentMapMacro", id: "closureSpecifiedTwice"),
            expand: { expression in
                try ConcurrentMapMacro.expansion(
                    of: expression,
                    in: BasicMacroExpansionContext()
                )
            }
        )
    }

    @Test("Throws diagnostic when transform closure is missing")
    func throwsDiagnosticWhenTransformClosureIsMissing() throws {
        let macroExpression = try TestSupport.parseMacroExpression(
            "#concurrentMap(urls, limit: 2)"
        )

        TestSupport.assertDiagnosticsError(
            from: macroExpression,
            expectedMessage: "'#concurrentMap' requires a transform closure either as trailing closure or 'transform:' argument.",
            expectedID: MessageID(domain: "ConcurrentMapMacro", id: "missingClosure"),
            expand: { expression in
                try ConcurrentMapMacro.expansion(
                    of: expression,
                    in: BasicMacroExpansionContext()
                )
            }
        )
    }
}
