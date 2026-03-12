//
//  ConcurrentCollectionMacros.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 12.03.26.
//

import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// Expands `#concurrentMap(...)` invocations into runtime helper calls.
public struct ConcurrentMapMacro: ExpressionMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in _: some MacroExpansionContext
    ) throws -> ExprSyntax {
        try ConcurrentCollectionMacroExpansion.expansion(
            of: node,
            configuration: .concurrentMap
        )
    }
}

/// Expands `#concurrentCompactMap(...)` invocations into runtime helper calls.
public struct ConcurrentCompactMapMacro: ExpressionMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in _: some MacroExpansionContext
    ) throws -> ExprSyntax {
        try ConcurrentCollectionMacroExpansion.expansion(
            of: node,
            configuration: .concurrentCompactMap
        )
    }
}

/// Expands `#concurrentFlatMap(...)` invocations into runtime helper calls.
public struct ConcurrentFlatMapMacro: ExpressionMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in _: some MacroExpansionContext
    ) throws -> ExprSyntax {
        try ConcurrentCollectionMacroExpansion.expansion(
            of: node,
            configuration: .concurrentFlatMap
        )
    }
}

/// Expands `#concurrentForEach(...)` invocations into runtime helper calls.
public struct ConcurrentForEachMacro: ExpressionMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in _: some MacroExpansionContext
    ) throws -> ExprSyntax {
        try ConcurrentCollectionMacroExpansion.expansion(
            of: node,
            configuration: .concurrentForEach
        )
    }
}

// MARK: - ConcurrentCollectionMacroExpansion

private enum ConcurrentCollectionMacroExpansion {
    static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        configuration: MacroConfiguration
    ) throws -> ExprSyntax {
        guard let inputArgument = node.arguments.first else {
            throw DiagnosticsError(
                syntax: node,
                domain: configuration.diagnosticDomain,
                id: "missingInputArgument",
                message: "'\(configuration.macroName)' requires a sequence as its first argument."
            )
        }

        guard inputArgument.label == nil else {
            throw DiagnosticsError(
                syntax: inputArgument,
                domain: configuration.diagnosticDomain,
                id: "inputMustBeUnlabeled",
                message: "'\(configuration.macroName)' first argument must be unlabeled."
            )
        }

        guard node.arguments.count <= 3 else {
            throw DiagnosticsError(
                syntax: node,
                domain: configuration.diagnosticDomain,
                id: "tooManyArguments",
                message: "'\(configuration.macroName)' accepts at most one sequence argument, one 'limit:' argument, and one '\(configuration.closureLabel):' argument."
            )
        }

        guard node.additionalTrailingClosures.isEmpty else {
            throw DiagnosticsError(
                syntax: node,
                domain: configuration.diagnosticDomain,
                id: "additionalTrailingClosuresNotSupported",
                message: "'\(configuration.macroName)' does not support additional trailing closures."
            )
        }

        var limitArgument: LabeledExprSyntax?
        var closureArgument: LabeledExprSyntax?

        for argument in node.arguments.dropFirst() {
            guard let label = argument.label?.text else {
                throw DiagnosticsError(
                    syntax: argument,
                    domain: configuration.diagnosticDomain,
                    id: "additionalArgumentsMustBeLabeled",
                    message: "'\(configuration.macroName)' arguments after the first must be labeled."
                )
            }

            switch label {
            case "limit":
                guard limitArgument == nil else {
                    throw DiagnosticsError(
                        syntax: argument,
                        domain: configuration.diagnosticDomain,
                        id: "duplicateLimitArgument",
                        message: "'\(configuration.macroName)' accepts at most one 'limit:' argument."
                    )
                }
                limitArgument = argument
            case configuration.closureLabel:
                guard closureArgument == nil else {
                    throw DiagnosticsError(
                        syntax: argument,
                        domain: configuration.diagnosticDomain,
                        id: "duplicateClosureArgument",
                        message: "'\(configuration.macroName)' accepts at most one '\(configuration.closureLabel):' argument."
                    )
                }
                closureArgument = argument
            default:
                throw DiagnosticsError(
                    syntax: argument,
                    domain: configuration.diagnosticDomain,
                    id: "invalidArgumentLabel",
                    message: "'\(configuration.macroName)' arguments after the first must be labeled 'limit:' or '\(configuration.closureLabel):'."
                )
            }
        }

        if closureArgument != nil, node.trailingClosure != nil {
            throw DiagnosticsError(
                syntax: node,
                domain: configuration.diagnosticDomain,
                id: "closureSpecifiedTwice",
                message: "'\(configuration.macroName)' \(configuration.closureLabel) must be provided either as trailing closure or '\(configuration.closureLabel):' argument, not both."
            )
        }

        let inputSource = inputArgument.expression.trimmedDescription
        let limitSource = limitArgument?.expression.trimmedDescription

        if let closureArgument {
            let closureSource = closureArgument.expression.trimmedDescription
            if let limitSource {
                return ExprSyntax(
                    stringLiteral: "ConcurrencyRuntime.\(configuration.runtimeFunctionName)(\(inputSource), limit: \(limitSource), \(configuration.closureLabel): \(closureSource))"
                )
            }

            return ExprSyntax(
                stringLiteral: "ConcurrencyRuntime.\(configuration.runtimeFunctionName)(\(inputSource), \(configuration.closureLabel): \(closureSource))"
            )
        }

        guard let trailingClosure = node.trailingClosure else {
            throw DiagnosticsError(
                syntax: node,
                domain: configuration.diagnosticDomain,
                id: "missingClosure",
                message: "'\(configuration.macroName)' requires \(configuration.closureLabelArticle) \(configuration.closureLabel) closure either as trailing closure or '\(configuration.closureLabel):' argument."
            )
        }

        if let limitSource {
            return ExprSyntax(
                stringLiteral: "ConcurrencyRuntime.\(configuration.runtimeFunctionName)(\(inputSource), limit: \(limitSource)) \(trailingClosure.trimmedDescription)"
            )
        }

        return ExprSyntax(
            stringLiteral: "ConcurrencyRuntime.\(configuration.runtimeFunctionName)(\(inputSource)) \(trailingClosure.trimmedDescription)"
        )
    }
}

