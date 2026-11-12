import Testing
import WebKit
@testable import Zigzag

/// Taking Zigzag's own page scripts out of a web view leaves everyone else's exactly as they were (#178). A web view's
/// set also holds what extensions inject; taking all out and putting the rest back made copies of those, the set grew
/// with every page, and WebKit crashed sending it to a new page's process.
@MainActor
struct OwnScriptsTests {
    private static func script(_ source: String) -> WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
    }

    @Test func onlyTheScriptsPickedAreTakenOut() {
        let controller = WKUserContentController()
        let extensionScript = Self.script("/* an extension's content script */")
        let ours = Self.script("/* ours */ 1")
        controller.addUserScript(extensionScript)
        controller.addUserScript(ours)
        controller.addUserScript(Self.script("/* ours */ 2"))

        #expect(OwnScripts.remove(from: controller, where: { $0.source.hasPrefix("/* ours */") }) == 2)
        #expect(controller.userScripts.count == 1)
        // The very script that was there, not a copy put back in its place.
        #expect(controller.userScripts.first === extensionScript)
        #expect(OwnScripts.remove(from: controller, where: { $0.source.hasPrefix("/* ours */") }) == 0)
    }

    @Test func pagesComingAndGoingNeverGrowTheSet() {
        let controller = WKUserContentController()
        controller.addUserScript(Self.script("/* an extension's content script */"))
        for _ in 0..<50 {
            controller.addUserScript(PageFullScreen.script())
            OwnScripts.remove(from: controller, where: PageFullScreen.isOurs)
        }
        #expect(controller.userScripts.count == 1)
    }

    @Test func aSiteFiltersClearLeavesOtherScripts() {
        let controller = WKUserContentController()
        let extensionScript = Self.script("/* an extension's content script */")
        controller.addUserScript(extensionScript)
        for script in PageFilters.scripts(for: AdInjection(page: ["1"], isolated: ["2"], styles: "a { }"), host: "www.youtube.com") {
            controller.addUserScript(script)
        }
        #expect(controller.userScripts.count == 4)
        PageFilters.clear(controller)
        #expect(controller.userScripts.count == 1)
        #expect(controller.userScripts.first === extensionScript)
    }
}
