// swift-tools-version: 6.0
// TalonKit — the shared core, the root helper (talond) and the CLI (talon).
// The app and widget live in App/ (XcodeGen) and link only TalonModel + TalonIPC.
import PackageDescription

let package = Package(
    name: "TalonKit",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "talond", targets: ["talond"]),
        .executable(name: "talon", targets: ["talon"]),
        .library(name: "TalonModel", targets: ["TalonModel"]),
        .library(name: "TalonIPC", targets: ["TalonIPC"]),
        .library(name: "TalonScalpel", targets: ["TalonScalpel"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        // Private Darwin declarations + the NVMe SMART CFPlugIn vtable. Prefixed name: Xcode 27's
        // dependency scanner needs every reachable Clang module to be uniquely named.
        .target(
            name: "TalonPrivate",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation"), .linkedLibrary("IOReport")]
        ),
        .target(name: "TalonModel"),
        .target(name: "TalonIPC", dependencies: ["TalonModel"]),
        .target(name: "TalonSensors", dependencies: ["TalonModel", "TalonPrivate"]),
        .target(name: "TalonCore", dependencies: ["TalonModel", "TalonSensors", "TalonPrivate"]),
        .target(name: "TalonStore", dependencies: ["TalonModel", "TalonCore", .product(name: "GRDB", package: "GRDB.swift")]),
        // scalpel: storage analysis and cleanup. Runs as the user (CLI or app), never inside talond.
        .target(name: "TalonScalpel", dependencies: ["TalonModel", "TalonPrivate"]),
        .target(name: "TalonDaemon", dependencies: ["TalonCore", "TalonStore", "TalonIPC", "TalonPrivate"]),
        .executableTarget(name: "talond", dependencies: ["TalonDaemon", "TalonIPC", "TalonModel"]),
        .executableTarget(
            name: "talon",
            dependencies: ["TalonCore", "TalonIPC", "TalonScalpel", .product(name: "ArgumentParser", package: "swift-argument-parser")]
        ),
        .testTarget(name: "TalonTests", dependencies: ["TalonModel", "TalonIPC", "TalonCore", "TalonStore", "TalonDaemon", "TalonScalpel"]),
    ]
)
