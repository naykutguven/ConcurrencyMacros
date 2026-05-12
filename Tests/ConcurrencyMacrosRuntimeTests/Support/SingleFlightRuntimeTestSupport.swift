//
//  SingleFlightRuntimeTestSupport.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 15.03.26.
//

import Testing
@testable import ConcurrencyMacrosRuntime

enum SingleFlightRuntimeTestSupport {
    enum ExpectedError: Error, Equatable {
        case failed
    }

    actor CounterActor {
        private var counter = 0

        func increment() {
            counter += 1
        }

        func value() -> Int {
            counter
        }
    }

    actor CancellationProbeActor {
        private var didStart = false
        private var didCancel = false
        private var didComplete = false
        private var executionCount = 0

        func incrementExecutions() {
            executionCount += 1
        }

        func markStarted() {
            didStart = true
        }

        func markCancelled() {
            didCancel = true
        }

        func markCompleted() {
            didComplete = true
        }

        func started() -> Bool { didStart }
        func cancelled() -> Bool { didCancel }
        func completed() -> Bool { didComplete }
        func executions() -> Int { executionCount }
    }

    actor StaleCleanupProbeActor {
        private var secondFlightExecutions = 0
        private var unexpectedExecutions = 0

        func markSecondFlightLeaderExecution() {
            secondFlightExecutions += 1
        }

        func markUnexpectedLeaderExecution() {
            unexpectedExecutions += 1
        }

        func secondFlightLeaderExecutions() -> Int {
            secondFlightExecutions
        }

        func unexpectedLeaderExecutions() -> Int {
            unexpectedExecutions
        }
    }

    actor IterationProbeActor {
        private var didStartFirstLeader = false

        func markFirstLeaderStarted() {
            didStartFirstLeader = true
        }

        func firstLeaderStarted() -> Bool {
            didStartFirstLeader
        }
    }

    final class HashProbe: Sendable {
        private let didHashStorage = Mutex(false)

        func markHashed() {
            didHashStorage.mutate { didHash in
                didHash = true
            }
        }

        func didHash() -> Bool {
            didHashStorage.value
        }
    }

    struct InstrumentedKey: Hashable, Sendable {
        let rawValue: String
        let hashProbe: HashProbe?

        init(_ rawValue: String, hashProbe: HashProbe? = nil) {
            self.rawValue = rawValue
            self.hashProbe = hashProbe
        }

        func hash(into hasher: inout Hasher) {
            hashProbe?.markHashed()
            hasher.combine(rawValue)
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue == rhs.rawValue
        }
    }

    actor AsyncGateActor {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func open() {
            guard !isOpen else { return }
            isOpen = true
            let pendingWaiters = waiters
            waiters.removeAll(keepingCapacity: false)
            for waiter in pendingWaiters {
                waiter.resume()
            }
        }
    }

    static func awaitResult<T>(_ operation: @escaping () async throws -> T) async -> Result<T, Error> {
        do {
            return .success(try await operation())
        } catch {
            return .failure(error)
        }
    }

    static func waitUntil(
        _ condition: @escaping @Sendable () async -> Bool,
        timeout: Duration = .seconds(2)
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while !(await condition()) {
            guard clock.now < deadline else {
                Issue.record("Timed out while waiting for condition")
                return
            }
            await Task.yield()
        }
    }
}
