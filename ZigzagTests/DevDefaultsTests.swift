import Foundation
import Testing
@testable import Zigzag

/// The test host keeps its settings in a suite of its own, never in the dev build's defaults.
@MainActor
struct DevDefaultsTests {
    private let devDomain = "wang.zigao.zigzag.dev"

    @Test func settingsGoToTheTestsSuite() throws {
        let probe = "DevDefaultsTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: probe) }
        UserDefaults.standard.set(true, forKey: probe)
        let tests = try #require(UserDefaults.standard.persistentDomain(forName: DevDefaults.testsSuite))
        #expect(tests[probe] as? Bool == true)
        #expect(UserDefaults.standard.persistentDomain(forName: devDomain)?[probe] == nil)
    }

    @Test func aProfileWithPinsLeavesTheDevDefaultsAsTheyWere() {
        let library = Library.shared
        let info = library.addProfile(name: "Dev defaults test")
        let installs = Profiles.shared.profile(info.id).installs
        let pinsKey = ProfileKey.extensionsPinned.name(in: info.id)
        let frameKey = "NSWindow Frame DevDefaultsTests"
        defer {
            installs.pins = ExtensionPins(ids: [])
            library.removeProfile(info.id)
            library.finishedRemovingProfile(info.id)
            UserDefaults.standard.removeObject(forKey: "LaunchCount")
            UserDefaults.standard.removeObject(forKey: frameKey)
        }
        installs.pins = ExtensionPins(ids: ["dev-defaults-test"])
        UserDefaults.standard.set(9999, forKey: "LaunchCount")
        UserDefaults.standard.set("0 0 800 600 0 0 1440 900 ", forKey: frameKey)
        let dev = UserDefaults.standard.persistentDomain(forName: devDomain) ?? [:]
        #expect(dev[pinsKey] == nil && dev[frameKey] == nil)
        #expect(dev["LaunchCount"] as? Int != 9999)
        #expect(UserDefaults.standard.stringArray(forKey: pinsKey) == ["dev-defaults-test"])
    }

    @Test func aTestCopyKeepsOneSuitePerDataFolder() {
        let one = DevDefaults.copySuite(dataDir: "/tmp/copy-one")
        #expect(one == DevDefaults.copySuite(dataDir: "/tmp/copy-one"))
        #expect(one != DevDefaults.copySuite(dataDir: "/tmp/copy-two"))
        #expect(one.hasPrefix("wang.zigao.zigzag.dev.copy."))
    }

    @Test func aTestCopyNeverSyncsWithICloudUnlessAsked() {
        let dev: [String: Any] = [ICloudSync.enabledKey: true, ICloudSync.accountKey: "_dev", ICloudSync.copyKey: true, "ReaderSize": 18]
        // A new copy starts from the dev build's settings, sync off and without the dev build's account.
        let new = DevDefaults.copyDomain(existing: nil, dev: dev, arguments: ["Zigzag"])
        #expect(new["ReaderSize"] as? Int == 18)
        #expect(new[ICloudSync.enabledKey] == nil && new[ICloudSync.accountKey] == nil && new[ICloudSync.copyKey] == nil)
        // Asked for at launch, still off until turned on in the copy.
        #expect(DevDefaults.copyDomain(existing: nil, dev: dev, arguments: ["Zigzag", DevDefaults.syncArgument])[ICloudSync.enabledKey] == nil)
        // A copy that had it on syncs only while launched with the argument.
        let on: [String: Any] = [ICloudSync.enabledKey: true, "ReaderSize": 14]
        #expect(DevDefaults.copyDomain(existing: on, dev: dev, arguments: ["Zigzag"])[ICloudSync.enabledKey] as? Bool != true)
        #expect(DevDefaults.copyDomain(existing: on, dev: dev, arguments: ["Zigzag"])["ReaderSize"] as? Int == 14)
        #expect(DevDefaults.copyDomain(existing: on, dev: dev, arguments: ["Zigzag", DevDefaults.syncArgument])[ICloudSync.enabledKey] as? Bool == true)
    }
}
