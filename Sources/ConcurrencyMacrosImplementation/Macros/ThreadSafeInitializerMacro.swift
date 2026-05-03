//
//  ThreadSafeInitializerMacro.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 09.03.26.
//

import Foundation
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Rewrites initializer bodies to stage assignments and initialize `_state` once values are ready.
public struct ThreadSafeInitializerMacro: BodyMacro {
    /// Rewrites the initializer to initialize the internal state with the stored properties.
    public static func expansion(
        of syntax: AttributeSyntax,
        providingBodyFor declaration: some DeclSyntaxProtocol & WithOptionalCodeBlockSyntax,
        in _: some MacroExpansionContext
    ) throws -> [CodeBlockItemSyntax] {
        guard
            let decl = declaration.body,
            let argument = syntax.arguments?.as(LabeledExprListSyntax.self)?.first
        else {
            return []
        }

        // Parse arguments
        guard let dictExpr = argument.expression.as(DictionaryExprSyntax.self)
        else {
            // Not a dictionary => do nothing
            return decl.statements.compactMap { CodeBlockItemSyntax($0) }
        }

        let elements = dictExpr.content.as(DictionaryElementListSyntax.self) ?? DictionaryElementListSyntax()

        let trackedProperties: [TrackedProperty] = elements.compactMap { element in
            // Parse the key
            guard
                let stringLiteral = element.key.as(StringLiteralExprSyntax.self),
                let firstSegment = stringLiteral.segments.first?.as(StringSegmentSyntax.self)
            else {
                return nil
            }

            let keyName = firstSegment.content.text

            // Parse the type
            guard
                let callExpr = element.value.as(FunctionCallExprSyntax.self),
                let genericType = callExpr.calledExpression.as(GenericSpecializationExprSyntax.self),
                let typeName = genericType.genericArgumentClause.arguments.first?.argument.trimmedDescription
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            else {
                return nil
            }

            // Parse the optional default value
            var defaultValue: String? = nil
            for arg in callExpr.arguments {
                if arg.label?.text == "value" {
                    defaultValue = arg.expression.trimmedDescription
                }
            }
            if defaultValue == nil, typeName.hasSuffix("?") { defaultValue = "nil" }

            return TrackedProperty(name: keyName, type: typeName, defaultValue: defaultValue)
        }

        let trackedNames = Set(trackedProperties.map(\.name))
        let requiredNames = Set(trackedProperties.filter(\.isRequired).map(\.name))
        var trackedAssignmentsByOffset: [Int: TrackedAssignment] = [:]
        var assignedRequiredNames = Set<String>()
        var shadowedTrackedNames = Set<String>()

        for (offset, statement) in decl.statements.enumerated() {
            defer {
                shadowedTrackedNames.formUnion(topLevelLocalNames(in: statement, trackedNames: trackedNames))
            }

            guard let assignment = trackedAssignment(
                in: statement,
                trackedNames: trackedNames,
                shadowedNames: shadowedTrackedNames
            ) else {
                continue
            }

            trackedAssignmentsByOffset[offset] = assignment
            if requiredNames.contains(assignment.propertyName) {
                assignedRequiredNames.insert(assignment.propertyName)
            }
        }

        if let missingRequiredProperty = trackedProperties.first(where: { $0.isRequired && !assignedRequiredNames.contains($0.name) }) {
            throw DiagnosticsError(
                threadSafe: declaration,
                id: "requiredInitializerAssignmentUnsupported",
                message: "Initializer must assign tracked property '\(missingRequiredProperty.name)' with a plain top-level assignment before @ThreadSafe state initialization."
            )
        }

        let lastRequiredAssignmentOffset = trackedAssignmentsByOffset
            .filter { requiredNames.contains($0.value.propertyName) }
            .map(\.key)
            .max() ?? -1

        var preStateShadowedTrackedNames = Set<String>()
        for (offset, statement) in decl.statements.enumerated() where offset <= lastRequiredAssignmentOffset {
            let unsupportedAssignment = unsupportedPreStateAssignment(
                in: statement,
                topLevelAssignment: trackedAssignmentsByOffset[offset],
                trackedNames: trackedNames,
                shadowedNames: preStateShadowedTrackedNames
            )

            guard let unsupportedAssignment else {
                preStateShadowedTrackedNames.formUnion(topLevelLocalNames(in: statement, trackedNames: trackedNames))
                continue
            }

            throw DiagnosticsError(
                threadSafe: statement,
                id: "unsupportedInitializerAssignment",
                message: "Initializer assignment to tracked property '\(unsupportedAssignment)' must be a plain top-level assignment before @ThreadSafe state initialization."
            )
        }

        // Replace foo = ... by _foo = ... for all stored properties
        var mutatedProperties = Set<String>()
        var statements: [CodeBlockItemSyntax?] = decl.statements.enumerated().flatMap { offset, statement -> [CodeBlockItemSyntax?] in
            if offset > lastRequiredAssignmentOffset {
                return [CodeBlockItemSyntax(statement)]
            }

            if let assignment = trackedAssignmentsByOffset[offset] {
                mutatedProperties.insert(assignment.propertyName)
                return [
                    CodeBlockItemSyntax(stringLiteral: "_\(assignment.propertyName) = \(assignment.rightHandSide.trimmedDescription)"),
                ]
            }

            return [CodeBlockItemSyntax(statement)]
        }

        // Set _state once the required properties have been set
        let addedStatement = CodeBlockItemSyntax(
            stringLiteral: "self._state = ConcurrencyMacros.Mutex<_State>(_State(\(trackedProperties.map { "\($0.name): _\($0.name)" }.joined(separator: ", "))))")
        statements.insert(addedStatement, at: lastRequiredAssignmentOffset + 1)

        // Add variables to hold the properties while they are created
        for property in trackedProperties.reversed() {
            let isMutated = mutatedProperties.contains(property.name)
            if let defaultValue = property.defaultValue {
                statements.insert(
                    CodeBlockItemSyntax(stringLiteral: "\(isMutated ? "var" : "let") _\(property.name): \(property.type) = \(defaultValue)"),
                    at: 0)
            } else {
                statements.insert(CodeBlockItemSyntax(stringLiteral: "\(isMutated ? "var" : "let") _\(property.name): \(property.type)"), at: 0)
            }
        }

        return statements.compactMap(\.self)
    }

