// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "vivarium",
    // macOS 27 only, and deliberately so: VZMacGuestProvisioningOptions is a
    // macOS 27 API and the guest must also be macOS 27, so there is nothing to
    // gain from availability-guarding this tool for older hosts.
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "viv", targets: ["Vivarium"])
    ],
    dependencies: [
        // ArgumentParser provides consistent `--flag value` and `--flag=value`
        // parsing, subcommand dispatch, generated help, and usage diagnostics.
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2")
    ],
    targets: [
        .executableTarget(
            name: "Vivarium",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/Vivarium",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "VivariumTests",
            dependencies: ["Vivarium"],
            path: "Tests/VivariumTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
