//
//  ConcurrentCompactMapMacroTests.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 12.03.26.
//

import SwiftSyntaxMacroExpansion
import SwiftDiagnostics
import Testing
@testable import ConcurrencyMacrosImplementation

@Suite("ConcurrentCompactMapMacro")
struct ConcurrentCompactMapMacroTests {
    @Test("Expands trailing-closure invocation")
    func expandsTrailingClosureInvocation() throws {
        let macroExpression = try TestSupport.parseMacroExpression(
            """
            #concurrentCompactMap(users, limit: 4) { user in
                try await avatarService.fetchAvatar(for: user.id)
            }
            """
        )

        let expanded = try ConcurrentCompactMapMacro.expansion(
            of: macroExpression,
            in: BasicMacroExpansionContext()
        )

        #expect(
            expanded.nonWhitespaceDescription
                == "ConcurrencyMacros.ConcurrencyRuntime.concurrentCompactMap(users,limit:4){userintryawaitavatarService.fetchAvatar(for:user.id)}"
        )
    }

    @Test("Expands labeled transform invocation")
    func expandsLabeledTransformInvocation() throws {
        let macroExpression = try TestSupport.parseMacroExpression(
            """
            #concurrentCompactMap(users, transform: { user in
                user.nickname
            })
            """
        )

        let expanded = try ConcurrentCompactMapMacro.expansion(
            of: macroExpression,
            in: BasicMacroExpansionContext()
        )

        #expect(
            expanded.nonWhitespaceDescription
                == "ConcurrencyMacros.ConcurrencyRuntime.concurrentCompactMap(users,transform:{userinuser.nickname})"
        )
    }

    @Test("Throws diagnostic when argument label is invalid")
    func throwsDiagnosticWhenArgumentLabelIsInvalid() throws {
        let macroExpression = try TestSupport.parseMacroExpression(
            """
            #concurrentCompactMap(users, mode: .default) { user in
                user.nickname
            }
            """
        )

        TestSupport.assertDiagnosticsError(
            from: macroExpression,
            expectedMessage: "'#concurrentCompactMap' arguments after the first must be labeled 'limit:' or 'transform:'.",
            expectedID: MessageID(domain: "ConcurrentCompactMapMacro", id: "invalidArgumentLabel"),
            expand: { expression in
                try ConcurrentCompactMapMacro.expansion(
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
            #concurrentCompactMap(users, transform: { $0 }, transform: { $0 })
            """
        )

        TestSupport.assertDiagnosticsError(
            from: macroExpression,
            expectedMessage: "'#concurrentCompactMap' accepts at most one 'transform:' argument.",
            expectedID: MessageID(domain: "ConcurrentCompactMapMacro", id: "duplicateClosureArgument"),
            expand: { expression in
                try ConcurrentCompactMapMacro.expansion(
                    of: expression,
                    in: BasicMacroExpansionContext()
                )
            }
        )
    }

    @Test("Throws diagnostic when transform closure is missing")
    func throwsDiagnosticWhenTransformClosureIsMissing() throws {
        let macroExpression = try TestSupport.parseMacroExpression(
            "#concurrentCompactMap(users, limit: 2)"
        )

        TestSupport.assertDiagnosticsError(
            from: macroExpression,
            expectedMessage: "'#concurrentCompactMap' requires a transform closure either as trailing closure or 'transform:' argument.",
            expectedID: MessageID(domain: "ConcurrentCompactMapMacro", id: "missingClosure"),
            expand: { expression in
                try ConcurrentCompactMapMacro.expansion(
                    of: expression,
                    in: BasicMacroExpansionContext()
                )
            }
        )
    }
}
