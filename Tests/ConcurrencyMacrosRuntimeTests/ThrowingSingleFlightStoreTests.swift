//
//  ThrowingSingleFlightStoreTests.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 15.03.26.
//

import Testing
@testable import ConcurrencyMacrosRuntime

@Suite("ThrowingSingleFlightStore")
struct ThrowingSingleFlightStoreTests {
    private typealias Support = SingleFlightRuntimeTestSupport

    @Test("Throwing store shares same error for concurrent waiters")
    func throwingStoreSharesErrorsForConcurrentWaiters() async {
        let store = ThrowingSingleFlightStore<Int>()
        let counter = Support.CounterActor()

        let first = Task {
            try await store.run(key: "same") {
                await counter.increment()
                _ = try? await Task.sleep(for: .milliseconds(80))
                throw Support.ExpectedError.failed
            }
        }

        let second = Task {
            try await store.run(key: "same") {
                await counter.increment()
                throw Support.ExpectedError.failed
            }
        }

        let firstResult = await Support.awaitResult { try await first.value }
        let secondResult = await Support.awaitResult { try await second.value }

        guard case let .failure(firstError) = firstResult else {
            Issue.record("Expected first waiter to fail")
            return
        }

        guard case let .failure(secondError) = secondResult else {
            Issue.record("Expected second waiter to fail")
            return
        }

        #expect(firstError as? Support.ExpectedError == .failed)
        #expect(secondError as? Support.ExpectedError == .failed)
        #expect(await counter.value() == 1)
    }

    @Test("Failures are not cached after completion")
    func failuresAreNotCachedAfterCompletion() async throws {
        let store = ThrowingSingleFlightStore<Int>()
        let counter = Support.CounterActor()

        let firstResult = await Support.awaitResult {
            try await store.run(key: "same") {
                await counter.increment()
                throw Support.ExpectedError.failed
            }
        }

        guard case let .failure(firstError) = firstResult else {
            Issue.record("Expected first call to fail")
            return
        }

        #expect(firstError as? Support.ExpectedError == .failed)

        let secondValue = try await store.run(key: "same") {
            await counter.increment()
            return 42
        }

        #expect(secondValue == 42)
        #expect(await counter.value() == 2)
    }

    @Test("Canceling one waiter keeps leader alive while others still wait")
    func cancelingOneWaiterKeepsLeaderAlive() async throws {
        let store = ThrowingSingleFlightStore<Int>()
        let probe = Support.CancellationProbeActor()

        let leader = Task {
            try await store.run(key: "shared") {
                await probe.markStarted()
                await probe.incrementExecutions()
                do {
                    try await Task.sleep(for: .milliseconds(120))
                    await probe.markCompleted()
                    return 42
                } catch is CancellationError {
                    await probe.markCancelled()
                    throw CancellationError()
                }
            }
        }

        await Support.waitUntil({ await probe.started() })

        let canceledWaiter = Task {
            try await store.run(key: "shared") {
                await probe.incrementExecutions()
                return 99
            }
        }

        canceledWaiter.cancel()

        let leaderValue = try await leader.value
        let canceledWaiterResult = await Support.awaitResult { try await canceledWaiter.value }

        #expect(leaderValue == 42)
        #expect(await probe.executions() == 1)
        #expect(await probe.completed() == true)
        #expect(await probe.cancelled() == false)

        switch canceledWaiterResult {
        case .success(let value):
            #expect(value == 42)
        case .failure(let error):
            #expect(error is CancellationError)
        }
    }

    @Test("Last waiter cancellation cancels leader with default policy")
    func lastWaiterCancellationCancelsLeaderWithDefaultPolicy() async {
        let store = ThrowingSingleFlightStore<Int>()
        let probe = Support.CancellationProbeActor()

        let waiter = Task {
            try await store.run(key: "shared") {
                await probe.markStarted()
                do {
                    try await Task.sleep(for: .seconds(5))
                    await probe.markCompleted()
                    return 1
                } catch is CancellationError {
                    await probe.markCancelled()
                    throw CancellationError()
                }
            }
        }

        await Support.waitUntil({ await probe.started() })

        waiter.cancel()
        let result = await Support.awaitResult { try await waiter.value }

        guard case let .failure(error) = result else {
            Issue.record("Expected canceled waiter to fail")
            return
        }

        #expect(error is CancellationError)
        await Support.waitUntil({ await probe.cancelled() })
    }