// MARK: - MacroConfiguration

private struct MacroConfiguration {
    let macroName: String
    let runtimeFunctionName: String
    let closureLabel: String
    let diagnosticDomain: String

    var closureLabelArticle: String {
        guard let firstCharacter = closureLabel.lowercased().first else { return "a" }
        return "aeiou".contains(firstCharacter) ? "an" : "a"
    }

    static let concurrentMap = MacroConfiguration(
        macroName: "#concurrentMap",
        runtimeFunctionName: "concurrentMap",
        closureLabel: "transform",
        diagnosticDomain: "ConcurrentMapMacro"
    )

    static let concurrentCompactMap = MacroConfiguration(
        macroName: "#concurrentCompactMap",
        runtimeFunctionName: "concurrentCompactMap",
        closureLabel: "transform",
        diagnosticDomain: "ConcurrentCompactMapMacro"
    )

    static let concurrentFlatMap = MacroConfiguration(
        macroName: "#concurrentFlatMap",
        runtimeFunctionName: "concurrentFlatMap",
        closureLabel: "transform",
        diagnosticDomain: "ConcurrentFlatMapMacro"
    )

    static let concurrentForEach = MacroConfiguration(
        macroName: "#concurrentForEach",
        runtimeFunctionName: "concurrentForEach",
        closureLabel: "operation",
        diagnosticDomain: "ConcurrentForEachMacro"
    )
}

// MARK: - ConcurrentCollectionMacroDiagnostic

private struct ConcurrentCollectionMacroDiagnostic: DiagnosticMessage {
    let domain: String
    let id: String
    let message: String

    var diagnosticID: MessageID {
        MessageID(domain: domain, id: id)
    }

    var severity: DiagnosticSeverity {
        .error
    }
}

// MARK: - DiagnosticsError Extension

private extension DiagnosticsError {
    init(
        syntax: some SyntaxProtocol,
        domain: String,
        id: String,
        message: String
    ) {
        self.init(diagnostics: [
            Diagnostic(
                node: Syntax(syntax),
                message: ConcurrentCollectionMacroDiagnostic(
                    domain: domain,
                    id: id,
                    message: message
                )
            )
        ])
    }
}
