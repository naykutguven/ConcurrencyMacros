//
//  ConcurrencyRuntime.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 11.03.26.
//

/// Namespace for runtime helpers used by freestanding concurrency macros.
public enum ConcurrencyRuntime {
    /// Error thrown when a timeout duration elapses before the operation completes.
    public enum TimeoutError: Error, Sendable, Equatable {
        /// Indicates the operation did not complete before the timeout expired.
        ///
        /// - Parameter after: The timeout duration that elapsed.
        case timedOut(after: Duration)
    }

    /// Executes `operation` and fails if it does not complete before `duration` expires.
    ///
    /// - Parameters:
    ///   - duration: Maximum time allowed for the operation to complete.
    ///   - operation: Async operation to run.
    /// - Returns: The operation result when it completes within `duration`.
    /// - Throws: `TimeoutError` when the timeout elapses, operation-thrown errors, or external cancellation.
    ///
    /// - Important: This helper uses structured cancellation. If the operation does not cooperate with cancellation,
    /// completion may exceed the requested timeout while child tasks unwind.
    public static func withTimeout<T: Sendable>(
        _ duration: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard duration > .zero else {
            throw TimeoutError.timedOut(after: duration)
        }

        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(operation: operation)
            group.addTask {
                try await ContinuousClock().sleep(for: duration)
                throw TimeoutError.timedOut(after: duration)
            }

            defer { group.cancelAll() }

            guard let firstResult = try await group.next() else {
                throw CancellationError()
            }

            return firstResult
        }
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
    public static func concurrentFlatMap<C: Collection, Segment: Sequence>(
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
    public static func concurrentFlatMap<C: Collection, Segment: Sequence>(
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
