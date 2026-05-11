//
//  ThreadSafeDiagnostics.swift
//  ConcurrencyMacros
//
//  Created by Codex on 02.05.26.
//

import SwiftDiagnostics
import SwiftSyntax

/// Diagnostic message emitted when `@ThreadSafe` expansion constraints are violated.
struct ThreadSafeDiagnostic: DiagnosticMessage {
    /// Stable diagnostic identifier suffix.
    let id: String

    /// Human-readable diagnostic text.
    let message: String

    /// Stable diagnostic identifier for tooling and tests.
    var diagnosticID: MessageID {
        MessageID(domain: "ThreadSafeMacro", id: id)
    }

    /// Severity used for invalid source shapes.
    var severity: DiagnosticSeverity {
        .error
    }
}

extension DiagnosticsError {
    /// Creates a diagnostics error containing one `@ThreadSafe` error-level message.
    ///
    /// - Parameters:
    ///   - syntax: Syntax node associated with the diagnostic.
    ///   - id: Stable diagnostic identifier suffix.
    ///   - message: Human-readable diagnostic text.
    init(threadSafe syntax: some SyntaxProtocol, id: String, message: String) {
        self.init(diagnostics: [
            Diagnostic(
                node: Syntax(syntax),
                message: ThreadSafeDiagnostic(id: id, message: message)
            ),
        ])
    }

}