    @Test("Continue policy keeps leader running when all waiters cancel")
    func continuePolicyKeepsLeaderRunningWhenAllWaitersCancel() async {
        let store = ThrowingSingleFlightStore<Int>(defaultCancellationPolicy: .continueWhenNoWaiters)
        let probe = Support.CancellationProbeActor()

        let waiter = Task {
            try await store.run(key: "shared") {
                await probe.markStarted()
                do {
                    try await Task.sleep(for: .milliseconds(120))
                    await probe.markCompleted()
                    return 5
                } catch is CancellationError {
                    await probe.markCancelled()
                    throw CancellationError()
                }
            }
        }

        await Support.waitUntil({ await probe.started() })

        waiter.cancel()
        _ = await Support.awaitResult { try await waiter.value }

        await Support.waitUntil({ await probe.completed() })
        #expect(await probe.cancelled() == false)
    }

    @Test("Continue policy keeps zero-waiter flight joinable by late callers")
    func continuePolicyKeepsZeroWaiterFlightJoinableByLateCallers() async throws {
        let store = ThrowingSingleFlightStore<Int>(defaultCancellationPolicy: .continueWhenNoWaiters)
        let probe = Support.CancellationProbeActor()
        let gate = Support.AsyncGateActor()

        let canceledWaiter = Task {
            try await store.run(key: "shared") {
                await probe.markStarted()
                await probe.incrementExecutions()
                await gate.wait()
                await probe.markCompleted()
                return 13
            }
        }

        await Support.waitUntil({ await probe.started() })

        canceledWaiter.cancel()

        let lateJoiner = Task {
            try await store.run(key: "shared") {
                await probe.incrementExecutions()
                return 99
            }
        }

        _ = try? await Task.sleep(for: .milliseconds(20))
        await gate.open()

        let joinedValue = try await lateJoiner.value
        _ = await Support.awaitResult { try await canceledWaiter.value }

        #expect(joinedValue == 13)
        #expect(await probe.executions() == 1)
        #expect(await probe.completed())
    }

    @Test("Leader completion removes zero-waiter flight under continue policy")
    func leaderCompletionRemovesZeroWaiterFlightUnderContinuePolicy() async throws {
        let store = ThrowingSingleFlightStore<Int>(defaultCancellationPolicy: .continueWhenNoWaiters)
        let probe = Support.CancellationProbeActor()
        let gate = Support.AsyncGateActor()

        let canceledWaiter = Task {
            try await store.run(key: "shared") {
                await probe.markStarted()
                await probe.incrementExecutions()
                await gate.wait()
                await probe.markCompleted()
                return 21
            }
        }

        await Support.waitUntil({ await probe.started() })
        canceledWaiter.cancel()
        await gate.open()

        _ = await Support.awaitResult { try await canceledWaiter.value }
        await Support.waitUntil({ await probe.completed() })

        // Give completion cleanup task a scheduling turn.
        await Task.yield()

        let newerValue = try await store.run(key: "shared") {
            await probe.incrementExecutions()
            return 34
        }

        #expect(newerValue == 34)
        #expect(await probe.executions() == 2)
    }

    @Test("Stale waiter cleanup does not interfere with newer same-key flights")
    func staleWaiterCleanupDoesNotInterfereWithNewerFlights() async throws {
        let store = ThrowingSingleFlightStore<Int>()
        let probe = Support.StaleCleanupProbeActor()

        for _ in 0..<20 {
            let iterationProbe = Support.IterationProbeActor()
            let gate = Support.AsyncGateActor()

            let leader = Task {
                try await store.run(key: "shared") {
                    await iterationProbe.markFirstLeaderStarted()
                    await gate.wait()
                    return 1
                }
            }

            await Support.waitUntil({ await iterationProbe.firstLeaderStarted() })

            let canceledWaiter = Task {
                try await store.run(key: "shared") {
                    await probe.markUnexpectedLeaderExecution()
                    return 999
                }
            }

            _ = try? await Task.sleep(for: .milliseconds(20))
            canceledWaiter.cancel()
            await gate.open()

            _ = try await leader.value

            let newerFlight = try await store.run(key: "shared") {
                await probe.markSecondFlightLeaderExecution()
                return 2
            }

            #expect(newerFlight == 2)
            _ = await Support.awaitResult { try await canceledWaiter.value }
        }

        #expect(await probe.unexpectedLeaderExecutions() == 0)
        #expect(await probe.secondFlightLeaderExecutions() == 20)
    }

    @Test("Run API uses sendable operation signature")
    func runAPIUsesSendableOperationSignature() async throws {
        let store = ThrowingSingleFlightStore<Int>()

        let run: (
            Int,
            SingleFlightCancellationPolicy?,
            @escaping @Sendable () async throws -> Int
        ) async throws -> Int = { key, policy, operation in
            try await store.run(key: key, policy: policy, operation: operation)
        }

        let value = try await run(1, nil) { 89 }
        #expect(value == 89)
    }
}
