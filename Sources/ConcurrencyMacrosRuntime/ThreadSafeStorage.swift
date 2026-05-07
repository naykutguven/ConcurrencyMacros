//
//  ThreadSafeStorage.swift
//  ConcurrencyMacros
//

import os.lock

/// Compile-time helper for generated `@ThreadSafe` code that requires checked property sendability.
public enum ThreadSafeSendabilityCheck<Value: Sendable> {}

/// Checked storage used by generated `@ThreadSafe` code.
///
/// The unchecked sendability assertion is safe because all access to `State` is serialized by the
/// shared lock core, and checked APIs only expose `Sendable` members or locked inout mutation.
public final class ThreadSafeStorage<State: Sendable>: @unchecked Sendable {
    private let core: ThreadSafeStorageCore<State>

    /// Creates storage with an initial state value.
    public init(_ initialState: State) {
        core = ThreadSafeStorageCore(initialState)
    }

    /// Reads a member snapshot while holding the storage lock.
    public func read<Member: Sendable>(_ keyPath: KeyPath<State, Member>) -> Member {
        core.read(keyPath)
    }

    /// Writes a member while holding the storage lock.
    public func write<Member: Sendable>(
        _ keyPath: WritableKeyPath<State, Member>,
        _ newValue: Member
    ) {
        core.write(keyPath, newValue)
    }

    @discardableResult
    /// Mutates the whole state while holding the storage lock.
    public func withLock<Result: Sendable>(
        _ body: @Sendable (inout State) throws -> Result
    ) rethrows -> Result {
        try core.withLock(body)
    }

    /// Provides locked member access for generated modify accessors.
    ///
    /// `_modify` intentionally holds the unfair lock across the yielded inout member mutation.
    public subscript<Member: Sendable>(modifying keyPath: WritableKeyPath<State, Member>) -> Member {
        _read {
            yield core.read(keyPath)
        }
        _modify {
            yield &core[modifying: keyPath]
        }
    }
}

/// Unchecked storage used by generated `@ThreadSafe` code for explicitly unchecked owners.
///
/// The unchecked sendability assertion is local to this wrapper: callers only get synchronized
/// access, and the macro selects this type only when the owning declaration accepts unchecked
/// sendability responsibility.
public final class UncheckedThreadSafeStorage<State>: @unchecked Sendable {
    private let core: ThreadSafeStorageCore<State>

    /// Creates storage with an initial state value.
    public init(_ initialState: State) {
        core = ThreadSafeStorageCore(initialState)
    }

    /// Reads a member snapshot while holding the storage lock.
    public func read<Member>(_ keyPath: KeyPath<State, Member>) -> Member {
        core.read(keyPath)
    }

    /// Writes a member while holding the storage lock.
    public func write<Member>(
        _ keyPath: WritableKeyPath<State, Member>,
        _ newValue: Member
    ) {
        core.write(keyPath, newValue)
    }

    @discardableResult
    /// Mutates the whole state while holding the storage lock.
    public func withLock<Result>(_ body: (inout State) throws -> Result) rethrows -> Result {
        try core.withLock(body)
    }

    /// Provides locked member access for generated modify accessors.
    ///
    /// `_modify` intentionally holds the unfair lock across the yielded inout member mutation.
    public subscript<Member>(modifying keyPath: WritableKeyPath<State, Member>) -> Member {
        _read {
            yield core.read(keyPath)
        }
        _modify {
            yield &core[modifying: keyPath]
        }
    }
}

// MARK: - ThreadSafeStorageCore

/// Shared storage core that keeps pointer-backed state alive while accessors yield under lock.
private final class ThreadSafeStorageCore<State>: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private let pointer: UnsafeMutablePointer<State>

    init(_ initialState: State) {
        pointer = .allocate(capacity: 1)
        pointer.initialize(to: initialState)
    }

    deinit {
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }

    func read<Member>(_ keyPath: KeyPath<State, Member>) -> Member {
        lock.lock()
        defer { lock.unlock() }
        return pointer.pointee[keyPath: keyPath]
    }

    func write<Member>(_ keyPath: WritableKeyPath<State, Member>, _ newValue: Member) {
        lock.lock()
        defer { lock.unlock() }
        pointer.pointee[keyPath: keyPath] = newValue
    }

    @discardableResult
    func withLock<Result>(_ body: (inout State) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&pointer.pointee)
    }

    subscript<Member>(modifying keyPath: WritableKeyPath<State, Member>) -> Member {
        _read {
            lock.lock()
            defer { lock.unlock() }
            yield pointer.pointee[keyPath: keyPath]
        }
        _modify {
            lock.lock()
            defer { lock.unlock() }
            yield &pointer.pointee[keyPath: keyPath]
        }
    }
}
