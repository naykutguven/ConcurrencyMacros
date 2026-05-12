//
//  ThreadSafeMode.swift
//  ConcurrencyMacros
//

/// Sendability mode selected by the owning `@ThreadSafe` class declaration.
enum ThreadSafeMode: Equatable {
    case checked
    case unchecked

    var storageTypeName: String {
        switch self {
        case .checked:
            return "ConcurrencyMacros.ThreadSafeStorage"
        case .unchecked:
            return "ConcurrencyMacros.UncheckedThreadSafeStorage"
        }
    }

    var stateConformanceSource: String {
        switch self {
        case .checked:
            return ": Sendable"
        case .unchecked:
            return ""
        }
    }
}
