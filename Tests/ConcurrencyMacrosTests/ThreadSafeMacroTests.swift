//
//  ThreadSafeMacroTests.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 09.03.26.
//

import SwiftDiagnostics
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import Testing
@testable import ConcurrencyMacrosPlugin

@Suite("ThreadSafeMacro")
struct ThreadSafeMacroTests {
    private var threadSafeAttribute: AttributeSyntax {
        AttributeSyntax(
            attributeName: IdentifierTypeSyntax(name: .identifier("ThreadSafe"))
        )
    }

    @Test("Returns no members when declaration is not a class")
    func returnsNoMembersForNonClassDeclaration() throws {
        let declaration = try firstDeclaration(
            in: """
            struct Example {
                var count: Int = 0
            }
            """
        )

        let expanded = try expandMembers(for: declaration)

        #expect(expanded.isEmpty)
    }

    @Test("Generates initialized internal state for classes without initializers")
    func generatesInitializedInternalStateWithoutInitializer() throws {
        let declaration = try classDeclaration(
            in: """
            class Example {
                var count: Int = 0
                var name = "Seed"
                var nickname: String?
            }
            """
        )

        let expanded = try expandMembers(for: declaration)

        #expect(expanded.count == 3)
        #expect(
            normalized(expanded[0])
                == #"privatelet_internalState=Mutex<_InternalState>(_InternalState(count:0,name:"Seed",nickname:nil))"#
        )
        #expect(normalized(expanded[1]).contains("privatestruct_InternalState:Sendable"))
        #expect(normalized(expanded[1]).contains("varcount:Int"))
        #expect(normalized(expanded[1]).contains("varname:String"))
        #expect(normalized(expanded[1]).contains("varnickname:String?"))
        #expect(normalized(expanded[2]).contains("privatefuncinLock<Result:Sendable>"))
        #expect(normalized(expanded[2]).contains("_internalState.mutate(mutation)"))
    }

    @Test("Throws diagnostics error when class has no initializer and required property defaults")
    func throwsDiagnosticsErrorWhenRequiredPropertyHasNoDefault() throws {
        let declaration = try classDeclaration(
            in: """
            class Example {
                var count: Int
            }
            """
        )

        do {
            _ = try expandMembers(for: declaration)
            Issue.record("Expected a diagnostics error to be thrown")
        } catch let error as DiagnosticsError {
            let diagnostic = try #require(error.diagnostics.first)
            #expect(
                diagnostic.message
                    == "Property 'count' must have a default value or the class must define an initializer."
            )
            #expect(diagnostic.diagMessage.severity == .error)
        }
    }

    @Test("Generates uninitialized internal state when class defines an initializer")
    func generatesUninitializedInternalStateWithInitializer() throws {
        let declaration = try classDeclaration(
            in: """
            class Example {
                var count: Int

                init(count: Int) {
                    self.count = count
                }
            }
            """
        )

        let expanded = try expandMembers(for: declaration)

        #expect(expanded.count == 3)
        #expect(normalized(expanded[0]) == "privatelet_internalState:Mutex<_InternalState>")
        #expect(normalized(expanded[1]).contains("varcount:Int"))
        #expect(normalized(expanded[2]).contains("_internalState.mutate(mutation)"))
    }

    @Test("SendableDiagnostic exposes stable metadata")
    func sendableDiagnosticExposesStableMetadata() {
        let diagnostic = SendableDiagnostic(message: "Example")

        #expect(diagnostic.message == "Example")
        #expect(diagnostic.severity == .error)
        #expect(
            diagnostic.diagnosticID
                == MessageID(domain: "ThreadSafeMacro", id: "propertyReplacement")
        )
    }

    @Test("Generates empty internal state for classes without mutable stored properties")
    func generatesEmptyInternalStateWhenNoMutableStoredPropertiesExist() throws {
        let declaration = try classDeclaration(
            in: """
            class Example {
                let id: Int = 1
            }
            """
        )

        let expanded = try expandMembers(for: declaration)

        #expect(expanded.count == 3)
        #expect(normalized(expanded[0]) == "privatelet_internalState=Mutex<_InternalState>(_InternalState())")
        #expect(normalized(expanded[1]) == "privatestruct_InternalState:Sendable{}")
        #expect(normalized(expanded[2]).contains("privatefuncinLock<Result:Sendable>"))
    }

    @Test("Adds ThreadSafeProperty attribute to mutable stored properties")
    func addsPropertyAttributeToMutableStoredProperty() throws {
        let declaration = try classDeclaration(
            in: """
            class Example {
                var count: Int = 0
            }
            """
        )
        let property = try member(in: declaration, at: 0)

        let expanded = try expandAttributes(attachedTo: declaration, member: property)

        #expect(expanded.count == 1)
        #expect(attributeName(expanded[0]) == "ThreadSafeProperty")
    }

    @Test("Does not add ThreadSafeProperty attribute to immutable properties")
    func doesNotAddPropertyAttributeToImmutableProperty() throws {
        let declaration = try classDeclaration(
            in: """
            class Example {
                let count: Int = 0
            }
            """
        )
        let property = try member(in: declaration, at: 0)

        let expanded = try expandAttributes(attachedTo: declaration, member: property)

        #expect(expanded.isEmpty)
    }

    @Test("Does not add ThreadSafeProperty attribute if one already exists")
    func skipsPropertyAlreadyMarkedThreadSafe() throws {
        let declaration = try classDeclaration(
            in: """
            class Example {
                @ThreadSafeProperty var count: Int = 0
            }
            """
        )
        let property = try member(in: declaration, at: 0)

        let expanded = try expandAttributes(attachedTo: declaration, member: property)

        #expect(expanded.isEmpty)
    }

    @Test("Adds ThreadSafeInitializer attribute to designated initializers")
    func addsInitializerAttributeToDesignatedInitializer() throws {
        let declaration = try classDeclaration(
            in: """
            class Example {
                var required: Int
                var optional: String?
                var name = "Seed"

                init(required: Int) {
                    self.required = required
                }
            }
            """
        )
        let initializer = try member(in: declaration, at: 3)

        let expanded = try expandAttributes(attachedTo: declaration, member: initializer)

        #expect(expanded.count == 1)
        let attribute = try #require(expanded.first)
        #expect(attributeName(attribute) == "ThreadSafeInitializer")

        let argumentExpression = try initializerArgumentExpression(in: attribute)
        #expect(argumentExpression.contains(#""required":TypeErased<Int>()"#))
        #expect(argumentExpression.contains(#""optional":TypeErased<String?>(value:nil)"#))
        #expect(argumentExpression.contains(#""name":TypeErased<String>(value:"Seed")"#))
    }

    @Test("Uses empty dictionary argument when class has no mutable stored properties")
    func usesEmptyDictionaryForInitializerWhenNoMutableStoredPropertiesExist() throws {
        let declaration = try classDeclaration(
            in: """
            class Example {
                let id: Int

                init(id: Int) {
                    self.id = id
                }
            }
            """
        )
        let initializer = try member(in: declaration, at: 1)

        let expanded = try expandAttributes(attachedTo: declaration, member: initializer)

        #expect(expanded.count == 1)
        let attribute = try #require(expanded.first)
        #expect(attributeName(attribute) == "ThreadSafeInitializer")
        #expect(try initializerArgumentExpression(in: attribute).contains("[:"))
    }

    @Test("Does not add initializer attribute to convenience initializers")
    func skipsConvenienceInitializers() throws {
        let declaration = try classDeclaration(
            in: """
            class Example {
                var count: Int = 0

                init() {}

                convenience init(flag: Bool) {
                    self.init()
                }
            }
            """
        )
        let convenienceInitializer = try member(in: declaration, at: 2)

        let expanded = try expandAttributes(attachedTo: declaration, member: convenienceInitializer)

        #expect(expanded.isEmpty)
    }

    @Test("Returns no initializer attributes when attached declaration group is not a class")
    func returnsNoInitializerAttributesForNonClassGroups() throws {
        let declaration = try structDeclaration(
            in: """
            struct Example {
                init(value: Int) {
                    _ = value
                }
            }
            """
        )
        let initializer = try member(in: declaration, at: 0)

        let expanded = try expandAttributes(attachedTo: declaration, member: initializer)

        #expect(expanded.isEmpty)
    }

    @Test("Returns no attributes for unsupported members")
    func returnsNoAttributesForUnsupportedMembers() throws {
        let declaration = try classDeclaration(
            in: """
            class Example {
                func performWork() {}
            }
            """
        )
        let function = try member(in: declaration, at: 0)

        let expanded = try expandAttributes(attachedTo: declaration, member: function)

        #expect(expanded.isEmpty)
    }
}

