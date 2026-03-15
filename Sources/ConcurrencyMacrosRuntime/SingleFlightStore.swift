//
//  SingleFlightStore.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 15.03.26.
//

/// Cancellation policy applied when the last waiter leaves an in-flight flight.
public enum SingleFlightCancellationPolicy: Sendable {
    /// Cancels the leader task when the final waiter cancels.
    case cancelWhenNoWaiters

    /// Keeps the leader task running even if all waiters cancel.
    case continueWhenNoWaiters
}

/// Deduplicates concurrent non-throwing async work for identical keys.
///
/// `SingleFlightStore` shares a single in-flight task among concurrent callers with the same key.
/// Finished flights are removed immediately.
///
/// - Important: This type does not provide post-completion caching. A later call after completion
///   always starts a new flight.
/// - Important: Cancellation behavior depends on `SingleFlightCancellationPolicy`. With
///   `.cancelWhenNoWaiters`, the leader task is canceled when the final waiter cancels.
public final class SingleFlightStore<Value: Sendable>: Sendable {
    private struct Flight: Sendable {
        let id: UInt64
        let task: Task<Value, Never>
        var waiterCount: Int
    }

    private struct State: Sendable {
        var nextFlightID: UInt64 = 0
        var flights: [AnySendableHashable: Flight] = [:]
    }

    private let defaultCancellationPolicy: SingleFlightCancellationPolicy
    private let state = Mutex(State())

    /// Creates a single-flight store with a default cancellation policy.
    ///
    /// - Parameter defaultCancellationPolicy: The policy used when `run` omits `policy`.
    public init(defaultCancellationPolicy: SingleFlightCancellationPolicy = .cancelWhenNoWaiters) {
        self.defaultCancellationPolicy = defaultCancellationPolicy
    }

    /// Runs `operation` under single-flight deduplication for `key`.
    ///
    /// All concurrent waiters for the same key await the same in-flight leader task.
    /// Results are not cached after completion.
    ///
    /// - Parameters:
    ///   - key: Typed dedupe key. Equal keys join the same in-flight task.
    ///   - policy: Optional per-call cancellation policy. Uses store default when omitted.
    ///   - operation: `@Sendable` async operation used to start a leader task when no flight exists.
    /// - Returns: The leader task result for this key.
    /// - Important: `operation` should be cancellation-cooperative when using
    ///   `.cancelWhenNoWaiters`; cancellation is best-effort and depends on cooperative checks.
    public func run<Key: Hashable & Sendable>(
        key: Key,
        policy: SingleFlightCancellationPolicy? = nil,
        operation: @escaping @Sendable () async -> Value
    ) async -> Value {
        await runAnyKey(
            key: AnySendableHashable(key),
            policy: policy,
            operation: operation
        )
    }

    /// Runs `operation` under single-flight deduplication for `key`.
    ///
    /// All concurrent waiters for the same key await the same in-flight leader task.
    /// Results are not cached after completion.
    private func runAnyKey(
        key: AnySendableHashable,
        policy: SingleFlightCancellationPolicy? = nil,
        operation: @escaping @Sendable () async -> Value
    ) async -> Value {
        let resolvedPolicy = policy ?? defaultCancellationPolicy
        let (task, flightID) = joinOrStartFlight(key: key, operation: operation)
        let cleanupGate = SingleFlightCleanupGate()

        return await withTaskCancellationHandler {
            defer {
                cleanupGate.runOnce {
                    removeFlightIfCurrent(key: key, flightID: flightID)
                }
            }
            return await task.value
        } onCancel: {
            cleanupGate.runOnce {
                cancelWaiter(key: key, flightID: flightID, policy: resolvedPolicy)
            }
        }
    }

    private func joinOrStartFlight(
        key: AnySendableHashable,
        operation: @escaping @Sendable () async -> Value
    ) -> (Task<Value, Never>, UInt64) {
        let result = state.mutate { state -> (task: Task<Value, Never>, flightID: UInt64, startedNewFlight: Bool) in
            if var existingFlight = state.flights[key] {
                existingFlight.waiterCount += 1
                state.flights[key] = existingFlight
                return (task: existingFlight.task, flightID: existingFlight.id, startedNewFlight: false)
            }

            state.nextFlightID &+= 1
            let flightID = state.nextFlightID
            let leaderTask = Task {
                await operation()
            }
            state.flights[key] = Flight(id: flightID, task: leaderTask, waiterCount: 1)
            return (task: leaderTask, flightID: flightID, startedNewFlight: true)
        }

        if result.startedNewFlight {
            startCompletionCleanup(for: result.task, key: key, flightID: result.flightID)
        }

        return (result.task, result.flightID)
    }

    private func removeFlightIfCurrent(key: AnySendableHashable, flightID: UInt64) {
        state.mutate { state in
            guard let existingFlight = state.flights[key], existingFlight.id == flightID else {
                return
            }

            // Completion is terminal for a flight: remove eagerly so late joiners start a new flight.
            state.flights.removeValue(forKey: key)
        }
    }

    private func cancelWaiter(
        key: AnySendableHashable,
        flightID: UInt64,
        policy: SingleFlightCancellationPolicy
    ) {
        state.mutate { state in
            guard var existingFlight = state.flights[key], existingFlight.id == flightID else {
                return
            }

            existingFlight.waiterCount -= 1

            guard existingFlight.waiterCount <= 0 else {
                state.flights[key] = existingFlight
                return
            }

            if policy == .cancelWhenNoWaiters {
                state.flights.removeValue(forKey: key)
                existingFlight.task.cancel()
                return
            }

            existingFlight.waiterCount = 0
            state.flights[key] = existingFlight
        }
    }

    private func startCompletionCleanup(for task: Task<Value, Never>, key: AnySendableHashable, flightID: UInt64) {
        Task {
            _ = await task.result
            self.removeFlightIfCurrent(key: key, flightID: flightID)
        }
    }
}

final class SingleFlightCleanupGate: Sendable {
    private let didCleanup = Mutex(false)

    func runOnce(_ cleanup: @Sendable () -> Void) {
        let shouldRun = didCleanup.mutate { didCleanup in
            guard !didCleanup else { return false }
            didCleanup = true
            return true
        }
        guard shouldRun else { return }
        cleanup()
    }
}

struct AnySendableHashable: Hashable, Sendable {
    private let typeID: ObjectIdentifier
    private let storage: any Sendable
    private let hashIntoImpl: @Sendable (inout Hasher) -> Void
    private let equalsImpl: @Sendable (AnySendableHashable) -> Bool

    init<Key: Hashable & Sendable>(_ key: Key) {
        typeID = ObjectIdentifier(Key.self)
        storage = key
        hashIntoImpl = { hasher in
            hasher.combine(key)
        }
        equalsImpl = { other in
            guard other.typeID == ObjectIdentifier(Key.self),
                  let otherKey = other.storage as? Key
            else {
                return false
            }
            return key == otherKey
        }
    }

    static func == (lhs: AnySendableHashable, rhs: AnySendableHashable) -> Bool {
        lhs.equalsImpl(rhs)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(typeID)
        hashIntoImpl(&hasher)
    }
}
