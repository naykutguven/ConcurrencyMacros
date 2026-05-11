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
    static let methodMacroName = "_ThreadSafeMethod"
    static let storageName = "_threadSafeStorage"
    static let stateName = "_ThreadSafeState"
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
        let mode = try classDecl.threadSafeMode()
        if mode == .checked && classDecl.hasThreadSafeIgnoredMutableState {
            throw DiagnosticsError(
                threadSafe: classDecl,
                id: "ignoredStateRequiresUncheckedSendable",
                message: "@ThreadSafeIgnored mutable state requires '@unchecked Sendable' because checked Sendable cannot verify unmanaged state."
            )
        }
        try classDecl.validateNoThreadSafeSynthesizedMemberConflicts(
            names: [Constant.storageName, Constant.stateName, "inLock"]
        )

        let storedProperties = try classDecl.threadSafeStoredProperties()
        if mode == .checked {
            try classDecl.validateNoThreadSafeSynthesizedMemberConflicts(
                names: Set(storedProperties.map { "_ThreadSafeSendable_\($0.nameText)" }),
                includeMutableVariables: true
            )
        }

        var members = [DeclSyntax]()
        let storageType = "\(mode.storageTypeName)<\(Constant.stateName)>"

        let hasDesignatedInitializer = classDecl.memberBlock.members.contains { member in
            guard let initializer = member.decl.as(InitializerDeclSyntax.self) else {
                return false
            }

            return !initializer.isConvenience
        }
        if !hasDesignatedInitializer {
            // Generate and initialize storage directly when no body rewrite is needed.
            let variables = try storedProperties.map { property in
                guard let defaultValue = property.defaultValueDescription else {
                    throw DiagnosticsError(
                        threadSafe: classDecl,
                        id: "missingDefaultValue",
                        message: "Property '\(property.nameText)' must have a default value or the class must define a designated initializer."
                    )
                }
                return "\(property.nameText): \(defaultValue)"
            }
            let decl = "private let \(Constant.storageName) = \(storageType)(\(Constant.stateName)(\(variables.joined(separator: ", "))))"
            let stateProperty = DeclSyntax("""
        \(raw: decl)
        """)
            members.append(stateProperty)
        } else {
            // Generate storage property for ThreadSafeInitializerMacro to initialize.
            let stateProperty = DeclSyntax("""
        private let \(raw: Constant.storageName): \(raw: storageType)
        """)
            members.append(stateProperty)
        }

        // Generate _ThreadSafeState struct with the stored properties
        var internalStateFields = ""
        for property in storedProperties {
            internalStateFields += "    var \(property.nameText): \(property.typeDescription)\n"
        }

        let internalStateStruct = DeclSyntax("""
      private struct \(raw: Constant.stateName)\(raw: mode.stateConformanceSource) {
      \(raw: internalStateFields)}
      """)
          members.append(internalStateStruct)

        if mode == .checked {
            for property in storedProperties {
                let sendabilityCheck = DeclSyntax("""
          private typealias _ThreadSafeSendable_\(raw: property.nameText) = ConcurrencyMacros.ThreadSafeSendabilityCheck<\(raw: property.typeDescription)>
          """)
                members.append(sendabilityCheck)
            }
        }

        // Generate `inLock` function
        let mutateFunc: DeclSyntax
        switch mode {
        case .checked:
            mutateFunc = DeclSyntax("""
          @discardableResult
          private func inLock<Result: Sendable>(_ body: @Sendable (inout \(raw: Constant.stateName)) throws -> Result) rethrows -> Result {
              try \(raw: Constant.storageName).withLock(body)
          }
      """)
        case .unchecked:
            mutateFunc = DeclSyntax("""
          @discardableResult
          private func inLock<Result>(_ body: (inout \(raw: Constant.stateName)) throws -> Result) rethrows -> Result {
              try \(raw: Constant.storageName).withLock(body)
          }
      """)
        }
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
            case .ignored, .intentionallyIgnored:
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
           !initDecl.isConvenience {
            let mode = try classDecl.threadSafeMode()
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

            let payloadSource = """
            storage: "\(mode.storageTypeName)",
            state: "\(Constant.stateName)",
            properties: \(argumentListExpr)
            """

            return [
                AttributeSyntax(stringLiteral: "@\(Constant.initializerMacroName)(\(payloadSource))")
            ]
        }

        // Add the internal body macro to user-marked @ThreadSafeMethod functions.
        if let function = member.as(FunctionDeclSyntax.self),
           function.hasThreadSafeMethodAttribute {
            let storedProperties = try classDecl.threadSafeStoredProperties()
            let properties = storedProperties
                .map { "\"\($0.nameText)\"" }
                .joined(separator: ", ")

            return [
                AttributeSyntax(stringLiteral: "@\(Constant.methodMacroName)(properties: [\(properties)])")
            ]
        }

        return []
    }
}

