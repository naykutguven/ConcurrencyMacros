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

    @Test("SingleFlightActor compiles with single import and deduplicates same key")
    func singleFlightActorCompilesWithSingleImportAndDeduplicatesSameKey() async throws {
        let service = AvatarService()

        async let first = service.loadAvatar(userID: 1)
        async let second = service.loadAvatar(userID: 1)
        async let third = service.loadAvatar(userID: 1)

        let firstValue = try await first
        let secondValue = try await second
        let thirdValue = try await third

        #expect(firstValue == 1)
        #expect(secondValue == 1)
        #expect(thirdValue == 1)
        #expect(await service.executionCount() == 1)
    }

    @Test("SingleFlightActor using shared store supports intentional cross-method dedupe")
    func singleFlightActorUsingSharedStoreDedupesAcrossMethods() async {
        let service = SharedStoreService()

        async let first = service.first(id: 1)
        async let second = service.second(id: 1)

        let firstValue = await first
        let secondValue = await second

        #expect(firstValue == 1)
        #expect(secondValue == 1)
        #expect(await service.executionCount() == 1)
    }

    @Test("SingleFlightActor defaults to per-method stores and does not cross-dedupe methods")
    func singleFlightActorDefaultsToPerMethodStores() async {
        let service = PerMethodStoreService()

        async let first = service.first(id: 1)
        async let second = service.second(id: 1)

        let firstValue = await first
        let secondValue = await second
        let counts = await service.executionCounts()

        #expect(firstValue == 1)
        #expect(secondValue == 1)
        #expect(counts.0 == 1)
        #expect(counts.1 == 1)
    }

    @Test("SingleFlightClass compiles with single import and deduplicates same key")
    func singleFlightClassCompilesWithSingleImportAndDeduplicatesSameKey() async throws {
        let service = ClassAvatarService()

        async let first = service.loadAvatar(userID: 1)
        async let second = service.loadAvatar(userID: 1)
        async let third = service.loadAvatar(userID: 1)

        let firstValue = try await first
        let secondValue = try await second
        let thirdValue = try await third

        #expect(firstValue == 1)
        #expect(secondValue == 1)
        #expect(thirdValue == 1)
        #expect(await service.executionCount() == 1)
    }

    @Test("SingleFlightClass using shared store supports intentional cross-method dedupe")
    func singleFlightClassUsingSharedStoreDedupesAcrossMethods() async {
        let service = SharedStoreClassService()

        async let first = service.first(id: 1)
        async let second = service.second(id: 1)

        let firstValue = await first
        let secondValue = await second

        #expect(firstValue == 1)
        #expect(secondValue == 1)
        #expect(await service.executionCount() == 1)
    }

    @Test("SingleFlightClass separate stores do not cross-dedupe methods")
    func singleFlightClassSeparateStoresDoNotCrossDedupeMethods() async {
        let service = SeparateStoreClassService()

        async let first = service.first(id: 1)
        async let second = service.second(id: 1)

        let firstValue = await first
        let secondValue = await second
        let counts = await service.executionCounts()

        #expect(firstValue == 1)
        #expect(secondValue == 1)
        #expect(counts.0 == 1)
        #expect(counts.1 == 1)
    }

    @Test("ConcurrencyLimit alias is available with single import")
    func concurrencyLimitAliasIsAvailableWithSingleImport() {
        let fixed: ConcurrencyLimit = 4
        #expect(fixed.resolvedValue == 4)
    }

    @Test("Retry aliases are available with single import")
    func retryAliasesAreAvailableWithSingleImport() async {
        let backoff: RetryBackoff = .none
        let jitter: RetryJitter = .none
        var capturedError: RetryConfigurationError?

        do {
            _ = try await ConcurrencyRuntime.retrying(
                max: -1,
                backoff: backoff,
                jitter: jitter
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

    @Test("StreamBridge generates AsyncStream wrappers that clean up token cancellation")
    func streamBridgeGeneratesAsyncStreamWrappersThatCleanUpTokenCancellation() async {
        let ticker = PriceTicker(value: 42)

        let received = await Task<Int?, Never> {
            for await price in ticker.priceStream(symbol: "AAPL") {
                return price
            }
            return nil
        }.value

        #expect(received == 42)
        #expect(ticker.cancelledCount() == 1)
    }

    @Test("StreamBridge generates throwing stream wrappers with erased error type")
    func streamBridgeGeneratesThrowingStreamWrappersWithErasedErrorType() async {
        let socket = SocketBridge()
        let stream = socket.messageStream()

        var capturedFailure: BridgeFailure?
        do {
            for try await _ in stream {}
            Issue.record("Expected typed stream failure")
        } catch let failure as BridgeFailure {
            capturedFailure = failure
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        #expect(capturedFailure == .disconnected)
        #expect(socket.cancelledCount() == 1)
    }

    @Test("Freestanding macros compile when client shadows runtime namespace")
    func freestandingMacrosCompileWhenClientShadowsRuntimeNamespace() async throws {
        let result = try await NamespaceCollisionFixtures.runFreestandingMacros()

        #expect(result.timeout == 42)
        #expect(result.retry == "ok")
        #expect(result.mapped == [2, 4, 6])
        #expect(result.compacted == [2, 4])
        #expect(result.flattened == [1, 2, 2, 3])
        #expect(result.forEachCount == 3)
    }

    @Test("ThreadSafe compiles when client shadows runtime aliases")
    func threadSafeCompilesWhenClientShadowsRuntimeAliases() {
        let initialized = NamespaceCollisionFixtures.InitializedCounter(count: 1)
        initialized.count = 2
        initialized.label = "next"

        #expect(initialized.count == 2)
        #expect(initialized.label == "next")

        let defaulted = NamespaceCollisionFixtures.DefaultedCounter()
        defaulted.count = 4

        #expect(defaulted.count == 4)
    }
}

private enum NamespaceCollisionFixtures {
    enum ConcurrencyRuntime {}
    enum Mutex<Value: Sendable> {}
    enum TypeErased<Value> {}

    @ThreadSafe
    final class InitializedCounter {
        var count: Int
        var label = "seed"

        init(count: Int) {
            self.count = count
        }
    }

    @ThreadSafe
    final class DefaultedCounter {
        var count: Int = 0
    }

    actor Collector {
        private var values: [Int] = []

        func append(_ value: Int) {
            values.append(value)
        }

        func count() -> Int {
            values.count
        }
    }

    static func runFreestandingMacros() async throws -> (
        timeout: Int,
        retry: String,
        mapped: [Int],
        compacted: [Int],
        flattened: [Int],
        forEachCount: Int
    ) {
        let timeout = try await #withTimeout(.seconds(1)) {
            42
        }

        let retry = try await #retrying(
            max: 0,
            backoff: .none,
            jitter: .none
        ) {
            "ok"
        }

        let mapped = await #concurrentMap([1, 2, 3], limit: 2) { value in
            value * 2
        }

        let compacted: [Int] = await #concurrentCompactMap([1, 2, 3, 4], limit: 2) { value in
            value.isMultiple(of: 2) ? value : nil
        }

        let flattened = await #concurrentFlatMap([1, 2], limit: 2) { value in
            value..<(value + 2)
        }

        let collector = Collector()
        await #concurrentForEach([10, 20, 30], limit: 2) { value in
            await collector.append(value)
        }

        return (
            timeout: timeout,
            retry: retry,
            mapped: mapped,
            compacted: compacted,
            flattened: flattened,
            forEachCount: await collector.count()
        )
    }
}

