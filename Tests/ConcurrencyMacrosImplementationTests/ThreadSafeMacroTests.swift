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
import SwiftSyntaxMacros
import Testing
@testable import ConcurrencyMacrosImplementation

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

    @Test("Expands ThreadSafe end-to-end with property and initializer rewriting")
    func expandsThreadSafeEndToEnd() {
        let sourceFile = Parser.parse(
            source: """
            @ThreadSafe
            class Example {
                var count: Int
                var name = "Seed"

                init(count: Int) {
                    self.count = count
                }
            }
            """
        )

        let context = BasicMacroExpansionContext()
        let expanded = sourceFile.expand(
            macros: Self.endToEndMacros,
            contextGenerator: { _ in context },
            indentationWidth: .spaces(4)
        )
        let output = expanded.nonWhitespaceDescription

        #expect(output.contains("privatelet_state:ConcurrencyMacros.Mutex<_State>"))
        #expect(output.contains("privatestruct_State:Sendable{varcount:Intvarname:String}"))
        #expect(output.contains("privatefuncinLock<Result:Sendable>(_mutation:@Sendable(inout_State)->Result)->Result{_state.mutate(mutation)}"))

        #expect(output.contains("get{_state.value.count}"))
        #expect(output.contains("set{_=_state.set(\\.count,to:newValue)}"))
        #expect(output.contains("get{_state.value.name}"))
        #expect(output.contains("set{_=_state.set(\\.name,to:newValue)}"))

        #expect(output.contains("var_count:Int"))
        #expect(output.contains(#"let_name:String="Seed""#))
        #expect(output.contains("_count=count"))
        #expect(output.contains("self._state=ConcurrencyMacros.Mutex<_State>(_State(count:_count,name:_name))"))
    }

    @Test("Expands ThreadSafe end-to-end with explicitly typed complex defaults")
    func expandsThreadSafeEndToEndWithExplicitlyTypedComplexDefaults() {
        let sourceFile = Parser.parse(
            source: """
            @ThreadSafe
            class Example {
                var values: [String: Int] = [:]
                var formatter: DateFormatter = DateFormatter()
            }
            """
        )

        let context = BasicMacroExpansionContext()
        let expanded = sourceFile.expand(
            macros: Self.endToEndMacros,
            contextGenerator: { _ in context },
            indentationWidth: .spaces(4)
        )
        let output = expanded.nonWhitespaceDescription

        #expect(output.contains("privatelet_state=ConcurrencyMacros.Mutex<_State>(_State(values:[:],formatter:DateFormatter()))"))
        #expect(output.contains("varvalues:[String:Int]"))
        #expect(output.contains("varformatter:DateFormatter"))
        #expect(output.contains("get{_state.value.values}"))
        #expect(output.contains("set{_=_state.set(\\.values,to:newValue)}"))
        #expect(output.contains("get{_state.value.formatter}"))
        #expect(output.contains("set{_=_state.set(\\.formatter,to:newValue)}"))
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
            expanded[0].nonWhitespaceDescription
                == #"privatelet_state=ConcurrencyMacros.Mutex<_State>(_State(count:0,name:"Seed",nickname:nil))"#
        )
        #expect(expanded[1].nonWhitespaceDescription.contains("privatestruct_State:Sendable"))
        #expect(expanded[1].nonWhitespaceDescription.contains("varcount:Int"))
        #expect(expanded[1].nonWhitespaceDescription.contains("varname:String"))
        #expect(expanded[1].nonWhitespaceDescription.contains("varnickname:String?"))
        #expect(expanded[2].nonWhitespaceDescription.contains("privatefuncinLock<Result:Sendable>"))
        #expect(expanded[2].nonWhitespaceDescription.contains("_state.mutate(mutation)"))
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

    @Test("Diagnoses complex inferred defaults without explicit type annotations")
    func diagnosesComplexInferredDefaultsWithoutExplicitTypeAnnotations() throws {
        let declaration = try classDeclaration(
            in: """
            class Example {
                var formatter = DateFormatter()
            }
            """
        )

        try assertThreadSafeDiagnostic(
            expectedMessage: "Property 'formatter' must declare an explicit type when the default value is not a simple literal.",
            expectedID: MessageID(domain: "ThreadSafeMacro", id: "complexInferredDefault"),
            operation: {
                _ = try expandMembers(for: declaration)
            }
        )
    }

    @Test("Diagnoses multi-binding mutable stored properties")
    func diagnosesMultiBindingMutableStoredProperties() throws {
        let declaration = try classDeclaration(
            in: """
            class Example {
                var first: Int = 1, second: Int = 2
            }
            """
        )

        try assertThreadSafeDiagnostic(
            expectedMessage: "@ThreadSafe supports one stored property per declaration; split this declaration into separate var declarations.",
            expectedID: MessageID(domain: "ThreadSafeMacro", id: "multipleBindingsUnsupported"),
            operation: {
                _ = try expandMembers(for: declaration)
            }
        )
    }

    @Test("Diagnoses attributes on tracked stored properties")
    func diagnosesAttributesOnTrackedStoredProperties() throws {
        let declaration = try classDeclaration(
            in: """
            class Example {
                @Clamped var count: Int = 0
            }
            """
        )

        try assertThreadSafeDiagnostic(
            expectedMessage: "@ThreadSafe does not support attributes on stored property 'count' in 1.0.",
            expectedID: MessageID(domain: "ThreadSafeMacro", id: "propertyAttributesUnsupported"),
            operation: {
                _ = try expandMembers(for: declaration)
            }
        )
    }

    @Test("Diagnoses unsupported modifiers on tracked stored properties")
    func diagnosesUnsupportedModifiersOnTrackedStoredProperties() throws {
        let cases = [
            (modifier: "static", name: "count", declaration: "static var count: Int = 0"),
            (modifier: "lazy", name: "cache", declaration: "lazy var cache: Int = 0"),
            (modifier: "weak", name: "delegate", declaration: "weak var delegate: Delegate?"),
            (modifier: "unowned", name: "owner", declaration: "unowned var owner: Owner"),
        ]

        for testCase in cases {
            let declaration = try classDeclaration(
                in: """
                class Example {
                    \(testCase.declaration)
                }
                """
            )

            try assertThreadSafeDiagnostic(
                expectedMessage: "@ThreadSafe does not support modifier '\(testCase.modifier)' on stored property '\(testCase.name)' in 1.0.",
                expectedID: MessageID(domain: "ThreadSafeMacro", id: "propertyModifiersUnsupported"),
                operation: {
                    _ = try expandMembers(for: declaration)
                }
            )
        }
    }

    @Test("Ignores computed properties because they are not stored state")
    func ignoresComputedPropertiesBecauseTheyAreNotStoredState() throws {
        let declaration = try classDeclaration(
            in: """
            class Example {
                var computed: Int { 1 }
            }
            """
        )

        let expanded = try expandMembers(for: declaration)

        #expect(expanded.count == 3)
        #expect(expanded[0].nonWhitespaceDescription == "privatelet_state=ConcurrencyMacros.Mutex<_State>(_State())")
        #expect(expanded[1].nonWhitespaceDescription == "privatestruct_State:Sendable{}")
    }

    @Test("Tracks stored properties with access-control modifiers")
    func tracksStoredPropertiesWithAccessControlModifiers() throws {
        let declaration = try classDeclaration(
            in: """
            class Example {
                private var count: Int = 0
            }
            """
        )

        let expanded = try expandMembers(for: declaration)

        #expect(expanded[0].nonWhitespaceDescription == "privatelet_state=ConcurrencyMacros.Mutex<_State>(_State(count:0))")
        #expect(expanded[1].nonWhitespaceDescription.contains("varcount:Int"))
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
        #expect(expanded[0].nonWhitespaceDescription == "privatelet_state:ConcurrencyMacros.Mutex<_State>")
        #expect(expanded[1].nonWhitespaceDescription.contains("varcount:Int"))
        #expect(expanded[2].nonWhitespaceDescription.contains("_state.mutate(mutation)"))
    }

    @Test("ThreadSafeDiagnostic exposes stable metadata")
    func threadSafeDiagnosticExposesStableMetadata() {
        let diagnostic = ThreadSafeDiagnostic(id: "example", message: "Example")

        #expect(diagnostic.message == "Example")
        #expect(diagnostic.severity == .error)
        #expect(
            diagnostic.diagnosticID
                == MessageID(domain: "ThreadSafeMacro", id: "example")
        )
    }

    @Test("Stored property extractor defaults optional spellings to nil")
    func storedPropertyExtractorDefaultsOptionalSpellingsToNil() throws {
        let declaration = try classDeclaration(
            in: """
            class Example {
                var shorthand: String?
                var generic: Optional<Int>
                var qualified: Swift.Optional<Double>
                var implicitlyUnwrapped: Bool!
            }
            """
        )

        let properties = try declaration.threadSafeStoredProperties()

        #expect(properties.map(\.nameText) == ["shorthand", "generic", "qualified", "implicitlyUnwrapped"])
        #expect(properties.map(\.typeDescription) == ["String?", "Optional<Int>", "Swift.Optional<Double>", "Bool!"])
        #expect(properties.map(\.defaultValueDescription) == ["nil", "nil", "nil", "nil"])
    }

    @Test("Stored property extractor infers negative numeric literal types")
    func storedPropertyExtractorInfersNegativeNumericLiteralTypes() throws {
        let declaration = try classDeclaration(
            in: """
            class Example {
                var integer = -1
                var double = -1.0
            }
            """
        )

        let properties = try declaration.threadSafeStoredProperties()

        #expect(properties.map(\.nameText) == ["integer", "double"])
        #expect(properties.map(\.typeDescription) == ["Int", "Double"])
        #expect(properties.map(\.defaultValueDescription) == ["-1", "-1.0"])
    }

    @Test("Stored property extractor detects qualified ThreadSafeProperty attributes")
    func storedPropertyExtractorDetectsQualifiedThreadSafePropertyAttributes() throws {
        let declaration = try classDeclaration(
            in: """
            class Example {
                @ConcurrencyMacros.ThreadSafeProperty var count: Int = 0
            }
            """
        )

        let variable = try #require(
            try declaration.memberDecl(at: 0).as(VariableDeclSyntax.self)
        )
        let properties = try declaration.threadSafeStoredProperties()

        #expect(variable.hasThreadSafePropertyAttribute)
        #expect(properties.map(\.nameText) == ["count"])
        #expect(properties.first?.typeDescription == "Int")
        #expect(properties.first?.defaultValueDescription == "0")
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
        #expect(expanded[0].nonWhitespaceDescription == "privatelet_state=ConcurrencyMacros.Mutex<_State>(_State())")
        #expect(expanded[1].nonWhitespaceDescription == "privatestruct_State:Sendable{}")
        #expect(expanded[2].nonWhitespaceDescription.contains("privatefuncinLock<Result:Sendable>"))
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
        let property = try declaration.memberDecl(at: 0)

        let expanded = try expandAttributes(attachedTo: declaration, member: property)

        #expect(expanded.count == 1)
        #expect(expanded[0].identifierTypeName == "ThreadSafeProperty")
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
        let property = try declaration.memberDecl(at: 0)

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
        let property = try declaration.memberDecl(at: 0)

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
        let initializer = try declaration.memberDecl(at: 3)

        let expanded = try expandAttributes(attachedTo: declaration, member: initializer)

        #expect(expanded.count == 1)
        let attribute = try #require(expanded.first)
        #expect(attribute.identifierTypeName == "ThreadSafeInitializer")

        let argumentExpression = try initializerArgumentExpression(in: attribute)
        #expect(argumentExpression.contains(#""required":ConcurrencyMacros.TypeErased<Int>()"#))
        #expect(argumentExpression.contains(#""optional":ConcurrencyMacros.TypeErased<String?>(value:nil)"#))
        #expect(argumentExpression.contains(#""name":ConcurrencyMacros.TypeErased<String>(value:"Seed")"#))
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
        let initializer = try declaration.memberDecl(at: 1)

        let expanded = try expandAttributes(attachedTo: declaration, member: initializer)

        #expect(expanded.count == 1)
        let attribute = try #require(expanded.first)
        #expect(attribute.identifierTypeName == "ThreadSafeInitializer")
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
        let convenienceInitializer = try declaration.memberDecl(at: 2)

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
        let initializer = try declaration.memberDecl(at: 0)

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
        let function = try declaration.memberDecl(at: 0)

        let expanded = try expandAttributes(attachedTo: declaration, member: function)

        #expect(expanded.isEmpty)
    }
}

