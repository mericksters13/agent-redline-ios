#if os(macOS)
import Foundation
import Testing
@testable import RedlineTool

struct ProjectAppsTests {
    private let temporary = TemporaryFolder("ProjectAppsTests")
    private var root: URL { temporary.url }
    private var paths: HubPaths { HubPaths(root: root.appending(path: "hub-root", directoryHint: .isDirectory)) }

    /// A project folder with two ways of setting bundle IDs.
    private func project() throws -> URL {
        let folder = root.appending(path: "ExampleApp", directoryHint: .isDirectory)
        let files = FileManager.default
        try files.createDirectory(at: folder.appending(path: "App/App.xcodeproj"), withIntermediateDirectories: true)
        try files.createDirectory(
            at: folder.appending(path: "Pods/Vendor.xcodeproj"),
            withIntermediateDirectories: true
        )
        try "targets:\n  App:\n    settings:\n      PRODUCT_BUNDLE_IDENTIFIER: com.example.app\n".write(
            to: folder.appending(path: "App/project.yml"),
            atomically: true,
            encoding: .utf8
        )
        try """
        { objects = {
            T1 = {isa = PBXNativeTarget; productType = "com.apple.product-type.application"; buildConfigurationList = L1; };
            L1 = {isa = XCConfigurationList; buildConfigurations = (C1); };
            C1 = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_BUNDLE_IDENTIFIER = com.example.app; }; };
        }; }
        """.write(to: folder.appending(path: "App/App.xcodeproj/project.pbxproj"), atomically: true, encoding: .utf8)
        // Other people's code doesn't count.
        try """
        { objects = {
            T1 = {isa = PBXNativeTarget; productType = "com.apple.product-type.application"; buildConfigurationList = L1; };
            L1 = {isa = XCConfigurationList; buildConfigurations = (C1); };
            C1 = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_BUNDLE_IDENTIFIER = org.cocoapods.vendor; }; };
        }; }
        """.write(
            to: folder.appending(path: "Pods/Vendor.xcodeproj/project.pbxproj"),
            atomically: true,
            encoding: .utf8
        )
        return folder
    }

    @Test func onlyAppTargetsCountWithEveryConfigurationsID() throws {
        let pbxproj = """
            // !$*UTF8*$!
            {
              archiveVersion = 1;
              objects = {
                T1 = {isa = PBXNativeTarget; productType = "com.apple.product-type.application"; buildConfigurationList = L1; };
                L1 = {isa = XCConfigurationList; buildConfigurations = (C1, C2); };
                C1 = {isa = XCBuildConfiguration; name = Debug; buildSettings = {PRODUCT_BUNDLE_IDENTIFIER = com.example.app.debug; }; };
                C2 = {isa = XCBuildConfiguration; name = Release; buildSettings = {PRODUCT_BUNDLE_IDENTIFIER = com.example.app; }; };
                T2 = {isa = PBXNativeTarget; productType = "com.apple.product-type.app-extension"; buildConfigurationList = L2; };
                L2 = {isa = XCConfigurationList; buildConfigurations = (C3); };
                C3 = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_BUNDLE_IDENTIFIER = com.example.app.widgets; }; };
                T3 = {isa = PBXNativeTarget; productType = "com.apple.product-type.bundle.unit-test"; buildConfigurationList = L3; };
                L3 = {isa = XCConfigurationList; buildConfigurations = (C4); };
                C4 = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_BUNDLE_IDENTIFIER = "$(PRODUCT_NAME)Tests"; }; };
                T4 = {isa = PBXNativeTarget; productType = "com.apple.product-type.application"; buildConfigurationList = L4; };
                L4 = {isa = XCConfigurationList; buildConfigurations = (C5); };
                C5 = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_BUNDLE_IDENTIFIER = com.example.app.watchkitapp; SDKROOT = watchos; }; };
              };
            }
            """
        // Debug builds often have their own ID, and the kit runs only in Debug builds.
        #expect(
            ProjectApps.appBundleIDs(inProject: Data(pbxproj.utf8)) == ["com.example.app", "com.example.app.debug"]
        )
    }

    @Test func withoutAnXcodeProjectTheSpecsIDsCountLessTests() throws {
        let folder = root.appending(path: "Spec", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "PRODUCT_BUNDLE_IDENTIFIER: com.example.other\nPRODUCT_BUNDLE_IDENTIFIER: com.example.OtherTests\n"
            .write(to: folder.appending(path: "project.yml"), atomically: true, encoding: .utf8)
        #expect(ProjectApps.bundleIDs(in: folder) == ["com.example.other"])
    }

    @Test func settingsLinesGiveTheirLiteralIDsOnly() {
        let text = """
            PRODUCT_BUNDLE_IDENTIFIER = "com.example.quoted";
            PRODUCT_BUNDLE_IDENTIFIER: 'com.example.single' # a comment
            PRODUCT_BUNDLE_IDENTIFIER = com.example.plain; // trailing
            PRODUCT_BUNDLE_IDENTIFIER = $(BASE_ID).debug;
            \tPRODUCT_BUNDLE_IDENTIFIER:\tcom.example.tabbed
            """
        #expect(
            ProjectApps.bundleIDs(inSettings: text) == [
                "com.example.quoted", "com.example.single", "com.example.plain", "com.example.tabbed",
            ]
        )
    }

    @Test func aProjectsAppIsFoundInItsXcodeProject() throws {
        #expect(ProjectApps.bundleIDs(in: try project()) == ["com.example.app"])
    }
}
#endif
