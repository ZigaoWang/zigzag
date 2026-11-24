import Testing
import WebKit
@testable import Zigzag

@MainActor struct PageLocationTests {
    /// macOS WebKit has no location source of its own; without the C API a page never gets a position.
    @Test func webKitHasTheLocationAPI() {
        #expect(PageLocation.isAvailable)
    }

    /// Every tab shares a process pool, which gets the source once.
    @Test func eachPoolGetsTheSourceOnce() {
        let first = WKWebViewConfiguration(), second = WKWebViewConfiguration()
        PageLocation.attach(to: first)
        let attached = PageLocation.attachedPools
        #expect(attached >= 1)
        PageLocation.attach(to: first)
        PageLocation.attach(to: second)
        let samePool = (first.value(forKey: "processPool") as AnyObject) === (second.value(forKey: "processPool") as AnyObject)
        #expect(PageLocation.attachedPools == attached + (samePool ? 0 : 1))
    }

    /// Location Services off for the whole Mac: macOS would never ask, so the page gets an error rather than waiting.
    @Test func locationServicesOffForTheMacAnswersWithAnError() {
        #expect(PageLocation.answer(servicesOn: false, status: .notDetermined) == .fail)
        #expect(PageLocation.answer(servicesOn: false, status: .authorizedAlways) == .fail)
        #expect(PageLocation.answer(servicesOn: true, status: .notDetermined) == .ask)
        #expect(PageLocation.answer(servicesOn: true, status: .denied) == .fail)
        #expect(PageLocation.answer(servicesOn: true, status: .restricted) == .fail)
        #expect(PageLocation.answer(servicesOn: true, status: .authorizedAlways) == .update)
    }
}
