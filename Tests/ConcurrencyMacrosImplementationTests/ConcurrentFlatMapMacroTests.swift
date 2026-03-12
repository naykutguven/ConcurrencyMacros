//
//  ConcurrentFlatMapMacroTests.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 12.03.26.
//

import SwiftSyntaxMacroExpansion
import SwiftDiagnostics
import Testing
@testable import ConcurrencyMacrosImplementation

@Suite("ConcurrentFlatMapMacro")
struct ConcurrentFlatMapMacroTests {
    @Test("Expands trailing-closure invocation")
    func expandsTrailingClosureInvocation() throws {
        let macroExpression = try TestSupport.parseMacroExpression(
            """
            #concurrentFlatMap(providers, limit: 3) { provider in
                try await provider.search(query: "swift")
            }
            """
        )

        let expanded = try ConcurrentFlatMapMacro.expansion(
            of: macroExpression,
            in: BasicMacroExpansionContext()
        )

        #expect(
            expanded.nonWhitespaceDescription
                == #"ConcurrencyRuntime.concurrentFlatMap(providers,limit:3){providerintryawaitprovider.search(query:"swift")}"#
        )
    }

    @Test("Expands labeled transform invocation")
    func expandsLabeledTransformInvocation() throws {
        let macroExpression = try TestSupport.parseMacroExpression(
            """
            #concurrentFlatMap(providers, transform: { provider in
                provider.cachedResults
            })
            """
        )

        let expanded = try ConcurrentFlatMapMacro.expansion(
            of: macroExpression,
            in: BasicMacroExpansionContext()
        )

        #expect(
            expanded.nonWhitespaceDescription
                == "ConcurrencyRuntime.concurrentFlatMap(providers,transform:{providerinprovider.cachedResults})"
        )
    }

    @Test("Throws diagnostic when argument label is invalid")
    func throwsDiagnosticWhenArgumentLabelIsInvalid() throws {
        let macroExpression = try TestSupport.parseMacroExpression(
            """
            #concurrentFlatMap(providers, mode: .default) { provider in
                provider.cachedResults
            }
            """
        )

        TestSupport.assertDiagnosticsError(
            from: macroExpression,
            expectedMessage: "'#concurrentFlatMap' arguments after the first must be labeled 'limit:' or 'transform:'.",
            expectedID: MessageID(domain: "ConcurrentFlatMapMacro", id: "invalidArgumentLabel"),
            expand: { expression in
                try ConcurrentFlatMapMacro.expansion(
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
            #concurrentFlatMap(providers, transform: { $0 }, transform: { $0 })
            """
        )

        TestSupport.assertDiagnosticsError(
            from: macroExpression,
            expectedMessage: "'#concurrentFlatMap' accepts at most one 'transform:' argument.",
            expectedID: MessageID(domain: "ConcurrentFlatMapMacro", id: "duplicateClosureArgument"),
            expand: { expression in
                try ConcurrentFlatMapMacro.expansion(
                    of: expression,
                    in: BasicMacroExpansionContext()
                )
            }
        )
    }

    @Test("Throws diagnostic when transform closure is missing")
    func throwsDiagnosticWhenTransformClosureIsMissing() throws {
        let macroExpression = try TestSupport.parseMacroExpression(
            "#concurrentFlatMap(providers, limit: 2)"
        )

        TestSupport.assertDiagnosticsError(
            from: macroExpression,
            expectedMessage: "'#concurrentFlatMap' requires a transform closure either as trailing closure or 'transform:' argument.",
            expectedID: MessageID(domain: "ConcurrentFlatMapMacro", id: "missingClosure"),
            expand: { expression in
                try ConcurrentFlatMapMacro.expansion(
                    of: expression,
                    in: BasicMacroExpansionContext()
                )
            }
        )
    }
}
