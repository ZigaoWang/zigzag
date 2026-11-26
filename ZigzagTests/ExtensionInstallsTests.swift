import AppKit
import Testing
import WebKit
@testable import Zigzag

/// An extension's package record and the first profile's answers about it share one file. Each is written without
/// the other's knowledge, so neither may lose what the other keeps there.
struct ExtensionRecordTests {
    private func file() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zigzag-records-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("state.json")
    }

    private let packageKeys = ["version", "pendingVersion", "unpackedPath"]
    private let stateKeys = ["enabled", "grantedPermissions", "grantedMatchPatterns", "siteAccess", "accessSites"]

    @Test func aFileFromBeforeReadsAsBoth() throws {
        let file = try file()
        try Data(#"{"version":"1.2","enabled":false,"grantedPermissions":["storage"],"siteAccess":"click","accessSites":["example.com"]}"#.utf8).write(to: file)
        let package = try #require(ExtensionStore.read(ExtensionStore.Package.self, from: file))
        let state = try #require(ExtensionStore.read(ExtensionInstalls.State.self, from: file))
        #expect(package.version == "1.2" && package.pendingVersion == nil && package.unpackedPath == nil)
        #expect(!state.enabled && state.grantedPermissions == ["storage"] && state.siteAccess == .click && state.accessSites == ["example.com"])
    }

    @Test func eachWriterKeepsTheOthersKeys() throws {
        let file = try file()
        ExtensionStore.write(ExtensionStore.Package(version: "1.0"), keys: packageKeys, to: file)
        ExtensionStore.write(ExtensionInstalls.State(enabled: false, grantedPermissions: ["tabs"]), keys: stateKeys, to: file)
        ExtensionStore.write(ExtensionStore.Package(version: "2.0", pendingVersion: "3.0"), keys: packageKeys, to: file)
        #expect(ExtensionStore.read(ExtensionStore.Package.self, from: file)?.pendingVersion == "3.0")
        let state = try #require(ExtensionStore.read(ExtensionInstalls.State.self, from: file))
        #expect(!state.enabled && state.grantedPermissions == ["tabs"])
    }

    @Test func aValueSetBackToNothingGoesFromTheFile() throws {
        let file = try file()
        ExtensionStore.write(ExtensionStore.Package(version: "1.0", pendingVersion: "2.0"), keys: packageKeys, to: file)
        ExtensionStore.write(ExtensionStore.Package(version: "2.0"), keys: packageKeys, to: file)
        #expect(ExtensionStore.read(ExtensionStore.Package.self, from: file)?.pendingVersion == nil)
    }

    @Test func removingAProfilesAnswersLeavesThePackage() throws {
        let file = try file()
        ExtensionStore.write(ExtensionStore.Package(version: "1.0"), keys: packageKeys, to: file)
        ExtensionStore.write(ExtensionInstalls.State(), keys: stateKeys, to: file)
        ExtensionStore.remove(keys: stateKeys, from: file)
        #expect(ExtensionStore.read(ExtensionInstalls.State.self, from: file) == nil)
        #expect(ExtensionStore.read(ExtensionStore.Package.self, from: file)?.version == "1.0")
    }

    @Test func noFileIsNoRecord() throws {
        let file = try file()
        #expect(ExtensionStore.read(ExtensionStore.Package.self, from: file) == nil)
        #expect(ExtensionStore.read(ExtensionInstalls.State.self, from: file) == nil)
    }
}

/// An extension added to another profile (In Other Profiles, or a new profile Same as another) starts allowed what it
/// is in the profile it comes from, never everything it asks for on every site without the install sheet.
struct CarriedExtensionStateTests {
    @Test func approvalsAndSiteAccessComeAlong() {
        let there = ExtensionInstalls.State(enabled: false, grantedPermissions: ["storage"], grantedMatchPatterns: ["https://github.com/*"],
                                            siteAccess: .sites, accessSites: ["github.com"])
        let here = there.carried(enabled: true)
        #expect(here.enabled)
        #expect(here.grantedPermissions == ["storage"])
        #expect(here.grantedMatchPatterns == ["https://github.com/*"])
        #expect(here.siteAccess == .sites && here.accessSites == ["github.com"])
        #expect(!there.carried(enabled: false).enabled)
    }

