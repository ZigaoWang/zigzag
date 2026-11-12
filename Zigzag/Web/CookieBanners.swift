import AppKit
import WebKit

/// Cookie banners (#175): a site's cookie consent pop-up is answered with no, by DuckDuckGo's Autoconsent, the library
/// DuckDuckGo's own browsers use, with rules kept up to date for each consent platform (OneTrust, Cookiebot, Didomi,
/// Sourcepoint, Quantcast and a thousand more). It never accepts: where a rule can't say no, the pop-up is only hidden,
/// and only where Autoconsent's own rules say hiding it is safe (a notice that sets nothing).
///
/// Settings › Privacy › Cookie banners rejects when possible (the default) or leaves them alone, and a site's controls
/// turn it on or off for one site; that row shows once a pop-up was found on the site, and says what was done there.
/// Private windows get it too, as DuckDuckGo's do. It's apart from ad blocking: turning one off leaves the other.
///
/// Autoconsent's content script (`autoconsent.playwright.js`, bundled unmodified) runs in every frame, in Zigzag's own
/// script world, where the page can't see it or its messages. Zigzag is its background: it answers `init` with the
/// rules for that frame and what to do (`initResp`), runs the few rules that have to ask the page's own scripts
/// (`eval`, in the page's world of that frame), and hears what was found and done.
enum CookieBanners {
    enum Mode: String, CaseIterable {
        /// Says no where a rule can, else hides a pop-up that's safe to hide.
        case reject
        /// Pop-ups are left as they are. They're still looked for, so a site's controls can offer to handle them.
        case leave
    }

    /// Where the choices are kept; tests use their own.
    static var defaults: UserDefaults = .standard
    /// The setting or a site's choice changed.
    static let changed = Signal<Void>()

    private static let modeKey = "CookieBanners"
    private static let handledKey = "CookieBannersHandledSites"
    private static let leftKey = "CookieBannersLeftSites"

    /// Settings › Privacy › Cookie banners. Reject when possible until changed.
    static var mode: Mode {
        get { defaults.string(forKey: modeKey).flatMap(Mode.init(rawValue:)) ?? .reject }
        set { defaults.set(newValue.rawValue, forKey: modeKey); changed.send() }
    }

    /// Sites (hosts without "www.") whose pop-ups are handled, or left alone, whatever the setting. A site covers its
    /// subdomains. Kept for every profile, as the other choices made for a site are.
    static var sitesHandled: Set<String> {
        get { Set(defaults.stringArray(forKey: handledKey) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: handledKey) }
    }

    static var sitesLeft: Set<String> {
        get { Set(defaults.stringArray(forKey: leftKey) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: leftKey) }
    }

    static func site(of url: URL?) -> String? { ContentBlocker.site(of: url) }

    private static func covers(_ sites: Set<String>, _ site: String) -> Bool {
        sites.contains { site == $0 || site.hasSuffix("." + $0) }
    }

    /// The site's own choice: handled, left alone, or nil to follow the setting.
    static func choice(for url: URL?) -> Bool? {
        guard let site = site(of: url) else { return nil }
        if covers(sitesHandled, site) { return true }
        if covers(sitesLeft, site) { return false }
        return nil
    }

    /// Handles a site's pop-ups, leaves them alone, or back to following the setting (nil). A choice the same as the
    /// setting's isn't kept: the site simply follows it. Whatever covered the site before (its parent domain's too) goes.
    static func setChoice(_ handled: Bool?, for url: URL?) {
        guard let site = site(of: url) else { return }
        var yes = sitesHandled.filter { !(site == $0 || site.hasSuffix("." + $0)) }
        var no = sitesLeft.filter { !(site == $0 || site.hasSuffix("." + $0)) }
        if let handled, handled != (mode == .reject) {
            if handled { yes.insert(site) } else { no.insert(site) }
        }
        sitesHandled = yes
        sitesLeft = no
        changed.send()
    }

    /// Every site's choice forgotten (Settings › Privacy › Sites › Reset All).
    static func forgetAll() {
        sitesHandled = []
        sitesLeft = []
        changed.send()
    }

    /// Whether pop-ups are handled: the site's own choice first, then the setting.
    static func handles(mode: Mode, site: Bool?) -> Bool { site ?? (mode == .reject) }

    static func handles(_ url: URL?) -> Bool { handles(mode: mode, site: choice(for: url)) }

    /// Only web pages have consent pop-ups to answer; never Zigzag's own pages or an extension's.
    static func applies(to url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "http"
    }

    // MARK: What was found on a page

