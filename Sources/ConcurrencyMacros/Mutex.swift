//
//  Mutex.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 09.03.26.
//

import Foundation
import os.lock

@dynamicMemberLookup
public final class Mutex<Value: Sendable>: Sendable {
    private let lock: OSAllocatedUnfairLock<Value>

    public init(_ value: Value) {
        lock = .init(initialState: value)
    }

    public var value: Value {
        lock.withLock { $0 }
    }

    @discardableResult
    public func mutate<Result: Sendable>(
        _ mutation: @Sendable (inout Value) throws -> Result
    ) rethrows -> Result {
        try lock.withLock { try mutation(&$0) }
    }

    /// Set to the new value and return the old value.
    @discardableResult
    public func set(_ newValue: Value) -> Value {
        lock.withLock { value in
            let oldValue = value
            value = newValue
            return oldValue
        }
    }

    /// Set property to the new value and return the old value.
    @discardableResult
    public func set<T: Sendable>(_ keyPath: WritableKeyPath<Value, T>, to newValue: T) -> T {
        lock.withLock { value in
            let oldValue = value[keyPath: keyPath]
            value[keyPath: keyPath] = newValue
            return oldValue
        }
    }

    public subscript<T: Sendable>(dynamicMember keyPath: WritableKeyPath<Value, T>) -> T {
        get { value[keyPath: keyPath] }
        set { lock.withLock { value in value[keyPath: keyPath] = newValue } }
    }

    public subscript<T>(dynamicMember keyPath: KeyPath<Value, T>) -> T {
        value[keyPath: keyPath]
    }
}

// MARK: - KeyPath + @unchecked @retroactive Sendable

extension KeyPath: @unchecked @retroactive Sendable where Root: Sendable, Value: Sendable { }
