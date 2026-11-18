import AppKit
import Testing
@testable import Zigzag

/// How a site's host splits and is cut to fit a header (#189): the registrable domain always whole until nothing
/// else is left to give.
struct HostTextTests {
    /// Every character half the size wide: easy widths to reason about.
    private func fit(_ name: String, _ width: CGFloat) -> HostText.Fit {
        HostText.fit(name, width: width, size: 20, shrink: 2, smallest: 15) { text, size in CGFloat(text.count) * size / 2 }
    }

    @Test func splitsSubdomainsFromTheRegistrableDomain() {
        #expect(HostText.parts(of: "gemini.google.com") == .init(subdomain: "gemini.", domain: "google.com", port: ""))
        #expect(HostText.parts(of: "a.b.c.example.co.uk") == .init(subdomain: "a.b.c.", domain: "example.co.uk", port: ""))
        #expect(HostText.parts(of: "google.com") == .init(subdomain: "", domain: "google.com", port: ""))
        #expect(HostText.parts(of: "alice.github.io") == .init(subdomain: "", domain: "alice.github.io", port: ""))
        #expect(HostText.parts(of: "dev.example.com:8443") == .init(subdomain: "dev.", domain: "example.com", port: ":8443"))
    }

    @Test func punycodeHostsStillSplit() {
        #expect(HostText.parts(of: "mail.xn--bcher-kva.de") == .init(subdomain: "mail.", domain: "xn--bcher-kva.de", port: ""))
        #expect(HostText.parts(of: "www.xn--80ak6aa92e.xn--p1ai") == .init(subdomain: "www.", domain: "xn--80ak6aa92e.xn--p1ai", port: ""))
        #expect(HostText.parts(of: "xn--fsqu00a.example.co.uk") == .init(subdomain: "xn--fsqu00a.", domain: "example.co.uk", port: ""))
    }

    @Test func namesThatArentDomainsStayWhole() {
        #expect(HostText.parts(of: "192.168.1.10") == .init(subdomain: "", domain: "192.168.1.10", port: ""))
        #expect(HostText.parts(of: "localhost:3000") == .init(subdomain: "", domain: "localhost", port: ":3000"))
        #expect(HostText.parts(of: "localhost") == .init(subdomain: "", domain: "localhost", port: ""))
        #expect(HostText.parts(of: "::1") == .init(subdomain: "", domain: "::1", port: ""))
        #expect(HostText.parts(of: "co.uk") == .init(subdomain: "", domain: "co.uk", port: ""))
        #expect(HostText.parts(of: "New Tab") == .init(subdomain: "", domain: "New Tab", port: ""))
    }

    @Test func wholeWhenItFits() {
        // 17 characters: 170 at 20.
        #expect(fit("gemini.google.com", 170) == .init(size: 20, lead: "gemini.", domain: "google.com"))
    }

    @Test func shrinksALittleBeforeCutting() {
        // 153 at 18, the floor.
        #expect(fit("gemini.google.com", 160) == .init(size: 18, lead: "gemini.", domain: "google.com"))
    }

    @Test func dropsWholeSubdomainLabelsFromTheStart() {
        // At 18: "a.b.c.example.co.uk" is 171, "…b.c.example.co.uk" 162, "…c.example.co.uk" 144, "….example.co.uk" 135.
        #expect(fit("a.b.c.example.co.uk", 165) == .init(size: 18, lead: "…b.c.", domain: "example.co.uk"))
        #expect(fit("a.b.c.example.co.uk", 145) == .init(size: 18, lead: "…c.", domain: "example.co.uk"))
        #expect(fit("gemini.google.com", 110) == .init(size: 18, lead: "….", domain: "google.com"))
    }

    @Test func neverCutsIntoTheDomainWhileItCanShrink() {
        // "….google.com" is 12: 108 at 18, 90 at 15.
        #expect(fit("gemini.google.com", 100) == .init(size: 16, lead: "….", domain: "google.com"))
        #expect(fit("gemini.google.com", 90) == .init(size: 15, lead: "….", domain: "google.com"))
    }

