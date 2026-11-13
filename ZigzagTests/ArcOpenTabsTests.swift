import Foundation
import Testing
@testable import Zigzag

/// Each of Arc's spaces' open tabs (its unpinned container, Today) come over in Arc's order as tabs that wait to
/// load, split views side by side; pinned pages stay pins and archived tabs stay behind (#210).
@MainActor struct ArcOpenTabsTests {
    private func tab(_ id: String, _ url: String, title: String? = nil, saved: String? = nil, parent: String? = nil) -> [String: Any] {
        var tab: [String: Any] = ["savedURL": url]
        if let saved { tab["savedTitle"] = saved }
        var node: [String: Any] = ["id": id, "data": ["tab": tab], "childrenIds": [String]()]
        if let title { node["title"] = title }
        if let parent { node["parentID"] = parent }
        return node
    }

    /// Two spaces, each with pins and open tabs: one with a split view, a renamed tab, a file that isn't on the web,
    /// pages in a list, and a closed tab that names the container without being in its list.
    private func sidebar(wrapped: Bool = false) throws -> Data {
        let items: [[String: Any]] = [
            ["id": "pinA", "childrenIds": ["p1"], "data": ["itemContainer": [:]]],
            tab("p1", "https://example.com/pinned"),
            ["id": "openA", "childrenIds": ["o1", "split", "o2", "file", "folder"], "data": ["itemContainer": [:]]],
            tab("o1", "https://example.com/1", saved: "One"),
            ["id": "split", "data": ["splitView": [:]], "childrenIds": ["s1", "s2"]],
            tab("s1", "https://example.com/left", saved: "Left"),
            tab("s2", "https://example.com/right", saved: "Right"),
            tab("o2", "https://example.com/2", title: "Mine", saved: "Two"),
            tab("file", "file:///Users/someone/notes.txt"),
            ["id": "folder", "data": ["list": [:]], "childrenIds": ["f1"]],
            tab("f1", "https://example.com/inside"),
            // Names the container but isn't in its list: closed since, left behind.
            tab("late", "https://example.com/late", parent: "openA"),
            ["id": "pinB", "childrenIds": [String](), "data": ["itemContainer": [:]]],
            ["id": "openB", "childrenIds": ["b1"], "data": ["itemContainer": [:]]],
            tab("b1", "https://example.org/b"),
            // Archived: under no container Arc still shows.
            tab("old", "https://example.com/archived", parent: "gone"),
        ]
        func space(_ id: String, _ title: String, _ pinned: String, _ open: String) -> [String: Any] {
            let ids: [Any] = wrapped ? [["unpinned": ["_0": [:]]], open, ["pinned": ["_0": [:]]], pinned] : ["unpinned", open, "pinned", pinned]
            return ["id": id, "title": title, "containerIDs": ids]
        }
        let spaces: [Any] = ["a", space("a", "Home", "pinA", "openA"), "b", space("b", "Work", "pinB", "openB")]
        let list: [Any] = wrapped ? items.flatMap { [$0["id"]!, ["value": $0]] } : items
        let root: [String: Any] = ["sidebar": ["containers": [["global": [:]], ["spaces": spaces, "items": list]]]]
        return try JSONSerialization.data(withJSONObject: root)
    }

    @Test func openTabsInArcsOrder() throws {
        for wrapped in [false, true] {
            let parsed = try ArcImporter.readSidebar(sidebar(wrapped: wrapped))
            #expect(parsed.spaces.map(\.name) == ["Home", "Work"])
            // Pinned pages stay pins, never open tabs too.
            #expect(parsed.spaces[0].bookmarks.map(\.url.lastPathComponent) == ["pinned"])
            let home = parsed.openTabs[parsed.spaces[0].id] ?? []
            #expect(home.map { $0.pages.map(\.url.lastPathComponent) } == [["1"], ["left", "right"], ["2"], ["inside"]])
            #expect(home.first?.pages.first?.title == "One")
            #expect(home.first?.pages.first?.customTitle == nil)
            // A tab renamed in Arc keeps its name, over the page's own title.
            #expect(home.count > 2 && home[2].pages[0].title == "Two" && home[2].pages[0].customTitle == "Mine")
            #expect(parsed.openTabs[parsed.spaces[1].id]?.map { $0.pages.map { $0.url.host() } } == [["example.org"]])
            // Archived tabs and files on the Mac don't come over.
            let all = parsed.openTabs.values.flatMap { $0.flatMap(\.pages) }.map(\.url.absoluteString)
            #expect(!all.contains { $0.contains("archived") || $0.hasPrefix("file:") })
        }
    }