private extension FunctionDeclSyntax {
    var hasThreadSafeMethodAttribute: Bool {
        attributes.contains { element in
            guard let attribute = element.as(AttributeSyntax.self) else {
                return false
            }
            let name = attribute.attributeName.trimmedDescription
                .replacingOccurrences(of: " ", with: "")
            return name == "ThreadSafeMethod" || name.hasSuffix(".ThreadSafeMethod")
        }
    }
}

private extension InitializerDeclSyntax {
    var isConvenience: Bool {
        modifiers.contains(where: { $0.name.text == "convenience" })
    }
}

private struct ThreadSafeSynthesizedMemberConflict {
    let name: String
    let syntax: Syntax
}

private extension ClassDeclSyntax {
    func validateNoThreadSafeSynthesizedMemberConflicts(
        names: Set<String>,
        includeMutableVariables: Bool = false
    ) throws {
        guard !names.isEmpty else {
            return
        }

        for member in memberBlock.members {
            guard let conflict = member.decl.threadSafeSynthesizedMemberConflict(
                in: names,
                includeMutableVariables: includeMutableVariables
            ) else {
                continue
            }

            throw DiagnosticsError(
                threadSafe: conflict.syntax,
                id: "reservedMemberName",
                message: "@ThreadSafe member name '\(conflict.name)' conflicts with a synthesized @ThreadSafe member; rename the member."
            )
        }
    }
}

private extension DeclSyntax {
    func threadSafeSynthesizedMemberConflict(
        in names: Set<String>,
        includeMutableVariables: Bool
    ) -> ThreadSafeSynthesizedMemberConflict? {
        if let variable = self.as(VariableDeclSyntax.self) {
            // Mutable stored properties already flow through the property extractor so existing
            // property-specific diagnostics stay stable.
            guard includeMutableVariables || variable.bindingSpecifier.text != "var" else {
                return nil
            }

            for binding in variable.bindings {
                if let conflict = binding.pattern.threadSafeSynthesizedMemberConflict(in: names) {
                    return conflict
                }
            }
        }

        if let function = self.as(FunctionDeclSyntax.self),
           names.contains(function.name.text) {
            return ThreadSafeSynthesizedMemberConflict(name: function.name.text, syntax: Syntax(function))
        }

        if let structure = self.as(StructDeclSyntax.self),
           names.contains(structure.name.text) {
            return ThreadSafeSynthesizedMemberConflict(name: structure.name.text, syntax: Syntax(structure))
        }

        if let classDecl = self.as(ClassDeclSyntax.self),
           names.contains(classDecl.name.text) {
            return ThreadSafeSynthesizedMemberConflict(name: classDecl.name.text, syntax: Syntax(classDecl))
        }

        if let actor = self.as(ActorDeclSyntax.self),
           names.contains(actor.name.text) {
            return ThreadSafeSynthesizedMemberConflict(name: actor.name.text, syntax: Syntax(actor))
        }

        if let enumeration = self.as(EnumDeclSyntax.self),
           names.contains(enumeration.name.text) {
            return ThreadSafeSynthesizedMemberConflict(name: enumeration.name.text, syntax: Syntax(enumeration))
        }

        if let protocolDecl = self.as(ProtocolDeclSyntax.self),
           names.contains(protocolDecl.name.text) {
            return ThreadSafeSynthesizedMemberConflict(name: protocolDecl.name.text, syntax: Syntax(protocolDecl))
        }

        if let typealiasDecl = self.as(TypeAliasDeclSyntax.self),
           names.contains(typealiasDecl.name.text) {
            return ThreadSafeSynthesizedMemberConflict(name: typealiasDecl.name.text, syntax: Syntax(typealiasDecl))
        }

        return nil
    }
}

private extension PatternSyntax {
    func threadSafeSynthesizedMemberConflict(in names: Set<String>) -> ThreadSafeSynthesizedMemberConflict? {
        if let identifier = self.as(IdentifierPatternSyntax.self),
           names.contains(identifier.identifier.text) {
            return ThreadSafeSynthesizedMemberConflict(
                name: identifier.identifier.text,
                syntax: Syntax(identifier)
            )
        }

        for child in children(viewMode: .sourceAccurate) {
            if let pattern = child.as(PatternSyntax.self),
               let conflict = pattern.threadSafeSynthesizedMemberConflict(in: names) {
                return conflict
            }
        }

        return nil
    }
}