    /// On click: it still waits for a click, but the sites it was clicked on there stay there.
    @Test func sitesClickedOnStayInTheirProfile() {
        let there = ExtensionInstalls.State(grantedPermissions: [], grantedMatchPatterns: ["<all_urls>"], siteAccess: .click, accessSites: ["bank.example"])
        let here = there.carried(enabled: true)
        #expect(here.siteAccess == .click)
        #expect(here.accessSites == nil)
        #expect(here.grantedMatchPatterns == ["<all_urls>"])
    }

    /// Unlike a blank state, which `restoreGrants` reads as everything the extension asks for.
    @Test func aCarriedStateIsNeverBlank() {
        let there = ExtensionInstalls.State(grantedPermissions: ["tabs"], grantedMatchPatterns: [])
        let here = there.carried(enabled: true)
        #expect(here.grantedPermissions != nil && here.grantedMatchPatterns != nil)
    }
}

/// Store packages are read off the main actor, up to the cap.
struct ExtensionPackageFetchTests {
    @Test func aPackageIsReadUpToTheCap() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("zigzag-package-\(UUID().uuidString)")
        let bytes = Data((0..<200_000).map { UInt8($0 % 251) })
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let (whole, _) = try await ExtensionStore.fetch(file, limit: 1 << 20)
        #expect(whole == bytes)
        let (capped, _) = try await ExtensionStore.fetch(file, limit: 100_000)
        #expect(capped == nil)
    }
}

/// Settings › Extensions' Site access rows change the same answers as the address menu's Site Access (#324).
@MainActor
struct SettingsSiteAccessTests {
    private let id = "site-access-settings-test"

    private func withInstalls(_ body: (ExtensionInstalls) throws -> Void) rethrows {
        let library = Library.shared
        let info = library.addProfile(name: "Site access test")
        let installs = Profiles.shared.profile(info.id).installs
        defer {
            installs.remove(id)
            library.removeProfile(info.id)
            library.finishedRemovingProfile(info.id)
        }
        installs.save(ExtensionInstalls.State(grantedPermissions: [], grantedMatchPatterns: ["<all_urls>"]), for: id)
        try body(installs)
    }

    private func rows(_ installs: ExtensionInstalls, heard: @escaping (String?) -> Void = { _ in }) -> [FormRow] {
        ExtensionSiteAccessRows.make(id: id, name: "Test", installs: installs, add: {}, changed: heard)
    }

    private func menu(in row: FormRow) throws -> DropdownButton {
        try #require(row.control.subviews.compactMap { $0 as? DropdownButton }.first)
    }

