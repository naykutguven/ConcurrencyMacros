//
//  ThreadSafeMethodMacro.swift
//  ConcurrencyMacros
//

import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Wraps synchronous `@ThreadSafe` instance methods in the class storage lock.
public struct ThreadSafeMethodMacro: BodyMacro {
    private enum Constant {
        static let storageName = "_threadSafeStorage"
        static let stateParameterName = "_threadSafeState"
    }

    public static func expansion(
        of attribute: AttributeSyntax,
        providingBodyFor declaration: some DeclSyntaxProtocol & WithOptionalCodeBlockSyntax,
        in context: some MacroExpansionContext
    ) throws -> [CodeBlockItemSyntax] {
        guard let function = declaration.as(FunctionDeclSyntax.self) else {
            throw DiagnosticsError(
                threadSafe: declaration,
                id: "threadSafeMethodInvalidAttachment",
                message: "'@ThreadSafeMethod' can only be attached to instance methods in @ThreadSafe classes."
            )
        }

        guard !function.isStaticOrClassMethod else {
            throw DiagnosticsError(
                threadSafe: function,
                id: "threadSafeMethodStaticUnsupported",
                message: "'@ThreadSafeMethod' does not support 'static' or 'class' methods."
            )
        }

        guard !function.isAsyncFunction else {
            throw DiagnosticsError(
                threadSafe: function,
                id: "threadSafeMethodAsyncUnsupported",
                message: "'@ThreadSafeMethod' supports synchronous instance methods only; use inLock inside async methods at explicit synchronous boundaries."
            )
        }

        guard let classDecl = threadSafeClass(for: function, context: context) else {
            throw DiagnosticsError(
                threadSafe: function,
                id: "threadSafeMethodClassRequired",
                message: "'@ThreadSafeMethod' can only be used inside a nominal @ThreadSafe class."
            )
        }

        let trackedPropertyNames = Set(try classDecl.threadSafeStoredProperties().map(\.nameText))
        try validate(function, attribute: attribute, trackedPropertyNames: trackedPropertyNames)

        guard let body = function.body else {
            return []
        }

        let rewrittenStatements = body.statements.map { statement in
            statement.rewritingThreadSafeMethodReferences(
                trackedPropertyNames: trackedPropertyNames,
                stateParameterName: Constant.stateParameterName
            )
        }.joined()

        let callPrefix: String
        switch (function.hasThreadSafeMethodNonVoidReturn, function.isThrowingFunction) {
        case (true, true):
            callPrefix = "return try "
        case (true, false):
            callPrefix = "return "
        case (false, true):
            callPrefix = "try "
        case (false, false):
            callPrefix = ""
        }

        return [
            CodeBlockItemSyntax(
                stringLiteral: """
                \(callPrefix)\(Constant.storageName).withLock { \(Constant.stateParameterName) in
                \(rewrittenStatements)
                }
                """
            ),
        ]
    }
}

private func threadSafeClass(
    for function: FunctionDeclSyntax,
    context: some MacroExpansionContext
) -> ClassDeclSyntax? {
    var lexicalThreadSafeClass: ClassDeclSyntax?

    for lexicalContext in context.lexicalContext {
        if lexicalContext.as(ExtensionDeclSyntax.self) != nil {
            return nil
        }

        if let classDecl = lexicalContext.as(ClassDeclSyntax.self) {
            lexicalThreadSafeClass = classDecl.hasThreadSafeAttribute ? classDecl : nil
            break
        }
    }

    if function.isDeclaredInExtension {
        return nil
    }

    if let classDecl = function.nearestEnclosingClassDecl,
       classDecl.hasThreadSafeAttribute {
        return classDecl
    }

    return lexicalThreadSafeClass
}

private func validate(
    _ function: FunctionDeclSyntax,
    attribute: AttributeSyntax,
    trackedPropertyNames: Set<String>
) throws {
    if let shadowedParameter = function.parameterLocalNames.first(where: { trackedPropertyNames.contains($0) }) {
        throw shadowingDiagnostic(syntax: function.signature.parameterClause, name: shadowedParameter)
    }

    guard let body = function.body else {
        return
    }

    if let failure = firstValidationFailure(in: Syntax(body), trackedPropertyNames: trackedPropertyNames) {
        switch failure {
        case .closure(let closure):
            throw DiagnosticsError(
                threadSafe: closure,
                id: "threadSafeMethodClosureUnsupported",
                message: "'@ThreadSafeMethod' does not support closures because they can capture locked state; use inLock around the synchronous statements instead."
            )
        case .nestedFunction(let nestedFunction):
            throw DiagnosticsError(
                threadSafe: nestedFunction,
                id: "threadSafeMethodClosureUnsupported",
                message: "'@ThreadSafeMethod' does not support closures because they can capture locked state; use inLock around the synchronous statements instead."
            )
        case .shadowedLocal(let shadowedLocal):
            throw shadowingDiagnostic(syntax: attribute, name: shadowedLocal)
        }
    }
}