// MARK: - Private Helpers

private extension ThreadSafeMacroTests {
    func expandMembers(for declaration: some DeclSyntaxProtocol) throws -> [DeclSyntax] {
        try ThreadSafeMacro.expansion(
            of: threadSafeAttribute,
            providingMembersOf: declaration,
            conformingTo: [],
            in: BasicMacroExpansionContext()
        )
    }

    func expandAttributes(
        attachedTo group: some DeclGroupSyntax,
        member: some DeclSyntaxProtocol
    ) throws -> [AttributeSyntax] {
        try ThreadSafeMacro.expansion(
            of: threadSafeAttribute,
            attachedTo: group,
            providingAttributesFor: member,
            in: BasicMacroExpansionContext()
        )
    }

    func firstDeclaration(in source: String) throws -> DeclSyntax {
        let sourceFile = Parser.parse(source: source)
        let statement = try #require(
            sourceFile.statements.first,
            "Expected source to contain at least one statement: \(source)"
        )
        return try #require(
            statement.item.as(DeclSyntax.self),
            "Expected the first statement to be a declaration: \(source)"
        )
    }

    func classDeclaration(in source: String) throws -> ClassDeclSyntax {
        let declaration = try firstDeclaration(in: source)
        return try #require(
            declaration.as(ClassDeclSyntax.self),
            "Expected source to begin with a class declaration: \(source)"
        )
    }

    func structDeclaration(in source: String) throws -> StructDeclSyntax {
        let declaration = try firstDeclaration(in: source)
        return try #require(
            declaration.as(StructDeclSyntax.self),
            "Expected source to begin with a struct declaration: \(source)"
        )
    }

    func member(in declaration: some DeclGroupSyntax, at index: Int) throws -> DeclSyntax {
        let memberDecl = try #require(
            declaration.memberBlock.members.dropFirst(index).first?.decl,
            "Expected declaration to contain a member at index \(index): \(declaration)"
        )
        return DeclSyntax(memberDecl)
    }

    func attributeName(_ attribute: AttributeSyntax) -> String? {
        attribute.attributeName.as(IdentifierTypeSyntax.self)?.name.text
    }

    func initializerArgumentExpression(in attribute: AttributeSyntax) throws -> String {
        let arguments = try #require(
            attribute.arguments?.as(LabeledExprListSyntax.self),
            "Expected initializer attribute to have one argument"
        )
        let expression = try #require(
            arguments.first?.expression,
            "Expected initializer attribute to include one argument expression"
        )
        return normalized(expression).replacingOccurrences(of: "\\", with: "")
    }

    func normalized(_ syntax: some SyntaxProtocol) -> String {
        syntax.description.filter { !$0.isWhitespace }
    }
}
