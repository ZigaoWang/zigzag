import AppKit
import CryptoKit

/// A site installed as an app (File › Install as App…, #165): a small app of its own in ~/Applications/Zigzag Apps,
/// with the site's name and icon, so it has its own Dock icon and ⌘Tab entry. That app (`ZigzagWebApp`) only stands
/// for the site: opening or choosing it asks Zigzag, over a zigzag-webapp: link, to show the site in a window of its
/// own (`WebAppWindowController`), on the profile it was installed from, so you stay signed in.
///
/// Why the page runs in Zigzag and not in the small app: a website data store belongs to the app that made it (WebKit
/// keeps it under that app's bundle id) and two processes can't share one while both run, so a page in the small app
/// would be signed out of everything, without the profile's extensions, passwords or blocking. Chrome's app shims on
/// the Mac stand in for their sites the same way.
nonisolated struct WebApp: Codable, Equatable {
    /// 16 lowercase hex digits, from the profile and the address (`WebApps.makeID`).
    var id: String
    var name: String
    /// Where it opens.
    var url: URL
    /// The profile it was installed from, whose sign-ins it uses.
    var profileID: UUID
    /// The space it was installed from, whose profile the page uses. Another of the profile's spaces if it's gone.
    var spaceID: UUID
    /// Where the app was made. Found again by its bundle id if it was moved.
    var bundlePath: String
    var created: Date
    /// The toolbar turned off (Show Toolbar): the window is just the page, with the traffic lights over it. Nil, as
    /// for an app installed before there was a choice, is on.
    var hidesToolbar: Bool? = nil
    /// The color the site's manifest gives its app (`theme_color`, "#0d1117"), for the toolbar when the page names
    /// none of its own.
    var themeColor: String? = nil

    var showsToolbar: Bool { hidesToolbar != true }
}

/// The links between an installed app and Zigzag: "zigzag-webapp://open/<id>" when the app is opened or chosen, and
/// "zigzag-webapp://close/<id>" when it's quit from its Dock menu. Only the app sends them, to the Zigzag that made it.
nonisolated enum WebAppLink {
    static let scheme = "zigzag-webapp"

    enum Action: String { case open, close }

    static func make(_ action: Action, id: String) -> URL {
        URL(string: "\(scheme)://\(action.rawValue)/\(id)")!
    }

    /// The action and the app's id, or nil for anything else, an id that isn't one included.
    static func parse(_ url: URL) -> (action: Action, id: String)? {
        guard url.scheme?.lowercased() == scheme, let action = url.host().flatMap({ Action(rawValue: $0.lowercased()) }) else { return nil }
        let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard WebApps.isValidID(id), url.query == nil, url.fragment == nil else { return nil }
        return (action, id)
    }
}

