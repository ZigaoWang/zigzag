import AppKit
import Foundation
import JavaScriptCore
import Testing
import WebKit
@testable import Zigzag

/// Extensions' address bar keywords (#324): which keyword the command bar takes, what it sends the extension, and
/// how the extension's suggestions read.
@MainActor
struct ExtensionOmniboxTests {
    private let raindrop = OmniboxKeyword(extensionID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", keyword: "rd", name: "Raindrop.io")

    // MARK: Keywords

    @Test func aManifestKeywordIsOneYouCanType() {
        #expect(OmniboxKeyword.keyword(in: ["omnibox": ["keyword": "rd"]]) == "rd")
        #expect(OmniboxKeyword.keyword(in: ["omnibox": ["keyword": "  rd "]]) == "rd")
        #expect(OmniboxKeyword.keyword(in: ["omnibox": ["keyword": ""]]) == nil)
        #expect(OmniboxKeyword.keyword(in: ["omnibox": ["keyword": "two words"]]) == nil)
        #expect(OmniboxKeyword.keyword(in: ["omnibox": ["keyword": 3]]) == nil)
        #expect(OmniboxKeyword.keyword(in: ["name": "No keyword"]) == nil)
    }

    @Test func webKitKeepsTheKeywordInTheManifest() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"manifest_version":3,"name":"Keyword probe","version":"1.0","omnibox":{"keyword":"zz"},"background":{"service_worker":"bg.js"}}"#.utf8)
            .write(to: folder.appendingPathComponent("manifest.json"))
        try Data("chrome.omnibox.onInputEntered.addListener(() => {});".utf8).write(to: folder.appendingPathComponent("bg.js"))
        let ext = try await WKWebExtension(resourceBaseURL: folder)
        #expect(OmniboxKeyword.keyword(in: ext.manifest) == "zz")
    }

    @Test func theFirstExtensionKeepsASharedKeyword() {
        let other = OmniboxKeyword(extensionID: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", keyword: "RD", name: "Other")
        let unique = OmniboxKeyword.unique([raindrop, other])
        #expect(unique == [raindrop])
    }

    /// A keyword Zigzag's own site search answers to stays the site's: "yt" still means YouTube.
    @Test func aSiteSearchKeepsItsKeyword() {
        let youtube = OmniboxKeyword(extensionID: "cccccccccccccccccccccccccccccccc", keyword: "YT", name: "Video Helper")
        let keys = Set(SiteSearch.builtIn.flatMap(\.keys))
        #expect(keys.contains("yt"))
        #expect(OmniboxKeyword.usable([youtube, raindrop], siteSearchKeys: keys) == [raindrop])
    }

    @Test func onlyTheKeywordAndASpaceEnterIt() {
        let keywords = [raindrop]
        #expect(OmniboxKeyword.entered("rd", among: keywords) == nil)
        #expect(OmniboxKeyword.entered("rd ", among: keywords)?.rest == "")
        #expect(OmniboxKeyword.entered("RD cats", among: keywords)?.rest == "cats")
        #expect(OmniboxKeyword.entered("rd  two", among: keywords)?.rest == " two")
        // Addresses and searches that only start the same way are left alone.
        for text in ["rdio.com", "rd.example/path", "rdx cats", " rd cats", "nerd cats", "rd/x y"] {
            #expect(OmniboxKeyword.entered(text, among: keywords) == nil, "\(text)")
        }
        #expect(OmniboxKeyword.named("Rd", among: keywords) == raindrop)
        #expect(OmniboxKeyword.named("rd ", among: keywords) == nil)
        #expect(OmniboxKeyword.named("r", among: keywords) == nil)
    }

    @Test func returnSaysWhereToOpenAsChromeDoes() {
        #expect(OmniboxKeyword.disposition(modifiers: [], inNewTab: false) == "currentTab")
        #expect(OmniboxKeyword.disposition(modifiers: [], inNewTab: true) == "newForegroundTab")
        #expect(OmniboxKeyword.disposition(modifiers: [.command], inNewTab: false) == "newBackgroundTab")
        #expect(OmniboxKeyword.disposition(modifiers: [.command], inNewTab: true) == "newBackgroundTab")
        #expect(OmniboxKeyword.disposition(modifiers: [.command, .shift], inNewTab: false) == "newForegroundTab")
        #expect(OmniboxKeyword.disposition(modifiers: [.option], inNewTab: false) == "newForegroundTab")
        #expect(OmniboxKeyword.disposition(modifiers: [.shift], inNewTab: false) == "currentTab")
        #expect(OmniboxKeyword.disposition(modifiers: [.control], inNewTab: false) == "currentTab")
    }

    // MARK: Descriptions

    @Test func markupBecomesPlainTextWithItsStyles() {
        let styled = OmniboxText.parse("<match>Rain</match>drop <dim>bookmarks</dim> <url>https://raindrop.io</url>")
        #expect(styled.text == "Raindrop bookmarks https://raindrop.io")
        #expect(styled.runs == [
            OmniboxText.Run(range: NSRange(location: 0, length: 4), styles: [.match]),
            OmniboxText.Run(range: NSRange(location: 9, length: 9), styles: [.dim]),
            OmniboxText.Run(range: NSRange(location: 19, length: 19), styles: [.url]),
        ])
        let nested = OmniboxText.parse("<dim>a <match>b</match></dim>")
        #expect(nested.text == "a b")
        #expect(nested.runs == [OmniboxText.Run(range: NSRange(location: 0, length: 2), styles: [.dim]),
                                OmniboxText.Run(range: NSRange(location: 2, length: 1), styles: [.dim, .match])])
    }

    @Test func otherTagsAreDroppedAndNothingIsRendered() {
        #expect(OmniboxText.parse("<b>bold</b> <script>alert(1)</script><img src=x onerror=y>").text == "bold alert(1)")
        #expect(OmniboxText.parse("<a href='https://evil.example'>link</a>").text == "link")
        #expect(OmniboxText.parse("1 &lt; 2 &amp;&amp; 3 &gt; 2 &quot;q&quot; &apos;a&apos; &#65;&#x42;").text == "1 < 2 && 3 > 2 \"q\" 'a' AB")
        #expect(OmniboxText.parse("&unknown; & alone &#0;").text == "&unknown; & alone &#0;")
        #expect(OmniboxText.parse("a < b").text == "a < b")
        #expect(OmniboxText.parse("  line\none\t\ttwo  ").text == "line one two")
        #expect(OmniboxText.parse("<match></match>").runs.isEmpty)
        #expect(OmniboxText.parse(String(repeating: "x", count: 1000)).text.count == OmniboxText.limit)
    }

    @Test func theDefaultSuggestionTakesWhatsTypedAsText() {
        let styled = OmniboxText.defaultSuggestion("Search Raindrop for <match>%s</match>", typed: "<b>cats</b> & dogs")
        #expect(styled.text == "Search Raindrop for <b>cats</b> & dogs")
        #expect(styled.runs == [OmniboxText.Run(range: NSRange(location: 20, length: 18), styles: [.match])])
        #expect(OmniboxText.defaultSuggestion("No placeholder", typed: "x").text == "No placeholder")
    }

    // MARK: The bridge's side

    private final class Sent { var events: [(id: String, event: String, args: [Any])] = []; var woken: [String] = [] }

    /// An omnibox whose events land in `sent`; `listening` is what each extension listens to.
    private func omnibox(listening: @escaping () -> [String: Set<String>]) -> (BridgeOmnibox, Sent) {
        let omnibox = BridgeOmnibox(host: Profiles.shared.default.extensions)
        let sent = Sent()
        omnibox.send = { id, event, args, _ in sent.events.append((id, event, args)) }
        omnibox.isListening = { id, event in listening()[id]?.contains(event) ?? false }
        omnibox.wake = { sent.woken.append($0) }
        return (omnibox, sent)
    }

    @Test func aKeywordSessionTellsTheExtensionEachStep() async throws {
        let all = Set(BridgeOmnibox.events)
        let (omnibox, sent) = omnibox { [self.raindrop.extensionID: all] }
        let input = omnibox.start(raindrop, isPrivate: false)
        input.change("ca")
        input.change("cats")
        var changes = 0
        input.onChange = { changes += 1 }
        // An answer for "ca" comes too late; the one for "cats" is shown.
        _ = try await omnibox.call("suggest", args: [1, [["content": "https://old.example", "description": "old"]]], extensionID: raindrop.extensionID)
        _ = try await omnibox.call("suggest", args: [2, [["content": "https://raindrop.io/cats", "description": "<match>cats</match> board"],
                                                         ["description": "no content"], "not an object"]], extensionID: raindrop.extensionID)
        #expect(input.suggestions.map(\.content) == ["https://raindrop.io/cats"])
        #expect(input.suggestions.first?.description.text == "cats board")
        _ = try await omnibox.call("setDefaultSuggestion", args: [["description": "Search for %s"]], extensionID: raindrop.extensionID)
        #expect(input.defaultSuggestion == "Search for %s")
        #expect(changes == 2)
        input.enter("cats", disposition: "currentTab")
        // Nothing more after Return: no cancel, no late change.
        input.cancel()
        input.change("dogs")
        #expect(sent.events.map(\.event) == ["omnibox.onInputStarted", "omnibox.onInputChanged", "omnibox.onInputChanged", "omnibox.onInputEntered"])
        #expect(sent.events[2].args.first as? String == "cats")
        #expect(sent.events[3].args as? [String] == ["cats", "currentTab"])
        #expect(sent.events.allSatisfy { $0.id == raindrop.extensionID })
    }

    @Test func leavingWithoutReturnCancels() {
        let (omnibox, sent) = omnibox { [self.raindrop.extensionID: Set(BridgeOmnibox.events)] }
        let input = omnibox.start(raindrop, isPrivate: false)
        input.cancel()
        input.cancel()
        #expect(sent.events.map(\.event) == ["omnibox.onInputStarted", "omnibox.onInputCancelled"])
    }

    @Test func onlyEventsTheExtensionListensToAreSent() {
        let (omnibox, sent) = omnibox { [self.raindrop.extensionID: ["omnibox.onInputEntered"]] }
        let input = omnibox.start(raindrop, isPrivate: false)
        input.change("x")
        input.enter("x", disposition: "newForegroundTab")
        #expect(sent.events.map(\.event) == ["omnibox.onInputEntered"])
        #expect(sent.woken.isEmpty)
    }

    @Test func anAsleepBackgroundIsWokenAndHearsWhatItMissed() {
        var listening: [String: Set<String>] = [:]
        let (omnibox, sent) = omnibox { listening }
        let input = omnibox.start(raindrop, isPrivate: false)
        input.change("cats")
        #expect(sent.events.isEmpty)
        #expect(sent.woken == [raindrop.extensionID])
        listening[raindrop.extensionID] = ["omnibox.onInputChanged", "omnibox.onInputEntered"]
        omnibox.flush()
        #expect(sent.events.map(\.event) == ["omnibox.onInputChanged"])
        // What's older than a moment is let go rather than sent late.
        listening = [:]
        input.enter("cats", disposition: "currentTab")
        listening[raindrop.extensionID] = ["omnibox.onInputEntered"]
        omnibox.flush(now: Date().addingTimeInterval(60))
        #expect(sent.events.count == 1)
    }

    @Test func anExtensionLetGoForgetsItsKeywordState() async throws {
        let (omnibox, _) = omnibox { [self.raindrop.extensionID: Set(BridgeOmnibox.events)] }
        _ = try await omnibox.call("setDefaultSuggestion", args: [["description": "x"]], extensionID: raindrop.extensionID)
        let input = omnibox.start(raindrop, isPrivate: false)
        omnibox.release(raindrop.extensionID)
        #expect(omnibox.defaultSuggestion(for: raindrop.extensionID) == nil)
        #expect(!input.isOpen)
        await #expect(throws: BridgeError.self) { try await omnibox.call("setDefaultSuggestion", args: [[:]], extensionID: raindrop.extensionID) }
    }

    @Test func theBridgeAnswersOmniboxCalls() {
        #expect(ExtensionBridge.handlerNames.contains("omnibox"))
        // The command bar's keyword is something you type: no permission stands in the way.
        #expect(BridgeOmnibox.permission.isEmpty)
    }

    // MARK: The extension's side

    /// bridge.js and the layers after it in a fake background; what it sends Zigzag lands in __sent.
    private func background(keyword: String?) -> JSContext {
        let context = JSContext()!
        context.exceptionHandler = { _, exception in Issue.record("\(exception?.toString() ?? "")") }
        let omnibox = keyword.map { ", omnibox: { keyword: '\($0)' }" } ?? ""
        context.evaluateScript("""
        var __timers = [];
        var setTimeout = (f) => { __timers.push(f); return __timers.length; };
        var clearTimeout = () => {}, setInterval = () => 0, clearInterval = () => {};
        var __flush = () => { for (let i = 0; i < 20 && __timers.length; i++) { const t = __timers.splice(0); t.forEach((f) => f()); } };
        var console = { log: () => {}, warn: () => {}, error: () => {} };
        const event = () => { const l = []; return { addListener: (f) => l.push(f), removeListener: () => {}, hasListener: (f) => l.includes(f), hasListeners: () => l.length > 0, fire: (...a) => l.map((f) => f(...a)) }; };
        var __sent = [], __listening = [];
        var __native = { onMessage: event(), onDisconnect: event(), postMessage: (m) => { if (m.listen) __listening.push(...m.listen); } };
        var chrome = {
          runtime: { id: 'x', getManifest: () => ({ manifest_version: 3, name: 'Probe', version: '1.0'\(omnibox) }), onMessage: event(), onConnect: event(),
                     sendNativeMessage: (host, m) => { if (host === 'zigzag.bridge') __sent.push(m); return Promise.resolve({ value: null }); },
                     connectNative: () => __native },
        };
        var browser = chrome;
        """)
        context.evaluateScript(ExtensionBridgeScript.source)
        context.evaluateScript(ExtensionBridgeScript.afterCompatibility)
        context.evaluateScript("__flush()")
        return context
    }

    @Test func anExtensionWithAKeywordGetsChromesOmnibox() throws {
        let context = background(keyword: "zz")
        context.evaluateScript("""
        var __entered = null, __started = 0;
        chrome.omnibox.onInputStarted.addListener(() => { __started++; });
        chrome.omnibox.onInputChanged.addListener((text, suggest) => {
          suggest([{ content: 'https://example.com/' + text, description: '<match>' + text + '</match>' }]);
        });
        chrome.omnibox.onInputEntered.addListener((text, disposition) => { __entered = text + '|' + disposition; });
        chrome.omnibox.setDefaultSuggestion({ description: 'Probe %s' });
        """)
        #expect(context.evaluateScript("__listening.sort().join()").toString()
                == "omnibox.onInputChanged,omnibox.onInputEntered,omnibox.onInputStarted")
        context.evaluateScript("""
        __native.onMessage.fire({ event: 'omnibox.onInputStarted', args: [] });
        __native.onMessage.fire({ event: 'omnibox.onInputChanged', args: ['cats', 7] });
        __native.onMessage.fire({ event: 'omnibox.onInputEntered', args: ['cats', 'newForegroundTab'] });
        """)
        context.evaluateScript("__flush()")
        #expect(context.evaluateScript("__started").toInt32() == 1)
        #expect(context.evaluateScript("__entered").toString() == "cats|newForegroundTab")
        let sent = context.evaluateScript("JSON.stringify(__sent.filter((m) => m.ns === 'omnibox'))").toString() ?? "[]"
        let calls = try #require(try JSONSerialization.jsonObject(with: Data(sent.utf8)) as? [[String: Any]])
        #expect(calls.map { $0["fn"] as? String } == ["setDefaultSuggestion", "suggest"])
        let suggest = try #require(calls.last?["args"] as? [Any])
        #expect(suggest.first as? Int == 7)
        #expect(((suggest.last as? [[String: Any]])?.first?["content"] as? String) == "https://example.com/cats")
        #expect(context.evaluateScript("chrome.omnibox.OnInputEnteredDisposition.NEW_BACKGROUND_TAB").toString() == "newBackgroundTab")
    }

    @Test func anExtensionWithoutAKeywordKeepsTheQuietStandIn() {
        let context = background(keyword: nil)
        #expect(context.evaluateScript("typeof chrome.omnibox.onInputEntered.addListener").toString() == "function")
        context.evaluateScript("var __answered = 'no'; chrome.omnibox.setDefaultSuggestion({ description: 'x' }).then(() => { __answered = 'yes'; });")
        context.evaluateScript("__flush()")
        #expect(context.evaluateScript("__answered").toString() == "yes")
        #expect(context.evaluateScript("__sent.filter((m) => m.ns === 'omnibox').length").toInt32() == 0)
    }
}
