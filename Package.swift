// swift-tools-version: 6.0
import PackageDescription

// The code that needs no app around it, so `swift test` runs it on any Mac. The app and its Safari
// extension are the Xcode project (project.yml), which uses the two libraries here.
let package = Package(
    name: "Slipstream",
    defaultLocalization: "de",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DropCore", targets: ["DropCore"]),
        .library(name: "HelperCore", targets: ["HelperCore"]),
        .executable(name: "slipstream-cli", targets: ["slipstream-cli"]),
    ],
    targets: [
        // The ProRes intermediate: plan, transcoder, checks, messages.
        .target(name: "DropCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        // The helper without its UI: the loopback endpoint, the ProRes jobs, the tunnel
        // configuration, the worker's events.
        .target(name: "HelperCore", dependencies: ["DropCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "slipstream-cli", dependencies: ["DropCore"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "DropCoreTests", dependencies: ["DropCore"],
                    resources: [.copy("fixtures")],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "HelperCoreTests", dependencies: ["HelperCore"],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
