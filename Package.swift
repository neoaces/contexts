// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Contexts",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: "Vendor/SwiftMath"),  // 1.7.3 with a font-loading patch, see Vendor/SwiftMath/PATCHES.md
    ],
    targets: [
        .executableTarget(
            name: "Contexts",
            dependencies: [.product(name: "SwiftMath", package: "SwiftMath")],
            path: "Sources/Contexts"
        ),
        .testTarget(name: "ContextsTests", dependencies: ["Contexts"], path: "Tests/ContextsTests"),
    ]
)