    private static func trackedAssignment(
        in statement: CodeBlockItemSyntax,
        trackedNames: Set<String>,
        shadowedNames: Set<String>
    ) -> TrackedAssignment? {
        guard
            case .expr(let expression) = statement.item,
            let assignmentParts = assignmentParts(from: expression),
            let target = trackedAssignmentTarget(from: assignmentParts.leftHandSide),
            trackedNames.contains(target.propertyName),
            !target.isShadowed(by: shadowedNames)
        else {
            return nil
        }

        return TrackedAssignment(propertyName: target.propertyName, rightHandSide: assignmentParts.rightHandSide)
    }

    private static func unsupportedPreStateAssignment(
        in statement: CodeBlockItemSyntax,
        topLevelAssignment: TrackedAssignment?,
        trackedNames: Set<String>,
        shadowedNames: Set<String>
    ) -> String? {
        if let topLevelAssignment {
            return firstTrackedAssignment(
                in: topLevelAssignment.rightHandSide,
                trackedNames: trackedNames,
                shadowedNames: shadowedNames
            )
        }

        return firstTrackedAssignment(
            in: statement,
            trackedNames: trackedNames,
            shadowedNames: shadowedNames
        )
    }

    private static func firstTrackedAssignment(
        in node: some SyntaxProtocol,
        trackedNames: Set<String>,
        shadowedNames: Set<String>
    ) -> String? {
        let syntax = Syntax(node)
        if let expression = syntax.as(ExprSyntax.self),
           let assignmentParts = assignmentParts(from: expression),
           let target = trackedAssignmentTarget(from: assignmentParts.leftHandSide),
           trackedNames.contains(target.propertyName),
           !target.isShadowed(by: shadowedNames)
        {
            return target.propertyName
        }

        for child in syntax.children(viewMode: .sourceAccurate) {
            if let propertyName = firstTrackedAssignment(
                in: child,
                trackedNames: trackedNames,
                shadowedNames: shadowedNames
            ) {
                return propertyName
            }
        }

        return nil
    }

