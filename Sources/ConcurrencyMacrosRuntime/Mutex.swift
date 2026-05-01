//
//  Mutex.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 09.03.26.
//

import Foundation
import os.lock

@dynamicMemberLookup
/// Wraps a `Sendable` value behind `OSAllocatedUnfairLock` for synchronized access and mutation.
public final class Mutex<Value: Sendable>: Sendable {
    private let lock: OSAllocatedUnfairLock<Value>

    /// Creates a mutex with an initial value.
    ///
    /// - Parameter value: The initial protected value.
    public init(_ value: Value) {
        lock = .init(initialState: value)
    }

    /// Returns a snapshot of the protected value captured under the lock.
    public var value: Value {
        lock.withLock { $0 }
    }

    @discardableResult
    /// Mutates the protected value while holding the lock.
    ///
    /// - Parameter mutation: A closure that receives the inout protected value.
    /// - Returns: The result produced by `mutation`.
    public func mutate<Result: Sendable>(
        _ mutation: @Sendable (inout Value) throws -> Result
    ) rethrows -> Result {
        try lock.withLock { try mutation(&$0) }
    }

    @discardableResult
    /// Replaces the protected value and returns the previous value.
    ///
    /// - Parameter newValue: The new value to store.
    /// - Returns: The value stored before replacement.
    public func set(_ newValue: Value) -> Value {
        lock.withLock { value in
            let oldValue = value
            value = newValue
            return oldValue
        }
    }

    @discardableResult
    /// Updates one writable member of the protected value and returns its previous value.
    ///
    /// - Parameters:
    ///   - keyPath: A writable key path identifying the member to update.
    ///   - newValue: The replacement member value.
    /// - Returns: The member value before replacement.
    public func set<T: Sendable>(_ keyPath: WritableKeyPath<Value, T>, to newValue: T) -> T {
        let sendableKeyPath = SendableWritableKeyPath(keyPath)
        return lock.withLock { value in
            let oldValue = value[keyPath: sendableKeyPath.keyPath]
            value[keyPath: sendableKeyPath.keyPath] = newValue
            return oldValue
        }
    }

    /// Provides mutable dynamic-member access for writable key paths.
    ///
    /// Reads return a locked snapshot, and writes are performed under the lock.
    public subscript<T: Sendable>(dynamicMember keyPath: WritableKeyPath<Value, T>) -> T {
        get { value[keyPath: keyPath] }
        set {
            let sendableKeyPath = SendableWritableKeyPath(keyPath)
            lock.withLock { value in value[keyPath: sendableKeyPath.keyPath] = newValue }
        }
    }

    /// Provides read-only dynamic-member access for immutable key paths.
    public subscript<T>(dynamicMember keyPath: KeyPath<Value, T>) -> T {
        value[keyPath: keyPath]
    }
}

// MARK: - SendableWritableKeyPath

/// Keeps the unchecked key-path sendability assertion local instead of exporting a retroactive standard-library conformance.
private struct SendableWritableKeyPath<Root: Sendable, Member: Sendable>: @unchecked Sendable {
    let keyPath: WritableKeyPath<Root, Member>

    init(_ keyPath: WritableKeyPath<Root, Member>) {
        self.keyPath = keyPath
    }
}
