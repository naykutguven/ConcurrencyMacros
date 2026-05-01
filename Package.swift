// swift-tools-version: 6.2

import CompilerPluginSupport
import PackageDescription

/// Shared Swift settings enabling approachable Swift 6 concurrency features for all targets.
let approachableConcurrencySettings: [SwiftSetting] = [
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

/// Keep macro builds on a SwiftSyntax line verified by this package's expression macro tests.
/// Advance to newer SwiftSyntax minor lines only after compiler-plugin expansion is verified.
let swiftSyntaxRange = Version(602, 0, 0)..<Version(603, 0, 0)

/// Swift package definition for the ConcurrencyMacros library, plugin, and tests.
let package = Package(
    name: "ConcurrencyMacros",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
        .watchOS(.v10)
    ],
    products: [
        .library(
            name: "ConcurrencyMacros",
            targets: ["ConcurrencyMacros"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax", swiftSyntaxRange)
    ],
    targets: [
        .target(
            name: "ConcurrencyMacrosRuntime",
            swiftSettings: approachableConcurrencySettings
        ),
        .target(
            name: "ConcurrencyMacros",
            dependencies: [
                "ConcurrencyMacrosImplementation",
                "ConcurrencyMacrosRuntime",
            ],
            swiftSettings: approachableConcurrencySettings
        ),
        .macro(
            name: "ConcurrencyMacrosImplementation",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ],
            swiftSettings: approachableConcurrencySettings
        ),
        .testTarget(
            name: "ConcurrencyMacrosTests",
            dependencies: ["ConcurrencyMacros"],
            swiftSettings: approachableConcurrencySettings
        ),
        .testTarget(
            name: "ConcurrencyMacrosRuntimeTests",
            dependencies: ["ConcurrencyMacrosRuntime"],
            swiftSettings: approachableConcurrencySettings
        ),
        .testTarget(
            name: "ConcurrencyMacrosImplementationTests",
            dependencies: [
                "ConcurrencyMacrosImplementation",
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ],
            swiftSettings: approachableConcurrencySettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