    /// What Autoconsent found and did on the page in a web view, in any of its frames.
    enum Outcome: Int, Comparable {
        /// A consent pop-up, left as it was (Leave alone, or no rule could answer it).
        case found
        /// Hidden, by a rule that says hiding is all it needs.
        case hidden
        /// Answered with no.
        case rejected

        static func < (a: Outcome, b: Outcome) -> Bool { a.rawValue < b.rawValue }
    }

    private final class Seen {
        weak var webView: WKWebView?
        var site: String
        var outcome: Outcome
        init(_ webView: WKWebView, site: String, outcome: Outcome) { self.webView = webView; self.site = site; self.outcome = outcome }
    }

    private static var seen: [ObjectIdentifier: Seen] = [:]

    /// What was found on the site a web view is on, if anything: what its controls say.
    static func outcome(in webView: WKWebView?, site: String) -> Outcome? {
        guard let webView, let entry = seen[ObjectIdentifier(webView)], entry.webView === webView, entry.site == site else { return nil }
        return entry.outcome
    }

    /// Notes what a frame of the page found or did. A page that was answered stays answered while it's on the same
    /// site: a pop-up seen again in another frame doesn't take that back.
    static func note(_ outcome: Outcome, in webView: WKWebView, site: String) {
        seen = seen.filter { $0.value.webView != nil }
        let key = ObjectIdentifier(webView)
        if let entry = seen[key], entry.webView === webView, entry.site == site {
            entry.outcome = max(entry.outcome, outcome)
        } else {
            seen[key] = Seen(webView, site: site, outcome: outcome)
        }
    }

    /// Forgets what was found in a web view: its site's choice changed, and it loads again to follow it.
    static func forget(in webView: WKWebView) {
        seen[ObjectIdentifier(webView)] = nil
    }

    // MARK: The content script

    static let world = WKContentWorld.world(name: "zigzag-consent")
    static let messageName = "zigzagConsent"

    /// The first line of the script, so it can be told from a web view's other scripts at a glance.
    static let scriptMark = "/* zigzag cookie banners */\n"

    /// The messages from Autoconsent that Zigzag answers or hears. Its `report`s, sent at every step, aren't sent on.
    static let heard: Set<String> = ["init", "eval", "popupFound", "optOutResult", "autoconsentDone"]

    /// Zigzag's side of the script: the two globals Autoconsent talks through (window.autoconsentSendMessage, which
    /// posts to Zigzag and hands its answer back to window.autoconsentReceiveMessage), set in Zigzag's own world, then
    /// Autoconsent itself, as it comes. Only in web pages' frames.
    static func source(engine: String) -> String {
        let heard = json(heard.sorted())
        return scriptMark + """
        (function () {
          'use strict';
          if (location.protocol !== 'https:' && location.protocol !== 'http:') return;
          const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(messageName);
          if (!handler) return;
          const heard = new Set(\(heard));
          window.autoconsentSendMessage = async (message) => {
            if (!message || !heard.has(message.type)) return;
            let reply = null;
            try { reply = await handler.postMessage(message); } catch (e) { return; }
            if (typeof reply === 'string' && reply && window.autoconsentReceiveMessage) {
              await window.autoconsentReceiveMessage(JSON.parse(reply));
            }
          };
        \(engine)
        })();
        """
    }

