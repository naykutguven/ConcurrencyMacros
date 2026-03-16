//
//  RuntimeExports.swift
//  ConcurrencyMacros
//
//  Created by Aykut Güven on 11.03.26.
//

import ConcurrencyMacrosRuntime

/// Keeps macro consumers on a single `import ConcurrencyMacros` by surfacing
/// only the runtime symbols referenced by macro-generated code.

/// Backward-compatible alias used by macro-generated code in client modules.
public typealias Mutex<Value: Sendable> = ConcurrencyMacrosRuntime.Mutex<Value>

/// Backward-compatible alias used by macro-generated initializer metadata.
public typealias TypeErased<T> = ConcurrencyMacrosRuntime.TypeErased<T>

/// Namespace for runtime helpers referenced by freestanding macro expansions.
public typealias ConcurrencyRuntime = ConcurrencyMacrosRuntime.ConcurrencyRuntime

/// Public limit type shared by bounded-concurrency runtime helpers and freestanding macros.
public typealias ConcurrencyLimit = ConcurrencyMacrosRuntime.ConcurrencyLimit

/// Timeout error surfaced by `#withTimeout` and runtime timeout helpers.
public typealias TimeoutError = ConcurrencyMacrosRuntime.ConcurrencyRuntime.TimeoutError

/// Retry backoff strategy surfaced by `#retrying` and runtime retry helpers.
public typealias RetryBackoff = ConcurrencyMacrosRuntime.RetryBackoff

/// Retry jitter strategy surfaced by `#retrying` and runtime retry helpers.
public typealias RetryJitter = ConcurrencyMacrosRuntime.RetryJitter

/// Retry configuration error surfaced by `#retrying` and runtime retry helpers.
public typealias RetryConfigurationError = ConcurrencyMacrosRuntime.ConcurrencyRuntime.RetryConfigurationError

/// Selector used by `@StreamBridge` to identify callback parameters.
public typealias StreamBridgeSelector = ConcurrencyMacrosRuntime.StreamBridgeSelector

/// Failure selector used by `@StreamBridge` for throwing stream generation.
public typealias StreamBridgeFailureSelector = ConcurrencyMacrosRuntime.StreamBridgeFailureSelector

/// Cancellation strategy used by `@StreamBridge` and `@StreamBridgeDefaults`.
public typealias StreamBridgeCancellation = ConcurrencyMacrosRuntime.StreamBridgeCancellation

/// Buffering configuration used by `@StreamBridge` and `@StreamBridgeDefaults`.
public typealias StreamBridgeBuffering = ConcurrencyMacrosRuntime.StreamBridgeBuffering

/// Sendability safety mode used by `@StreamBridge` and `@StreamBridgeDefaults`.
public typealias StreamBridgeSafety = ConcurrencyMacrosRuntime.StreamBridgeSafety

/// Token protocol used by `@StreamBridge` token-method cancellation mode.
public typealias StreamBridgeTokenCancellable = ConcurrencyMacrosRuntime.StreamBridgeTokenCancellable

/// Runtime helpers used by generated `@StreamBridge` methods.
public typealias StreamBridgeRuntime = ConcurrencyMacrosRuntime.StreamBridgeRuntime

/// Cancellation policy used by single-flight runtime stores.
public typealias SingleFlightCancellationPolicy = ConcurrencyMacrosRuntime.SingleFlightCancellationPolicy

/// Non-throwing runtime single-flight store surfaced for macro-generated code.
public typealias SingleFlightStore<Value: Sendable> = ConcurrencyMacrosRuntime.SingleFlightStore<Value>

/// Throwing runtime single-flight store surfaced for macro-generated code.
public typealias ThrowingSingleFlightStore<Value: Sendable> = ConcurrencyMacrosRuntime.ThrowingSingleFlightStore<Value>

/// Compile-time helper used by generated single-flight wrappers to enforce sendable captures.
@inlinable
public func __singleFlightRequireSendable<T: Sendable>(_ value: T) {}

/// Compile-time helper used by generated stream-bridge wrappers to enforce sendable captures.
@inlinable
public func __streamBridgeRequireSendable<T: Sendable>(_ value: T) {}
