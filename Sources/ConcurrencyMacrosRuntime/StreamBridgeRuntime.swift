//
//  StreamBridgeRuntime.swift
//  ConcurrencyMacrosRuntime
//
//  Created by Codex on 15.03.26.
//

import Foundation

/// Selects a callback parameter by external argument label.
public enum StreamBridgeSelector: Sendable, Equatable {
    /// Selects a callback parameter whose external label matches `label`.
    case label(String)
}

/// Selects a failure callback and optionally pins the stream failure type.
public enum StreamBridgeFailureSelector {
    /// Selects a callback parameter whose external label matches `label`.
    ///
    /// - Parameters:
    ///   - label: External argument label identifying the failure callback parameter.
    ///   - failureType: Explicit stream failure type.
    case label(String, as: any Error.Type)
}

/// Configures cancellation cleanup behavior for generated stream bridges.
public enum StreamBridgeCancellation: Sendable, Equatable {
    /// No cancellation cleanup is performed on stream termination.
    case none

    /// Invokes an instance method on the owner with the registration token.
    ///
    /// - Parameters:
    ///   - name: Method name to call on the owner.
    ///   - argumentLabel: External argument label to use for token forwarding.
    ///     Use `"_"` for unlabeled arguments.
    case ownerMethod(String, argumentLabel: String = "_")

    /// Invokes `cancelStreamBridgeToken()` on the registration token.
    case tokenMethod
}

/// Configures stream buffering for generated stream bridges.
public enum StreamBridgeBuffering: Sendable, Equatable {
    /// Uses unbounded buffering.
    case unbounded

    /// Drops oldest buffered values when capacity is reached.
    case bufferingOldest(Int)

    /// Keeps only the newest values when capacity is reached.
    case bufferingNewest(Int)
}

/// Configures sendability enforcement for generated stream bridges.
public enum StreamBridgeSafety: Sendable, Equatable {
    /// Enforces strict sendability checks in generated code.
    case strict

    /// Skips generated sendability checks.
    case unchecked
}

/// Token protocol used by `.tokenMethod` cancellation mode.
public protocol StreamBridgeTokenCancellable {
    /// Performs cancellation cleanup for an active stream registration token.
    func cancelStreamBridgeToken()
}

/// Namespace for runtime helpers used by stream-bridge macros.
public enum StreamBridgeRuntime {
    /// Builds an `AsyncStream` from callback registration logic.
    ///
    /// The helper guarantees:
    /// - termination cleanup runs at most once,
    /// - termination-before-token-install races are handled safely,
    /// - completion is idempotent.
    ///
    /// - Parameters:
    ///   - bufferingPolicy: Buffering policy applied to the stream continuation.
    ///   - register: Registration function that receives event and completion callbacks and returns a token.
    ///   - cancel: Optional cancellation cleanup closure invoked with the token.
    /// - Returns: A bridged async stream.
    public static func makeStream<Event: Sendable, Token>(
        bufferingPolicy: AsyncStream<Event>.Continuation.BufferingPolicy = .unbounded,
        register: (
            _ onEvent: @escaping @Sendable (Event) -> Void,
            _ onCompletion: @escaping @Sendable () -> Void
        ) -> Token,
        cancel: (@Sendable (Token) -> Void)? = nil
    ) -> AsyncStream<Event> {
        AsyncStream(bufferingPolicy: bufferingPolicy) { continuation in
            let terminationState = StreamBridgeTerminationState<Token>(cancel: cancel)

            continuation.onTermination = { _ in
                terminationState.terminate()
            }

            let token = register(
                { event in
                    continuation.yield(event)
                },
                {
                    terminationState.finish {
                        continuation.finish()
                    }
                }
            )

            terminationState.install(token: token)
        }
    }

    /// Builds an unchecked `AsyncStream` bridge.
    ///
    /// Use this only when strict sendability checks are intentionally disabled.
    public static func makeStreamUnchecked<Event, Token>(
        bufferingPolicy: AsyncStream<Event>.Continuation.BufferingPolicy = .unbounded,
        register: (
            _ onEvent: @escaping (sending Event) -> Void,
            _ onCompletion: @escaping () -> Void
        ) -> Token,
        cancel: ((Token) -> Void)? = nil
    ) -> AsyncStream<Event> {
        AsyncStream(bufferingPolicy: bufferingPolicy) { continuation in
            let terminationState = StreamBridgeTerminationStateUnchecked<Token>(cancel: cancel)

            continuation.onTermination = { _ in
                terminationState.terminate()
            }

            let token = register(
                { event in
                    continuation.yield(event)
                },
                {
                    terminationState.finish {
                        continuation.finish()
                    }
                }
            )

            terminationState.install(token: token)
        }
    }

