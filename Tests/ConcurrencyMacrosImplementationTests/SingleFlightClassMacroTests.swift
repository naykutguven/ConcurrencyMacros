//
//  SingleFlightClassMacroTests.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 16.03.26.
//

import SwiftDiagnostics
import SwiftSyntaxMacroExpansion
import Testing
@testable import ConcurrencyMacrosImplementation

@Suite("SingleFlightClassMacro")
struct SingleFlightClassMacroTests {
    @Test("Expands throwing class method with required explicit store")
    func expandsThrowingClassMethodWithRequiredExplicitStore() throws {
        let (peerOutput, bodyOutput) = try expandedOutputs(
            from: """
            final class ProfileService: Sendable {
                private static let sharedFlights = ThrowingSingleFlightStore<String>()

                @SingleFlightClass(key: userID, using: Self.sharedFlights)
                func profile(userID: Int) async throws -> String {
                    try await api.fetchProfile(id: userID)
                }
            }
            """
        )

        #expect(!peerOutput.contains("privatelet__singleFlightStore_"))
        #expect(peerOutput.contains("privatefunc__singleFlightImpl_"))
        #expect(peerOutput.contains("tryawaitapi.fetchProfile(id:userID)"))
        #expect(bodyOutput.contains("let__singleFlightKey=userID"))
        #expect(bodyOutput.contains("ConcurrencyMacros.__singleFlightRequireSendable(self)"))
        #expect(bodyOutput.contains("ConcurrencyMacros.__singleFlightRequireSendable(__singleFlightKey)"))
        #expect(bodyOutput.contains("ConcurrencyMacros.__singleFlightRequireSendable(userID)"))
        #expect(bodyOutput.contains("let__singleFlightClassInstance=self"))
        #expect(bodyOutput.contains("let__singleFlightOperation:@Sendable()asyncthrows->String={"))
        #expect(bodyOutput.contains("__singleFlightClassInstance.__singleFlightImpl_"))
        #expect(bodyOutput.contains("returntryawaitSelf.sharedFlights.run(key:__singleFlightKey,operation:__singleFlightOperation)"))
    }

    @Test("Expands non-throwing class method with explicit policy")
    func expandsNonThrowingClassMethodWithExplicitPolicy() throws {
        let (peerOutput, bodyOutput) = try expandedOutputs(
            from: """
            final class CounterService: Sendable {
                private static let sharedFlights = SingleFlightStore<Int>()

                @SingleFlightClass(key: id, using: Self.sharedFlights, policy: .continueWhenNoWaiters)
                func value(id: Int) async -> Int {
                    id * 2
                }
            }
            """
        )

        #expect(!peerOutput.contains("privatelet__singleFlightStore_"))
        #expect(peerOutput.contains("privatefunc__singleFlightImpl_"))
        #expect(peerOutput.contains("id*2"))
        #expect(bodyOutput.contains("ConcurrencyMacros.__singleFlightRequireSendable(self)"))
        #expect(bodyOutput.contains("ConcurrencyMacros.__singleFlightRequireSendable(__singleFlightKey)"))
        #expect(bodyOutput.contains("ConcurrencyMacros.__singleFlightRequireSendable(id)"))
        #expect(bodyOutput.contains("let__singleFlightOperation:@Sendable()async->Int={"))
        #expect(bodyOutput.contains("returnawaitSelf.sharedFlights.run(key:__singleFlightKey,policy:.continueWhenNoWaiters,operation:__singleFlightOperation)"))
    }

    @Test("Evaluates key expression once and forwards bound key")
    func evaluatesKeyExpressionOnce() throws {
        let (_, bodyOutput) = try expandedOutputs(
            from: """
            final class ProfileService: Sendable {
                private static let sharedFlights = ThrowingSingleFlightStore<Int>()
                func nextKey() -> Int { 7 }

                @SingleFlightClass(key: nextKey(), using: Self.sharedFlights)
                func profile() async throws -> Int {
                    42
                }
            }
            """
        )

        #expect(bodyOutput.contains("let__singleFlightKey=nextKey()"))
        #expect(bodyOutput.contains("ConcurrencyMacros.__singleFlightRequireSendable(__singleFlightKey)"))
        #expect(bodyOutput.contains("run(key:__singleFlightKey,operation:__singleFlightOperation)"))
        #expect(!bodyOutput.contains("run(key:nextKey(),"))
    }

    @Test("Rejects non-class contexts")
    func rejectsNonClassContexts() throws {
        try assertPeerDiagnostic(
            source: """
            @SingleFlightClass(key: id, using: sharedFlights)
            func profile(id: Int) async throws -> Int { 1 }
            """,
            expectedMessage: "'@SingleFlightClass' can only be attached to class instance methods.",
            expectedID: MessageID(domain: "SingleFlightClassMacro", id: "nonClassContext")
        )
    }

    @Test("Rejects methods declared in extensions")
    func rejectsMethodsDeclaredInExtensions() throws {
        try assertPeerDiagnostic(
            source: """
            final class ProfileService: Sendable {}

            extension ProfileService {
                @SingleFlightClass(key: id, using: sharedFlights)
                func profile(id: Int) async -> Int { id }
            }
            """,
            expectedMessage: "'@SingleFlightClass' does not support methods declared in extensions in v1.",
            expectedID: MessageID(domain: "SingleFlightClassMacro", id: "extensionsUnsupported")
        )
    }

