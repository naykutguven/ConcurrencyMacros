//
//  WithTimeoutMacroTests.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 11.03.26.
//

import SwiftDiagnostics
import SwiftSyntaxMacroExpansion
import Testing
@testable import ConcurrencyMacrosImplementation

@Suite("WithTimeoutMacro")
struct WithTimeoutMacroTests {
    @Test("Expands trailing-closure invocation to runtime helper call")
    func expandsTrailingClosureInvocation() throws {
        let macroExpression = try TestSupport.parseMacroExpression(
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
                == "ConcurrencyMacros.ConcurrencyRuntime.withTimeout(.seconds(3)){tryawaitapi.fetchProfile(id:userID)}"
        )
    }

    @Test("Expands operation-argument invocation to runtime helper call")
    func expandsOperationArgumentInvocation() throws {
        let macroExpression = try TestSupport.parseMacroExpression(
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
                == "ConcurrencyMacros.ConcurrencyRuntime.withTimeout(.seconds(3),operation:{tryawaitapi.fetchProfile(id:userID)})"
        )
    }

    @Test("Expands absolute-deadline trailing-closure invocation to runtime helper call")
    func expandsAbsoluteDeadlineTrailingClosureInvocation() throws {
        let macroExpression = try TestSupport.parseMacroExpression(
            """
            #withTimeout(until: deadline) {
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
                == "ConcurrencyMacros.ConcurrencyRuntime.withTimeout(until:deadline){tryawaitapi.fetchProfile(id:userID)}"
        )
    }

    @Test("Expands tolerance argument to runtime helper call")
    func expandsToleranceArgument() throws {
        let macroExpression = try TestSupport.parseMacroExpression(
            """
            #withTimeout(until: deadline, tolerance: .milliseconds(5), operation: {
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
                == "ConcurrencyMacros.ConcurrencyRuntime.withTimeout(until:deadline,tolerance:.milliseconds(5),operation:{tryawaitapi.fetchProfile(id:userID)})"
        )
    }

    @Test("Expands custom clock argument to runtime helper call")
    func expandsCustomClockArgument() throws {
        let macroExpression = try TestSupport.parseMacroExpression(
            """
            #withTimeout(until: deadline, tolerance: .milliseconds(5), clock: clock) {
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
                == "ConcurrencyMacros.ConcurrencyRuntime.withTimeout(until:deadline,tolerance:.milliseconds(5),clock:clock){tryawaitapi.fetchProfile(id:userID)}"
        )
    }

    @Test("Expands duration, tolerance, clock, and operation arguments to runtime helper call")
    func expandsDurationToleranceClockAndOperationArguments() throws {
        let macroExpression = try TestSupport.parseMacroExpression(
            """
            #withTimeout(.seconds(3), tolerance: .milliseconds(5), clock: clock, operation: {
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
                == "ConcurrencyMacros.ConcurrencyRuntime.withTimeout(.seconds(3),tolerance:.milliseconds(5),clock:clock,operation:{tryawaitapi.fetchProfile(id:userID)})"
        )
    }

    @Test("Throws diagnostic when duration argument is missing")
    func throwsDiagnosticWhenDurationArgumentIsMissing() throws {
        let macroExpression = try TestSupport.parseMacroExpression(
            """
            #withTimeout {
                42
            }
            """
        )

        TestSupport.assertDiagnosticsError(
            from: macroExpression,
            expectedMessage: "'#withTimeout' requires a duration or deadline as its first argument.",
            expectedID: MessageID(domain: "WithTimeoutMacro", id: "missingDurationArgument"),
            expand: { expression in
                try WithTimeoutMacro.expansion(
                    of: expression,
                    in: BasicMacroExpansionContext()
                )
            }
        )
    }

