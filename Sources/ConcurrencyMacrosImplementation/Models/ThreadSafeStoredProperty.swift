//
//  ThreadSafeStoredProperty.swift
//  ConcurrencyMacros
//
//  Created by Codex on 02.05.26.
//

import Foundation
import SwiftSyntax

/// Macro-internal metadata for a mutable stored property tracked by `@ThreadSafe`.
struct ThreadSafeStoredProperty {
    /// Source token for the stored property's identifier.
    let name: TokenSyntax

    /// Type used for the synthesized `_State` field and staging local.
    let type: TypeSyntax

    /// Initial value used when the source property has a default or optional fallback.
    let defaultValue: ExprSyntax?

    /// Identifier text used when generating source fragments.
    var nameText: String {
        name.text
    }

    /// Normalized source text for `type`.
    var typeDescription: String {
        type.trimmedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Normalized source text for `defaultValue`.
    var defaultValueDescription: String? {
        defaultValue?.trimmedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
