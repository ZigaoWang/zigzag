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

/// Arc profiles map to separate profiles; with one Arc profile everything goes to one (#279).
@MainActor struct ArcProfilesTests {
    private static let custom: [String: Any] = ["custom": ["_0": ["directoryBasename": "Profile 1"]]]
    private static let standard: [String: Any] = ["default": [String: Any]()]

    private func tab(_ id: String, _ url: String) -> [String: Any] {
        ["id": id, "data": ["tab": ["savedURL": url]], "childrenIds": [String]()]
    }

    /// Home on Arc's default profile and Work on "Profile 1", each with a Favorites container.
    private func sidebar(homeProfile: [String: Any] = standard, workProfile: [String: Any] = custom) throws -> ArcImporter.Sidebar {
        let items: [[String: Any]] = [
            ["id": "pinA", "childrenIds": ["p1"], "data": ["itemContainer": [:]]],
            tab("p1", "https://example.com/home"),
            ["id": "pinB", "childrenIds": ["p2"], "data": ["itemContainer": [:]]],
            tab("p2", "https://example.com/work"),
            ["id": "topA", "childrenIds": ["fa1", "fa2"], "data": ["itemContainer": [:]]],
            tab("fa1", "https://mail.example.com/"),
            tab("fa2", "https://news.example.com/"),
            ["id": "topB", "childrenIds": ["fb1"], "data": ["itemContainer": [:]]],
            tab("fb1", "https://tracker.example.com/"),
        ]
        let spaces: [Any] = [
            "a", ["id": "a", "title": "Home", "containerIDs": ["pinned", "pinA"], "profile": homeProfile],
            "b", ["id": "b", "title": "Work", "containerIDs": ["pinned", "pinB"], "profile": workProfile],
        ]
        let top: [Any] = [homeProfile, "topA", workProfile, "topB"]
        let root: [String: Any] = ["sidebar": ["containers": [["global": [:]], ["spaces": spaces, "items": items, "topAppsContainerIDs": top]]]]
        return try ArcImporter.readSidebar(JSONSerialization.data(withJSONObject: root))
    }

    @Test func profileMarkers() {
        #expect(ArcImporter.arcProfile(Self.custom) == "Profile 1")
        #expect(ArcImporter.arcProfile(["value": Self.custom]) == "Profile 1")
        #expect(ArcImporter.arcProfile(Self.standard) == nil)
        #expect(ArcImporter.arcProfile("default") == nil)
        #expect(ArcImporter.arcProfile(nil) == nil)
        #expect(ArcImporter.arcProfile(["custom": ["_0": ["directoryBasename": "Default"]]]) == nil)
    }

    @Test func twoProfilesStayApart() throws {
        let parsed = try sidebar()
        #expect(parsed.spaces.map(\.name) == ["Home", "Work"])
        #expect(parsed.profilesInUse == ["Profile 1"])
        #expect(parsed.profile(of: parsed.spaces[0].id) == nil)
        #expect(parsed.profile(of: parsed.spaces[1].id) == "Profile 1")
        // All favorites import, per profile.
        #expect(parsed.favorites.count == 3)
        let groups = parsed.favoriteGroups
        #expect(groups.map(\.profile) == [nil, "Profile 1"])
        #expect(groups.first?.favorites.compactMap { $0.url.host() } == ["mail.example.com", "news.example.com"])
        #expect(groups.last?.favorites.compactMap { $0.url.host() } == ["tracker.example.com"])
        let plan = ArcImporter.plan(parsed, parts: .all, existing: [])
        #expect(plan.favoriteGroups.map(\.favorites.count) == [2, 1])
        #expect(ArcImporter.plan(parsed, parts: .spaces, existing: []).favoriteGroups.isEmpty)
    }

    /// One Arc profile: all favorites together.
    @Test func oneProfileAsBefore() throws {
        for (home, work) in [(Self.standard, Self.standard), (Self.custom, Self.custom)] {
            let parsed = try sidebar(homeProfile: home, workProfile: work)
            #expect(parsed.profilesInUse.isEmpty)
            #expect(parsed.spaces.allSatisfy { parsed.profile(of: $0.id) == nil })
            #expect(parsed.favoriteGroups.count == 1)
            #expect(parsed.favoriteGroups.first?.profile == nil)
            #expect(parsed.favoriteGroups.first?.favorites.map(\.id) == parsed.favorites.map(\.id))
            #expect(parsed.favorites.count == 3)
        }
    }

