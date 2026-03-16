//
//  StreamTokenMacro.swift
//  ConcurrencyMacrosImplementation
//
//  Created by Codex on 15.03.26.
//

import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// Synthesizes `StreamBridgeTokenCancellable` conformance for token types.
public struct StreamTokenMacro: ExtensionMacro {
    public static func expansion(
        of attribute: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo _: [TypeSyntax],
        in _: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard declaration.as(ClassDeclSyntax.self) != nil ||
                declaration.as(StructDeclSyntax.self) != nil ||
                declaration.as(EnumDeclSyntax.self) != nil
        else {
            throw DiagnosticsError(
                syntax: declaration,
                id: "invalidAttachment",
                message: "'@StreamToken' can only be attached to class, struct, or enum declarations."
            )
        }

        let cancelMethodName = try parseCancelMethodName(from: attribute)

        let extensionDeclSource = """
        extension \(type.trimmedDescription): ConcurrencyMacros.StreamBridgeTokenCancellable {
            public func cancelStreamBridgeToken() {
                self.\(cancelMethodName)()
            }
        }
        """
        guard let extensionDecl = DeclSyntax(stringLiteral: extensionDeclSource).as(ExtensionDeclSyntax.self) else {
            throw DiagnosticsError(
                syntax: declaration,
                id: "internalExtensionGenerationFailure",
                message: "'@StreamToken' failed to generate conformance extension."
            )
        }

        return [extensionDecl]
    }
}

private extension StreamTokenMacro {
    static func parseCancelMethodName(from attribute: AttributeSyntax) throws -> String {
        let argumentList = attribute.arguments?.as(LabeledExprListSyntax.self) ?? LabeledExprListSyntax([])

        var cancelMethodName: String?

        for argument in argumentList {
            guard let label = argument.label?.text else {
                throw DiagnosticsError(
                    syntax: argument,
                    id: "unlabeledArgument",
                    message: "'@StreamToken' arguments must be labeled."
                )
            }

            guard label == "cancelMethod" else {
                throw DiagnosticsError(
                    syntax: argument,
                    id: "unknownArgumentLabel",
                    message: "'@StreamToken' arguments must be labeled 'cancelMethod:'."
                )
            }

            guard cancelMethodName == nil else {
                throw DiagnosticsError(
                    syntax: argument,
                    id: "duplicateCancelMethod",
                    message: "'@StreamToken' accepts at most one 'cancelMethod:' argument."
                )
            }

            cancelMethodName = try parseMethodNameLiteral(argument.expression)
        }

        guard let cancelMethodName else {
            throw DiagnosticsError(
                syntax: attribute,
                id: "missingCancelMethod",
                message: "'@StreamToken' requires a 'cancelMethod:' argument."
            )
        }

        return cancelMethodName
    }

    static func parseMethodNameLiteral(_ expression: ExprSyntax) throws -> String {
        guard let literal = expression.as(StringLiteralExprSyntax.self),
              literal.segments.count == 1,
              let segment = literal.segments.first?.as(StringSegmentSyntax.self)
        else {
            throw DiagnosticsError(
                syntax: expression,
                id: "cancelMethodMustBeStaticString",
                message: "'@StreamToken' 'cancelMethod:' must be a static string literal."
            )
        }

        let value = segment.content.text
        guard isValidIdentifier(value) else {
            throw DiagnosticsError(
                syntax: expression,
                id: "invalidCancelMethodName",
                message: "'@StreamToken' 'cancelMethod:' must be a valid Swift identifier."
            )
        }

        return value
    }

    static func isValidIdentifier(_ candidate: String) -> Bool {
        guard let first = candidate.first else { return false }
        guard first.isLetter || first == "_" else { return false }
        return candidate.dropFirst().allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}

private struct StreamTokenMacroDiagnostic: DiagnosticMessage {
    let id: String
    let message: String

    var diagnosticID: MessageID {
        MessageID(domain: "StreamTokenMacro", id: id)
    }

    var severity: DiagnosticSeverity {
        .error
    }
}

private extension DiagnosticsError {
    init(
        syntax: some SyntaxProtocol,
        id: String,
        message: String
    ) {
        self.init(diagnostics: [
            Diagnostic(
                node: Syntax(syntax),
                message: StreamTokenMacroDiagnostic(
                    id: id,
                    message: message
                )
            )
        ])
    }
}
