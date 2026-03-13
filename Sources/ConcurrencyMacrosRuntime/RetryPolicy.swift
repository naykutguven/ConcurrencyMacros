//
//  RetryPolicy.swift
//  ConcurrencyMacrosRuntime
//
//  Created by Aykut Güven on 12.03.26.
//

/// Backoff strategy used by retry helpers.
public enum RetryBackoff: Sendable, Equatable {
    /// Retries immediately without any delay.
    case none

    /// Uses the same delay for every retry attempt.
    ///
    /// - Parameter delay: Delay applied before each retry. Must be greater than zero.
    case constant(Duration)

    /// Uses exponentially increasing delays between retry attempts.
    ///
    /// - Parameters:
    ///   - initial: Delay before the first retry. Must be greater than zero.
    ///   - multiplier: Growth factor applied after each retry. Must be finite and greater than one.
    ///   - maxDelay: Optional upper bound for delays. When provided, must be greater than zero and
    ///     not less than `initial`.
    case exponential(
        initial: Duration,
        multiplier: Double = 2,
        maxDelay: Duration? = nil
    )
}

/// Jitter strategy used by retry helpers.
public enum RetryJitter: Sendable, Equatable {
    /// Applies no jitter.
    case none

    /// Applies full jitter: a random delay in the range `[0, baseDelay]`.
    case full
}
