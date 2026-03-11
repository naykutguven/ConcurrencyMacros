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
}
