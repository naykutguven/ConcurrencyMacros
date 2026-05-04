//
//  ThreadSafeMacro.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 09.03.26.
//

import Foundation
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

// MARK: - Constants

private enum Constant {
    static let trackedMacroName = "ThreadSafeProperty"
    static let initializerMacroName = "ThreadSafeInitializer"
    static let stateName = "_state"
}

/// A macro that makes class properties thread-safe by using an atomic internal state.
public struct ThreadSafeMacro: MemberMacro {
    /// Adds the internal state type and its corresponding property to the class.
    public static func expansion(
        of _: AttributeSyntax,
        providingMembersOf declaration: some DeclSyntaxProtocol,
        conformingTo _: [TypeSyntax],
        in _: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let classDecl = declaration.as(ClassDeclSyntax.self) else {
            throw DiagnosticsError(
                threadSafe: declaration,
                id: "invalidAttachment",
                message: "@ThreadSafe can only be attached to class declarations."
            )
        }
        let storedProperties = try classDecl.threadSafeStoredProperties()

        var members = [DeclSyntax]()

        let hasInitializer = classDecl.memberBlock.members.contains(where: { $0.decl.as(InitializerDeclSyntax.self) != nil })
        if !hasInitializer {
            // Generate and initialize _state property
            let variables = try storedProperties.map { property in
                guard let defaultValue = property.defaultValueDescription else {
                    throw DiagnosticsError(
                        syntax: classDecl,
                        message: "Property '\(property.nameText)' must have a default value or the class must define an initializer."
                    )
                }
                return "\(property.nameText): \(defaultValue)"
            }
            let decl = "private let \(Constant.stateName) = ConcurrencyMacros.Mutex<_State>(_State(\(variables.joined(separator: ", "))))"
            let stateProperty = DeclSyntax("""
        \(raw: decl)
        """)
            members.append(stateProperty)
        } else {
            // Generate _state property
            let stateProperty = DeclSyntax("""
        private let \(raw: Constant.stateName): ConcurrencyMacros.Mutex<_State>
        """)
            members.append(stateProperty)
        }

        // Generate _State struct with the stored properties
        var internalStateFields = ""
        for property in storedProperties {
            internalStateFields += "    var \(property.nameText): \(property.typeDescription)\n"
        }

        let internalStateStruct = DeclSyntax("""
      private struct _State: Sendable {
      \(raw: internalStateFields)}
      """)
          members.append(internalStateStruct)

        // Generate `inLock` function
        let mutateFunc = DeclSyntax("""
          @discardableResult
          private func inLock<Result: Sendable>(_ mutation: @Sendable (inout _State) -> Result) -> Result {
              _state.mutate(mutation)
          }
      """)
        members.append(mutateFunc)

        return members
    }
}

// MARK: MemberAttributeMacro

/// Adds member attributes required by `@ThreadSafe` synthesized behavior.
extension ThreadSafeMacro: MemberAttributeMacro {
    /// Adds `@ThreadSafeProperty` and `@ThreadSafeInitializer` attributes to the class members.
    public static func expansion(
        of _: AttributeSyntax,
        attachedTo group: some DeclGroupSyntax,
        providingAttributesFor member: some DeclSyntaxProtocol,
        in _: some MacroExpansionContext
    ) throws -> [AttributeSyntax] {
        guard let classDecl = group.as(ClassDeclSyntax.self) else { return [] }

        // Add @ThreadSafeProperty to stored var properties
        if let property = member.as(VariableDeclSyntax.self) {
            switch try property.threadSafeStoredProperty() {
            case .ignored:
                return []
            case .tracked:
                guard !property.hasThreadSafePropertyAttribute else {
                    return []
                }

                return [
                    AttributeSyntax(
                        attributeName: IdentifierTypeSyntax(
                            name: .identifier(Constant.trackedMacroName)
                        )
                    )
                ]
            }
        }

        // Add @ThreadSafeInitializer to initializers (not convenience ones)
        if let initDecl = member.as(InitializerDeclSyntax.self),
           !initDecl.modifiers.contains(where: { $0.name.text == "convenience" }) {
            let storedProperties = try classDecl.threadSafeStoredProperties()

            let argumentListExpr: String = {
                if storedProperties.isEmpty { return "[:]" }
                let arguments = storedProperties.map { property in
                    if let defaultValue = property.defaultValueDescription {
                        "\"\(property.nameText)\": ConcurrencyMacros.TypeErased<\(property.typeDescription)>(value: \(defaultValue)),"
                    } else {
                        "\"\(property.nameText)\": ConcurrencyMacros.TypeErased<\(property.typeDescription)>(),"
                    }
                }.joined(separator: "\n")
                return "[\n\(arguments)\n]"
            }()

            let argumentList = LabeledExprListSyntax(
                [
                    LabeledExprSyntax(expression: ExprSyntax(stringLiteral: argumentListExpr)),
                ]
            )

            return [
                AttributeSyntax(
                    attributeName: IdentifierTypeSyntax(
                        name: .identifier(Constant.initializerMacroName)),
                    leftParen: TokenSyntax.leftParenToken(),
                    arguments: AttributeSyntax.Arguments.argumentList(argumentList),
                    rightParen: TokenSyntax.rightParenToken()
                )
            ]
        }

        return []
    }
}
