//
//  ClassDeclSyntax+Extensions.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 09.03.26.
//

import Foundation
import SwiftDiagnostics
import SwiftSyntax

/// Utilities for extracting macro-relevant stored-property metadata from class declarations.
extension ClassDeclSyntax {
    /// Returns mutable stored properties tracked by `@ThreadSafe`.
    func threadSafeStoredProperties() throws -> [ThreadSafeStoredProperty] {
        var storedProperties = [ThreadSafeStoredProperty]()

        for member in memberBlock.members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else {
                continue
            }

            switch try varDecl.threadSafeStoredProperty() {
            case .ignored, .intentionallyIgnored:
                continue
            case .tracked(let property):
                storedProperties.append(property)
            }
        }

        return storedProperties
    }

    /// Returns the sendability mode selected by the class declaration.
    func threadSafeMode() throws -> ThreadSafeMode {
        switch explicitSendableConformanceKind {
        case .checked:
            guard isFinalDeclaration else {
                throw DiagnosticsError(
                    threadSafe: self,
                    id: "finalClassRequired",
                    message: "@ThreadSafe checked Sendable classes must be 'final'; mark the class 'final' or use '@unchecked Sendable' if subclass state is intentionally outside macro checking."
                )
            }
            return .checked
        case .unchecked:
            return .unchecked
        case .none:
            throw DiagnosticsError(
                threadSafe: self,
                id: "sendableConformanceRequired",
                message: "@ThreadSafe requires the class to explicitly conform to 'Sendable' or '@unchecked Sendable'."
            )
        }
    }

    /// Indicates whether the class declaration carries `@ThreadSafe`.
    var hasThreadSafeAttribute: Bool {
        attributes.contains { element in
            guard let attribute = element.as(AttributeSyntax.self) else {
                return false
            }
            let name = attribute.attributeName.trimmedDescription.replacingOccurrences(of: " ", with: "")
            return name == "ThreadSafe" || name.hasSuffix(".ThreadSafe")
        }
    }

    /// Returns true when the class contains mutable state marked with `@ThreadSafeIgnored`.
    var hasThreadSafeIgnoredMutableState: Bool {
        memberBlock.members.contains { member in
            guard let variable = member.decl.as(VariableDeclSyntax.self),
                  variable.bindingSpecifier.text == "var"
            else {
                return false
            }
            return variable.hasThreadSafeIgnoredAttribute
        }
    }

    /// Indicates whether the class declaration is explicitly `final`.
    var isFinalDeclaration: Bool {
        modifiers.contains { modifier in
            modifier.name.tokenKind == .keyword(.final) || modifier.name.text == "final"
        }
    }

    /// Indicates whether the class declares checked `Sendable` conformance explicitly.
    var hasExplicitSendableConformance: Bool {
        explicitSendableConformanceKind == .checked
    }

    /// Indicates whether the class declares `@unchecked Sendable` conformance explicitly.
    var hasExplicitUncheckedSendableConformance: Bool {
        explicitSendableConformanceKind == .unchecked
    }

    var explicitSendableConformanceKind: SendableConformanceKind {
        guard let inheritedTypes = inheritanceClause?.inheritedTypes else {
            return .none
        }

        var hasCheckedSendable = false

        for inheritedType in inheritedTypes {
            let normalizedTypeSource = inheritedType.type.trimmedDescription
                .replacingOccurrences(of: " ", with: "")

            if normalizedTypeSource == "@uncheckedSendable" || normalizedTypeSource == "@uncheckedSwift.Sendable" {
                return .unchecked
            }

            if normalizedTypeSource == "Sendable" || normalizedTypeSource == "Swift.Sendable" {
                hasCheckedSendable = true
            }
        }

        return hasCheckedSendable ? .checked : .none
    }

    enum SendableConformanceKind {
        case none
        case checked
        case unchecked
    }
}
