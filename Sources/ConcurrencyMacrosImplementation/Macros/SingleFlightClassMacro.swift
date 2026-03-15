//
//  SingleFlightClassMacro.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 16.03.26.
//

import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// Rewrites class instance methods to deduplicate concurrent in-flight work by key.
public struct SingleFlightClassMacro: BodyMacro, PeerMacro {
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

        return [
            implementationMethodDecl(
                for: method.function,
                implementationName: method.synthesizedImplementationName
            ),
        ]
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
        let storeExpressionSource = storeExpressionSource(from: method.arguments.usingExpression)
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
            with: "__singleFlightClassInstance."
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
            CodeBlockItemSyntax(stringLiteral: "let __singleFlightClassInstance = self")
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

private extension SingleFlightClassMacro {
    struct MethodContext {
        let function: FunctionDeclSyntax
        let arguments: ParsedArguments
        let synthesizedImplementationName: String
    }

    struct ParsedArguments {
        let keyExpression: ExprSyntax
        let usingExpression: ExprSyntax
        let policyExpression: ExprSyntax?
    }

    enum EnclosingContextKind {
        case classDecl(ClassDeclSyntax)
        case `extension`
        case other
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
                message: "'@SingleFlightClass' can only be attached to instance methods."
            )
        }

        let arguments = try parseArguments(from: attribute)
        let enclosingContext = enclosingContextKind(from: context, fallbackFunction: function)

        switch enclosingContext {
        case .extension:
            throw DiagnosticsError(
                syntax: function,
                id: "extensionsUnsupported",
                message: "'@SingleFlightClass' does not support methods declared in extensions in v1."
            )
        case .other:
            throw DiagnosticsError(
                syntax: function,
                id: "nonClassContext",
                message: "'@SingleFlightClass' can only be attached to class instance methods."
            )
        case .classDecl(let classDecl):
            guard classDecl.isFinalDeclaration else {
                throw DiagnosticsError(
                    syntax: classDecl,
                    id: "finalClassRequired",
                    message: "'@SingleFlightClass' requires the enclosing class to be declared 'final'."
                )
            }

            guard !classDecl.hasExplicitUncheckedSendableConformance else {
                throw DiagnosticsError(
                    syntax: classDecl,
                    id: "uncheckedSendableUnsupported",
                    message: "'@SingleFlightClass' does not support '@unchecked Sendable' conformances."
                )
            }

            guard classDecl.hasExplicitSendableConformance else {
                throw DiagnosticsError(
                    syntax: classDecl,
                    id: "sendableConformanceRequired",
                    message: "'@SingleFlightClass' requires the enclosing class to explicitly conform to 'Sendable'."
                )
            }
        }

        guard !function.isStaticOrClassMethod else {
            throw DiagnosticsError(
                syntax: function,
                id: "staticMethodUnsupported",
                message: "'@SingleFlightClass' does not support 'static' or 'class' methods."
            )
        }

        guard function.isAsyncFunction else {
            throw DiagnosticsError(
                syntax: function,
                id: "asyncRequired",
                message: "'@SingleFlightClass' requires an 'async' method."
            )
        }

        guard !function.hasTypedThrows else {
            throw DiagnosticsError(
                syntax: function,
                id: "typedThrowsUnsupported",
                message: "'@SingleFlightClass' does not support typed-throws methods in v1."
            )
        }

        guard !function.isGenericFunction else {
            throw DiagnosticsError(
                syntax: function,
                id: "genericMethodUnsupported",
                message: "'@SingleFlightClass' does not support generic methods in v1."
            )
        }

        guard !function.hasOpaqueReturnType else {
            throw DiagnosticsError(
                syntax: function,
                id: "opaqueReturnUnsupported",
                message: "'@SingleFlightClass' does not support opaque 'some' return types in v1."
            )
        }

        if let unsupportedParameterMessage = function.unsupportedSingleFlightParameterMessage(
            macroName: "SingleFlightClass"
        ) {
            throw DiagnosticsError(
                syntax: function,
                id: "unsupportedParameterForm",
                message: unsupportedParameterMessage
            )
        }

        return MethodContext(
            function: function,
            arguments: arguments,
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
            if let classDecl = lexicalContext.as(ClassDeclSyntax.self) {
                return .classDecl(classDecl)
            }
        }

        if function.isDeclaredInExtension {
            return .extension
        }
        if let classDecl = function.nearestEnclosingClassDecl {
            return .classDecl(classDecl)
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
                    message: "'@SingleFlightClass' arguments must be labeled as 'key:', 'using:', or 'policy:'."
                )
            }

            switch label {
            case "key":
                guard keyExpression == nil else {
                    throw DiagnosticsError(
                        syntax: argument,
                        id: "duplicateKey",
                        message: "'@SingleFlightClass' accepts at most one 'key:' argument."
                    )
                }
                keyExpression = argument.expression
            case "using":
                guard usingExpression == nil else {
                    throw DiagnosticsError(
                        syntax: argument,
                        id: "duplicateUsing",
                        message: "'@SingleFlightClass' accepts at most one 'using:' argument."
                    )
                }
                usingExpression = try validatedUsingExpression(argument.expression)
            case "policy":
                guard policyExpression == nil else {
                    throw DiagnosticsError(
                        syntax: argument,
                        id: "duplicatePolicy",
                        message: "'@SingleFlightClass' accepts at most one 'policy:' argument."
                    )
                }
                policyExpression = argument.expression
            default:
                throw DiagnosticsError(
                    syntax: argument,
                    id: "unknownArgumentLabel",
                    message: "'@SingleFlightClass' arguments must be labeled as 'key:', 'using:', or 'policy:'."
                )
            }
        }

        guard let keyExpression else {
            throw DiagnosticsError(
                syntax: attribute,
                id: "missingKey",
                message: "'@SingleFlightClass' requires a 'key:' argument."
            )
        }

        guard let usingExpression else {
            throw DiagnosticsError(
                syntax: attribute,
                id: "missingUsing",
                message: "'@SingleFlightClass' requires a 'using:' argument."
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
            .compactMap { $0 }
            .filter { !$0.isEmpty }
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
        var statements = [
            "ConcurrencyMacros.__singleFlightRequireSendable(self)",
            "ConcurrencyMacros.__singleFlightRequireSendable(__singleFlightKey)",
        ]
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

    static func storeExpressionSource(from usingExpression: ExprSyntax) -> String {
        usingExpression.trimmedDescription
    }
}

private struct SingleFlightClassMacroDiagnostic: DiagnosticMessage {
    let id: String
    let message: String

    var diagnosticID: MessageID {
        MessageID(domain: "SingleFlightClassMacro", id: id)
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
                message: SingleFlightClassMacroDiagnostic(id: id, message: message)
            ),
        ])
    }
}