    @Test("Rejects static methods")
    func rejectsStaticMethods() throws {
        try assertPeerDiagnostic(
            source: """
            final class ProfileService: Sendable {
                private static let sharedFlights = ThrowingSingleFlightStore<Int>()

                @SingleFlightClass(key: id, using: sharedFlights)
                static func profile(id: Int) async throws -> Int { 1 }
            }
            """,
            expectedMessage: "'@SingleFlightClass' does not support 'static' or 'class' methods.",
            expectedID: MessageID(domain: "SingleFlightClassMacro", id: "staticMethodUnsupported")
        )
    }

    @Test("Rejects missing using argument")
    func rejectsMissingUsingArgument() throws {
        try assertPeerDiagnostic(
            source: """
            final class ProfileService: Sendable {
                @SingleFlightClass(key: id)
                func profile(id: Int) async -> Int { id }
            }
            """,
            expectedMessage: "'@SingleFlightClass' requires a 'using:' argument.",
            expectedID: MessageID(domain: "SingleFlightClassMacro", id: "missingUsing")
        )
    }

    @Test("Rejects non-final classes")
    func rejectsNonFinalClasses() throws {
        try assertPeerDiagnostic(
            source: """
            class ProfileService: Sendable {
                private let sharedFlights = SingleFlightStore<Int>()

                @SingleFlightClass(key: id, using: sharedFlights)
                func profile(id: Int) async -> Int { id }
            }
            """,
            expectedMessage: "'@SingleFlightClass' requires the enclosing class to be declared 'final'.",
            expectedID: MessageID(domain: "SingleFlightClassMacro", id: "finalClassRequired")
        )
    }

    @Test("Rejects classes without explicit Sendable conformance")
    func rejectsClassesWithoutExplicitSendableConformance() throws {
        try assertPeerDiagnostic(
            source: """
            final class ProfileService {
                private let sharedFlights = SingleFlightStore<Int>()

                @SingleFlightClass(key: id, using: sharedFlights)
                func profile(id: Int) async -> Int { id }
            }
            """,
            expectedMessage: "'@SingleFlightClass' requires the enclosing class to explicitly conform to 'Sendable'.",
            expectedID: MessageID(domain: "SingleFlightClassMacro", id: "sendableConformanceRequired")
        )
    }

    @Test("Rejects classes using @unchecked Sendable")
    func rejectsUncheckedSendableConformance() throws {
        try assertPeerDiagnostic(
            source: """
            final class ProfileService: @unchecked Sendable {
                private let sharedFlights = SingleFlightStore<Int>()

                @SingleFlightClass(key: id, using: sharedFlights)
                func profile(id: Int) async -> Int { id }
            }
            """,
            expectedMessage: "'@SingleFlightClass' does not support '@unchecked Sendable' conformances.",
            expectedID: MessageID(domain: "SingleFlightClassMacro", id: "uncheckedSendableUnsupported")
        )
    }

    @Test("Rejects non-async methods")
    func rejectsNonAsyncMethods() throws {
        try assertPeerDiagnostic(
            source: """
            final class ProfileService: Sendable {
                private let sharedFlights = SingleFlightStore<Int>()

                @SingleFlightClass(key: id, using: sharedFlights)
                func profile(id: Int) -> Int { 1 }
            }
            """,
            expectedMessage: "'@SingleFlightClass' requires an 'async' method.",
            expectedID: MessageID(domain: "SingleFlightClassMacro", id: "asyncRequired")
        )
    }

    @Test("Rejects typed throws methods")
    func rejectsTypedThrowsMethods() throws {
        try assertPeerDiagnostic(
            source: """
            final class ProfileService: Sendable {
                enum Failure: Error { case failed }
                private let sharedFlights = ThrowingSingleFlightStore<Int>()

                @SingleFlightClass(key: id, using: sharedFlights)
                func profile(id: Int) async throws(Failure) -> Int { 1 }
            }
            """,
            expectedMessage: "'@SingleFlightClass' does not support typed-throws methods in v1.",
            expectedID: MessageID(domain: "SingleFlightClassMacro", id: "typedThrowsUnsupported")
        )
    }

    @Test("Rejects generic methods")
    func rejectsGenericMethods() throws {
        try assertPeerDiagnostic(
            source: """
            final class ProfileService: Sendable {
                private let sharedFlights = ThrowingSingleFlightStore<Int>()

                @SingleFlightClass(key: id, using: sharedFlights)
                func profile<T>(id: Int, value: T) async throws -> Int { id }
            }
            """,
            expectedMessage: "'@SingleFlightClass' does not support generic methods in v1.",
            expectedID: MessageID(domain: "SingleFlightClassMacro", id: "genericMethodUnsupported")
        )
    }

