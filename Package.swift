// swift-tools-version: 6.2

import CompilerPluginSupport
import PackageDescription

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
        .package(url: "https://github.com/swiftlang/swift-syntax", "509.0.0"..<"603.0.0")
    ],
    targets: [
        .target(
            name: "ConcurrencyMacros",
            dependencies: [
                "ConcurrencyMacrosPlugin"
            ]
        ),
        .macro(
          name: "ConcurrencyMacrosPlugin",
          dependencies: [
            .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
            .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
          ]
        ),
        .testTarget(
            name: "ConcurrencyMacrosTests",
            dependencies: [
                "ConcurrencyMacros",
                "ConcurrencyMacrosPlugin",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
    ]
)
