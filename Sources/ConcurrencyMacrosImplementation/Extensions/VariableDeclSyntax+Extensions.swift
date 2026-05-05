//
//  VariableDeclSyntax+Extensions.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 09.03.26.
//

import Foundation
import SwiftDiagnostics
import SwiftSyntax

enum ThreadSafeStoredPropertyExtraction {
    case ignored
    case tracked(ThreadSafeStoredProperty)
}

/// Variable declaration helpers used by macro expansion.
extension VariableDeclSyntax {
    func threadSafeStoredProperty() throws -> ThreadSafeStoredPropertyExtraction {
        guard bindingSpecifier.text == "var" else {
            return .ignored
        }

        guard bindings.count == 1, let binding = bindings.first else {
            throw DiagnosticsError(
                threadSafe: self,
                id: "multipleBindingsUnsupported",
                message: "@ThreadSafe supports one stored property per declaration; split this declaration into separate var declarations."
            )
        }

        guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else {
            throw DiagnosticsError(
                threadSafe: binding.pattern,
                id: "unsupportedPropertyPattern",
                message: "@ThreadSafe supports only identifier stored-property patterns."
            )
        }

        let name = pattern.identifier
        if name.isReservedThreadSafeStoredPropertyName {
            throw DiagnosticsError(
                threadSafe: pattern,
                id: "reservedPropertyName",
                message: "@ThreadSafe property name '\(name.text)' conflicts with synthesized storage; rename the property."
            )
        }

        if let accessorBlock = binding.accessorBlock {
            guard !accessorBlock.hasPropertyObserver else {
                throw DiagnosticsError(
                    threadSafe: accessorBlock,
                    id: "propertyObserversUnsupported",
                    message: "@ThreadSafe does not support property observers on stored property '\(name.text)' in 1.0."
                )
            }

            throw DiagnosticsError(
                threadSafe: accessorBlock,
                id: "computedPropertyUnsupported",
                message: "@ThreadSafe does not support computed property '\(name.text)' in 1.0."
            )
        }

        if let unsupportedAttribute = attributes.firstUnsupportedThreadSafeStoredPropertyAttribute {
            if let wrapperName = unsupportedAttribute.likelyPropertyWrapperName {
                throw DiagnosticsError(
                    threadSafe: unsupportedAttribute,
                    id: "propertyWrappersUnsupported",
                    message: "@ThreadSafe does not support property wrapper '\(wrapperName)' on stored property '\(name.text)' in 1.0."
                )
            }

            throw DiagnosticsError(
                threadSafe: self,
                id: "propertyAttributesUnsupported",
                message: "@ThreadSafe does not support attributes on stored property '\(name.text)' in 1.0."
            )
        }

        if let unsupportedModifier = modifiers.firstUnsupportedThreadSafeStoredPropertyModifier {
            throw DiagnosticsError(
                threadSafe: unsupportedModifier,
                id: "propertyModifiersUnsupported",
                message: "@ThreadSafe does not support modifier '\(unsupportedModifier.name.text)' on stored property '\(name.text)' in 1.0."
            )
        }

        let defaultValue = binding.initializer?.value

        if let type = binding.typeAnnotation?.type {
            return .tracked(
                ThreadSafeStoredProperty(
                    name: name,
                    type: type,
                    defaultValue: defaultValue ?? type.defaultValueForOptionalExpr
                )
            )
        }

        guard let defaultValue else {
            throw DiagnosticsError(
                threadSafe: binding,
                id: "missingTypeAnnotation",
                message: "Property '\(name.text)' must declare an explicit type."
            )
        }

        guard let inferredType = defaultValue.simpleLiteralType else {
            throw DiagnosticsError(
                threadSafe: defaultValue,
                id: "complexInferredDefault",
                message: "Property '\(name.text)' must declare an explicit type when the default value is not a simple literal."
            )
        }

        return .tracked(
            ThreadSafeStoredProperty(
                name: name,
                type: TypeSyntax(stringLiteral: inferredType),
                defaultValue: defaultValue
            )
        )
    }

