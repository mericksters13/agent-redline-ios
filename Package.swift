// swift-tools-version: 6.0
import PackageDescription

// Everything in the kit is compiled only for debug configurations. Release and
// other release-type configurations (such as TestFlight) get an empty module
// whose public modifier returns the view unchanged.
let debugOnly: [SwiftSetting] = [.define("AGENTIC_DEBUGGING", .when(configuration: .debug))]

let package = Package(
    name: "iOSAgenticDebuggingKit",
    // macOS is listed only so the platform-independent logic can be tested with
    // `swift test` on the Mac. The kit itself runs on iOS.
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "iOSAgenticDebuggingKit", targets: ["iOSAgenticDebuggingKit"]),
    ],
    targets: [
        .target(name: "iOSAgenticDebuggingKit", swiftSettings: debugOnly),
        .testTarget(
            name: "iOSAgenticDebuggingKitTests",
            dependencies: ["iOSAgenticDebuggingKit"],
            swiftSettings: debugOnly
        ),
    ]
)
