//
//  StreamBridgeRuntimeTests.swift
//  ConcurrencyMacrosRuntimeTests
//
//  Created by Codex on 15.03.26.
//

import Testing
@testable import ConcurrencyMacrosRuntime

@Suite("StreamBridgeRuntime")
struct StreamBridgeRuntimeTests {
    private final class LegacyEvent {
        let value: Int

        init(value: Int) {
            self.value = value
        }
    }

    private final class LegacyFailureBox: Sendable {
        let code: Int

        init(code: Int) {
            self.code = code
        }
    }

    private enum LegacyFailure: Error {
        case disconnected(LegacyFailureBox)
    }

    private enum ExpectedFailure: Error, Equatable, Sendable {
        case disconnected
        case duplicate
    }

    @Test("onTermination triggers cleanup exactly once when consumer stops early")
    func onTerminationTriggersCleanupExactlyOnceWhenConsumerStopsEarly() async {
        let cancelCount = Mutex(0)

        let stream = StreamBridgeRuntime.makeStream(
            register: { onEvent, _ in
                onEvent(7)
                return 1
            },
            cancel: { _ in
                cancelCount.mutate { value in
                    value += 1
                }
            }
        )

        let task = Task<Int?, Never> {
            var iterator = stream.makeAsyncIterator()
            let first = await iterator.next()
            _ = await iterator.next()
            return first
        }

        for _ in 0..<10 {
            await Task.yield()
        }
        task.cancel()
        let received = await task.value

        #expect(cancelCount.value == 1)
        #expect(received == 7)
    }

    @Test("Cancels token when completion arrives before token installation")
    func cancelsTokenWhenCompletionArrivesBeforeTokenInstallation() async {
        let cancelCount = Mutex(0)

        let stream: AsyncStream<Int> = StreamBridgeRuntime.makeStream(
            register: { _, onCompletion in
                onCompletion()
                return 9
            },
            cancel: { _ in
                cancelCount.mutate { value in
                    value += 1
                }
            }
        )

        for await _ in stream {}

        #expect(cancelCount.value == 1)
    }

    @Test("Finish is idempotent for throwing stream callbacks")
    func finishIsIdempotentForThrowingStreamCallbacks() async {
        let cancelCount = Mutex(0)
        let stream: AsyncThrowingStream<Int, any Error> = StreamBridgeRuntime.makeThrowingStream(
            register: { _, onFailure, onCompletion in
                onFailure(ExpectedFailure.disconnected)
                onCompletion()
                onFailure(ExpectedFailure.duplicate)
                return 42
            },
            cancel: { _ in
                cancelCount.mutate { value in
                    value += 1
                }
            }
        )

        var capturedFailure: ExpectedFailure?
        do {
            for try await _ in stream {}
            Issue.record("Expected stream failure")
        } catch let failure as ExpectedFailure {
            capturedFailure = failure
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        #expect(capturedFailure == .disconnected)
        #expect(cancelCount.value == 1)
    }

    @Test("Surfaces failure as erased error from makeThrowingStream")
    func surfacesFailureAsErasedErrorFromMakeThrowingStream() async {
        let stream: AsyncThrowingStream<Int, any Error> = StreamBridgeRuntime.makeThrowingStream(
            register: { _, onFailure, _ in
                onFailure(ExpectedFailure.disconnected)
                return 5
            }
        )

        var capturedFailure: ExpectedFailure?
        do {
            for try await _ in stream {}
            Issue.record("Expected stream failure")
        } catch let failure as ExpectedFailure {
            capturedFailure = failure
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        #expect(capturedFailure == .disconnected)
    }

    @Test("Unchecked stream bridge supports non-Sendable events")
    func uncheckedStreamBridgeSupportsNonSendableEvents() async {
        let stream = StreamBridgeRuntime.makeStreamUnchecked(
            register: { onEvent, _ in
                onEvent(LegacyEvent(value: 9))
                return 1
            }
        )

        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.value == 9)
    }

    @Test("Unchecked throwing bridge supports boxed failure payloads")
    func uncheckedThrowingBridgeSupportsBoxedFailurePayloads() async {
        let stream: AsyncThrowingStream<Int, any Error> = StreamBridgeRuntime.makeThrowingStreamUnchecked(
            register: { _, onFailure, _ in
                onFailure(LegacyFailure.disconnected(LegacyFailureBox(code: 404)))
                return 1
            }
        )

        var observedCode: Int?
        do {
            for try await _ in stream {}
            Issue.record("Expected stream failure")
        } catch let failure as LegacyFailure {
            if case .disconnected(let payload) = failure {
                observedCode = payload.code
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        #expect(observedCode == 404)
    }
}
