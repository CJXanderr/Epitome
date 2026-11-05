// swift-tools-version:5.9
// Epitome — instant file-name search for macOS.
import PackageDescription

let optimize: [SwiftSetting] = []

let package = Package(
    name: "Epitome",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Epitome", targets: ["Epitome"]),
        .executable(name: "ep", targets: ["ep"]),
        .executable(name: "epitome-selftest", targets: ["EpitomeSelfTest"]),
    ],
    targets: [
        .target(
            name: "EpitomeCore",
            path: "Sources/EpitomeCore",
            swiftSettings: optimize
        ),
        .executableTarget(
            name: "Epitome",
            dependencies: ["EpitomeCore"],
            path: "Sources/Epitome",
            swiftSettings: optimize,
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreServices"),
                .linkedFramework("Quartz"),
                .linkedFramework("QuickLookThumbnailing"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("ImageIO"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("WebKit"),
            ]
        ),
        .executableTarget(
            name: "ep",
            dependencies: ["EpitomeCore"],
            path: "Sources/ep",
            swiftSettings: optimize
        ),
        .executableTarget(
            name: "EpitomeSelfTest",
            dependencies: ["EpitomeCore"],
            path: "Sources/EpitomeSelfTest",
            swiftSettings: optimize
        ),
    ]
)