    private var click: NSEvent {
        NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    @Test func theMenuSetsSiteAccess() throws {
        try withInstalls { installs in
            var heard: [String?] = []
            let shown = rows(installs) { heard.append($0) }
            #expect(shown.count == 1)
            let menu = try menu(in: shown[0])
            #expect(menu.selectedIndex == 0)
            menu.onSelect?(1)
            #expect(installs.siteAccess(id) == .click)
            menu.onSelect?(2)
            #expect(installs.siteAccess(id) == .sites && installs.accessSites(id).isEmpty)
            menu.onSelect?(0)
            #expect(installs.siteAccess(id) == .all && installs.state(id)?.accessSites == nil)
            #expect(heard.count == 3 && heard.allSatisfy { $0 == nil })
            #expect(try self.menu(in: rows(installs)[0]).selectedIndex == 0)
        }
    }

    @Test func specificSitesAreAddedAndRemoved() throws {
        try withInstalls { installs in
            installs.chooseSiteAccess(id, .sites)
            installs.addAccessSite(id, "github.com")
            installs.addAccessSite(id, "example.com")
            installs.addAccessSite(id, "github.com")
            #expect(installs.accessSites(id) == ["github.com", "example.com"])
            var heard: [String?] = []
            let shown = rows(installs) { heard.append($0) }
            #expect(Array(shown.map(\.debugTitle).dropFirst()) == ["github.com", "example.com"])
            #expect(try menu(in: shown[0]).selectedIndex == 2)
            let remove = try #require(shown[2].control as? IconButton)
            remove.onClick?(click)
            #expect(installs.accessSites(id) == ["github.com"])
            #expect(heard == ["example.com"])
            // Another choice starts over: back on Specific Sites, the list is empty.
            installs.chooseSiteAccess(id, .click)
            installs.chooseSiteAccess(id, .sites)
            #expect(installs.accessSites(id).isEmpty)
        }
    }

    @Test func theAddressMenusSitesShowInSettings() throws {
        try withInstalls { installs in
            installs.setSiteAccess(id, .sites, sites: ["news.example"])
            #expect(rows(installs).map(\.debugTitle).last == "news.example")
            // Sites clicked on with On Click aren't a list to edit.
            installs.setSiteAccess(id, .click, sites: ["bank.example"])
            #expect(rows(installs).count == 1)
            installs.addAccessSite(id, "github.com")
            #expect(installs.siteAccess(id) == .sites && installs.accessSites(id) == ["github.com"])
        }
    }
}

/// Allow in private windows (#353): off until you turn it on, kept with the profile's other answers about the
/// extension, asked again in another profile, and gone when the extension is.
@MainActor
struct PrivateWindowAccessTests {
    private let id = "private-access-settings-test"

    private func withInstalls(_ body: (ExtensionInstalls) throws -> Void) rethrows {
        let library = Library.shared
        let info = library.addProfile(name: "Private access test")
        let installs = Profiles.shared.profile(info.id).installs
        defer {
            installs.remove(id)
            library.removeProfile(info.id)
            library.finishedRemovingProfile(info.id)
        }
        installs.save(ExtensionInstalls.State(grantedPermissions: [], grantedMatchPatterns: ["<all_urls>"]), for: id)
        try body(installs)
    }

    @Test func onlyAnAllowedExtensionSeesPrivateWindows() {
        #expect(PrivateAccess.sees(isPrivate: false, allowed: false))
        #expect(PrivateAccess.sees(isPrivate: false, allowed: true))
        #expect(PrivateAccess.sees(isPrivate: true, allowed: true))
        #expect(!PrivateAccess.sees(isPrivate: true, allowed: false))
    }

    @Test func aRecordFromBeforeIsOff() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("zigzag-private-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"{"enabled":true,"grantedPermissions":["tabs"]}"#.utf8).write(to: file)
        #expect(try #require(ExtensionStore.read(ExtensionInstalls.State.self, from: file)).allowsPrivate == nil)
        ExtensionStore.write(ExtensionInstalls.State(allowsPrivate: true), keys: ExtensionInstalls.State.keys, to: file)
        #expect(ExtensionStore.read(ExtensionInstalls.State.self, from: file)?.allowsPrivate == true)
        ExtensionStore.remove(keys: ExtensionInstalls.State.keys, from: file)
        #expect(ExtensionStore.read(ExtensionInstalls.State.self, from: file) == nil)
    }

    @Test func anotherProfileAsksAgain() {
        let there = ExtensionInstalls.State(grantedPermissions: ["tabs"], grantedMatchPatterns: ["<all_urls>"], allowsPrivate: true)
        #expect(there.carried(enabled: true).allowsPrivate == nil)
    }

