//
//  ThreadSafeMethodMacroTests.swift
//  ConcurrencyMacros
//

import SwiftDiagnostics
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import Testing
@testable import ConcurrencyMacrosImplementation

@Suite("ThreadSafeMethodMacro")
struct ThreadSafeMethodMacroTests {
    private var emptyThreadSafeMethodBodyAttribute: AttributeSyntax {
        AttributeSyntax(stringLiteral: "@_ThreadSafeMethod(properties: [])")
    }

    private static let callUnsupportedMessage =
        "'@ThreadSafeMethod' only supports calls rooted on tracked properties while holding the storage lock; use inLock explicitly for method calls or other helper calls."

    @Test("Wraps sync method body and rewrites bare and self tracked references")
    func wrapsSyncMethodBodyAndRewritesTrackedReferences() throws {
        let function = try firstAttributedFunction(
            in: """
            @ThreadSafe
            final class Counter: Sendable {
                var count: Int = 0
                var total: Int = 0

                @ThreadSafeMethod
                func bump(by amount: Int) {
                    count += amount
                    self.total = self.count + count
                }
            }
            """
        )

        let body = try expandBody(for: function)

        #expect(body.count == 1)
        let output = body[0].nonWhitespaceDescription
        #expect(output.hasPrefix("_threadSafeStorage.withLock{_threadSafeStatein"))
        #expect(output.contains("_threadSafeState.count+=amount"))
        #expect(output.contains("_threadSafeState.total=_threadSafeState.count+_threadSafeState.count"))
    }

    @Test("Wraps throwing returning method with return try")
    func wrapsThrowingReturningMethodWithReturnTry() throws {
        let function = try firstAttributedFunction(
            in: """
            @ThreadSafe
            final class Counter: Sendable {
                var count: Int = 0

                @ThreadSafeMethod
                func next() throws -> Int {
                    count += 1
                    return self.count
                }
            }
            """
        )

        let body = try expandBody(for: function)

        #expect(body.count == 1)
        let output = body[0].nonWhitespaceDescription
        #expect(output.hasPrefix("returntry_threadSafeStorage.withLock{_threadSafeStatein"))
        #expect(output.contains("_threadSafeState.count+=1"))
        #expect(output.contains("return_threadSafeState.count"))
    }

    @Test("Allows member calls rooted on tracked property")
    func allowsMemberCallsRootedOnTrackedProperty() throws {
        let function = try firstAttributedFunction(
            in: """
            @ThreadSafe
            final class Store: Sendable {
                var items: [Int] = []

                @ThreadSafeMethod
                func append(_ value: Int) {
                    items.append(value)
                    self.items.append(value + 1)
                }
            }
            """
        )

        let body = try expandBody(for: function)

        #expect(body.count == 1)
        let output = body[0].nonWhitespaceDescription
        #expect(output.contains("_threadSafeState.items.append(value)"))
        #expect(output.contains("_threadSafeState.items.append(value+1)"))
    }

    @Test("Rewrites parenthesized self property references")
    func rewritesParenthesizedSelfPropertyReferences() throws {
        let function = try firstAttributedFunction(
            in: """
            @ThreadSafe
            final class Store: Sendable {
                var count: Int = 0
                var items: [Int] = []

                @ThreadSafeMethod
                func update(_ value: Int) {
                    (self).count += 1
                    ((self)).items.append(value)
                }
            }
            """
        )

        let body = try expandBody(for: function)

        #expect(body.count == 1)
        let output = body[0].nonWhitespaceDescription
        #expect(output.contains("_threadSafeState.count+=1"))
        #expect(output.contains("_threadSafeState.items.append(value)"))
    }

    @Test("Rejects unqualified helper calls")
    func rejectsUnqualifiedHelperCalls() throws {
        let function = try firstAttributedFunction(
            in: """
            @ThreadSafe
            final class Counter: Sendable {
                var count: Int = 0

                @ThreadSafeMethod
                func refresh() {
                    helper()
                }

                func helper() {
                    count += 1
                }
            }
            """
        )

        assertThreadSafeMethodDiagnostic(
            for: function,
            expectedMessage: Self.callUnsupportedMessage,
            expectedID: MessageID(domain: "ThreadSafeMacro", id: "threadSafeMethodCallUnsupported")
        )
    }