    @Test func aVeryLongDomainLosesTheEndOfItsNameLast() {
        // At 15, 7.5 a character: 12 characters fit in 90.
        let fit = fit("physicsandmathstutor.com", 90)
        #expect(fit.size == 15)
        #expect(fit.domain == "physics….com")
        let sub = self.fit("www.physicsandmathstutor.co.uk", 90)
        #expect(sub.lead == "….")
        #expect(sub.domain == "phy….co.uk")
    }

    @Test func keepsThePortWithTheDomain() {
        let fit = fit("staging.example.com:8443", 140)
        #expect(fit.domain == "example.com:8443")
        #expect(fit.lead == "….")
        #expect(fit.size == 15)
    }

    @Test func addressesAndLocalhostCutAtTheEnd() {
        let ip = fit("192.168.100.200", 60)
        #expect(ip.lead == "")
        #expect(ip.domain == "192.168…")
    }

    @MainActor @Test func styledTextKeepsTheDomainInPrimaryInk() {
        let text = HostText.styled(.init(size: 18, lead: "gemini.", domain: "google.com"), font: { .systemFont(ofSize: $0) })
        #expect(text.string == "gemini.google.com")
        #expect(text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == Tokens.Color.textSecondary)
        #expect(text.attribute(.foregroundColor, at: 7, effectiveRange: nil) as? NSColor == Tokens.Color.textPrimary)
        let panel = SitePanel.fitted("gemini.google.com", in: 400)
        #expect(panel.string == "gemini.google.com")
    }
}

/// Addresses in text can't impersonate another site: no userinfo, long hosts cut at the start, escapes not decoded into "/" or "@".
@MainActor
struct AddressTextTests {
    @Test func aLongHostKeepsItsEndEvenWithoutAKnownDomain() {
        // Ports and unlisted IDN labels are still cut at the start.
        #expect(AddressView.lineBreak(forName: "accounts.google.com.aaaaaaaaaaaaaaaa.xn--80ak6aa92e.example") == .byTruncatingHead)
        #expect(AddressView.lineBreak(forName: "accounts.google.com.aaaaaaaaaaaaaaaa.evil.example:8443") == .byTruncatingHead)
        #expect(AddressView.lineBreak(forName: "xn--80ak6aa92e.com") == .byTruncatingMiddle)
        #expect(AddressView.lineBreak(forName: "physicsandmathstutor.com:8443") == .byTruncatingMiddle)
        #expect(AddressView.lineBreak(forName: "New Tab") == .byTruncatingTail)
    }

    @Test func noUserNameAheadOfTheHost() throws {
        let tricky = try #require(URL(string: "https://paypal.com:secret@evil.example/login"))
        #expect(CommandRanker.displayURL(tricky) == "evil.example/login")
        #expect(LinkStatusController.describe(tricky) == "evil.example/login")
        let plain = try #require(URL(string: "https://www.example.com/a?b=1"))
        #expect(CommandRanker.displayURL(plain) == "example.com/a?b=1")
        #expect(AddressText.withoutUserInfo(plain) == plain)
    }

    @Test func theLinkPillNeverDecodesASeparator() throws {
        let link = try #require(URL(string: "https://good.example%2F@evil.example/"))
        #expect(LinkStatusController.describe(link) == "evil.example")
        let path = try #require(URL(string: "https://evil.example/%2F%2Fgood.example%40x/caf%C3%A9?q=a%20b%E2%80%AEfdp.exe"))
        #expect(LinkStatusController.describe(path) == "evil.example/%2F%2Fgood.example%40x/café?q=a%20b%E2%80%AEfdp.exe")
        // IDN hosts show as punycode, never decoded into lookalikes.
        let idn = try #require(URL(string: "https://xn--pple-43d.com/caf%C3%A9"))
        #expect(LinkStatusController.describe(idn) == "xn--pple-43d.com/café")
        #expect(AddressText.readable("%E2%80%8Bx%zz%") == "%E2%80%8Bx%zz%")
    }

