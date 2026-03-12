//
//  ConcurrencyLimitTests.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 12.03.26.
//

import Testing
@testable import ConcurrencyMacrosRuntime

@Suite("ConcurrencyLimit")
struct ConcurrencyLimitTests {
    @Test("Integer literal creates fixed concurrency limit")
    func integerLiteralCreatesFixedConcurrencyLimit() {
        let limit: ConcurrencyLimit = 4

        switch limit {
        case .default:
            Issue.record("Expected fixed limit for integer literal")
        case .fixed(let value):
            #expect(value == 4)
        }
    }

    @Test("Default limit case resolves to default mode")
    func defaultLimitCaseResolvesToDefaultMode() {
        switch ConcurrencyLimit.default {
        case .default:
            // Expected.
            break
        case .fixed:
            Issue.record("Expected default limit to be default case")
        }
    }

    @Test("Resolved fixed values are clamped to at least one")
    func resolvedFixedValuesAreClampedToAtLeastOne() {
        #expect(ConcurrencyLimit.fixed(5).resolvedValue == 5)
        #expect(ConcurrencyLimit.fixed(0).resolvedValue == 1)
        #expect(ConcurrencyLimit.fixed(-3).resolvedValue == 1)
    }

    @Test("Default resolved value is always at least one")
    func defaultResolvedValueIsAlwaysAtLeastOne() {
        #expect(ConcurrencyLimit.default.resolvedValue >= 1)
    }
}