    @Test("Rejects parenthesized unqualified helper calls")
    func rejectsParenthesizedUnqualifiedHelperCalls() throws {
        let function = try firstAttributedFunction(
            in: """
            @ThreadSafe
            final class Counter: Sendable {
                var count: Int = 0

                @ThreadSafeMethod
                func refresh() {
                    (helper)()
                }

                func helper() {
                    count += 1
                }
            }
            """
        )

        assertThreadSafeMethodDiagnostic(
            for: function,
            expectedMessage: Self.callUnsupportedMessage,
            expectedID: MessageID(domain: "ThreadSafeMacro", id: "threadSafeMethodCallUnsupported")
        )
    }

    @Test("Rejects self helper calls")
    func rejectsSelfHelperCalls() throws {
        let function = try firstAttributedFunction(
            in: """
            @ThreadSafe
            final class Counter: Sendable {
                var count: Int = 0

                @ThreadSafeMethod
                func refresh() {
                    self.helper()
                }

                func helper() {
                    count += 1
                }
            }
            """
        )

        assertThreadSafeMethodDiagnostic(
            for: function,
            expectedMessage: Self.callUnsupportedMessage,
            expectedID: MessageID(domain: "ThreadSafeMacro", id: "threadSafeMethodCallUnsupported")
        )
    }

    @Test("Rejects parenthesized self helper calls")
    func rejectsParenthesizedSelfHelperCalls() throws {
        let function = try firstAttributedFunction(
            in: """
            @ThreadSafe
            final class Counter: Sendable {
                var count: Int = 0

                @ThreadSafeMethod
                func refresh() {
                    (self.helper)()
                }

                func helper() {
                    count += 1
                }
            }
            """
        )

        assertThreadSafeMethodDiagnostic(
            for: function,
            expectedMessage: Self.callUnsupportedMessage,
            expectedID: MessageID(domain: "ThreadSafeMacro", id: "threadSafeMethodCallUnsupported")
        )
    }

    @Test("Rejects type-qualified owner method reference calls")
    func rejectsTypeQualifiedOwnerMethodReferenceCalls() throws {
        let function = try firstAttributedFunction(
            in: """
            @ThreadSafe
            final class Counter: Sendable {
                var count: Int = 0

                @ThreadSafeMethod
                func refresh() {
                    Self.helper(self)()
                }

                func helper() {
                    count += 1
                }
            }
            """
        )

        assertThreadSafeMethodDiagnostic(
            for: function,
            expectedMessage: Self.callUnsupportedMessage,
            expectedID: MessageID(domain: "ThreadSafeMacro", id: "threadSafeMethodCallUnsupported")
        )
    }

    @Test("Rejects metatype owner method reference calls")
    func rejectsMetatypeOwnerMethodReferenceCalls() throws {
        let function = try firstAttributedFunction(
            in: """
            @ThreadSafe
            final class Counter: Sendable {
                var count: Int = 0

                @ThreadSafeMethod
                func refresh() {
                    Counter.self.helper(self)()
                }

                func helper() {
                    count += 1
                }
            }
            """
        )

        assertThreadSafeMethodDiagnostic(
            for: function,
            expectedMessage: Self.callUnsupportedMessage,
            expectedID: MessageID(domain: "ThreadSafeMacro", id: "threadSafeMethodCallUnsupported")
        )
    }

    @Test("Rejects parenthesized metatype owner method reference calls")
    func rejectsParenthesizedMetatypeOwnerMethodReferenceCalls() throws {
        let function = try firstAttributedFunction(
            in: """
            @ThreadSafe
            final class Counter: Sendable {
                var count: Int = 0

                @ThreadSafeMethod
                func refresh() {
                    (Counter).self.helper(self)()
                }

                func helper() {
                    count += 1
                }
            }
            """
        )

        assertThreadSafeMethodDiagnostic(
            for: function,
            expectedMessage: Self.callUnsupportedMessage,
            expectedID: MessageID(domain: "ThreadSafeMacro", id: "threadSafeMethodCallUnsupported")
        )
    }

