//
//  ConcurrentCollectionsTests.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 11.03.26.
//

import Testing
@testable import ConcurrencyMacrosRuntime

@Suite("ConcurrentCollections")
struct ConcurrentCollectionsTests {
    private enum ExpectedError: Error, Equatable {
        case failed
        case exhausted
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
