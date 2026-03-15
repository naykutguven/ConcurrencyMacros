//
//  FunctionDeclSyntax+Extensions.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 15.03.26.
//

import SwiftSyntax

/// Function declaration helpers used by `@SingleFlightActor` expansion.
extension FunctionDeclSyntax {
    /// Indicates whether this declaration is a static or class method.
    var isStaticOrClassMethod: Bool {
        modifiers.contains { modifier in
            let name = modifier.name.text
            return name == "static" || name == "class"
        }
    }

    /// Indicates whether this declaration is explicitly marked `nonisolated`.
    var isNonisolatedMethod: Bool {
        modifiers.contains { $0.name.text == "nonisolated" }
    }

    /// Indicates whether this function is `async`.
    var isAsyncFunction: Bool {
        signature.effectSpecifiers?.asyncSpecifier != nil
    }

    /// Indicates whether this function has a `throws` effect.
    var isThrowingFunction: Bool {
        signature.effectSpecifiers?.throwsClause != nil
    }

    /// Indicates whether this function uses typed-throws syntax.
    var hasTypedThrows: Bool {
        signature.effectSpecifiers?.throwsClause?.type != nil
    }

    /// Indicates whether this declaration declares generic parameters or constraints.
    var isGenericFunction: Bool {
        genericParameterClause != nil || genericWhereClause != nil
    }

    /// Indicates whether the return type is an opaque `some` type.
    var hasOpaqueReturnType: Bool {
        guard let returnType = signature.returnClause?.type else {
            return false
        }

        if let someOrAny = returnType.as(SomeOrAnyTypeSyntax.self) {
            return someOrAny.someOrAnySpecifier.text == "some"
        }

        return returnType.trimmedDescription.hasPrefix("some ")
    }

    /// Returns the explicit return type source, or `Void` when omitted.
    var returnTypeSource: String {
        signature.returnClause?.type.trimmedDescription ?? "Void"
    }

    /// Returns local parameter names used inside the function body, in declaration order.
    var parameterLocalNames: [String] {
        signature.parameterClause.parameters.compactMap { parameter in
            if let secondName = parameter.secondName, secondName.text != "_" {
                return secondName.text
            }

            let firstName = parameter.firstName.text
            if firstName != "_" {
                return firstName
            }

            return nil
        }
    }

    /// Returns the source used to forward current method parameters to a synthesized helper call.
    var singleFlightForwardedArgumentsSource: String {
        signature.parameterClause.parameters.compactMap { parameter in
            let localName: String? = {
                if let secondName = parameter.secondName, secondName.text != "_" {
                    return secondName.text
                }

                let firstName = parameter.firstName.text
                if firstName != "_" {
                    return firstName
                }

                return nil
            }()

            guard let localName else { return nil }
            let label = parameter.firstName.text

            if label == "_" {
                return localName
            }
            return "\(label): \(localName)"
        }.joined(separator: ", ")
    }

    /// Returns a diagnostic message describing the first unsupported parameter form, if any.
    var unsupportedSingleFlightParameterMessage: String? {
        for parameter in signature.parameterClause.parameters {
            if parameter.type.trimmedDescription.hasPrefix("inout ") {
                return "'@SingleFlightActor' does not support 'inout' parameters."
            }

            if parameter.ellipsis != nil {
                return "'@SingleFlightActor' does not support variadic parameters."
            }

            let parameterType = parameter.type.trimmedDescription
            if parameterType.contains("each ") || parameterType.contains("repeat ") {
                return "'@SingleFlightActor' does not support parameter packs."
            }

            let firstName = parameter.firstName.text
            let secondName = parameter.secondName?.text
            if firstName == "_", secondName == nil || secondName == "_" {
                return "'@SingleFlightActor' requires parameters to have a usable local name."
            }
        }

        return nil
    }

    /// Indicates whether the function is declared in an extension.
    var isDeclaredInExtension: Bool {
        nearestEnclosingDeclGroup?.is(ExtensionDeclSyntax.self) == true
    }

    /// Indicates whether the function is declared in an actor nominal type.
    var isDeclaredInActor: Bool {
        nearestEnclosingDeclGroup?.is(ActorDeclSyntax.self) == true
    }

    private var nearestEnclosingDeclGroup: Syntax? {
        var current: Syntax? = Syntax(self).parent
        while let node = current {
            if node.is(ActorDeclSyntax.self) ||
                node.is(ExtensionDeclSyntax.self) ||
                node.is(ClassDeclSyntax.self) ||
                node.is(StructDeclSyntax.self) ||
                node.is(EnumDeclSyntax.self) ||
                node.is(ProtocolDeclSyntax.self)
            {
                return node
            }
            current = node.parent
        }
        return nil
    }
}
