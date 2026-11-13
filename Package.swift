// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "WdkCore",
    platforms: [
        .iOS(.v14),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "WdkCore",
            targets: ["WdkCore"]
        )
    ],
    dependencies: [
        // bare-kit-swift 1.x wraps the Bare Kit v2 Objective-C API (`BareWorklet`), the one the
        // BareKit 2.x prebuilds expose and this package is written against. 2.x of the wrapper
        // targets Bare Kit v3, which arrives with the bare-stow rework
        // (tetherto/wdk-worklet-bundler#84, phase 3a). `from:` stops below the next major.
        .package(url: "https://github.com/holepunchto/bare-kit-swift", from: "1.0.0")
    ],
    targets: [
        .target(
            name: "WdkCore",
            dependencies: [
                .product(name: "BareKit", package: "bare-kit-swift"),
            ]
        ),
        .testTarget(
            name: "WdkCoreTests",
            dependencies: ["WdkCore"]
        ),
    ]
)
