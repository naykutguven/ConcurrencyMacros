//
//  StreamBridgeMacroTests.swift
//  ConcurrencyMacrosImplementationTests
//
//  Created by Codex on 15.03.26.
//

import SwiftDiagnostics
import SwiftSyntaxMacroExpansion
import Testing
@testable import ConcurrencyMacrosImplementation

@Suite("StreamBridgeMacro")
struct StreamBridgeMacroTests {
    @Test("Expands non-throwing bridge with owner-method cancellation")
    func expandsNonThrowingBridgeWithOwnerMethodCancellation() throws {
        let (peerOutput, bodyOutput) = try expandedOutputs(
            from: """
            final class StockTicker: Sendable {
                @StreamBridge(
                    as: "priceStream",
                    event: .label("handler"),
                    cancel: .ownerMethod("stopObserving")
                )
                func observePrice(
                    symbol: String,
                    handler: @escaping @Sendable (Double) -> Void
                ) -> ObservationToken {
                    makeToken(symbol: symbol, handler: handler)
                }

                func stopObserving(_ token: ObservationToken) {}
            }
            """
        )

        #expect(peerOutput.contains("funcpriceStream(symbol:String)->AsyncStream<Double>"))
        #expect(peerOutput.contains("StreamBridgeRuntime.makeStream("))
        #expect(peerOutput.contains("bufferingPolicy:.unbounded"))
        #expect(peerOutput.contains("let__streamBridgeToken=__streamBridgeOwner.observePrice("))
        #expect(peerOutput.contains("handler:{__streamBridgeEventin"))
        #expect(peerOutput.contains("__streamBridgeOnEvent(__streamBridgeEvent)"))
        #expect(peerOutput.contains("cancel:{__streamBridgeTokenin_=__streamBridgeOwner.stopObserving(__streamBridgeToken)}"))
        #expect(peerOutput.contains("ConcurrencyMacros.__streamBridgeRequireSendable(__streamBridgeOwner)"))
        #expect(peerOutput.contains("ConcurrencyMacros.__streamBridgeRequireSendable(__streamBridgeToken)"))
        #expect(bodyOutput.contains("makeToken(symbol:symbol,handler:handler)"))
    }

    @Test("Expands throwing bridge and applies defaults precedence")
    func expandsThrowingBridgeAndAppliesDefaultsPrecedence() throws {
        let (peerOutput, _) = try expandedOutputs(
            from: """
            @StreamBridgeDefaults(
                cancel: .ownerMethod("disconnect"),
                buffering: .bufferingNewest(2),
                safety: .unchecked
            )
            final class SocketClient: Sendable {
                @StreamBridge(
                    as: "messageStream",
                    event: .label("onMessage"),
                    failure: .label("onError", as: SocketError.self),
                    completion: .label("onClose"),
                    buffering: .unbounded
                )
                func connect(
                    channel: String,
                    onMessage: @escaping @Sendable (Message) -> Void,
                    onError: @escaping @Sendable (SocketError) -> Void,
                    onClose: @escaping @Sendable () -> Void
                ) -> ConnectionToken {
                    makeConnection(
                        channel: channel,
                        onMessage: onMessage,
                        onError: onError,
                        onClose: onClose
                    )
                }

                func disconnect(_ token: ConnectionToken) {}
            }
            """
        )

        #expect(peerOutput.contains("funcmessageStream(channel:String)->AsyncThrowingStream<Message,anyError>"))
        #expect(peerOutput.contains("StreamBridgeRuntime.makeThrowingStreamUnchecked("))
        #expect(peerOutput.contains("bufferingPolicy:.unbounded"))
        #expect(peerOutput.contains("let__streamBridgeOnFailureTyped:(SocketError)->Void=__streamBridgeOnFailure"))
        #expect(peerOutput.contains("onMessage:{__streamBridgeEventin__streamBridgeOnEvent(__streamBridgeEvent)}"))
        #expect(peerOutput.contains("onError:{(__streamBridgeFailure:SocketError)in__streamBridgeOnFailureTyped(__streamBridgeFailure)}"))
        #expect(peerOutput.contains("onClose:{__streamBridgeOnCompletion()}"))
        #expect(peerOutput.contains("cancel:{__streamBridgeTokenin_=__streamBridgeOwner.disconnect(__streamBridgeToken)}"))
        #expect(!peerOutput.contains("__streamBridgeRequireSendable("))
    }