    @Test("Rejects opaque return types")
    func rejectsOpaqueReturnTypes() throws {
        try assertPeerDiagnostic(
            source: """
            final class ProfileService: Sendable {
                private let sharedFlights = SingleFlightStore<Int>()

                @SingleFlightClass(key: id, using: sharedFlights)
                func profile(id: Int) async -> some Sequence<Int> { [id] }
            }
            """,
            expectedMessage: "'@SingleFlightClass' does not support opaque 'some' return types in v1.",
            expectedID: MessageID(domain: "SingleFlightClassMacro", id: "opaqueReturnUnsupported")
        )
    }

    @Test("Rejects unsupported parameter forms")
    func rejectsUnsupportedParameterForms() throws {
        try assertPeerDiagnostic(
            source: """
            final class ProfileService: Sendable {
                private let sharedFlights = SingleFlightStore<Int>()

                @SingleFlightClass(key: id, using: sharedFlights)
                func profile(id: inout Int) async -> Int { id }
            }
            """,
            expectedMessage: "'@SingleFlightClass' does not support 'inout' parameters.",
            expectedID: MessageID(domain: "SingleFlightClassMacro", id: "unsupportedParameterForm")
        )
    }

    @Test("Rejects legacy string literal key arguments")
    func rejectsLegacyStringLiteralKeyArguments() throws {
        try assertPeerDiagnostic(
            source: """
            final class ProfileService: Sendable {
                private let sharedFlights = SingleFlightStore<Int>()

                @SingleFlightClass(key: "id", using: sharedFlights)
                func profile(id: Int) async -> Int { id }
            }
            """,
            expectedMessage: "String literal keys are unsupported. Use an expression, for example 'key: { (id: User.ID) in id }'.",
            expectedID: MessageID(domain: "SingleFlightClassMacro", id: "legacyStringKey")
        )
    }

    @Test("Rejects legacy string literal using arguments")
    func rejectsLegacyStringLiteralUsingArguments() throws {
        try assertPeerDiagnostic(
            source: """
            final class ProfileService: Sendable {
                @SingleFlightClass(key: id, using: "sharedFlights")
                func profile(id: Int) async -> Int { id }
            }
            """,
            expectedMessage: "String literal stores are unsupported. Use an expression, for example 'using: sharedFlightsStore'.",
            expectedID: MessageID(domain: "SingleFlightClassMacro", id: "legacyStringUsing")
        )
    }

    @Test("Rejects key-path using expressions")
    func rejectsKeyPathUsingExpressions() throws {
        try assertPeerDiagnostic(
            source: """
            final class ProfileService: Sendable {
                static let sharedFlights = SingleFlightStore<Int>()

                @SingleFlightClass(key: id, using: \\Self.sharedFlights)
                func profile(id: Int) async -> Int { id }
            }
            """,
            expectedMessage: "'using:' does not accept key-path literals. Pass a store expression such as 'using: sharedFlightsStore' or 'using: Self.sharedFlightsStore'.",
            expectedID: MessageID(domain: "SingleFlightClassMacro", id: "keyPathUsingUnsupported")
        )
    }

    @Test("Rejects unsupported using expressions")
    func rejectsUnsupportedUsingExpressions() throws {
        try assertPeerDiagnostic(
            source: """
            final class ProfileService: Sendable {
                func makeStore() -> SingleFlightStore<Int> { SingleFlightStore<Int>() }

                @SingleFlightClass(key: id, using: makeStore())
                func profile(id: Int) async -> Int { id }
            }
            """,
            expectedMessage: "'using:' must reference an existing store value (identifier or member access).",
            expectedID: MessageID(domain: "SingleFlightClassMacro", id: "unsupportedUsingExpression")
        )
    }
}

private extension SingleFlightClassMacroTests {
    func expandedOutputs(from source: String) throws -> (peerOutput: String, bodyOutput: String) {
        let function = try TestSupport.firstAttributedFunction(in: source)
        let attribute = try TestSupport.firstAttribute(in: function)
        let context = BasicMacroExpansionContext()

        let peers = try SingleFlightClassMacro.expansion(
            of: attribute,
            providingPeersOf: function,
            in: context
        )
        let body = try SingleFlightClassMacro.expansion(
            of: attribute,
            providingBodyFor: function,
            in: context
        )

        let peerOutput = peers.map(\.nonWhitespaceDescription).joined(separator: "")
        let bodyOutput = body.map(\.nonWhitespaceDescription).joined(separator: "")
        return (peerOutput, bodyOutput)
    }

    func assertPeerDiagnostic(
        source: String,
        expectedMessage: String,
        expectedID: MessageID
    ) throws {
        let function = try TestSupport.firstAttributedFunction(in: source)
        let attribute = try TestSupport.firstAttribute(in: function)

        do {
            _ = try SingleFlightClassMacro.expansion(
                of: attribute,
                providingPeersOf: function,
                in: BasicMacroExpansionContext()
            )
            Issue.record("Expected diagnostics error to be thrown")
        } catch let error as DiagnosticsError {
            let diagnostic = try #require(error.diagnostics.first)
            #expect(diagnostic.message == expectedMessage)
            #expect(diagnostic.diagMessage.severity == .error)
            #expect(diagnostic.diagMessage.diagnosticID == expectedID)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}
