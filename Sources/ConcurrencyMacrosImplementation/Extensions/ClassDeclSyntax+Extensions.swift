//
//  ClassDeclSyntax+Extensions.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 09.03.26.
//

import Foundation
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
            case .ignored:
                continue
            case .tracked(let property):
                storedProperties.append(property)
            }
        }

        return storedProperties
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

    private var explicitSendableConformanceKind: SendableConformanceKind {
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

    private enum SendableConformanceKind {
        case none
        case checked
        case unchecked
    }
}
