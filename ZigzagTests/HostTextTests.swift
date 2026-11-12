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
