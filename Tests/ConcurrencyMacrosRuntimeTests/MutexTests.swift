//
//  MutexTests.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 11.03.26.
//

import Testing
@testable import ConcurrencyMacrosRuntime

@Suite("Mutex")
struct MutexTests {
    private struct State: Sendable, Equatable {
        var count: Int
        var name: String
        let id: Int

        var summary: String {
            "\(id)-\(name)-\(count)"
        }
    }

    private enum ExpectedError: Error, Equatable {
        case failed
    }

    @Test("Returns initial value snapshot")
    func returnsInitialValueSnapshot() {
        let mutex = Mutex(State(count: 1, name: "seed", id: 7))

        #expect(mutex.value == State(count: 1, name: "seed", id: 7))
    }

    @Test("Mutates state and returns closure result")
    func mutatesStateAndReturnsClosureResult() {
        let mutex = Mutex(State(count: 1, name: "seed", id: 7))

        let result = mutex.mutate { state in
            state.count += 1
            state.name = state.name.uppercased()
            return "\(state.id):\(state.name):\(state.count)"
        }

        #expect(result == "7:SEED:2")
        #expect(mutex.value == State(count: 2, name: "SEED", id: 7))
    }

    @Test("Rethrows errors from mutation closure")
    func rethrowsErrorsFromMutationClosure() {
        let mutex = Mutex(State(count: 1, name: "seed", id: 7))
        var capturedError: ExpectedError?

        do {
            _ = try mutex.mutate { _ in
                throw ExpectedError.failed
            }
        } catch let error as ExpectedError {
            capturedError = error
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        #expect(capturedError == .failed)
        #expect(mutex.value == State(count: 1, name: "seed", id: 7))
    }

    @Test("Replaces whole state and returns previous value")
    func replacesWholeStateAndReturnsPreviousValue() {
        let mutex = Mutex(State(count: 1, name: "seed", id: 7))

        let previous = mutex.set(State(count: 4, name: "done", id: 8))

        #expect(previous == State(count: 1, name: "seed", id: 7))
        #expect(mutex.value == State(count: 4, name: "done", id: 8))
    }

    @Test("Replaces one member by key path and returns previous member value")
    func replacesMemberByKeyPathAndReturnsPreviousMemberValue() {
        let mutex = Mutex(State(count: 1, name: "seed", id: 7))

        let previousCount = mutex.set(\.count, to: 9)

        #expect(previousCount == 1)
        #expect(mutex.value.count == 9)
        #expect(mutex.value.name == "seed")
    }

    @Test("Supports writable dynamic member access")
    func supportsWritableDynamicMemberAccess() {
        let mutex = Mutex(State(count: 1, name: "seed", id: 7))

        #expect(mutex.count == 1)
        mutex.count = 3
        mutex.name = "next"

        #expect(mutex.count == 3)
        #expect(mutex.name == "next")
    }

    @Test("Supports read-only dynamic member access")
    func supportsReadonlyDynamicMemberAccess() {
        let mutex = Mutex(State(count: 5, name: "value", id: 2))

        #expect(mutex.summary == "2-value-5")
    }

    @Test("Supports concurrent mutations")
    func supportsConcurrentMutations() async {
        let mutex = Mutex(State(count: 0, name: "seed", id: 1))

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<200 {
                group.addTask {
                    mutex.mutate { state in
                        state.count += 1
                    }
                }
            }
        }

        #expect(mutex.count == 200)
    }
}
