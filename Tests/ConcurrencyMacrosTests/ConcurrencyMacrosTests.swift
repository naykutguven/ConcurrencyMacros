//
//  ConcurrencyMacrosTests.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 11.03.26.
//

import ConcurrencyMacros
import Testing

@Suite("ConcurrencyMacros")
struct ConcurrencyMacrosTests {
    @ThreadSafe
    private final class Counter {
        var count: Int
        var label: String = "seed"

        init(count: Int) {
            self.count = count
        }
    }

    private actor Collector {
        private var values: [Int] = []

        func append(_ value: Int) {
            values.append(value)
        }

        func count() -> Int {
            values.count
        }
    }

    @Test("ThreadSafe compiles with a single import")
    func threadSafeCompilesWithSingleImport() {
        let counter = Counter(count: 1)
        #expect(counter.count == 1)
        #expect(counter.label == "seed")

        counter.count = 2
        counter.label = "next"

        #expect(counter.count == 2)
        #expect(counter.label == "next")
    }

    @Test("withTimeout compiles with a single import and returns result")
    func withTimeoutCompilesWithSingleImport() async throws {
        let value = try await #withTimeout(.seconds(1)) {
            42
        }

        #expect(value == 42)
    }

    @Test("withTimeout supports operation argument form")
    func withTimeoutSupportsOperationArgumentForm() async throws {
        let value = try await #withTimeout(.seconds(1), operation: {
            42
        })

        #expect(value == 42)
    }

    @Test("withTimeout surfaces TimeoutError through ConcurrencyMacros import")
    func withTimeoutSurfacesTimeoutErrorAlias() async {
        let timeout = Duration.milliseconds(50)

        do {
            _ = try await #withTimeout(timeout) {
                try await Task.sleep(for: .seconds(1))
                return 1
            }
            Issue.record("Expected timeout error")
        } catch let error as TimeoutError {
            #expect(error == .timedOut(after: timeout))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("retrying compiles with single import and succeeds after retries")
    func retryingCompilesWithSingleImportAndSucceedsAfterRetries() async throws {
        actor Attempts {
            private var count = 0

            func next() -> Int {
                defer { count += 1 }
                return count
            }
        }

        enum ExpectedError: Error {
            case transientFailure
        }

        let attempts = Attempts()

        let value = try await #retrying(
            max: 3,
            backoff: .constant(.milliseconds(1)),
            jitter: .none
        ) {
            let attempt = await attempts.next()

            guard attempt >= 2 else {
                throw ExpectedError.transientFailure
            }

            return 42
        }

        #expect(value == 42)
    }

    @Test("retrying supports operation argument form")
    func retryingSupportsOperationArgumentForm() async throws {
        actor Attempts {
            private var count = 0

            func next() -> Int {
                defer { count += 1 }
                return count
            }
        }

        enum ExpectedError: Error {
            case transientFailure
        }

        let attempts = Attempts()

        let value = try await #retrying(
            max: 1,
            backoff: .none,
            jitter: .none,
            operation: {
                let attempt = await attempts.next()
                if attempt == 0 {
                    throw ExpectedError.transientFailure
                }
                return "ok"
            }
        )

        #expect(value == "ok")
    }

    @Test("retrying surfaces RetryConfigurationError through ConcurrencyMacros import")
    func retryingSurfacesRetryConfigurationErrorAlias() async {
        var capturedError: RetryConfigurationError?

        do {
            _ = try await #retrying(
                max: -1,
                backoff: .none,
                jitter: .none
            ) {
                1
            }
            Issue.record("Expected retry configuration error")
        } catch let error as RetryConfigurationError {
            capturedError = error
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        #expect(capturedError == .negativeMaxRetries(-1))
    }

    @Test("concurrentMap compiles with single import and non-throwing transform")
    func concurrentMapCompilesWithSingleImport() async {
        let values = await #concurrentMap([1, 2, 3], limit: 2) { value in
            value * 2
        }

        #expect(values == [2, 4, 6])
    }

    @Test("concurrentMap supports throwing transform form")
    func concurrentMapSupportsThrowingTransformForm() async throws {
        let values = try await #concurrentMap([1, 2, 3], limit: 2) { value in
            try await Task.sleep(for: .milliseconds(2))
            return value * 3
        }

        #expect(values == [3, 6, 9])
    }

    @Test("concurrentCompactMap compiles with single import")
    func concurrentCompactMapCompilesWithSingleImport() async {
        let values = await #concurrentCompactMap([1, 2, 3, 4], limit: 2) { value in
            value.isMultiple(of: 2) ? value : nil
        }

        #expect(values == [2, 4])
    }

    @Test("concurrentFlatMap compiles with single import and sequence transform output")
    func concurrentFlatMapCompilesWithSingleImport() async {
        let values = await #concurrentFlatMap([1, 2], limit: 2) { value in
            value..<(value + 2)
        }

        #expect(values == [1, 2, 2, 3])
    }

    @Test("concurrentForEach compiles with single import")
    func concurrentForEachCompilesWithSingleImport() async {
        let collector = Collector()

        await #concurrentForEach([10, 20, 30], limit: 2) { value in
            await collector.append(value)
        }

        #expect(await collector.count() == 3)
    }

    @Test("ConcurrencyLimit alias is available with single import")
    func concurrencyLimitAliasIsAvailableWithSingleImport() {
        let fixed: ConcurrencyLimit = 4
        #expect(fixed.resolvedValue == 4)

        switch ConcurrencyLimit.default {
        case .default:
            // Expected.
            break
        case .fixed:
            Issue.record("Expected default limit to be default case")
        }
    }

    @Test("Retry aliases are available with single import")
    func retryAliasesAreAvailableWithSingleImport() {
        let backoff: RetryBackoff = .exponential(
            initial: .milliseconds(100),
            multiplier: 2,
            maxDelay: .seconds(1)
        )
        let jitter: RetryJitter = .full
        let configurationError: RetryConfigurationError = .invalidMultiplier(.infinity)

        switch backoff {
        case .none, .constant:
            Issue.record("Expected exponential backoff case")
        case .exponential(let initial, let multiplier, let maxDelay):
            #expect(initial == .milliseconds(100))
            #expect(multiplier == 2)
            #expect(maxDelay == .seconds(1))
        }

        #expect(jitter == .full)
        #expect(configurationError == .invalidMultiplier(.infinity))
    }
}
