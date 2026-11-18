import JavaScriptCore
import Testing
@testable import Zigzag

/// Chrome's DevTools in the Web Inspector: its files served from the app and nothing beside them, and scripts that parse.
@MainActor
struct ChromeDevToolsTests {
    @Test func servesTheFrontendWithOurHostFirst() throws {
        let (page, type) = try #require(FrontendFiles.file(at: "/devtools_app.html"))
        let html = try #require(String(data: page, encoding: .utf8))
        #expect(type.hasPrefix("text/html"))
        let host = try #require(html.range(of: "zigzag-host.js"))
        let module = try #require(html.range(of: "<script type=\"module\""))
        #expect(host.lowerBound < module.lowerBound)
        #expect(FrontendFiles.file(at: "/zigzag-host.js")?.1.hasPrefix("text/javascript") == true)
        #expect(FrontendFiles.file(at: "/entrypoints/devtools_app/devtools_app.js") != nil)
    }

    @Test func nothingOutsideTheFrontend() {
        #expect(FrontendFiles.file(at: "/../Info.plist") == nil)
        #expect(FrontendFiles.file(at: "/../../MacOS/Zigzag") == nil)
        #expect(FrontendFiles.file(at: "/no-such-file.js") == nil)
    }

    @Test(arguments: [true, false]) func scriptsParse(on: Bool) throws {
        let context = try #require(JSContext())
        for source in [ChromeDevTools.bridgeSource(on: on), ChromeDevTools.host] {
            #expect(!source.contains("__CONFIG__"))
            context.setObject(source, forKeyedSubscript: "source" as NSString)
            context.evaluateScript("new Function(source)")
            #expect(context.exception == nil)
        }
    }
}