    @Test("Rejects non-tracked free function calls")
    func rejectsNonTrackedFreeFunctionCalls() throws {
        let function = try firstAttributedFunction(
            in: """
            @ThreadSafe
            final class Counter: Sendable {
                var count: Int = 0

                @ThreadSafeMethod
                func normalized() -> Int {
                    max(count, 0)
                }
            }
            """
        )

        assertThreadSafeMethodDiagnostic(
            for: function,
            expectedMessage: Self.callUnsupportedMessage,
            expectedID: MessageID(domain: "ThreadSafeMacro", id: "threadSafeMethodCallUnsupported")
        )
    }

    @Test("Rejects non-tracked constructor calls")
    func rejectsNonTrackedConstructorCalls() throws {
        let function = try firstAttributedFunction(
            in: """
            @ThreadSafe
            final class Counter: Sendable {
                var count: Int = 0

                @ThreadSafeMethod
                func normalized() -> Int {
                    Int(count)
                }
            }
            """
        )

        assertThreadSafeMethodDiagnostic(
            for: function,
            expectedMessage: Self.callUnsupportedMessage,
            expectedID: MessageID(domain: "ThreadSafeMacro", id: "threadSafeMethodCallUnsupported")
        )
    }

    @Test("Rejects key path expressions")
    func rejectsKeyPathExpressions() throws {
        let function = try firstAttributedFunction(
            in: """
            @ThreadSafe
            final class Counter: Sendable {
                var count: Int = 0

                @ThreadSafeMethod
                func keyPath() -> KeyPath<Counter, Int> {
                    \\Counter.count
                }
            }
            """
        )

        assertThreadSafeMethodDiagnostic(
            for: function,
            expectedMessage: "'@ThreadSafeMethod' does not support key path expressions because tracked properties are rewritten under lock; use inLock explicitly.",
            expectedID: MessageID(domain: "ThreadSafeMacro", id: "threadSafeMethodKeyPathUnsupported")
        )
    }

    @Test("Rejects nested local type declarations")
    func rejectsNestedLocalTypeDeclarations() throws {
        let function = try firstAttributedFunction(
            in: """
            @ThreadSafe
            final class Counter: Sendable {
                var count: Int = 0

                @ThreadSafeMethod
                func refresh() {
                    struct Snapshot {
                        let count: Int
                    }
                    count += 1
                }
            }
            """
        )

        assertThreadSafeMethodDiagnostic(
            for: function,
            expectedMessage: "'@ThreadSafeMethod' does not support nested declarations because they can capture or shadow locked state; use inLock around the synchronous statements instead.",
            expectedID: MessageID(domain: "ThreadSafeMacro", id: "threadSafeMethodNestedDeclarationUnsupported")
        )
    }

    @Test("Rejects nested typealias declarations")
    func rejectsNestedTypealiasDeclarations() throws {
        let function = try firstAttributedFunction(
            in: """
            @ThreadSafe
            final class Counter: Sendable {
                var count: Int = 0

                @ThreadSafeMethod
                func refresh() {
                    typealias Owner = Counter
                    Owner.helper(self)()
                }

                func helper() {
                    count += 1
                }
            }
            """
        )

        assertThreadSafeMethodDiagnostic(
            for: function,
            expectedMessage: "'@ThreadSafeMethod' does not support nested declarations because they can capture or shadow locked state; use inLock around the synchronous statements instead.",
            expectedID: MessageID(domain: "ThreadSafeMacro", id: "threadSafeMethodNestedDeclarationUnsupported")
        )
    }

    @Test("Rejects async methods")
    func rejectsAsyncMethods() throws {
        let function = try firstAttributedFunction(
            in: """
            @ThreadSafe
            final class Counter: Sendable {
                var count: Int = 0

                @ThreadSafeMethod
                func refresh() async {
                    count += 1
                }
            }
            """
        )

        assertThreadSafeMethodDiagnostic(
            for: function,
            expectedMessage: "'@ThreadSafeMethod' supports synchronous instance methods only; use inLock inside async methods at explicit synchronous boundaries.",
            expectedID: MessageID(domain: "ThreadSafeMacro", id: "threadSafeMethodAsyncUnsupported")
        )
    }

