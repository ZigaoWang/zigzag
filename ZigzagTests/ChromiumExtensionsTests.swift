import Foundation
import Testing
@testable import Zigzag

/// Reading which extensions a Chromium profile added from the Chrome Web Store, from made-up preferences and
/// extension folders shaped like Chrome's.
struct ChromiumExtensionsTests {
    static let darkMode = String(repeating: "a", count: 32)
    static let component = String(repeating: "b", count: 32)
    static let unpacked = String(repeating: "c", count: 32)
    static let disabled = String(repeating: "d", count: 32)
    static let oldDisabled = String(repeating: "e", count: 32)
    static let theme = String(repeating: "f", count: 32)
    static let byDefault = String(repeating: "g", count: 32)
    static let otherStore = String(repeating: "h", count: 32)
    static let flagged = String(repeating: "i", count: 32)
    static let olderBuild = String(repeating: "j", count: 32)
    static let plainPreferences = String(repeating: "k", count: 32)

    /// A profile folder with both preferences files and the extensions' own folders.
    static func makeProfile() throws -> URL {
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent("zigzag-test-\(UUID().uuidString)/Default", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        func folder(_ id: String, _ version: String, _ manifest: [String: Any], messages: [String: Any]? = nil) throws {
            let dir = profile.appendingPathComponent("Extensions/\(id)/\(version)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: manifest).write(to: dir.appendingPathComponent("manifest.json"))
            if let messages {
                try FileManager.default.createDirectory(at: dir.appendingPathComponent("_locales/en"), withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: messages).write(to: dir.appendingPathComponent("_locales/en/messages.json"))
            }
        }
        let store = "https://clients2.google.com/service/update2/crx"
        // An older version folder beside the current one: the newest is read.
        try folder(darkMode, "4.9.0_0", ["name": "Old Name", "version": "4.9.0", "update_url": store])
        try folder(darkMode, "4.10.1_0", ["name": "__MSG_extName__", "default_locale": "en", "version": "4.10.1", "update_url": store],
                   messages: ["extname": ["message": "Dark Mode"]])
        try folder(component, "1.0", ["name": "Chrome PDF Viewer", "version": "1.0"])
        try folder(disabled, "1.0", ["name": "Turned Off", "version": "1.0", "update_url": store])
        try folder(oldDisabled, "1.0", ["name": "Turned Off Long Ago", "version": "1.0", "update_url": store])
        try folder(theme, "1.0", ["name": "Ocean Theme", "version": "1.0", "theme": ["colors": [:]], "update_url": store])
        try folder(byDefault, "1.0", ["name": "Docs Offline", "version": "1.0", "update_url": store])
        try folder(otherStore, "1.0", ["name": "From Edge's Store", "version": "1.0", "update_url": "https://edge.microsoft.com/extensionwebstorebase/v1/crx"])
        try folder(flagged, "1.0", ["name": "Flagged", "version": "1.0", "update_url": store])
        try folder(plainPreferences, "2.0", ["name": "Tab Counter", "version": "2.0", "update_url": store])
        let settings: [String: Any] = [
            darkMode: ["location": 1, "from_webstore": true, "path": "\(darkMode)/4.10.1_0", "state": 1],
            component: ["location": 5, "from_webstore": false],
            unpacked: ["location": 4, "path": "/Users/someone/code/my-extension", "manifest": ["name": "Mine", "version": "0.1"]],
            disabled: ["location": 1, "from_webstore": true, "disable_reasons": [1]],
            oldDisabled: ["location": 1, "from_webstore": true, "state": 0],
            theme: ["location": 1, "from_webstore": true],
            byDefault: ["location": 1, "from_webstore": true, "was_installed_by_default": true],
            otherStore: ["location": 1, "from_webstore": true],
            flagged: ["location": 1, "from_webstore": true, "blacklist_state": 1],
            // Older builds kept the manifest in the preferences and said "from the store" with a flag.
            olderBuild: ["location": 1, "creation_flags": 2, "manifest": ["name": "Old Style", "version": "3.0", "update_url": store]],
        ]
        try JSONSerialization.data(withJSONObject: ["extensions": ["settings": settings]]).write(to: profile.appendingPathComponent("Secure Preferences"))
        let plain: [String: Any] = [
            plainPreferences: ["location": 1, "from_webstore": true, "disable_reasons": 0],
            // The secure copy wins: turned off there, it stays behind even though this says on.
            disabled: ["location": 1, "from_webstore": true],
        ]
        try JSONSerialization.data(withJSONObject: ["extensions": ["settings": plain]]).write(to: profile.appendingPathComponent("Preferences"))
        return profile
    }

    @Test func keepsOnlyWebStoreExtensionsThatAreOn() throws {
        let profile = try Self.makeProfile()
        defer { try? FileManager.default.removeItem(at: profile.deletingLastPathComponent()) }
        let found = ChromiumExtensions.found(inProfile: profile)
        #expect(found.map(\.id) == [Self.darkMode, Self.olderBuild, Self.plainPreferences])
        // Its name in its own language file, from the newest version's folder.
        #expect(found.map(\.name) == ["Dark Mode", "Old Style", "Tab Counter"])
    }

    @Test func readsWhetherItsOff() {
        #expect(ChromiumExtensions.isDisabled(["state": 0]))
        #expect(ChromiumExtensions.isDisabled(["disable_reasons": [1]]))
        #expect(ChromiumExtensions.isDisabled(["disable_reasons": 8192]))
        #expect(!ChromiumExtensions.isDisabled(["disable_reasons": 0]))
        #expect(!ChromiumExtensions.isDisabled(["disable_reasons": []]))
        #expect(!ChromiumExtensions.isDisabled(["state": 1]))
    }

    @Test func refusesWhatIsntAnExtensionID() {
        #expect(!ChromiumExtensions.isFromWebStore(id: "not-an-id", entry: ["location": 1, "from_webstore": true]))
        #expect(!ChromiumExtensions.isFromWebStore(id: String(repeating: "z", count: 32), entry: ["location": 1, "from_webstore": true]))
        #expect(!ChromiumExtensions.isFromWebStore(id: Self.darkMode, entry: ["location": 1]))
        #expect(ChromiumExtensions.isFromWebStore(id: Self.darkMode, entry: ["location": 1, "from_webstore": true]))
    }

    /// A path in the preferences that leads out of the profile is never followed.
    @Test func neverReadsOutsideTheProfile() throws {
        let profile = try Self.makeProfile()
        defer { try? FileManager.default.removeItem(at: profile.deletingLastPathComponent()) }
        let outside = profile.deletingLastPathComponent().appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["name": "Elsewhere", "version": "1"]).write(to: outside.appendingPathComponent("manifest.json"))
        let id = String(repeating: "l", count: 32)
        let settings: [String: Any] = [id: ["location": 1, "from_webstore": true, "path": "../../elsewhere"]]
        try JSONSerialization.data(withJSONObject: ["extensions": ["settings": settings]]).write(to: profile.appendingPathComponent("Secure Preferences"))
        try Data("{}".utf8).write(to: profile.appendingPathComponent("Preferences"))
        #expect(ChromiumExtensions.found(inProfile: profile).isEmpty)
    }

    @Test func addsEachOnceAndNoneAlreadyHere() {
        let chrome = [ChromiumExtensions.Found(id: Self.darkMode, name: "Dark Mode", source: "Chrome"),
                      ChromiumExtensions.Found(id: Self.olderBuild, name: "Old Style", source: "Chrome")]
        let arc = [ChromiumExtensions.Found(id: Self.darkMode, name: "Dark Mode", source: "Arc"),
                   ChromiumExtensions.Found(id: Self.plainPreferences, name: "Tab Counter", source: "Arc")]
        let toAdd = ChromiumExtensions.toAdd(chrome + arc, installed: [Self.olderBuild])
        #expect(toAdd.map(\.id) == [Self.darkMode, Self.plainPreferences])
        // The first browser it was found in keeps it.
        #expect(toAdd.first?.source == "Chrome")
    }
}
