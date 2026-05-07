//
//  ThreadSafeStorageTests.swift
//  ConcurrencyMacros
//

import Testing
@testable import ConcurrencyMacrosRuntime

@Suite("ThreadSafeStorage")
struct ThreadSafeStorageTests {
    private struct State: Sendable, Equatable {
        var count: Int
        var items: [String]
    }

    private final class NonSendableValue {
        var value: Int

        init(_ value: Int) {
            self.value = value
        }
    }

    private struct UncheckedState {
        var value: NonSendableValue
    }

    @Test("Reads and writes checked state members")
    func readsAndWritesCheckedStateMembers() {
        let storage = ThreadSafeStorage(State(count: 1, items: ["a"]))

        #expect(storage.read(\.count) == 1)
        storage.write(\.count, 2)
        #expect(storage.read(\.count) == 2)
    }

    @Test("Modify accessor holds checked storage mutation")
    func modifyAccessorHoldsCheckedStorageMutation() {
        let storage = ThreadSafeStorage(State(count: 0, items: []))

        storage[modifying: \.count] += 1
        storage[modifying: \.items].append("x")

        #expect(storage.read(\.count) == 1)
        #expect(storage.read(\.items) == ["x"])
    }

    @Test("withLock mutates whole checked state")
    func withLockMutatesWholeCheckedState() {
        let storage = ThreadSafeStorage(State(count: 2, items: ["a", "b"]))

        let result = storage.withLock { state in
            state.count += state.items.count
            state.items.append("c")
            return state.count
        }

        #expect(result == 4)
        #expect(storage.read(\.count) == 4)
        #expect(storage.read(\.items) == ["a", "b", "c"])
    }

    @Test("Unchecked storage accepts non-Sendable state")
    func uncheckedStorageAcceptsNonSendableState() {
        let storage = UncheckedThreadSafeStorage(UncheckedState(value: NonSendableValue(1)))

        storage[modifying: \.value].value += 1

        #expect(storage.read(\.value).value == 2)
    }

    @Test("Checked storage supports concurrent modifying access")
    func checkedStorageSupportsConcurrentModifyingAccess() async {
        let storage = ThreadSafeStorage(State(count: 0, items: []))

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<200 {
                group.addTask {
                    storage[modifying: \.count] += 1
                }
            }
        }

        #expect(storage.read(\.count) == 200)
    }
}
