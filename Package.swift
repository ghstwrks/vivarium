// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "vre-poc",
    // macOS 27 only, and deliberately so: VZMacGuestProvisioningOptions is a
    // macOS 27 API and the guest must also be macOS 27, so there is nothing to
    // gain from availability-guarding this tool for older hosts.
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "vre-poc", targets: ["VREPOC"])
    ],
    targets: [
        .executableTarget(
            name: "VREPOC",
            path: "Sources/VREPOC",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
