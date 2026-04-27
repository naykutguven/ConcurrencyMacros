//
//  ConcurrentForEachMacroTests.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 12.03.26.
//

import SwiftDiagnostics
import SwiftSyntaxMacroExpansion
import Testing
@testable import ConcurrencyMacrosImplementation

@Suite("ConcurrentForEachMacro")
struct ConcurrentForEachMacroTests {
    @Test("Expands trailing-closure invocation")
    func expandsTrailingClosureInvocation() throws {
        let macroExpression = try TestSupport.parseMacroExpression(
            """
            #concurrentForEach(items, limit: 2) { item in
                try await uploader.upload(item)
            }
            """
        )

        let expanded = try ConcurrentForEachMacro.expansion(
            of: macroExpression,
            in: BasicMacroExpansionContext()
        )

        #expect(
            expanded.nonWhitespaceDescription
                == "ConcurrencyMacros.ConcurrencyRuntime.concurrentForEach(items,limit:2){itemintryawaituploader.upload(item)}"
        )
    }

    @Test("Expands labeled operation invocation")
    func expandsLabeledOperationInvocation() throws {
        let macroExpression = try TestSupport.parseMacroExpression(
            """
            #concurrentForEach(items, operation: { item in
                await sink.push(item)
            })
            """
        )

        let expanded = try ConcurrentForEachMacro.expansion(
            of: macroExpression,
            in: BasicMacroExpansionContext()
        )

        #expect(
            expanded.nonWhitespaceDescription
                == "ConcurrencyMacros.ConcurrencyRuntime.concurrentForEach(items,operation:{iteminawaitsink.push(item)})"
        )
    }

    @Test("Uses operation label in missing closure diagnostics")
    func usesOperationLabelInMissingClosureDiagnostics() throws {
        let macroExpression = try TestSupport.parseMacroExpression(
            "#concurrentForEach(items, limit: 2)"
        )

        TestSupport.assertDiagnosticsError(
            from: macroExpression,
            expectedMessage: "'#concurrentForEach' requires an operation closure either as trailing closure or 'operation:' argument.",
            expectedID: MessageID(domain: "ConcurrentForEachMacro", id: "missingClosure"),
            expand: { expression in
                try ConcurrentForEachMacro.expansion(
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
            #concurrentForEach(items, mode: .default) { item in
                await sink.push(item)
            }
            """
        )

        TestSupport.assertDiagnosticsError(
            from: macroExpression,
            expectedMessage: "'#concurrentForEach' arguments after the first must be labeled 'limit:' or 'operation:'.",
            expectedID: MessageID(domain: "ConcurrentForEachMacro", id: "invalidArgumentLabel"),
            expand: { expression in
                try ConcurrentForEachMacro.expansion(
                    of: expression,
                    in: BasicMacroExpansionContext()
                )
            }
        )
    }

    @Test("Throws diagnostic when operation argument is duplicated")
    func throwsDiagnosticWhenOperationArgumentIsDuplicated() throws {
        let macroExpression = try TestSupport.parseMacroExpression(
            """
            #concurrentForEach(items, operation: { _ in }, operation: { _ in })
            """
        )

        TestSupport.assertDiagnosticsError(
            from: macroExpression,
            expectedMessage: "'#concurrentForEach' accepts at most one 'operation:' argument.",
            expectedID: MessageID(domain: "ConcurrentForEachMacro", id: "duplicateClosureArgument"),
            expand: { expression in
                try ConcurrentForEachMacro.expansion(
                    of: expression,
                    in: BasicMacroExpansionContext()
                )
            }
        )
    }
}
