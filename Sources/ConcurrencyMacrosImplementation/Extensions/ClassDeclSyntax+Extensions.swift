//
//  ClassDeclSyntax+Extensions.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 09.03.26.
//

import Foundation
import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import RegexBuilder

/// Utilities for extracting macro-relevant stored-property metadata from class declarations.
extension ClassDeclSyntax {
    private static var trailingCallSuffixRegex: Regex<Substring> {
        Regex {
            "("
            ZeroOrMore {
                CharacterClass.anyOf(")").inverted
            }
            ")"
            Anchor.endOfLine
        }
    }

    private static var integerLiteralRegex: Regex<Substring> {
        Regex {
            Anchor.startOfLine
            Optionally { "-" }
            OneOrMore(.digit)
            Anchor.endOfLine
        }
    }

    private static var doubleLiteralRegex: Regex<Substring> {
        Regex {
            Anchor.startOfLine
            Optionally { "-" }
            OneOrMore(.digit)
            Optionally { "." }
            ZeroOrMore(.digit)
            Anchor.endOfLine
        }
    }

    private static var quotedStringRegex: Regex<Substring> {
        Regex {
            Anchor.startOfLine
            "\""
            ZeroOrMore {
                CharacterClass.anyOf("\n").inverted
            }
            "\""
            Anchor.endOfLine
        }
    }

    /// Returns the list of mutable stored properties in the class.
    var storedVariables: [(name: String, type: String, defaultValue: String?)] {
        var storedVars = [(String, String, String?)]()

        for member in memberBlock.members {
            guard
                let varDecl = member.decl.as(VariableDeclSyntax.self),
                varDecl.isMutable
            else { continue }

            for binding in varDecl.bindings {
                if
                    binding.accessorBlock == nil,
                    let pattern = binding.pattern.as(IdentifierPatternSyntax.self)
                {
                    let name = pattern.identifier.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let defaultValue = binding.initializer?.value.trimmedDescription
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? binding
                        .typeAnnotation?.type.defaultValueForOptional

                    if let typeAnnotation = binding.typeAnnotation {
                        let type = typeAnnotation.type.trimmedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                        storedVars.append((name, type, defaultValue))
                    } else if let defaultValue {
                        // Heuristically tries to infer the type from the default value
                        let value = stripTrailingCallSuffix(from: defaultValue)
                            .trimmingCharacters(in: .whitespacesAndNewlines)

                        let type: String =
                        if value == "true" || value == "false" {
                            "Bool"
                        } else if value.wholeMatch(of: Self.integerLiteralRegex) != nil {
                            "Int"
                        } else if value.wholeMatch(of: Self.doubleLiteralRegex) != nil {
                            "Double"
                        } else if value.wholeMatch(of: Self.quotedStringRegex) != nil {
                            "String"
                        } else {
                            value
                        }
                        storedVars.append((name, type, defaultValue))
                    }
                }
            }
        }
        return storedVars
    }

    private func stripTrailingCallSuffix(from value: String) -> String {
        guard let match = value.firstMatch(of: Self.trailingCallSuffixRegex) else {
            return value
        }
        return String(value[..<match.range.lowerBound])
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
