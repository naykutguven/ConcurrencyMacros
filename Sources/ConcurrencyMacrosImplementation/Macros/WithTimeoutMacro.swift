//
//  WithTimeoutMacro.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 11.03.26.
//

import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// Expands `#withTimeout(duration) { ... }`, `#withTimeout(until: deadline) { ... }`,
/// and `operation:`/`tolerance:`/`clock:` variants into runtime helper calls.
public struct WithTimeoutMacro: ExpressionMacro {
    /// Validates invocation shape and returns a runtime helper call expression.
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in _: some MacroExpansionContext
    ) throws -> ExprSyntax {
        guard let timeoutArgument = node.arguments.first else {
            throw DiagnosticsError(
                syntax: node,
                id: "missingDurationArgument",
                message: "'#withTimeout' requires a duration or deadline as its first argument."
            )
        }

        let isDeadline = timeoutArgument.label?.text == "until"
        guard timeoutArgument.label == nil || isDeadline else {
            throw DiagnosticsError(
                syntax: timeoutArgument,
                id: "invalidFirstArgumentLabel",
                message: "'#withTimeout' first argument must be an unlabeled duration or 'until:' deadline."
            )
        }

        guard node.arguments.count <= 4 else {
            throw DiagnosticsError(
                syntax: node,
                id: "tooManyArguments",
                message: "'#withTimeout' accepts at most one timeout/deadline, one 'tolerance:', one 'clock:', and one 'operation:' argument."
            )
        }

        guard node.additionalTrailingClosures.isEmpty else {
            throw DiagnosticsError(
                syntax: node,
                id: "additionalTrailingClosuresNotSupported",
                message: "'#withTimeout' does not support additional trailing closures."
            )
        }

        var toleranceSource: String?
        var clockSource: String?
        var operationSource: String?

        for argument in node.arguments.dropFirst() {
            switch argument.label?.text {
            case "tolerance":
                guard toleranceSource == nil else {
                    throw DiagnosticsError(
                        syntax: argument,
                        id: "duplicateToleranceArgument",
                        message: "'#withTimeout' accepts at most one 'tolerance:' argument."
                    )
                }
                toleranceSource = argument.expression.trimmedDescription
            case "clock":
                guard clockSource == nil else {
                    throw DiagnosticsError(
                        syntax: argument,
                        id: "duplicateClockArgument",
                        message: "'#withTimeout' accepts at most one 'clock:' argument."
                    )
                }
                clockSource = argument.expression.trimmedDescription
            case "operation":
                guard operationSource == nil else {
                    throw DiagnosticsError(
                        syntax: argument,
                        id: "duplicateOperationArgument",
                        message: "'#withTimeout' accepts at most one 'operation:' argument."
                    )
                }
                operationSource = argument.expression.trimmedDescription
            default:
                throw DiagnosticsError(
                    syntax: argument,
                    id: "invalidArgumentLabel",
                    message: "'#withTimeout' arguments after the first must be labeled 'tolerance:', 'clock:', or 'operation:'."
                )
            }
        }

        let trailingClosure = node.trailingClosure
        let timeoutSource = timeoutArgument.expression.trimmedDescription

        if operationSource != nil {
            guard trailingClosure == nil else {
                throw DiagnosticsError(
                    syntax: node,
                    id: "operationClosureSpecifiedTwice",
                    message: "'#withTimeout' operation must be provided either as trailing closure or 'operation:' argument, not both."
                )
            }
        }

        guard operationSource != nil || trailingClosure != nil else {
            throw DiagnosticsError(
                syntax: node,
                id: "missingOperationClosure",
                message: "'#withTimeout' requires an operation closure either as trailing closure or 'operation:' argument."
            )
        }

        var runtimeArguments = [
            isDeadline ? "until: \(timeoutSource)" : timeoutSource
        ]
        if let toleranceSource {
            runtimeArguments.append("tolerance: \(toleranceSource)")
        }
        if let clockSource {
            runtimeArguments.append("clock: \(clockSource)")
        }
        if let operationSource {
            runtimeArguments.append("operation: \(operationSource)")
        }

        let runtimeCall = "ConcurrencyMacros.ConcurrencyRuntime.withTimeout(\(runtimeArguments.joined(separator: ", ")))"
        guard let trailingClosure else {
            return ExprSyntax(stringLiteral: runtimeCall)
        }

        return ExprSyntax(
            stringLiteral: "\(runtimeCall) \(trailingClosure.trimmedDescription)"
        )
    }
}

// MARK: - WithTimeoutMacroDiagnostic

/// Diagnostic message emitted when `#withTimeout` is invoked with invalid syntax.
private struct WithTimeoutMacroDiagnostic: DiagnosticMessage {
    /// Stable diagnostic identifier.
    let id: String

    /// Human-readable diagnostic text.
    let message: String

    /// Stable diagnostic identifier metadata for testing and tooling.
    var diagnosticID: MessageID {
        MessageID(domain: "WithTimeoutMacro", id: id)
    }

    /// Severity used for invocation validation diagnostics.
    var severity: DiagnosticSeverity {
        .error
    }
}

// MARK: - DiagnosticsError Extension

private extension DiagnosticsError {
    /// Creates a diagnostics error containing one error-level message anchored to `syntax`.
    ///
    /// - Parameters:
    ///   - syntax: The syntax node associated with the diagnostic.
    ///   - id: Stable diagnostic identifier.
    ///   - message: The diagnostic message text.
    init(syntax: some SyntaxProtocol, id: String, message: String) {
        self.init(diagnostics: [
            Diagnostic(
                node: Syntax(syntax),
                message: WithTimeoutMacroDiagnostic(id: id, message: message)
            ),
        ])
    }
}