    @Test("Expands owner-method cancellation with explicit token argument label")
    func expandsOwnerMethodCancellationWithExplicitTokenArgumentLabel() throws {
        let (peerOutput, _) = try expandedOutputs(
            from: """
            final class StockTicker: Sendable {
                @StreamBridge(
                    as: "priceStream",
                    event: .label("handler"),
                    cancel: .ownerMethod("stopObserving", argumentLabel: "token")
                )
                func observePrice(
                    handler: @escaping @Sendable (Double) -> Void
                ) -> ObservationToken {
                    makeToken(handler: handler)
                }

                func stopObserving(token: ObservationToken) {}
            }
            """
        )

        #expect(peerOutput.contains("cancel:{__streamBridgeTokenin_=__streamBridgeOwner.stopObserving(token:__streamBridgeToken)}"))
    }

    @Test("Rejects missing as argument")
    func rejectsMissingAsArgument() throws {
        try assertPeerDiagnostic(
            source: """
            final class StockTicker: Sendable {
                @StreamBridge(event: .label("handler"))
                func observePrice(handler: @escaping @Sendable (Int) -> Void) -> Token {
                    makeToken(handler: handler)
                }
            }
            """,
            expectedMessage: "'@StreamBridge' requires an 'as:' argument.",
            expectedID: MessageID(domain: "StreamBridgeMacro", id: "missingAs")
        )
    }

    @Test("Rejects selector labels that do not match any parameter")
    func rejectsSelectorLabelsThatDoNotMatchAnyParameter() throws {
        try assertPeerDiagnostic(
            source: """
            final class StockTicker: Sendable {
                @StreamBridge(as: "priceStream", event: .label("updates"))
                func observePrice(handler: @escaping @Sendable (Int) -> Void) -> Token {
                    makeToken(handler: handler)
                }
            }
            """,
            expectedMessage: "'@StreamBridge' could not find a event callback parameter labeled 'updates'.",
            expectedID: MessageID(domain: "StreamBridgeMacro", id: "eventSelectorNotFound")
        )
    }

    @Test("Rejects failure selector without explicit failure type")
    func rejectsFailureSelectorWithoutExplicitFailureType() throws {
        try assertPeerDiagnostic(
            source: """
            enum BridgeFailure: Error { case disconnected }

            final class SocketBridge: Sendable {
                @StreamBridge(
                    as: "messageStream",
                    event: .label("onMessage"),
                    failure: .label("onError")
                )
                func connect(
                    onMessage: @escaping @Sendable (String) -> Void,
                    onError: @escaping @Sendable (BridgeFailure) -> Void
                ) -> Token {
                    makeToken(onMessage: onMessage, onError: onError)
                }
            }
            """,
            expectedMessage: "'@StreamBridge' failure selector requires one label string and one 'as:' failure type.",
            expectedID: MessageID(domain: "StreamBridgeMacro", id: "failureSelectorArgumentShape")
        )
    }

    @Test("Rejects invalid callback signature for event selector")
    func rejectsInvalidCallbackSignatureForEventSelector() throws {
        try assertPeerDiagnostic(
            source: """
            final class StockTicker: Sendable {
                @StreamBridge(as: "priceStream", event: .label("handler"))
                func observePrice(handler: @escaping @Sendable (Int, Int) -> Void) -> Token {
                    makeToken(handler: handler)
                }
            }
            """,
            expectedMessage: "'@StreamBridge' event callback must have one parameter and return 'Void'.",
            expectedID: MessageID(domain: "StreamBridgeMacro", id: "invalidEventCallbackSignature")
        )
    }

