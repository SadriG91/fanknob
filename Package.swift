// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "fanknob",
    platforms: [.macOS(.v13)],
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
    ]
)
