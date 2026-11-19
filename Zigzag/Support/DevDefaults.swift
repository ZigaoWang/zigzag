import Foundation
import ObjectiveC

#if DEBUG
/// Unit tests and test copies (ZIGZAG_DATA_DIR) keep their settings out of the dev build's own defaults: every
/// `UserDefaults.standard` in the process, AppKit's included, answers from a suite of their own.
nonisolated enum DevDefaults {
    /// Where the test host keeps its settings; emptied each run.
    static let testsSuite = "wang.zigao.zigzag.dev.tests"

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
}
#endif
