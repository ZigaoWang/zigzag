import Foundation

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
    static let session = file("Session.json")
    static let history = file("History.sqlite")
    static let favicons = directory("Favicons")
    static let tabState = directory("TabState")
    static let snapshots = directory("Snapshots")
}

nonisolated enum JSONStore {
    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        if let value = try? decoder.decode(type, from: data) { return value }
        // There, but unreadable (cut short, or written by a newer Zigzag): kept aside, never written over, so
        // starting fresh can't erase it and it can still be recovered.
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let aside = url.deletingPathExtension().appendingPathExtension("unreadable-\(stamp).\(url.pathExtension)")
        try? FileManager.default.moveItem(at: url, to: aside)
        return nil
    }

    static func save<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
