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
}
