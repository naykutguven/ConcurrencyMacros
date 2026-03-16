//
//  StreamBridgeMacro.swift
//  ConcurrencyMacrosImplementation
//
//  Created by Codex on 15.03.26.
//

import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// Generates stream-returning wrappers for callback-based registration APIs.
public struct StreamBridgeMacro: BodyMacro, PeerMacro {
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
            generatedStreamMethod(for: method)
        ]
    }

    public static func expansion(
        of attribute: AttributeSyntax,
        providingBodyFor declaration: some DeclSyntaxProtocol & WithOptionalCodeBlockSyntax,
        in context: some MacroExpansionContext
    ) throws -> [CodeBlockItemSyntax] {
        // Peer expansion is responsible for diagnostics to avoid duplicate messages.
        guard let function = declaration.as(FunctionDeclSyntax.self),
              let _ = try? validatedMethod(
                  from: function,
                  attribute: attribute,
                  context: context
              )
        else {
            return declaration.body?.statements.compactMap { CodeBlockItemSyntax($0) } ?? []
        }

        return function.body?.statements.compactMap { CodeBlockItemSyntax($0) } ?? []
    }
}

/// Validates and stores defaults for `@StreamBridge` attached to nominal types.
public struct StreamBridgeDefaultsMacro: MemberMacro {
    public static func expansion(
        of attribute: AttributeSyntax,
        providingMembersOf declaration: some DeclSyntaxProtocol,
        conformingTo _: [TypeSyntax],
        in _: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard declaration.as(ClassDeclSyntax.self) != nil ||
                declaration.as(ActorDeclSyntax.self) != nil ||
                declaration.as(StructDeclSyntax.self) != nil ||
                declaration.as(EnumDeclSyntax.self) != nil
        else {
            throw DiagnosticsError(
                syntax: declaration,
                domain: "StreamBridgeDefaultsMacro",
                id: "invalidAttachment",
                message: "'@StreamBridgeDefaults' can only be attached to nominal type declarations."
            )
        }

        _ = try StreamBridgeMacro.parseDefaultsArguments(
            from: attribute,
            domain: "StreamBridgeDefaultsMacro"
        )

        return []
    }
}

private extension StreamBridgeMacro {
    struct MethodContext {
        let function: FunctionDeclSyntax
        let generatedName: String
        let eventParameter: CallbackParameter
        let failureParameter: CallbackParameter?
        let completionParameter: CallbackParameter?
        let eventTypeSource: String
        let failureTypeSource: String?
        let cancellation: CancellationStrategy
        let buffering: BufferingStrategy
        let safety: StreamSafety
        let nonCallbackParameters: [FunctionParameterSyntax]
    }

    struct CallbackParameter {
        let index: Int
        let parameter: FunctionParameterSyntax
        let signature: CallbackSignature
    }

    struct CallbackSignature {
        let arity: Int
        let firstParameterTypeSource: String?
        let returnsVoid: Bool
        let isSendableClosure: Bool
    }

    struct ParsedBridgeArguments {
        let generatedName: String
        let eventSelector: LabelSelector
        let failureSelector: FailureSelector?
        let completionSelector: LabelSelector?
        let cancellation: CancellationStrategy?
        let buffering: BufferingStrategy?
        let safety: StreamSafety?
    }

    struct ParsedDefaultsArguments {
        let cancellation: CancellationStrategy?
        let buffering: BufferingStrategy?
        let safety: StreamSafety?
    }

    struct LabelSelector {
        let label: String
    }

    struct FailureSelector {
        let label: String
        let explicitFailureTypeSource: String
    }

    enum CancellationStrategy: Equatable {
        case none
        case ownerMethod(name: String, argumentLabel: String)
        case tokenMethod
    }

    enum BufferingStrategy: Equatable {
        case unbounded
        case bufferingOldest(String)
        case bufferingNewest(String)

        var policySource: String {
            switch self {
            case .unbounded:
                return ".unbounded"
            case .bufferingOldest(let count):
                return ".bufferingOldest(\(count))"
            case .bufferingNewest(let count):
                return ".bufferingNewest(\(count))"
            }
        }
    }

    enum StreamSafety: Equatable {
        case strict
        case unchecked
    }