private actor AvatarService {
    private var executions = 0

    @SingleFlightActor(key: { (userID: Int) in userID })
    func loadAvatar(userID: Int) async throws -> Int {
        executions += 1
        try await Task.sleep(for: .milliseconds(25))
        return userID
    }

    func executionCount() -> Int {
        executions
    }
}

private let sharedStoreServiceFlights = SingleFlightStore<Int>()
private let classAvatarFlights = ThrowingSingleFlightStore<Int>()
private let sharedStoreClassFlights = SingleFlightStore<Int>()
private let separateStoreClassFirstFlights = SingleFlightStore<Int>()
private let separateStoreClassSecondFlights = SingleFlightStore<Int>()

private actor SharedStoreService {
    private var executions = 0

    @SingleFlightActor(key: { (id: Int) in id }, using: sharedStoreServiceFlights)
    func first(id: Int) async -> Int {
        executions += 1
        await Task.yield()
        return id
    }

    @SingleFlightActor(key: { (id: Int) in id }, using: sharedStoreServiceFlights)
    func second(id: Int) async -> Int {
        executions += 1
        await Task.yield()
        return id
    }

    func executionCount() -> Int {
        executions
    }
}

private actor PerMethodStoreService {
    private var firstExecutions = 0
    private var secondExecutions = 0

    @SingleFlightActor(key: { (id: Int) in id })
    func first(id: Int) async -> Int {
        firstExecutions += 1
        await Task.yield()
        return id
    }

    @SingleFlightActor(key: { (id: Int) in id })
    func second(id: Int) async -> Int {
        secondExecutions += 1
        await Task.yield()
        return id
    }

    func executionCounts() -> (Int, Int) {
        (firstExecutions, secondExecutions)
    }
}

