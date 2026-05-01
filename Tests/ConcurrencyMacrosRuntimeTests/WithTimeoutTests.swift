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

    fileprivate enum ClockSleepError: Error, Equatable {
        case failed
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

    private actor CancellationProbe {
        private var didCancel = false

        func markCancelled() {
            didCancel = true
        }

        func cancelled() -> Bool {
            didCancel
        }
    }

    @Test("Returns value when operation completes before timeout")
    func returnsValueBeforeTimeout() async throws {
        let value = try await ConcurrencyRuntime.withTimeout(.seconds(1)) {
            42
        }

        #expect(value == 42)
    }

    @Test("Returns value when operation completes before absolute deadline")
    func returnsValueBeforeAbsoluteDeadline() async throws {
        let clock = ContinuousClock()
        let value = try await ConcurrencyRuntime.withTimeout(
            until: clock.now.advanced(by: .seconds(1)),
            tolerance: .milliseconds(5)
        ) {
            42
        }

        #expect(value == 42)
    }

    @Test("Returns value when operation completes before custom-clock deadline")
    func returnsValueBeforeCustomClockDeadline() async throws {
        let clock = TestClock()
        let value = try await ConcurrencyRuntime.withTimeout(
            until: clock.now.advanced(by: .seconds(1)),
            clock: clock
        ) {
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

        Self.expectTimedOut(capturedError, after: timeout)
    }

    @Test("Throws timeout error when absolute deadline elapses first")
    func throwsTimeoutErrorWhenAbsoluteDeadlineElapsesFirst() async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(50))
        var capturedError: ConcurrencyRuntime.TimeoutError?

        do {
            _ = try await ConcurrencyRuntime.withTimeout(until: deadline) {
                try await Task.sleep(for: .seconds(1))
                return 1
            }
        } catch let error as ConcurrencyRuntime.TimeoutError {
            capturedError = error
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        Self.expectDeadlineExceeded(capturedError, until: deadline)
    }

    @Test("TimeoutError supports stable equality")
    func timeoutErrorSupportsStableEquality() {
        let clock = TestClock()
        let deadline = clock.now.advanced(by: .seconds(1))

        #expect(
            ConcurrencyRuntime.TimeoutError.timedOut(after: .seconds(1))
                == ConcurrencyRuntime.TimeoutError.timedOut(after: .seconds(1))
        )
        #expect(
            ConcurrencyRuntime.TimeoutError.timedOut(after: .seconds(1))
                != ConcurrencyRuntime.TimeoutError.timedOut(after: .seconds(2))
        )
        #expect(
            ConcurrencyRuntime.TimeoutError.deadlineExceeded(until: deadline)
                == ConcurrencyRuntime.TimeoutError.deadlineExceeded(until: deadline)
        )
        #expect(
            ConcurrencyRuntime.TimeoutError.deadlineExceeded(until: deadline)
                != ConcurrencyRuntime.TimeoutError.deadlineExceeded(until: deadline.advanced(by: .seconds(1)))
        )
    }

    @Test("Returns promptly when timed-out operation ignores cancellation")
    func returnsPromptlyWhenTimedOutOperationIgnoresCancellation() async {
        let timeout = Duration.milliseconds(50)
        let operationDuration = Duration.milliseconds(500)
        let allowedElapsed = Duration.milliseconds(250)
        let clock = ContinuousClock()
        let start = clock.now
        var capturedError: ConcurrencyRuntime.TimeoutError?

        do {
            _ = try await ConcurrencyRuntime.withTimeout(timeout) {
                await Self.sleepIgnoringCancellation(for: operationDuration)
                return 1
            }
            Issue.record("Expected timeout error")
        } catch let error as ConcurrencyRuntime.TimeoutError {
            capturedError = error
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        let elapsed = start.duration(to: clock.now)
        Self.expectTimedOut(capturedError, after: timeout)
        #expect(
            elapsed < allowedElapsed,
            "Expected timeout to return before \(allowedElapsed), elapsed: \(elapsed)"
        )
    }

    @Test("Returns promptly when absolute-deadline operation ignores cancellation")
    func returnsPromptlyWhenAbsoluteDeadlineOperationIgnoresCancellation() async {
        let operationDuration = Duration.milliseconds(500)
        let allowedElapsed = Duration.milliseconds(250)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(50))
        let start = clock.now
        var capturedError: ConcurrencyRuntime.TimeoutError?

        do {
            _ = try await ConcurrencyRuntime.withTimeout(until: deadline) {
                await Self.sleepIgnoringCancellation(for: operationDuration)
                return 1
            }
            Issue.record("Expected timeout error")
        } catch let error as ConcurrencyRuntime.TimeoutError {
            capturedError = error
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        let elapsed = start.duration(to: clock.now)
        Self.expectDeadlineExceeded(capturedError, until: deadline)
        #expect(
            elapsed < allowedElapsed,
            "Expected deadline timeout to return before \(allowedElapsed), elapsed: \(elapsed)"
        )
    }

    @Test("Returns promptly when custom-clock deadline elapses")
    func returnsPromptlyWhenCustomClockDeadlineElapses() async {
        let clock = TestClock()
        let deadline = clock.now.advanced(by: .milliseconds(50))
        var capturedError: ConcurrencyRuntime.TimeoutError?

        let task = Task {
            try await ConcurrencyRuntime.withTimeout(until: deadline, clock: clock) {
                await Self.sleepIgnoringCancellation(for: .milliseconds(500))
                return 1
            }
        }

        await SingleFlightRuntimeTestSupport.waitUntil {
            clock.pendingSleepers > 0
        }

        let start = ContinuousClock().now
        clock.advance(by: .milliseconds(50))

        do {
            _ = try await task.value
            Issue.record("Expected timeout error")
        } catch let error as ConcurrencyRuntime.TimeoutError {
            capturedError = error
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        let elapsed = start.duration(to: ContinuousClock().now)
        Self.expectDeadlineExceeded(capturedError, until: deadline)
        #expect(
            elapsed < .milliseconds(250),
            "Expected custom-clock timeout to return promptly, elapsed: \(elapsed)"
        )
    }

    @Test("Returns promptly when custom-clock duration elapses")
    func returnsPromptlyWhenCustomClockDurationElapses() async {
        let clock = TestClock()
        let timeout = Duration.milliseconds(50)
        var capturedError: ConcurrencyRuntime.TimeoutError?

        let task = Task {
            try await ConcurrencyRuntime.withTimeout(timeout, clock: clock) {
                await Self.sleepIgnoringCancellation(for: .milliseconds(500))
                return 1
            }
        }

        await SingleFlightRuntimeTestSupport.waitUntil {
            clock.pendingSleepers > 0
        }

        let start = ContinuousClock().now
        clock.advance(by: timeout)

        do {
            _ = try await task.value
            Issue.record("Expected timeout error")
        } catch let error as ConcurrencyRuntime.TimeoutError {
            capturedError = error
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        let elapsed = start.duration(to: ContinuousClock().now)
        Self.expectTimedOut(capturedError, after: timeout)
        #expect(
            elapsed < .milliseconds(250),
            "Expected custom-clock duration timeout to return promptly, elapsed: \(elapsed)"
        )
    }

    @Test("Reports timeout when operation throws after timeout cancellation")
    func reportsTimeoutWhenOperationThrowsAfterTimeoutCancellation() async {
        let clock = TestClock()
        let timeout = Duration.milliseconds(50)
        var capturedTimeout: ConcurrencyRuntime.TimeoutError?

        let task = Task {
            try await ConcurrencyRuntime.withTimeout(timeout, clock: clock) {
                do {
                    try await clock.sleep(until: clock.now.advanced(by: .seconds(1)))
                } catch {
                    throw ExpectedError.failed
                }

                return 1
            }
        }

        await SingleFlightRuntimeTestSupport.waitUntil {
            clock.pendingSleepers == 2
        }
        clock.advance(by: timeout)

        do {
            _ = try await task.value
            Issue.record("Expected timeout error")
        } catch let error as ConcurrencyRuntime.TimeoutError {
            capturedTimeout = error
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        Self.expectTimedOut(capturedTimeout, after: timeout)
    }

    @Test("Propagates unexpected custom-clock sleep failures")
    func propagatesUnexpectedCustomClockSleepFailures() async {
        let clock = FailingClock()
        let start = ContinuousClock().now
        var capturedError: ClockSleepError?

        do {
            _ = try await ConcurrencyRuntime.withTimeout(.seconds(1), clock: clock) {
                await Self.sleepIgnoringCancellation(for: .milliseconds(500))
                return 1
            }
            Issue.record("Expected custom clock sleep error")
        } catch let error as ClockSleepError {
            capturedError = error
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        let elapsed = start.duration(to: ContinuousClock().now)
        #expect(capturedError == .failed)
        #expect(
            elapsed < .milliseconds(250),
            "Expected custom-clock sleep failure to return promptly, elapsed: \(elapsed)"
        )
    }

    @Test("Cancels operation when timeout elapses")
    func cancelsOperationWhenTimeoutElapses() async {
        let probe = CancellationProbe()

        do {
            _ = try await ConcurrencyRuntime.withTimeout(.milliseconds(50)) {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch is CancellationError {
                    await probe.markCancelled()
                    throw CancellationError()
                }

                return 1
            }
            Issue.record("Expected timeout error")
        } catch is ConcurrencyRuntime.TimeoutError {
            // Expected.
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        await SingleFlightRuntimeTestSupport.waitUntil {
            await probe.cancelled()
        }

        #expect(await probe.cancelled())
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

        Self.expectTimedOut(capturedError, after: .zero)
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

        Self.expectTimedOut(capturedError, after: negativeDuration)
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

private extension WithTimeoutTests {
    static func expectTimedOut(
        _ error: ConcurrencyRuntime.TimeoutError?,
        after expectedDuration: Duration
    ) {
        guard case .timedOut(let duration) = error else {
            Issue.record("Expected timedOut error, got \(String(describing: error))")
            return
        }

        #expect(duration == expectedDuration)
    }

    static func expectDeadlineExceeded<I: InstantProtocol>(
        _ error: ConcurrencyRuntime.TimeoutError?,
        until expectedDeadline: I
    ) {
        guard case .deadlineExceeded(let deadline) = error else {
            Issue.record("Expected deadlineExceeded error, got \(String(describing: error))")
            return
        }

        guard let typedDeadline = deadline as? I else {
            Issue.record("Expected deadline type \(I.self), got \(type(of: deadline))")
            return
        }

        #expect(typedDeadline == expectedDeadline)
    }

    static func sleepIgnoringCancellation(for duration: Duration) async {
        await withCheckedContinuation { continuation in
            Task.detached {
                try? await Task.sleep(for: duration)
                continuation.resume()
            }
        }
    }
}

private final class TestClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol, Sendable {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    private struct Sleeper: Sendable {
        var deadline: Instant
        var continuation: CheckedContinuation<Void, any Error>
    }

    private struct State: Sendable {
        var now = Instant(offset: .zero)
        var nextID = 0
        var sleepers: [Int: Sleeper] = [:]
    }

    private let state = Mutex(State())

    var now: Instant {
        state.value.now
    }

    var minimumResolution: Duration {
        .zero
    }

    var pendingSleepers: Int {
        state.value.sleepers.count
    }

    func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        if deadline <= now {
            try Task.checkCancellation()
            return
        }

        let sleeperID = state.mutate { state in
            defer { state.nextID += 1 }
            return state.nextID
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let shouldResume = state.mutate { state in
                    guard deadline > state.now else {
                        return true
                    }

                    state.sleepers[sleeperID] = Sleeper(
                        deadline: deadline,
                        continuation: continuation
                    )
                    return false
                }

                if shouldResume {
                    continuation.resume()
                }
            }
        } onCancel: {
            let sleeper = state.mutate { state in
                state.sleepers.removeValue(forKey: sleeperID)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let continuations = state.mutate { state in
            state.now = state.now.advanced(by: duration)
            let expiredIDs = state.sleepers
                .filter { _, sleeper in sleeper.deadline <= state.now }
                .map(\.key)
            return expiredIDs.compactMap { id in
                state.sleepers.removeValue(forKey: id)?.continuation
            }
        }

        for continuation in continuations {
            continuation.resume()
        }
    }
}

private struct FailingClock: Clock, Sendable {
    struct Instant: InstantProtocol, Sendable {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    var now: Instant {
        Instant(offset: .zero)
    }

    var minimumResolution: Duration {
        .zero
    }

    func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        throw WithTimeoutTests.ClockSleepError.failed
    }
}