    @Test("Throws diagnostic when duration argument is labeled")
    func throwsDiagnosticWhenDurationArgumentIsLabeled() throws {
        let macroExpression = try TestSupport.parseMacroExpression(
            """
            #withTimeout(duration: .seconds(3)) {
                42
            }
            """
        )

        TestSupport.assertDiagnosticsError(
            from: macroExpression,
            expectedMessage: "'#withTimeout' first argument must be an unlabeled duration or 'until:' deadline.",
            expectedID: MessageID(domain: "WithTimeoutMacro", id: "invalidFirstArgumentLabel"),
            expand: { expression in
                try WithTimeoutMacro.expansion(
                    of: expression,
                    in: BasicMacroExpansionContext()
                )
            }
        )
    }

    @Test("Throws diagnostic when invocation has too many arguments")
    func throwsDiagnosticWhenTooManyArgumentsAreProvided() throws {
        let macroExpression = try TestSupport.parseMacroExpression(
            """
            #withTimeout(.seconds(1), tolerance: .milliseconds(5), clock: clock, operation: { 1 }, operation: { 2 })
            """
        )

        TestSupport.assertDiagnosticsError(
            from: macroExpression,
            expectedMessage: "'#withTimeout' accepts at most one timeout/deadline, one 'tolerance:', one 'clock:', and one 'operation:' argument.",
            expectedID: MessageID(domain: "WithTimeoutMacro", id: "tooManyArguments"),
            expand: { expression in
                try WithTimeoutMacro.expansion(
                    of: expression,
                    in: BasicMacroExpansionContext()
                )
            }
        )
    }

    @Test("Throws diagnostic when trailing closure and operation argument are both provided")
    func throwsDiagnosticWhenOperationIsSpecifiedTwice() throws {
        let macroExpression = try TestSupport.parseMacroExpression(
            """
            #withTimeout(.seconds(3), operation: {
                1
            }) {
                2
            }
            """
        )

        TestSupport.assertDiagnosticsError(
            from: macroExpression,
            expectedMessage: "'#withTimeout' operation must be provided either as trailing closure or 'operation:' argument, not both.",
            expectedID: MessageID(domain: "WithTimeoutMacro", id: "operationClosureSpecifiedTwice"),
            expand: { expression in
                try WithTimeoutMacro.expansion(
                    of: expression,
                    in: BasicMacroExpansionContext()
                )
            }
        )
    }

    @Test("Throws diagnostic when operation argument label is invalid")
    func throwsDiagnosticWhenOperationArgumentLabelIsInvalid() throws {
        let macroExpression = try TestSupport.parseMacroExpression(
            """
            #withTimeout(.seconds(3), work: {
                42
            })
            """
        )

        TestSupport.assertDiagnosticsError(
            from: macroExpression,
            expectedMessage: "'#withTimeout' arguments after the first must be labeled 'tolerance:', 'clock:', or 'operation:'.",
            expectedID: MessageID(domain: "WithTimeoutMacro", id: "invalidArgumentLabel"),
            expand: { expression in
                try WithTimeoutMacro.expansion(
                    of: expression,
                    in: BasicMacroExpansionContext()
                )
            }
        )
    }

    @Test("Throws diagnostic when operation closure is missing")
    func throwsDiagnosticWhenOperationClosureIsMissing() throws {
        let macroExpression = try TestSupport.parseMacroExpression(
            "#withTimeout(.seconds(3))"
        )

        TestSupport.assertDiagnosticsError(
            from: macroExpression,
            expectedMessage: "'#withTimeout' requires an operation closure either as trailing closure or 'operation:' argument.",
            expectedID: MessageID(domain: "WithTimeoutMacro", id: "missingOperationClosure"),
            expand: { expression in
                try WithTimeoutMacro.expansion(
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
            #withTimeout(.seconds(3)) {
                1
            } fallback: {
                2
            }
            """
        )

        TestSupport.assertDiagnosticsError(
            from: macroExpression,
            expectedMessage: "'#withTimeout' does not support additional trailing closures.",
            expectedID: MessageID(domain: "WithTimeoutMacro", id: "additionalTrailingClosuresNotSupported"),
            expand: { expression in
                try WithTimeoutMacro.expansion(
                    of: expression,
                    in: BasicMacroExpansionContext()
                )
            }
        )
    }
}
