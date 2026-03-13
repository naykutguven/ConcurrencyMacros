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