    private static func topLevelLocalNames(
        in statement: CodeBlockItemSyntax,
        trackedNames: Set<String>
    ) -> Set<String> {
        guard
            case .decl(let declaration) = statement.item,
            let variable = declaration.as(VariableDeclSyntax.self)
        else {
            return []
        }

        return Set(
            variable.bindings.flatMap { binding in
                localNames(in: binding.pattern).filter { trackedNames.contains($0) }
            }
        )
    }

    private static func localNames(in pattern: PatternSyntax) -> [String] {
        if let identifierPattern = pattern.as(IdentifierPatternSyntax.self) {
            return [identifierPattern.identifier.text]
        }

        if let tuplePattern = pattern.as(TuplePatternSyntax.self) {
            return tuplePattern.elements.flatMap { element in
                localNames(in: element.pattern)
            }
        }

        if let valueBindingPattern = pattern.as(ValueBindingPatternSyntax.self) {
            return localNames(in: valueBindingPattern.pattern)
        }

        return []
    }

    private static func assignmentParts(from expression: ExprSyntax) -> (leftHandSide: ExprSyntax, rightHandSide: ExprSyntax)? {
        if let sequenceExpression = expression.as(SequenceExprSyntax.self) {
            let elements = Array(sequenceExpression.elements)
            guard
                elements.count >= 3,
                elements[1].is(AssignmentExprSyntax.self),
                elements.dropFirst(2).allSatisfy({ !$0.is(AssignmentExprSyntax.self) })
            else {
                return nil
            }

            let rightHandSideElements = Array(elements.dropFirst(2))
            let rightHandSide = rightHandSideElements.count == 1
                ? rightHandSideElements[0]
                : ExprSyntax(SequenceExprSyntax(elements: ExprListSyntax(rightHandSideElements)))

            return (leftHandSide: elements[0], rightHandSide: rightHandSide)
        }

        if let infixExpression = expression.as(InfixOperatorExprSyntax.self),
           infixExpression.operator.is(AssignmentExprSyntax.self)
        {
            return (
                leftHandSide: infixExpression.leftOperand,
                rightHandSide: infixExpression.rightOperand
            )
        }

        return nil
    }

    private static func trackedAssignmentTarget(from expression: ExprSyntax) -> TrackedAssignmentTarget? {
        if let referenceExpression = expression.as(DeclReferenceExprSyntax.self) {
            return .bare(referenceExpression.baseName.text)
        }

        guard
            let memberAccessExpression = expression.as(MemberAccessExprSyntax.self),
            let baseExpression = memberAccessExpression.base?.as(DeclReferenceExprSyntax.self),
            baseExpression.baseName.text == "self"
        else {
            return nil
        }

        return .explicitSelf(memberAccessExpression.declName.baseName.text)
    }

    private enum TrackedAssignmentTarget {
        case bare(String)
        case explicitSelf(String)

        var propertyName: String {
            switch self {
            case .bare(let name), .explicitSelf(let name):
                return name
            }
        }

        func isShadowed(by names: Set<String>) -> Bool {
            switch self {
            case .bare(let name):
                return names.contains(name)
            case .explicitSelf:
                return false
            }
        }
    }
}

private struct TrackedProperty {
    let name: String
    let type: String
    let defaultValue: String?

    var isRequired: Bool {
        defaultValue == nil
    }
}

private struct TrackedAssignment {
    let propertyName: String
    let rightHandSide: ExprSyntax
}
