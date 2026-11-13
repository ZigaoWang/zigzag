import AppKit
import Testing
import WebKit
@testable import Zigzag

/// Settings' list of what websites keep (#207): grouping by site, finding, sorting, removing, and the list made
/// only of rows in view, on a made-up store of thousands of sites.
@MainActor
struct SiteDataListTests {
    /// A store of made-up sites: what it lists, what's been removed from it, and how many times it was read.
    final class FakeSource: SiteDataSource {
        var stored: [SiteDataRecord]
        var sizesByName: [String: Int64]
        var reads = 0
        var removedNames: [String] = []
        var removedAll = false

        init(_ records: [SiteDataRecord], sizes: [String: Int64] = [:]) {
            stored = records
            sizesByName = sizes
        }

        func records() async -> [SiteDataRecord] {
            reads += 1
            return stored
        }

        func sizes() async -> [String: Int64] { sizesByName.filter { name, _ in stored.contains { $0.name == name } } }

        func remove(_ names: [String]) async {
            removedNames += names
            stored.removeAll { names.contains($0.name) }
        }

        func removeAll() async {
            removedAll = true
            stored = []
        }

        /// `count` sites, "site-0000.example" on, every seventh with a shop. subdomain too.
        static func many(_ count: Int) -> FakeSource {
            var records: [SiteDataRecord] = []
            var sizes: [String: Int64] = [:]
            for i in 0..<count {
                let site = "site-\(String(format: "%04d", i)).example"
                records.append(SiteDataRecord(name: site, kinds: .cookies))
                sizes[site] = Int64(i * 1000)
                if i % 7 == 0 {
                    records.append(SiteDataRecord(name: "shop." + site, kinds: .cache))
                    sizes["shop." + site] = 500
                }
            }
            return FakeSource(records, sizes: sizes)
        }
    }

    // MARK: Grouping

    @Test func recordsOfOneRegistrableDomainAreOneSite() {
        let entries = SiteDataListing.group([
            SiteDataRecord(name: "news.bbc.co.uk", kinds: .cache, size: 10),
            SiteDataRecord(name: "bbc.co.uk", kinds: .cookies, size: 5),
            SiteDataRecord(name: "apple.com", kinds: .saved),
            SiteDataRecord(name: "localhost", kinds: .cookies),
        ])
        #expect(entries.map(\.site) == ["apple.com", "bbc.co.uk", "localhost"])
        let bbc = entries[1]
        #expect(bbc.kinds == [.cookies, .cache])
        #expect(bbc.size == 15)
        #expect(Set(bbc.names) == ["news.bbc.co.uk", "bbc.co.uk"])
        #expect(entries[0].size == nil)
    }

    @Test func kindsComeFromWebKitsTypes() {
        #expect(SiteDataKinds(types: [WKWebsiteDataTypeCookies]) == .cookies)
        #expect(SiteDataKinds(types: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache]) == .cache)
        #expect(SiteDataKinds(types: [WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeCookies]) == [.saved, .cookies])
        #expect(SiteDataRow.describe([.cookies, .cache]) == String(localized: "Cookies and cache", comment: "Under a site in Settings › Privacy › Site Data: what it keeps on this Mac. A label, no full stop."))
    }

    @Test func namesSortAsFinderDoesAndSizesLargestFirst() {
        let entries = [SiteDataEntry(site: "a10.com", kinds: .cookies, size: 1, names: []),
                       SiteDataEntry(site: "a2.com", kinds: .cookies, size: nil, names: []),
                       SiteDataEntry(site: "b.com", kinds: .cookies, size: 99, names: [])]
        #expect(SiteDataListing.sort(entries, by: .name).map(\.site) == ["a2.com", "a10.com", "b.com"])
        #expect(SiteDataListing.sort(entries, by: .size).map(\.site) == ["b.com", "a10.com", "a2.com"])
    }

    // MARK: Finding

    @Test func searchMatchesEveryWordAnywhereInTheName() {
        let entries = SiteDataListing.group(["github.com", "gitlab.com", "apple.com", "café.fr"].map { SiteDataRecord(name: $0, kinds: .cookies) })
        #expect(SiteDataListing.filter(entries, words: ["GIT"]).map(\.site) == ["github.com", "gitlab.com"])
        #expect(SiteDataListing.filter(entries, words: ["git", "lab"]).map(\.site) == ["gitlab.com"])
        #expect(SiteDataListing.filter(entries, words: ["cafe"]).map(\.site) == ["café.fr"])
        #expect(SiteDataListing.filter(entries, words: ["nothing"]).isEmpty)
        #expect(SiteDataListing.filter(entries, words: []).count == 4)
        #expect(SiteDataListing.matchRanges(of: ["hub"], in: "github.com") == [NSRange(location: 3, length: 3)])
    }

