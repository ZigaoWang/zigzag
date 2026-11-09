import Foundation

/// The extensions a Chromium profile has added from the Chrome Web Store, read from its preferences and its
/// `Extensions/<id>/<version>/manifest.json` folders. Only their IDs and names come over: each is downloaded again
/// from the store and checked as if you added it here yourself.
///
/// Left behind: what the browser put there itself (component, default and policy installs), unpacked ones,
/// themes and apps, ones from another store (Edge's, Opera's), and ones turned off there. Off is a choice
/// you made, or the browser made for you (it asked for more, or was flagged), so it stays off by staying behind,
/// as Edge's and Arc's imports do.
nonisolated enum ChromiumExtensions {
    struct Found: Sendable, Hashable {
        let id: String
        let name: String
        /// The browser it came from ("Chrome (Work)"), for the summary.
        var source: String = ""
    }

    /// Chrome's `Manifest::Location::kInternal`: added by the person, from the store or a .crx.
    static let internalLocation = 1
    /// Chrome's `Extension::FROM_WEBSTORE` creation flag.
    static let fromWebStoreFlag = 1 << 1
    static let webStoreUpdateHost = "clients2.google.com"

    /// Every profile of the browser, once each, by name.
    static func found(in browser: ChromiumImporter.Browser, source: String) -> [Found] {
        var seen = Set<String>()
        return ChromiumImporter.profiles(of: browser).flatMap { found(inProfile: $0) }
            .filter { seen.insert($0.id).inserted }
            .map { Found(id: $0.id, name: $0.name, source: source) }
    }

    /// One profile folder's Web Store extensions, by name.
    static func found(inProfile profile: URL) -> [Found] {
        // macOS Chrome keeps them in Secure Preferences; older builds and some browsers in Preferences. Both are
        // read, the secure copy winning.
        var settings: [String: [String: Any]] = [:]
        for file in ["Preferences", "Secure Preferences"] {
            guard let data = try? Data(contentsOf: profile.appendingPathComponent(file)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entries = (json["extensions"] as? [String: Any])?["settings"] as? [String: Any] else { continue }
            for (id, entry) in entries { if let entry = entry as? [String: Any] { settings[id, default: [:]].merge(entry) { _, new in new } } }
        }
        let folder = profile.appendingPathComponent("Extensions", isDirectory: true)
        return settings.compactMap { id, entry in
            guard isFromWebStore(id: id, entry: entry), let package = package(id, entry: entry, in: folder) else { return nil }
            let manifest = package.manifest
            // Themes and apps aren't extensions here; one updated from elsewhere isn't in the Chrome Web Store.
            guard manifest["theme"] == nil, manifest["app"] == nil else { return nil }
            if let update = manifest["update_url"] as? String, URL(string: update)?.host() != webStoreUpdateHost { return nil }
            return Found(id: id, name: name(manifest, in: package.folder) ?? id)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Added by the person from the Chrome Web Store, and on.
    static func isFromWebStore(id: String, entry: [String: Any]) -> Bool {
        guard id.count == 32, id.allSatisfy({ ("a"..."p").contains($0) }),
              entry["location"] as? Int == internalLocation else { return false }
        let flags = entry["creation_flags"] as? Int ?? 0
        guard entry["from_webstore"] as? Bool == true || flags & fromWebStoreFlag != 0 else { return false }
        // Put there by the browser or the Mac's maker, not by you.
        if entry["was_installed_by_default"] as? Bool == true || entry["was_installed_by_oem"] as? Bool == true { return false }
        // Flagged as harmful by Google.
        if entry["blacklist"] as? Bool == true || (entry["blacklist_state"] as? Int ?? 0) > 0 || (entry["blocklist_state"] as? Int ?? 0) > 0 { return false }
        return !isDisabled(entry)
    }

    /// Off there: older builds say `state: 0`, newer ones list why (`disable_reasons`, a number or a list).
    static func isDisabled(_ entry: [String: Any]) -> Bool {
        if entry["state"] as? Int == 0 { return true }
        switch entry["disable_reasons"] {
        case let reasons as Int: return reasons != 0
        case let reasons as [Any]: return !reasons.isEmpty
        default: return false
        }
    }

    /// Its manifest: in the preferences on older builds, else in its newest version's folder inside the profile's
    /// own Extensions folder (never a path that leads out of it).
    private static func package(_ id: String, entry: [String: Any], in extensions: URL) -> (manifest: [String: Any], folder: URL?)? {
        let root = extensions.appendingPathComponent(id, isDirectory: true)
        var folders: [URL] = []
        if let path = entry["path"] as? String, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") {
            folders.append(extensions.appendingPathComponent(path, isDirectory: true))
        }
        let versions = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { !$0.hasPrefix(".") && !$0.contains("..") }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        folders += versions.map { root.appendingPathComponent($0, isDirectory: true) }
        for folder in folders {
            if let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
               let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return (manifest, folder) }
        }
        if let manifest = entry["manifest"] as? [String: Any] { return (manifest, folders.first) }
        return nil
    }

    /// Its name as the browser shows it: "__MSG_appName__" looked up in its default language's messages.
    static func name(_ manifest: [String: Any], in folder: URL?) -> String? {
        guard let raw = (manifest["name"] as? String)?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        guard raw.hasPrefix("__MSG_"), raw.hasSuffix("__"), raw.count > 8 else { return raw }
        let key = raw.dropFirst(6).dropLast(2).lowercased()
        guard let folder else { return nil }
        for locale in [manifest["default_locale"] as? String, "en", "en_US"].compactMap({ $0 }) {
            guard !locale.contains("/"), let data = try? Data(contentsOf: folder.appendingPathComponent("_locales/\(locale)/messages.json")),
                  let messages = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let entry = messages.first { $0.key.lowercased() == key }?.value as? [String: Any]
            if let message = (entry?["message"] as? String)?.trimmingCharacters(in: .whitespaces), !message.isEmpty { return message }
        }
        return nil
    }

    /// What's left to add: once each across browsers and profiles, the first one found keeping it, and none
    /// Zigzag has already.
    static func toAdd(_ found: [Found], installed: Set<String>) -> [Found] {
        var seen = installed
        return found.filter { seen.insert($0.id).inserted }
    }
}