    @Test func theSwitchIsOffAtFirstAndKeepsItsChoice() throws {
        try withInstalls { installs in
            let row = ExtensionPrivateRow.make(id: id, name: "Test", installs: installs)
            let toggle = try #require(row.control as? Toggle)
            #expect(!toggle.isOn)
            #expect(!installs.allowsPrivate(id))
            toggle.onChange?(true)
            #expect(installs.allowsPrivate(id))
            #expect(installs.state(id)?.allowsPrivate == true)
            #expect(try #require(ExtensionPrivateRow.make(id: id, name: "Test", installs: installs).control as? Toggle).isOn)
            toggle.onChange?(false)
            #expect(!installs.allowsPrivate(id))
            #expect(installs.state(id)?.allowsPrivate == nil)
        }
    }

    @Test func removingTheExtensionForgetsIt() throws {
        try withInstalls { installs in
            installs.setAllowsPrivate(id, true)
            installs.remove(id)
            #expect(!installs.allowsPrivate(id))
            installs.save(ExtensionInstalls.State(), for: id)
            #expect(!installs.allowsPrivate(id))
        }
    }
}

/// What the person granted an extension later (an optional permission, an optional site) stays through an update
/// while the new version still declares it, and through a relaunch after, as in Chrome (#484).
@MainActor
@Suite(.serialized)
struct ExtensionUpdateGrantsTests {
    /// Packages in a temporary folder and a profile no list knows, so nothing lands in the person's own.
    fileprivate final class Workspace {
        let folder: URL
        let profile = Profile(id: UUID())

        init() async throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("zigzag-update-grants-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("Extensions"), withIntermediateDirectories: true)
            ExtensionStore.rootOverride = folder.appendingPathComponent("Extensions", isDirectory: true)
            ExtensionStore.forgetWhatWasRead()
            // The profile's own start reads it later; done before the test ends with it.
            while !profile.extensions.finishedLoading { await Task.yield() }
        }

        func cleanUp() {
            for id in profile.installs.installedIDs { profile.extensions.unload(id) }
            ExtensionStore.rootOverride = nil
            ExtensionStore.forgetWhatWasRead()
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: profile.folder)
        }
    }

    private static let nativeMessaging = WKWebExtension.Permission.nativeMessaging.rawValue

    fileprivate static func manifest(_ gecko: String, _ version: String, permissions: [String] = ["storage"],
                                 optional: [String] = ["nativeMessaging"], hosts: [String] = ["https://a.example/*"],
                                 optionalHosts: [String] = ["https://later.example/*"]) -> [String: Any] {
        XPIArchive.manifest(gecko, version, ["manifest_version": 3, "permissions": permissions, "optional_permissions": optional,
                                             "host_permissions": hosts, "optional_host_permissions": optionalHosts])
    }

