import Foundation
@testable import Zigzag

nonisolated extension UserDefaults {
    /// Empties a test's own suite and deletes its file, which `removePersistentDomain` leaves behind in
    /// ~/Library/Preferences.
    func removeScratchSuite(_ name: String) {
        removePersistentDomain(forName: name)
        // Written out now: cfprefsd would otherwise write the emptied file again after it's deleted.
        CFPreferencesAppSynchronize(name as CFString)
        // Never the app's own settings or the test host's suite.
        guard !name.hasPrefix("wang.zigao.zigzag"), !name.contains("/") else { return }
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(name).plist")
        try? FileManager.default.removeItem(at: file)
        DevDefaults.noteEmptiedSuite(name)
    }
}

nonisolated extension FileManager {
    /// A new empty folder for one test, inside the test process's own scratch folder, which goes when the process
    /// ends (or at the next run, after a crash).
    func scratchFolder(_ prefix: String) throws -> URL {
        let root = DevDefaults.testsScratch ?? temporaryDirectory
        let folder = root.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
