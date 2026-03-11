//
//  TypeErasedTests.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 11.03.26.
//

import Testing
@testable import ConcurrencyMacrosRuntime

@Suite("TypeErased")
struct TypeErasedTests {
    @Test("Stores non-nil value")
    func storesNonNilValue() {
        let value = TypeErased<Int>(value: 42)

        #expect(value.value == 42)
    }

    @Test("Default initializer stores nil")
    func defaultInitializerStoresNil() {
        let value = TypeErased<String>()

        #expect(value.value == nil)
    }

    @Test("Supports optional payload values")
    func supportsOptionalPayloadValues() {
        let explicitNil = TypeErased<String?>(value: nil)
        let wrappedValue = TypeErased<String?>(value: "hello")

        #expect(explicitNil.value == nil)
        #expect(wrappedValue.value == "hello")
    }
}