private actor ClassCounterActor {
    private var value = 0

    func increment() {
        value += 1
    }

    func current() -> Int {
        value
    }
}

private actor ClassDualCounterActor {
    private var first = 0
    private var second = 0

    func incrementFirst() {
        first += 1
    }

    func incrementSecond() {
        second += 1
    }

    func counts() -> (Int, Int) {
        (first, second)
    }
}

private final class ClassAvatarService: Sendable {
    private let executions = ClassCounterActor()

    @SingleFlightClass(key: { (userID: Int) in userID }, using: classAvatarFlights)
    func loadAvatar(userID: Int) async throws -> Int {
        await executions.increment()
        try await Task.sleep(for: .milliseconds(25))
        return userID
    }

    func executionCount() async -> Int {
        await executions.current()
    }
}

private final class SharedStoreClassService: Sendable {
    private let executions = ClassCounterActor()

    @SingleFlightClass(key: { (id: Int) in id }, using: sharedStoreClassFlights)
    func first(id: Int) async -> Int {
        await executions.increment()
        await Task.yield()
        return id
    }

    @SingleFlightClass(key: { (id: Int) in id }, using: sharedStoreClassFlights)
    func second(id: Int) async -> Int {
        await executions.increment()
        await Task.yield()
        return id
    }

    func executionCount() async -> Int {
        await executions.current()
    }
}

private final class SeparateStoreClassService: Sendable {
    private let counters = ClassDualCounterActor()

    @SingleFlightClass(key: { (id: Int) in id }, using: separateStoreClassFirstFlights)
    func first(id: Int) async -> Int {
        await counters.incrementFirst()
        await Task.yield()
        return id
    }

    @SingleFlightClass(key: { (id: Int) in id }, using: separateStoreClassSecondFlights)
    func second(id: Int) async -> Int {
        await counters.incrementSecond()
        await Task.yield()
        return id
    }

    func executionCounts() async -> (Int, Int) {
        await counters.counts()
    }
}

@StreamToken(cancelMethod: "invalidate")
private final class BridgeObservationToken: Sendable {
    private let onCancel: @Sendable () -> Void

    init(onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    func invalidate() {
        onCancel()
    }
}

private enum BridgeFailure: Error, Equatable, Sendable {
    case disconnected
}

@StreamBridgeDefaults(cancel: .tokenMethod, buffering: .bufferingNewest(1))
private final class PriceTicker: Sendable {
    private let value: Int
    private let cancelCount = Mutex(0)

    init(value: Int) {
        self.value = value
    }

    @StreamBridge(as: "priceStream", event: .label("handler"))
    func observePrice(
        symbol: String,
        handler: @escaping @Sendable (Int) -> Void
    ) -> BridgeObservationToken {
        _ = symbol
        handler(value)
        return BridgeObservationToken {
            self.cancelCount.mutate { count in
                count += 1
            }
        }
    }

    func cancelledCount() -> Int {
        cancelCount.value
    }
}

@StreamBridgeDefaults(cancel: .tokenMethod, buffering: .bufferingNewest(1))
private final class SocketBridge: Sendable {
    private let cancelCount = Mutex(0)

    @StreamBridge(
        as: "messageStream",
        event: .label("onMessage"),
        failure: .label("onError", as: BridgeFailure.self),
        completion: .label("onClose")
    )
    func connect(
        onMessage: @escaping @Sendable (String) -> Void,
        onError: @escaping @Sendable (BridgeFailure) -> Void,
        onClose: @escaping @Sendable () -> Void
    ) -> BridgeObservationToken {
        _ = onMessage
        onError(.disconnected)
        onClose()
        return BridgeObservationToken {
            self.cancelCount.mutate { count in
                count += 1
            }
        }
    }

    func cancelledCount() -> Int {
        cancelCount.value
    }
}
