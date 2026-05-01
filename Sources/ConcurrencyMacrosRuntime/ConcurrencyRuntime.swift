//
//  ConcurrencyRuntime.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 11.03.26.
//

/// Namespace for runtime helpers used by freestanding concurrency macros.
public enum ConcurrencyRuntime {
    /// Error thrown when a timeout duration or deadline elapses before the operation completes.
    ///
    /// Equality compares elapsed timeout durations exactly. Deadline errors compare equal only when
    /// both stored deadlines have the same concrete instant type and value.
    public enum TimeoutError: Error, Sendable, Equatable {
        /// Indicates the operation did not complete before the timeout expired.
        ///
        /// - Parameter after: The timeout duration that elapsed.
        case timedOut(after: Duration)

        /// Indicates the operation did not complete before the absolute deadline expired.
        ///
        /// - Parameter until: The deadline instant that expired.
        case deadlineExceeded(until: any InstantProtocol & Sendable)

        public static func == (lhs: TimeoutError, rhs: TimeoutError) -> Bool {
            switch (lhs, rhs) {
            case let (.timedOut(lhsDuration), .timedOut(rhsDuration)):
                return lhsDuration == rhsDuration
            case let (.deadlineExceeded(lhsDeadline), .deadlineExceeded(rhsDeadline)):
                return deadlinesAreEqual(lhsDeadline, rhsDeadline)
            case (.timedOut, .deadlineExceeded), (.deadlineExceeded, .timedOut):
                return false
            }
        }

        private static func deadlinesAreEqual<I: InstantProtocol & Sendable>(
            _ lhs: I,
            _ rhs: any InstantProtocol & Sendable
        ) -> Bool {
            guard let rhs = rhs as? I else {
                return false
            }

            return lhs == rhs
        }
    }

    /// Error thrown when retry configuration is invalid.
    public enum RetryConfigurationError: Error, Sendable, Equatable {
        /// Indicates the retry count is negative.
        case negativeMaxRetries(Int)

        /// Indicates a `.constant` delay is zero or negative.
        case nonPositiveConstantDelay(Duration)

        /// Indicates an `.exponential` initial delay is zero or negative.
        case nonPositiveInitialDelay(Duration)

        /// Indicates an `.exponential` multiplier is not finite or not greater than one.
        case invalidMultiplier(Double)

        /// Indicates an `.exponential` max delay is zero or negative.
        case nonPositiveMaxDelay(Duration)

        /// Indicates an `.exponential` max delay is smaller than the initial delay.
        case maxDelayLessThanInitial(initial: Duration, maxDelay: Duration)

        /// Indicates exponential growth produced an unrepresentable delay.
        case exponentialDelayOverflow(initial: Duration, multiplier: Double, retry: Int)
    }

    /// Runtime dependencies used by retry helpers.
    ///
    /// This is internal so tests can inject deterministic sleep and random behavior.
    struct RetryingDependencies: Sendable {
        let randomUnitInterval: @Sendable () -> Double
        let sleep: @Sendable (Duration) async throws -> Void

        init(
            randomUnitInterval: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
            sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
                try await ContinuousClock().sleep(for: duration)
            }
        ) {
            self.randomUnitInterval = randomUnitInterval
            self.sleep = sleep
        }

