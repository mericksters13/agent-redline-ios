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

    @Test func bundleIDsSetInXcconfigFilesAndFromOtherSettingsAreFound() throws {
        let folder = root.appending(path: "Configured", directoryHint: .isDirectory)
        let config = folder.appending(path: "Config", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: folder.appending(path: "App.xcodeproj"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try """
        // Shared by every target.
        APP_BUNDLE_ID = com.example.$(PRODUCT_NAME:rfc1034identifier)
        PRODUCT_BUNDLE_IDENTIFIER[sdk=macosx*] = com.example.mac
        """.write(to: config.appending(path: "Shared.xcconfig"), atomically: true, encoding: .utf8)
        try """
        #include "Shared.xcconfig"
        PRODUCT_BUNDLE_IDENTIFIER = $(APP_BUNDLE_ID) // the App Store ID
        """.write(to: config.appending(path: "App.xcconfig"), atomically: true, encoding: .utf8)
        try """
        // !$*UTF8*$!
        {
          archiveVersion = 1;
          rootObject = P1;
          objects = {
            P1 = {isa = PBXProject; mainGroup = G1; buildConfigurationList = L0; };
            L0 = {isa = XCConfigurationList; buildConfigurations = (C0); };
            C0 = {isa = XCBuildConfiguration; name = Debug; buildSettings = {SDKROOT = iphoneos; }; };
            G1 = {isa = PBXGroup; sourceTree = "<group>"; children = (G2); };
            G2 = {isa = PBXGroup; path = Config; sourceTree = "<group>"; children = (F1); };
            F1 = {isa = PBXFileReference; path = App.xcconfig; sourceTree = "<group>"; };
            T1 = {isa = PBXNativeTarget; name = "My App"; productType = "com.apple.product-type.application"; buildConfigurationList = L1; };
            L1 = {isa = XCConfigurationList; buildConfigurations = (C1, C2); };
            C1 = {isa = XCBuildConfiguration; name = Debug; baseConfigurationReference = F1; buildSettings = {PRODUCT_BUNDLE_IDENTIFIER = "$(APP_BUNDLE_ID).debug"; }; };
            C2 = {isa = XCBuildConfiguration; name = Release; baseConfigurationReference = F1; buildSettings = {}; };
            T2 = {isa = PBXNativeTarget; name = Other; productType = "com.apple.product-type.application"; buildConfigurationList = L2; };
            L2 = {isa = XCConfigurationList; buildConfigurations = (C3); };
            C3 = {isa = XCBuildConfiguration; name = Debug; buildSettings = {PRODUCT_BUNDLE_IDENTIFIER = "$(UNDEFINED_ID)"; }; };
          };
        }
        """.write(to: folder.appending(path: "App.xcodeproj/project.pbxproj"), atomically: true, encoding: .utf8)
        // A setting that names one nobody sets can't be worked out, so it's left out.
        #expect(ProjectApps.bundleIDs(in: folder) == ["com.example.My-App", "com.example.My-App.debug"])
    }

    @Test func bundleIDsSetForTheIPhoneSDKOnlyAreFound() throws {
        let folder = root.appending(path: "Conditional", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: folder.appending(path: "App.xcodeproj"),
            withIntermediateDirectories: true
        )
        try """
        PRODUCT_BUNDLE_IDENTIFIER[sdk=iphoneos*] = com.example.device
        PRODUCT_BUNDLE_IDENTIFIER[sdk=iphonesimulator*] = $(inherited).simulator
        PRODUCT_BUNDLE_IDENTIFIER[sdk=macosx*] = com.example.mac
        PRODUCT_BUNDLE_IDENTIFIER[arch=x86_64] = com.example.intel
        OTHER_ID[sdk=iphoneos*] = com.example.other.device
        OTHER_ID = com.example.other
        """.write(to: folder.appending(path: "App.xcconfig"), atomically: true, encoding: .utf8)
        try """
        // !$*UTF8*$!
        {
          archiveVersion = 1;
          rootObject = P1;
          objects = {
            P1 = {isa = PBXProject; mainGroup = G1; buildConfigurationList = L0; };
            L0 = {isa = XCConfigurationList; buildConfigurations = (C0); };
            C0 = {isa = XCBuildConfiguration; name = Debug; buildSettings = {PRODUCT_BUNDLE_IDENTIFIER = com.example.base; }; };
            G1 = {isa = PBXGroup; sourceTree = "<group>"; children = (F1); };
            F1 = {isa = PBXFileReference; path = App.xcconfig; sourceTree = "<group>"; };
            T1 = {isa = PBXNativeTarget; name = App; productType = "com.apple.product-type.application"; buildConfigurationList = L1; };
            L1 = {isa = XCConfigurationList; buildConfigurations = (C1); };
            C1 = {isa = XCBuildConfiguration; name = Debug; baseConfigurationReference = F1; buildSettings = {}; };
            T2 = {isa = PBXNativeTarget; name = Plain; productType = "com.apple.product-type.application"; buildConfigurationList = L2; };
            L2 = {isa = XCConfigurationList; buildConfigurations = (C2); };
            C2 = {isa = XCBuildConfiguration; name = Debug; baseConfigurationReference = F1; buildSettings = {PRODUCT_BUNDLE_IDENTIFIER = com.example.plain; }; };
            T3 = {isa = PBXNativeTarget; name = Other; productType = "com.apple.product-type.application"; buildConfigurationList = L3; };
            L3 = {isa = XCConfigurationList; buildConfigurations = (C3); };
            C3 = {isa = XCBuildConfiguration; name = Debug; baseConfigurationReference = F1; buildSettings = {PRODUCT_BUNDLE_IDENTIFIER = "$(OTHER_ID)"; }; };
          };
        }
        """.write(to: folder.appending(path: "App.xcodeproj/project.pbxproj"), atomically: true, encoding: .utf8)
        // Each iOS SDK's own ID, over the project's; a setting for every SDK at a higher level
        // replaces them, as in Xcode, but not one later in the same file. The Mac's and one
        // architecture's are left out.
        #expect(
            ProjectApps.bundleIDs(in: folder) == [
                "com.example.base.simulator", "com.example.device", "com.example.other", "com.example.other.device",
                "com.example.plain",
            ]
        )
    }

    @Test func bundleIDsSetForOneConfigurationOnlyAreFound() throws {
        let folder = root.appending(path: "PerConfiguration", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: folder.appending(path: "App.xcodeproj"),
            withIntermediateDirectories: true
        )
        try """
        PRODUCT_BUNDLE_IDENTIFIER[config=Debug] = com.example.debug
        PRODUCT_BUNDLE_IDENTIFIER[config=Release][sdk=iphoneos*] = com.example.release
        PRODUCT_BUNDLE_IDENTIFIER[config=Beta] = com.example.beta
        """.write(to: folder.appending(path: "App.xcconfig"), atomically: true, encoding: .utf8)
        try """
        // !$*UTF8*$!
        {
          archiveVersion = 1;
          rootObject = P1;
          objects = {
            P1 = {isa = PBXProject; mainGroup = G1; buildConfigurationList = L0; };
            L0 = {isa = XCConfigurationList; buildConfigurations = (C0); };
            C0 = {isa = XCBuildConfiguration; name = Debug; buildSettings = {}; };
            G1 = {isa = PBXGroup; sourceTree = "<group>"; children = (F1); };
            F1 = {isa = PBXFileReference; path = App.xcconfig; sourceTree = "<group>"; };
            T1 = {isa = PBXNativeTarget; name = App; productType = "com.apple.product-type.application"; buildConfigurationList = L1; };
            L1 = {isa = XCConfigurationList; buildConfigurations = (C1, C2); };
            C1 = {isa = XCBuildConfiguration; name = Debug; baseConfigurationReference = F1; buildSettings = {}; };
            C2 = {isa = XCBuildConfiguration; name = Release; baseConfigurationReference = F1; buildSettings = {}; };
          };
        }
        """.write(to: folder.appending(path: "App.xcodeproj/project.pbxproj"), atomically: true, encoding: .utf8)
        // Each configuration the target has gets its own ID; one it doesn't have adds nothing.
        #expect(ProjectApps.bundleIDs(in: folder) == ["com.example.debug", "com.example.release"])
    }

    @Test func inheritedSettingsKeepTheValueFromTheLevelBelow() throws {
        let folder = root.appending(path: "Inherited", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: folder.appending(path: "App.xcodeproj"),
            withIntermediateDirectories: true
        )
        try "PRODUCT_BUNDLE_IDENTIFIER = com.example.base\nPRODUCT_BUNDLE_IDENTIFIER = $(inherited).app\n"
            .write(to: folder.appending(path: "Project.xcconfig"), atomically: true, encoding: .utf8)
        try """
        // !$*UTF8*$!
        {
          archiveVersion = 1;
          rootObject = P1;
          objects = {
            P1 = {isa = PBXProject; mainGroup = G1; buildConfigurationList = L0; };
            L0 = {isa = XCConfigurationList; buildConfigurations = (C0, C00); };
            C0 = {isa = XCBuildConfiguration; name = Debug; baseConfigurationReference = F1; buildSettings = {}; };
            C00 = {isa = XCBuildConfiguration; name = Release; buildSettings = {PRODUCT_BUNDLE_IDENTIFIER = com.example.release; }; };
            G1 = {isa = PBXGroup; sourceTree = "<group>"; children = (F1); };
            F1 = {isa = PBXFileReference; path = Project.xcconfig; sourceTree = "<group>"; };
            T1 = {isa = PBXNativeTarget; name = App; productType = "com.apple.product-type.application"; buildConfigurationList = L1; };
            L1 = {isa = XCConfigurationList; buildConfigurations = (C1, C2); };
            C1 = {isa = XCBuildConfiguration; name = Debug; buildSettings = {PRODUCT_BUNDLE_IDENTIFIER = "$(inherited).debug"; }; };
            C2 = {isa = XCBuildConfiguration; name = Release; buildSettings = {PRODUCT_BUNDLE_IDENTIFIER = "${inherited}"; }; };
          };
        }
        """.write(to: folder.appending(path: "App.xcodeproj/project.pbxproj"), atomically: true, encoding: .utf8)
        #expect(ProjectApps.bundleIDs(in: folder) == ["com.example.base.app.debug", "com.example.release"])
    }

    @Test func settingReferencesAreFilledInAsXcodeDoes() {
        let settings = ["TARGET_NAME": "Sample App", "PRODUCT_NAME": "$(TARGET_NAME)", "BASE": "com.example"]
        #expect(
            ProjectApps.expand("${BASE}.$(PRODUCT_NAME:rfc1034identifier:lower)", with: settings)
                == "com.example.sample-app"
        )
        #expect(ProjectApps.expand("$(inherited)com.example.app", with: settings) == "com.example.app")
        #expect(ProjectApps.expand("$(MISSING).app", with: settings) == nil)
        // A setting that refers to itself doesn't loop.
        #expect(ProjectApps.expand("$(LOOP)", with: ["LOOP": "$(LOOP)"]) == nil)
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

    @Test func commentedOutBundleIDsDontCount() {
        let spec = """
            targets:
              App:
                settings:
                  # PRODUCT_BUNDLE_IDENTIFIER: com.example.old
                  PRODUCT_BUNDLE_IDENTIFIER: com.example.app # was com.example.older
            """
        #expect(ProjectApps.bundleIDs(inSettings: spec) == ["com.example.app"])
    }

    @Test func aProjectsAppIsFoundInItsXcodeProject() throws {
        #expect(ProjectApps.bundleIDs(in: try project()) == ["com.example.app"])
    }
}
#endif
