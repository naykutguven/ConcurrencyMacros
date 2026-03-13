//
//  WithTimeoutTests.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 11.03.26.
//

import Testing
@testable import ConcurrencyMacrosRuntime

@Suite("WithTimeout")
struct WithTimeoutTests {
    private enum ExpectedError: Error, Equatable {
        case failed
        case exhausted
    }

    private actor ExecutionFlag {
        var didRun = false

        func markRan() {
            didRun = true
        }

        func value() -> Bool {
            didRun
        }
    }

    @Test("Returns value when operation completes before timeout")
    func returnsValueBeforeTimeout() async throws {
        let value = try await ConcurrencyRuntime.withTimeout(.seconds(1)) {
            42
        }

        #expect(value == 42)
    }

    @Test("Propagates operation-thrown errors")
    func propagatesOperationErrors() async {
        var capturedError: ExpectedError?

        do {
            _ = try await ConcurrencyRuntime.withTimeout(.seconds(1)) {
                throw ExpectedError.failed
            }
        } catch let error as ExpectedError {
            capturedError = error
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        #expect(capturedError == .failed)
    }

    @Test("Throws timeout error when duration elapses first")
    func throwsTimeoutErrorWhenDurationElapsesFirst() async {
        let timeout = Duration.milliseconds(50)
        var capturedError: ConcurrencyRuntime.TimeoutError?

        do {
            _ = try await ConcurrencyRuntime.withTimeout(timeout) {
                try await Task.sleep(for: .seconds(1))
                return 1
            }
        } catch let error as ConcurrencyRuntime.TimeoutError {
            capturedError = error
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        #expect(capturedError == .timedOut(after: timeout))
    }

    @Test("Throws immediately for non-positive durations and does not execute operation")
    func throwsImmediatelyForNonPositiveDuration() async {
        let executionFlag = ExecutionFlag()
        var capturedError: ConcurrencyRuntime.TimeoutError?

        do {
            _ = try await ConcurrencyRuntime.withTimeout(.zero) {
                await executionFlag.markRan()
                return 1
            }
            Issue.record("Expected timeout error to be thrown")
        } catch let error as ConcurrencyRuntime.TimeoutError {
            capturedError = error
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        #expect(capturedError == .timedOut(after: .zero))
        #expect(await executionFlag.value() == false)
    }

    @Test("Throws immediately for negative durations and does not execute operation")
    func throwsImmediatelyForNegativeDuration() async {
        let executionFlag = ExecutionFlag()
        let negativeDuration = Duration.milliseconds(-1)
        var capturedError: ConcurrencyRuntime.TimeoutError?

        do {
            _ = try await ConcurrencyRuntime.withTimeout(negativeDuration) {
                await executionFlag.markRan()
                return 1
            }
            Issue.record("Expected timeout error to be thrown")
        } catch let error as ConcurrencyRuntime.TimeoutError {
            capturedError = error
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        #expect(capturedError == .timedOut(after: negativeDuration))
        #expect(await executionFlag.value() == false)
    }

    @Test("Preserves external cancellation")
    func preservesExternalCancellation() async {
        let task = Task {
            try await ConcurrencyRuntime.withTimeout(.seconds(5)) {
                try await Task.sleep(for: .seconds(10))
                return 1
            }
        }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

}