    /// Builds an `AsyncThrowingStream` from callback registration logic.
    ///
    /// The helper guarantees:
    /// - termination cleanup runs at most once,
    /// - termination-before-token-install races are handled safely,
    /// - completion/failure is idempotent.
    ///
    /// - Parameters:
    ///   - bufferingPolicy: Buffering policy applied to the stream continuation.
    ///   - register: Registration function that receives event, failure, and completion callbacks and returns a token.
    ///   - cancel: Optional cancellation cleanup closure invoked with the token.
    /// - Returns: A bridged async throwing stream.
    public static func makeThrowingStream<Event: Sendable, Failure: Error & Sendable, Token>(
        bufferingPolicy: AsyncThrowingStream<Event, any Error>.Continuation.BufferingPolicy = .unbounded,
        register: (
            _ onEvent: @escaping @Sendable (Event) -> Void,
            _ onFailure: @escaping @Sendable (Failure) -> Void,
            _ onCompletion: @escaping @Sendable () -> Void
        ) -> Token,
        cancel: (@Sendable (Token) -> Void)? = nil
    ) -> AsyncThrowingStream<Event, any Error> {
        AsyncThrowingStream<Event, any Error>(bufferingPolicy: bufferingPolicy) { continuation in
            let terminationState = StreamBridgeTerminationState<Token>(cancel: cancel)

            continuation.onTermination = { _ in
                terminationState.terminate()
            }

            let token = register(
                { event in
                    continuation.yield(event)
                },
                { failure in
                    terminationState.finish {
                        continuation.finish(throwing: failure)
                    }
                },
                {
                    terminationState.finish {
                        continuation.finish()
                    }
                }
            )

            terminationState.install(token: token)
        }
    }

    /// Builds an unchecked `AsyncThrowingStream` bridge.
    ///
    /// Use this only when strict sendability checks are intentionally disabled.
    public static func makeThrowingStreamUnchecked<Event, Failure: Error, Token>(
        bufferingPolicy: AsyncThrowingStream<Event, any Error>.Continuation.BufferingPolicy = .unbounded,
        register: (
            _ onEvent: @escaping (sending Event) -> Void,
            _ onFailure: @escaping (sending Failure) -> Void,
            _ onCompletion: @escaping () -> Void
        ) -> Token,
        cancel: ((Token) -> Void)? = nil
    ) -> AsyncThrowingStream<Event, any Error> {
        AsyncThrowingStream<Event, any Error>(bufferingPolicy: bufferingPolicy) { continuation in
            let terminationState = StreamBridgeTerminationStateUnchecked<Token>(cancel: cancel)

            continuation.onTermination = { _ in
                terminationState.terminate()
            }

            let token = register(
                { event in
                    continuation.yield(event)
                },
                { failure in
                    terminationState.finish {
                        continuation.finish(throwing: failure)
                    }
                },
                {
                    terminationState.finish {
                        continuation.finish()
                    }
                }
            )

            terminationState.install(token: token)
        }
    }
}

// MARK: - Termination State

private final class StreamBridgeTerminationState<Token>: @unchecked Sendable {
    private enum TokenState {
        case pending
        case installed(Token)
    }

    private let lock = NSLock()
    private let cancel: (@Sendable (Token) -> Void)?
    private var tokenState: TokenState = .pending
    private var isTerminated = false
    private var isFinished = false

    init(cancel: (@Sendable (Token) -> Void)?) {
        self.cancel = cancel
    }

    func install(token: Token) {
        var cancellation: ((@Sendable (Token) -> Void, Token))?

        lock.lock()
        if isTerminated {
            if let cancel {
                cancellation = (cancel, token)
            }
        } else {
            tokenState = .installed(token)
        }
        lock.unlock()

        if let cancellation {
            cancellation.0(cancellation.1)
        }
    }

    func terminate() {
        var cancellation: ((@Sendable (Token) -> Void, Token))?

        lock.lock()
        if !isTerminated {
            isTerminated = true

            if case .installed(let token) = tokenState, let cancel {
                cancellation = (cancel, token)
            }
        }
        lock.unlock()

        if let cancellation {
            cancellation.0(cancellation.1)
        }
    }

    func finish(_ finishAction: () -> Void) {
        var shouldFinish = false

        lock.lock()
        if !isFinished {
            isFinished = true
            shouldFinish = true
        }
        lock.unlock()

        if shouldFinish {
            finishAction()
        }
    }
}

private final class StreamBridgeTerminationStateUnchecked<Token>: @unchecked Sendable {
    private enum TokenState {
        case pending
        case installed(Token)
    }

    private let lock = NSLock()
    private let cancel: ((Token) -> Void)?
    private var tokenState: TokenState = .pending
    private var isTerminated = false
    private var isFinished = false

    init(cancel: ((Token) -> Void)?) {
        self.cancel = cancel
    }

    func install(token: Token) {
        var cancellation: (((Token) -> Void, Token))?

        lock.lock()
        if isTerminated {
            if let cancel {
                cancellation = (cancel, token)
            }
        } else {
            tokenState = .installed(token)
        }
        lock.unlock()

        if let cancellation {
            cancellation.0(cancellation.1)
        }
    }

    func terminate() {
        var cancellation: (((Token) -> Void, Token))?

        lock.lock()
        if !isTerminated {
            isTerminated = true

            if case .installed(let token) = tokenState, let cancel {
                cancellation = (cancel, token)
            }
        }
        lock.unlock()

        if let cancellation {
            cancellation.0(cancellation.1)
        }
    }

    func finish(_ finishAction: () -> Void) {
        var shouldFinish = false

        lock.lock()
        if !isFinished {
            isFinished = true
            shouldFinish = true
        }
        lock.unlock()

        if shouldFinish {
            finishAction()
        }
    }
}
