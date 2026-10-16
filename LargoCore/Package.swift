// swift-tools-version:5.9
import PackageDescription

/// Audio analysis for Largo: waveform peaks, chord detection, beat and bar tracking.
let package = Package(
    name: "LargoCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "LargoCore", targets: ["LargoCore"]),
    ],
    targets: [
        .target(name: "LargoCore"),
        .testTarget(name: "LargoCoreTests", dependencies: ["LargoCore"]),
    ]
)
