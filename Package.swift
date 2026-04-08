// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacRecovery",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "RecoveryCore", targets: ["RecoveryCore"]),
        .executable(name: "recoverycli", targets: ["RecoveryCLI"]),
        .executable(name: "MacRecoveryApp", targets: ["MacRecoveryApp"]),
    ],
    targets: [
        .target(
            name: "RecoveryCore",
            path: "RecoveryCore/Sources",
            linkerSettings: [
                .linkedFramework("DiskArbitration"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
            ]
        ),
        .testTarget(
            name: "RecoveryCoreTests",
            dependencies: ["RecoveryCore"],
            path: "RecoveryCore/Tests"
        ),
        .executableTarget(
            name: "RecoveryCLI",
            dependencies: ["RecoveryCore"],
            path: "RecoveryCLI"
        ),
        .executableTarget(
            name: "MacRecoveryApp",
            dependencies: ["RecoveryCore"],
            path: "MacRecoveryApp",
            linkerSettings: [
                .linkedFramework("DiskArbitration"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
            ]
        ),
    ]
)