    static func resource(_ name: String, _ ext: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// At document start, in every frame: Autoconsent only sends `init` there and waits; it looks for pop-ups once the
    /// frame's document is ready, when the browser is idle.
    static let script = WKUserScript(source: source(engine: resource("autoconsent.playwright", "js")),
                                     injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world)

    /// A web view's set of scripts gets Autoconsent, once.
    static func attach(to controller: WKUserContentController) {
        guard !controller.userScripts.contains(where: { ($0.source as NSString).hasPrefix(scriptMark) }) else { return }
        controller.addUserScript(script)
        controller.removeScriptMessageHandler(forName: messageName, contentWorld: world)
        controller.addScriptMessageHandler(Messages.shared, contentWorld: world, name: messageName)
        // The rules are read and their sites' patterns made ready before the first page asks.
        Task.detached(priority: .utility) { _ = Rules.shared }
    }

    // MARK: Answering Autoconsent

    /// What Autoconsent is told to do in a frame (its `Config`): say no and hide what's safe to hide while it looks,
    /// or only look. It never says yes, and its guesses from a pop-up's words (heuristics, which can accept) stay off.
    static func config(handles: Bool) -> [String: Any] {
        [
            "enabled": true,
            "autoAction": handles ? "optOut" : NSNull(),
            "disabledCmps": [String](),
            "enablePrehide": handles,
            "enableCosmeticRules": true,
            "enableGeneratedRules": true,
            "enableHeuristicDetection": false,
            "heuristicMode": "off",
            "enablePopupMutationObserver": false,
            "detectRetries": 20,
            "isMainWorld": false,
            "prehideTimeout": 2000,
            "visualTest": false,
            "performanceLoggingEnabled": false,
            "logs": ["lifecycle": false, "rulesteps": false, "detectionsteps": false, "evals": false, "errors": false, "messages": false, "waits": false],
        ]
    }

    static func json(_ object: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// The answer to a frame's `init`, as JSON: what to do (`config`, JSON) and the rules for that frame (JSON).
    nonisolated static func initResponse(config: String, rules: String) -> String {
        #"{"type":"initResp","config":"# + config + #","rules":{"autoconsent":[],"compact":"# + rules + "}}"
    }

    static func evalResponse(id: String, result: Bool) -> String {
        json(["type": "evalResp", "id": id, "result": result])
    }

    /// Only the rules' own snippets, by name, run in the page (EVAL_COOKIEBOT_1 and the like).
    nonisolated static func isSnippet(_ id: String?) -> Bool {
        guard let id, id.hasPrefix("EVAL_"), id.count <= 80 else { return false }
        return id.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber || $0 == "_") }
    }

    /// The page the frame is in, which the site's choice is read from: the frame's own address for the page itself,
    /// the web view's for a frame inside it.
    static func topURL(frameURL: String?, isMainFrame: Bool, webViewURL: URL?) -> URL? {
        isMainFrame ? frameURL.flatMap(URL.init(string:)) ?? webViewURL : webViewURL
    }

    /// What a message from a frame means for its page: what to note there, if anything.
    static func outcome(of message: [String: Any]) -> Outcome? {
        switch message["type"] as? String {
        case "popupFound": return .found
        case "autoconsentDone": return message["isCosmetic"] as? Bool == true ? .hidden : .rejected
        default: return nil
        }
    }

