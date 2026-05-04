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
            throw DiagnosticsError(
                threadSafe: argument.expression,
                id: "invalidInitializerPayload",
                message: "@ThreadSafeInitializer entries must use string keys and generic storage values."
            )
        }

        let elements = dictExpr.content.as(DictionaryElementListSyntax.self) ?? DictionaryElementListSyntax()

        let trackedProperties = try elements.map(parseTrackedProperty)
        if let collidingStagingName = stagingNameCollision(
            in: declaration,
            statements: decl.statements,
            trackedProperties: trackedProperties
        ) {
            throw DiagnosticsError(
                threadSafe: declaration,
                id: "stagingNameCollision",
                message: stagingNameCollisionMessage(for: collidingStagingName)
            )
        }

        let trackedNames = Set(trackedProperties.map(\.name))
        let requiredNames = Set(trackedProperties.filter(\.isRequired).map(\.name))
        var trackedAssignmentsByOffset: [Int: TrackedAssignment] = [:]
        var assignedRequiredNames = Set<String>()
        var shadowedTrackedNames = initializerInoutParameterLocalNames(
            in: declaration,
            trackedNames: trackedNames
        )

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

        if let collidingStagingName = postStateStagingNameReference(
            in: decl.statements,
            after: lastRequiredAssignmentOffset,
            stagingNames: Set(trackedProperties.map { "_\($0.name)" })
        ) {
            throw DiagnosticsError(
                threadSafe: declaration,
                id: "stagingNameCollision",
                message: stagingNameCollisionMessage(for: collidingStagingName)
            )
        }

        var preStateShadowedTrackedNames = initializerParameterLocalNames(
            in: declaration,
            trackedNames: trackedNames
        )
        for (offset, statement) in decl.statements.enumerated() where offset <= lastRequiredAssignmentOffset {
            let unsupportedAccess = unsupportedPreStateAccess(
                in: statement,
                topLevelAssignment: trackedAssignmentsByOffset[offset],
                trackedNames: trackedNames,
                shadowedNames: preStateShadowedTrackedNames
            )

            guard let unsupportedAccess else {
                preStateShadowedTrackedNames.formUnion(topLevelLocalNames(in: statement, trackedNames: trackedNames))
                continue
            }

            throw DiagnosticsError(
                threadSafe: statement,
                id: "unsupportedInitializerAssignment",
                message: "Initializer access to tracked property '\(unsupportedAccess)' before @ThreadSafe state initialization is only supported as the left-hand side of a plain top-level assignment."
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

    private static func parseTrackedProperty(from element: DictionaryElementSyntax) throws -> TrackedProperty {
        guard
            let stringLiteral = element.key.as(StringLiteralExprSyntax.self),
            stringLiteral.segments.count == 1,
            let keySegment = stringLiteral.segments.first?.as(StringSegmentSyntax.self),
            let callExpr = element.value.as(FunctionCallExprSyntax.self),
            let genericType = callExpr.calledExpression.as(GenericSpecializationExprSyntax.self),
            genericType.genericArgumentClause.arguments.count == 1,
            let genericArgument = genericType.genericArgumentClause.arguments.first,
            keySegment.content.text.isValidThreadSafeIdentifier
        else {
            throw DiagnosticsError(
                threadSafe: element,
                id: "invalidInitializerPayload",
                message: "@ThreadSafeInitializer entries must use string keys and generic storage values."
            )
        }

        let typeName = genericArgument.argument.trimmedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typeName.isEmpty else {
            throw DiagnosticsError(
                threadSafe: element,
                id: "invalidInitializerPayload",
                message: "@ThreadSafeInitializer entries must use string keys and generic storage values."
            )
        }

        var defaultValue: String? = nil
        for arg in callExpr.arguments where arg.label?.text == "value" {
            defaultValue = arg.expression.trimmedDescription
        }
        if defaultValue == nil, typeName.hasSuffix("?") { defaultValue = "nil" }

        return TrackedProperty(name: keySegment.content.text, type: typeName, defaultValue: defaultValue)
    }

    private static func stagingNameCollision(
        in declaration: some DeclSyntaxProtocol,
        statements: CodeBlockItemListSyntax,
        trackedProperties: [TrackedProperty]
    ) -> String? {
        let initializerLocals = initializerParameterNames(in: declaration)
        let trackedNames = Set(trackedProperties.map(\.name))

        for property in trackedProperties {
            let stagingName = "_\(property.name)"
            if initializerLocals.contains(stagingName) || trackedNames.contains(stagingName) {
                return stagingName
            }
        }

        var topLevelLocalNames = Set<String>()
        for statement in statements {
            topLevelLocalNames.formUnion(topLevelDeclarationLocalNames(in: statement))
        }

        return trackedProperties
            .map { "_\($0.name)" }
            .first { topLevelLocalNames.contains($0) }
    }

    private static func stagingNameCollisionMessage(for stagingName: String) -> String {
        "@ThreadSafeInitializer staging local '\(stagingName)' conflicts with an initializer parameter, local, or tracked property; rename the property, parameter, or local."
    }

    private static func postStateStagingNameReference(
        in statements: CodeBlockItemListSyntax,
        after lastRequiredAssignmentOffset: Int,
        stagingNames: Set<String>
    ) -> String? {
        for (offset, statement) in statements.enumerated() where offset > lastRequiredAssignmentOffset {
            if let name = firstUnshadowedBareReference(
                in: statement,
                names: stagingNames,
                shadowedNames: []
            ) {
                return name
            }
        }

        return nil
    }

    private static func firstUnshadowedBareReference(
        in node: some SyntaxProtocol,
        names: Set<String>,
        shadowedNames: Set<String>
    ) -> String? {
        let syntax = Syntax(node)

        if isNestedDeclarationContext(syntax) {
            return nil
        }

        if let ifExpression = syntax.as(IfExprSyntax.self) {
            return firstUnshadowedBareReference(
                in: ifExpression,
                names: names,
                shadowedNames: shadowedNames
            )
        }

        if let guardStatement = syntax.as(GuardStmtSyntax.self) {
            return firstUnshadowedBareReference(
                in: guardStatement,
                names: names,
                shadowedNames: shadowedNames
            )
        }

        if let whileStatement = syntax.as(WhileStmtSyntax.self) {
            return firstUnshadowedBareReference(
                in: whileStatement,
                names: names,
                shadowedNames: shadowedNames
            )
        }

        if let closureExpression = syntax.as(ClosureExprSyntax.self) {
            return firstUnshadowedBareReference(
                in: closureExpression,
                names: names,
                shadowedNames: shadowedNames
            )
        }

        if let forStatement = syntax.as(ForStmtSyntax.self) {
            return firstUnshadowedBareReference(
                in: forStatement,
                names: names,
                shadowedNames: shadowedNames
            )
        }

        if let switchCase = syntax.as(SwitchCaseSyntax.self) {
            return firstUnshadowedBareReference(
                in: switchCase,
                names: names,
                shadowedNames: shadowedNames
            )
        }

        if let catchClause = syntax.as(CatchClauseSyntax.self) {
            return firstUnshadowedBareReference(
                in: catchClause,
                names: names,
                shadowedNames: shadowedNames
            )
        }

        if let functionDeclaration = syntax.as(FunctionDeclSyntax.self) {
            return firstUnshadowedBareReference(
                in: functionDeclaration,
                names: names,
                shadowedNames: shadowedNames
            )
        }

        if let statements = syntax.as(CodeBlockItemListSyntax.self) {
            var blockShadowedNames = shadowedNames

            for statement in statements {
                if let name = firstUnshadowedBareReference(
                    in: statement,
                    names: names,
                    shadowedNames: blockShadowedNames
                ) {
                    return name
                }

                blockShadowedNames.formUnion(topLevelLocalNames(in: statement, trackedNames: names))
            }

            return nil
        }

        if let memberAccessExpression = syntax.as(MemberAccessExprSyntax.self) {
            guard let base = memberAccessExpression.base else {
                return nil
            }

            return firstUnshadowedBareReference(
                in: normalizedExpression(base),
                names: names,
                shadowedNames: shadowedNames
            )
        }

        if let referenceExpression = syntax.as(DeclReferenceExprSyntax.self) {
            let name = referenceExpression.baseName.text
            if names.contains(name), !shadowedNames.contains(name) {
                return name
            }
        }

        for child in syntax.children(viewMode: .sourceAccurate) {
            if let name = firstUnshadowedBareReference(
                in: child,
                names: names,
                shadowedNames: shadowedNames
            ) {
                return name
            }
        }

        return nil
    }

    private static func firstUnshadowedBareReference(
        in closureExpression: ClosureExprSyntax,
        names: Set<String>,
        shadowedNames: Set<String>
    ) -> String? {
        if let capture = closureExpression.signature?.capture,
           let name = firstUnshadowedBareReference(
               in: capture,
               names: names,
               shadowedNames: shadowedNames
           ) {
            return name
        }

        var closureShadowedNames = shadowedNames
        if let signature = closureExpression.signature {
            if let capture = signature.capture {
                closureShadowedNames.formUnion(closureCaptureAliasLocalNames(in: capture, names: names))
            }
            closureShadowedNames.formUnion(closureParameterLocalNames(in: signature, trackedNames: names))
        }

        return firstUnshadowedBareReference(
            in: closureExpression.statements,
            names: names,
            shadowedNames: closureShadowedNames
        )
    }

    private static func firstUnshadowedBareReference(
        in forStatement: ForStmtSyntax,
        names: Set<String>,
        shadowedNames: Set<String>
    ) -> String? {
        if let name = firstUnshadowedBareReference(
            in: forStatement.sequence,
            names: names,
            shadowedNames: shadowedNames
        ) {
            return name
        }

        var bodyShadowedNames = shadowedNames
        bodyShadowedNames.formUnion(localNames(in: forStatement.pattern).filter { names.contains($0) })

        if let whereClause = forStatement.whereClause,
           let name = firstUnshadowedBareReference(
               in: whereClause,
               names: names,
               shadowedNames: bodyShadowedNames
           ) {
            return name
        }

        return firstUnshadowedBareReference(
            in: forStatement.body.statements,
            names: names,
            shadowedNames: bodyShadowedNames
        )
    }

    private static func firstUnshadowedBareReference(
        in switchCase: SwitchCaseSyntax,
        names: Set<String>,
        shadowedNames: Set<String>
    ) -> String? {
        var caseShadowedNames = shadowedNames

        if let caseLabel = switchCase.label.as(SwitchCaseLabelSyntax.self) {
            for caseItem in caseLabel.caseItems {
                caseShadowedNames.formUnion(localNames(in: caseItem.pattern).filter { names.contains($0) })
            }

            for caseItem in caseLabel.caseItems {
                if let whereClause = caseItem.whereClause,
                   let name = firstUnshadowedBareReference(
                       in: whereClause,
                       names: names,
                       shadowedNames: caseShadowedNames
                   ) {
                    return name
                }
            }
        }

        return firstUnshadowedBareReference(
            in: switchCase.statements,
            names: names,
            shadowedNames: caseShadowedNames
        )
    }

    private static func firstUnshadowedBareReference(
        in catchClause: CatchClauseSyntax,
        names: Set<String>,
        shadowedNames: Set<String>
    ) -> String? {
        var catchShadowedNames = shadowedNames

        for catchItem in catchClause.catchItems {
            if let pattern = catchItem.pattern {
                catchShadowedNames.formUnion(localNames(in: pattern).filter { names.contains($0) })
            }
        }

        for catchItem in catchClause.catchItems {
            if let whereClause = catchItem.whereClause,
               let name = firstUnshadowedBareReference(
                   in: whereClause,
                   names: names,
                   shadowedNames: catchShadowedNames
               ) {
                return name
            }
        }

        return firstUnshadowedBareReference(
            in: catchClause.body.statements,
            names: names,
            shadowedNames: catchShadowedNames
        )
    }

    private static func firstUnshadowedBareReference(
        in functionDeclaration: FunctionDeclSyntax,
        names: Set<String>,
        shadowedNames: Set<String>
    ) -> String? {
        for parameter in functionDeclaration.signature.parameterClause.parameters {
            if let defaultValue = parameter.defaultValue,
               let name = firstUnshadowedBareReference(
                   in: defaultValue.value,
                   names: names,
                   shadowedNames: shadowedNames
               ) {
                return name
            }
        }

        guard let body = functionDeclaration.body else {
            return nil
        }

        var bodyShadowedNames = shadowedNames
        if names.contains(functionDeclaration.name.text) {
            bodyShadowedNames.insert(functionDeclaration.name.text)
        }
        bodyShadowedNames.formUnion(functionParameterLocalNames(
            in: functionDeclaration.signature.parameterClause,
            trackedNames: names
        ))

        return firstUnshadowedBareReference(
            in: body.statements,
            names: names,
            shadowedNames: bodyShadowedNames
        )
    }

    private static func isNestedDeclarationContext(_ syntax: Syntax) -> Bool {
        syntax.is(ActorDeclSyntax.self)
            || syntax.is(ClassDeclSyntax.self)
            || syntax.is(EnumDeclSyntax.self)
            || syntax.is(ExtensionDeclSyntax.self)
            || syntax.is(ProtocolDeclSyntax.self)
            || syntax.is(StructDeclSyntax.self)
    }

    private static func firstUnshadowedBareReference(
        in ifExpression: IfExprSyntax,
        names: Set<String>,
        shadowedNames: Set<String>
    ) -> String? {
        let conditionScan = scanConditionElementsForBareReference(
            in: ifExpression.conditions,
            names: names,
            shadowedNames: shadowedNames
        )
        if let name = conditionScan.reference {
            return name
        }

        if let name = firstUnshadowedBareReference(
            in: ifExpression.body.statements,
            names: names,
            shadowedNames: conditionScan.shadowedNames
        ) {
            return name
        }

        if let elseIfExpression = ifExpression.elseBody?.as(IfExprSyntax.self) {
            return firstUnshadowedBareReference(
                in: elseIfExpression,
                names: names,
                shadowedNames: shadowedNames
            )
        }

        if let elseBlock = ifExpression.elseBody?.as(CodeBlockSyntax.self) {
            return firstUnshadowedBareReference(
                in: elseBlock.statements,
                names: names,
                shadowedNames: shadowedNames
            )
        }

        return nil
    }

    private static func firstUnshadowedBareReference(
        in guardStatement: GuardStmtSyntax,
        names: Set<String>,
        shadowedNames: Set<String>
    ) -> String? {
        let conditionScan = scanConditionElementsForBareReference(
            in: guardStatement.conditions,
            names: names,
            shadowedNames: shadowedNames
        )
        if let name = conditionScan.reference {
            return name
        }

        return firstUnshadowedBareReference(
            in: guardStatement.body.statements,
            names: names,
            shadowedNames: shadowedNames
        )
    }

    private static func firstUnshadowedBareReference(
        in whileStatement: WhileStmtSyntax,
        names: Set<String>,
        shadowedNames: Set<String>
    ) -> String? {
        let conditionScan = scanConditionElementsForBareReference(
            in: whileStatement.conditions,
            names: names,
            shadowedNames: shadowedNames
        )
        if let name = conditionScan.reference {
            return name
        }

        return firstUnshadowedBareReference(
            in: whileStatement.body.statements,
            names: names,
            shadowedNames: conditionScan.shadowedNames
        )
    }

    private static func scanConditionElementsForBareReference(
        in conditions: ConditionElementListSyntax,
        names: Set<String>,
        shadowedNames: Set<String>
    ) -> (reference: String?, shadowedNames: Set<String>) {
        var conditionShadowedNames = shadowedNames

        for condition in conditions {
            if let name = shorthandOptionalBindingBareReference(
                in: condition,
                names: names,
                shadowedNames: conditionShadowedNames
            ) {
                return (reference: name, shadowedNames: conditionShadowedNames)
            }

            if let name = firstUnshadowedBareReference(
                in: condition,
                names: names,
                shadowedNames: conditionShadowedNames
            ) {
                return (reference: name, shadowedNames: conditionShadowedNames)
            }

            conditionShadowedNames.formUnion(localNames(in: condition, trackedNames: names))
        }

        return (reference: nil, shadowedNames: conditionShadowedNames)
    }

    private static func shorthandOptionalBindingBareReference(
        in conditionElement: ConditionElementSyntax,
        names: Set<String>,
        shadowedNames: Set<String>
    ) -> String? {
        guard
            let optionalBinding = conditionElement.condition.as(OptionalBindingConditionSyntax.self),
            optionalBinding.initializer == nil
        else {
            return nil
        }

        return localNames(in: optionalBinding.pattern)
            .first { names.contains($0) && !shadowedNames.contains($0) }
    }

    private static func unsupportedPreStateAccess(
        in statement: CodeBlockItemSyntax,
        topLevelAssignment: TrackedAssignment?,
        trackedNames: Set<String>,
        shadowedNames: Set<String>
    ) -> String? {
        if let topLevelAssignment {
            return firstTrackedPreStateAccess(
                in: topLevelAssignment.rightHandSide,
                trackedNames: trackedNames,
                shadowedNames: shadowedNames
            )
        }

        return firstTrackedPreStateAccess(
            in: statement,
            trackedNames: trackedNames,
            shadowedNames: shadowedNames
        )
    }

    private static func firstTrackedPreStateAccess(
        in node: some SyntaxProtocol,
        trackedNames: Set<String>,
        shadowedNames: Set<String>
    ) -> String? {
        let syntax = Syntax(node)

        if let ifExpression = syntax.as(IfExprSyntax.self) {
            return firstTrackedPreStateAccess(
                in: ifExpression,
                trackedNames: trackedNames,
                shadowedNames: shadowedNames
            )
        }

        if let guardStatement = syntax.as(GuardStmtSyntax.self) {
            return firstTrackedPreStateAccess(
                in: guardStatement,
                trackedNames: trackedNames,
                shadowedNames: shadowedNames
            )
        }

        if let whileStatement = syntax.as(WhileStmtSyntax.self) {
            return firstTrackedPreStateAccess(
                in: whileStatement,
                trackedNames: trackedNames,
                shadowedNames: shadowedNames
            )
        }

        if let closureExpression = syntax.as(ClosureExprSyntax.self) {
            return firstTrackedPreStateAccess(
                in: closureExpression,
                trackedNames: trackedNames,
                shadowedNames: shadowedNames
            )
        }

        if let forStatement = syntax.as(ForStmtSyntax.self) {
            return firstTrackedPreStateAccess(
                in: forStatement,
                trackedNames: trackedNames,
                shadowedNames: shadowedNames
            )
        }

        if let switchCase = syntax.as(SwitchCaseSyntax.self) {
            return firstTrackedPreStateAccess(
                in: switchCase,
                trackedNames: trackedNames,
                shadowedNames: shadowedNames
            )
        }

        if let catchClause = syntax.as(CatchClauseSyntax.self) {
            return firstTrackedPreStateAccess(
                in: catchClause,
                trackedNames: trackedNames,
                shadowedNames: shadowedNames
            )
        }

        if let functionDeclaration = syntax.as(FunctionDeclSyntax.self) {
            return firstTrackedPreStateAccess(
                in: functionDeclaration,
                trackedNames: trackedNames,
                shadowedNames: shadowedNames
            )
        }

        if let statements = syntax.as(CodeBlockItemListSyntax.self) {
            var blockShadowedNames = shadowedNames

            for statement in statements {
                if let propertyName = firstTrackedPreStateAccess(
                    in: statement,
                    trackedNames: trackedNames,
                    shadowedNames: blockShadowedNames
                ) {
                    return propertyName
                }

                blockShadowedNames.formUnion(topLevelLocalNames(in: statement, trackedNames: trackedNames))
            }

            return nil
        }

        if let memberAccessExpression = syntax.as(MemberAccessExprSyntax.self) {
            if let propertyName = explicitSelfPropertyName(in: memberAccessExpression),
               trackedNames.contains(propertyName) {
                return propertyName
            }

            guard let base = memberAccessExpression.base else {
                return nil
            }

            return firstTrackedPreStateAccess(
                in: normalizedExpression(base),
                trackedNames: trackedNames,
                shadowedNames: shadowedNames
            )
        }

        if let referenceExpression = syntax.as(DeclReferenceExprSyntax.self) {
            let propertyName = referenceExpression.baseName.text
            if trackedNames.contains(propertyName), !shadowedNames.contains(propertyName) {
                return propertyName
            }
        }

        for child in syntax.children(viewMode: .sourceAccurate) {
            if let propertyName = firstTrackedPreStateAccess(
                in: child,
                trackedNames: trackedNames,
                shadowedNames: shadowedNames
            ) {
                return propertyName
            }
        }

        return nil
    }

    private static func firstTrackedPreStateAccess(
        in closureExpression: ClosureExprSyntax,
        trackedNames: Set<String>,
        shadowedNames: Set<String>
    ) -> String? {
        if let capture = closureExpression.signature?.capture,
           let propertyName = firstTrackedPreStateAccess(
               in: capture,
               trackedNames: trackedNames,
               shadowedNames: shadowedNames
           ) {
            return propertyName
        }

        var closureShadowedNames = shadowedNames
        if let signature = closureExpression.signature {
            if let capture = signature.capture {
                closureShadowedNames.formUnion(closureCaptureAliasLocalNames(in: capture, names: trackedNames))
            }
            closureShadowedNames.formUnion(closureParameterLocalNames(in: signature, trackedNames: trackedNames))
        }

        return firstTrackedPreStateAccess(
            in: closureExpression.statements,
            trackedNames: trackedNames,
            shadowedNames: closureShadowedNames
        )
    }

    private static func firstTrackedPreStateAccess(
        in forStatement: ForStmtSyntax,
        trackedNames: Set<String>,
        shadowedNames: Set<String>
    ) -> String? {
        if let propertyName = firstTrackedPreStateAccess(
            in: forStatement.sequence,
            trackedNames: trackedNames,
            shadowedNames: shadowedNames
        ) {
            return propertyName
        }

        var bodyShadowedNames = shadowedNames
        bodyShadowedNames.formUnion(localNames(in: forStatement.pattern).filter { trackedNames.contains($0) })

        if let whereClause = forStatement.whereClause,
           let propertyName = firstTrackedPreStateAccess(
               in: whereClause,
               trackedNames: trackedNames,
               shadowedNames: bodyShadowedNames
           ) {
            return propertyName
        }

        return firstTrackedPreStateAccess(
            in: forStatement.body.statements,
            trackedNames: trackedNames,
            shadowedNames: bodyShadowedNames
        )
    }

    private static func firstTrackedPreStateAccess(
        in switchCase: SwitchCaseSyntax,
        trackedNames: Set<String>,
        shadowedNames: Set<String>
    ) -> String? {
        var caseShadowedNames = shadowedNames

        if let caseLabel = switchCase.label.as(SwitchCaseLabelSyntax.self) {
            for caseItem in caseLabel.caseItems {
                caseShadowedNames.formUnion(localNames(in: caseItem.pattern).filter { trackedNames.contains($0) })
            }

            for caseItem in caseLabel.caseItems {
                if let whereClause = caseItem.whereClause,
                   let propertyName = firstTrackedPreStateAccess(
                       in: whereClause,
                       trackedNames: trackedNames,
                       shadowedNames: caseShadowedNames
                   ) {
                    return propertyName
                }
            }
        }

        return firstTrackedPreStateAccess(
            in: switchCase.statements,
            trackedNames: trackedNames,
            shadowedNames: caseShadowedNames
        )
    }

    private static func firstTrackedPreStateAccess(
        in catchClause: CatchClauseSyntax,
        trackedNames: Set<String>,
        shadowedNames: Set<String>
    ) -> String? {
        var catchShadowedNames = shadowedNames

        for catchItem in catchClause.catchItems {
            if let pattern = catchItem.pattern {
                catchShadowedNames.formUnion(localNames(in: pattern).filter { trackedNames.contains($0) })
            }
        }

        for catchItem in catchClause.catchItems {
            if let whereClause = catchItem.whereClause,
               let propertyName = firstTrackedPreStateAccess(
                   in: whereClause,
                   trackedNames: trackedNames,
                   shadowedNames: catchShadowedNames
               ) {
                return propertyName
            }
        }

        return firstTrackedPreStateAccess(
            in: catchClause.body.statements,
            trackedNames: trackedNames,
            shadowedNames: catchShadowedNames
        )
    }

    private static func firstTrackedPreStateAccess(
        in functionDeclaration: FunctionDeclSyntax,
        trackedNames: Set<String>,
        shadowedNames: Set<String>
    ) -> String? {
        for parameter in functionDeclaration.signature.parameterClause.parameters {
            if let defaultValue = parameter.defaultValue,
               let propertyName = firstTrackedPreStateAccess(
                   in: defaultValue.value,
                   trackedNames: trackedNames,
                   shadowedNames: shadowedNames
               ) {
                return propertyName
            }
        }

        guard let body = functionDeclaration.body else {
            return nil
        }

        var bodyShadowedNames = shadowedNames
        if trackedNames.contains(functionDeclaration.name.text) {
            bodyShadowedNames.insert(functionDeclaration.name.text)
        }
        bodyShadowedNames.formUnion(functionParameterLocalNames(
            in: functionDeclaration.signature.parameterClause,
            trackedNames: trackedNames
        ))

        return firstTrackedPreStateAccess(
            in: body.statements,
            trackedNames: trackedNames,
            shadowedNames: bodyShadowedNames
        )
    }

    private static func explicitSelfPropertyName(in memberAccessExpression: MemberAccessExprSyntax) -> String? {
        guard
            let base = memberAccessExpression.base,
            let baseExpression = normalizedExpression(base).as(DeclReferenceExprSyntax.self),
            baseExpression.baseName.text == "self"
        else {
            return nil
        }

        return memberAccessExpression.declName.baseName.text
    }

    private static func normalizedExpression(_ expression: ExprSyntax) -> ExprSyntax {
        var expression = expression

        while
            let tupleExpression = expression.as(TupleExprSyntax.self),
            tupleExpression.elements.count == 1,
            let element = tupleExpression.elements.first,
            element.label == nil
        {
            expression = element.expression
        }

        return expression
    }

    private static func closureCaptureAliasLocalNames(
        in capture: ClosureCaptureClauseSyntax,
        names: Set<String>
    ) -> Set<String> {
        Set(
            capture.items.compactMap { item in
                let name = item.name.text
                guard item.initializer != nil, name != "_", names.contains(name) else {
                    return nil
                }

                return name
            }
        )
    }

    private static func closureParameterLocalNames(
        in signature: ClosureSignatureSyntax,
        trackedNames: Set<String>
    ) -> Set<String> {
        guard let parameterClause = signature.parameterClause else {
            return []
        }

        switch parameterClause {
        case .simpleInput(let parameters):
            return Set(
                parameters.compactMap { parameter in
                    let name = parameter.name.text
                    guard name != "_", trackedNames.contains(name) else {
                        return nil
                    }

                    return name
                }
            )

        case .parameterClause(let parameterClause):
            return Set(
                parameterClause.parameters.compactMap { parameter in
                    let name = parameter.secondName?.text ?? parameter.firstName.text
                    guard name != "_", trackedNames.contains(name) else {
                        return nil
                    }

                    return name
                }
            )
        }
    }

    private static func functionParameterLocalNames(
        in parameterClause: FunctionParameterClauseSyntax,
        trackedNames: Set<String>
    ) -> Set<String> {
        Set(
            parameterClause.parameters.compactMap { parameter in
                let name = parameter.secondName?.text ?? parameter.firstName.text
                guard name != "_", trackedNames.contains(name) else {
                    return nil
                }

                return name
            }
        )
    }

    private static func firstTrackedPreStateAccess(
        in ifExpression: IfExprSyntax,
        trackedNames: Set<String>,
        shadowedNames: Set<String>
    ) -> String? {
        let conditionScan = scanConditionElements(
            in: ifExpression.conditions,
            trackedNames: trackedNames,
            shadowedNames: shadowedNames
        )
        if let propertyName = conditionScan.unsupportedAccess {
            return propertyName
        }

        if let propertyName = firstTrackedPreStateAccess(
            in: ifExpression.body.statements,
            trackedNames: trackedNames,
            shadowedNames: conditionScan.shadowedNames
        ) {
            return propertyName
        }

        if let elseIfExpression = ifExpression.elseBody?.as(IfExprSyntax.self) {
            return firstTrackedPreStateAccess(
                in: elseIfExpression,
                trackedNames: trackedNames,
                shadowedNames: shadowedNames
            )
        }

        if let elseBlock = ifExpression.elseBody?.as(CodeBlockSyntax.self) {
            return firstTrackedPreStateAccess(
                in: elseBlock.statements,
                trackedNames: trackedNames,
                shadowedNames: shadowedNames
            )
        }

        return nil
    }

    private static func firstTrackedPreStateAccess(
        in guardStatement: GuardStmtSyntax,
        trackedNames: Set<String>,
        shadowedNames: Set<String>
    ) -> String? {
        let conditionScan = scanConditionElements(
            in: guardStatement.conditions,
            trackedNames: trackedNames,
            shadowedNames: shadowedNames
        )
        if let propertyName = conditionScan.unsupportedAccess {
            return propertyName
        }

        return firstTrackedPreStateAccess(
            in: guardStatement.body.statements,
            trackedNames: trackedNames,
            shadowedNames: shadowedNames
        )
    }

    private static func firstTrackedPreStateAccess(
        in whileStatement: WhileStmtSyntax,
        trackedNames: Set<String>,
        shadowedNames: Set<String>
    ) -> String? {
        let conditionScan = scanConditionElements(
            in: whileStatement.conditions,
            trackedNames: trackedNames,
            shadowedNames: shadowedNames
        )
        if let propertyName = conditionScan.unsupportedAccess {
            return propertyName
        }

        return firstTrackedPreStateAccess(
            in: whileStatement.body.statements,
            trackedNames: trackedNames,
            shadowedNames: conditionScan.shadowedNames
        )
    }

    private static func scanConditionElements(
        in conditions: ConditionElementListSyntax,
        trackedNames: Set<String>,
        shadowedNames: Set<String>
    ) -> (unsupportedAccess: String?, shadowedNames: Set<String>) {
        var conditionShadowedNames = shadowedNames

        for condition in conditions {
            if let propertyName = shorthandOptionalBindingTrackedAccess(
                in: condition,
                trackedNames: trackedNames,
                shadowedNames: conditionShadowedNames
            ) {
                return (unsupportedAccess: propertyName, shadowedNames: conditionShadowedNames)
            }

            if let propertyName = firstTrackedPreStateAccess(
                in: condition,
                trackedNames: trackedNames,
                shadowedNames: conditionShadowedNames
            ) {
                return (unsupportedAccess: propertyName, shadowedNames: conditionShadowedNames)
            }

            conditionShadowedNames.formUnion(localNames(in: condition, trackedNames: trackedNames))
        }

        return (unsupportedAccess: nil, shadowedNames: conditionShadowedNames)
    }

    private static func shorthandOptionalBindingTrackedAccess(
        in conditionElement: ConditionElementSyntax,
        trackedNames: Set<String>,
        shadowedNames: Set<String>
    ) -> String? {
        guard
            let optionalBinding = conditionElement.condition.as(OptionalBindingConditionSyntax.self),
            optionalBinding.initializer == nil
        else {
            return nil
        }

        return localNames(in: optionalBinding.pattern)
            .first { trackedNames.contains($0) && !shadowedNames.contains($0) }
    }

    private static func initializerParameterLocalNames(
        in declaration: some DeclSyntaxProtocol,
        trackedNames: Set<String>
    ) -> Set<String> {
        guard let initializer = declaration.as(InitializerDeclSyntax.self) else {
            return []
        }

        return Set(
            initializer.signature.parameterClause.parameters.compactMap { parameter -> String? in
                let localName = parameter.secondName?.text ?? parameter.firstName.text
                guard localName != "_", trackedNames.contains(localName) else {
                    return nil
                }

                return localName
            }
        )
    }

    private static func initializerInoutParameterLocalNames(
        in declaration: some DeclSyntaxProtocol,
        trackedNames: Set<String>
    ) -> Set<String> {
        guard let initializer = declaration.as(InitializerDeclSyntax.self) else {
            return []
        }

        return Set(
            initializer.signature.parameterClause.parameters.compactMap { parameter -> String? in
                let localName = parameter.secondName?.text ?? parameter.firstName.text
                guard
                    localName != "_",
                    trackedNames.contains(localName),
                    parameter.type.hasInoutSpecifier
                else {
                    return nil
                }

                return localName
            }
        )
    }

    private static func initializerParameterNames(in declaration: some DeclSyntaxProtocol) -> Set<String> {
        guard let initializer = declaration.as(InitializerDeclSyntax.self) else {
            return []
        }

        return Set(
            initializer.signature.parameterClause.parameters.compactMap { parameter -> String? in
                let localName = parameter.secondName?.text ?? parameter.firstName.text
                guard localName != "_" else {
                    return nil
                }

                return localName
            }
        )
    }

    private static func topLevelDeclarationLocalNames(in statement: CodeBlockItemSyntax) -> Set<String> {
        guard case .decl(let declaration) = statement.item else {
            return []
        }

        if let variable = declaration.as(VariableDeclSyntax.self) {
            return Set(
                variable.bindings.flatMap { binding in
                    localNames(in: binding.pattern)
                }
            )
        }

        if let function = declaration.as(FunctionDeclSyntax.self) {
            return [function.name.text]
        }

        return []
    }

    private static func topLevelLocalNames(
        in statement: CodeBlockItemSyntax,
        trackedNames: Set<String>
    ) -> Set<String> {
        if case .stmt(let statement) = statement.item,
           let guardStatement = statement.as(GuardStmtSyntax.self) {
            return localNames(in: guardStatement.conditions, trackedNames: trackedNames)
        }

        guard case .decl(let declaration) = statement.item else {
            return []
        }

        if let variable = declaration.as(VariableDeclSyntax.self) {
            return Set(
                variable.bindings.flatMap { binding in
                    localNames(in: binding.pattern).filter { trackedNames.contains($0) }
                }
            )
        }

        if let function = declaration.as(FunctionDeclSyntax.self),
           trackedNames.contains(function.name.text) {
            return [function.name.text]
        }

        return []
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

        if let expressionPattern = pattern.as(ExpressionPatternSyntax.self) {
            return localNames(inPatternExpression: expressionPattern.expression)
        }

        return []
    }

    private static func localNames(inPatternExpression expression: ExprSyntax) -> [String] {
        let expression = normalizedExpression(expression)

        if let referenceExpression = expression.as(DeclReferenceExprSyntax.self) {
            return [referenceExpression.baseName.text]
        }

        if let optionalChainingExpression = expression.as(OptionalChainingExprSyntax.self) {
            return localNames(inPatternExpression: optionalChainingExpression.expression)
        }

        if let patternExpression = expression.as(PatternExprSyntax.self) {
            return localNames(in: patternExpression.pattern)
        }

        if let functionCallExpression = expression.as(FunctionCallExprSyntax.self) {
            return functionCallExpression.arguments.flatMap { argument in
                localNames(inPatternExpression: argument.expression)
            }
        }

        return []
    }

    private static func localNames(
        in conditions: ConditionElementListSyntax,
        trackedNames: Set<String>
    ) -> Set<String> {
        Set(
            conditions.flatMap { conditionElement in
                localNames(in: conditionElement, trackedNames: trackedNames)
            }
        )
    }

    private static func localNames(
        in conditionElement: ConditionElementSyntax,
        trackedNames: Set<String>
    ) -> [String] {
        if let optionalBinding = conditionElement.condition.as(OptionalBindingConditionSyntax.self) {
            return localNames(in: optionalBinding.pattern).filter { trackedNames.contains($0) }
        }

        if let matchingPattern = conditionElement.condition.as(MatchingPatternConditionSyntax.self) {
            return localNames(in: matchingPattern.pattern).filter { trackedNames.contains($0) }
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
        let expression = normalizedExpression(expression)

        if let referenceExpression = expression.as(DeclReferenceExprSyntax.self) {
            return .bare(referenceExpression.baseName.text)
        }

        guard
            let memberAccessExpression = expression.as(MemberAccessExprSyntax.self),
            let propertyName = explicitSelfPropertyName(in: memberAccessExpression)
        else {
            return nil
        }

        return .explicitSelf(propertyName)
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

private extension TypeSyntax {
    var hasInoutSpecifier: Bool {
        guard let attributedType = self.as(AttributedTypeSyntax.self) else {
            return false
        }

        return attributedType.specifiers.contains { specifier in
            specifier.as(SimpleTypeSpecifierSyntax.self)?.specifier.text == "inout"
        }
    }
}

private extension String {
    var isValidThreadSafeIdentifier: Bool {
        guard let firstScalar = unicodeScalars.first else {
            return false
        }

        let identifierHead = CharacterSet.letters.union(CharacterSet(charactersIn: "_"))
        let identifierBody = identifierHead.union(.decimalDigits)

        return identifierHead.contains(firstScalar)
            && unicodeScalars.dropFirst().allSatisfy { identifierBody.contains($0) }
    }
}