/// The installed apps, the folder they go in, and the rules for making and removing them.
nonisolated enum WebApps {
    /// The file inside an app that says Zigzag made it, and for which app: removing one checks it first.
    static let markerName = "ZigzagWebApp.json"
    static let markerKind = "zigzag-web-app"
    /// The small app's program, inside Zigzag (Contents/MacOS) and inside every app it makes.
    static let launcherName = "ZigzagWebApp"

    /// What `markerName` holds.
    struct Marker: Codable, Equatable {
        var kind: String
        var id: String
        /// The bundle id of the Zigzag that made it.
        var host: String
        var name: String
        var url: URL
    }

    /// The profile among `profiles` this app id was made on. An id encodes profile and address, so a changed address or
    /// a non-web one matches none.
    static func profile(madeID id: String, url: URL, among profiles: [UUID]) -> UUID? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host() != nil else { return nil }
        return profiles.first { makeID(url: url, profileID: $0) == id }
    }

    /// The same site on the same profile is the same app: installing it again replaces it.
    static func makeID(url: URL, profileID: UUID) -> String {
        let digest = SHA256.hash(data: Data("\(profileID.uuidString.lowercased())|\(url.absoluteString)".utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func isValidID(_ id: String) -> Bool {
        id.count == 16 && id.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// Each app's bundle id, under the Zigzag that made it: wang.zigao.zigzag.app.<id>.
    static func bundleIdentifier(host: String, id: String) -> String { "\(host).app.\(id)" }

    /// ~/Applications/Zigzag Apps (the dev build's, Zigzag Dev Apps). Debug builds take ZIGZAG_WEBAPPS_DIR instead, so
    /// a test copy never writes to the real Applications folder.
    static var folder: URL {
        #if DEBUG
        if let custom = ProcessInfo.processInfo.environment["ZIGZAG_WEBAPPS_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        #endif
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Zigzag"
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("\(name) Apps", isDirectory: true)
    }

    /// A name Finder takes as a file name: no slashes or colons, no leading dot, not too long; the site's host when
    /// nothing is left.
    static func fileName(for name: String, fallback: String) -> String {
        var cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .components(separatedBy: .controlCharacters).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = String(cleaned.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : cleaned
    }

    /// Whether the app at `bundle` is one this Zigzag made for the app `id`: an .app folder (not a link to one), not
    /// Zigzag itself, holding the marker with that id and this Zigzag's bundle id, and with the bundle id Zigzag gave it.
    /// Nothing else is ever removed.
    static func isMadeByZigzag(_ bundle: URL, id: String, host: String, zigzag: URL = Bundle.main.bundleURL) -> Bool {
        guard isValidID(id), bundle.pathExtension.lowercased() == "app" else { return false }
        let values = try? bundle.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else { return false }
        guard bundle.standardizedFileURL.resolvingSymlinksInPath() != zigzag.standardizedFileURL.resolvingSymlinksInPath() else { return false }
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        guard let data = try? Data(contentsOf: contents.appendingPathComponent("Resources/\(markerName)")),
              let marker = try? JSONDecoder().decode(Marker.self, from: data),
              marker.kind == markerKind, marker.id == id, marker.host == host else { return false }
        guard let plist = NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist")),
              plist["CFBundleIdentifier"] as? String == bundleIdentifier(host: host, id: id),
              plist["ZigzagWebAppID"] as? String == id else { return false }
        return true
    }

    /// The disk a path is on when it isn't the startup disk, as "/Volumes/<name>", with the links along the path
    /// followed, also ones to a disk that isn't there. Nil for the startup disk.
    static func volumeRoot(of path: String) -> String? {
        let parts = followingLinks(path).split(separator: "/")
        guard parts.count >= 2, parts[0] == "Volumes" else { return nil }
        return "/Volumes/\(parts[1])"
    }

    /// The path with each link along it followed, also when a link points at something that isn't there now.
    static func followingLinks(_ path: String) -> String {
        func components(_ path: String) -> [String] { path.split(separator: "/").map(String.init).filter { $0 != "." } }
        var done = "/"
        var rest = components(path)
        var hops = 0
        while !rest.isEmpty {
            let part = rest.removeFirst()
            if part == ".." { done = (done as NSString).deletingLastPathComponent; continue }
            let next = (done as NSString).appendingPathComponent(part)
            if hops < 32, let target = try? FileManager.default.destinationOfSymbolicLink(atPath: next) {
                hops += 1
                rest = components(target.hasPrefix("/") ? target : (done as NSString).appendingPathComponent(target)) + rest
                done = "/"
            } else {
                done = next
            }
        }
        return done
    }

    /// The disks mounted now, as their mount points ("/Volumes/<name>").
    static func mountedVolumes() -> Set<String> {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
        return Set(urls.map { $0.standardizedFileURL.path })
    }

    /// Where a link from the app's window goes: true to the browser, false to stay. Only a link you click to another
    /// site leaves; a sign-in page, and anything the site does on its own (redirects, forms), stay in the window.
    static func opensInBrowser(_ url: URL, from here: URL, isLinkClick: Bool) -> Bool {
        guard isLinkClick, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        return Tab.leavesSite(from: here, to: url)
    }
}

/// The list of installed apps, kept in WebApps.json in Zigzag's data folder.
final class WebAppStore {
    static let shared = WebAppStore(file: Paths.file("WebApps.json"), volumes: NSWorkspace.shared.notificationCenter)

    private let file: URL
    private(set) var apps: [WebApp]
    /// Sent when one is installed or removed, and when a disk is connected or ejected.
    let changed = Signal<Void>()
    /// The disks mounted now (`WebApps.mountedVolumes`); tests give their own.
    var mountedVolumes: () -> Set<String> = WebApps.mountedVolumes
    private var volumeWatch: VolumeWatch?

    /// `volumes`: where disks being connected and ejected are heard, NSWorkspace's for the shared list.
    init(file: URL, volumes: NotificationCenter? = nil) {
        self.file = file
        apps = JSONStore.load([WebApp].self, from: file) ?? []
        volumeWatch = volumes.map { VolumeWatch(center: $0) { [weak self] in self?.changed.send() } }
    }

    /// Hears disks being connected and ejected until it goes away.
    private nonisolated final class VolumeWatch {
        private let center: NotificationCenter
        private let observers: [NSObjectProtocol]

        init(center: NotificationCenter, then run: @escaping @MainActor () -> Void) {
            self.center = center
            observers = [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification].map { name in
                center.addObserver(forName: name, object: nil, queue: .main) { _ in MainActor.assumeIsolated { run() } }
            }
        }

        deinit { observers.forEach(center.removeObserver) }
    }

    func app(_ id: String) -> WebApp? { apps.first { $0.id == id } }

    func save(_ app: WebApp) {
        if let i = apps.firstIndex(where: { $0.id == app.id }) { apps[i] = app } else { apps.append(app) }
        persist()
    }

    /// Settings › General's switch, and Show Toolbar in the app's own View menu.
    func setShowsToolbar(_ on: Bool, for id: String) {
        guard var app = app(id), app.showsToolbar != on else { return }
        app.hidesToolbar = on ? nil : true
        save(app)
    }

    func forget(_ id: String) {
        apps.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        JSONStore.save(apps, to: file)
        changed.send()
    }

    /// Where the app is now: where it was made, or, moved, wherever Launch Services finds its bundle id. Only one
    /// Zigzag made.
    func bundle(of app: WebApp, host: String = Bundle.main.bundleIdentifier ?? "") -> URL? {
        let made = URL(fileURLWithPath: app.bundlePath, isDirectory: true)
        if WebApps.isMadeByZigzag(made, id: app.id, host: host) { return made }
        if let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: WebApps.bundleIdentifier(host: host, id: app.id)),
           WebApps.isMadeByZigzag(found, id: app.id, host: host) { return found }
        return nil
    }

    /// Show in Finder: the app's bundle selected in a Finder window, wherever it is now. False when it's gone.
    @discardableResult
    func revealInFinder(_ app: WebApp) -> Bool {
        guard let bundle = bundle(of: app) else { return false }
        NSWorkspace.shared.activateFileViewerSelecting([bundle])
        return true
    }

    /// Where an app's bundle is: found, on a disk that isn't connected now, or gone.
    enum Place: Equatable { case found(URL), diskNotConnected, gone }

    func place(of app: WebApp, host: String = Bundle.main.bundleIdentifier ?? "") -> Place {
        if let bundle = bundle(of: app, host: host) { return .found(bundle) }
        if let root = WebApps.volumeRoot(of: app.bundlePath), !mountedVolumes().contains(root) { return .diskNotConnected }
        return .gone
    }

    /// Apps that were thrown away in Finder leave the list. One on a disk that isn't connected stays, and is back
    /// when the disk is.
    func pruneMissing() {
        let gone = apps.filter { place(of: $0) == .gone }.map(\.id)
        guard !gone.isEmpty else { return }
        apps.removeAll { gone.contains($0.id) }
        persist()
    }

    /// What a zigzag-webapp: link asks: the app's window shown, or closed.
    /// `sender`: the process that sent it, if known.
    static func handle(_ link: URL, from sender: pid_t? = nil) {
        guard let (action, id) = WebAppLink.parse(link) else { return }
        switch action {
        case .open:
            // Web addresses only; anything else isn't a Zigzag app.
            guard let app = shared.app(id) ?? shared.recover(id), ["http", "https"].contains(app.url.scheme?.lowercased() ?? "") else { return }
            WebAppWindowController.show(app, from: sender)
        case .close:
            WebAppWindowController.controller(for: id)?.window?.close()
        }
    }

    /// Recovers a Zigzag-made app whose record is lost, reading it from the app bundle on its profile. Its id must
    /// match what Zigzag gives that address on one of your profiles.
    func recover(_ id: String) -> WebApp? {
        let host = Bundle.main.bundleIdentifier ?? ""
        guard let bundle = NSWorkspace.shared.urlForApplication(withBundleIdentifier: WebApps.bundleIdentifier(host: host, id: id)),
              WebApps.isMadeByZigzag(bundle, id: id, host: host),
              let data = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Resources/\(WebApps.markerName)")),
              let marker = try? JSONDecoder().decode(WebApps.Marker.self, from: data) else { return nil }
        let spaces = Library.shared.spaces
        var profiles: [UUID] = []
        for space in spaces where !profiles.contains(Library.shared.profileID(ofSpace: space.id)) { profiles.append(Library.shared.profileID(ofSpace: space.id)) }
        guard let profile = WebApps.profile(madeID: id, url: marker.url, among: profiles),
              let space = spaces.first(where: { Library.shared.profileID(ofSpace: $0.id) == profile }) else { return nil }
        let app = WebApp(id: id, name: marker.name, url: marker.url, profileID: profile, spaceID: space.id,
                         bundlePath: bundle.path, created: Date())
        save(app)
        return app
    }

    /// The small app's running process, if it is.
    static func runningLauncher(of id: String) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: WebApps.bundleIdentifier(host: Bundle.main.bundleIdentifier ?? "", id: id))
    }

    /// Removes an app: its window closes, its small app quits, and the app is deleted. Only an app Zigzag made
    /// (`WebApps.isMadeByZigzag`); one that's already gone just leaves the list.
    func remove(_ id: String) {
        guard let app = app(id) else { return }
        WebAppWindowController.controller(for: id)?.window?.close()
        Self.runningLauncher(of: id).forEach { $0.terminate() }
        if let bundle = bundle(of: app) {
            try? FileManager.default.removeItem(at: bundle)
        }
        forget(id)
    }
}