    private func profile(_ folder: String, machine: String) -> [String: Any] {
        ["custom": ["_0": ["directoryBasename": folder, "machineID": machine]]]
    }

    /// Test sidebar with one Favorites container per profile, in either Arc encoding.
    private func favoritesCopy(spaces: [[String: Any]], groups: [(profile: [String: Any], urls: [String])]) -> [String: Any] {
        var items: [[String: Any]] = [], top: [Any] = []
        for (i, group) in groups.enumerated() {
            let children = group.urls.indices.map { "favorite-\(i)-\($0)" }
            items.append(["id": "top-\(i)", "childrenIds": children, "data": ["itemContainer": [:]]])
            items += zip(children, group.urls).map { tab($0.0, $0.1) }
            top += [group.profile, "top-\(i)"]
        }
        return ["spaces": spaces, "items": items, "topAppsContainerIDs": top]
    }

    private func synced(_ copy: [String: Any]) -> [String: Any] {
        let spaces = copy["spaces"] as? [[String: Any]] ?? []
        let items = copy["items"] as? [[String: Any]] ?? []
        return ["spaceModels": spaces.map { ["value": $0] }, "items": items.map { ["value": $0] },
                "container": ["value": ["orderedSpaceIDs": spaces.compactMap { $0["id"] as? String },
                                         "topAppsContainerIDs": copy["topAppsContainerIDs"] ?? []]]]
    }

