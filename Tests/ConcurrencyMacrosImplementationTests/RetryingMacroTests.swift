//
//  RetryingMacroTests.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 12.03.26.
//

import SwiftDiagnostics
import SwiftSyntaxMacroExpansion
import Testing
@testable import ConcurrencyMacrosImplementation

@Suite("RetryingMacro")
struct RetryingMacroTests {
    @Test("Expands trailing-closure invocation to runtime helper call")
    func expandsTrailingClosureInvocation() throws {
        let macroExpression = try TestSupport.parseMacroExpression(
            """
            #retrying(max: 3, backoff: .exponential(initial: .milliseconds(200)), jitter: .full) {
                try await api.upload(videoData)
            }
            """
        )

        let expanded = try RetryingMacro.expansion(
            of: macroExpression,
            in: BasicMacroExpansionContext()
        )

        #expect(
            expanded.nonWhitespaceDescription
                == "ConcurrencyRuntime.retrying(max:3,backoff:.exponential(initial:.milliseconds(200)),jitter:.full){tryawaitapi.upload(videoData)}"
        )
    }

    @Test("Expands operation-argument invocation and normalizes argument order")
    func expandsOperationArgumentInvocation() throws {
        let macroExpression = try TestSupport.parseMacroExpression(
            """
            #retrying(jitter: .none, backoff: .constant(.milliseconds(25)), max: 2, operation: {
                try await api.fetchProfile(id: userID)
            })
            """
        )

        let expanded = try RetryingMacro.expansion(
            of: macroExpression,
            in: BasicMacroExpansionContext()
        )

        #expect(
            expanded.nonWhitespaceDescription
                == "ConcurrencyRuntime.retrying(max:2,backoff:.constant(.milliseconds(25)),jitter:.none,operation:{tryawaitapi.fetchProfile(id:userID)})"
        )
    }

    @Test("Throws diagnostic when max argument is missing")
    func throwsDiagnosticWhenMaxArgumentIsMissing() throws {
        let macroExpression = try TestSupport.parseMacroExpression(
            """
            #retrying(backoff: .none, jitter: .none) {
                try await work()
            }
            """
        )

        TestSupport.assertDiagnosticsError(
            from: macroExpression,
            expectedMessage: "'#retrying' requires a 'max:' argument.",
            expectedID: MessageID(domain: "RetryingMacro", id: "missingMaxArgument"),
            expand: { expression in
                try RetryingMacro.expansion(
                    of: expression,
                    in: BasicMacroExpansionContext()
                )
            }
        )
    }

    @Test("Throws diagnostic when backoff argument is missing")
    func throwsDiagnosticWhenBackoffArgumentIsMissing() throws {
        let macroExpression = try TestSupport.parseMacroExpression(
            """
            #retrying(max: 2, jitter: .none) {
                try await work()
            }
            """
        )

        TestSupport.assertDiagnosticsError(
            from: macroExpression,
            expectedMessage: "'#retrying' requires a 'backoff:' argument.",
            expectedID: MessageID(domain: "RetryingMacro", id: "missingBackoffArgument"),
            expand: { expression in
                try RetryingMacro.expansion(
                    of: expression,
                    in: BasicMacroExpansionContext()
                )
            }
        )
    }

    @Test("Throws diagnostic when jitter argument is missing")
    func throwsDiagnosticWhenJitterArgumentIsMissing() throws {
        let macroExpression = try TestSupport.parseMacroExpression(
            """
            #retrying(max: 2, backoff: .none) {
                try await work()
            }
            """
        )

        TestSupport.assertDiagnosticsError(
            from: macroExpression,
            expectedMessage: "'#retrying' requires a 'jitter:' argument.",
            expectedID: MessageID(domain: "RetryingMacro", id: "missingJitterArgument"),
            expand: { expression in
                try RetryingMacro.expansion(
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
            #retrying(max: 1, backoff: .none, jitter: .none, mode: .default) {
                try await work()
            }
            """
        )

        TestSupport.assertDiagnosticsError(
            from: macroExpression,
            expectedMessage: "'#retrying' arguments must be labeled 'max:', 'backoff:', 'jitter:', or 'operation:'.",
            expectedID: MessageID(domain: "RetryingMacro", id: "invalidArgumentLabel"),
            expand: { expression in
                try RetryingMacro.expansion(
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
            #retrying(max: 1, backoff: .none, jitter: .none, operation: { try await work() }, operation: { try await fallback() })
            """
        )

        TestSupport.assertDiagnosticsError(
            from: macroExpression,
            expectedMessage: "'#retrying' accepts at most one 'max:' argument, one 'backoff:' argument, one 'jitter:' argument, and one 'operation:' argument.",
            expectedID: MessageID(domain: "RetryingMacro", id: "tooManyArguments"),
            expand: { expression in
                try RetryingMacro.expansion(
                    of: expression,
                    in: BasicMacroExpansionContext()
                )
            }
        )
    }

    @Test("Throws diagnostic when max argument is duplicated")
    func throwsDiagnosticWhenMaxArgumentIsDuplicated() throws {
        let macroExpression = try TestSupport.parseMacroExpression(
            """
            #retrying(max: 1, backoff: .none, jitter: .none, max: 2) {
                try await work()
            }
            """
        )

        TestSupport.assertDiagnosticsError(
            from: macroExpression,
            expectedMessage: "'#retrying' accepts at most one 'max:' argument.",
            expectedID: MessageID(domain: "RetryingMacro", id: "duplicateMaxArgument"),
            expand: { expression in
                try RetryingMacro.expansion(
                    of: expression,
                    in: BasicMacroExpansionContext()
                )
            }
        )
    }

    @Test("Throws diagnostic when backoff argument is duplicated")
    func throwsDiagnosticWhenBackoffArgumentIsDuplicated() throws {
        let macroExpression = try TestSupport.parseMacroExpression(
            """
            #retrying(max: 1, backoff: .none, jitter: .none, backoff: .constant(.milliseconds(10))) {
                try await work()
            }
            """
        )

        TestSupport.assertDiagnosticsError(
            from: macroExpression,
            expectedMessage: "'#retrying' accepts at most one 'backoff:' argument.",
            expectedID: MessageID(domain: "RetryingMacro", id: "duplicateBackoffArgument"),
            expand: { expression in
                try RetryingMacro.expansion(
                    of: expression,
                    in: BasicMacroExpansionContext()
                )
            }
        )
    }

    @Test("Throws diagnostic when jitter argument is duplicated")
    func throwsDiagnosticWhenJitterArgumentIsDuplicated() throws {
        let macroExpression = try TestSupport.parseMacroExpression(
            """
            #retrying(max: 1, backoff: .none, jitter: .none, jitter: .full) {
                try await work()
            }
            """
        )

        TestSupport.assertDiagnosticsError(
            from: macroExpression,
            expectedMessage: "'#retrying' accepts at most one 'jitter:' argument.",
            expectedID: MessageID(domain: "RetryingMacro", id: "duplicateJitterArgument"),
            expand: { expression in
                try RetryingMacro.expansion(
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
            #retrying(
                max: 1,
                backoff: .none,
                operation: { try await work() },
                operation: { try await fallback() }
            )
            """
        )

        TestSupport.assertDiagnosticsError(
            from: macroExpression,
            expectedMessage: "'#retrying' accepts at most one 'operation:' argument.",
            expectedID: MessageID(domain: "RetryingMacro", id: "duplicateOperationArgument"),
            expand: { expression in
                try RetryingMacro.expansion(
                    of: expression,
                    in: BasicMacroExpansionContext()
                )
            }
        )
    }

    @Test("Throws diagnostic when operation is specified twice")
    func throwsDiagnosticWhenOperationIsSpecifiedTwice() throws {
        let macroExpression = try TestSupport.parseMacroExpression(
            """
            #retrying(max: 2, backoff: .none, jitter: .none, operation: {
                try await work()
            }) {
                try await fallback()
            }
            """
        )

        TestSupport.assertDiagnosticsError(
            from: macroExpression,
            expectedMessage: "'#retrying' operation must be provided either as trailing closure or 'operation:' argument, not both.",
            expectedID: MessageID(domain: "RetryingMacro", id: "operationSpecifiedTwice"),
            expand: { expression in
                try RetryingMacro.expansion(
                    of: expression,
                    in: BasicMacroExpansionContext()
                )
            }
        )
    }

    @Test("Throws diagnostic when operation closure is missing")
    func throwsDiagnosticWhenOperationClosureIsMissing() throws {
        let macroExpression = try TestSupport.parseMacroExpression(
            "#retrying(max: 2, backoff: .none, jitter: .none)"
        )

        TestSupport.assertDiagnosticsError(
            from: macroExpression,
            expectedMessage: "'#retrying' requires an operation closure either as trailing closure or 'operation:' argument.",
            expectedID: MessageID(domain: "RetryingMacro", id: "missingOperationClosure"),
            expand: { expression in
                try RetryingMacro.expansion(
                    of: expression,
                    in: BasicMacroExpansionContext()
                )
            }
        )
    }

    @Test("Throws diagnostic when invocation includes additional trailing closures")
    func throwsDiagnosticWhenAdditionalTrailingClosuresAreProvided() throws {
        let macroExpression = try TestSupport.parseMacroExpression(
            """
            #retrying(max: 1, backoff: .none, jitter: .none) {
                try await work()
            } fallback: {
                try await fallback()
            }
            """
        )

        TestSupport.assertDiagnosticsError(
            from: macroExpression,
            expectedMessage: "'#retrying' does not support additional trailing closures.",
            expectedID: MessageID(domain: "RetryingMacro", id: "additionalTrailingClosuresNotSupported"),
            expand: { expression in
                try RetryingMacro.expansion(
                    of: expression,
                    in: BasicMacroExpansionContext()
                )
            }
        )
    }

    @Test("Throws diagnostic when arguments are unlabeled")
    func throwsDiagnosticWhenArgumentsAreUnlabeled() throws {
        let macroExpression = try TestSupport.parseMacroExpression(
            """
            #retrying(max: 1, backoff: .none, jitter: .none, {
                try await work()
            })
            """
        )

        TestSupport.assertDiagnosticsError(
            from: macroExpression,
            expectedMessage: "'#retrying' arguments must be labeled.",
            expectedID: MessageID(domain: "RetryingMacro", id: "argumentsMustBeLabeled"),
            expand: { expression in
                try RetryingMacro.expansion(
                    of: expression,
                    in: BasicMacroExpansionContext()
                )
            }
        )
    }
}