    /// The sidebar's three parts come over only as chosen: Spaces and Pinned Tabs, Bookmarks (Arc's Favorites) and
    /// Open Tabs, every combination of them.
    @Test func eachChoiceBringsOnlyItsOwnPart() throws {
        var root = try #require(JSONSerialization.jsonObject(with: sidebar()) as? [String: Any])
        var sidebarRoot = try #require(root["sidebar"] as? [String: Any])
        var containers = try #require(sidebarRoot["containers"] as? [[String: Any]])
        var items = try #require(containers[1]["items"] as? [Any])
        items += [["id": "top", "childrenIds": ["fav"], "data": ["itemContainer": [:]]], tab("fav", "https://example.com/favorite")]
        containers[1]["items"] = items
        containers[1]["topAppsContainerIDs"] = ["top"]
        sidebarRoot["containers"] = containers
        root["sidebar"] = sidebarRoot
        let parsed = try ArcImporter.readSidebar(JSONSerialization.data(withJSONObject: root))
        #expect(parsed.favorites.map(\.url.lastPathComponent) == ["favorite"])

        let options: [ImportCoordinator.Choice] = [.tabs, .bookmarks, .openTabs]
        for mask in 0..<8 {
            var choice: ImportCoordinator.Choice = [.passwords, .history]
            for (bit, option) in options.enumerated() where mask & (1 << bit) != 0 { choice.insert(option) }
            let parts = ArcImporter.Parts(choice)
            #expect(parts.contains(.spaces) == choice.contains(.tabs))
            #expect(parts.contains(.favorites) == choice.contains(.bookmarks))
            #expect(parts.contains(.openTabs) == choice.contains(.openTabs))
            let plan = ArcImporter.plan(parsed, parts: parts, existing: [])
            #expect(plan.spaces.isEmpty != choice.contains(.tabs), "spaces for \(mask)")
            #expect(plan.favorites.isEmpty != choice.contains(.bookmarks), "favorites for \(mask)")
            #expect(plan.openTabs.isEmpty != choice.contains(.openTabs), "open tabs for \(mask)")
            for (space, tabs) in plan.openTabs {
                #expect(!tabs.isEmpty)
                // With the spaces, each into its own; without, none made for them: the space you're in.
                #expect(space == (choice.contains(.tabs) ? parsed.spaces.first { parsed.openTabs[$0.id] == tabs }?.id : nil))
            }
        }
        #expect(ArcImporter.Parts([.passwords, .history, .signIns, .extensions]).isEmpty)
    }

    /// Open tabs on their own go into the space here with the same name, when there is one.
    @Test func openTabsAloneGoToTheSpaceWithTheirName() throws {
        let parsed = try ArcImporter.readSidebar(sidebar())
        let work = SpaceInfo(name: "Work", color: .sky)
        let plan = ArcImporter.plan(parsed, parts: .openTabs, existing: [work])
        #expect(plan.spaces.isEmpty && plan.favorites.isEmpty)
        #expect(plan.openTabs.count == 2)
        #expect(plan.openTabs.first?.space == nil)
        #expect(plan.openTabs.last?.space == work.id)
        // With spaces chosen too, a space here of the same name still takes them, as importing again merges.
        let both = ArcImporter.plan(parsed, parts: [.spaces, .openTabs], existing: [work])
        #expect(both.openTabs.map(\.space) == [parsed.spaces[0].id, work.id])
    }

