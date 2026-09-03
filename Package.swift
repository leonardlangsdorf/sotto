// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Sotto",
    platforms: [.macOS(.v26)],
    targets: [
        // Hardware-free logic. Everything here is unit testable.
        .target(
            name: "SottoCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The app itself. Talks to CoreGraphics, AVFoundation, Speech, AppKit.
        // A library rather than the executable so tests can reach inside it.
        .target(
            name: "SottoKit",
            dependencies: ["SottoCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "SottoApp",
            dependencies: ["SottoKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SottoCoreTests",
            dependencies: ["SottoCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SottoKitTests",
            dependencies: ["SottoKit"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
