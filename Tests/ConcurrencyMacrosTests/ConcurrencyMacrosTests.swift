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
}
