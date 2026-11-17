import Foundation
import Testing
@testable import Zigzag

struct FirefoxUniverseTests {
    @Test func universeNamesTheFirefoxSurface() throws {
        let url = try #require(Bundle.main.url(forResource: "firefox-api", withExtension: "json"))
        let api = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: [String: Any]])

        // Firefox's pinned types declare 63 namespace blocks; _manifest is skipped and two are empty, leaving 60
        // top-level namespaces. A namespace's sub-APIs (storage.local, privacy.network, a browserSettings setting) are
        // objects in this same shape. Counting the whole tree clears the plan's floor of 100 namespace-shaped scopes;
        // counting only top-level keys could not, because Firefox publishes 60.
        #expect(api.count >= 60, "\(api.count) top-level namespaces")
        func scopes(_ spec: [String: Any]) -> Int {
            let objects = spec["objects"] as? [String: Any] ?? [:]
            return 1 + objects.values.reduce(0) { $0 + scopes($1 as? [String: Any] ?? [:]) }
        }
        let count = api.values.reduce(0) { $0 + scopes($1) }
        #expect(count >= 100, "\(count) API scopes")

        let areas = try #require(api["storage"]?["objects"] as? [String: Any], "storage areas")
        for area in ["local", "sync", "session"] {
            let spec = try #require(areas[area] as? [String: Any], "storage.\(area)")
            let functions = spec["functions"] as? [String] ?? []
            #expect(functions.contains("get"), "storage.\(area).get")
            #expect(functions.contains("set"), "storage.\(area).set")
        }

        let runtimeFunctions = try #require(api["runtime"]?["functions"] as? [String], "runtime functions")
        #expect(runtimeFunctions.contains("getBrowserInfo"))
        #expect(runtimeFunctions.contains("getPlatformInfo"))

        #expect(api["sidebarAction"] != nil)
        #expect(api["_manifest"] == nil)
        #expect(api.keys.allSatisfy { !$0.hasPrefix("browser.") })
    }
}
