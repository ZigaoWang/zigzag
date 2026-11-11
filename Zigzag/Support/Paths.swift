import Foundation
import os

nonisolated enum Paths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // The dev build keeps its data apart from the Zigzag you use.
        let isDev = Bundle.main.bundleIdentifier?.hasSuffix(".dev") ?? false
        var dir = base.appendingPathComponent(isDev ? "Zigzag Dev" : "Zigzag", isDirectory: true)
        #if DEBUG
        // A second debug copy (for staged screenshots) keeps its own data, apart from the dev build's.
        if let custom = ProcessInfo.processInfo.environment["ZIGZAG_DATA_DIR"], !custom.isEmpty { dir = URL(fileURLWithPath: custom, isDirectory: true) }
        #endif
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func file(_ name: String) -> URL { support.appendingPathComponent(name) }

    static func directory(_ name: String) -> URL {
        let dir = support.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static let library = file("Library.json")
    static let profiles = file("Profiles.json")
    static let session = file("Session.json")
    static let downloads = file("Downloads.json")
    static let history = file("History.sqlite")
    static let favicons = directory("Favicons")
    /// Icons that clearing history set aside, so ⌘Z can put them back. Emptied when Zigzag starts.
    static let setAsideIcons = support.appendingPathComponent("Cleared Icons", isDirectory: true)
    static let tabState = directory("TabState")
    static let snapshots = directory("Snapshots")
}

nonisolated enum JSONStore {
    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else {
            // There but can't be read (its permissions, a disk error): set aside too, so a fresh start can't save
            // over it.
            if FileManager.default.fileExists(atPath: url.path) { setAside(url) }
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        if let value = try? decoder.decode(type, from: data) { return value }
        // There, but unreadable (cut short, or written by a newer Zigzag): kept aside, never written over, so
        // starting fresh can't erase it and it can still be recovered.
        setAside(url)
        return nil
    }

    private static func setAside(_ url: URL) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let aside = url.deletingPathExtension().appendingPathExtension("unreadable-\(stamp).\(url.pathExtension)")
        try? FileManager.default.moveItem(at: url, to: aside)
    }

    /// Whether it was written: for what must be on disk before something that can't be undone goes ahead.
    @discardableResult
    static func save<T: Encodable>(_ value: T, to url: URL) -> Bool {
        guard let data = encode(value) else { return false }
        return write(data, to: url)
    }

    /// What `save` writes, for comparing with what was written last.
    static func encode<T: Encodable>(_ value: T) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try? encoder.encode(value)
    }

    @discardableResult
    static func write(_ data: Data, to url: URL) -> Bool {
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            tellOnce(error)
            return false
        }
    }

    /// A save that failed (the disk full, a folder you can't write to) is said once a run, in the front window, so
    /// work doesn't go unsaved without anyone knowing.
    private static let told = OSAllocatedUnfairLock(initialState: false)
    private static func tellOnce(_ error: Error) {
        guard told.withLock({ old in defer { old = true }; return !old }) else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let controller = WindowManager.shared.keyController ?? WindowManager.shared.controllers.first else { return }
                Toast.show(SaveFailure.message(String(localized: "Zigzag couldn’t save your tabs and spaces", comment: "Toast when Zigzag can't write its library of spaces and tabs; a reason may follow as its own sentence."), error), symbol: "exclamationmark.triangle",
                           duration: 8, in: controller)
            }
        }
    }
}