    @Test("Rejects duplicate metadata arguments")
    func rejectsDuplicateMetadataArguments() throws {
        try assertPeerDiagnostic(
            source: """
            final class StockTicker: Sendable {
                @StreamBridge(
                    as: "priceStream",
                    event: .label("handler"),
                    cancel: .none,
                    cancel: .tokenMethod
                )
                func observePrice(handler: @escaping @Sendable (Int) -> Void) -> Token {
                    makeToken(handler: handler)
                }
            }
            """,
            expectedMessage: "'@StreamBridge' accepts at most one 'cancel:' argument.",
            expectedID: MessageID(domain: "StreamBridgeMacro", id: "duplicateCancel")
        )
    }

    @Test("Rejects cancellation strategy when source method returns void")
    func rejectsCancellationStrategyWhenSourceMethodReturnsVoid() throws {
        try assertPeerDiagnostic(
            source: """
            final class StockTicker: Sendable {
                @StreamBridge(
                    as: "priceStream",
                    event: .label("handler"),
                    cancel: .ownerMethod("stop")
                )
                func observePrice(handler: @escaping @Sendable (Int) -> Void) {
                    _ = handler
                }
            }
            """,
            expectedMessage: "'@StreamBridge' cancellation strategies other than '.none' require the source method to return a token.",
            expectedID: MessageID(domain: "StreamBridgeMacro", id: "cancelRequiresTokenReturn")
        )
    }

    @Test("Defers owner cancellation label mismatch to compiler type checking")
    func defersOwnerCancellationLabelMismatchToCompilerTypeChecking() throws {
        let (peerOutput, _) = try expandedOutputs(
            from: """
            final class StockTicker: Sendable {
                @StreamBridge(
                    as: "priceStream",
                    event: .label("handler"),
                    cancel: .ownerMethod("stopObserving", argumentLabel: "token")
                )
                func observePrice(handler: @escaping @Sendable (Int) -> Void) -> ObservationToken {
                    makeToken(handler: handler)
                }

                func stopObserving(_ token: ObservationToken) {}
            }
            """
        )

        #expect(peerOutput.contains("cancel:{__streamBridgeTokenin_=__streamBridgeOwner.stopObserving(token:__streamBridgeToken)}"))
    }

    @Test("Defers async owner cancellation method checks to compiler type checking")
    func defersAsyncOwnerCancellationMethodChecksToCompilerTypeChecking() throws {
        let (peerOutput, _) = try expandedOutputs(
            from: """
            final class StockTicker: Sendable {
                @StreamBridge(
                    as: "priceStream",
                    event: .label("handler"),
                    cancel: .ownerMethod("stopObserving")
                )
                func observePrice(handler: @escaping @Sendable (Int) -> Void) -> ObservationToken {
                    makeToken(handler: handler)
                }

                func stopObserving(_ token: ObservationToken) async {}
            }
            """
        )

        #expect(peerOutput.contains("cancel:{__streamBridgeTokenin_=__streamBridgeOwner.stopObserving(__streamBridgeToken)}"))
    }

    @Test("Resolves owner cancellation overload by token type")
    func resolvesOwnerCancellationOverloadByTokenType() throws {
        let (peerOutput, _) = try expandedOutputs(
            from: """
            final class StockTicker: Sendable {
                @StreamBridge(
                    as: "priceStream",
                    event: .label("handler"),
                    cancel: .ownerMethod("stopObserving")
                )
                func observePrice(handler: @escaping @Sendable (Int) -> Void) -> ObservationToken {
                    makeToken(handler: handler)
                }

                func stopObserving(_ token: ObservationToken) {}
                func stopObserving(_ token: String) {}
            }
            """
        )

        #expect(peerOutput.contains("cancel:{__streamBridgeTokenin_=__streamBridgeOwner.stopObserving(__streamBridgeToken)}"))
    }

