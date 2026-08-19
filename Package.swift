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
        // The POC hand-rolled its parser to keep the dependency graph empty, so
        // that a resolved package could never be blamed for an unexpected
        // Virtualization result. That rationale expired with the POC, and the
        // hand-rolled parser rejected `--flag=value`; swift-argument-parser
        // gives that, subcommand trees, and generated help for free.
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
        // Only what can be asserted without a hypervisor: the guest scripts,
        // the template record's compatibility with the one 0.1 wrote, the
        // cloud-init documents, and the xz decoder. Everything that needs a
        // running guest is `viv selftest`, which is the integration test and
        // cannot be one of these.
        .testTarget(
            name: "VivariumTests",
            dependencies: ["Vivarium"],
            path: "Tests/VivariumTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
