//
//  SingleFlightStoreTests.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 15.03.26.
//

import Testing
@testable import ConcurrencyMacrosRuntime

@Suite("SingleFlightStore")
struct SingleFlightStoreTests {
    private typealias Support = SingleFlightRuntimeTestSupport

    @Test("Non-throwing store deduplicates identical concurrent keys")
    func nonThrowingStoreDeduplicatesIdenticalConcurrentKeys() async {
        let store = SingleFlightStore<Int>()
        let counter = Support.CounterActor()

        async let first = store.run(key: "same") {
            await counter.increment()
            _ = try? await Task.sleep(for: .milliseconds(80))
            return 7
        }

        async let second = store.run(key: "same") {
            await counter.increment()
            return 8
        }

        async let third = store.run(key: "same") {
            await counter.increment()
            return 9
        }

        let firstValue = await first
        let secondValue = await second
        let thirdValue = await third

        #expect(firstValue == 7)
        #expect(secondValue == 7)
        #expect(thirdValue == 7)
        #expect(await counter.value() == 1)
    }

    @Test("Different keys do not deduplicate")
    func differentKeysDoNotDeduplicate() async {
        let store = SingleFlightStore<Int>()
        let counter = Support.CounterActor()

        async let first = store.run(key: "first") {
            await counter.increment()
            _ = try? await Task.sleep(for: .milliseconds(40))
            return 1
        }

        async let second = store.run(key: "second") {
            await counter.increment()
            return 2
        }

        let firstValue = await first
        let secondValue = await second

        #expect(firstValue == 1)
        #expect(secondValue == 2)
        #expect(await counter.value() == 2)
    }

    @Test("Run API uses sendable operation signature")
    func runAPIUsesSendableOperationSignature() async {
        let store = SingleFlightStore<Int>()

        let run: (
            Int,
            SingleFlightCancellationPolicy?,
            @escaping @Sendable () async -> Int
        ) async -> Int = { key, policy, operation in
            await store.run(key: key, policy: policy, operation: operation)
        }

        let value = await run(1, nil) { 55 }
        #expect(value == 55)
    }
}
