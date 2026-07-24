// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "fanknob",
    platforms: [.macOS(.v15)],
    targets: [
        // Shared engine: SMC access, fan/temp model, daemon client.
        .target(
            name: "FanknobCore",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        // CLI client (status/temp/tui/set/auto).
        .executableTarget(
            name: "fanknob",
            dependencies: ["FanknobCore"]
        ),
        // Root daemon that performs privileged SMC writes.
        .executableTarget(
            name: "fanknobd",
            dependencies: ["FanknobCore"]
        ),
        // SwiftUI menu-bar app.
        .executableTarget(
            name: "FanknobApp",
            dependencies: ["FanknobCore"]
        ),
        .testTarget(
            name: "FanknobCoreTests",
            dependencies: ["FanknobCore"]
        ),
    ],
    // Keep Swift 5 semantics: the daemon/app manage threading manually and
    // don't need Swift 6 strict-concurrency enforcement.
    swiftLanguageModes: [.v5]
)
