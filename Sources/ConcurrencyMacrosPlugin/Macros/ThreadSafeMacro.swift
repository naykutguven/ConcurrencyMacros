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
    static let internalStateName = "_internalState"
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
        guard let classDecl = declaration.as(ClassDeclSyntax.self) else { return [] }
        let storedVariables = classDecl.storedVariables

        var members = [DeclSyntax]()

        let hasInitializer = classDecl.memberBlock.members.contains(where: { $0.decl.as(InitializerDeclSyntax.self) != nil })
        if !hasInitializer {
            // Generate and initialize _internalState property
            let variables = try storedVariables.map { name, _, defaultValue in
                guard let defaultValue else {
                    throw DiagnosticsError(
                        syntax: classDecl,
                        message: "Property '\(name)' must have a default value or the class must define an initializer.")
                }
                return "\(name): \(defaultValue)"
            }
            let decl = "private let \(Constant.internalStateName) = Mutex<_InternalState>(_InternalState(\(variables.joined(separator: ", "))))"
            let internalStateProperty = DeclSyntax("""
        \(raw: decl)
        """)
            members.append(internalStateProperty)
        } else {
            // Generate _internalState property
            let internalStateProperty = DeclSyntax("""
        private let \(raw: Constant.internalStateName): Mutex<_InternalState>
        """)
            members.append(internalStateProperty)
        }

        // Generate _InternalState struct with the stored properties
        var internalStateFields = ""
        for (name, type, _) in storedVariables {
            internalStateFields += "    var \(name): \(type)\n"
        }

        let internalStateStruct = DeclSyntax("""
      private struct _InternalState: Sendable {
      \(raw: internalStateFields)}
      """)
          members.append(internalStateStruct)

        // Generate `inLock` function
        let mutateFunc = DeclSyntax("""
          @discardableResult
          private func inLock<Result: Sendable>(_ mutation: @Sendable (inout _InternalState) -> Result) -> Result {
              _internalState.mutate(mutation)
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
        // Add @ThreadSafeProperty to stored var properties
        if let property = member.as(VariableDeclSyntax.self) {
            // Don't apply if the property is already tracked
            if
                property.attributes.contains(where: {
                    $0.as(AttributeSyntax.self)?.attributeName.as(IdentifierTypeSyntax.self)?.name.text == Constant.trackedMacroName
                })
            {
                return []
            }

            if property.isMutable {
                // Apply the @ThreadSafeProperty attribute
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
            guard let classDecl = group.as(ClassDeclSyntax.self) else { return [] }
            let storedVariablesNames = classDecl.storedVariables

            let argumentListExpr: String = {
                if storedVariablesNames.isEmpty { return "[:]" }
                let arguments = storedVariablesNames.map { key, type, defaultValue in
                    if let defaultValue {
                        "\"\(key)\": TypeErased<\(type)>(value: \(defaultValue)),"
                    } else {
                        "\"\(key)\": TypeErased<\(type)>(),"
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

// MARK: - SendableDiagnostic

/// Diagnostic message emitted when thread-safe macro expansion constraints are violated.
struct SendableDiagnostic: DiagnosticMessage {
    /// Human-readable diagnostic text.
    let message: String

    /// Stable diagnostic identifier for tooling and assertions.
    var diagnosticID: MessageID {
        MessageID(domain: "ThreadSafeMacro", id: "propertyReplacement")
    }

    /// Severity used for emitted diagnostics.
    var severity: DiagnosticSeverity {
        .error
    }
}

// MARK: - DiagnosticsError Extension

/// Convenience constructors for emitting diagnostics from macro helpers.
extension DiagnosticsError {
    /// Creates a diagnostics error containing one error-level message anchored to `syntax`.
    ///
    /// - Parameters:
    ///   - syntax: The syntax node associated with the diagnostic.
    ///   - message: The diagnostic message text.
    init(syntax: some SyntaxProtocol, message: String) {
        self.init(diagnostics: [
            Diagnostic(node: Syntax(syntax), message: SendableDiagnostic(message: message)),
        ])
    }
}