private extension ThreadSafeMacroTests {
    /// Macro set used by end-to-end expansion tests.
    static let endToEndMacros: [String: Macro.Type] = [
        "ThreadSafe": ThreadSafeMacro.self,
        "ThreadSafeProperty": ThreadSafePropertyMacro.self,
        "ThreadSafeInitializer": ThreadSafeInitializerMacro.self,
    ]
}

// MARK: - Private Helpers

private extension ThreadSafeMacroTests {
    /// Expands members synthesized by `ThreadSafeMacro` for a declaration.
    ///
    /// - Parameter declaration: Declaration to expand.
    /// - Returns: Expanded member declarations.
    func expandMembers(for declaration: some DeclSyntaxProtocol) throws -> [DeclSyntax] {
        try ThreadSafeMacro.expansion(
            of: threadSafeAttribute,
            providingMembersOf: declaration,
            conformingTo: [],
            in: BasicMacroExpansionContext()
        )
    }

    /// Expands member attributes synthesized by `ThreadSafeMacro`.
    ///
    /// - Parameters:
    ///   - group: The declaration group the attribute is attached to.
    ///   - member: The member declaration being inspected.
    /// - Returns: Synthesized attributes for the member.
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

    /// Asserts that a `@ThreadSafe` expansion operation throws a single expected diagnostic.
    ///
    /// - Parameters:
    ///   - expectedMessage: Exact diagnostic text expected from the macro.
    ///   - expectedID: Stable diagnostic identifier expected from the macro.
    ///   - operation: Expansion operation that should fail with `DiagnosticsError`.
    func assertThreadSafeDiagnostic(
        expectedMessage: String,
        expectedID: MessageID,
        operation: () throws -> Void
    ) throws {
        do {
            try operation()
            Issue.record("Expected diagnostics error to be thrown")
        } catch let error as DiagnosticsError {
            #expect(error.diagnostics.count == 1)
            let diagnostic = try #require(error.diagnostics.first)
            #expect(diagnostic.message == expectedMessage)
            #expect(diagnostic.diagMessage.severity == .error)
            #expect(diagnostic.diagMessage.diagnosticID == expectedID)
        }
    }