    /// Site names in wrapping text (the extension sheet) never break at hyphens.
    @Test func aWrappedLineKeepsASitesNameWhole() {
        let line = "Read and change what you see on custom-progress-bar.com and 5 other sites"
        let kept = AddressText.keepingHostsWhole(line)
        #expect(kept.replacingOccurrences(of: "\u{2060}", with: "") == line)
        #expect(kept.contains("custom-\u{2060}progress-\u{2060}bar.com"))
        // Hyphens in plain words, and text with no host, are unchanged.
        #expect(AddressText.keepingHostsWhole("A built-in tool") == "A built-in tool")
        #expect(AddressText.keepingHostsWhole("x-y.example and a-b") == "x-\u{2060}y.example and a-b")
        // At every width the sheet could use, no line breaks inside the name.
        let font = Tokens.Font.body()
        for width in stride(from: CGFloat(160), through: 420, by: 2) {
            let storage = NSTextStorage(string: kept, attributes: [.font: font])
            let layout = NSLayoutManager(), container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            storage.addLayoutManager(layout)
            layout.ensureLayout(for: container)
            var index = 0
            while index < layout.numberOfGlyphs {
                var range = NSRange()
                layout.lineFragmentRect(forGlyphAt: index, effectiveRange: &range)
                let text = (kept as NSString).substring(with: layout.characterRange(forGlyphRange: range, actualGlyphRange: nil))
                    .replacingOccurrences(of: "\u{2060}", with: "")
                #expect(!text.hasSuffix("-"), "width \(width): \(text)")
                index = NSMaxRange(range)
            }
        }
    }
}

/// The full address where there's room (bar, popup, Mini): no scheme or "www.", the host as loaded, no userinfo, host never cut for the path.
@MainActor
struct FullAddressTests {
    private func parts(_ text: String) -> FullAddress.Parts? { URL(string: text).flatMap(FullAddress.parts(of:)) }