        static let live = RetryingDependencies()
    }

    /// Retries a throwing async operation using the provided backoff and jitter strategy.
    ///
    /// - Parameters:
    ///   - max: Maximum number of retries after the initial attempt.
    ///   - backoff: Backoff strategy controlling delay between retries.
    ///   - jitter: Jitter strategy applied on top of backoff delay.
    ///   - operation: Throwing async operation to execute.
    /// - Returns: The operation result.
    /// - Throws: `RetryConfigurationError` for invalid retry configuration, operation-thrown errors,
    ///   or external cancellation.
    public static func retrying<T>(
        max: Int,
        backoff: RetryBackoff,
        jitter: RetryJitter,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        try await retrying(
            max: max,
            backoff: backoff,
            jitter: jitter,
            dependencies: .live,
            operation: operation
        )
    }

    static func retrying<T>(
        max: Int,
        backoff: RetryBackoff,
        jitter: RetryJitter,
        dependencies: RetryingDependencies,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        let configuration = try validatedRetryConfiguration(
            max: max,
            backoff: backoff,
            jitter: jitter
        )
        var exponentialState: ExponentialState?
        var retry = 0

        while true {
            do {
                return try await operation()
            } catch let cancellation as CancellationError {
                throw cancellation
            } catch {
                guard retry < configuration.maxRetries else {
                    throw error
                }

                try Task.checkCancellation()
                retry += 1

                let baseDelay = try configuration.delay(
                    beforeRetry: retry,
                    exponentialState: &exponentialState
                )
                let delayedByJitter = jitteredDelay(
                    baseDelay,
                    jitter: configuration.jitter,
                    randomUnitInterval: dependencies.randomUnitInterval
                )

                if delayedByJitter > .zero {
                    try await dependencies.sleep(delayedByJitter)
                }
            }
        }
    }

    /// Executes `operation` and fails if it does not complete before `duration` expires.
    ///
    /// - Parameters:
    ///   - duration: Maximum time allowed for the operation to complete.
    ///   - tolerance: Optional tolerance used when sleeping until the timeout deadline.
    ///   - operation: Async operation transferred into a timeout-managed task.
    /// - Returns: The operation result when it completes within `duration`.
    /// - Throws: `TimeoutError` when the timeout elapses, operation-thrown errors, or external cancellation.
    ///
    /// - Important: This helper uses cooperative cancellation. When the timeout elapses, this function can return
    /// immediately by throwing ``TimeoutError``. The operation task is cancelled but not awaited, so if the
    /// operation does not cooperate with cancellation it may continue running in the background after timeout.
    public static func withTimeout<T: Sendable>(
        _ duration: Duration,
        tolerance: Duration? = nil,
        operation: sending @escaping @isolated(any) () async throws -> T
    ) async throws -> T {
        try await withTimeout(
            duration,
            tolerance: tolerance,
            clock: ContinuousClock(),
            operation: operation
        )
    }

    /// Executes `operation` and fails if it does not complete before `duration` expires on `clock`.
    ///
    /// - Parameters:
    ///   - duration: Maximum time allowed for the operation to complete.
    ///   - tolerance: Optional tolerance used when sleeping until the timeout deadline.
    ///   - clock: Clock used to compute and sleep until the timeout deadline.
    ///   - operation: Async operation transferred into a timeout-managed task.
    /// - Returns: The operation result when it completes within `duration`.
    /// - Throws: `TimeoutError` when the timeout elapses, operation-thrown errors, or external cancellation.
    ///
    /// - Important: This helper preserves `withTimeout` fail-fast semantics: the operation task is cancelled
    /// but not awaited after timeout expiry.
    public static func withTimeout<T: Sendable, C: Clock>(
        _ duration: Duration,
        tolerance: Duration? = nil,
        clock: C,
        operation: sending @escaping @isolated(any) () async throws -> T
    ) async throws -> T where C.Instant.Duration == Duration, C.Instant: Sendable {
        guard duration > .zero else {
            throw TimeoutError.timedOut(after: duration)
        }

        return try await timeoutRace(
            until: clock.now.advanced(by: duration),
            tolerance: tolerance,
            clock: clock,
            timeoutError: .timedOut(after: duration),
            operation: operation
        )
    }

    /// Executes `operation` and fails if it does not complete before `deadline`.
    ///
    /// - Parameters:
    ///   - deadline: Absolute continuous-clock instant by which the operation must complete.
    ///   - tolerance: Optional tolerance used when sleeping until `deadline`.
    ///   - operation: Async operation transferred into a timeout-managed task.
    /// - Returns: The operation result when it completes before `deadline`.
    /// - Throws: `TimeoutError` when the deadline elapses, operation-thrown errors, or external cancellation.
    ///
    /// - Important: Unlike Swift Evolution proposal SE-0526's `withDeadline`, this helper preserves
    /// `withTimeout` fail-fast semantics: the operation task is cancelled but not awaited after deadline expiry.
    public static func withTimeout<T: Sendable>(
        until deadline: ContinuousClock.Instant,
        tolerance: Duration? = nil,
        operation: sending @escaping @isolated(any) () async throws -> T
    ) async throws -> T {
        let clock = ContinuousClock()
        guard deadline > clock.now else {
            throw TimeoutError.deadlineExceeded(until: deadline)
        }

        return try await timeoutRace(
            until: deadline,
            tolerance: tolerance,
            clock: clock,
            timeoutError: .deadlineExceeded(until: deadline),
            operation: operation
        )
    }

    /// Executes `operation` and fails if it does not complete before `deadline` on `clock`.
    ///
    /// - Parameters:
    ///   - deadline: Absolute clock instant by which the operation must complete.
    ///   - tolerance: Optional tolerance used when sleeping until `deadline`.
    ///   - clock: Clock used to interpret `deadline`.
    ///   - operation: Async operation transferred into a timeout-managed task.
    /// - Returns: The operation result when it completes before `deadline`.
    /// - Throws: `TimeoutError` when the deadline elapses, operation-thrown errors, or external cancellation.
    ///
    /// - Important: This helper preserves `withTimeout` fail-fast semantics: the operation task is cancelled
    /// but not awaited after deadline expiry.
    public static func withTimeout<T: Sendable, C: Clock>(
        until deadline: C.Instant,
        tolerance: Duration? = nil,
        clock: C,
        operation: sending @escaping @isolated(any) () async throws -> T
    ) async throws -> T where C.Instant.Duration == Duration, C.Instant: Sendable {
        guard clock.now.duration(to: deadline) > .zero else {
            throw TimeoutError.deadlineExceeded(until: deadline)
        }

        return try await timeoutRace(
            until: deadline,
            tolerance: tolerance,
            clock: clock,
            timeoutError: .deadlineExceeded(until: deadline),
            operation: operation
        )
    }

    private static func timeoutRace<T: Sendable, C: Clock>(
        until deadline: C.Instant,
        tolerance: Duration?,
        clock: C,
        timeoutError: TimeoutError,
        operation: sending @escaping @isolated(any) () async throws -> T
    ) async throws -> T where C.Instant.Duration == Duration, C.Instant: Sendable {
        // A task group would await losing children at scope exit, which breaks
        // the timeout contract for non-cancellation-cooperative operations.
        let operationTask = Task(operation: operation)

        let results = AsyncThrowingStream<T, any Error> { continuation in
            let operationWaiter = Task {
                do {
                    continuation.yield(try await operationTask.value)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            let timeoutTask = Task {
                do {
                    try await clock.sleep(until: deadline, tolerance: tolerance)
                } catch is CancellationError {
                    return
                } catch {
                    continuation.finish(throwing: error)
                    operationTask.cancel()
                    return
                }

                continuation.finish(throwing: timeoutError)
                operationTask.cancel()
            }

            continuation.onTermination = { @Sendable _ in
                operationWaiter.cancel()
                timeoutTask.cancel()
                operationTask.cancel()
            }
        }

        var iterator = results.makeAsyncIterator()
        guard let result = try await iterator.next() else {
            throw CancellationError()
        }
        return result
    }

    /// Concurrently transforms elements of a collection while preserving input order.
    ///
    /// - Parameters:
    ///   - sequence: The collection whose elements should be transformed.
    ///   - limit: Maximum number of in-flight child tasks at a time.
    ///   - transform: Async transform applied to each element.
    /// - Returns: Transformed values in the same logical order as `sequence`.
    ///
    /// - Important: Even though work executes concurrently, result ordering matches
    /// input ordering.
    public static func concurrentMap<C: Collection, Output: Sendable>(
        _ sequence: C,
        limit: ConcurrencyLimit = .default,
        transform: @escaping @Sendable (C.Element) async -> Output
    ) async -> [Output] where C.Element: Sendable {
        await orderedConcurrentTransform(sequence, limit: limit, transform: transform)
    }

    /// Concurrently transforms elements of a collection while preserving input order.
    ///
    /// - Parameters:
    ///   - sequence: The collection whose elements should be transformed.
    ///   - limit: Maximum number of in-flight child tasks at a time.
    ///   - transform: Async throwing transform applied to each element.
    /// - Returns: Transformed values in the same logical order as `sequence`.
    /// - Throws: The first error thrown by `transform`. Remaining in-flight work is cancelled.
    ///
    /// - Important: Even though work executes concurrently, result ordering matches
    /// input ordering.
    public static func concurrentMap<C: Collection, Output: Sendable>(
        _ sequence: C,
        limit: ConcurrencyLimit = .default,
        transform: @escaping @Sendable (C.Element) async throws -> Output
    ) async throws -> [Output] where C.Element: Sendable {
        try await orderedConcurrentTransform(sequence, limit: limit, transform: transform)
    }

    /// Concurrently transforms elements and drops `nil` results while preserving input order.
    ///
    /// - Parameters:
    ///   - sequence: The collection whose elements should be transformed.
    ///   - limit: Maximum number of in-flight child tasks at a time.
    ///   - transform: Async transform that may return `nil` for elements to discard.
    /// - Returns: Non-`nil` transformed values in input order after compaction.
    public static func concurrentCompactMap<C: Collection, Output: Sendable>(
        _ sequence: C,
        limit: ConcurrencyLimit = .default,
        transform: @escaping @Sendable (C.Element) async -> Output?
    ) async -> [Output] where C.Element: Sendable {
        await orderedConcurrentTransform(sequence, limit: limit, transform: transform).compactMap { $0 }
    }

    /// Concurrently transforms elements and drops `nil` results while preserving input order.
    ///
    /// - Parameters:
    ///   - sequence: The collection whose elements should be transformed.
    ///   - limit: Maximum number of in-flight child tasks at a time.
    ///   - transform: Async throwing transform that may return `nil` for elements to discard.
    /// - Returns: Non-`nil` transformed values in input order after compaction.
    /// - Throws: The first error thrown by `transform`. Remaining in-flight work is cancelled.
    public static func concurrentCompactMap<C: Collection, Output: Sendable>(
        _ sequence: C,
        limit: ConcurrencyLimit = .default,
        transform: @escaping @Sendable (C.Element) async throws -> Output?
    ) async throws -> [Output] where C.Element: Sendable {
        try await orderedConcurrentTransform(sequence, limit: limit, transform: transform).compactMap { $0 }
    }

    /// Concurrently transforms elements into child sequences and flattens the results.
    ///
    /// - Parameters:
    ///   - sequence: The collection whose elements should be transformed.
    ///   - limit: Maximum number of in-flight child tasks at a time.
    ///   - transform: Async transform returning a sequence per input element.
    /// - Returns: Flattened elements preserving outer input ordering.
    ///
    /// - Important: Child segments are flattened in input-element order. Elements within
    /// each child segment preserve that segment's own order.
    public static func concurrentFlatMap<C: Collection, Segment: Sequence & Sendable>(
        _ sequence: C,
        limit: ConcurrencyLimit = .default,
        transform: @escaping @Sendable (C.Element) async -> Segment
    ) async -> [Segment.Element] where C.Element: Sendable, Segment.Element: Sendable {
        let segments = await orderedConcurrentTransform(sequence, limit: limit) { element in
            let segment = await transform(element)
            return Array(segment)
        }
        return segments.flatMap { $0 }
    }

    /// Concurrently transforms elements into child sequences and flattens the results.
    ///
    /// - Parameters:
    ///   - sequence: The collection whose elements should be transformed.
    ///   - limit: Maximum number of in-flight child tasks at a time.
    ///   - transform: Async throwing transform returning a sequence per input element.
    /// - Returns: Flattened elements preserving outer input ordering.
    /// - Throws: The first error thrown by `transform`. Remaining in-flight work is cancelled.
    ///
    /// - Important: Child segments are flattened in input-element order. Elements within
    /// each child segment preserve that segment's own order.
    public static func concurrentFlatMap<C: Collection, Segment: Sequence & Sendable>(
        _ sequence: C,
        limit: ConcurrencyLimit = .default,
        transform: @escaping @Sendable (C.Element) async throws -> Segment
    ) async throws -> [Segment.Element] where C.Element: Sendable, Segment.Element: Sendable {
        let segments = try await orderedConcurrentTransform(sequence, limit: limit) { element in
            let segment = try await transform(element)
            return Array(segment)
        }
        return segments.flatMap { $0 }
    }

    /// Concurrently executes side-effectful work for each element in a collection.
    ///
    /// - Parameters:
    ///   - sequence: The collection whose elements should be processed.
    ///   - limit: Maximum number of in-flight child tasks at a time.
    ///   - operation: Async non-throwing operation executed per element.
    public static func concurrentForEach<C: Collection>(
        _ sequence: C,
        limit: ConcurrencyLimit = .default,
        operation: @escaping @Sendable (C.Element) async -> Void
    ) async where C.Element: Sendable {
        await executeConcurrently(sequence, limit: limit, operation: operation)
    }

    /// Concurrently executes side-effectful work for each element in a collection.
    ///
    /// - Parameters:
    ///   - sequence: The collection whose elements should be processed.
    ///   - limit: Maximum number of in-flight child tasks at a time.
    ///   - operation: Async throwing operation executed per element.
    /// - Throws: The first error thrown by `operation`. Remaining in-flight work is cancelled.
    public static func concurrentForEach<C: Collection>(
        _ sequence: C,
        limit: ConcurrencyLimit = .default,
        operation: @escaping @Sendable (C.Element) async throws -> Void
    ) async throws where C.Element: Sendable {
        try await executeConcurrently(sequence, limit: limit, operation: operation)
    }
}

// MARK: - Private Helpers

private extension ConcurrencyRuntime {
    struct RetryConfiguration: Sendable {
        let maxRetries: Int
        let backoff: NormalizedBackoff
        let jitter: RetryJitter

        func delay(
            beforeRetry retry: Int,
            exponentialState: inout ExponentialState?
        ) throws -> Duration {
            switch backoff {
            case .none:
                return .zero
            case .constant(let delay):
                return delay
            case .exponential(let definition):
                return try definition.nextDelay(
                    retry: retry,
                    exponentialState: &exponentialState
                )
            }
        }
    }

    enum NormalizedBackoff: Sendable {
        case none
        case constant(Duration)
        case exponential(ExponentialDefinition)
    }

    struct ExponentialDefinition: Sendable {
        let initial: Duration
        let multiplier: Double
        let maxDelay: Duration?

        func nextDelay(
            retry: Int,
            exponentialState: inout ExponentialState?
        ) throws -> Duration {
            let currentState = exponentialState ?? ExponentialState(
                delay: initial,
                seconds: durationInSeconds(initial)
            )

            guard currentState.seconds.isFinite else {
                throw RetryConfigurationError.exponentialDelayOverflow(
                    initial: initial,
                    multiplier: multiplier,
                    retry: retry
                )
            }

            if let maxDelay, currentState.delay >= maxDelay {
                exponentialState = ExponentialState(
                    delay: maxDelay,
                    seconds: durationInSeconds(maxDelay)
                )
                return maxDelay
            }

            guard retry > 1 else {
                exponentialState = currentState
                return currentState.delay
            }

            let nextDelay: Duration

            if let maxDelay {
                let maxDelaySeconds = durationInSeconds(maxDelay)
                if currentState.seconds >= maxDelaySeconds {
                    nextDelay = maxDelay
                } else if currentState.seconds >= maxDelaySeconds / multiplier {
                    nextDelay = maxDelay
                } else {
                    nextDelay = min(
                        try scaledDuration(
                            currentState.delay,
                            multiplier: multiplier,
                            initial: initial,
                            retry: retry
                        ),
                        maxDelay
                    )
                }
            } else {
                nextDelay = try scaledDuration(
                    currentState.delay,
                    multiplier: multiplier,
                    initial: initial,
                    retry: retry
                )
            }

            exponentialState = ExponentialState(
                delay: nextDelay,
                seconds: durationInSeconds(nextDelay)
            )

            return nextDelay
        }
    }

    struct ExponentialState: Sendable {
        let delay: Duration
        let seconds: Double
    }

    static func validatedRetryConfiguration(
        max: Int,
        backoff: RetryBackoff,
        jitter: RetryJitter
    ) throws -> RetryConfiguration {
        guard max >= 0 else {
            throw RetryConfigurationError.negativeMaxRetries(max)
        }

        let normalizedBackoff: NormalizedBackoff
        switch backoff {
        case .none:
            normalizedBackoff = .none
        case .constant(let delay):
            guard delay > .zero else {
                throw RetryConfigurationError.nonPositiveConstantDelay(delay)
            }
            normalizedBackoff = .constant(delay)
        case .exponential(let initial, let multiplier, let maxDelay):
            guard initial > .zero else {
                throw RetryConfigurationError.nonPositiveInitialDelay(initial)
            }

            guard multiplier.isFinite, multiplier > 1 else {
                throw RetryConfigurationError.invalidMultiplier(multiplier)
            }

            if let maxDelay {
                guard maxDelay > .zero else {
                    throw RetryConfigurationError.nonPositiveMaxDelay(maxDelay)
                }

                guard maxDelay >= initial else {
                    throw RetryConfigurationError.maxDelayLessThanInitial(
                        initial: initial,
                        maxDelay: maxDelay
                    )
                }
            }

            normalizedBackoff = .exponential(
                ExponentialDefinition(
                    initial: initial,
                    multiplier: multiplier,
                    maxDelay: maxDelay
                )
            )
        }

        return RetryConfiguration(
            maxRetries: max,
            backoff: normalizedBackoff,
            jitter: jitter
        )
    }

    static func jitteredDelay(
        _ delay: Duration,
        jitter: RetryJitter,
        randomUnitInterval: @Sendable () -> Double
    ) -> Duration {
        switch jitter {
        case .none:
            return delay
        case .full:
            let sample = normalizedUnitIntervalSample(randomUnitInterval())
            return delay * sample
        }
    }

    static func normalizedUnitIntervalSample(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    static func durationInSeconds(_ duration: Duration) -> Double {
        let components = duration.components
        let attosecondsPerSecond = 1_000_000_000_000_000_000.0
        return Double(components.seconds) + (Double(components.attoseconds) / attosecondsPerSecond)
    }

    static func scaledDuration(
        _ duration: Duration,
        multiplier: Double,
        initial: Duration,
        retry: Int
    ) throws -> Duration {
        let seconds = durationInSeconds(duration)
        guard seconds.isFinite else {
            throw RetryConfigurationError.exponentialDelayOverflow(
                initial: initial,
                multiplier: multiplier,
                retry: retry
            )
        }

        let scaledSeconds = seconds * multiplier
        guard scaledSeconds.isFinite else {
            throw RetryConfigurationError.exponentialDelayOverflow(
                initial: initial,
                multiplier: multiplier,
                retry: retry
            )
        }

        // `Duration.seconds` can trap when converting out-of-range doubles to internal integer
        // components, so clamp strictly below the representable boundary before construction.
        let maxSeconds = maxRepresentableDurationSeconds.nextDown
        guard scaledSeconds <= maxSeconds else {
            throw RetryConfigurationError.exponentialDelayOverflow(
                initial: initial,
                multiplier: multiplier,
                retry: retry
            )
        }

        return Duration.seconds(scaledSeconds)
    }

    static let maxRepresentableDurationSeconds = Double(Int64.max)

    /// Value paired with source index to restore deterministic ordering after concurrent execution.
    struct IndexedValue<Value: Sendable>: Sendable {
        let index: Int
        let value: Value
    }

    static func orderedConcurrentTransform<C: Collection, Output: Sendable>(
        _ sequence: C,
        limit: ConcurrencyLimit,
        transform: @escaping @Sendable (C.Element) async -> Output
    ) async -> [Output] where C.Element: Sendable {
        let elements = Array(sequence)
        guard !elements.isEmpty else { return [] }

        let maxInFlight = min(limit.resolvedValue, elements.count)

        return await withTaskGroup(of: IndexedValue<Output>.self) { group in
            var nextIndex = 0
            var orderedResults = Array<Output?>(repeating: nil, count: elements.count)

            func scheduleNextTaskIfAvailable() {
                guard !Task.isCancelled else { return }
                guard nextIndex < elements.count else { return }

                let index = nextIndex
                let element = elements[index]
                nextIndex += 1

                group.addTask {
                    IndexedValue(index: index, value: await transform(element))
                }
            }

            for _ in 0..<maxInFlight {
                scheduleNextTaskIfAvailable()
            }

            while let result = await group.next() {
                orderedResults[result.index] = result.value
                scheduleNextTaskIfAvailable()
            }

            return orderedResults.compactMap { $0 }
        }
    }

    static func orderedConcurrentTransform<C: Collection, Output: Sendable>(
        _ sequence: C,
        limit: ConcurrencyLimit,
        transform: @escaping @Sendable (C.Element) async throws -> Output
    ) async throws -> [Output] where C.Element: Sendable {
        let elements = Array(sequence)
        guard !elements.isEmpty else { return [] }

        let maxInFlight = min(limit.resolvedValue, elements.count)

        return try await withThrowingTaskGroup(of: IndexedValue<Output>.self) { group in
            var nextIndex = 0
            var orderedResults = Array<Output?>(repeating: nil, count: elements.count)

            func scheduleNextTaskIfAvailable() {
                guard !Task.isCancelled else { return }
                guard nextIndex < elements.count else { return }

                let index = nextIndex
                let element = elements[index]
                nextIndex += 1

                group.addTask {
                    IndexedValue(index: index, value: try await transform(element))
                }
            }

            for _ in 0..<maxInFlight {
                scheduleNextTaskIfAvailable()
            }

            do {
                while let result = try await group.next() {
                    orderedResults[result.index] = result.value
                    scheduleNextTaskIfAvailable()
                }
            } catch {
                group.cancelAll()
                throw error
            }

            return orderedResults.compactMap { $0 }
        }
    }

    static func executeConcurrently<C: Collection>(
        _ sequence: C,
        limit: ConcurrencyLimit,
        operation: @escaping @Sendable (C.Element) async -> Void
    ) async where C.Element: Sendable {
        await withTaskGroup(of: Void.self) { group in
            var iterator = sequence.makeIterator()
            var activeTasks = 0
            let maxInFlight = limit.resolvedValue

            while !Task.isCancelled, activeTasks < maxInFlight, let element = iterator.next() {
                activeTasks += 1
                group.addTask {
                    await operation(element)
                }
            }

            while activeTasks > 0 {
                _ = await group.next()
                activeTasks -= 1

                if !Task.isCancelled, let element = iterator.next() {
                    activeTasks += 1
                    group.addTask {
                        await operation(element)
                    }
                }
            }
        }
    }

    static func executeConcurrently<C: Collection>(
        _ sequence: C,
        limit: ConcurrencyLimit,
        operation: @escaping @Sendable (C.Element) async throws -> Void
    ) async throws where C.Element: Sendable {
        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = sequence.makeIterator()
            var activeTasks = 0
            let maxInFlight = limit.resolvedValue

            while !Task.isCancelled, activeTasks < maxInFlight, let element = iterator.next() {
                activeTasks += 1
                group.addTask {
                    try await operation(element)
                }
            }

            do {
                while activeTasks > 0 {
                    _ = try await group.next()
                    activeTasks -= 1

                    if !Task.isCancelled, let element = iterator.next() {
                        activeTasks += 1
                        group.addTask {
                            try await operation(element)
                        }
                    }
                }
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }
}
