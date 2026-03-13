//
//  ConcurrencyRuntimeTests.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 11.03.26.
//

import Testing
@testable import ConcurrencyMacrosRuntime

@Suite("ConcurrencyRuntime")
struct ConcurrencyRuntimeTests {
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

    private actor InFlightTracker {
        private var inFlight = 0
        private var maxInFlight = 0

        func run<Value: Sendable>(
            _ operation: @Sendable () async -> Value
        ) async -> Value {
            inFlight += 1
            maxInFlight = max(maxInFlight, inFlight)
            defer { inFlight -= 1 }
            return await operation()
        }

        func run<Value: Sendable>(
            _ operation: @Sendable () async throws -> Value
        ) async rethrows -> Value {
            inFlight += 1
            maxInFlight = max(maxInFlight, inFlight)
            defer { inFlight -= 1 }
            return try await operation()
        }

        func maxObserved() -> Int {
            maxInFlight
        }
    }

    private actor StartedElements {
        private var values: [Int] = []

        func append(_ value: Int) {
            values.append(value)
        }

        func allValues() -> [Int] {
            values
        }
    }

    private actor Counter {
        private var value = 0

        func increment() {
            value += 1
        }

        func currentValue() -> Int {
            value
        }
    }

    private actor AttemptCounter {
        private var attempts = 0

        func nextAttempt() -> Int {
            defer { attempts += 1 }
            return attempts
        }

        func count() -> Int {
            attempts
        }
    }

