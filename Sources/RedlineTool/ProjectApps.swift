#if os(macOS)
import Foundation

/// Finds the bundle IDs a project folder builds, so a chat working there gets that app's reports.
enum ProjectApps {
    /// Folders that hold other people's code or build output, never the project's own settings.
    private static let skipped: Set<String> = [
        ".git", ".build", "build", "DerivedData", "Pods", "Carthage", "node_modules", ".swiftpm", "SourcePackages",
    ]

    /// The bundle IDs of the app targets in the folder's Xcode projects, a few levels deep: every
    /// configuration's, since Debug builds often use their own.
    ///
    /// Extensions, watch apps and test bundles are left out; the kit runs only in iOS apps. Without
    /// an Xcode project, the literal IDs in an XcodeGen `project.yml`, less test bundles.
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
                found.formUnion(
                    appBundleIDs(inProject: data, root: project.deletingLastPathComponent().deletingLastPathComponent())
                )
            }
        }
        return found.sorted()
    }

    /// The bundle IDs of an Xcode project's app targets, read from its `project.pbxproj`.
    ///
    /// Each configuration's ID is worked out as Xcode does: from the target's settings, its
    /// `.xcconfig` file, then the project's settings and `.xcconfig`, with references to other
    /// settings such as `$(APP_BUNDLE_ID)` or `$(PRODUCT_NAME:rfc1034identifier)` filled in. `root` is
    /// the folder holding the `.xcodeproj`, where the project's file paths start; without it,
    /// `.xcconfig` files aren't read.
    static func appBundleIDs(inProject data: Data, root: URL? = nil) -> Set<String> {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let objects = plist["objects"] as? [String: [String: Any]]
        else { return [] }
        var parents: [String: String] = [:]
        for (id, object) in objects {
            for child in object["children"] as? [String] ?? [] { parents[child] = id }
        }
        let project = PBXProject(objects: objects, parents: parents, root: root)
        let rootList = (plist["rootObject"] as? String).flatMap { objects[$0]?["buildConfigurationList"] as? String }
        let projectSettings = Dictionary(
            project.configurations(of: rootList).map { ($0["name"] as? String ?? "", project.settings(of: $0)) },
            uniquingKeysWith: { first, _ in first }
        )
        var found = Set<String>()
        for target in objects.values
        where target["isa"] as? String == "PBXNativeTarget"
            && target["productType"] as? String == "com.apple.product-type.application"
        {
            for configuration in project.configurations(of: target["buildConfigurationList"] as? String) {
                var settings = ["TARGET_NAME": target["name"] as? String ?? "", "PRODUCT_NAME": "$(TARGET_NAME)"]
                settings = Self.settings(projectSettings[configuration["name"] as? String ?? ""] ?? [:], over: settings)
                settings = Self.settings(project.settings(of: configuration), over: settings)
                // A watch, TV, Mac or Vision app; the kit runs only on iOS.
                if let sdk = settings["SDKROOT"], ["watchos", "appletvos", "macosx", "xros"].contains(sdk) { continue }
                // The app on a device and in the simulator, which can each have their own ID.
                for sdk in ["iphoneos", "iphonesimulator"] {
                    let resolved = Self.settings(
                        settings,
                        sdk: sdk,
                        configuration: configuration["name"] as? String ?? ""
                    )
                    if let id = resolved["PRODUCT_BUNDLE_IDENTIFIER"].flatMap({ expand($0, with: resolved) }),
                        isLiteral(id)
                    {
                        found.insert(id)
                    }
                }
            }
        }
        return found
    }

    /// The parts of a `project.pbxproj` that settings are read from.
    private struct PBXProject {
        let objects: [String: [String: Any]]
        /// Each file and group's group.
        let parents: [String: String]
        let root: URL?

        func configurations(of list: String?) -> [[String: Any]] {
            let ids = list.flatMap { objects[$0]?["buildConfigurations"] as? [String] } ?? []
            return ids.compactMap { objects[$0] }
        }

        /// A configuration's settings over those of its `.xcconfig` file.
        func settings(of configuration: [String: Any]) -> [String: String] {
            var settings: [String: String] = [:]
            var file = (configuration["baseConfigurationReference"] as? String).flatMap { path(of: $0) }
            // Xcode 16 names a file inside a folder it keeps in sync by the folder and a path in it.
            if file == nil,
                let folder = (configuration["baseConfigurationReferenceAnchor"] as? String).flatMap({ path(of: $0) }),
                let relative = configuration["baseConfigurationReferenceRelativePath"] as? String
            {
                file = folder.appending(path: relative)
            }
            if let file { settings = ProjectApps.xcconfigSettings(at: file) }
            var own: [String: String] = [:]
            for case (let key, let value as String) in configuration["buildSettings"] as? [String: Any] ?? [:] {
                own[key] = value
            }
            return ProjectApps.settings(own, over: settings)
        }

        /// Where a file or group the project lists is.
        func path(of id: String, depth: Int = 0) -> URL? {
            guard let root, depth < 64, let object = objects[id] else { return nil }
            let path = object["path"] as? String
            switch object["sourceTree"] as? String ?? "<group>" {
            case "<absolute>":
                return path.map { URL(filePath: $0) }
            case "SOURCE_ROOT":
                return path.map { root.appending(path: $0) } ?? root
            case "<group>":
                let base = parents[id].flatMap { self.path(of: $0, depth: depth + 1) } ?? root
                return path.map { base.appending(path: $0) } ?? base
            default:
                return nil
            }
        }
    }

    /// The settings in an `.xcconfig` file and the files it includes.
    ///
    /// Settings for one SDK, configuration or architecture only, such as `KEY[sdk=iphoneos*]`, keep
    /// their condition in the key for `settings(_:sdk:configuration:)` to apply.
    static func xcconfigSettings(at file: URL, depth: Int = 0) -> [String: String] {
        guard depth < 8, let text = try? String(contentsOf: file, encoding: .utf8) else { return [:] }
        var settings: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = (raw.range(of: "//").map { raw[..<$0.lowerBound] } ?? raw).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#include") {
                let parts = line.split(separator: "\"", omittingEmptySubsequences: false)
                guard parts.count >= 3 else { continue }
                let path = String(parts[1])
                let included =
                    path.hasPrefix("/") ? URL(filePath: path) : file.deletingLastPathComponent().appending(path: path)
                settings = Self.settings(
                    xcconfigSettings(at: included, depth: depth + 1),
                    over: settings,
                    isSameLevel: true
                )
                continue
            }
            // The first "=" outside a condition such as `[sdk=iphoneos*]`.
            var isInCondition = false
            let equals = line.firstIndex { character in
                if character == "[" {
                    isInCondition = true
                } else if character == "]" {
                    isInCondition = false
                }
                return character == "=" && !isInCondition
            }
            guard let equals else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.hasSuffix(";") { value.removeLast() }
            settings = Self.settings(
                [key: value.trimmingCharacters(in: CharacterSet(charactersIn: " \t\""))],
                over: settings,
                isSameLevel: true
            )
        }
        return settings
    }

    /// One level of settings over the levels below it, as Xcode layers them: the project's
    /// `.xcconfig`, the project, the target's `.xcconfig`, then the target.
    ///
    /// `$(inherited)` in a setting becomes the value below it; where nothing below sets it yet, it
    /// stays for a lower level to fill in, and `expand` leaves it empty. A setting for every SDK
    /// replaces the lower levels' settings of it for one SDK; within one level (`isSameLevel`, such
    /// as later lines of one `.xcconfig`) both stay, and the one for the SDK wins when it applies.
    static func settings(
        _ upper: [String: String],
        over lower: [String: String],
        isSameLevel: Bool = false
    ) -> [String: String] {
        let plain = isSameLevel ? [] : Set(upper.keys.filter { !$0.contains("[") })
        var settings = lower.filter { key, _ in
            key.firstIndex(of: "[").map { !plain.contains(String(key[..<$0])) } ?? true
        }
        for (key, value) in upper {
            guard let below = lower[key] else {
                settings[key] = value
                continue
            }
            settings[key] = value.replacing("$(inherited)", with: below).replacing("${inherited}", with: below)
        }
        return settings
    }

    /// The settings as Xcode applies them when building `configuration`, such as `Debug`, for `sdk`,
    /// such as `iphoneos`: a setting for that SDK or configuration only, such as `KEY[sdk=iphoneos*]`
    /// or `KEY[config=Debug]`, over the setting for every one.
    ///
    /// Settings with other conditions, such as an architecture, are left out.
    static func settings(_ settings: [String: String], sdk: String, configuration: String = "") -> [String: String] {
        var resolved = settings.filter { !$0.key.contains("[") }
        for (key, value) in settings {
            guard let open = key.firstIndex(of: "["), key.hasSuffix("]") else { continue }
            let conditions = key[key.index(after: open)..<key.index(before: key.endIndex)].components(separatedBy: "][")
            let applies = conditions.allSatisfy { condition in
                let parts = condition.split(separator: "=", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                guard parts.count == 2 else { return false }
                switch parts[0] {
                case _ where parts[1] == "*": return true
                case "sdk": return fnmatch(parts[1], sdk, 0) == 0
                case "config": return fnmatch(parts[1], configuration, 0) == 0
                default: return false
                }
            }
            guard applies else { continue }
            let name = key[..<open].trimmingCharacters(in: .whitespaces)
            let below = settings[name] ?? ""
            resolved[name] = value.replacing("$(inherited)", with: below).replacing("${inherited}", with: below)
        }
        return resolved
    }

    /// A setting with its references to other settings filled in, such as `$(APP_BUNDLE_ID)`,
    /// `${TARGET_NAME}` or `$(PRODUCT_NAME:rfc1034identifier)`.
    ///
    /// Nil when one can't be.
    static func expand(_ value: String, with settings: [String: String], depth: Int = 0) -> String? {
        guard depth < 16 else { return nil }
        var result = ""
        var rest = Substring(value)
        while let dollar = rest.firstIndex(of: "$") {
            result += rest[..<dollar]
            let after = rest[rest.index(after: dollar)...]
            guard let open = after.first, open == "(" || open == "{" else { return nil }
            guard let end = after.firstIndex(of: open == "(" ? ")" : "}") else { return nil }
            let reference = after[after.index(after: after.startIndex)..<end]
            guard !reference.contains("$") else { return nil }
            let parts = reference.split(separator: ":", omittingEmptySubsequences: false)
            var filled = ""
            // `settings(_:over:)` has put in what each level inherits; what's left, nothing sets.
            if parts[0] != "inherited" {
                guard let setting = settings[String(parts[0])],
                    let expanded = expand(setting, with: settings, depth: depth + 1)
                else { return nil }
                filled = expanded
            }
            for modifier in parts.dropFirst() {
                switch modifier {
                case "rfc1034identifier":
                    filled = String(filled.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
                case "c99extidentifier", "identifier":
                    filled = String(filled.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_" })
                case "lower": filled = filled.lowercased()
                case "upper": filled = filled.uppercased()
                default: return nil
                }
            }
            result += filled
            rest = after[after.index(after: end)...]
        }
        return result + rest
    }

    /// Bundle IDs set in a `project.yml` (`PRODUCT_BUNDLE_IDENTIFIER: com.example.app`) or a
    /// `project.pbxproj` (`PRODUCT_BUNDLE_IDENTIFIER = com.example.app;`), whatever the target.
    static func bundleIDs(inSettings text: String) -> Set<String> {
        var found = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            guard let key = line.range(of: "PRODUCT_BUNDLE_IDENTIFIER") else { continue }
            // Commented out: `# PRODUCT_BUNDLE_IDENTIFIER: ...` in YAML, `// ...` elsewhere.
            let before = line[..<key.lowerBound]
            if before.contains("#") || before.contains("//") { continue }
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
        guard depth >= 0, let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
            return []
        }
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