    /// Installs through the store's own two steps, as the install sheet does.
    @discardableResult
    fileprivate static func install(_ manifest: [String: Any], in profile: Profile) async throws -> String {
        guard case .success(let prepared) = await ExtensionStore.prepareInstallXPI(data: try XPIArchive.xpi(manifest)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard case .success = await ExtensionStore.finishInstall(prepared, in: profile) else { throw CocoaError(.fileWriteUnknown) }
        // No list knows the profile, so the install's own reload doesn't reach it.
        await relaunch(prepared.id, in: profile)
        return prepared.id
    }

    /// What allowing native messaging records (the more-access sheet), with an optional site it asked for.
    private static func grantOptional(_ id: String, in profile: Profile) {
        profile.installs.update(id) {
            $0.grantedPermissions = (($0.grantedPermissions ?? []) + [nativeMessaging]).sorted()
            $0.requestedMatchPatterns = ["https://later.example/*"]
        }
    }

    /// A new version stored beside the current one, as a store download is.
    private static func stage(_ manifest: [String: Any], version: String, for id: String) throws {
        let folder = ExtensionStore.folder(for: id).appendingPathComponent("versions/\(version)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try XPIArchive.json(manifest).write(to: folder.appendingPathComponent("manifest.json"))
        ExtensionStore.forgetWhatWasRead()
    }

    /// What a relaunch does: the extension is read again from its record.
    private static func relaunch(_ id: String, in profile: Profile) async {
        profile.extensions.unload(id)
        #expect(await profile.extensions.load(id) != nil)
    }

    private static func keepsOptional(_ id: String, in profile: Profile) {
        #expect(profile.extensions.allowsNativeHosts(id))
        #expect(profile.installs.state(id)?.grantedPermissions?.contains(nativeMessaging) == true)
        #expect(profile.installs.state(id)?.requestedMatchPatterns == ["https://later.example/*"])
    }

    @Test func aHeldBackUpdateKeepsGrantedOptionalPermissions() async throws {
        let work = try await Workspace()
        defer { work.cleanUp() }
        let id = try await Self.install(Self.manifest("held@example.com", "1.0"), in: work.profile)
        Self.grantOptional(id, in: work.profile)
        #expect(work.profile.extensions.allowsNativeHosts(id))

        try Self.stage(Self.manifest("held@example.com", "2.0", permissions: ["storage", "tabs"]), version: "2.0", for: id)
        ExtensionStore.update(id) { $0.pendingVersion = "2.0" }
        await ExtensionStore.approvePendingUpdate(id, in: [work.profile])
        #expect(ExtensionStore.package(id)?.version == "2.0")
        // What the update asked for was approved with it.
        #expect(work.profile.installs.state(id)?.grantedPermissions?.contains("tabs") == true)
        Self.keepsOptional(id, in: work.profile)
        await Self.relaunch(id, in: work.profile)
        Self.keepsOptional(id, in: work.profile)
    }

    @Test func aSilentUpdateKeepsGrantedOptionalPermissions() async throws {
        let work = try await Workspace()
        defer { work.cleanUp() }
        let id = try await Self.install(Self.manifest("silent@example.com", "1.0"), in: work.profile)
        Self.grantOptional(id, in: work.profile)

        try Self.stage(Self.manifest("silent@example.com", "1.1"), version: "1.1", for: id)
        #expect(await ExtensionStore.switchVersion(of: id, to: "1.1", in: [work.profile]))
        Self.keepsOptional(id, in: work.profile)
        await Self.relaunch(id, in: work.profile)
        Self.keepsOptional(id, in: work.profile)
    }

    @Test func installingOverAnInstallKeepsGrantedOptionalPermissions() async throws {
        let work = try await Workspace()
        defer { work.cleanUp() }
        let id = try await Self.install(Self.manifest("again@example.com", "1.0"), in: work.profile)
        Self.grantOptional(id, in: work.profile)

        try await Self.install(Self.manifest("again@example.com", "2.0"), in: work.profile)
        Self.keepsOptional(id, in: work.profile)
        await Self.relaunch(id, in: work.profile)
        Self.keepsOptional(id, in: work.profile)
    }

    @Test func whatTheNewVersionNoLongerDeclaresIsDropped() async throws {
        let work = try await Workspace()
        defer { work.cleanUp() }
        let id = try await Self.install(Self.manifest("dropped@example.com", "1.0", hosts: ["https://a.example/*", "https://b.example/*"]),
                                        in: work.profile)
        Self.grantOptional(id, in: work.profile)

        try Self.stage(Self.manifest("dropped@example.com", "1.1", optional: [], optionalHosts: []), version: "1.1", for: id)
        #expect(await ExtensionStore.switchVersion(of: id, to: "1.1", in: [work.profile]))
        let state = try #require(work.profile.installs.state(id))
        #expect(!work.profile.extensions.allowsNativeHosts(id))
        #expect(state.grantedPermissions?.contains(Self.nativeMessaging) == false)
        #expect(state.grantedPermissions?.contains("storage") == true)
        #expect(state.grantedMatchPatterns == ["https://a.example/*"])
        #expect(state.requestedMatchPatterns == nil)
    }

    /// A site stays while a declared pattern covers it, the way WebKit matches one pattern against another.
    @Test func aSiteStaysWhileADeclaredPatternCoversIt() throws {
        let all = try WKWebExtension.MatchPattern(string: "<all_urls>"), one = try WKWebExtension.MatchPattern(string: "https://one.example/*")
        let state = ExtensionInstalls.State(grantedPermissions: ["storage"], grantedMatchPatterns: ["https://one.example/*"],
                                            requestedMatchPatterns: ["<all_urls>"])
        // Every site covers one; one site doesn't cover every site.
        #expect(ExtensionHost.boundedGrants(state, declared: ["storage"], patterns: [all]) == nil)
        let underOne = try #require(ExtensionHost.boundedGrants(state, declared: ["storage"], patterns: [one]))
        #expect(underOne.grantedMatchPatterns == ["https://one.example/*"] && underOne.requestedMatchPatterns == nil)
        #expect(underOne.grantedPermissions == ["storage"])
    }

    @Test func uninstallingForgetsEveryGrant() async throws {
        let work = try await Workspace()
        defer { work.cleanUp() }
        let id = try await Self.install(Self.manifest("gone@example.com", "1.0"), in: work.profile)
        Self.grantOptional(id, in: work.profile)
        ExtensionStore.uninstall(id, from: work.profile)
        try await Self.install(Self.manifest("gone@example.com", "1.0"), in: work.profile)
        #expect(!work.profile.extensions.allowsNativeHosts(id))
        #expect(work.profile.installs.state(id)?.requestedMatchPatterns == nil)
    }
}

/// A profile removed or freed while its extensions are still starting: what was waiting stops, and nothing reads
/// the profile after it's gone.
@MainActor
@Suite(.serialized)
struct ExtensionHostLifetimeTests {
    /// Another profile with the workspace's extension on record, its extensions not started yet.
    private static func profile(having id: String, from work: ExtensionUpdateGrantsTests.Workspace) throws -> Profile {
        let profile = Profile(id: UUID())
        profile.installs.save(try #require(work.profile.installs.state(id)), for: id)
        return profile
    }

    private static func settle() async throws {
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(300))
    }

    @Test func aProfileFreedAsItsExtensionsStartIsLeftAlone() async throws {
        var profile: Profile? = Profile(id: UUID())
        let folder = try #require(profile).folder
        defer { try? FileManager.default.removeItem(at: folder) }
        let host = try #require(profile).extensions
        profile = nil
        try await Self.settle()
        #expect(host.contexts.isEmpty)
    }

    @Test func aProfileFreedWhileAnExtensionLoadsIsLeftAlone() async throws {
        let work = try await ExtensionUpdateGrantsTests.Workspace()
        defer { work.cleanUp() }
        let id = try await ExtensionUpdateGrantsTests.install(ExtensionUpdateGrantsTests.manifest("freed@example.com", "1.0"), in: work.profile)
        var profile: Profile? = try Self.profile(having: id, from: work)
        let folder = try #require(profile).folder
        defer { try? FileManager.default.removeItem(at: folder) }
        let host = try #require(profile).extensions
        await Task.yield()
        profile = nil
        try await Self.settle()
        #expect(host.context(for: id) == nil)
    }

    @Test func aRemovedProfileLoadsNothingMore() async throws {
        let work = try await ExtensionUpdateGrantsTests.Workspace()
        defer { work.cleanUp() }
        let id = try await ExtensionUpdateGrantsTests.install(ExtensionUpdateGrantsTests.manifest("removed@example.com", "1.0"), in: work.profile)
        let profile = try Self.profile(having: id, from: work)
        defer { try? FileManager.default.removeItem(at: profile.folder) }
        let host = profile.extensions
        await host.shutDown()
        try await Self.settle()
        #expect(host.contexts.isEmpty)
        #expect(await host.load(id) == nil)
    }
}
