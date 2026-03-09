//
//  ThreadSafeInitializerMacroTests.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 09.03.26.
//

import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import Testing
@testable import ConcurrencyMacrosPlugin

@Suite("ThreadSafeInitializerMacro")
struct ThreadSafeInitializerMacroTests {
    @Test("Returns empty expansion when attribute is missing arguments")
    func returnsEmptyExpansionWhenAttributeHasNoArguments() throws {
        let declaration = try initializerInStruct(
            """
            struct Example {
                init(value: Int) {
                    self.value = value
                }
            }
            """
        )

        let expanded = try expandBody(
            attributeSource: "@ThreadSafeInitializer",
            for: declaration
        )

        #expect(expanded.isEmpty)
    }

    @Test("Returns empty expansion when declaration has no body")
    func returnsEmptyExpansionWhenDeclarationHasNoBody() throws {
        let declaration = try initializerRequirementInProtocol(
            """
            protocol ExampleProtocol {
                init(value: Int)
            }
            """
        )

        let expanded = try expandBody(
            attributeSource: #"@ThreadSafeInitializer(["value": Storage<Int>()])"#,
            for: declaration
        )

        #expect(expanded.isEmpty)
    }

    @Test("Leaves body unchanged when first argument is not a dictionary")
    func leavesBodyUnchangedForNonDictionaryArgument() throws {
        let declaration = try initializerInStruct(
            """
            struct Example {
                init(value: Int) {
                    self.value = value
                    print(value)
                }
            }
            """
        )

        let expanded = try expandBody(
            attributeSource: #"@ThreadSafeInitializer("value")"#,
            for: declaration
        )
        let originalBody = try #require(declaration.body)
        let originalStatements = originalBody.statements.compactMap { CodeBlockItemSyntax($0) }

        #expect(
            expanded.map(\.nonWhitespaceDescription)
                == originalStatements.map(\.nonWhitespaceDescription)
        )
    }

    @Test("Rewrites assignments and initializes internal state after the last required assignment")
    func rewritesAssignmentsAndInitializesInternalState() throws {
        let declaration = try initializerInStruct(
            """
            struct Example {
                init(first: String, second: Int, optionalThird: String?) {
                    self.first = first
                    optionalThird = optionalThird
                    second = second + 1
                    print(second)
                }
            }
            """
        )

        let expanded = try expandBody(
            attributeSource: #"@ThreadSafeInitializer(["first": Storage<String>(), "second": Storage<Int>(), "optionalThird": Storage<String?>()])"#,
            for: declaration
        )

        #expect(
            expanded.map(\.nonWhitespaceDescription) == [
                "var_first:String",
                "var_second:Int",
                "var_optionalThird:String?=nil",
                "_first=first",
                "_optionalThird=optionalThird",
                "_second=second+1",
                "self._state=Mutex<_State>(_State(first:_first,second:_second,optionalThird:_optionalThird))",
                "print(second)",
            ]
        )
    }

    @Test("Places internal state initialization first when no required property is assigned")
    func placesInternalStateInitializationFirstWithoutRequiredAssignments() throws {
        let declaration = try initializerInStruct(
            """
            struct Example {
                init(id: Int) {
                    print(id)
                }
            }
            """
        )

        let expanded = try expandBody(
            attributeSource: #"@ThreadSafeInitializer(["id": Storage<Int>(), "name": Storage<String>(value: "Anonymous")])"#,
            for: declaration
        )

        #expect(
            expanded.map(\.nonWhitespaceDescription) == [
                "let_id:Int",
                #"let_name:String="Anonymous""#,
                "self._state=Mutex<_State>(_State(id:_id,name:_name))",
                "print(id)",
            ]
        )
    }

    @Test("Handles empty dictionary argument by initializing an empty internal state")
    func handlesEmptyDictionaryArgument() throws {
        let declaration = try initializerInStruct(
            """
            struct Example {
                init(value: Int) {
                    print(value)
                }
            }
            """
        )

        let expanded = try expandBody(
            attributeSource: "@ThreadSafeInitializer([:])",
            for: declaration
        )

        #expect(
            expanded.map(\.nonWhitespaceDescription) == [
                "self._state=Mutex<_State>(_State())",
                "print(value)",
            ]
        )
    }

    @Test("Ignores dictionary entries that cannot be parsed")
    func ignoresUnparsableDictionaryEntries() throws {
        let declaration = try initializerInStruct(
            """
            struct Example {
                init(count: Int) {
                    self.count = count
                }
            }
            """
        )

        let expanded = try expandBody(
            attributeSource: #"@ThreadSafeInitializer(["count": makeStorage(), invalidKey: Storage<Int>()])"#,
            for: declaration
        )

        #expect(
            expanded.map(\.nonWhitespaceDescription) == [
                "self._state=Mutex<_State>(_State())",
                "self.count=count",
            ]
        )
    }
}