    /// Hears Autoconsent in every frame, and answers.
    private final class Messages: NSObject, WKScriptMessageHandlerWithReply {
        static let shared = Messages()

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String, let webView = message.webView else {
                replyHandler(nil, nil); return
            }
            let frame = message.frameInfo
            let top = CookieBanners.topURL(frameURL: body["url"] as? String, isMainFrame: frame.isMainFrame, webViewURL: webView.url)
            guard CookieBanners.applies(to: top), let site = CookieBanners.site(of: top) else { replyHandler(nil, nil); return }
            switch type {
            case "init":
                let config = CookieBanners.json(CookieBanners.config(handles: CookieBanners.handles(top)))
                let url = body["url"] as? String ?? "", main = frame.isMainFrame
                Task.detached(priority: .userInitiated) {
                    guard let rules = Rules.shared?.json(url: url, mainFrame: main) else {
                        await MainActor.run { replyHandler(nil, nil) }
                        return
                    }
                    let reply = CookieBanners.initResponse(config: config, rules: rules)
                    await MainActor.run { replyHandler(reply, nil) }
                }
            case "eval":
                guard let id = body["id"] as? String, let code = body["code"] as? String, CookieBanners.isSnippet(body["snippetId"] as? String) else {
                    replyHandler(nil, nil); return
                }
                // In the page's own world of the same frame, where the consent platform's script is.
                webView.callAsyncJavaScript("try { return !!(\(code)); } catch (e) { return false; }", arguments: [:], in: frame, in: .page) { result in
                    let yes = (try? result.get()) as? Bool ?? false
                    replyHandler(CookieBanners.evalResponse(id: id, result: yes), nil)
                }
            default:
                if let outcome = CookieBanners.outcome(of: body) {
                    CookieBanners.note(outcome, in: webView, site: site)
                    #if DEBUG
                    debugLog("cookie banners: \(outcome) \(body["cmp"] as? String ?? "") on \(site)")
                    #endif
                }
                replyHandler(nil, nil)
            }
        }
    }

    // MARK: Rules

    /// Autoconsent's rules in their compact form (`autoconsent-compact-rules.json`), and the ones each frame gets, as
    /// Autoconsent's own `filterCompactRules` chooses them: in the page itself, the rules for any site and those for
    /// this one; in a frame, the rules that run in frames. Each rule is kept as its JSON, so a frame's are only joined.
    nonisolated final class Rules: @unchecked Sendable {
        static let shared: Rules? = {
            guard let url = Bundle.main.url(forResource: "autoconsent-compact-rules", withExtension: "json"),
                  let data = try? Data(contentsOf: url) else { return nil }
            return Rules(data: data)
        }()

        let version: Int
        /// Each rule as JSON, in the file's order.
        let rules: [String]
        /// Each rule's address pattern, as a JavaScript RegExp would read it: nil for one that has none (for any site)
        /// or that ICU can't read (for none, `hasPattern` tells which).
        let patterns: [NSRegularExpression?]
        let hasPattern: [Bool]
        /// Where each rule runs, the page, frames or both, as two digits (`CompactCMPRule`'s fifth field).
        let runContexts: [Int]
        let generic: Range<Int>
        let frames: Range<Int>
        let specific: Range<Int>
        /// The strings every rule refers to by number, as JSON: all of them, and those up to the frames' last one.
        let allStrings: String
        let frameStrings: String
        /// What the page itself gets on a site with no rules of its own: most sites.
        let genericJSON: String

        init?(data: Data) {
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let v = root["v"] as? Int, v == 1, let s = root["s"] as? [String], let r = root["r"] as? [[Any]],
                  let index = root["index"] as? [String: Any],
                  let g = index["genericRuleRange"] as? [Int], let f = index["frameRuleRange"] as? [Int], let sp = index["specificRuleRange"] as? [Int],
                  g.count == 2, f.count == 2, sp.count == 2, let frameStringEnd = index["frameStringEnd"] as? Int,
                  let genericStringEnd = index["genericStringEnd"] as? Int else { return nil }
            func range(_ pair: [Int]) -> Range<Int>? {
                pair[0] <= pair[1] && pair[0] >= 0 && pair[1] <= r.count ? pair[0]..<pair[1] : nil
            }
            guard let generic = range(g), let frames = range(f), let specific = range(sp),
                  frameStringEnd <= s.count, genericStringEnd <= s.count else { return nil }
            func json(_ value: Any) -> String? {
                (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])).flatMap { String(data: $0, encoding: .utf8) }
            }
            var rules: [String] = [], patterns: [NSRegularExpression?] = [], has: [Bool] = [], contexts: [Int] = []
            for rule in r {
                guard rule.count >= 5, let encoded = json(rule) else { return nil }
                rules.append(encoded)
                let pattern = rule[3] as? String ?? ""
                has.append(!pattern.isEmpty)
                patterns.append(pattern.isEmpty ? nil : try? NSRegularExpression(pattern: pattern))
                contexts.append(rule[4] as? Int ?? 22)
            }
            guard let all = json(s), let framed = json(Array(s[..<frameStringEnd])), let genericStrings = json(Array(s[..<genericStringEnd])) else { return nil }
            version = v
            self.rules = rules
            self.patterns = patterns
            hasPattern = has
            runContexts = contexts
            self.generic = generic
            self.frames = frames
            self.specific = specific
            allStrings = all
            frameStrings = framed
            genericJSON = Self.ruleset(v, genericStrings, rules[generic])
        }

        private static func ruleset(_ v: Int, _ strings: String, _ rules: ArraySlice<String>) -> String {
            #"{"v":"# + String(v) + #","s":"# + strings + #","r":["# + rules.joined(separator: ",") + "]}"
        }

        /// Whether a rule runs in this frame, at this address (Autoconsent's `shouldRunRuleInContext`): the page or a
        /// frame by where it says it runs, and its address pattern, if it has one, matching.
        func runs(_ i: Int, url: String, mainFrame: Bool) -> Bool {
            let context = runContexts[i]
            if mainFrame && context == 1 { return false }
            if !mainFrame && [20, 22, 10, 12].contains(context) { return false }
            // No pattern: for any site. One that couldn't be read: for none.
            guard hasPattern[i] else { return true }
            guard let pattern = patterns[i] else { return false }
            return pattern.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
        }

        /// The rules a frame at `url` gets, as Autoconsent's compact ruleset in JSON.
        func json(url: String, mainFrame: Bool) -> String {
            if !mainFrame {
                return Self.ruleset(version, frameStrings, ArraySlice(frames.filter { runs($0, url: url, mainFrame: false) }.map { rules[$0] }))
            }
            let mine = specific.filter { runs($0, url: url, mainFrame: true) }
            if mine.isEmpty { return genericJSON }
            return Self.ruleset(version, allStrings, ArraySlice(generic.map { rules[$0] } + mine.map { rules[$0] }))
        }
    }
}
