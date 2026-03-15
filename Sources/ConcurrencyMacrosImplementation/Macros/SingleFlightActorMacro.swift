//
//  SingleFlightActorMacro.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 15.03.26.
//

import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// Rewrites actor instance methods to deduplicate concurrent in-flight work by key.
public struct SingleFlightActorMacro: BodyMacro, PeerMacro {
    public static func expansion(
        of attribute: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let method = try validatedMethod(
            from: declaration,
            attribute: attribute,
            context: context
        )

        var peers: [DeclSyntax] = []

        if method.arguments.usingExpression == nil {
            let storeTypeName = method.function.isThrowingFunction
                ? "ConcurrencyMacros.ThrowingSingleFlightStore<\(method.function.returnTypeSource)>"
                : "ConcurrencyMacros.SingleFlightStore<\(method.function.returnTypeSource)>"
            peers.append(
                DeclSyntax(stringLiteral: "private let \(method.synthesizedStoreName): \(storeTypeName) = \(storeTypeName)()")
            )
        }

        peers.append(
            implementationMethodDecl(
                for: method.function,
                implementationName: method.synthesizedImplementationName
            )
        )

        return peers
    }

    public static func expansion(
        of attribute: AttributeSyntax,
        providingBodyFor declaration: some DeclSyntaxProtocol & WithOptionalCodeBlockSyntax,
        in context: some MacroExpansionContext
    ) throws -> [CodeBlockItemSyntax] {
        // Peer expansion is responsible for diagnostics to avoid duplicate messages.
        guard let function = declaration.as(FunctionDeclSyntax.self),
              let method = try? validatedMethod(
                  from: function,
                  attribute: attribute,
                  context: context
              )
        else {
            return declaration.body?.statements.compactMap { CodeBlockItemSyntax($0) } ?? []
        }

        let keyExpressionSource = evaluatedKeyExpressionSource(
            from: method.arguments.keyExpression,
            for: function
        )
        let storeExpressionSource = storeExpressionSource(
            from: method.arguments.usingExpression,
            fallbackStoreName: method.synthesizedStoreName
        )
        let invocationPrefix = function.isThrowingFunction ? "try await" : "await"
        let helperInvocationPrefix = function.isThrowingFunction ? "try await" : "await"
        let operationTypeSource = function.isThrowingFunction
            ? "@Sendable () async throws -> \(function.returnTypeSource)"
            : "@Sendable () async -> \(function.returnTypeSource)"
        let sendabilityCheckStatements = sendabilityCheckStatements(for: function)
        let forwardedArgumentsSource = function.singleFlightForwardedArgumentsSource
        let implementationInvocationSource: String = {
            if forwardedArgumentsSource.isEmpty {
                return "self.\(method.synthesizedImplementationName)()"
            }
            return "self.\(method.synthesizedImplementationName)(\(forwardedArgumentsSource))"
        }()
        let operationInvocationSource = implementationInvocationSource.replacingOccurrences(
            of: "self.",
            with: "__singleFlightActor."
        )
        let runArgumentsSource: String = {
            guard let policyExpression = method.arguments.policyExpression else {
                return "key: __singleFlightKey"
            }

            return """
            key: __singleFlightKey,
                        policy: \(policyExpression.trimmedDescription)
            """
        }()

        var bodyItems: [CodeBlockItemSyntax] = [
            CodeBlockItemSyntax(stringLiteral: "let __singleFlightKey = \(keyExpressionSource)")
        ]

        bodyItems.append(contentsOf: sendabilityCheckStatements.map { statement in
            CodeBlockItemSyntax(stringLiteral: statement)
        })

        bodyItems.append(
            CodeBlockItemSyntax(stringLiteral: "let __singleFlightActor = self")
        )
        bodyItems.append(
            CodeBlockItemSyntax(stringLiteral: """
            let __singleFlightOperation: \(operationTypeSource) = {
                return \(helperInvocationPrefix) \(operationInvocationSource)
            }
            """)
        )
        bodyItems.append(
            CodeBlockItemSyntax(stringLiteral: """
            return \(invocationPrefix) \(storeExpressionSource).run(
                \(runArgumentsSource),
                operation: __singleFlightOperation
            )
            """)
        )

        return bodyItems
    }
}

private extension SingleFlightActorMacro {
    struct MethodContext {
        let function: FunctionDeclSyntax
        let arguments: ParsedArguments
        let synthesizedStoreName: String
        let synthesizedImplementationName: String
    }

    struct ParsedArguments {
        let keyExpression: ExprSyntax
        let usingExpression: ExprSyntax?
        let policyExpression: ExprSyntax?
    }