    @Test(
        "Rejects static and class methods",
        arguments: ["static", "class"]
    )
    func rejectsStaticAndClassMethods(modifier: String) throws {
        let function = try firstAttributedFunction(
            in: """
            @ThreadSafe
            class Counter: @unchecked Sendable {
                var count: Int = 0

                @ThreadSafeMethod
                \(modifier) func refresh() {
                    count += 1
                }
            }
            """
        )

        assertThreadSafeMethodDiagnostic(
            for: function,
            expectedMessage: "'@ThreadSafeMethod' does not support 'static' or 'class' methods.",
            expectedID: MessageID(domain: "ThreadSafeMacro", id: "threadSafeMethodStaticUnsupported")
        )
    }

    @Test("Rejects use outside ThreadSafe class")
    func rejectsUseOutsideThreadSafeClass() throws {
        let function = try firstAttributedFunction(
            in: """
            final class Counter: Sendable {
                var count: Int = 0

                @ThreadSafeMethod
                func refresh() {
                    count += 1
                }
            }
            """
        )

        assertThreadSafeMethodDiagnostic(
            for: function,
            expectedMessage: "'@ThreadSafeMethod' can only be used inside a nominal @ThreadSafe class.",
            expectedID: MessageID(domain: "ThreadSafeMacro", id: "threadSafeMethodClassRequired")
        )
    }

    @Test("Rejects extension use")
    func rejectsExtensionUse() throws {
        let function = try firstAttributedFunction(
            in: """
            @ThreadSafe
            final class Counter: Sendable {
                var count: Int = 0
            }

            extension Counter {
                @ThreadSafeMethod
                func refresh() {
                    count += 1
                }
            }
            """
        )

        assertThreadSafeMethodDiagnostic(
            for: function,
            expectedMessage: "'@ThreadSafeMethod' can only be used inside a nominal @ThreadSafe class.",
            expectedID: MessageID(domain: "ThreadSafeMacro", id: "threadSafeMethodClassRequired")
        )
    }

    @Test("Rejects parameter shadowing of tracked property")
    func rejectsParameterShadowingOfTrackedProperty() throws {
        let function = try firstAttributedFunction(
            in: """
            @ThreadSafe
            final class Counter: Sendable {
                var count: Int = 0

                @ThreadSafeMethod
                func replace(count: Int) {
                    self.count = count
                }
            }
            """
        )

        assertThreadSafeMethodDiagnostic(
            for: function,
            expectedMessage: "'@ThreadSafeMethod' does not support local or parameter shadowing of tracked property 'count'; rename the local value or use inLock explicitly.",
            expectedID: MessageID(domain: "ThreadSafeMacro", id: "threadSafeMethodShadowingUnsupported")
        )
    }

    @Test("Rejects local shadowing of tracked property")
    func rejectsLocalShadowingOfTrackedProperty() throws {
        let function = try firstAttributedFunction(
            in: """
            @ThreadSafe
            final class Counter: Sendable {
                var count: Int = 0

                @ThreadSafeMethod
                func refresh() {
                    let count = 1
                    self.count = count
                }
            }
            """
        )

        assertThreadSafeMethodDiagnostic(
            for: function,
            expectedMessage: "'@ThreadSafeMethod' does not support local or parameter shadowing of tracked property 'count'; rename the local value or use inLock explicitly.",
            expectedID: MessageID(domain: "ThreadSafeMacro", id: "threadSafeMethodShadowingUnsupported")
        )
    }

    @Test("Rejects closures")
    func rejectsClosures() throws {
        let function = try firstAttributedFunction(
            in: """
            @ThreadSafe
            final class Counter: Sendable {
                var count: Int = 0

                @ThreadSafeMethod
                func refresh() {
                    let update = { count += 1 }
                    update()
                }
            }
            """
        )

        assertThreadSafeMethodDiagnostic(
            for: function,
            expectedMessage: "'@ThreadSafeMethod' does not support closures because they can capture locked state; use inLock around the synchronous statements instead.",
            expectedID: MessageID(domain: "ThreadSafeMacro", id: "threadSafeMethodClosureUnsupported")
        )
    }