private func shadowingDiagnostic(syntax: some SyntaxProtocol, name: String) -> DiagnosticsError {
    DiagnosticsError(
        threadSafe: syntax,
        id: "threadSafeMethodShadowingUnsupported",
        message: "'@ThreadSafeMethod' does not support local or parameter shadowing of tracked property '\(name)'; rename the local value or use inLock explicitly."
    )
}

private extension FunctionDeclSyntax {
    var hasThreadSafeMethodNonVoidReturn: Bool {
        guard let returnType = signature.returnClause?.type else {
            return false
        }

        switch returnType.trimmedDescription.replacingOccurrences(of: " ", with: "") {
        case "Void", "()", "Swift.Void":
            return false
        default:
            return true
        }
    }
}

private enum ThreadSafeMethodValidationFailure {
    case closure(ClosureExprSyntax)
    case nestedFunction(FunctionDeclSyntax)
    case shadowedLocal(String)
}

private func firstValidationFailure(
    in syntax: Syntax,
    trackedPropertyNames: Set<String>
) -> ThreadSafeMethodValidationFailure? {
    if let closure = syntax.as(ClosureExprSyntax.self) {
        return .closure(closure)
    }

    if let function = syntax.as(FunctionDeclSyntax.self) {
        return .nestedFunction(function)
    }

    if let variable = syntax.as(VariableDeclSyntax.self) {
        for binding in variable.bindings {
            if let name = binding.pattern.firstIdentifier(in: trackedPropertyNames) {
                return .shadowedLocal(name)
            }
        }
    }

    if let pattern = syntax.as(IdentifierPatternSyntax.self),
       trackedPropertyNames.contains(pattern.identifier.text) {
        return .shadowedLocal(pattern.identifier.text)
    }

    for child in syntax.children(viewMode: .sourceAccurate) {
        if let failure = firstValidationFailure(in: child, trackedPropertyNames: trackedPropertyNames) {
            return failure
        }
    }

    return nil
}

private struct ThreadSafeMethodReplacement {
    let start: Int
    let end: Int
    let replacement: String
}

private extension CodeBlockItemSyntax {
    func rewritingThreadSafeMethodReferences(
        trackedPropertyNames: Set<String>,
        stateParameterName: String
    ) -> String {
        let replacements = threadSafeMethodReplacements(
            in: Syntax(self),
            trackedPropertyNames: trackedPropertyNames,
            stateParameterName: stateParameterName
        )

        guard !replacements.isEmpty else {
            return description
        }

        let baseOffset = position.utf8Offset
        var bytes = Array(description.utf8)
        for replacement in replacements.sorted(by: { $0.start > $1.start }) {
            let start = replacement.start - baseOffset
            let end = replacement.end - baseOffset
            guard start >= 0, end >= start, end <= bytes.count else {
                continue
            }
            bytes.replaceSubrange(start..<end, with: replacement.replacement.utf8)
        }

        return String(decoding: bytes, as: UTF8.self)
    }
}

private func threadSafeMethodReplacements(
    in syntax: Syntax,
    trackedPropertyNames: Set<String>,
    stateParameterName: String
) -> [ThreadSafeMethodReplacement] {
    if let memberAccess = syntax.as(MemberAccessExprSyntax.self),
       let base = memberAccess.base,
       base.trimmedDescription == "self" {
        let name = memberAccess.declName.baseName.text
        if trackedPropertyNames.contains(name) {
            return [
                ThreadSafeMethodReplacement(
                    start: memberAccess.positionAfterSkippingLeadingTrivia.utf8Offset,
                    end: memberAccess.endPositionBeforeTrailingTrivia.utf8Offset,
                    replacement: "\(stateParameterName).\(name)"
                ),
            ]
        }
    }

    if let reference = syntax.as(DeclReferenceExprSyntax.self) {
        let name = reference.baseName.text
        if trackedPropertyNames.contains(name) {
            return [
                ThreadSafeMethodReplacement(
                    start: reference.positionAfterSkippingLeadingTrivia.utf8Offset,
                    end: reference.endPositionBeforeTrailingTrivia.utf8Offset,
                    replacement: "\(stateParameterName).\(name)"
                ),
            ]
        }
    }

    return syntax.children(viewMode: .sourceAccurate).flatMap { child in
        threadSafeMethodReplacements(
            in: child,
            trackedPropertyNames: trackedPropertyNames,
            stateParameterName: stateParameterName
        )
    }
}

private extension PatternSyntax {
    func firstIdentifier(in names: Set<String>) -> String? {
        if let identifierPattern = self.as(IdentifierPatternSyntax.self),
           names.contains(identifierPattern.identifier.text) {
            return identifierPattern.identifier.text
        }

        for child in children(viewMode: .sourceAccurate) {
            if let pattern = child.as(PatternSyntax.self),
               let name = pattern.firstIdentifier(in: names) {
                return name
            }
        }

        return nil
    }
}
