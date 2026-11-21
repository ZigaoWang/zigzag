import AppKit
import Foundation
import Testing
@testable import Zigzag

/// Pure black per site (#382): a site's own choice over the setting, and only ever on a page dark pages draw.
@MainActor
@Suite(.serialized)
struct PureBlackTests {
    private func withDefaults(_ body: () throws -> Void) rethrows {
        let name = "PureBlackTests-\(UUID().uuidString)"
        let saved = DarkPages.defaults
        DarkPages.defaults = UserDefaults(suiteName: name)!
        defer {
            DarkPages.defaults.removePersistentDomain(forName: name)
            DarkPages.defaults = saved
        }
        try body()
    }

    /// A site on the list is black whatever the setting says; every other site follows it.
    @Test func aSitesChoiceOverTheSetting() {
        for setting in [false, true] {
            for site in [false, true] { #expect(DarkPages.black(setting: setting, site: site) == (setting || site)) }
        }
        withDefaults {
            let url = URL(string: "https://www.example.com/a")
            #expect(!DarkPages.black(url))
            DarkPages.setBlack(true, for: url)
            #expect(DarkPages.sitesBlack == ["example.com"] && DarkPages.black(url))
            // The site covers its subdomains, and no other site.
            #expect(DarkPages.black(URL(string: "https://docs.example.com/")))
            #expect(!DarkPages.black(URL(string: "https://example.org/")))
            // The setting comes on: the site is black and still has its own choice; another site follows the setting.
            DarkPages.pureBlack = true
            #expect(DarkPages.black(URL(string: "https://example.org/")) && !DarkPages.hasBlackSite(for: URL(string: "https://example.org/")))
            #expect(DarkPages.black(url) && DarkPages.hasBlackSite(for: url))
            // And off again: the site's own choice keeps it black, the other follows the setting.
            DarkPages.pureBlack = false
            #expect(DarkPages.black(url) && !DarkPages.black(URL(string: "https://example.org/")))
            DarkPages.setBlack(false, for: url)
            #expect(DarkPages.sitesBlack.isEmpty && !DarkPages.black(url))
            // Reset All forgets it too.
            DarkPages.setBlack(true, for: url)
            DarkPages.forgetAll()
            #expect(DarkPages.sitesBlack.isEmpty && !DarkPages.black(url))
        }
    }

    /// A site with no choice of its own follows the setting, on or off, as every site does.
    @Test func aSiteWithoutAChoiceFollowsTheSetting() {
        withDefaults {
            let url = URL(string: "https://example.com/")
            #expect(!DarkPages.black(url))
            DarkPages.pureBlack = true
            #expect(DarkPages.black(url))
            #expect(!DarkPages.hasBlackSite(for: url))
        }
    }

    /// Pure black changes only a darkened page: a light one is never black, whatever the site or the setting says.
    @Test func aLightPageIgnoresIt() {
        withDefaults {
            let url = URL(string: "https://example.com/"), white = NSColor.white
            DarkPages.setBlack(true, for: url)
            let light = DarkPages.State(darkened: false, native: true, color: white, site: "example.com", looked: true)
            #expect(Tab.pageColor(dark: light, under: nil, theme: white, url: url) == white)
            // Darkened, the same page is drawn black, and the bar above it too.
            let darkened = DarkPages.State(darkened: true, native: false, color: nil, site: "example.com", looked: true)
            #expect(Tab.pageColor(dark: darkened, under: nil, theme: white, url: url) == DarkPages.background(black: true))
            #expect(Tab.pageColor(dark: darkened, under: nil, theme: white, url: URL(string: "https://example.org/"))
                    == DarkPages.background(black: false))
        }
    }
}
