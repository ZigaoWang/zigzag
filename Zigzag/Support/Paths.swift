import Foundation

nonisolated enum Paths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // The dev build keeps its data apart from the Zigzag you use.
        let isDev = Bundle.main.bundleIdentifier?.hasSuffix(".dev") ?? false
        let dir = base.appendingPathComponent(isDev ? "Zigzag Dev" : "Zigzag", isDirectory: true)
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
        return try? decoder.decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