// MARK: - Private Helpers

private extension ThreadSafeInitializerMacroTests {
    /// Expands a declaration body for a parsed `@ThreadSafeInitializer` attribute.
    ///
    /// - Parameters:
    ///   - attributeSource: Source text that parses to an attribute.
    ///   - declaration: Declaration whose body should be rewritten.
    /// - Returns: Expanded code block items.
    func expandBody<D: DeclSyntaxProtocol & WithOptionalCodeBlockSyntax>(
        attributeSource: String,
        for declaration: D
    ) throws -> [CodeBlockItemSyntax] {
        try ThreadSafeInitializerMacro.expansion(
            of: try attribute(from: attributeSource),
            providingBodyFor: declaration,
            in: BasicMacroExpansionContext()
        )
    }

    /// Parses an `AttributeSyntax` node from source text.
    ///
    /// - Parameter source: Attribute source text.
    /// - Returns: Parsed attribute syntax.
    func attribute(from source: String) throws -> AttributeSyntax {
        let parsedFile = Parser.parse(
            source: """
            \(source)
            func placeholder() {}
            """
        )
        let function = try #require(
            parsedFile.statements.first?.item.as(FunctionDeclSyntax.self),
            "Expected an attributed function declaration from source: \(source)"
        )
        return try #require(
            function.attributes.first?.as(AttributeSyntax.self),
            "Expected source to contain one attribute: \(source)"
        )
    }

    /// Returns the first initializer declared in a struct snippet.
    ///
    /// - Parameter source: Source that starts with a struct declaration.
    /// - Returns: The first initializer in the struct body.
    func initializerInStruct(_ source: String) throws -> InitializerDeclSyntax {
        let parsedFile = Parser.parse(source: source)
        let structDeclaration = try #require(
            parsedFile.statements.first?.item.as(StructDeclSyntax.self),
            "Expected source to begin with a struct declaration: \(source)"
        )
        return try #require(
            structDeclaration.memberBlock.members.compactMap { $0.decl.as(InitializerDeclSyntax.self) }.first,
            "Expected struct to contain an initializer declaration: \(source)"
        )
    }

    /// Returns the first initializer requirement declared in a protocol snippet.
    ///
    /// - Parameter source: Source that starts with a protocol declaration.
    /// - Returns: The first initializer requirement in the protocol body.
    func initializerRequirementInProtocol(_ source: String) throws -> InitializerDeclSyntax {
        let parsedFile = Parser.parse(source: source)
        let protocolDeclaration = try #require(
            parsedFile.statements.first?.item.as(ProtocolDeclSyntax.self),
            "Expected source to begin with a protocol declaration: \(source)"
        )
        return try #require(
            protocolDeclaration.memberBlock.members.compactMap { $0.decl.as(InitializerDeclSyntax.self) }.first,
            "Expected protocol to contain an initializer requirement: \(source)"
        )
    }
}