    static func validatedMethod(
        from declaration: some DeclSyntaxProtocol,
        attribute: AttributeSyntax,
        context: some MacroExpansionContext
    ) throws -> MethodContext {
        guard let function = declaration.as(FunctionDeclSyntax.self) else {
            throw DiagnosticsError(
                syntax: declaration,
                id: "invalidAttachment",
                message: "'@SingleFlightActor' can only be attached to instance methods."
            )
        }

        let arguments = try parseArguments(from: attribute)
        let enclosingContext = enclosingContextKind(from: context, fallbackFunction: function)

        guard enclosingContext != .extension else {
            throw DiagnosticsError(
                syntax: function,
                id: "extensionsUnsupported",
                message: "'@SingleFlightActor' does not support methods declared in extensions in v1."
            )
        }

        guard enclosingContext == .actor else {
            throw DiagnosticsError(
                syntax: function,
                id: "nonActorContext",
                message: "'@SingleFlightActor' can only be attached to actor instance methods."
            )
        }

        guard !function.isStaticOrClassMethod else {
            throw DiagnosticsError(
                syntax: function,
                id: "staticMethodUnsupported",
                message: "'@SingleFlightActor' does not support 'static' or 'class' methods."
            )
        }

        guard !function.isNonisolatedMethod else {
            throw DiagnosticsError(
                syntax: function,
                id: "nonisolatedUnsupported",
                message: "'@SingleFlightActor' does not support 'nonisolated' methods."
            )
        }

        guard function.isAsyncFunction else {
            throw DiagnosticsError(
                syntax: function,
                id: "asyncRequired",
                message: "'@SingleFlightActor' requires an 'async' method."
            )
        }

        guard !function.hasTypedThrows else {
            throw DiagnosticsError(
                syntax: function,
                id: "typedThrowsUnsupported",
                message: "'@SingleFlightActor' does not support typed-throws methods in v1."
            )
        }

        guard !function.isGenericFunction else {
            throw DiagnosticsError(
                syntax: function,
                id: "genericMethodUnsupported",
                message: "'@SingleFlightActor' does not support generic methods in v1."
            )
        }

        guard !function.hasOpaqueReturnType else {
            throw DiagnosticsError(
                syntax: function,
                id: "opaqueReturnUnsupported",
                message: "'@SingleFlightActor' does not support opaque 'some' return types in v1."
            )
        }

        if let unsupportedParameterMessage = function.unsupportedSingleFlightParameterMessage {
            throw DiagnosticsError(
                syntax: function,
                id: "unsupportedParameterForm",
                message: unsupportedParameterMessage
            )
        }

        return MethodContext(
            function: function,
            arguments: arguments,
            synthesizedStoreName: synthesizedStoreName(for: function),
            synthesizedImplementationName: synthesizedImplementationName(for: function)
        )
    }

    static func enclosingContextKind(
        from context: some MacroExpansionContext,
        fallbackFunction function: FunctionDeclSyntax
    ) -> EnclosingContextKind {
        for lexicalContext in context.lexicalContext {
            if lexicalContext.as(ExtensionDeclSyntax.self) != nil {
                return .extension
            }
            if lexicalContext.as(ActorDeclSyntax.self) != nil {
                return .actor
            }
        }

        if function.isDeclaredInExtension {
            return .extension
        }
        if function.isDeclaredInActor {
            return .actor
        }

        return .other
    }

    static func parseArguments(from attribute: AttributeSyntax) throws -> ParsedArguments {
        let argumentList = attribute.arguments?.as(LabeledExprListSyntax.self) ?? LabeledExprListSyntax([])

        var keyExpression: ExprSyntax?
        var usingExpression: ExprSyntax?
        var policyExpression: ExprSyntax?

        for argument in argumentList {
            guard let label = argument.label?.text else {
                throw DiagnosticsError(
                    syntax: argument,
                    id: "unlabeledArgument",
                    message: "'@SingleFlightActor' arguments must be labeled as 'key:', 'using:', or 'policy:'."
                )
            }

            switch label {
            case "key":
                guard keyExpression == nil else {
                    throw DiagnosticsError(
                        syntax: argument,
                        id: "duplicateKey",
                        message: "'@SingleFlightActor' accepts at most one 'key:' argument."
                    )
                }
                keyExpression = argument.expression
            case "using":
                guard usingExpression == nil else {
                    throw DiagnosticsError(
                        syntax: argument,
                        id: "duplicateUsing",
                        message: "'@SingleFlightActor' accepts at most one 'using:' argument."
                    )
                }
                usingExpression = try validatedUsingExpression(argument.expression)
            case "policy":
                guard policyExpression == nil else {
                    throw DiagnosticsError(
                        syntax: argument,
                        id: "duplicatePolicy",
                        message: "'@SingleFlightActor' accepts at most one 'policy:' argument."
                    )
                }
                policyExpression = argument.expression
            default:
                throw DiagnosticsError(
                    syntax: argument,
                    id: "unknownArgumentLabel",
                    message: "'@SingleFlightActor' arguments must be labeled as 'key:', 'using:', or 'policy:'."
                )
            }
        }

        guard let keyExpression else {
            throw DiagnosticsError(
                syntax: attribute,
                id: "missingKey",
                message: "'@SingleFlightActor' requires a 'key:' argument."
            )
        }

        if keyExpression.as(StringLiteralExprSyntax.self) != nil {
            throw DiagnosticsError(
                syntax: keyExpression,
                id: "legacyStringKey",
                message: "String literal keys are unsupported. Use an expression, for example 'key: { (id: User.ID) in id }'."
            )
        }

        return ParsedArguments(
            keyExpression: keyExpression,
            usingExpression: usingExpression,
            policyExpression: policyExpression
        )
    }

