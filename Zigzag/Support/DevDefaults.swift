import Foundation
import ObjectiveC

#if DEBUG
/// Unit tests and test copies (ZIGZAG_DATA_DIR) keep their settings out of the dev build's own defaults: every
/// `UserDefaults.standard` in the process, AppKit's included, answers from a suite of their own.
nonisolated enum DevDefaults {
    private static let testsPrefix = "wang.zigao.zigzag.dev.tests"
    private static let dataPrefix = "ZigzagTests-Data-"

    /// Where the test host keeps its settings: one suite per test process, so runs side by side never share one.
    static let testsSuite = "\(testsPrefix).\(getpid())"

    /// Where the test host keeps its data: one folder per test process, removed when it ends.
    static let testsData: URL? = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil ? nil
        : FileManager.default.temporaryDirectory.appendingPathComponent("\(dataPrefix)\(getpid())", isDirectory: true)

    /// Where tests keep files of their own: one folder per test process, removed when it ends.
    static let testsScratch: URL? = testsData == nil ? nil
        : FileManager.default.temporaryDirectory.appendingPathComponent("\(scratchPrefix)\(getpid())", isDirectory: true)
    private static let scratchPrefix = "ZigzagTests-Scratch-"
    private static let suitesPrefix = "ZigzagTests-Suites-"

    /// Notes a suite a test emptied, whose file the system writes again as the test process ends; the next test
    /// process deletes it.
    static func noteEmptiedSuite(_ name: String) {
        let list = FileManager.default.temporaryDirectory.appendingPathComponent("\(suitesPrefix)\(getpid())")
        suitesLock.withLock {
            if !FileManager.default.fileExists(atPath: list.path) { FileManager.default.createFile(atPath: list.path, contents: nil) }
            guard let handle = try? FileHandle(forWritingTo: list) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((name + "\n").utf8))
        }
    }
    private static let suitesLock = NSLock()

    /// The suite a test copy on this data folder keeps, one per folder.
    static func copySuite(dataDir: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in dataDir.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return "wang.zigao.zigzag.dev.copy." + String(hash, radix: 16)
    }

    /// Runs first thing in main, before anything reads a setting.
    static func isolate(environment env: [String: String] = ProcessInfo.processInfo.environment, arguments: [String] = CommandLine.arguments) {
        let name: String
        var seed = false
        if env["XCTestConfigurationFilePath"] != nil {
            name = testsSuite
            removeTestLeftovers()
            atexit { DevDefaults.removeTestState() }
        } else if let dir = env["ZIGZAG_DATA_DIR"], !dir.isEmpty {
            name = copySuite(dataDir: dir)
            seed = true
        } else {
            return
        }
        guard let suite = UserDefaults(suiteName: name) else { return }
        if !seed {
            suite.removePersistentDomain(forName: name)
        } else if let own = Bundle.main.bundleIdentifier {
            suite.setPersistentDomain(copyDomain(existing: suite.persistentDomain(forName: name),
                                                 dev: UserDefaults.standard.persistentDomain(forName: own) ?? [:],
                                                 arguments: arguments), forName: name)
        }
        guard let method = class_getClassMethod(UserDefaults.self, #selector(getter: UserDefaults.standard)) else { return }
        let standard: @convention(block) (AnyObject) -> UserDefaults = { _ in suite }
        method_setImplementation(method, imp_implementationWithBlock(standard))
    }

    /// A test copy launched with this syncs with iCloud when it's turned on in the copy; without it, sync stays off,
    /// so a copy never syncs into, or removes, the dev build's iCloud.
    static let syncArgument = "--sync-with-icloud"

    /// Sync with iCloud's own switch and what it notes beside it (ICloudSync.enabledKey and the rest).
    static let syncKeys: Set<String> = ["SyncWithICloud", "SyncWithICloudAccount", "SyncWithICloudCopy", "SyncWithICloudPreferenceTimes"]

    /// A test copy's settings at launch: a new copy starts from the dev build's, as it did when it shared them, but
    /// never with sync on or the dev build's account. A copy's own are kept as they are.
    static func copyDomain(existing: [String: Any]?, dev: [String: Any], arguments: [String]) -> [String: Any] {
        existing ?? dev.filter { !syncKeys.contains($0.key) }
    }

    /// Whether this launch may reach iCloud: never the test host; a test copy only when launched with
    /// `syncArgument`, whatever its switch says, so the switch is kept for the next launch that asks.
    static func mayUseICloud(environment env: [String: String] = ProcessInfo.processInfo.environment,
                             arguments: [String] = CommandLine.arguments) -> Bool {
        if env["XCTestConfigurationFilePath"] != nil { return false }
        guard let dir = env["ZIGZAG_DATA_DIR"], !dir.isEmpty else { return true }
        return arguments.contains(syncArgument)
    }

    /// This test process's settings and data, at exit.
    private static func removeTestState() {
        removeSuite(testsSuite)
        if let testsData { try? FileManager.default.removeItem(at: testsData) }
        if let testsScratch { try? FileManager.default.removeItem(at: testsScratch) }
    }

    private static func removeSuite(_ name: String) {
        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        // The emptied domain's file stays behind otherwise.
        try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(name).plist"))
    }

    /// Whether the process with this ID has ended.
    static func isGone(_ pid: Substring) -> Bool { Int32(pid).map { kill($0, 0) != 0 && errno == ESRCH } ?? false }

    /// What test processes that are gone left behind: a crash or a stopped run.
    private static func removeTestLeftovers() {
        let fm = FileManager.default
        let gone = isGone
        let preferences = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences", isDirectory: true)
        for file in (try? fm.contentsOfDirectory(atPath: preferences.path)) ?? [] where file.hasPrefix(testsPrefix + ".") && file.hasSuffix(".plist") {
            let domain = file.dropLast(".plist".count)
            if gone(domain.dropFirst(testsPrefix.count + 1)) { removeSuite(String(domain)) }
        }
        // Suites tests emptied, when the system wrote their files again: only those still empty.
        let temporary = fm.temporaryDirectory
        for list in (try? fm.contentsOfDirectory(atPath: temporary.path)) ?? [] where list.hasPrefix(suitesPrefix) {
            guard gone(list.dropFirst(suitesPrefix.count)) else { continue }
            let url = temporary.appendingPathComponent(list)
            let names = (try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n") ?? []
            for name in names where !name.contains("/") && !name.hasPrefix("wang.zigao.zigzag") {
                let file = preferences.appendingPathComponent("\(name).plist")
                if let values = NSDictionary(contentsOf: file), values.count == 0 { try? fm.removeItem(at: file) }
            }
            try? fm.removeItem(at: url)
        }
        // Also the folders StrictTransport and DarkSeen keep per test process.
        for folder in (try? fm.contentsOfDirectory(atPath: temporary.path)) ?? [] {
            guard let prefix = [dataPrefix, scratchPrefix, "ZigzagTests-StrictTransport-", "ZigzagTests-DarkSeen-"].first(where: folder.hasPrefix),
                  gone(folder.dropFirst(prefix.count)) else { continue }
            try? fm.removeItem(at: temporary.appendingPathComponent(folder))
        }
    }
}
#endif
