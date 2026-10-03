#if os(macOS)
import Foundation

/// Finds the bundle IDs a project folder builds, so a chat working there gets that app's reports.
enum ProjectApps {
    /// Folders that hold other people's code or build output, never the project's own settings.
    private static let skipped: Set<String> = [".git", ".build", "build", "DerivedData", "Pods", "Carthage", "node_modules", ".swiftpm", "SourcePackages"]

    /// The bundle IDs of the app targets in the folder's Xcode projects, a few levels deep:
    /// every configuration's, since Debug builds often use their own. Extensions, watch apps and
    /// test bundles are left out; the kit runs only in iOS apps. Without an Xcode project, the
    /// literal IDs in an XcodeGen `project.yml`, less test bundles.
    static func bundleIDs(in folder: URL, depth: Int = 4) -> [String] {
        let files = settingsFiles(in: folder, depth: depth)
        let projects = files.filter { $0.lastPathComponent == "project.pbxproj" }
        var found = Set<String>()
        if projects.isEmpty {
            for file in files {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                found.formUnion(bundleIDs(inSettings: text).filter { !$0.hasSuffix("Tests") })
            }
        } else {
            for project in projects {
                guard let data = try? Data(contentsOf: project) else { continue }
                found.formUnion(appBundleIDs(inProject: data))
            }
        }
        return found.sorted()
    }

    /// The bundle IDs of an Xcode project's app targets, read from its `project.pbxproj`.
    static func appBundleIDs(inProject data: Data) -> Set<String> {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let objects = plist["objects"] as? [String: [String: Any]]
        else { return [] }
        var found = Set<String>()
        for target in objects.values where target["isa"] as? String == "PBXNativeTarget"
            && target["productType"] as? String == "com.apple.product-type.application" {
            guard let list = target["buildConfigurationList"] as? String,
                  let configurations = objects[list]?["buildConfigurations"] as? [String]
            else { continue }
            for configuration in configurations {
                let settings = objects[configuration]?["buildSettings"] as? [String: Any]
                // A watch, TV, Mac or Vision app; the kit runs only on iOS.
                if let sdk = settings?["SDKROOT"] as? String, ["watchos", "appletvos", "macosx", "xros"].contains(sdk) { continue }
                if let id = settings?["PRODUCT_BUNDLE_IDENTIFIER"] as? String, isLiteral(id) { found.insert(id) }
            }
        }
        return found
    }

    /// Bundle IDs set in a `project.yml` (`PRODUCT_BUNDLE_IDENTIFIER: com.example.app`) or a
    /// `project.pbxproj` (`PRODUCT_BUNDLE_IDENTIFIER = com.example.app;`), whatever the target.
    static func bundleIDs(inSettings text: String) -> Set<String> {
        var found = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            guard let key = line.range(of: "PRODUCT_BUNDLE_IDENTIFIER") else { continue }
            var value = line[key.upperBound...].drop { $0 == " " || $0 == "=" || $0 == ":" || $0 == "\t" }
            value = value.prefix { $0 != ";" && $0 != "#" }
            let id = value.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
            if isLiteral(id) { found.insert(id) }
        }
        return found
    }

    /// Not built from a variable like `$(PRODUCT_NAME)`.
    private static func isLiteral(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
    }

    private static func settingsFiles(in folder: URL, depth: Int) -> [URL] {
        guard depth >= 0, let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        var files: [URL] = []
        for name in names where !skipped.contains(name) {
            let url = folder.appending(path: name)
            if name.hasSuffix(".xcodeproj") {
                files.append(url.appending(path: "project.pbxproj"))
            } else if name == "project.yml" || name == "project.yaml" {
                files.append(url)
            } else if !name.hasPrefix("."), (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                files += settingsFiles(in: url, depth: depth - 1)
            }
        }
        return files
    }
}
#endif
