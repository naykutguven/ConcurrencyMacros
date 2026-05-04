//
//  ThreadSafeInitializerMacroTests.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 09.03.26.
//

import SwiftParser
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import Testing
@testable import ConcurrencyMacrosImplementation

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

    @Test("Diagnoses first argument that is not a dictionary")
    func diagnosesNonDictionaryArgument() throws {
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

        try assertInitializerDiagnostic(
            attributeSource: #"@ThreadSafeInitializer("value")"#,
            for: declaration,
            expectedMessage: "@ThreadSafeInitializer entries must use string keys and generic storage values.",
            expectedID: MessageID(domain: "ThreadSafeMacro", id: "invalidInitializerPayload")
        )
    }

    @Test("Diagnoses staging local collision with initializer parameter")
    func diagnosesStagingLocalCollisionWithInitializerParameter() throws {
        let declaration = try initializerInStruct(
            """
            struct Example {
                init(_count: Int, count: Int) {
                    self.count = count
                }
            }
            """
        )

        try assertInitializerDiagnostic(
            attributeSource: #"@ThreadSafeInitializer(["count": Storage<Int>()])"#,
            for: declaration,
            expectedMessage: "@ThreadSafeInitializer staging local '_count' conflicts with an initializer parameter or top-level local; rename the parameter or local.",
            expectedID: MessageID(domain: "ThreadSafeMacro", id: "stagingNameCollision")
        )
    }

    @Test("Diagnoses staging local collision with top-level local declaration")
    func diagnosesStagingLocalCollisionWithTopLevelLocalDeclaration() throws {
        let declaration = try initializerInStruct(
            """
            struct Example {
                init(count: Int) {
                    let _count = count
                    self.count = _count
                }
            }
            """
        )

        try assertInitializerDiagnostic(
            attributeSource: #"@ThreadSafeInitializer(["count": Storage<Int>()])"#,
            for: declaration,
            expectedMessage: "@ThreadSafeInitializer staging local '_count' conflicts with an initializer parameter or top-level local; rename the parameter or local.",
            expectedID: MessageID(domain: "ThreadSafeMacro", id: "stagingNameCollision")
        )
    }

    @Test("Diagnoses staging local collision with top-level local function")
    func diagnosesStagingLocalCollisionWithTopLevelLocalFunction() throws {
        let declaration = try initializerInStruct(
            """
            struct Example {
                init(count: Int) {
                    func _count() -> Int { count }
                    self.count = _count()
                }
            }
            """
        )

        try assertInitializerDiagnostic(
            attributeSource: #"@ThreadSafeInitializer(["count": Storage<Int>()])"#,
            for: declaration,
            expectedMessage: "@ThreadSafeInitializer staging local '_count' conflicts with an initializer parameter or top-level local; rename the parameter or local.",
            expectedID: MessageID(domain: "ThreadSafeMacro", id: "stagingNameCollision")
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
                "self._state=ConcurrencyMacros.Mutex<_State>(_State(first:_first,second:_second,optionalThird:_optionalThird))",
                "print(second)",
            ]
        )
    }

    @Test("Rewrites no-space initializer assignments")
    func rewritesNoSpaceInitializerAssignments() throws {
        let declaration = try initializerInStruct(
            """
            struct Example {
                init(first: String, second: Int) {
                    self.first=first
                    second=second + 1
                    print(second)
                }
            }
            """
        )

        let expanded = try expandBody(
            attributeSource: #"@ThreadSafeInitializer(["first": Storage<String>(), "second": Storage<Int>()])"#,
            for: declaration
        )

        #expect(
            expanded.map(\.nonWhitespaceDescription) == [
                "var_first:String",
                "var_second:Int",
                "_first=first",
                "_second=second+1",
                "self._state=ConcurrencyMacros.Mutex<_State>(_State(first:_first,second:_second))",
                "print(second)",
            ]
        )
    }

    @Test("Does not rewrite comparison expressions that mention tracked names")
    func doesNotRewriteComparisonExpressionsThatMentionTrackedNames() throws {
        let declaration = try initializerInStruct(
            """
            struct Example {
                init(count: Int, other: Int) {
                    count == other
                    self.count = count
                }
            }
            """
        )

        let expanded = try expandBody(
            attributeSource: #"@ThreadSafeInitializer(["count": Storage<Int>()])"#,
            for: declaration
        )

        #expect(
            expanded.map(\.nonWhitespaceDescription) == [
                "var_count:Int",
                "count==other",
                "_count=count",
                "self._state=ConcurrencyMacros.Mutex<_State>(_State(count:_count))",
            ]
        )
    }

    @Test("Does not rewrite bare assignments after a top-level local declaration shadows a tracked property")
    func doesNotRewriteBareAssignmentsAfterTopLevelLocalDeclarationShadowsTrackedProperty() throws {
        let declaration = try initializerInStruct(
            """
            struct Example {
                init(input: Int) {
                    var count = input
                    count = count + 1
                    self.count = count
                }
            }
            """
        )

        let expanded = try expandBody(
            attributeSource: #"@ThreadSafeInitializer(["count": Storage<Int>()])"#,
            for: declaration
        )

        #expect(
            expanded.map(\.nonWhitespaceDescription) == [
                "var_count:Int",
                "varcount=input",
                "count=count+1",
                "_count=count",
                "self._state=ConcurrencyMacros.Mutex<_State>(_State(count:_count))",
            ]
        )
    }

    @Test("Does not rewrite bare assignments after a top-level tuple local declaration shadows a tracked property")
    func doesNotRewriteBareAssignmentsAfterTopLevelTupleLocalDeclarationShadowsTrackedProperty() throws {
        let declaration = try initializerInStruct(
            """
            struct Example {
                init(input: Int) {
                    var (count, other) = (input, 0)
                    count = count + 1
                    self.count = count
                }
            }
            """
        )

        let expanded = try expandBody(
            attributeSource: #"@ThreadSafeInitializer(["count": Storage<Int>()])"#,
            for: declaration
        )

        #expect(
            expanded.map(\.nonWhitespaceDescription) == [
                "var_count:Int",
                "var(count,other)=(input,0)",
                "count=count+1",
                "_count=count",
                "self._state=ConcurrencyMacros.Mutex<_State>(_State(count:_count))",
            ]
        )
    }

    @Test("Diagnoses required assignments inside unsupported control flow")
    func diagnosesRequiredAssignmentsInsideUnsupportedControlFlow() throws {
        let declaration = try initializerInStruct(
            """
            struct Example {
                init(count: Int, flag: Bool) {
                    if flag {
                        self.count = count
                    } else {
                        self.count = 0
                    }
                }
            }
            """
        )

        try assertInitializerDiagnostic(
            attributeSource: #"@ThreadSafeInitializer(["count": Storage<Int>()])"#,
            for: declaration,
            expectedMessage: "Initializer must assign tracked property 'count' with a plain top-level assignment before @ThreadSafe state initialization.",
            expectedID: MessageID(domain: "ThreadSafeMacro", id: "requiredInitializerAssignmentUnsupported")
        )
    }

    @Test("Diagnoses required property missing a top-level assignment")
    func diagnosesRequiredPropertyMissingTopLevelAssignment() throws {
        let declaration = try initializerInStruct(
            """
            struct Example {
                init(id: Int) {
                    print(id)
                }
            }
            """
        )

        try assertInitializerDiagnostic(
            attributeSource: #"@ThreadSafeInitializer(["id": Storage<Int>(), "name": Storage<String>(value: "Anonymous")])"#,
            for: declaration,
            expectedMessage: "Initializer must assign tracked property 'id' with a plain top-level assignment before @ThreadSafe state initialization.",
            expectedID: MessageID(domain: "ThreadSafeMacro", id: "requiredInitializerAssignmentUnsupported")
        )
    }

    @Test("Diagnoses nested assignment to defaulted property before state initialization")
    func diagnosesNestedDefaultedAssignmentBeforeStateInitialization() throws {
        let declaration = try initializerInStruct(
            """
            struct Example {
                init(count: Int, flag: Bool) {
                    if flag {
                        self.name = "Override"
                    }
                    self.count = count
                }
            }
            """
        )

        try assertInitializerDiagnostic(
            attributeSource: #"@ThreadSafeInitializer(["count": Storage<Int>(), "name": Storage<String>(value: "Seed")])"#,
            for: declaration,
            expectedMessage: "Initializer access to tracked property 'name' before @ThreadSafe state initialization is only supported as the left-hand side of a plain top-level assignment.",
            expectedID: MessageID(domain: "ThreadSafeMacro", id: "unsupportedInitializerAssignment")
        )
    }

    @Test("Diagnoses explicit tracked property read before state initialization")
    func diagnosesExplicitTrackedPropertyReadBeforeStateInitialization() throws {
        let declaration = try initializerInStruct(
            """
            struct Example {
                init(count: Int) {
                    print(self.name)
                    self.count = count
                }
            }
            """
        )

        try assertInitializerDiagnostic(
            attributeSource: #"@ThreadSafeInitializer(["count": Storage<Int>(), "name": Storage<String>(value: "Seed")])"#,
            for: declaration,
            expectedMessage: "Initializer access to tracked property 'name' before @ThreadSafe state initialization is only supported as the left-hand side of a plain top-level assignment.",
            expectedID: MessageID(domain: "ThreadSafeMacro", id: "unsupportedInitializerAssignment")
        )
    }

    @Test("Diagnoses tracked property read on supported assignment RHS before state initialization")
    func diagnosesTrackedPropertyReadOnSupportedAssignmentRHSBeforeStateInitialization() throws {
        let declaration = try initializerInStruct(
            """
            struct Example {
                init() {
                    self.count = self.name.count
                }
            }
            """
        )

        try assertInitializerDiagnostic(
            attributeSource: #"@ThreadSafeInitializer(["count": Storage<Int>(), "name": Storage<String>(value: "Seed")])"#,
            for: declaration,
            expectedMessage: "Initializer access to tracked property 'name' before @ThreadSafe state initialization is only supported as the left-hand side of a plain top-level assignment.",
            expectedID: MessageID(domain: "ThreadSafeMacro", id: "unsupportedInitializerAssignment")
        )
    }

    @Test("Allows assignment RHS member name matching tracked property before state initialization")
    func allowsAssignmentRHSMemberNameMatchingTrackedPropertyBeforeStateInitialization() throws {
        let declaration = try initializerInStruct(
            """
            struct Example {
                init(name: String) {
                    self.count = name.count
                }
            }
            """
        )

        let expanded = try expandBody(
            attributeSource: #"@ThreadSafeInitializer(["count": Storage<Int>()])"#,
            for: declaration
        )

        #expect(
            expanded.map(\.nonWhitespaceDescription) == [
                "var_count:Int",
                "_count=name.count",
                "self._state=ConcurrencyMacros.Mutex<_State>(_State(count:_count))",
            ]
        )
    }

    @Test("Allows assignment RHS member name matching tracked property on untracked base before state initialization")
    func allowsAssignmentRHSMemberNameMatchingTrackedPropertyOnUntrackedBaseBeforeStateInitialization() throws {
        let declaration = try initializerInStruct(
            """
            struct Example {
                init(other: String) {
                    self.count = other.count
                }
            }
            """
        )

        let expanded = try expandBody(
            attributeSource: #"@ThreadSafeInitializer(["count": Storage<Int>()])"#,
            for: declaration
        )

        #expect(
            expanded.map(\.nonWhitespaceDescription) == [
                "var_count:Int",
                "_count=other.count",
                "self._state=ConcurrencyMacros.Mutex<_State>(_State(count:_count))",
            ]
        )
    }

    @Test("Diagnoses assignment RHS member access rooted in unshadowed tracked property before state initialization")
    func diagnosesAssignmentRHSMemberAccessRootedInUnshadowedTrackedPropertyBeforeStateInitialization() throws {
        let declaration = try initializerInStruct(
            """
            struct Example {
                init() {
                    self.count = name.value
                }
            }
            """
        )

        try assertInitializerDiagnostic(
            attributeSource: #"@ThreadSafeInitializer(["count": Storage<Int>(), "name": Storage<ExampleName>(value: ExampleName())])"#,
            for: declaration,
            expectedMessage: "Initializer access to tracked property 'name' before @ThreadSafe state initialization is only supported as the left-hand side of a plain top-level assignment.",
            expectedID: MessageID(domain: "ThreadSafeMacro", id: "unsupportedInitializerAssignment")
        )
    }

    @Test("Allows closure parameter to shadow tracked property before state initialization")
    func allowsClosureParameterToShadowTrackedPropertyBeforeStateInitialization() throws {
        let declaration = try initializerInStruct(
            """
            struct Example {
                init(values: [String]) {
                    self.count = values.map { name in name.count }.reduce(0, +)
                }
            }
            """
        )

        let expanded = try expandBody(
            attributeSource: #"@ThreadSafeInitializer(["count": Storage<Int>(), "name": Storage<String>(value: "Seed")])"#,
            for: declaration
        )

        #expect(
            expanded.map(\.nonWhitespaceDescription) == [
                "var_count:Int",
                #"let_name:String="Seed""#,
                "_count=values.map{nameinname.count}.reduce(0,+)",
                "self._state=ConcurrencyMacros.Mutex<_State>(_State(count:_count,name:_name))",
            ]
        )
    }

    @Test("Allows for pattern to shadow tracked property before state initialization")
    func allowsForPatternToShadowTrackedPropertyBeforeStateInitialization() throws {
        let declaration = try initializerInStruct(
            """
            struct Example {
                init(count: Int, names: [String]) {
                    for name in names {
                        print(name)
                    }
                    self.count = count
                }
            }
            """
        )

        let expanded = try expandBody(
            attributeSource: #"@ThreadSafeInitializer(["count": Storage<Int>(), "name": Storage<String>(value: "Seed")])"#,
            for: declaration
        )

        #expect(
            expanded.map(\.nonWhitespaceDescription) == [
                "var_count:Int",
                #"let_name:String="Seed""#,
                "fornameinnames{print(name)}",
                "_count=count",
                "self._state=ConcurrencyMacros.Mutex<_State>(_State(count:_count,name:_name))",
            ]
        )
    }

    @Test("Allows local function name to shadow tracked property inside its own body before state initialization")
    func allowsLocalFunctionNameToShadowTrackedPropertyInsideItsOwnBodyBeforeStateInitialization() throws {
        let declaration = try initializerInStruct(
            """
            struct Example {
                init(count: Int) {
                    func name() {
                        name()
                    }
                    self.count = count
                }
            }
            """
        )

        let expanded = try expandBody(
            attributeSource: #"@ThreadSafeInitializer(["count": Storage<Int>(), "name": Storage<String>(value: "Seed")])"#,
            for: declaration
        )

        #expect(
            expanded.map(\.nonWhitespaceDescription) == [
                "var_count:Int",
                #"let_name:String="Seed""#,
                "funcname(){name()}",
                "_count=count",
                "self._state=ConcurrencyMacros.Mutex<_State>(_State(count:_count,name:_name))",
            ]
        )
    }

    @Test("Allows for enum case pattern binding to shadow tracked property before state initialization")
    func allowsForEnumCasePatternBindingToShadowTrackedPropertyBeforeStateInitialization() throws {
        let declaration = try initializerInStruct(
            """
            struct Example {
                init(count: Int, values: [String?]) {
                    for case let .some(name) in values {
                        print(name)
                    }
                    self.count = count
                }
            }
            """
        )

        let expanded = try expandBody(
            attributeSource: #"@ThreadSafeInitializer(["count": Storage<Int>(), "name": Storage<String>(value: "Seed")])"#,
            for: declaration
        )

        #expect(
            expanded.map(\.nonWhitespaceDescription) == [
                "var_count:Int",
                #"let_name:String="Seed""#,
                "forcaselet.some(name)invalues{print(name)}",
                "_count=count",
                "self._state=ConcurrencyMacros.Mutex<_State>(_State(count:_count,name:_name))",
            ]
        )
    }

    @Test("Diagnoses unshadowed tracked root inside closure before state initialization")
    func diagnosesUnshadowedTrackedRootInsideClosureBeforeStateInitialization() throws {
        let declaration = try initializerInStruct(
            """
            struct Example {
                init(values: [String]) {
                    self.count = values.map { _ in name.count }.reduce(0, +)
                }
            }
            """
        )

        try assertInitializerDiagnostic(
            attributeSource: #"@ThreadSafeInitializer(["count": Storage<Int>(), "name": Storage<String>(value: "Seed")])"#,
            for: declaration,
            expectedMessage: "Initializer access to tracked property 'name' before @ThreadSafe state initialization is only supported as the left-hand side of a plain top-level assignment.",
            expectedID: MessageID(domain: "ThreadSafeMacro", id: "unsupportedInitializerAssignment")
        )
    }

    @Test("Diagnoses parenthesized explicit self tracked property read before state initialization")
    func diagnosesParenthesizedExplicitSelfTrackedPropertyReadBeforeStateInitialization() throws {
        let declaration = try initializerInStruct(
            """
            struct Example {
                init(count: Int) {
                    print((self).name)
                    self.count = count
                }
            }
            """
        )

        try assertInitializerDiagnostic(
            attributeSource: #"@ThreadSafeInitializer(["count": Storage<Int>(), "name": Storage<String>(value: "Seed")])"#,
            for: declaration,
            expectedMessage: "Initializer access to tracked property 'name' before @ThreadSafe state initialization is only supported as the left-hand side of a plain top-level assignment.",
            expectedID: MessageID(domain: "ThreadSafeMacro", id: "unsupportedInitializerAssignment")
        )
    }

    @Test("Diagnoses parenthesized explicit self tracked subscript mutation before state initialization")
    func diagnosesParenthesizedExplicitSelfTrackedSubscriptMutationBeforeStateInitialization() throws {
        let declaration = try initializerInStruct(
            """
            struct Example {
                init(count: Int, value: String) {
                    (self).items[0] = value
                    self.count = count
                }
            }
            """
        )

        try assertInitializerDiagnostic(
            attributeSource: #"@ThreadSafeInitializer(["count": Storage<Int>(), "items": Storage<[String]>(value: [])])"#,
            for: declaration,
            expectedMessage: "Initializer access to tracked property 'items' before @ThreadSafe state initialization is only supported as the left-hand side of a plain top-level assignment.",
            expectedID: MessageID(domain: "ThreadSafeMacro", id: "unsupportedInitializerAssignment")
        )
    }

    @Test("Diagnoses non-plain tracked property mutation before state initialization")
    func diagnosesNonPlainTrackedPropertyMutationBeforeStateInitialization() throws {
        let declaration = try initializerInStruct(
            """
            struct Example {
                init(count: Int, value: String) {
                    self.items[0] = value
                    self.count = count
                }
            }
            """
        )

        try assertInitializerDiagnostic(
            attributeSource: #"@ThreadSafeInitializer(["count": Storage<Int>(), "items": Storage<[String]>(value: [])])"#,
            for: declaration,
            expectedMessage: "Initializer access to tracked property 'items' before @ThreadSafe state initialization is only supported as the left-hand side of a plain top-level assignment.",
            expectedID: MessageID(domain: "ThreadSafeMacro", id: "unsupportedInitializerAssignment")
        )
    }

    @Test("Allows nested local shadowing before state initialization")
    func allowsNestedLocalShadowingBeforeStateInitialization() throws {
        let declaration = try initializerInStruct(
            """
            struct Example {
                init(count: Int, flag: Bool) {
                    if flag {
                        var name = "Temp"
                        name = "Override"
                    }
                    self.count = count
                }
            }
            """
        )

        let expanded = try expandBody(
            attributeSource: #"@ThreadSafeInitializer(["count": Storage<Int>(), "name": Storage<String>(value: "Seed")])"#,
            for: declaration
        )

        #expect(
            expanded.map(\.nonWhitespaceDescription) == [
                "var_count:Int",
                #"let_name:String="Seed""#,
                "ifflag{varname=\"Temp\"name=\"Override\"}",
                "_count=count",
                "self._state=ConcurrencyMacros.Mutex<_State>(_State(count:_count,name:_name))",
            ]
        )
    }

    @Test("Allows condition binding local shadowing before state initialization")
    func allowsConditionBindingLocalShadowingBeforeStateInitialization() throws {
        let declaration = try initializerInStruct(
            """
            struct Example {
                init(count: Int, optionalName: String?) {
                    if var name = optionalName {
                        name = "Override"
                    }
                    self.count = count
                }
            }
            """
        )

        let expanded = try expandBody(
            attributeSource: #"@ThreadSafeInitializer(["count": Storage<Int>(), "name": Storage<String>(value: "Seed")])"#,
            for: declaration
        )

        #expect(
            expanded.map(\.nonWhitespaceDescription) == [
                "var_count:Int",
                #"let_name:String="Seed""#,
                "ifvarname=optionalName{name=\"Override\"}",
                "_count=count",
                "self._state=ConcurrencyMacros.Mutex<_State>(_State(count:_count,name:_name))",
            ]
        )
    }

    @Test("Diagnoses if shorthand optional binding of unshadowed tracked property before state initialization")
    func diagnosesIfShorthandOptionalBindingOfUnshadowedTrackedPropertyBeforeStateInitialization() throws {
        let declaration = try initializerInStruct(
            """
            struct Example {
                init(count: Int) {
                    if let name {
                        print(name)
                    }
                    self.count = count
                }
            }
            """
        )

        try assertInitializerDiagnostic(
            attributeSource: #"@ThreadSafeInitializer(["count": Storage<Int>(), "name": Storage<String?>()])"#,
            for: declaration,
            expectedMessage: "Initializer access to tracked property 'name' before @ThreadSafe state initialization is only supported as the left-hand side of a plain top-level assignment.",
            expectedID: MessageID(domain: "ThreadSafeMacro", id: "unsupportedInitializerAssignment")
        )
    }

    @Test("Diagnoses guard shorthand optional binding of unshadowed tracked property before state initialization")
    func diagnosesGuardShorthandOptionalBindingOfUnshadowedTrackedPropertyBeforeStateInitialization() throws {
        let declaration = try initializerInStruct(
            """
            struct Example {
                init(count: Int) {
                    guard let name else {
                        return
                    }
                    print(name)
                    self.count = count
                }
            }
            """
        )

        try assertInitializerDiagnostic(
            attributeSource: #"@ThreadSafeInitializer(["count": Storage<Int>(), "name": Storage<String?>()])"#,
            for: declaration,
            expectedMessage: "Initializer access to tracked property 'name' before @ThreadSafe state initialization is only supported as the left-hand side of a plain top-level assignment.",
            expectedID: MessageID(domain: "ThreadSafeMacro", id: "unsupportedInitializerAssignment")
        )
    }

    @Test("Diagnoses while shorthand optional binding of unshadowed tracked property before state initialization")
    func diagnosesWhileShorthandOptionalBindingOfUnshadowedTrackedPropertyBeforeStateInitialization() throws {
        let declaration = try initializerInStruct(
            """
            struct Example {
                init(count: Int) {
                    while let name {
                        print(name)
                        break
                    }
                    self.count = count
                }
            }
            """
        )

        try assertInitializerDiagnostic(
            attributeSource: #"@ThreadSafeInitializer(["count": Storage<Int>(), "name": Storage<String?>()])"#,
            for: declaration,
            expectedMessage: "Initializer access to tracked property 'name' before @ThreadSafe state initialization is only supported as the left-hand side of a plain top-level assignment.",
            expectedID: MessageID(domain: "ThreadSafeMacro", id: "unsupportedInitializerAssignment")
        )
    }

    @Test("Allows shorthand optional binding of shadowed tracked property before state initialization")
    func allowsShorthandOptionalBindingOfShadowedTrackedPropertyBeforeStateInitialization() throws {
        let declaration = try initializerInStruct(
            """
            struct Example {
                init(count: Int, name: String?) {
                    if let name {
                        print(name)
                    }
                    self.count = count
                }
            }
            """
        )

        let expanded = try expandBody(
            attributeSource: #"@ThreadSafeInitializer(["count": Storage<Int>(), "name": Storage<String?>()])"#,
            for: declaration
        )

        #expect(
            expanded.map(\.nonWhitespaceDescription) == [
                "var_count:Int",
                "let_name:String?=nil",
                "ifletname{print(name)}",
                "_count=count",
                "self._state=ConcurrencyMacros.Mutex<_State>(_State(count:_count,name:_name))",
            ]
        )
    }

    @Test("Allows earlier condition binding to shadow later condition elements")
    func allowsEarlierConditionBindingToShadowLaterConditionElements() throws {
        let declaration = try initializerInStruct(
            """
            struct Example {
                init(count: Int, optionalName: String?) {
                    if var name = optionalName, ({
                        name = "Override"
                        return true
                    })() {
                    }
                    self.count = count
                }
            }
            """
        )

        let expanded = try expandBody(
            attributeSource: #"@ThreadSafeInitializer(["count": Storage<Int>(), "name": Storage<String>(value: "Seed")])"#,
            for: declaration
        )

        #expect(
            expanded.map(\.nonWhitespaceDescription) == [
                "var_count:Int",
                #"let_name:String="Seed""#,
                #"ifvarname=optionalName,({name="Override"returntrue})(){}"#,
                "_count=count",
                "self._state=ConcurrencyMacros.Mutex<_State>(_State(count:_count,name:_name))",
            ]
        )
    }

    @Test("Allows earlier case condition binding to shadow later condition elements")
    func allowsEarlierCaseConditionBindingToShadowLaterConditionElements() throws {
        let declaration = try initializerInStruct(
            """
            struct Example {
                init(count: Int, optionalName: String?) {
                    if case var name? = optionalName, ({
                        name = "Override"
                        return true
                    })() {
                    }
                    self.count = count
                }
            }
            """
        )

        let expanded = try expandBody(
            attributeSource: #"@ThreadSafeInitializer(["count": Storage<Int>(), "name": Storage<String>(value: "Seed")])"#,
            for: declaration
        )

        #expect(
            expanded.map(\.nonWhitespaceDescription) == [
                "var_count:Int",
                #"let_name:String="Seed""#,
                #"ifcasevarname?=optionalName,({name="Override"returntrue})(){}"#,
                "_count=count",
                "self._state=ConcurrencyMacros.Mutex<_State>(_State(count:_count,name:_name))",
            ]
        )
    }

    @Test("Allows earlier enum case condition binding to shadow later condition elements")
    func allowsEarlierEnumCaseConditionBindingToShadowLaterConditionElements() throws {
        let declaration = try initializerInStruct(
            """
            struct Example {
                init(count: Int, optionalName: String?) {
                    if case let .some(name) = optionalName, ({
                        name = "Override"
                        return true
                    })() {
                    }
                    self.count = count
                }
            }
            """
        )

        let expanded = try expandBody(
            attributeSource: #"@ThreadSafeInitializer(["count": Storage<Int>(), "name": Storage<String>(value: "Seed")])"#,
            for: declaration
        )

        #expect(
            expanded.map(\.nonWhitespaceDescription) == [
                "var_count:Int",
                #"let_name:String="Seed""#,
                #"ifcaselet.some(name)=optionalName,({name="Override"returntrue})(){}"#,
                "_count=count",
                "self._state=ConcurrencyMacros.Mutex<_State>(_State(count:_count,name:_name))",
            ]
        )
    }

    @Test("Allows earlier guard condition binding to shadow later condition elements")
    func allowsEarlierGuardConditionBindingToShadowLaterConditionElements() throws {
        let declaration = try initializerInStruct(
            """
            struct Example {
                init(count: Int, optionalName: String?) {
                    guard var name = optionalName, ({
                        name = "Override"
                        return true
                    })() else {
                        return
                    }
                    self.count = count
                }
            }
            """
        )

        let expanded = try expandBody(
            attributeSource: #"@ThreadSafeInitializer(["count": Storage<Int>(), "name": Storage<String>(value: "Seed")])"#,
            for: declaration
        )

        #expect(
            expanded.map(\.nonWhitespaceDescription) == [
                "var_count:Int",
                #"let_name:String="Seed""#,
                #"guardvarname=optionalName,({name="Override"returntrue})()else{return}"#,
                "_count=count",
                "self._state=ConcurrencyMacros.Mutex<_State>(_State(count:_count,name:_name))",
            ]
        )
    }

    @Test("Allows earlier while condition binding to shadow later condition elements")
    func allowsEarlierWhileConditionBindingToShadowLaterConditionElements() throws {
        let declaration = try initializerInStruct(
            """
            struct Example {
                init(count: Int, optionalName: String?) {
                    while var name = optionalName, ({
                        name = "Override"
                        return false
                    })() {
                    }
                    self.count = count
                }
            }
            """
        )

        let expanded = try expandBody(
            attributeSource: #"@ThreadSafeInitializer(["count": Storage<Int>(), "name": Storage<String>(value: "Seed")])"#,
            for: declaration
        )

        #expect(
            expanded.map(\.nonWhitespaceDescription) == [
                "var_count:Int",
                #"let_name:String="Seed""#,
                #"whilevarname=optionalName,({name="Override"returnfalse})(){}"#,
                "_count=count",
                "self._state=ConcurrencyMacros.Mutex<_State>(_State(count:_count,name:_name))",
            ]
        )
    }

    @Test("Diagnoses explicit self assignment in later condition element despite earlier binding")
    func diagnosesExplicitSelfAssignmentInLaterConditionElementDespiteEarlierBinding() throws {
        let declaration = try initializerInStruct(
            """
            struct Example {
                init(count: Int, optionalName: String?) {
                    if var name = optionalName, ({
                        self.name = "Override"
                        return true
                    })() {
                    }
                    self.count = count
                }
            }
            """
        )

        try assertInitializerDiagnostic(
            attributeSource: #"@ThreadSafeInitializer(["count": Storage<Int>(), "name": Storage<String>(value: "Seed")])"#,
            for: declaration,
            expectedMessage: "Initializer access to tracked property 'name' before @ThreadSafe state initialization is only supported as the left-hand side of a plain top-level assignment.",
            expectedID: MessageID(domain: "ThreadSafeMacro", id: "unsupportedInitializerAssignment")
        )
    }

    @Test("Diagnoses explicit self access in later condition element despite earlier case binding")
    func diagnosesExplicitSelfAccessInLaterConditionElementDespiteEarlierCaseBinding() throws {
        let declaration = try initializerInStruct(
            """
            struct Example {
                init(count: Int, optionalName: String?) {
                    if case var name? = optionalName, ({
                        print(self.name)
                        return true
                    })() {
                    }
                    self.count = count
                }
            }
            """
        )

        try assertInitializerDiagnostic(
            attributeSource: #"@ThreadSafeInitializer(["count": Storage<Int>(), "name": Storage<String>(value: "Seed")])"#,
            for: declaration,
            expectedMessage: "Initializer access to tracked property 'name' before @ThreadSafe state initialization is only supported as the left-hand side of a plain top-level assignment.",
            expectedID: MessageID(domain: "ThreadSafeMacro", id: "unsupportedInitializerAssignment")
        )
    }

    @Test("Places internal state initialization first when all tracked properties have defaults")
    func placesInternalStateInitializationFirstWhenAllTrackedPropertiesHaveDefaults() throws {
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
            attributeSource: #"@ThreadSafeInitializer(["name": Storage<String>(value: "Anonymous")])"#,
            for: declaration
        )

        #expect(
            expanded.map(\.nonWhitespaceDescription) == [
                #"let_name:String="Anonymous""#,
                "self._state=ConcurrencyMacros.Mutex<_State>(_State(name:_name))",
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
                "self._state=ConcurrencyMacros.Mutex<_State>(_State())",
                "print(value)",
            ]
        )
    }

    @Test("Diagnoses dictionary entries with malformed values")
    func diagnosesDictionaryEntriesWithMalformedValues() throws {
        let declaration = try initializerInStruct(
            """
            struct Example {
                init(count: Int) {
                    self.count = count
                }
            }
            """
        )

        try assertInitializerDiagnostic(
            attributeSource: #"@ThreadSafeInitializer(["count": makeStorage(), invalidKey: Storage<Int>()])"#,
            for: declaration,
            expectedMessage: "@ThreadSafeInitializer entries must use string keys and generic storage values.",
            expectedID: MessageID(domain: "ThreadSafeMacro", id: "invalidInitializerPayload")
        )
    }

    @Test("Diagnoses dictionary entries with malformed keys")
    func diagnosesDictionaryEntriesWithMalformedKeys() throws {
        let declaration = try initializerInStruct(
            """
            struct Example {
                init(count: Int) {
                    self.count = count
                }
            }
            """
        )

        try assertInitializerDiagnostic(
            attributeSource: #"@ThreadSafeInitializer([invalidKey: Storage<Int>()])"#,
            for: declaration,
            expectedMessage: "@ThreadSafeInitializer entries must use string keys and generic storage values.",
            expectedID: MessageID(domain: "ThreadSafeMacro", id: "invalidInitializerPayload")
        )
    }

    @Test("Diagnoses dictionary entries with interpolated keys")
    func diagnosesDictionaryEntriesWithInterpolatedKeys() throws {
        let declaration = try initializerInStruct(
            """
            struct Example {
                init(count: Int) {
                    self.count = count
                }
            }
            """
        )

        try assertInitializerDiagnostic(
            attributeSource: #"@ThreadSafeInitializer(["count\(suffix)": Storage<Int>()])"#,
            for: declaration,
            expectedMessage: "@ThreadSafeInitializer entries must use string keys and generic storage values.",
            expectedID: MessageID(domain: "ThreadSafeMacro", id: "invalidInitializerPayload")
        )
    }

    @Test("Diagnoses dictionary entries with empty string keys")
    func diagnosesDictionaryEntriesWithEmptyStringKeys() throws {
        let declaration = try initializerInStruct(
            """
            struct Example {
                init(count: Int) {
                    self.count = count
                }
            }
            """
        )

        try assertInitializerDiagnostic(
            attributeSource: #"@ThreadSafeInitializer(["": Storage<Int>()])"#,
            for: declaration,
            expectedMessage: "@ThreadSafeInitializer entries must use string keys and generic storage values.",
            expectedID: MessageID(domain: "ThreadSafeMacro", id: "invalidInitializerPayload")
        )
    }

    @Test("Diagnoses dictionary entries with non-identifier string keys")
    func diagnosesDictionaryEntriesWithNonIdentifierStringKeys() throws {
        let declaration = try initializerInStruct(
            """
            struct Example {
                init(count: Int) {
                    self.count = count
                }
            }
            """
        )

        try assertInitializerDiagnostic(
            attributeSource: #"@ThreadSafeInitializer(["not valid": Storage<Int>()])"#,
            for: declaration,
            expectedMessage: "@ThreadSafeInitializer entries must use string keys and generic storage values.",
            expectedID: MessageID(domain: "ThreadSafeMacro", id: "invalidInitializerPayload")
        )
    }

    @Test("Diagnoses mixed payloads with an interpolated key after a valid entry")
    func diagnosesMixedPayloadsWithInterpolatedKeyAfterValidEntry() throws {
        let declaration = try initializerInStruct(
            """
            struct Example {
                init(count: Int, name: String) {
                    self.count = count
                    self.name = name
                }
            }
            """
        )

        try assertInitializerDiagnostic(
            attributeSource: #"@ThreadSafeInitializer(["count": Storage<Int>(), "name\(suffix)": Storage<String>()])"#,
            for: declaration,
            expectedMessage: "@ThreadSafeInitializer entries must use string keys and generic storage values.",
            expectedID: MessageID(domain: "ThreadSafeMacro", id: "invalidInitializerPayload")
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

    /// Asserts that initializer body expansion throws a single expected diagnostic.
    ///
    /// - Parameters:
    ///   - attributeSource: Source text that parses to an attribute.
    ///   - declaration: Initializer declaration whose body should be expanded.
    ///   - expectedMessage: Exact diagnostic message expected from expansion.
    ///   - expectedID: Stable diagnostic identifier expected from expansion.
    func assertInitializerDiagnostic(
        attributeSource: String,
        for declaration: InitializerDeclSyntax,
        expectedMessage: String,
        expectedID: MessageID
    ) throws {
        do {
            _ = try expandBody(attributeSource: attributeSource, for: declaration)
            Issue.record("Expected diagnostics error to be thrown")
        } catch let error as DiagnosticsError {
            #expect(error.diagnostics.count == 1)
            let diagnostic = try #require(error.diagnostics.first)
            #expect(diagnostic.message == expectedMessage)
            #expect(diagnostic.diagMessage.severity == .error)
            #expect(diagnostic.diagMessage.diagnosticID == expectedID)
        }
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
