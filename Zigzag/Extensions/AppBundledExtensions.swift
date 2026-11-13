import Foundation

/// Chrome extensions that come inside an app on this Mac (#194). StopTheMadness Pro, bought in the App Store, carries
/// one for Chrome at StopTheMadness Pro.app/Contents/MacOS/StopTheMadness Chrome.app/Contents/Resources/chromium,
/// and Settings › Extensions offers it, and any like it, under From Apps on This Mac.
///
/// Found by looking, not from a list of apps: the folders right inside an app's Resources, and inside the Resources
/// of the apps it holds one level down, that have a manifest.json with a manifest_version. Nothing deeper, so a
/// look through Applications takes a moment. Installed, one is read where it is, as Install from Folder reads any
/// folder: never copied and never changed, so the app's own updates update the extension.
nonisolated enum AppBundledExtensions {
    struct Found: Equatable, Sendable {
        /// The app in Applications it comes with.
        let app: URL
        /// The extension's own folder, the one with manifest.json.
        let folder: URL

        /// The app as Finder names it ("StopTheMadness Pro").
        var appName: String { AppBundledExtensions.name(of: app) }
    }

    /// /Applications, or in a debug test copy, ZIGZAG_APPLICATIONS_DIR's folder of made-up apps.
    static let applications: URL = {
        #if DEBUG
        if let custom = ProcessInfo.processInfo.environment["ZIGZAG_APPLICATIONS_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        #endif
        return URL(fileURLWithPath: "/Applications", isDirectory: true)
    }()

    /// Where an app keeps the apps that come inside it.
    private static let helperPlaces = ["MacOS", "Resources", "Helpers", "Applications", "Library/LoginItems", "SharedSupport"]

    /// Every app's extensions, the apps by name.
    static func find(in folder: URL = applications) -> [Found] {
        let apps = children(of: folder).filter { $0.pathExtension == "app" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return apps.flatMap(find(inApp:))
    }

    /// The extensions in one app: its own Resources, then those of the apps inside it.
    static func find(inApp app: URL) -> [Found] {
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        var places = [contents.appendingPathComponent("Resources", isDirectory: true)]
        for place in helperPlaces {
            for helper in children(of: contents.appendingPathComponent(place, isDirectory: true)) where helper.pathExtension == "app" {
                places.append(helper.appendingPathComponent("Contents/Resources", isDirectory: true))
            }
        }
        var found: [Found] = []
        for resources in places {
            for folder in children(of: resources) where isCandidate(folder) && isExtension(folder) {
                found.append(Found(app: app, folder: folder))
            }
        }
        return found
    }

    /// A folder that could hold an extension: not a language's strings, a bundle or another app.
    private static func isCandidate(_ folder: URL) -> Bool {
        let skipped: Set<String> = ["lproj", "bundle", "framework", "app", "appex", "plugin", "nib", "storyboardc", "car", "xpc"]
        guard !skipped.contains(folder.pathExtension.lowercased()), !folder.lastPathComponent.hasPrefix(".") else { return false }
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder) && isFolder.boolValue
    }

    /// A folder whose manifest.json says it's an extension: a manifest_version of 2 or 3, and a name.
    static func isExtension(_ folder: URL) -> Bool {
        let manifest = folder.appendingPathComponent("manifest.json")
        guard let size = (try? FileManager.default.attributesOfItem(atPath: manifest.path))?[.size] as? Int, size < 1_000_000,
              let data = try? Data(contentsOf: manifest),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["manifest_version"] as? Int, (2...3).contains(version),
              let name = json["name"] as? String, !name.isEmpty else { return false }
        return true
    }

    /// The app an extension's folder is inside, by name, when it's in one: the outermost app on its path.
    static func app(containing path: String) -> String? {
        let parts = URL(fileURLWithPath: path).pathComponents
        guard let index = parts.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return name(of: URL(fileURLWithPath: NSString.path(withComponents: Array(parts[...index]))))
    }

    static func name(of app: URL) -> String {
        let shown = FileManager.default.displayName(atPath: app.path)
        return shown.hasSuffix(".app") ? String(shown.dropLast(4)) : shown
    }

    private static func children(of folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    }
}