    private actor SleepRecorder {
        private var delays: [Duration] = []

        func record(_ delay: Duration) {
            delays.append(delay)
        }

        func allDelays() -> [Duration] {
            delays
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

    @Test("retrying returns value when operation succeeds on first attempt")
    func retryingReturnsValueOnFirstAttempt() async throws {
        let value = try await ConcurrencyRuntime.retrying(
            max: 3,
            backoff: .constant(.milliseconds(10)),
            jitter: .none
        ) {
            42
        }

        #expect(value == 42)
    }

    @Test("retrying retries then succeeds and records expected attempts")
    func retryingRetriesThenSucceedsAndRecordsExpectedAttempts() async throws {
        let attempts = AttemptCounter()
        let recorder = SleepRecorder()
        let dependencies = ConcurrencyRuntime.RetryingDependencies(
            randomUnitInterval: { 1.0 },
            sleep: { delay in
                await recorder.record(delay)
            }
        )

        let value = try await ConcurrencyRuntime.retrying(
            max: 3,
            backoff: .constant(.milliseconds(20)),
            jitter: .none,
            dependencies: dependencies
        ) {
            let attempt = await attempts.nextAttempt()
            guard attempt >= 2 else { throw ExpectedError.failed }
            return 7
        }

        #expect(value == 7)
        #expect(await attempts.count() == 3)
        #expect(await recorder.allDelays() == [.milliseconds(20), .milliseconds(20)])
    }

    @Test("retrying rethrows the last operation error when retries are exhausted")
    func retryingRethrowsLastOperationErrorWhenRetriesAreExhausted() async {
        let attempts = AttemptCounter()
        var capturedError: ExpectedError?

        do {
            _ = try await ConcurrencyRuntime.retrying(
                max: 2,
                backoff: .none,
                jitter: .none
            ) {
                let attempt = await attempts.nextAttempt()
                if attempt == 2 {
                    throw ExpectedError.exhausted
                }
                throw ExpectedError.failed
            }
            Issue.record("Expected retrying to throw")
        } catch let error as ExpectedError {
            capturedError = error
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        #expect(capturedError == .exhausted)
        #expect(await attempts.count() == 3)
    }

    @Test("retrying with max zero executes once without retries")
    func retryingWithMaxZeroExecutesOnceWithoutRetries() async {
        let attempts = AttemptCounter()
        var capturedError: ExpectedError?

        do {
            _ = try await ConcurrencyRuntime.retrying(
                max: 0,
                backoff: .none,
                jitter: .none
            ) {
                _ = await attempts.nextAttempt()
                throw ExpectedError.failed
            }
            Issue.record("Expected retrying to throw")
        } catch let error as ExpectedError {
            capturedError = error
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        #expect(capturedError == .failed)
        #expect(await attempts.count() == 1)
    }

    @Test("retrying preserves cancellation and does not retry cancellation errors")
    func retryingPreservesCancellationAndDoesNotRetryCancellationErrors() async {
        let attempts = AttemptCounter()

        do {
            _ = try await ConcurrencyRuntime.retrying(
                max: 5,
                backoff: .constant(.milliseconds(10)),
                jitter: .none
            ) {
                _ = await attempts.nextAttempt()
                throw CancellationError()
            }
            Issue.record("Expected cancellation error")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        #expect(await attempts.count() == 1)
    }

    @Test("retrying preserves external cancellation even when backoff delay is zero")
    func retryingPreservesExternalCancellationWhenBackoffDelayIsZero() async {
        let attempts = AttemptCounter()
        let task = Task {
            try await ConcurrencyRuntime.retrying(
                max: 1_000,
                backoff: .none,
                jitter: .none
            ) {
                _ = await attempts.nextAttempt()
                throw ExpectedError.failed
            }
        }

        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation error")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("retrying throws configuration error for negative max retries")
    func retryingThrowsConfigurationErrorForNegativeMaxRetries() async {
        var capturedError: ConcurrencyRuntime.RetryConfigurationError?

        do {
            _ = try await ConcurrencyRuntime.retrying(
                max: -1,
                backoff: .none,
                jitter: .none
            ) {
                1
            }
            Issue.record("Expected retry configuration error")
        } catch let error as ConcurrencyRuntime.RetryConfigurationError {
            capturedError = error
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        #expect(capturedError == .negativeMaxRetries(-1))
    }

    @Test("retrying throws configuration error for non-positive constant delay")
    func retryingThrowsConfigurationErrorForNonPositiveConstantDelay() async {
        var capturedError: ConcurrencyRuntime.RetryConfigurationError?

        do {
            _ = try await ConcurrencyRuntime.retrying(
                max: 1,
                backoff: .constant(.zero),
                jitter: .none
            ) {
                1
            }
            Issue.record("Expected retry configuration error")
        } catch let error as ConcurrencyRuntime.RetryConfigurationError {
            capturedError = error
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        #expect(capturedError == .nonPositiveConstantDelay(.zero))
    }

    @Test("retrying throws configuration error for non-positive exponential initial delay")
    func retryingThrowsConfigurationErrorForNonPositiveExponentialInitialDelay() async {
        var capturedError: ConcurrencyRuntime.RetryConfigurationError?

        do {
            _ = try await ConcurrencyRuntime.retrying(
                max: 1,
                backoff: .exponential(initial: .zero),
                jitter: .none
            ) {
                1
            }
            Issue.record("Expected retry configuration error")
        } catch let error as ConcurrencyRuntime.RetryConfigurationError {
            capturedError = error
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        #expect(capturedError == .nonPositiveInitialDelay(.zero))
    }

    @Test("retrying throws configuration error for invalid exponential multiplier")
    func retryingThrowsConfigurationErrorForInvalidExponentialMultiplier() async {
        var capturedError: ConcurrencyRuntime.RetryConfigurationError?

        do {
            _ = try await ConcurrencyRuntime.retrying(
                max: 1,
                backoff: .exponential(initial: .milliseconds(10), multiplier: .infinity),
                jitter: .none
            ) {
                1
            }
            Issue.record("Expected retry configuration error")
        } catch let error as ConcurrencyRuntime.RetryConfigurationError {
            capturedError = error
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        #expect(capturedError == .invalidMultiplier(.infinity))
    }

    @Test("retrying throws configuration error for multiplier equal to one")
    func retryingThrowsConfigurationErrorForMultiplierEqualToOne() async {
        var capturedError: ConcurrencyRuntime.RetryConfigurationError?

        do {
            _ = try await ConcurrencyRuntime.retrying(
                max: 1,
                backoff: .exponential(initial: .milliseconds(10), multiplier: 1),
                jitter: .none
            ) {
                1
            }
            Issue.record("Expected retry configuration error")
        } catch let error as ConcurrencyRuntime.RetryConfigurationError {
            capturedError = error
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        #expect(capturedError == .invalidMultiplier(1))
    }

    @Test("retrying throws configuration error for multiplier less than one")
    func retryingThrowsConfigurationErrorForMultiplierLessThanOne() async {
        var capturedError: ConcurrencyRuntime.RetryConfigurationError?

        do {
            _ = try await ConcurrencyRuntime.retrying(
                max: 1,
                backoff: .exponential(initial: .milliseconds(10), multiplier: 0.5),
                jitter: .none
            ) {
                1
            }
            Issue.record("Expected retry configuration error")
        } catch let error as ConcurrencyRuntime.RetryConfigurationError {
            capturedError = error
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        #expect(capturedError == .invalidMultiplier(0.5))
    }

    @Test("retrying throws configuration error for non-positive exponential max delay")
    func retryingThrowsConfigurationErrorForNonPositiveExponentialMaxDelay() async {
        var capturedError: ConcurrencyRuntime.RetryConfigurationError?

        do {
            _ = try await ConcurrencyRuntime.retrying(
                max: 1,
                backoff: .exponential(initial: .milliseconds(10), maxDelay: .zero),
                jitter: .none
            ) {
                1
            }
            Issue.record("Expected retry configuration error")
        } catch let error as ConcurrencyRuntime.RetryConfigurationError {
            capturedError = error
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        #expect(capturedError == .nonPositiveMaxDelay(.zero))
    }

    @Test("retrying throws configuration error when exponential max delay is less than initial")
    func retryingThrowsConfigurationErrorWhenExponentialMaxDelayIsLessThanInitial() async {
        let initial = Duration.milliseconds(50)
        let maxDelay = Duration.milliseconds(20)
        var capturedError: ConcurrencyRuntime.RetryConfigurationError?

        do {
            _ = try await ConcurrencyRuntime.retrying(
                max: 1,
                backoff: .exponential(initial: initial, maxDelay: maxDelay),
                jitter: .none
            ) {
                1
            }
            Issue.record("Expected retry configuration error")
        } catch let error as ConcurrencyRuntime.RetryConfigurationError {
            capturedError = error
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        #expect(capturedError == .maxDelayLessThanInitial(initial: initial, maxDelay: maxDelay))
    }

    @Test("retrying throws configuration error when exponential delay growth overflows")
    func retryingThrowsConfigurationErrorWhenExponentialDelayGrowthOverflows() async {
        let hugeInitial = Duration.seconds(Double(Int64.max) / 2)
        var capturedError: ConcurrencyRuntime.RetryConfigurationError?

        do {
            _ = try await ConcurrencyRuntime.retrying(
                max: 2,
                backoff: .exponential(initial: hugeInitial, multiplier: 2),
                jitter: .none,
                dependencies: .init(
                    randomUnitInterval: { 1 },
                    sleep: { _ in }
                )
            ) {
                throw ExpectedError.failed
            }
            Issue.record("Expected retry configuration error")
        } catch let error as ConcurrencyRuntime.RetryConfigurationError {
            capturedError = error
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        #expect(
            capturedError
                == .exponentialDelayOverflow(initial: hugeInitial, multiplier: 2, retry: 2)
        )
    }

    @Test("retrying handles near-boundary exponential scaling without overflow")
    func retryingHandlesNearBoundaryExponentialScalingWithoutOverflow() async throws {
        let nearLimitInitial = Duration.seconds(Double(Int64.max).nextDown / 2.1)
        let recorder = SleepRecorder()
        let dependencies = ConcurrencyRuntime.RetryingDependencies(
            randomUnitInterval: { 1.0 },
            sleep: { delay in
                await recorder.record(delay)
            }
        )
        let attempts = AttemptCounter()

        _ = try await ConcurrencyRuntime.retrying(
            max: 2,
            backoff: .exponential(initial: nearLimitInitial, multiplier: 2),
            jitter: .none,
            dependencies: dependencies
        ) {
            let attempt = await attempts.nextAttempt()
            guard attempt >= 2 else { throw ExpectedError.failed }
            return 1
        }

        let delays = await recorder.allDelays()
        #expect(delays.count == 2)
        let firstDelay = try #require(delays.first)
        let lastDelay = try #require(delays.last)
        #expect(firstDelay == nearLimitInitial)
        #expect(lastDelay > firstDelay)
    }

    @Test("retrying with no jitter keeps base delay values")
    func retryingWithNoJitterKeepsBaseDelayValues() async throws {
        let recorder = SleepRecorder()
        let dependencies = ConcurrencyRuntime.RetryingDependencies(
            randomUnitInterval: { 0.1 },
            sleep: { delay in
                await recorder.record(delay)
            }
        )
        let attempts = AttemptCounter()

        _ = try await ConcurrencyRuntime.retrying(
            max: 1,
            backoff: .constant(.milliseconds(120)),
            jitter: .none,
            dependencies: dependencies
        ) {
            let attempt = await attempts.nextAttempt()
            guard attempt > 0 else { throw ExpectedError.failed }
            return 1
        }

        #expect(await recorder.allDelays() == [.milliseconds(120)])
    }

    @Test("retrying with full jitter uses delay within zero and base delay range")
    func retryingWithFullJitterUsesDelayWithinZeroAndBaseDelayRange() async throws {
        let recorder = SleepRecorder()
        let dependencies = ConcurrencyRuntime.RetryingDependencies(
            randomUnitInterval: { 0.25 },
            sleep: { delay in
                await recorder.record(delay)
            }
        )
        let attempts = AttemptCounter()
        let baseDelay = Duration.milliseconds(200)

        _ = try await ConcurrencyRuntime.retrying(
            max: 1,
            backoff: .constant(baseDelay),
            jitter: .full,
            dependencies: dependencies
        ) {
            let attempt = await attempts.nextAttempt()
            guard attempt > 0 else { throw ExpectedError.failed }
            return 1
        }

        let delays = await recorder.allDelays()
        let jitteredDelay = try #require(delays.first)
        #expect(jitteredDelay >= .zero)
        #expect(jitteredDelay <= baseDelay)
        #expect(jitteredDelay == .milliseconds(50))
    }

    @Test("concurrentMap supports non-throwing transform without try")
    func concurrentMapSupportsNonThrowingTransformWithoutTry() async {
        let doubled = await ConcurrencyRuntime.concurrentMap([1, 2, 3], limit: 2) { value in
            value * 2
        }

        #expect(doubled == [2, 4, 6])
    }

    @Test("concurrentMap preserves source order for throwing transforms")
    func concurrentMapPreservesSourceOrderForThrowingTransforms() async throws {
        let values = Array(0..<8)
        let mapped = try await ConcurrencyRuntime.concurrentMap(values, limit: 3) { value in
            try await Task.sleep(for: .milliseconds(Int64(values.count - value) * 5))
            return value * 10
        }

        #expect(mapped == values.map { $0 * 10 })
    }

    @Test("concurrentCompactMap drops nil values and preserves source order")
    func concurrentCompactMapDropsNilValuesAndPreservesSourceOrder() async throws {
        let values = Array(0..<8)
        let compacted = try await ConcurrencyRuntime.concurrentCompactMap(values, limit: 3) { value in
            try await Task.sleep(for: .milliseconds(Int64(values.count - value) * 4))
            return value.isMultiple(of: 2) ? value : nil
        }

        #expect(compacted == [0, 2, 4, 6])
    }

    @Test("concurrentFlatMap supports sequence outputs and preserves source order")
    func concurrentFlatMapSupportsSequenceOutputsAndPreservesSourceOrder() async throws {
        let values = Array(0..<4)
        let flattened = try await ConcurrencyRuntime.concurrentFlatMap(values, limit: 2) { value in
            try await Task.sleep(for: .milliseconds(Int64(values.count - value) * 3))
            return value..<(value + 2)
        }

        #expect(flattened == [0, 1, 1, 2, 2, 3, 3, 4])
    }

    @Test("concurrentForEach executes operation for each element")
    func concurrentForEachExecutesOperationForEachElement() async {
        let counter = Counter()

        await ConcurrencyRuntime.concurrentForEach(Array(0..<20), limit: 4) { _ in
            await counter.increment()
        }

        #expect(await counter.currentValue() == 20)
    }

    @Test("concurrentMap respects explicit in-flight limit")
    func concurrentMapRespectsExplicitInflightLimit() async throws {
        let tracker = InFlightTracker()

        _ = try await ConcurrencyRuntime.concurrentMap(Array(0..<18), limit: 3) { value in
            try await tracker.run {
                try await Task.sleep(for: .milliseconds(15))
                return value
            }
        }

        #expect(await tracker.maxObserved() <= 3)
    }

    @Test("concurrentForEach respects explicit in-flight limit")
    func concurrentForEachRespectsExplicitInflightLimit() async throws {
        let tracker = InFlightTracker()

        try await ConcurrencyRuntime.concurrentForEach(Array(0..<18), limit: 2) { value in
            _ = try await tracker.run {
                try await Task.sleep(for: .milliseconds(15))
                return value
            }
        }

        #expect(await tracker.maxObserved() <= 2)
    }

    @Test("concurrentMap clamps zero limit to one")
    func concurrentMapClampsZeroLimitToOne() async {
        let tracker = InFlightTracker()

        _ = await ConcurrencyRuntime.concurrentMap(Array(0..<12), limit: .fixed(0)) { value in
            await tracker.run {
                try? await Task.sleep(for: .milliseconds(10))
                return value
            }
        }

        #expect(await tracker.maxObserved() == 1)
    }

    @Test("concurrentMap clamps negative limit to one")
    func concurrentMapClampsNegativeLimitToOne() async {
        let tracker = InFlightTracker()

        _ = await ConcurrencyRuntime.concurrentMap(Array(0..<12), limit: .fixed(-8)) { value in
            await tracker.run {
                try? await Task.sleep(for: .milliseconds(10))
                return value
            }
        }

        #expect(await tracker.maxObserved() == 1)
    }

    @Test("concurrentMap fails fast and cancels remaining work on first error")
    func concurrentMapFailsFastAndCancelsRemainingWorkOnFirstError() async {
        let started = StartedElements()
        let values = Array(0..<20)
        var capturedError: ExpectedError?

        do {
            _ = try await ConcurrencyRuntime.concurrentMap(values, limit: 3) { value in
                await started.append(value)

                if value == 2 {
                    throw ExpectedError.failed
                }

                try await Task.sleep(for: .seconds(1))
                return value
            }
            Issue.record("Expected error to be thrown")
        } catch let error as ExpectedError {
            capturedError = error
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        #expect(capturedError == .failed)
        #expect(await started.allValues().count < values.count)
    }

    @Test("concurrentForEach fails fast and cancels remaining work on first error")
    func concurrentForEachFailsFastAndCancelsRemainingWorkOnFirstError() async {
        let started = StartedElements()
        let values = Array(0..<20)
        var capturedError: ExpectedError?

        do {
            try await ConcurrencyRuntime.concurrentForEach(values, limit: 3) { value in
                await started.append(value)

                if value == 2 {
                    throw ExpectedError.failed
                }

                try await Task.sleep(for: .seconds(1))
            }
            Issue.record("Expected error to be thrown")
        } catch let error as ExpectedError {
            capturedError = error
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        #expect(capturedError == .failed)
        #expect(await started.allValues().count < values.count)
    }
}
