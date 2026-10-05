// swift-tools-version: 6.2
import PackageDescription

// Everything in the kit is compiled only for debug configurations. Release and
// other release-type configurations (such as TestFlight) get an empty module
// whose public modifier returns the view unchanged.
let debugOnly: [SwiftSetting] = [.define("REDLINE", .when(configuration: .debug))]

let package = Package(
    name: "Redline",
    // iOS 18 for the kit. macOS 15 for the redline command and menu bar app, and so swift test
    // can run the kit's platform-independent logic on the Mac.
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "Redline", targets: ["Redline"]),
        .executable(name: "redline", targets: ["RedlineTool"]),
    ],
    targets: [
        .target(name: "Redline", swiftSettings: debugOnly),
        // The kit's tests compile only where the kit does. Run them in debug, the default; swift test
        // -c release builds an empty test target and runs nothing.
        .testTarget(
            name: "RedlineTests",
            dependencies: ["Redline"],
            swiftSettings: debugOnly
        ),
        // The Mac side: takes reports off paired phones and simulators for agent chats. It runs
        // on the Mac only and never ships in an app, so it isn't limited to debug builds.
        .executableTarget(name: "RedlineTool"),
        // Depends on the kit too, so tests check that the Mac reads exactly what the kit writes:
        // the messages between them and report.json.
        .testTarget(
            name: "RedlineToolTests",
            dependencies: ["RedlineTool", "Redline"],
            swiftSettings: debugOnly
        ),
    ]
)
