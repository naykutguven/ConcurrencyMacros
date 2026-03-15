//
//  SingleFlightActorMacroTests.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 15.03.26.
//

import SwiftDiagnostics
import SwiftSyntaxMacroExpansion
import Testing
@testable import ConcurrencyMacrosImplementation

@Suite("SingleFlightActorMacro")
struct SingleFlightActorMacroTests {
    @Test("Expands throwing actor method with synthesized per-method store")
    func expandsThrowingActorMethodWithSynthesizedStore() throws {
        let (peerOutput, bodyOutput) = try expandedOutputs(
            from: """
            actor ProfileService {
                @SingleFlightActor(key: userID)
                func profile(userID: Int) async throws -> String {
                    try await api.fetchProfile(id: userID)
                }
            }
            """
        )

        #expect(peerOutput.contains("privatelet__singleFlightStore_"))
        #expect(peerOutput.contains("ConcurrencyMacros.ThrowingSingleFlightStore<String>()"))
        #expect(peerOutput.contains("privatefunc__singleFlightImpl_"))
        #expect(peerOutput.contains("tryawaitapi.fetchProfile(id:userID)"))
        #expect(bodyOutput.contains("let__singleFlightKey=userID"))
        #expect(bodyOutput.contains("ConcurrencyMacros.__singleFlightRequireSendable(__singleFlightKey)"))
        #expect(bodyOutput.contains("ConcurrencyMacros.__singleFlightRequireSendable(userID)"))
        #expect(bodyOutput.contains("let__singleFlightActor=self"))
        #expect(bodyOutput.contains("let__singleFlightOperation:@Sendable()asyncthrows->String={"))
        #expect(bodyOutput.contains("__singleFlightActor.__singleFlightImpl_"))
        #expect(bodyOutput.contains("returntryawait__singleFlightStore_"))
        #expect(bodyOutput.contains(".run(key:__singleFlightKey,operation:__singleFlightOperation)"))
        #expect(!bodyOutput.contains("func__singleFlightImpl"))
    }

    @Test("Expands non-throwing actor method with synthesized per-method store")
    func expandsNonThrowingActorMethodWithSynthesizedStore() throws {
        let (peerOutput, bodyOutput) = try expandedOutputs(
            from: """
            actor CounterService {
                @SingleFlightActor(key: id)
                func value(id: Int) async -> Int {
                    id * 2
                }
            }
            """
        )

        #expect(peerOutput.contains("privatelet__singleFlightStore_"))
        #expect(peerOutput.contains("ConcurrencyMacros.SingleFlightStore<Int>()"))
        #expect(peerOutput.contains("privatefunc__singleFlightImpl_"))
        #expect(peerOutput.contains("id*2"))
        #expect(bodyOutput.contains("returnawait__singleFlightStore_"))
        #expect(bodyOutput.contains("ConcurrencyMacros.__singleFlightRequireSendable(__singleFlightKey)"))
        #expect(bodyOutput.contains("ConcurrencyMacros.__singleFlightRequireSendable(id)"))
        #expect(bodyOutput.contains("let__singleFlightActor=self"))
        #expect(bodyOutput.contains("let__singleFlightOperation:@Sendable()async->Int={"))
        #expect(bodyOutput.contains("__singleFlightActor.__singleFlightImpl_"))
        #expect(bodyOutput.contains(".run(key:__singleFlightKey,operation:__singleFlightOperation)"))
        #expect(!bodyOutput.contains("func__singleFlightImpl"))
    }

    @Test("Uses explicit store expression when using is provided")
    func usesExplicitStoreExpressionWhenUsingIsProvided() throws {
        let (peerOutput, bodyOutput) = try expandedOutputs(
            from: """
            actor ProfileService {
                private let sharedFlights = ThrowingSingleFlightStore<String>()

                @SingleFlightActor(key: userID, using: sharedFlights, policy: .continueWhenNoWaiters)
                func profile(userID: Int) async throws -> String {
                    try await api.fetchProfile(id: userID)
                }
            }
            """
        )

        #expect(!peerOutput.contains("privatelet__singleFlightStore_"))
        #expect(peerOutput.contains("privatefunc__singleFlightImpl_"))
        #expect(bodyOutput.contains("ConcurrencyMacros.__singleFlightRequireSendable(__singleFlightKey)"))
        #expect(bodyOutput.contains("ConcurrencyMacros.__singleFlightRequireSendable(userID)"))
        #expect(bodyOutput.contains("let__singleFlightActor=self"))
        #expect(bodyOutput.contains("let__singleFlightOperation:@Sendable()asyncthrows->String={"))
        #expect(bodyOutput.contains("__singleFlightActor.__singleFlightImpl_"))
        #expect(bodyOutput.contains("returntryawaitsharedFlights.run(key:__singleFlightKey,policy:.continueWhenNoWaiters,operation:__singleFlightOperation)"))
    }