    @Test func splitsTheHostFromTheRest() {
        #expect(parts("https://linux.do/t/topic/482293") == .init(host: "linux.do", rest: "/t/topic/482293"))
        #expect(parts("https://github.com/ZigaoWang/zigzag/issues?q=is%3Aopen#top")
                == .init(host: "github.com", rest: "/ZigaoWang/zigzag/issues?q=is%3Aopen#top"))
        #expect(parts("https://example.com/a/b/") == .init(host: "example.com", rest: "/a/b/"))
        #expect(parts("https://example.com?q=1") == .init(host: "example.com", rest: "/?q=1"))
        #expect(parts("https://example.com/#f") == .init(host: "example.com", rest: "/#f"))
    }

    @Test func noSchemeNoWWWNoTrailingSlashOnAFrontPage() {
        #expect(parts("https://www.linux.do/") == .init(host: "linux.do", rest: ""))
        #expect(parts("http://www.example.com") == .init(host: "example.com", rest: ""))
        // Only a leading "www." is removed.
        #expect(parts("https://mail.www.example.com/")?.host == "mail.www.example.com")
        #expect(parts("https://www2.example.com/")?.host == "www2.example.com")
    }

    @Test func neverAUserNameAheadOfTheHost() {
        #expect(parts("https://paypal.com:secret@evil.example/login") == .init(host: "evil.example", rest: "/login"))
        #expect(parts("https://paypal.com@evil.example/") == .init(host: "evil.example", rest: ""))
    }

    @Test func internationalNamesShowAsWebKitLoadsThem() {
        #expect(parts("https://xn--bcher-kva.de/a") == .init(host: "xn--bcher-kva.de", rest: "/a"))
        #expect(parts("https://bücher.de/")?.host == "xn--bcher-kva.de")
        #expect(parts("https://xn--80ak6aa92e.com/")?.host == "xn--80ak6aa92e.com")
        // The path shows as text, but escapes never decode into separators or invisible marks.
        #expect(parts("https://例子.中国/路径")?.rest == "/路径")
        #expect(parts("https://example.com/a%2Fb%40c")?.rest == "/a%2Fb%40c")
        #expect(parts("https://example.com/%E2%80%AEtxt.exe")?.rest == "/%E2%80%AEtxt.exe")
    }

    @Test func addressesAndPorts() {
        #expect(parts("http://192.168.1.10:80/admin") == .init(host: "192.168.1.10", rest: "/admin"))
        #expect(parts("https://192.168.1.10:8443/") == .init(host: "192.168.1.10:8443", rest: ""))
        #expect(parts("http://localhost:3000/app") == .init(host: "localhost:3000", rest: "/app"))
        #expect(parts("http://[::1]:8080/x") == .init(host: "[::1]:8080", rest: "/x"))
        #expect(parts("https://example.com:443/") == .init(host: "example.com", rest: ""))
        #expect(parts("http://example.com:443/") == .init(host: "example.com:443", rest: ""))
    }

    @Test func pagesWithoutASiteKeepTheirName() {
        #expect(parts("file:///Users/a/report.pdf") == nil)
        #expect(parts("data:text/html,hi") == nil)
        #expect(parts("about:blank") == nil)
        #expect(parts("blob:https://example.com/1234") == nil)
        #expect(parts("zigzag://history") == nil)
        #expect(parts("ftp://example.com/file") == nil)
        #expect(FullAddress.parts(of: nil) == nil)
    }

    @Test func aLongRestIsKeptToItsStart() throws {
        let long = String(repeating: "a", count: 50_000)
        let full = try #require(parts("https://example.com/\(long)"))
        #expect(full.host == "example.com")
        #expect(full.rest.count == FullAddress.longestRest)
    }

    /// Every character is 10 wide.
    private func shown(_ parts: FullAddress.Parts, _ room: CGFloat) -> FullAddress.Shown {
        FullAddress.shown(parts, room: room) { CGFloat($0.count) * 10 }
    }

    @Test func theHostIsNeverSqueezedForTheRest() {
        let page = FullAddress.Parts(host: "linux.do", rest: "/t/topic/482293")
        // Whole: 23 characters.
        #expect(shown(page, 230) == .whole)
        // Host, four path characters and "…" (13): the path is cut at its end.
        #expect(shown(page, 130) == .whole)
        // Less: host only.
        #expect(shown(page, 129) == .host)
        #expect(shown(page, 40) == .host)
        // A front page is just the host, cut normally if needed.
        #expect(shown(FullAddress.Parts(host: "linux.do", rest: ""), 10) == .whole)
        // A short path that fits needs nothing more.
        #expect(shown(FullAddress.Parts(host: "a.io", rest: "/x"), 60) == .whole)
    }

    @Test func styledTextIsTheHostDarkAndTheRestQuiet() {
        let text = FullAddress.styled(.init(host: "linux.do", rest: "/t/1"), font: .systemFont(ofSize: 13))
        #expect(text.string == "linux.do/t/1")
        #expect(text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == Tokens.Color.textPrimary)
        #expect(text.attribute(.foregroundColor, at: 8, effectiveRange: nil) as? NSColor == Tokens.Color.textSecondary)
        let paragraph = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(paragraph?.lineBreakMode == .byTruncatingTail)
    }

    @Test func aLabelTooNarrowShowsTheHostAlone() {
        let label = Label("", font: .systemFont(ofSize: 13))
        let page = FullAddress.Parts(host: "accounts.google.com", rest: "/signin/v2/challenge/pwd")
        FullAddress.show(page, in: label, room: 1000)
        #expect(label.stringValue == page.whole)
        FullAddress.show(page, in: label, room: 60)
        #expect(label.stringValue == page.host)
        let paragraph = label.attributedStringValue.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(paragraph?.lineBreakMode == AddressView.lineBreak(forName: page.host))
    }

    @Test func theBarAboveThePageShowsTheSiteInItsPill() {
        // #275: the pill names a split pane's site like the sidebar address; a new tab shows its prompt.
        let bar = TopBarView()
        bar.showPage(url: URL(string: "https://www.example.com/some/long/path?q=1"), notSecure: false)
        #expect(bar.pill.text == "example.com")
        #expect(!bar.pill.hasSiteControls)
        bar.showPage(url: nil, notSecure: false)
        #expect(bar.pill.text == String(localized: "Search or enter address", comment: "Placeholder of the address in the sidebar, on a new tab."))
        // An insecure page keeps its mark and label.
        bar.showPage(url: URL(string: "http://example.com"), notSecure: true)
        #expect(bar.pill.notSecure)
        #expect(bar.pill.accessibilityLabel()?.contains(SitePanel.notSecure) == true)
    }
}
