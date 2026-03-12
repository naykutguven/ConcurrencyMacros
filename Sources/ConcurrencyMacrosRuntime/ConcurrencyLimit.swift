//
//  ConcurrencyLimit.swift
//  ConcurrencyMacrosRuntime
//
//  Created by Aykut Güven on 12.03.26.
//

import Foundation

/// Controls the maximum number of child tasks that may run simultaneously.
///
/// Use this type with bounded-concurrency runtime helpers to control
/// in-flight task count.
public enum ConcurrencyLimit: Sendable, ExpressibleByIntegerLiteral {
    /// Uses the package default heuristic:
    /// `max(1, ProcessInfo.processInfo.activeProcessorCount - 1)`.
    case `default`

    /// Uses a fixed upper bound for in-flight child tasks.
    ///
    /// - Parameter value: Desired in-flight task cap. Values less than `1`
    /// are clamped to `1` when resolved.
    case fixed(Int)

    /// Creates a fixed concurrency limit from an integer literal.
    ///
    /// - Parameter value: The integer literal value used to create
    /// `ConcurrencyLimit.fixed(value)`.
    public init(integerLiteral value: Int) {
        self = .fixed(value)
    }

    /// Resolves the effective in-flight task limit, clamped to at least `1`.
    ///
    /// - Returns: The normalized in-flight task limit used by runtime helpers.
    public var resolvedValue: Int {
        switch self {
        case .default:
            max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
        case .fixed(let value):
            max(1, value)
        }
    }
}
