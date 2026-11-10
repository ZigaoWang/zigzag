import Foundation
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
