import AppKit
import Testing
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