    /// A tab closed long ago, still in an older copy of the sidebar, never comes back: only what the fullest copy's
    /// container lists is open.
    @Test func aClosedTabInAnOlderCopyStaysClosed() throws {
        let space: [Any] = ["a", ["id": "a", "title": "Home", "containerIDs": ["unpinned", "openA"]]]
        let older: [String: Any] = ["spaces": space, "items": [
            ["id": "openA", "childrenIds": ["now", "closed"], "data": ["itemContainer": [:]]],
            tab("now", "https://example.com/now", parent: "openA"),
            tab("closed", "https://example.com/closed", parent: "openA"),
        ]]
        let current: [String: Any] = ["spaces": space, "items": [
            ["id": "openA", "childrenIds": ["now", "new"], "data": ["itemContainer": [:]]],
            tab("now", "https://example.com/now", parent: "openA"),
            tab("new", "https://example.com/new", parent: "openA"),
            ["id": "pins", "childrenIds": [String](), "data": ["itemContainer": [:]]],
        ]]
        let root: [String: Any] = ["sidebar": ["containers": [["global": [:]], older, current]]]
        let parsed = try ArcImporter.readSidebar(JSONSerialization.data(withJSONObject: root))
        let open = parsed.openTabs[try #require(parsed.spaces.first).id] ?? []
        #expect(open.map { $0.pages.map(\.url.lastPathComponent) } == [["now"], ["new"]])
    }

    /// A sidebar from before open tabs were read still gives its spaces and pins, with no open tabs.
    @Test func noUnpinnedContainer() throws {
        let root: [String: Any] = ["sidebar": ["containers": [["global": [:]], [
            "spaces": ["a", ["id": "a", "title": "Home", "containerIDs": ["pinned", "pinA"]]],
            "items": [["id": "pinA", "childrenIds": ["p1"], "data": ["itemContainer": [:]]], tab("p1", "https://example.com/pinned")],
        ]]]]
        let parsed = try ArcImporter.readSidebar(JSONSerialization.data(withJSONObject: root))
        #expect(parsed.spaces.first?.bookmarks.count == 1)
        #expect(parsed.openTabs.isEmpty)
    }

    @Test func splitViewsOfMoreThanTwo() {
        let ids = (0..<5).map { _ in UUID() }
        #expect(ArcImporter.splitPair(Array(ids.prefix(2)))?.count == 2)
        #expect(ArcImporter.splitPair(Array(ids.prefix(3)))?.count == 3)
        // Four at most, as a group holds.
        #expect(ArcImporter.splitPair(ids).map { Set($0.ids) } == Set(ids.prefix(4)))
    }

    /// They open as tabs that wait to load, after what's there, and importing again adds nothing twice.
    @Test func openWithoutLoadingAndOnlyOnce() throws {
        let space = Library.shared.spaces[0].id
        let manager = TabManager(spaceID: space)
        manager.adopt([Tab(url: URL(string: "https://example.com/1")!, spaceID: space)], in: space)
        defer { manager.allTabs.forEach { $0.close() }; manager.invalidate() }
        let parsed = try ArcImporter.readSidebar(sidebar())
        let rows = parsed.openTabs[parsed.spaces[0].id] ?? []
        #expect(ArcImporter.open([(space, rows)], in: manager) == 4)
        let tabs = manager.tabs(in: space)
        #expect(tabs.map { $0.url?.lastPathComponent ?? "" } == ["1", "left", "right", "2", "inside"])
        #expect(tabs.allSatisfy { !$0.isLoaded })
        #expect(tabs.first { $0.url?.lastPathComponent == "2" }?.customTitle == "Mine")
        let left = try #require(tabs.first { $0.url?.lastPathComponent == "left" })
        #expect(manager.partner(of: left)?.url?.lastPathComponent == "right")
        #expect(ArcImporter.open([(space, rows)], in: manager) == 0)
        #expect(manager.tabs(in: space).count == 5)
    }
}