    /// Parses and returns the first declaration from source text.
    ///
    /// - Parameter source: Source that begins with a declaration.
    /// - Returns: The first declaration in the parsed source file.
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

    /// Parses and returns a class declaration from source text.
    ///
    /// - Parameter source: Source expected to begin with a class declaration.
    /// - Returns: Parsed `ClassDeclSyntax`.
    func classDeclaration(in source: String) throws -> ClassDeclSyntax {
        let declaration = try firstDeclaration(in: source)
        return try #require(
            declaration.as(ClassDeclSyntax.self),
            "Expected source to begin with a class declaration: \(source)"
        )
    }

    /// Parses and returns a struct declaration from source text.
    ///
    /// - Parameter source: Source expected to begin with a struct declaration.
    /// - Returns: Parsed `StructDeclSyntax`.
    func structDeclaration(in source: String) throws -> StructDeclSyntax {
        let declaration = try firstDeclaration(in: source)
        return try #require(
            declaration.as(StructDeclSyntax.self),
            "Expected source to begin with a struct declaration: \(source)"
        )
    }

    /// Extracts the single argument expression text from an attribute for assertion use.
    ///
    /// - Parameter attribute: Attribute whose first argument should be read.
    /// - Returns: Normalized argument expression description.
    func initializerArgumentExpression(in attribute: AttributeSyntax) throws -> String {
        try attribute
            .singleArgumentExpressionDescription()
            .replacingOccurrences(of: "\\", with: "")
    }
}