    @Test("Rejects non-function attachments")
    func rejectsNonFunctionAttachments() throws {
        let declaration = try firstAttributedInitializer(
            in: """
            @ThreadSafe
            final class Counter: Sendable {
                var count: Int

                @ThreadSafeMethod
                init(count: Int) {
                    self.count = count
                }
            }
            """
        )

        assertThreadSafeMethodDiagnostic(
            for: declaration,
            expectedMessage: "'@ThreadSafeMethod' can only be attached to instance methods in @ThreadSafe classes.",
            expectedID: MessageID(domain: "ThreadSafeMacro", id: "threadSafeMethodInvalidAttachment")
        )
    }
}

// MARK: - Private Helpers

private extension ThreadSafeMethodMacroTests {
    func expandBody(for function: FunctionDeclSyntax) throws -> [CodeBlockItemSyntax] {
        try ThreadSafeMethodBodyMacro.expansion(
            of: threadSafeMethodBodyAttribute(for: function),
            providingBodyFor: function,
            in: BasicMacroExpansionContext()
        )
    }

    func threadSafeMethodBodyAttribute(for declaration: some DeclSyntaxProtocol) throws -> AttributeSyntax {
        guard let function = declaration.as(FunctionDeclSyntax.self),
              let classDecl = function.nearestEnclosingClassDecl
        else {
            return emptyThreadSafeMethodBodyAttribute
        }

        let properties = try classDecl.threadSafeStoredProperties()
            .map { "\"\($0.nameText)\"" }
            .joined(separator: ", ")
        return AttributeSyntax(stringLiteral: "@_ThreadSafeMethod(properties: [\(properties)])")
    }

    func firstAttributedFunction(in source: String) throws -> FunctionDeclSyntax {
        let sourceFile = Parser.parse(source: source)
        for statement in sourceFile.statements {
            if let classDecl = statement.item.as(ClassDeclSyntax.self),
               let function = classDecl.memberBlock.members
                   .compactMap({ $0.decl.as(FunctionDeclSyntax.self) })
                   .first(where: { $0.attributes.containsThreadSafeMethodAttribute })
            {
                return function
            }

            if let extensionDecl = statement.item.as(ExtensionDeclSyntax.self),
               let function = extensionDecl.memberBlock.members
                   .compactMap({ $0.decl.as(FunctionDeclSyntax.self) })
                   .first(where: { $0.attributes.containsThreadSafeMethodAttribute })
            {
                return function
            }
        }

        Issue.record("Expected source to include an attributed function declaration: \(source)")
        throw TestSupport.Failure()
    }

    func firstAttributedInitializer(in source: String) throws -> InitializerDeclSyntax {
        let sourceFile = Parser.parse(source: source)
        for statement in sourceFile.statements {
            if let classDecl = statement.item.as(ClassDeclSyntax.self),
               let initializer = classDecl.memberBlock.members
                   .compactMap({ $0.decl.as(InitializerDeclSyntax.self) })
                   .first(where: { $0.attributes.containsThreadSafeMethodAttribute })
            {
                return initializer
            }
        }

        Issue.record("Expected source to include an attributed initializer declaration: \(source)")
        throw TestSupport.Failure()
    }

    func assertThreadSafeMethodDiagnostic(
        for declaration: some DeclSyntaxProtocol & WithOptionalCodeBlockSyntax,
        expectedMessage: String,
        expectedID: MessageID
    ) {
        do {
            _ = try ThreadSafeMethodBodyMacro.expansion(
                of: try threadSafeMethodBodyAttribute(for: declaration),
                providingBodyFor: declaration,
                in: BasicMacroExpansionContext()
            )
            Issue.record("Expected diagnostics error to be thrown")
        } catch let error as DiagnosticsError {
            guard let diagnostic = error.diagnostics.first else {
                Issue.record("Expected at least one diagnostic")
                return
            }

            #expect(diagnostic.message == expectedMessage)
            #expect(diagnostic.diagMessage.severity == .error)
            #expect(diagnostic.diagMessage.diagnosticID == expectedID)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}

private extension AttributeListSyntax {
    var containsThreadSafeMethodAttribute: Bool {
        contains { element in
            guard let attribute = element.as(AttributeSyntax.self) else {
                return false
            }
            let name = attribute.attributeName.trimmedDescription.replacingOccurrences(of: " ", with: "")
            return name == "ThreadSafeMethod" || name.hasSuffix(".ThreadSafeMethod")
        }
    }
}
