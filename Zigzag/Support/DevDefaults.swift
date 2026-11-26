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

    /// The suite a test copy on this data folder keeps, one per folder.
    static func copySuite(dataDir: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in dataDir.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return "wang.zigao.zigzag.dev.copy." + String(hash, radix: 16)
    }

    /// Runs first thing in main, before anything reads a setting.
    static func isolate(environment env: [String: String] = ProcessInfo.processInfo.environment) {
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
        } else if suite.persistentDomain(forName: name) == nil, let own = Bundle.main.bundleIdentifier {
            // A new copy starts from the dev build's settings, as it did when it shared them.
            suite.setPersistentDomain(UserDefaults.standard.persistentDomain(forName: own) ?? [:], forName: name)
        }
        guard let method = class_getClassMethod(UserDefaults.self, #selector(getter: UserDefaults.standard)) else { return }
        let standard: @convention(block) (AnyObject) -> UserDefaults = { _ in suite }
        method_setImplementation(method, imp_implementationWithBlock(standard))
    }

    /// This test process's settings and data, at exit.
    private static func removeTestState() {
        removeSuite(testsSuite)
        if let testsData { try? FileManager.default.removeItem(at: testsData) }
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
        // Also the folders StrictTransport and DarkSeen keep per test process.
        let temporary = fm.temporaryDirectory
        for folder in (try? fm.contentsOfDirectory(atPath: temporary.path)) ?? [] {
            guard let prefix = [dataPrefix, "ZigzagTests-StrictTransport-", "ZigzagTests-DarkSeen-"].first(where: folder.hasPrefix),
                  gone(folder.dropFirst(prefix.count)) else { continue }
            try? fm.removeItem(at: temporary.appendingPathComponent(folder))
        }
    }
}
#endif