    static func synthesizedStoreName(for function: FunctionDeclSyntax) -> String {
        let hash = stableSignatureHash(for: function)
        return "__singleFlightStore_\(String(hash, radix: 16))"
    }

    static func synthesizedImplementationName(for function: FunctionDeclSyntax) -> String {
        let hash = stableSignatureHash(for: function)
        return "__singleFlightImpl_\(String(hash, radix: 16))"
    }

    static func implementationMethodDecl(
        for function: FunctionDeclSyntax,
        implementationName: String
    ) -> DeclSyntax {
        let parameterClauseSource = function.signature.parameterClause.trimmedDescription
        let effectSpecifiersSource = function.signature.effectSpecifiers?.trimmedDescription
        let returnClauseSource = function.signature.returnClause?.trimmedDescription
        let signatureSuffix = [effectSpecifiersSource, returnClauseSource]
            .compactMap { $0?.nilIfEmpty }
            .joined(separator: " ")
        let originalBodyStatements = function.body?.statements.trimmedDescription ?? ""
        let signatureTail = signatureSuffix.isEmpty ? "" : " \(signatureSuffix)"

        return DeclSyntax(stringLiteral: """
        private func \(implementationName)\(parameterClauseSource)\(signatureTail) {
        \(originalBodyStatements)
        }
        """)
    }

    static func stableSignatureHash(for function: FunctionDeclSyntax) -> UInt64 {
        let signatureSource = [
            function.name.text,
            function.signature.parameterClause.trimmedDescription,
            function.signature.returnClause?.type.trimmedDescription ?? "Void",
            function.isThrowingFunction ? "throws" : "nonthrowing",
        ].joined(separator: "|")
        return stableHash(signatureSource)
    }

    static func stableHash(_ source: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in source.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    static func evaluatedKeyExpressionSource(
        from keyExpression: ExprSyntax,
        for function: FunctionDeclSyntax
    ) -> String {
        let keyExpressionSource = keyExpression.trimmedDescription
        guard keyExpression.as(ClosureExprSyntax.self) != nil else {
            return keyExpressionSource
        }

        let parameters = function.parameterLocalNames.joined(separator: ", ")
        return "(\(keyExpressionSource))(\(parameters))"
    }

    static func sendabilityCheckStatements(for function: FunctionDeclSyntax) -> [String] {
        var statements = ["ConcurrencyMacros.__singleFlightRequireSendable(__singleFlightKey)"]
        statements.append(contentsOf: function.parameterLocalNames.map { parameterName in
            "ConcurrencyMacros.__singleFlightRequireSendable(\(parameterName))"
        })
        return statements
    }

    static func validatedUsingExpression(_ usingExpression: ExprSyntax) throws -> ExprSyntax {
        if usingExpression.as(StringLiteralExprSyntax.self) != nil {
            throw DiagnosticsError(
                syntax: usingExpression,
                id: "legacyStringUsing",
                message: "String literal stores are unsupported. Use an expression, for example 'using: sharedFlightsStore'."
            )
        }

        if usingExpression.as(KeyPathExprSyntax.self) != nil {
            throw DiagnosticsError(
                syntax: usingExpression,
                id: "keyPathUsingUnsupported",
                message: "'using:' does not accept key-path literals. Pass a store expression such as 'using: sharedFlightsStore' or 'using: Self.sharedFlightsStore'."
            )
        }

        guard isSupportedUsingExpression(usingExpression) else {
            throw DiagnosticsError(
                syntax: usingExpression,
                id: "unsupportedUsingExpression",
                message: "'using:' must reference an existing store value (identifier or member access)."
            )
        }

        return usingExpression
    }

    static func isSupportedUsingExpression(_ expression: ExprSyntax) -> Bool {
        expression.as(DeclReferenceExprSyntax.self) != nil ||
            expression.as(MemberAccessExprSyntax.self) != nil
    }

    static func storeExpressionSource(
        from usingExpression: ExprSyntax?,
        fallbackStoreName: String
    ) -> String {
        guard let usingExpression else {
            return fallbackStoreName
        }

        return usingExpression.trimmedDescription
    }

    enum EnclosingContextKind {
        case actor
        case `extension`
        case other
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private struct SingleFlightActorMacroDiagnostic: DiagnosticMessage {
    let id: String
    let message: String

    var diagnosticID: MessageID {
        MessageID(domain: "SingleFlightActorMacro", id: id)
    }

    var severity: DiagnosticSeverity {
        .error
    }
}

private extension DiagnosticsError {
    init(syntax: some SyntaxProtocol, id: String, message: String) {
        self.init(diagnostics: [
            Diagnostic(
                node: Syntax(syntax),
                message: SingleFlightActorMacroDiagnostic(id: id, message: message)
            ),
        ])
    }
}