    // MARK: The model, on a fake store

    @Test func modelReadsGroupsAndAddsSizes() async {
        let source = FakeSource.many(2000)
        let model = SiteDataModel(source: source)
        #expect(model.state == .idle)
        model.refresh()
        #expect(model.state == .loading)
        await model.settle()
        #expect(model.state == .loaded)
        #expect(model.entries.count == 2000)
        #expect(model.hasSizes)
        // site-0007's shop. subdomain is part of it.
        #expect(model.entries.first { $0.site == "site-0007.example" }?.size == 7000 + 500)
        model.order = .size
        #expect(model.shown.first?.site == "site-1999.example")
    }

    @Test func aSecondReadKeepsTheListAndAsksOnce() async {
        let source = FakeSource.many(50)
        let model = SiteDataModel(source: source)
        model.refresh()
        model.refresh()
        await model.settle()
        #expect(source.reads == 1)
        var changes = 0
        model.changed = { changes += 1 }
        model.refresh()
        await model.settle()
        // Nothing changed: nothing is shown again.
        #expect(changes == 0)
        #expect(model.entries.count == 50)
    }

    @Test func filteringNarrowsWhatsShownAndFindASettingAddsItsWords() async {
        let model = SiteDataModel(source: FakeSource.many(2000))
        model.refresh()
        await model.settle()
        model.query = "site-01"
        #expect(model.shown.count == 100)
        model.outsideWords = ["0199"]
        #expect(model.shown.map(\.site) == ["site-0199.example"])
        #expect(model.isFiltering)
        model.query = ""
        model.outsideWords = []
        #expect(model.shown.count == 2000)
    }

    @Test func removingASiteRemovesAllItsRecordsAndItStaysGone() async {
        let source = FakeSource.many(20)
        let model = SiteDataModel(source: source)
        model.refresh()
        await model.settle()
        let site = model.entries.first { $0.site == "site-0007.example" }!
        await model.remove([site])
        #expect(Set(source.removedNames) == ["site-0007.example", "shop.site-0007.example"])
        #expect(!model.entries.contains { $0.site == site.site })
        model.refresh()
        await model.settle()
        #expect(model.entries.count == 19)
    }

    @Test func removeAllShownRemovesOnlyTheMatchesAndRemoveAllEverything() async {
        let source = FakeSource.many(30)
        let model = SiteDataModel(source: source)
        model.refresh()
        await model.settle()
        model.query = "site-001"
        await model.removeAllShown()
        #expect(!source.removedAll)
        #expect(source.removedNames.count == 10 + 1)
        model.query = ""
        #expect(model.entries.count == 20)
        await model.removeAllShown()
        #expect(source.removedAll)
        #expect(model.entries.isEmpty)
    }

    // MARK: The list

    @Test func theListMakesRowsOnlyForWhatsInView() async {
        let model = SiteDataModel(source: FakeSource.many(2000))
        model.refresh()
        await model.settle()
        let list = SiteDataList(frame: NSRect(x: 0, y: 0, width: 600, height: 0))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: 600, height: 10))
        scroll.documentView = document
        document.addSubview(list)
        list.model = model
        // Thirty first, then every site after Show All, as tall as all of them.
        #expect(list.debugListed == SiteDataList.collapsedCount)
        list.showsAll = true
        #expect(list.debugListed == 2000)
        let height = list.height(for: 600)
        #expect(height == SiteDataList.rowHeight * 2000)
        list.frame.size.height = height
        document.frame.size.height = height
        list.layoutSubtreeIfNeeded()
        let inView = list.debugRowViews
        #expect(inView > 0 && inView < 40)
        // Scrolled far down: a few views, reused, with room in view and past both edges now.
        document.scroll(NSPoint(x: 0, y: height / 2))
        list.layout()
        #expect(list.debugRowViews < 30, "\(inView) then \(list.debugRowViews)")
        // A search lists every match, without Show All's limit.
        list.showsAll = false
        model.query = "site-1"
        #expect(list.debugListed == 1000)
        model.query = "zzz"
        #expect(list.debugListed == 0)
        #expect(!list.find(["nothing-like-it"]))
    }
}