    /// Arc Sync keeps other Macs' Favorites; only profiles of visible spaces are imported.
    @Test(arguments: [false, true], [false, true])
    func favoritesFollowTheirSpacesMachine(useSync: Bool, oneProfile: Bool) throws {
        let local = profile("Profile 4", machine: "mac-a"), remote = profile("Profile 4", machine: "mac-b")
        let unused = profile("Profile 9", machine: "mac-a")
        var spaces: [[String: Any]] = [
            ["id": "work", "title": "Work", "profile": local],
            ["id": "focus", "title": "Focus", "profile": ["value": local]],
        ]
        if !oneProfile { spaces.insert(["id": "home", "title": "Home", "profile": Self.standard], at: 0) }
        let copy = favoritesCopy(spaces: spaces, groups: [
            (remote, ["https://example.com/remote"]),
            (local, ["https://example.com/mail", "https://example.com/docs"]),
            (unused, ["https://example.com/unused"]),
            (Self.standard, ["https://example.com/home"]),
        ])
        let root: [String: Any] = useSync ? ["sidebarSyncState": synced(copy)] : ["sidebar": ["containers": [copy]]]
        let parsed = try ArcImporter.readSidebar(JSONSerialization.data(withJSONObject: root))
        let plan = ArcImporter.plan(parsed, parts: .all, existing: [])
        #expect(parsed.favorites.map(\.url.lastPathComponent) == (oneProfile ? ["mail", "docs"] : ["mail", "docs", "home"]))
        #expect(plan.favoriteGroups.map(\.profile) == (oneProfile ? [nil] : [nil, "Profile 4"]))
        #expect(plan.favoriteGroups.map { $0.favorites.map(\.url.lastPathComponent) } == (oneProfile ? [["mail", "docs"]] : [["home"], ["mail", "docs"]]))
        #expect(parsed.spaces.filter { $0.name == "Work" || $0.name == "Focus" }.allSatisfy {
            parsed.profile(of: $0.id) == (oneProfile ? nil : "Profile 4")
        })
    }

    /// A newer Favorites container wins, even when empty.
    @Test(arguments: [false, true])
    func olderFavoritesContainersStayBehind(empty: Bool) throws {
        let local = profile("Profile 4", machine: "mac-a")
        let spaces: [[String: Any]] = [["id": "work", "title": "Work", "profile": local]]
        let older = favoritesCopy(spaces: spaces, groups: [(local, ["https://example.com/old"])])
        var current = favoritesCopy(spaces: spaces, groups: [(local, empty ? [] : ["https://example.com/new"])])
        var items = try #require(current["items"] as? [[String: Any]])
        items[0]["id"] = "replacement-top"
        items[0]["childrenIds"] = empty ? [String]() : ["new-favorite"]
        if !empty { items[1]["id"] = "new-favorite" }
        current["topAppsContainerIDs"] = [local, "replacement-top"]
        items += (0..<3).map { tab("extra-\($0)", "https://example.com/extra-\($0)") }
        current["items"] = items
        let root: [String: Any] = ["sidebar": ["containers": [older]], "sidebarSyncState": synced(current)]
        let parsed = try ArcImporter.readSidebar(JSONSerialization.data(withJSONObject: root))
        #expect(parsed.favorites.map(\.url.lastPathComponent) == (empty ? [] : ["new"]))
    }

    /// A marker without a machine ID still matches its folder.
    @Test(arguments: [false, true])
    func favoritesMatchAFolderWithoutAMachine(spaceHasMachine: Bool) throws {
        let withMachine = profile("Profile 4", machine: "mac-a")
        let bare: [String: Any] = ["custom": ["_0": ["directoryBasename": "Profile 4"]]]
        let spaces: [[String: Any]] = [
            ["id": "home", "title": "Home", "profile": Self.standard],
            ["id": "work", "title": "Work", "profile": spaceHasMachine ? withMachine : bare],
        ]
        let copy = favoritesCopy(spaces: spaces, groups: [
            (spaceHasMachine ? bare : withMachine, ["https://example.com/mail"]),
            (Self.standard, ["https://example.com/home"]),
        ])
        let parsed = try ArcImporter.readSidebar(JSONSerialization.data(withJSONObject: ["sidebar": ["containers": [copy]]]))
        let plan = ArcImporter.plan(parsed, parts: .all, existing: [])
        #expect(plan.favoriteGroups.map(\.profile) == [nil, "Profile 4"])
        #expect(plan.favoriteGroups.map { $0.favorites.map(\.url.lastPathComponent) } == [["home"], ["mail"]])
    }

    /// Reimporting merges into the same-named space on its profile, else any same-named space.
    @Test func importingAgainMergesOnItsProfile() {
        let work = UUID()
        let onDefault = SpaceInfo(name: "Work", color: .sky), onWork = SpaceInfo(name: "Work", color: .sky)
        let profileOf: (UUID) -> UUID = { $0 == onWork.id ? work : Profile.defaultID }
        let incoming = SpaceInfo(name: "Work", color: .sky)
        #expect(ArcImporter.match(incoming, in: [onDefault, onWork], wants: work, profileOf: profileOf)?.id == onWork.id)
        #expect(ArcImporter.match(incoming, in: [onDefault, onWork], wants: Profile.defaultID, profileOf: profileOf)?.id == onDefault.id)
        #expect(ArcImporter.match(incoming, in: [onDefault], wants: work, profileOf: profileOf)?.id == onDefault.id)
        #expect(ArcImporter.match(SpaceInfo(name: "Other", color: .sky), in: [onDefault, onWork], wants: work, profileOf: profileOf) == nil)
    }

    /// Profile names come from Arc, else the folder; existing names are reused.
    @Test func profileNames() {
        #expect(ArcImporter.profileName("Profile 1", names: ["Profile 1": "School"]) == "School")
        #expect(ArcImporter.profileName("Profile 2", names: ["Profile 1": "School"]) == "Profile 2")
        #expect(ArcImporter.profileName("Profile 1", names: ["Profile 1": " "]) == "Profile 1")
        let school = ProfileInfo(id: UUID(), name: "School")
        let profiles = [ProfileInfo(id: Profile.defaultID), school]
        #expect(ArcImporter.profile(named: "school", in: profiles)?.id == school.id)
        #expect(ArcImporter.profile(named: "Work", in: profiles) == nil)
    }

    /// Sign-ins follow their Arc profile; the rest go to the importing one.
    @Test func signInsFollowTheirProfile() {
        func cookie(_ name: String) -> SignInImporter.Cookie {
            SignInImporter.Cookie(domain: ".example.com", name: name, value: "v", path: "/", expires: nil, secure: true, httpOnly: false, sameSite: .lax)
        }
        var batch = ImportBatch()
        batch.cookies = [cookie("a"), cookie("b"), cookie("c")]
        batch.cookieProfiles = ["Default": [0..<1], "Profile 1": [1..<3]]
        let into = UUID(), work = UUID()
        let groups = ImportCoordinator.cookieGroups(batch, apart: ["Profile 1": work], into: into)
        #expect(groups.map(\.profile) == [into, work])
        #expect(groups.map { $0.cookies.map(\.name) } == [["a"], ["b", "c"]])
        let one = ImportCoordinator.cookieGroups(batch, apart: [:], into: into)
        #expect(one.map(\.profile) == [into] && one.first?.cookies.count == 3)
    }
}