    var hasThreadSafePropertyAttribute: Bool {
        attributes.contains { $0.isThreadSafePropertyAttribute }
    }
}

private extension TokenSyntax {
    var isReservedThreadSafeStoredPropertyName: Bool {
        switch text {
        case "_state", "_State", "inLock":
            return true
        default:
            return false
        }
    }
}

private extension AccessorBlockSyntax {
    var hasPropertyObserver: Bool {
        guard case .accessors(let accessors) = accessors else {
            return false
        }

        return accessors.contains { accessor in
            switch accessor.accessorSpecifier.tokenKind {
            case .keyword(.willSet), .keyword(.didSet):
                return true
            default:
                return false
            }
        }
    }
}

private extension DeclModifierListSyntax {
    var firstUnsupportedThreadSafeStoredPropertyModifier: DeclModifierSyntax? {
        first { !$0.isSupportedThreadSafeStoredPropertyModifier }
    }
}

private extension DeclModifierSyntax {
    var isSupportedThreadSafeStoredPropertyModifier: Bool {
        switch name.text {
        case "open", "public", "package", "internal", "fileprivate", "private":
            return true
        default:
            return false
        }
    }
}

private extension AttributeListSyntax.Element {
    var isThreadSafePropertyAttribute: Bool {
        guard let attribute = self.as(AttributeSyntax.self) else {
            return false
        }
        let name = attribute.attributeName.trimmedDescription
            .replacingOccurrences(of: " ", with: "")
        return name == "ThreadSafeProperty" || name.hasSuffix(".ThreadSafeProperty")
    }
}

private extension AttributeListSyntax {
    var firstUnsupportedThreadSafeStoredPropertyAttribute: AttributeSyntax? {
        for element in self where !element.isThreadSafePropertyAttribute {
            if let attribute = element.as(AttributeSyntax.self) {
                return attribute
            }
        }

        return nil
    }
}

private extension AttributeSyntax {
    private static let knownNonWrapperAttributeNames: Set<String> = [
        "IBInspectable",
        "IBOutlet",
        "IBOutletCollection",
        "GKInspectable",
        "MainActor",
        "NSCopying",
        "NSManaged",
        "Sendable",
    ]

    // Without type information, the best available signal for wrapper-like attributes is a
    // type-style attribute name such as `Clamped` or `MyModule.Clamped`.
    var likelyPropertyWrapperName: String? {
        let normalizedName = attributeName.trimmedDescription.replacingOccurrences(of: " ", with: "")
        guard let lastComponent = normalizedName.split(separator: ".").last else {
            return nil
        }

        guard !Self.knownNonWrapperAttributeNames.contains(String(lastComponent)) else {
            return nil
        }

        guard let firstScalar = lastComponent.unicodeScalars.first,
              CharacterSet.uppercaseLetters.contains(firstScalar)
        else {
            return nil
        }

        return String(lastComponent)
    }
}

private extension ExprSyntax {
    var simpleLiteralType: String? {
        if let prefixedExpression = self.as(PrefixOperatorExprSyntax.self),
           prefixedExpression.operator.text == "-" {
            if prefixedExpression.expression.as(IntegerLiteralExprSyntax.self) != nil {
                return "Int"
            }

            if prefixedExpression.expression.as(FloatLiteralExprSyntax.self) != nil {
                return "Double"
            }
        }

        if self.as(BooleanLiteralExprSyntax.self) != nil {
            return "Bool"
        }

        if self.as(IntegerLiteralExprSyntax.self) != nil {
            return "Int"
        }

        if self.as(FloatLiteralExprSyntax.self) != nil {
            return "Double"
        }

        guard let stringLiteral = self.as(StringLiteralExprSyntax.self),
              stringLiteral.segments.allSatisfy({ $0.as(StringSegmentSyntax.self) != nil })
        else {
            return nil
        }

        return "String"
    }
}