    @Test("Evaluates key expression once and forwards bound key")
    func evaluatesKeyExpressionOnce() throws {
        let (_, bodyOutput) = try expandedOutputs(
            from: """
            actor ProfileService {
                func nextKey() -> Int { 7 }

                @SingleFlightActor(key: nextKey())
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

    @Test("Rejects non-actor contexts")
    func rejectsNonActorContexts() throws {
        try assertPeerDiagnostic(
            source: """
            @SingleFlightActor(key: id)
            func profile(id: Int) async throws -> Int { 1 }
            """,
            expectedMessage: "'@SingleFlightActor' can only be attached to actor instance methods.",
            expectedID: MessageID(domain: "SingleFlightActorMacro", id: "nonActorContext")
        )
    }

    @Test("Rejects static methods")
    func rejectsStaticMethods() throws {
        try assertPeerDiagnostic(
            source: """
            actor ProfileService {
                @SingleFlightActor(key: id)
                static func profile(id: Int) async throws -> Int { 1 }
            }
            """,
            expectedMessage: "'@SingleFlightActor' does not support 'static' or 'class' methods.",
            expectedID: MessageID(domain: "SingleFlightActorMacro", id: "staticMethodUnsupported")
        )
    }

    @Test("Rejects non-async methods")
    func rejectsNonAsyncMethods() throws {
        try assertPeerDiagnostic(
            source: """
            actor ProfileService {
                @SingleFlightActor(key: id)
                func profile(id: Int) -> Int { 1 }
            }
            """,
            expectedMessage: "'@SingleFlightActor' requires an 'async' method.",
            expectedID: MessageID(domain: "SingleFlightActorMacro", id: "asyncRequired")
        )
    }

    @Test("Rejects typed throws methods")
    func rejectsTypedThrowsMethods() throws {
        try assertPeerDiagnostic(
            source: """
            actor ProfileService {
                enum Failure: Error { case failed }

                @SingleFlightActor(key: id)
                func profile(id: Int) async throws(Failure) -> Int { 1 }
            }
            """,
            expectedMessage: "'@SingleFlightActor' does not support typed-throws methods in v1.",
            expectedID: MessageID(domain: "SingleFlightActorMacro", id: "typedThrowsUnsupported")
        )
    }

    @Test("Rejects unsupported parameter forms")
    func rejectsUnsupportedParameterForms() throws {
        try assertPeerDiagnostic(
            source: """
            actor ProfileService {
                @SingleFlightActor(key: id)
                func profile(id: inout Int) async -> Int { id }
            }
            """,
            expectedMessage: "'@SingleFlightActor' does not support 'inout' parameters.",
            expectedID: MessageID(domain: "SingleFlightActorMacro", id: "unsupportedParameterForm")
        )
    }

    @Test("Rejects legacy string literal key arguments")
    func rejectsLegacyStringLiteralKeyArguments() throws {
        try assertPeerDiagnostic(
            source: """
            actor ProfileService {
                @SingleFlightActor(key: "id")
                func profile(id: Int) async -> Int { id }
            }
            """,
            expectedMessage: "String literal keys are unsupported. Use an expression, for example 'key: { (id: User.ID) in id }'.",
            expectedID: MessageID(domain: "SingleFlightActorMacro", id: "legacyStringKey")
        )
    }

    @Test("Rejects legacy string literal using arguments")
    func rejectsLegacyStringLiteralUsingArguments() throws {
        try assertPeerDiagnostic(
            source: """
            actor ProfileService {
                @SingleFlightActor(key: id, using: "sharedFlights")
                func profile(id: Int) async -> Int { id }
            }
            """,
            expectedMessage: "String literal stores are unsupported. Use an expression, for example 'using: sharedFlightsStore'.",
            expectedID: MessageID(domain: "SingleFlightActorMacro", id: "legacyStringUsing")
        )
    }

    @Test("Rejects key-path using expressions")
    func rejectsKeyPathUsingExpressions() throws {
        try assertPeerDiagnostic(
            source: """
            actor ProfileService {
                static let sharedFlights = SingleFlightStore<Int>()

                @SingleFlightActor(key: id, using: \\Self.sharedFlights)
                func profile(id: Int) async -> Int { id }
            }
            """,
            expectedMessage: "'using:' does not accept key-path literals. Pass a store expression such as 'using: sharedFlightsStore' or 'using: Self.sharedFlightsStore'.",
            expectedID: MessageID(domain: "SingleFlightActorMacro", id: "keyPathUsingUnsupported")
        )
    }

    @Test("Rejects unsupported using expressions")
    func rejectsUnsupportedUsingExpressions() throws {
        try assertPeerDiagnostic(
            source: """
            actor ProfileService {
                func makeStore() -> SingleFlightStore<Int> { SingleFlightStore<Int>() }

                @SingleFlightActor(key: id, using: makeStore())
                func profile(id: Int) async -> Int { id }
            }
            """,
            expectedMessage: "'using:' must reference an existing store value (identifier or member access).",
            expectedID: MessageID(domain: "SingleFlightActorMacro", id: "unsupportedUsingExpression")
        )
    }

    @Test("Rejects methods declared in extensions")
    func rejectsMethodsDeclaredInExtensions() throws {
        try assertPeerDiagnostic(
            source: """
            actor ProfileService {}

            extension ProfileService {
                @SingleFlightActor(key: id)
                func profile(id: Int) async -> Int { id }
            }
            """,
            expectedMessage: "'@SingleFlightActor' does not support methods declared in extensions in v1.",
            expectedID: MessageID(domain: "SingleFlightActorMacro", id: "extensionsUnsupported")
        )
    }
}

private extension SingleFlightActorMacroTests {
    func expandedOutputs(from source: String) throws -> (peerOutput: String, bodyOutput: String) {
        let function = try TestSupport.firstAttributedFunction(in: source)
        let attribute = try TestSupport.firstAttribute(in: function)
        let context = BasicMacroExpansionContext()

        let peers = try SingleFlightActorMacro.expansion(
            of: attribute,
            providingPeersOf: function,
            in: context
        )
        let body = try SingleFlightActorMacro.expansion(
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
            _ = try SingleFlightActorMacro.expansion(
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
