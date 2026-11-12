import AppKit
import CoreServices

/// Makes the small app for a site installed as an app: Info.plist, the icon, the marker, and the launcher copied out of
/// Zigzag, signed on this Mac (ad hoc, as Chrome signs its app shims), in ~/Applications/Zigzag Apps. Made apart and
/// moved into place whole, so a half-made app never shows in Finder or the Dock.
nonisolated enum WebAppBundle {
    struct Spec {
        var id: String
        var name: String
        var url: URL
        /// The Zigzag the app opens in: its bundle id and where it is.
        var host: String
        var hostPath: String
        /// Zigzag's own copy of the launcher.
        var launcher: URL
        var icns: Data
        /// What the app says when that Zigzag is gone, in the language Zigzag speaks now.
        var missingHostMessage: String
    }

    enum Failure: Error, Equatable {
        case noLauncher
        case signing(String)
    }

    static func infoPlist(_ spec: Spec) -> [String: Any] {
        [
            "CFBundleIdentifier": WebApps.bundleIdentifier(host: spec.host, id: spec.id),
            "CFBundleName": spec.name,
            "CFBundleDisplayName": spec.name,
            "CFBundleExecutable": WebApps.launcherName,
            "CFBundleIconFile": "AppIcon",
            "CFBundlePackageType": "APPL",
            "CFBundleSignature": "????",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "CFBundleDevelopmentRegion": "en",
            "LSMinimumSystemVersion": "15.4",
            "LSApplicationCategoryType": "public.app-category.productivity",
            // An app with a Dock icon and a place in ⌘Tab, one copy at a time.
            "LSUIElement": false,
            "LSMultipleInstancesProhibited": true,
            "NSPrincipalClass": "NSApplication",
            "NSHighResolutionCapable": true,
            // It has no windows of its own: macOS mustn't take that for idle and end it.
            "NSSupportsAutomaticTermination": false,
            "NSSupportsSuddenTermination": true,
            "ZigzagWebAppID": spec.id,
            "ZigzagWebAppURL": spec.url.absoluteString,
            "ZigzagHostBundleIdentifier": spec.host,
            "ZigzagHostPath": spec.hostPath,
            "ZigzagMissingHostMessage": spec.missingHostMessage,
        ]
    }

    static func marker(_ spec: Spec) -> WebApps.Marker {
        WebApps.Marker(kind: WebApps.markerKind, id: spec.id, host: spec.host, name: spec.name, url: spec.url)
    }

    /// Where the app goes in `folder`: its name, or "Name 2" and on when another app has that name. `own` is where
    /// this app already is, which it may take again.
    static func destination(for spec: Spec, in folder: URL, own: URL?) -> URL {
        let base = WebApps.fileName(for: spec.name, fallback: spec.url.host() ?? "Web App")
        var n = 1
        while true {
            let name = n == 1 ? base : "\(base) \(n)"
            let candidate = folder.appendingPathComponent("\(name).app", isDirectory: true)
            let taken = FileManager.default.fileExists(atPath: candidate.path)
            if !taken || candidate.standardizedFileURL == own?.standardizedFileURL
                || WebApps.isMadeByZigzag(candidate, id: spec.id, host: spec.host) { return candidate }
            n += 1
        }
    }

    /// Writes the app's parts into an empty folder `bundle` (named .app), unsigned.
    static func write(_ spec: Spec, to bundle: URL) throws {
        let fm = FileManager.default
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: infoPlist(spec), format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        try Data("APPL????".utf8).write(to: contents.appendingPathComponent("PkgInfo"))
        // Read and written afresh rather than copied, so none of Zigzag's own file attributes come along to trouble
        // the signature.
        guard let program = try? Data(contentsOf: spec.launcher), !program.isEmpty else { throw Failure.noLauncher }
        let executable = macOS.appendingPathComponent(WebApps.launcherName)
        try program.write(to: executable)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try spec.icns.write(to: resources.appendingPathComponent("AppIcon.icns"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(marker(spec)).write(to: resources.appendingPathComponent(WebApps.markerName))
    }

    /// Signs the app on this Mac, as it was made here: an ad hoc signature, which Apple silicon needs to run it at all.
    /// Gatekeeper looks only at apps that came from elsewhere (quarantined); one made here is never asked about.
    static func sign(_ bundle: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", "--timestamp=none", bundle.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let said = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw Failure.signing(said.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Makes the app in `folder` and returns where it is. Replaces this app's earlier copy (`old`, only if Zigzag made
    /// it), which may have had another name.
    static func install(_ spec: Spec, in folder: URL, replacing old: URL?) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let previous = old.flatMap { WebApps.isMadeByZigzag($0, id: spec.id, host: spec.host) ? $0 : nil }
        let staging = folder.appendingPathComponent(".\(spec.id).partial.app", isDirectory: true)
        try? fm.removeItem(at: staging)
        do {
            try write(spec, to: staging)
            try sign(staging)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        let target = destination(for: spec, in: folder, own: previous)
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.moveItem(at: staging, to: target)
        if let previous, previous.standardizedFileURL != target.standardizedFileURL { try? fm.removeItem(at: previous) }
        // Launch Services hears of it now, so the Dock, Spotlight and Launchpad have its name and icon at once.
        LSRegisterURL(target as CFURL, true)
        return target
    }
}

/// Installing from a tab: the icon drawn, the app made off the main thread, the list updated.
@MainActor
enum WebAppInstaller {
    static var launcher: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/\(WebApps.launcherName)") }

    static var missingHostMessage: String {
        String(localized: "This app opens in Zigzag, which isn’t on this Mac anymore.", comment: "Shown by an app made with Install as App when the Zigzag that made it is gone.")
    }

    /// Opens the app just installed, as Chrome does: its small app starts and its window comes forward. The one it
    /// replaced may still be on its way out; it waits for that first (briefly), so the new one isn't taken for it.
    static func launch(_ app: WebApp, attempt: Int = 0) {
        if !WebAppStore.runningLauncher(of: app.id).allSatisfy(\.isTerminated), attempt < 20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { launch(app, attempt: attempt + 1) }
            return
        }
        guard let bundle = WebAppStore.shared.bundle(of: app) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { _, error in
            guard let error else { return }
            DispatchQueue.main.async { Diagnostics.note("Opening an installed app failed", site: app.url.host(), "\(error)") }
        }
    }

    /// Makes the app for `url` on `space`'s profile, named `name`, with `icon` (the 1024 one). `done` hears the record,
    /// or nil if it couldn't be made.
    static func install(name: String, url: URL, spaceID: UUID, icon: CGImage, folder: URL = WebApps.folder,
                        done: @escaping (WebApp?) -> Void) {
        let profileID = Library.shared.profileID(ofSpace: spaceID)
        let id = WebApps.makeID(url: url, profileID: profileID)
        let host = Bundle.main.bundleIdentifier ?? "wang.zigao.zigzag"
        let old = WebAppStore.shared.app(id).flatMap { WebAppStore.shared.bundle(of: $0) }
        guard let icns = WebAppIcon.icns(from: icon) else { done(nil); return }
        let spec = WebAppBundle.Spec(id: id, name: name, url: url, host: host, hostPath: Bundle.main.bundlePath,
                                     launcher: launcher, icns: icns, missingHostMessage: missingHostMessage)
        // Open already: its window and its small app close first, so the new one takes their place.
        WebAppWindowController.controller(for: id)?.window?.close()
        WebAppStore.runningLauncher(of: id).forEach { $0.terminate() }
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try WebAppBundle.install(spec, in: folder, replacing: old) } }.value
            switch result {
            case .success(let bundle):
                let app = WebApp(id: id, name: name, url: url, profileID: profileID, spaceID: spaceID, bundlePath: bundle.path, created: Date())
                WebAppStore.shared.save(app)
                Diagnostics.note("Installed as app", site: url.host())
                done(app)
            case .failure(let error):
                Diagnostics.note("Install as app failed", site: url.host(), "\(error)")
                done(nil)
            }
        }
    }
}
