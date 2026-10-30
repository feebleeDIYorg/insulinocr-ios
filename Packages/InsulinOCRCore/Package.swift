// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "InsulinOCRCore",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "InsulinOCRCore", targets: ["InsulinOCRCore"]),
        .executable(name: "insulinocr-analyze", targets: ["InsulinOCRAnalyze"]),
    ],
    targets: [
        .executableTarget(name: "InsulinOCRAnalyze", dependencies: ["InsulinOCRCore"]),
        .target(
            name: "InsulinOCRCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "InsulinOCRCoreTests",
            dependencies: ["InsulinOCRCore"],
            resources: [.process("Fixtures")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
