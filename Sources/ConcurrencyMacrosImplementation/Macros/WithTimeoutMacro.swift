//
//  WithTimeoutMacro.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 11.03.26.
//

import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// Expands `#withTimeout(duration) { ... }` or
/// `#withTimeout(duration, operation: { ... })` into runtime helper calls.
public struct WithTimeoutMacro: ExpressionMacro {
    /// Validates invocation shape and returns a runtime helper call expression.
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in _: some MacroExpansionContext
    ) throws -> ExprSyntax {
        guard let durationArgument = node.arguments.first else {
            throw DiagnosticsError(
                syntax: node,
                id: "missingDurationArgument",
                message: "'#withTimeout' requires a duration as its first argument."
            )
        }

        guard durationArgument.label == nil else {
            throw DiagnosticsError(
                syntax: durationArgument,
                id: "durationMustBeUnlabeled",
                message: "'#withTimeout' duration argument must be unlabeled."
            )
        }

        guard node.arguments.count <= 2 else {
            throw DiagnosticsError(
                syntax: node,
                id: "tooManyArguments",
                message: "'#withTimeout' accepts at most one duration and one 'operation' argument."
            )
        }

        guard node.additionalTrailingClosures.isEmpty else {
            throw DiagnosticsError(
                syntax: node,
                id: "additionalTrailingClosuresNotSupported",
                message: "'#withTimeout' does not support additional trailing closures."
            )
        }

        let operationArgument = node.arguments.dropFirst().first
        let trailingClosure = node.trailingClosure
        let durationSource = durationArgument.expression.trimmedDescription

        if let operationArgument {
            guard operationArgument.label?.text == "operation" else {
                throw DiagnosticsError(
                    syntax: operationArgument,
                    id: "invalidOperationArgumentLabel",
                    message: "'#withTimeout' second argument must be labeled 'operation:'."
                )
            }

            guard trailingClosure == nil else {
                throw DiagnosticsError(
                    syntax: node,
                    id: "operationClosureSpecifiedTwice",
                    message: "'#withTimeout' operation must be provided either as trailing closure or 'operation:' argument, not both."
                )
            }

            let operationSource = operationArgument.expression.trimmedDescription
            return ExprSyntax(
                stringLiteral: "ConcurrencyMacros.ConcurrencyRuntime.withTimeout(\(durationSource), operation: \(operationSource))"
            )
        }

        guard let trailingClosure else {
            throw DiagnosticsError(
                syntax: node,
                id: "missingOperationClosure",
                message: "'#withTimeout' requires an operation closure either as trailing closure or 'operation:' argument."
            )
        }

        return ExprSyntax(
            stringLiteral: "ConcurrencyMacros.ConcurrencyRuntime.withTimeout(\(durationSource)) \(trailingClosure.trimmedDescription)"
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
