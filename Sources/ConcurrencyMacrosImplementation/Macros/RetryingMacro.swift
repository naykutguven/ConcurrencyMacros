//
//  RetryingMacro.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 12.03.26.
//

import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// Expands `#retrying(max:backoff:jitter:) { ... }` or
/// `#retrying(max:backoff:jitter:operation:)` into runtime helper calls.
public struct RetryingMacro: ExpressionMacro {
    /// Validates invocation shape and returns a runtime helper call expression.
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in _: some MacroExpansionContext
    ) throws -> ExprSyntax {
        guard node.arguments.count <= 4 else {
            throw DiagnosticsError(
                syntax: node,
                id: "tooManyArguments",
                message: "'#retrying' accepts at most one 'max:' argument, one 'backoff:' argument, one 'jitter:' argument, and one 'operation:' argument."
            )
        }

        guard node.additionalTrailingClosures.isEmpty else {
            throw DiagnosticsError(
                syntax: node,
                id: "additionalTrailingClosuresNotSupported",
                message: "'#retrying' does not support additional trailing closures."
            )
        }

        var maxArgument: LabeledExprSyntax?
        var backoffArgument: LabeledExprSyntax?
        var jitterArgument: LabeledExprSyntax?
        var operationArgument: LabeledExprSyntax?

        for argument in node.arguments {
            guard let label = argument.label?.text else {
                throw DiagnosticsError(
                    syntax: argument,
                    id: "argumentsMustBeLabeled",
                    message: "'#retrying' arguments must be labeled."
                )
            }

            switch label {
            case "max":
                guard maxArgument == nil else {
                    throw DiagnosticsError(
                        syntax: argument,
                        id: "duplicateMaxArgument",
                        message: "'#retrying' accepts at most one 'max:' argument."
                    )
                }
                maxArgument = argument
            case "backoff":
                guard backoffArgument == nil else {
                    throw DiagnosticsError(
                        syntax: argument,
                        id: "duplicateBackoffArgument",
                        message: "'#retrying' accepts at most one 'backoff:' argument."
                    )
                }
                backoffArgument = argument
            case "jitter":
                guard jitterArgument == nil else {
                    throw DiagnosticsError(
                        syntax: argument,
                        id: "duplicateJitterArgument",
                        message: "'#retrying' accepts at most one 'jitter:' argument."
                    )
                }
                jitterArgument = argument
            case "operation":
                guard operationArgument == nil else {
                    throw DiagnosticsError(
                        syntax: argument,
                        id: "duplicateOperationArgument",
                        message: "'#retrying' accepts at most one 'operation:' argument."
                    )
                }
                operationArgument = argument
            default:
                throw DiagnosticsError(
                    syntax: argument,
                    id: "invalidArgumentLabel",
                    message: "'#retrying' arguments must be labeled 'max:', 'backoff:', 'jitter:', or 'operation:'."
                )
            }
        }

        guard let maxArgument else {
            throw DiagnosticsError(
                syntax: node,
                id: "missingMaxArgument",
                message: "'#retrying' requires a 'max:' argument."
            )
        }

        guard let backoffArgument else {
            throw DiagnosticsError(
                syntax: node,
                id: "missingBackoffArgument",
                message: "'#retrying' requires a 'backoff:' argument."
            )
        }

        guard let jitterArgument else {
            throw DiagnosticsError(
                syntax: node,
                id: "missingJitterArgument",
                message: "'#retrying' requires a 'jitter:' argument."
            )
        }

        if operationArgument != nil, node.trailingClosure != nil {
            throw DiagnosticsError(
                syntax: node,
                id: "operationSpecifiedTwice",
                message: "'#retrying' operation must be provided either as trailing closure or 'operation:' argument, not both."
            )
        }

        let maxSource = maxArgument.expression.trimmedDescription
        let backoffSource = backoffArgument.expression.trimmedDescription
        let jitterSource = jitterArgument.expression.trimmedDescription

        if let operationArgument {
            let operationSource = operationArgument.expression.trimmedDescription
            return ExprSyntax(
                stringLiteral: "ConcurrencyRuntime.retrying(max: \(maxSource), backoff: \(backoffSource), jitter: \(jitterSource), operation: \(operationSource))"
            )
        }

        guard let trailingClosure = node.trailingClosure else {
            throw DiagnosticsError(
                syntax: node,
                id: "missingOperationClosure",
                message: "'#retrying' requires an operation closure either as trailing closure or 'operation:' argument."
            )
        }

        return ExprSyntax(
            stringLiteral: "ConcurrencyRuntime.retrying(max: \(maxSource), backoff: \(backoffSource), jitter: \(jitterSource)) \(trailingClosure.trimmedDescription)"
        )
    }
}

// MARK: - RetryingMacroDiagnostic

/// Diagnostic message emitted when `#retrying` is invoked with invalid syntax.
private struct RetryingMacroDiagnostic: DiagnosticMessage {
    /// Stable diagnostic identifier.
    let id: String

    /// Human-readable diagnostic text.
    let message: String

    /// Stable diagnostic identifier metadata for testing and tooling.
    var diagnosticID: MessageID {
        MessageID(domain: "RetryingMacro", id: id)
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
                message: RetryingMacroDiagnostic(id: id, message: message)
            ),
        ])
    }
}