    enum EnclosingContext {
        case actor(ActorDeclSyntax)
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
                domain: "StreamBridgeMacro",
                id: "invalidAttachment",
                message: "'@StreamBridge' can only be attached to instance methods."
            )
        }

        let argumentList = try parseBridgeArguments(from: attribute)
        let defaults = try defaultsArguments(for: function, context: context)
        let cancellation = argumentList.cancellation ?? defaults.cancellation ?? .none
        let buffering = argumentList.buffering ?? defaults.buffering ?? .unbounded
        let safety = argumentList.safety ?? defaults.safety ?? .strict
        let enclosing = enclosingContext(from: context, fallbackFunction: function)

        switch enclosing {
        case .extension:
            throw DiagnosticsError(
                syntax: function,
                domain: "StreamBridgeMacro",
                id: "extensionsUnsupported",
                message: "'@StreamBridge' does not support methods declared in extensions in v1."
            )
        case .other:
            throw DiagnosticsError(
                syntax: function,
                domain: "StreamBridgeMacro",
                id: "nonNominalContext",
                message: "'@StreamBridge' can only be attached to actor or class instance methods."
            )
        case .actor(_), .classDecl(_):
            break
        }

        guard !function.isStaticOrClassMethod else {
            throw DiagnosticsError(
                syntax: function,
                domain: "StreamBridgeMacro",
                id: "staticMethodUnsupported",
                message: "'@StreamBridge' does not support 'static' or 'class' methods."
            )
        }

        guard !function.isAsyncFunction, !function.isThrowingFunction else {
            throw DiagnosticsError(
                syntax: function,
                domain: "StreamBridgeMacro",
                id: "synchronousMethodRequired",
                message: "'@StreamBridge' requires a synchronous non-throwing registration method."
            )
        }

        guard !function.isGenericFunction else {
            throw DiagnosticsError(
                syntax: function,
                domain: "StreamBridgeMacro",
                id: "genericMethodUnsupported",
                message: "'@StreamBridge' does not support generic methods in v1."
            )
        }

        let parameters = Array(function.signature.parameterClause.parameters)
        let eventParameter = try selectedCallbackParameter(
            in: parameters,
            selector: argumentList.eventSelector,
            kind: "event",
            fallbackSyntax: function
        )
        let failureParameter = try argumentList.failureSelector.map {
            try selectedCallbackParameter(
                in: parameters,
                selector: .init(label: $0.label),
                kind: "failure",
                fallbackSyntax: function
            )
        }
        let completionParameter = try argumentList.completionSelector.map {
            try selectedCallbackParameter(
                in: parameters,
                selector: $0,
                kind: "completion",
                fallbackSyntax: function
            )
        }

        let callbackIndices = Set(
            [eventParameter.index, failureParameter?.index, completionParameter?.index]
                .compactMap { $0 }
        )
        let callbackIndexCount = [eventParameter.index, failureParameter?.index, completionParameter?.index]
            .compactMap { $0 }
            .count
        guard callbackIndices.count == callbackIndexCount else {
            throw DiagnosticsError(
                syntax: function,
                domain: "StreamBridgeMacro",
                id: "callbackSelectorOverlap",
                message: "'@StreamBridge' callback selectors must refer to distinct parameters."
            )
        }

        try validateEventSignature(
            eventParameter.signature,
            syntax: eventParameter.parameter
        )
        if let failureParameter {
            try validateFailureSignature(
                failureParameter.signature,
                syntax: failureParameter.parameter
            )
        }
        if let completionParameter {
            try validateCompletionSignature(
                completionParameter.signature,
                syntax: completionParameter.parameter
            )
        }

        let eventTypeSource = try require(
            eventParameter.signature.firstParameterTypeSource,
            syntax: eventParameter.parameter,
            id: "invalidEventCallbackSignature",
            message: "'@StreamBridge' event callback must have one parameter and return 'Void'."
        )

        if let failureParameter {
            let callbackFailureType = try require(
                failureParameter.signature.firstParameterTypeSource,
                syntax: failureParameter.parameter,
                id: "invalidFailureCallbackSignature",
                message: "'@StreamBridge' failure callback must have one parameter and return 'Void'."
            )
            _ = callbackFailureType
        }

        let failureTypeSource = argumentList.failureSelector?.explicitFailureTypeSource

        let returnsVoid = isVoidReturnType(function.signature.returnClause?.type)
        if cancellation != .none && returnsVoid {
            throw DiagnosticsError(
                syntax: function,
                domain: "StreamBridgeMacro",
                id: "cancelRequiresTokenReturn",
                message: "'@StreamBridge' cancellation strategies other than '.none' require the source method to return a token."
            )
        }

        if case .tokenMethod = cancellation,
           isOptionalType(function.signature.returnClause?.type)
        {
            throw DiagnosticsError(
                syntax: function,
                domain: "StreamBridgeMacro",
                id: "optionalTokenUnsupported",
                message: "'@StreamBridge' '.tokenMethod' does not support optional token return types in v1."
            )
        }

        if case .ownerMethod = cancellation,
           case .actor(_) = enclosing
        {
            throw DiagnosticsError(
                syntax: function,
                domain: "StreamBridgeMacro",
                id: "ownerMethodUnsupportedOnActor",
                message: "'@StreamBridge' '.ownerMethod' cancellation is not supported on actor methods in v1; use '.tokenMethod' or '.none'."
            )
        }

        if safety == .strict {
            if case .classDecl(let classDecl) = enclosing {
                if classDecl.hasExplicitUncheckedSendableConformance {
                    throw DiagnosticsError(
                        syntax: classDecl,
                        domain: "StreamBridgeMacro",
                        id: "uncheckedSendableUnsupported",
                        message: "'@StreamBridge' strict safety does not support '@unchecked Sendable' classes."
                    )
                }

                if !classDecl.hasExplicitSendableConformance {
                    throw DiagnosticsError(
                        syntax: classDecl,
                        domain: "StreamBridgeMacro",
                        id: "sendableConformanceRequired",
                        message: "'@StreamBridge' strict safety requires the enclosing class to explicitly conform to 'Sendable'."
                    )
                }
            }

            try validateSendableCallback(eventParameter, kind: "event")
            if let failureParameter {
                try validateSendableCallback(failureParameter, kind: "failure")
            }
            if let completionParameter {
                try validateSendableCallback(completionParameter, kind: "completion")
            }
        }

        var nonCallbackParameters: [FunctionParameterSyntax] = []
        for (index, parameter) in parameters.enumerated() where !callbackIndices.contains(index) {
            nonCallbackParameters.append(parameter)
        }

        for parameter in nonCallbackParameters {
            guard parameterLocalName(parameter) != nil else {
                throw DiagnosticsError(
                    syntax: parameter,
                    domain: "StreamBridgeMacro",
                    id: "unsupportedParameterForm",
                    message: "'@StreamBridge' requires non-callback parameters to have a usable local name."
                )
            }
        }

        return MethodContext(
            function: function,
            generatedName: argumentList.generatedName,
            eventParameter: eventParameter,
            failureParameter: failureParameter,
            completionParameter: completionParameter,
            eventTypeSource: eventTypeSource,
            failureTypeSource: failureTypeSource,
            cancellation: cancellation,
            buffering: buffering,
            safety: safety,
            nonCallbackParameters: nonCallbackParameters
        )
    }

    static func generatedStreamMethod(for method: MethodContext) -> DeclSyntax {
        let isThrowingStream = method.failureParameter != nil
        let returnTypeSource = isThrowingStream
            ? "AsyncThrowingStream<\(method.eventTypeSource), any Error>"
            : "AsyncStream<\(method.eventTypeSource)>"
        let parameterClauseSource = parameterClauseSource(from: method.nonCallbackParameters)
        let accessLevelPrefix = accessLevelPrefix(for: method.function)
        let sourceCall = sourceRegistrationInvocationSource(for: method)
        let sendabilityChecks = sendabilityCheckLines(for: method)
        let tokenCheckLine = tokenSendabilityCheckLine(for: method)
        let cancelSource = cancelClosureSource(for: method)
        let throwingFailureTypeSource = method.failureTypeSource ?? "any Error"
        let registerSource: String = if isThrowingStream {
            """
            register: { __streamBridgeOnEvent, __streamBridgeOnFailure, __streamBridgeOnCompletion in
                        let __streamBridgeOnFailureTyped: (\(throwingFailureTypeSource)) -> Void = __streamBridgeOnFailure
                        let __streamBridgeToken = \(sourceCall)
                        \(tokenCheckLine)return __streamBridgeToken
                    }
            """
        } else {
            """
            register: { __streamBridgeOnEvent, __streamBridgeOnCompletion in
                        let __streamBridgeToken = \(sourceCall)
                        \(tokenCheckLine)return __streamBridgeToken
                    }
            """
        }
        let runtimeFunctionName: String = if isThrowingStream {
            method.safety == .strict ? "makeThrowingStream" : "makeThrowingStreamUnchecked"
        } else {
            method.safety == .strict ? "makeStream" : "makeStreamUnchecked"
        }

        return DeclSyntax(stringLiteral: """
        \(accessLevelPrefix)func \(method.generatedName)\(parameterClauseSource) -> \(returnTypeSource) {
            let __streamBridgeOwner = self
            \(sendabilityChecks)return ConcurrencyMacros.StreamBridgeRuntime.\(runtimeFunctionName)(
                bufferingPolicy: \(method.buffering.policySource),
                \(registerSource),
                cancel: \(cancelSource)
            )
        }
        """)
    }

    static func defaultsArguments(
        for function: FunctionDeclSyntax,
        context: some MacroExpansionContext
    ) throws -> ParsedDefaultsArguments {
        guard let defaultsAttribute = try defaultsAttribute(for: function, context: context) else {
            return ParsedDefaultsArguments(
                cancellation: nil,
                buffering: nil,
                safety: nil
            )
        }

        return try parseDefaultsArguments(
            from: defaultsAttribute,
            domain: "StreamBridgeMacro"
        )
    }

    static func defaultsAttribute(
        for function: FunctionDeclSyntax,
        context: some MacroExpansionContext
    ) throws -> AttributeSyntax? {
        let attributes: AttributeListSyntax? = {
            for lexicalContext in context.lexicalContext {
                if let actor = lexicalContext.as(ActorDeclSyntax.self) {
                    return actor.attributes
                }
                if let classDecl = lexicalContext.as(ClassDeclSyntax.self) {
                    return classDecl.attributes
                }
                if let structure = lexicalContext.as(StructDeclSyntax.self) {
                    return structure.attributes
                }
                if let enumeration = lexicalContext.as(EnumDeclSyntax.self) {
                    return enumeration.attributes
                }
            }

            if let actor = function.nearestEnclosingActorDecl {
                return actor.attributes
            }
            if let classDecl = function.nearestEnclosingClassDecl {
                return classDecl.attributes
            }

            return nil
        }()

        let defaults = (attributes ?? []).compactMap { element -> AttributeSyntax? in
            guard let attribute = element.as(AttributeSyntax.self) else { return nil }
            guard attribute.attributeName.trimmedDescription == "StreamBridgeDefaults" else { return nil }
            return attribute
        }

        if defaults.count > 1 {
            throw DiagnosticsError(
                syntax: function,
                domain: "StreamBridgeMacro",
                id: "duplicateDefaultsAttributes",
                message: "'@StreamBridge' supports at most one enclosing '@StreamBridgeDefaults' attribute."
            )
        }

        return defaults.first
    }

    static func enclosingContext(
        from context: some MacroExpansionContext,
        fallbackFunction function: FunctionDeclSyntax
    ) -> EnclosingContext {
        for lexicalContext in context.lexicalContext {
            if lexicalContext.as(ExtensionDeclSyntax.self) != nil {
                return .extension
            }
            if let actorDecl = lexicalContext.as(ActorDeclSyntax.self) {
                return .actor(actorDecl)
            }
            if let classDecl = lexicalContext.as(ClassDeclSyntax.self) {
                return .classDecl(classDecl)
            }
        }

        if function.isDeclaredInExtension {
            return .extension
        }
        if let actorDecl = function.nearestEnclosingActorDecl {
            return .actor(actorDecl)
        }
        if let classDecl = function.nearestEnclosingClassDecl {
            return .classDecl(classDecl)
        }

        return .other
    }

    static func parseBridgeArguments(from attribute: AttributeSyntax) throws -> ParsedBridgeArguments {
        let argumentList = attribute.arguments?.as(LabeledExprListSyntax.self) ?? LabeledExprListSyntax([])

        var generatedName: String?
        var eventSelector: LabelSelector?
        var failureSelector: FailureSelector?
        var completionSelector: LabelSelector?
        var cancellation: CancellationStrategy?
        var buffering: BufferingStrategy?
        var safety: StreamSafety?

        for argument in argumentList {
            guard let label = argument.label?.text else {
                throw DiagnosticsError(
                    syntax: argument,
                    domain: "StreamBridgeMacro",
                    id: "unlabeledArgument",
                    message: "'@StreamBridge' arguments must be labeled."
                )
            }

            switch label {
            case "as":
                guard generatedName == nil else {
                    throw DiagnosticsError(
                        syntax: argument,
                        domain: "StreamBridgeMacro",
                        id: "duplicateAs",
                        message: "'@StreamBridge' accepts at most one 'as:' argument."
                    )
                }
                generatedName = try parseGeneratedMethodName(from: argument.expression)
            case "event":
                guard eventSelector == nil else {
                    throw DiagnosticsError(
                        syntax: argument,
                        domain: "StreamBridgeMacro",
                        id: "duplicateEvent",
                        message: "'@StreamBridge' accepts at most one 'event:' argument."
                    )
                }
                eventSelector = try parseSelector(
                    from: argument.expression,
                    domain: "StreamBridgeMacro",
                    idPrefix: "event"
                )
            case "failure":
                guard failureSelector == nil else {
                    throw DiagnosticsError(
                        syntax: argument,
                        domain: "StreamBridgeMacro",
                        id: "duplicateFailure",
                        message: "'@StreamBridge' accepts at most one 'failure:' argument."
                    )
                }
                failureSelector = try parseFailureSelector(
                    from: argument.expression,
                    domain: "StreamBridgeMacro"
                )
            case "completion":
                guard completionSelector == nil else {
                    throw DiagnosticsError(
                        syntax: argument,
                        domain: "StreamBridgeMacro",
                        id: "duplicateCompletion",
                        message: "'@StreamBridge' accepts at most one 'completion:' argument."
                    )
                }
                completionSelector = try parseSelector(
                    from: argument.expression,
                    domain: "StreamBridgeMacro",
                    idPrefix: "completion"
                )
            case "cancel":
                guard cancellation == nil else {
                    throw DiagnosticsError(
                        syntax: argument,
                        domain: "StreamBridgeMacro",
                        id: "duplicateCancel",
                        message: "'@StreamBridge' accepts at most one 'cancel:' argument."
                    )
                }
                cancellation = try parseCancellation(
                    from: argument.expression,
                    domain: "StreamBridgeMacro"
                )
            case "buffering":
                guard buffering == nil else {
                    throw DiagnosticsError(
                        syntax: argument,
                        domain: "StreamBridgeMacro",
                        id: "duplicateBuffering",
                        message: "'@StreamBridge' accepts at most one 'buffering:' argument."
                    )
                }
                buffering = try parseBuffering(
                    from: argument.expression,
                    domain: "StreamBridgeMacro"
                )
            case "safety":
                guard safety == nil else {
                    throw DiagnosticsError(
                        syntax: argument,
                        domain: "StreamBridgeMacro",
                        id: "duplicateSafety",
                        message: "'@StreamBridge' accepts at most one 'safety:' argument."
                    )
                }
                safety = try parseSafety(
                    from: argument.expression,
                    domain: "StreamBridgeMacro"
                )
            default:
                throw DiagnosticsError(
                    syntax: argument,
                    domain: "StreamBridgeMacro",
                    id: "unknownArgumentLabel",
                    message: "'@StreamBridge' arguments must be labeled 'as:', 'event:', 'failure:', 'completion:', 'cancel:', 'buffering:', or 'safety:'."
                )
            }
        }

        guard let generatedName else {
            throw DiagnosticsError(
                syntax: attribute,
                domain: "StreamBridgeMacro",
                id: "missingAs",
                message: "'@StreamBridge' requires an 'as:' argument."
            )
        }
        guard let eventSelector else {
            throw DiagnosticsError(
                syntax: attribute,
                domain: "StreamBridgeMacro",
                id: "missingEvent",
                message: "'@StreamBridge' requires an 'event:' argument."
            )
        }

        return ParsedBridgeArguments(
            generatedName: generatedName,
            eventSelector: eventSelector,
            failureSelector: failureSelector,
            completionSelector: completionSelector,
            cancellation: cancellation,
            buffering: buffering,
            safety: safety
        )
    }

    static func parseDefaultsArguments(
        from attribute: AttributeSyntax,
        domain: String
    ) throws -> ParsedDefaultsArguments {
        let argumentList = attribute.arguments?.as(LabeledExprListSyntax.self) ?? LabeledExprListSyntax([])

        var cancellation: CancellationStrategy?
        var buffering: BufferingStrategy?
        var safety: StreamSafety?

        for argument in argumentList {
            guard let label = argument.label?.text else {
                throw DiagnosticsError(
                    syntax: argument,
                    domain: domain,
                    id: "unlabeledDefaultsArgument",
                    message: "'@StreamBridgeDefaults' arguments must be labeled."
                )
            }

            switch label {
            case "cancel":
                guard cancellation == nil else {
                    throw DiagnosticsError(
                        syntax: argument,
                        domain: domain,
                        id: "duplicateDefaultsCancel",
                        message: "'@StreamBridgeDefaults' accepts at most one 'cancel:' argument."
                    )
                }
                cancellation = try parseCancellation(
                    from: argument.expression,
                    domain: domain
                )
            case "buffering":
                guard buffering == nil else {
                    throw DiagnosticsError(
                        syntax: argument,
                        domain: domain,
                        id: "duplicateDefaultsBuffering",
                        message: "'@StreamBridgeDefaults' accepts at most one 'buffering:' argument."
                    )
                }
                buffering = try parseBuffering(
                    from: argument.expression,
                    domain: domain
                )
            case "safety":
                guard safety == nil else {
                    throw DiagnosticsError(
                        syntax: argument,
                        domain: domain,
                        id: "duplicateDefaultsSafety",
                        message: "'@StreamBridgeDefaults' accepts at most one 'safety:' argument."
                    )
                }
                safety = try parseSafety(
                    from: argument.expression,
                    domain: domain
                )
            default:
                throw DiagnosticsError(
                    syntax: argument,
                    domain: domain,
                    id: "unknownDefaultsArgumentLabel",
                    message: "'@StreamBridgeDefaults' arguments must be labeled 'cancel:', 'buffering:', or 'safety:'."
                )
            }
        }

        return ParsedDefaultsArguments(
            cancellation: cancellation,
            buffering: buffering,
            safety: safety
        )
    }

    static func parseGeneratedMethodName(from expression: ExprSyntax) throws -> String {
        guard let literal = expression.as(StringLiteralExprSyntax.self),
              literal.segments.count == 1,
              let segment = literal.segments.first?.as(StringSegmentSyntax.self)
        else {
            throw DiagnosticsError(
                syntax: expression,
                domain: "StreamBridgeMacro",
                id: "asMustBeStaticStringLiteral",
                message: "'@StreamBridge' 'as:' must be a static string literal."
            )
        }

        let value = segment.content.text
        guard isValidIdentifier(value) else {
            throw DiagnosticsError(
                syntax: expression,
                domain: "StreamBridgeMacro",
                id: "invalidGeneratedMethodName",
                message: "'@StreamBridge' 'as:' must be a valid Swift identifier."
            )
        }

        return value
    }

    static func parseSelector(
        from expression: ExprSyntax,
        domain: String,
        idPrefix: String
    ) throws -> LabelSelector {
        guard let call = expression.as(FunctionCallExprSyntax.self),
              calledCaseName(from: call.calledExpression) == "label"
        else {
            throw DiagnosticsError(
                syntax: expression,
                domain: domain,
                id: "\(idPrefix)SelectorUnsupported",
                message: "'@StreamBridge' \(idPrefix) selector must use '.label(\"...\")'."
            )
        }

        guard call.arguments.count == 1 else {
            throw DiagnosticsError(
                syntax: expression,
                domain: domain,
                id: "\(idPrefix)SelectorArgumentShape",
                message: "'@StreamBridge' \(idPrefix) selector must provide exactly one label string."
            )
        }

        let argument = call.arguments[call.arguments.startIndex]
        guard argument.label == nil else {
            throw DiagnosticsError(
                syntax: argument,
                domain: domain,
                id: "\(idPrefix)SelectorLabelMustBeUnlabeled",
                message: "'@StreamBridge' \(idPrefix) selector label argument must be unlabeled."
            )
        }

        let label = try parseStringLiteral(
            from: argument.expression,
            domain: domain,
            id: "\(idPrefix)SelectorLabelMustBeString"
        )

        return LabelSelector(label: label)
    }

    static func parseFailureSelector(
        from expression: ExprSyntax,
        domain: String
    ) throws -> FailureSelector {
        guard let call = expression.as(FunctionCallExprSyntax.self),
              calledCaseName(from: call.calledExpression) == "label"
        else {
            throw DiagnosticsError(
                syntax: expression,
                domain: domain,
                id: "failureSelectorUnsupported",
                message: "'@StreamBridge' failure selector must use '.label(\"...\", as: Failure.self)'."
            )
        }

        guard call.arguments.count == 2 else {
            throw DiagnosticsError(
                syntax: expression,
                domain: domain,
                id: "failureSelectorArgumentShape",
                message: "'@StreamBridge' failure selector requires one label string and one 'as:' failure type."
            )
        }

        let firstArgument = call.arguments[call.arguments.startIndex]
        guard firstArgument.label == nil else {
            throw DiagnosticsError(
                syntax: firstArgument,
                domain: domain,
                id: "failureSelectorLabelMustBeUnlabeled",
                message: "'@StreamBridge' failure selector label argument must be unlabeled."
            )
        }

        let label = try parseStringLiteral(
            from: firstArgument.expression,
            domain: domain,
            id: "failureSelectorLabelMustBeString"
        )

        let secondArgument = call.arguments[call.arguments.index(after: call.arguments.startIndex)]
        guard secondArgument.label?.text == "as" else {
            throw DiagnosticsError(
                syntax: secondArgument,
                domain: domain,
                id: "failureSelectorInvalidAsLabel",
                message: "'@StreamBridge' failure selector second argument must be labeled 'as:'."
            )
        }

        let explicitFailureTypeSource = try parseMetatypeSource(
            from: secondArgument.expression,
            domain: domain,
            id: "failureSelectorAsMustBeMetatype"
        )

        return FailureSelector(
            label: label,
            explicitFailureTypeSource: explicitFailureTypeSource
        )
    }

    static func parseCancellation(
        from expression: ExprSyntax,
        domain: String
    ) throws -> CancellationStrategy {
        if calledCaseName(from: expression) == "none" {
            return .none
        }
        if calledCaseName(from: expression) == "tokenMethod" {
            return .tokenMethod
        }

        if let call = expression.as(FunctionCallExprSyntax.self),
           calledCaseName(from: call.calledExpression) == "ownerMethod"
        {
            guard let methodNameArgument = call.arguments.first,
                  methodNameArgument.label == nil
            else {
                throw DiagnosticsError(
                    syntax: expression,
                    domain: domain,
                    id: "cancelOwnerMethodArgumentShape",
                    message: "'@StreamBridge' '.ownerMethod' requires one unlabeled method name and optional 'argumentLabel:' string."
                )
            }

            let methodName = try parseStringLiteral(
                from: methodNameArgument.expression,
                domain: domain,
                id: "cancelOwnerMethodMustBeString"
            )
            guard isValidIdentifier(methodName) else {
                throw DiagnosticsError(
                    syntax: methodNameArgument.expression,
                    domain: domain,
                    id: "cancelOwnerMethodInvalidName",
                    message: "'@StreamBridge' '.ownerMethod' argument must be a valid Swift identifier."
                )
            }

            let argumentLabel: String
            switch call.arguments.count {
            case 1:
                argumentLabel = "_"
            case 2:
                let labelArgument = call.arguments[call.arguments.index(after: call.arguments.startIndex)]
                guard labelArgument.label?.text == "argumentLabel" else {
                    throw DiagnosticsError(
                        syntax: labelArgument,
                        domain: domain,
                        id: "cancelOwnerMethodInvalidArgumentLabelName",
                        message: "'@StreamBridge' '.ownerMethod' optional second argument must be labeled 'argumentLabel:'."
                    )
                }
                let parsedLabel = try parseStringLiteral(
                    from: labelArgument.expression,
                    domain: domain,
                    id: "cancelOwnerMethodArgumentLabelMustBeString"
                )
                guard parsedLabel == "_" || isValidIdentifier(parsedLabel) else {
                    throw DiagnosticsError(
                        syntax: labelArgument.expression,
                        domain: domain,
                        id: "cancelOwnerMethodInvalidArgumentLabelValue",
                        message: "'@StreamBridge' '.ownerMethod' 'argumentLabel:' must be '_' or a valid Swift identifier."
                    )
                }
                argumentLabel = parsedLabel
            default:
                throw DiagnosticsError(
                    syntax: expression,
                    domain: domain,
                    id: "cancelOwnerMethodArgumentShape",
                    message: "'@StreamBridge' '.ownerMethod' requires one unlabeled method name and optional 'argumentLabel:' string."
                )
            }

            return .ownerMethod(name: methodName, argumentLabel: argumentLabel)
        }

        throw DiagnosticsError(
            syntax: expression,
            domain: domain,
            id: "cancelUnsupported",
            message: "'@StreamBridge' cancel must be '.none', '.ownerMethod(\"...\", argumentLabel: \"...\")', or '.tokenMethod'."
        )
    }

    static func parseBuffering(
        from expression: ExprSyntax,
        domain: String
    ) throws -> BufferingStrategy {
        if calledCaseName(from: expression) == "unbounded" {
            return .unbounded
        }

        if let call = expression.as(FunctionCallExprSyntax.self) {
            let caseName = calledCaseName(from: call.calledExpression)
            guard call.arguments.count == 1,
                  let argument = call.arguments.first,
                  argument.label == nil
            else {
                throw DiagnosticsError(
                    syntax: expression,
                    domain: domain,
                    id: "bufferingArgumentShape",
                    message: "'@StreamBridge' buffering cases require one unlabeled capacity argument."
                )
            }

            let capacitySource = argument.expression.trimmedDescription
            switch caseName {
            case "bufferingOldest":
                return .bufferingOldest(capacitySource)
            case "bufferingNewest":
                return .bufferingNewest(capacitySource)
            default:
                break
            }
        }

        throw DiagnosticsError(
            syntax: expression,
            domain: domain,
            id: "bufferingUnsupported",
            message: "'@StreamBridge' buffering must be '.unbounded', '.bufferingOldest(_)', or '.bufferingNewest(_)'."
        )
    }

    static func parseSafety(
        from expression: ExprSyntax,
        domain: String
    ) throws -> StreamSafety {
        switch calledCaseName(from: expression) {
        case "strict":
            return .strict
        case "unchecked":
            return .unchecked
        default:
            throw DiagnosticsError(
                syntax: expression,
                domain: domain,
                id: "safetyUnsupported",
                message: "'@StreamBridge' safety must be '.strict' or '.unchecked'."
            )
        }
    }

    static func selectedCallbackParameter(
        in parameters: [FunctionParameterSyntax],
        selector: LabelSelector,
        kind: String,
        fallbackSyntax: some SyntaxProtocol
    ) throws -> CallbackParameter {
        let matches = parameters.enumerated().filter { _, parameter in
            parameter.firstName.text == selector.label
        }

        guard let first = matches.first else {
            throw DiagnosticsError(
                syntax: fallbackSyntax,
                domain: "StreamBridgeMacro",
                id: "\(kind)SelectorNotFound",
                message: "'@StreamBridge' could not find a \(kind) callback parameter labeled '\(selector.label)'."
            )
        }

        guard matches.count == 1 else {
            throw DiagnosticsError(
                syntax: first.element,
                domain: "StreamBridgeMacro",
                id: "\(kind)SelectorAmbiguous",
                message: "'@StreamBridge' \(kind) selector '\(selector.label)' is ambiguous."
            )
        }

        let signature = callbackSignature(for: first.element)
        guard let signature else {
            throw DiagnosticsError(
                syntax: first.element,
                domain: "StreamBridgeMacro",
                id: "\(kind)CallbackNotFunction",
                message: "'@StreamBridge' selected \(kind) callback parameter must be a function type."
            )
        }

        return CallbackParameter(
            index: first.offset,
            parameter: first.element,
            signature: signature
        )
    }

    static func callbackSignature(for parameter: FunctionParameterSyntax) -> CallbackSignature? {
        let isSendableClosure = parameter.type.trimmedDescription.contains("@Sendable")
        var type = parameter.type
        while let attributed = type.as(AttributedTypeSyntax.self) {
            type = attributed.baseType
        }

        guard let functionType = type.as(FunctionTypeSyntax.self) else {
            return nil
        }

        let parameterTypes = functionType.parameters.map { $0.type.trimmedDescription }
        let returnTypeSource = functionType.returnClause.type.trimmedDescription
        let returnsVoid = normalizedTypeSource(returnTypeSource) == normalizedTypeSource("Void") ||
            normalizedTypeSource(returnTypeSource) == normalizedTypeSource("()")

        return CallbackSignature(
            arity: parameterTypes.count,
            firstParameterTypeSource: parameterTypes.first,
            returnsVoid: returnsVoid,
            isSendableClosure: isSendableClosure
        )
    }

    static func validateEventSignature(
        _ signature: CallbackSignature,
        syntax: some SyntaxProtocol
    ) throws {
        guard signature.arity == 1, signature.returnsVoid else {
            throw DiagnosticsError(
                syntax: syntax,
                domain: "StreamBridgeMacro",
                id: "invalidEventCallbackSignature",
                message: "'@StreamBridge' event callback must have one parameter and return 'Void'."
            )
        }
    }

    static func validateFailureSignature(
        _ signature: CallbackSignature,
        syntax: some SyntaxProtocol
    ) throws {
        guard signature.arity == 1, signature.returnsVoid else {
            throw DiagnosticsError(
                syntax: syntax,
                domain: "StreamBridgeMacro",
                id: "invalidFailureCallbackSignature",
                message: "'@StreamBridge' failure callback must have one parameter and return 'Void'."
            )
        }
    }

    static func validateCompletionSignature(
        _ signature: CallbackSignature,
        syntax: some SyntaxProtocol
    ) throws {
        guard signature.arity == 0, signature.returnsVoid else {
            throw DiagnosticsError(
                syntax: syntax,
                domain: "StreamBridgeMacro",
                id: "invalidCompletionCallbackSignature",
                message: "'@StreamBridge' completion callback must have zero parameters and return 'Void'."
            )
        }
    }

    static func validateSendableCallback(_ callback: CallbackParameter, kind: String) throws {
        guard callback.signature.isSendableClosure else {
            throw DiagnosticsError(
                syntax: callback.parameter,
                domain: "StreamBridgeMacro",
                id: "\(kind)CallbackMustBeSendable",
                message: "'@StreamBridge' strict safety requires the selected \(kind) callback parameter to be '@Sendable'."
            )
        }
    }

    static func sourceRegistrationInvocationSource(for method: MethodContext) -> String {
        let parameters = Array(method.function.signature.parameterClause.parameters)
        let eventAdapter = eventAdapterSource(for: method)
        let failureAdapter = failureAdapterSource(for: method)
        let completionAdapter = completionAdapterSource()

        let arguments = parameters.enumerated().compactMap { index, parameter -> String? in
            let valueSource: String
            if index == method.eventParameter.index {
                valueSource = eventAdapter
            } else if index == method.failureParameter?.index {
                valueSource = failureAdapter
            } else if index == method.completionParameter?.index {
                valueSource = completionAdapter
            } else if let localName = parameterLocalName(parameter) {
                valueSource = localName
            } else {
                return nil
            }

            let label = parameter.firstName.text
            if label == "_" {
                return valueSource
            }
            return "\(label): \(valueSource)"
        }

        let invocationArguments = arguments.joined(separator: ",\n                    ")
        if invocationArguments.isEmpty {
            return "__streamBridgeOwner.\(method.function.name.text)()"
        }

        return """
        __streamBridgeOwner.\(method.function.name.text)(
                    \(invocationArguments)
                )
        """
    }

    static func eventAdapterSource(for method: MethodContext) -> String {
        let sendabilityLine = method.safety == .strict
            ? "ConcurrencyMacros.__streamBridgeRequireSendable(__streamBridgeEvent)\n                        "
            : ""

        return """
        { __streamBridgeEvent in
                        \(sendabilityLine)__streamBridgeOnEvent(__streamBridgeEvent)
                    }
        """
    }

    static func failureAdapterSource(for method: MethodContext) -> String {
        guard method.failureParameter != nil else {
            return "{}"
        }

        let failureTypeSource = method.failureTypeSource ?? "any Error"
        let sendabilityLine = method.safety == .strict
            ? "ConcurrencyMacros.__streamBridgeRequireSendable(__streamBridgeFailure)\n                        "
            : ""

        return """
        { (__streamBridgeFailure: \(failureTypeSource)) in
                        \(sendabilityLine)__streamBridgeOnFailureTyped(__streamBridgeFailure)
                    }
        """
    }

    static func completionAdapterSource() -> String {
        """
        {
                        __streamBridgeOnCompletion()
                    }
        """
    }

    static func sendabilityCheckLines(for method: MethodContext) -> String {
        guard method.safety == .strict else { return "" }
        return "ConcurrencyMacros.__streamBridgeRequireSendable(__streamBridgeOwner)\n            "
    }

    static func tokenSendabilityCheckLine(for method: MethodContext) -> String {
        guard method.safety == .strict, method.cancellation != .none else { return "" }
        return "ConcurrencyMacros.__streamBridgeRequireSendable(__streamBridgeToken)\n                        "
    }

    static func cancelClosureSource(for method: MethodContext) -> String {
        switch method.cancellation {
        case .none:
            return "nil"
        case .ownerMethod(let methodName, let argumentLabel):
            let invocation = ownerMethodInvocationSource(
                methodName: methodName,
                argumentLabel: argumentLabel
            )
            return """
            { __streamBridgeToken in
                        _ = \(invocation)
                    }
            """
        case .tokenMethod:
            return """
            { __streamBridgeToken in
                        __streamBridgeToken.cancelStreamBridgeToken()
                    }
            """
        }
    }

    static func parameterClauseSource(from parameters: [FunctionParameterSyntax]) -> String {
        let parameterSource = parameters.map { parameter in
            parameter.with(\.trailingComma, nil).trimmedDescription
        }.joined(separator: ", ")
        return parameterSource.isEmpty ? "()" : "(\(parameterSource))"
    }

    static func accessLevelPrefix(for function: FunctionDeclSyntax) -> String {
        let accessLevel = function.modifiers.first { modifier in
            switch modifier.name.text {
            case "private", "fileprivate", "internal", "package", "public", "open":
                return true
            default:
                return false
            }
        }?.trimmedDescription

        guard let accessLevel else { return "" }
        return "\(accessLevel) "
    }

    static func parameterLocalName(_ parameter: FunctionParameterSyntax) -> String? {
        if let secondName = parameter.secondName, secondName.text != "_" {
            return secondName.text
        }

        let firstName = parameter.firstName.text
        guard firstName != "_" else {
            return nil
        }
        return firstName
    }

    static func parseStringLiteral(
        from expression: ExprSyntax,
        domain: String,
        id: String
    ) throws -> String {
        guard let literal = expression.as(StringLiteralExprSyntax.self),
              literal.segments.count == 1,
              let segment = literal.segments.first?.as(StringSegmentSyntax.self)
        else {
            throw DiagnosticsError(
                syntax: expression,
                domain: domain,
                id: id,
                message: "'@StreamBridge' expected a static string literal."
            )
        }
        return segment.content.text
    }

    static func parseMetatypeSource(
        from expression: ExprSyntax,
        domain: String,
        id: String
    ) throws -> String {
        let source = expression.trimmedDescription
        guard source.hasSuffix(".self"), source.count > ".self".count else {
            throw DiagnosticsError(
                syntax: expression,
                domain: domain,
                id: id,
                message: "'@StreamBridge' expected a metatype expression such as 'SocketError.self'."
            )
        }

        return String(source.dropLast(".self".count))
    }

    static func calledCaseName(from expression: ExprSyntax) -> String {
        if let memberAccess = expression.as(MemberAccessExprSyntax.self) {
            return memberAccess.declName.baseName.text
        }
        if let declReference = expression.as(DeclReferenceExprSyntax.self) {
            return declReference.baseName.text
        }
        return ""
    }

    static func isVoidReturnType(_ typeSyntax: TypeSyntax?) -> Bool {
        guard let typeSyntax else { return true }
        let normalized = normalizedTypeSource(typeSyntax.trimmedDescription)
        return normalized == normalizedTypeSource("Void") || normalized == normalizedTypeSource("()")
    }

    static func isOptionalType(_ typeSyntax: TypeSyntax?) -> Bool {
        guard let typeSyntax else { return false }
        if typeSyntax.as(OptionalTypeSyntax.self) != nil {
            return true
        }
        return typeSyntax.trimmedDescription.hasSuffix("?")
    }

    static func normalizedTypeSource(_ source: String) -> String {
        source.replacingOccurrences(of: " ", with: "")
    }

    static func ownerMethodInvocationSource(methodName: String, argumentLabel: String) -> String {
        if argumentLabel == "_" {
            return "__streamBridgeOwner.\(methodName)(__streamBridgeToken)"
        }
        return "__streamBridgeOwner.\(methodName)(\(argumentLabel): __streamBridgeToken)"
    }

    static func isValidIdentifier(_ candidate: String) -> Bool {
        guard let first = candidate.first else { return false }
        guard first.isLetter || first == "_" else { return false }
        return candidate.dropFirst().allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    static func require<T>(
        _ value: T?,
        syntax: some SyntaxProtocol,
        id: String,
        message: String
    ) throws -> T {
        guard let value else {
            throw DiagnosticsError(
                syntax: syntax,
                domain: "StreamBridgeMacro",
                id: id,
                message: message
            )
        }
        return value
    }
}

private struct StreamBridgeMacroDiagnostic: DiagnosticMessage {
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
                message: StreamBridgeMacroDiagnostic(
                    domain: domain,
                    id: id,
                    message: message
                )
            )
        ])
    }
}
