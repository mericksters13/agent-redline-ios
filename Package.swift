// swift-tools-version: 6.0
import PackageDescription

// Everything in the kit is compiled only for debug configurations. Release and
// other release-type configurations (such as TestFlight) get an empty module
// whose public modifier returns the view unchanged.
let debugOnly: [SwiftSetting] = [.define("AGENT_REDLINE", .when(configuration: .debug))]

let package = Package(
    name: "AgentRedline",
    // macOS is listed only so the platform-independent logic can be tested with
    // `swift test` on the Mac. The kit itself runs on iOS.
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "AgentRedline", targets: ["AgentRedline"]),
        .executable(name: "redline", targets: ["RedlineTool"]),
    ],
    targets: [
        .target(name: "AgentRedline", swiftSettings: debugOnly),
        .testTarget(
            name: "AgentRedlineTests",
            dependencies: ["AgentRedline"],
            swiftSettings: debugOnly
        ),
        // The Mac side: takes reports off paired phones and simulators for agent chats. It runs
        // on the Mac only and never ships in an app, so it isn't limited to debug builds.
        .executableTarget(name: "RedlineTool"),
        .testTarget(name: "RedlineToolTests", dependencies: ["RedlineTool"]),
    ]
)
