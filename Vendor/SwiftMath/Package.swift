// swift-tools-version: 5.7
// Vendored from https://github.com/mgriebling/SwiftMath 1.7.3 (MIT). See PATCHES.md.
import PackageDescription

let package = Package(
    name: "SwiftMath",
    defaultLocalization: "en",
    platforms: [.iOS("11.0"), .macOS("12.0")],
    products: [
        .library(name: "SwiftMath", targets: ["SwiftMath"]),
    ],
    targets: [
        .target(name: "SwiftMath", resources: [.copy("mathFonts.bundle")]),
    ]
)