    @Test("Defers owner cancellation token type mismatch to compiler type checking")
    func defersOwnerCancellationTokenTypeMismatchToCompilerTypeChecking() throws {
        let (peerOutput, _) = try expandedOutputs(
            from: """
            final class StockTicker: Sendable {
                @StreamBridge(
                    as: "priceStream",
                    event: .label("handler"),
                    cancel: .ownerMethod("stopObserving")
                )
                func observePrice(handler: @escaping @Sendable (Int) -> Void) -> ObservationToken {
                    makeToken(handler: handler)
                }

                func stopObserving(_ token: String) {}
            }
            """
        )

        #expect(peerOutput.contains("cancel:{__streamBridgeTokenin_=__streamBridgeOwner.stopObserving(__streamBridgeToken)}"))
    }

    @Test("Allows owner cancellation methods declared in extensions")
    func allowsOwnerCancellationMethodsDeclaredInExtensions() throws {
        let (peerOutput, _) = try expandedOutputs(
            from: """
            final class StockTicker: Sendable {
                @StreamBridge(
                    as: "priceStream",
                    event: .label("handler"),
                    cancel: .ownerMethod("stopObserving")
                )
                func observePrice(handler: @escaping @Sendable (Int) -> Void) -> ObservationToken {
                    makeToken(handler: handler)
                }
            }

            extension StockTicker {
                func stopObserving(_ token: ObservationToken) {}
            }
            """
        )

        #expect(peerOutput.contains("cancel:{__streamBridgeTokenin_=__streamBridgeOwner.stopObserving(__streamBridgeToken)}"))
    }

    @Test("Rejects owner-method cancellation on actor methods")
    func rejectsOwnerMethodCancellationOnActorMethods() throws {
        try assertPeerDiagnostic(
            source: """
            actor StockTicker {
                @StreamBridge(
                    as: "priceStream",
                    event: .label("handler"),
                    cancel: .ownerMethod("stopObserving")
                )
                func observePrice(handler: @escaping @Sendable (Int) -> Void) -> ObservationToken {
                    makeToken(handler: handler)
                }

                func stopObserving(_ token: ObservationToken) {}
            }
            """,
            expectedMessage: "'@StreamBridge' '.ownerMethod' cancellation is not supported on actor methods in v1; use '.tokenMethod' or '.none'.",
            expectedID: MessageID(domain: "StreamBridgeMacro", id: "ownerMethodUnsupportedOnActor")
        )
    }

    @Test("Rejects strict safety when enclosing class is not explicitly sendable")
    func rejectsStrictSafetyWhenEnclosingClassIsNotExplicitlySendable() throws {
        try assertPeerDiagnostic(
            source: """
            final class StockTicker {
                @StreamBridge(as: "priceStream", event: .label("handler"))
                func observePrice(handler: @escaping @Sendable (Int) -> Void) -> Token {
                    makeToken(handler: handler)
                }
            }
            """,
            expectedMessage: "'@StreamBridge' strict safety requires the enclosing class to explicitly conform to 'Sendable'.",
            expectedID: MessageID(domain: "StreamBridgeMacro", id: "sendableConformanceRequired")
        )
    }
}

private extension StreamBridgeMacroTests {
    func expandedOutputs(from source: String) throws -> (peerOutput: String, bodyOutput: String) {
        let function = try TestSupport.firstAttributedFunction(in: source)
        let attribute = try TestSupport.firstAttribute(in: function)
        let context = BasicMacroExpansionContext()

        let peers = try StreamBridgeMacro.expansion(
            of: attribute,
            providingPeersOf: function,
            in: context
        )
        let body = try StreamBridgeMacro.expansion(
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
            _ = try StreamBridgeMacro.expansion(
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
