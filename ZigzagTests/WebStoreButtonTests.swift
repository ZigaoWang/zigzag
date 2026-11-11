import Foundation
import JavaScriptCore
import Testing
@testable import Zigzag

@MainActor
struct WebStoreButtonTests {
    private let id = "bcjindcccaagfpapjjmafapmmgkkhgoa"

    // MARK: Who's heard

    @Test func onlyTheStoresOwnPageIsHeard() {
        #expect(WebStoreButton.isStore(scheme: "https", host: "chromewebstore.google.com", port: 0, isMainFrame: true))
        #expect(WebStoreButton.isStore(scheme: "https", host: "ChromeWebStore.google.com", port: 443, isMainFrame: true))
        // A frame on the store, plain http, another port, the old store, a look-alike host: none of them.
        #expect(!WebStoreButton.isStore(scheme: "https", host: "chromewebstore.google.com", port: 0, isMainFrame: false))
        #expect(!WebStoreButton.isStore(scheme: "http", host: "chromewebstore.google.com", port: 0, isMainFrame: true))
        #expect(!WebStoreButton.isStore(scheme: "https", host: "chromewebstore.google.com", port: 8443, isMainFrame: true))
        #expect(!WebStoreButton.isStore(scheme: "https", host: "chrome.google.com", port: 0, isMainFrame: true))
        #expect(!WebStoreButton.isStore(scheme: "https", host: "chromewebstore.google.com.example.com", port: 0, isMainFrame: true))
        #expect(!WebStoreButton.isStore(scheme: "https", host: "evil-chromewebstore.google.com", port: 0, isMainFrame: true))
    }

    @Test func theTabsAddressMustBeTheStoreToo() {
        #expect(WebStoreButton.isStore(URL(string: "https://chromewebstore.google.com/detail/json-formatter/\(id)")))
        #expect(!WebStoreButton.isStore(URL(string: "https://example.com/chromewebstore.google.com")))
        #expect(!WebStoreButton.isStore(URL(string: "http://chromewebstore.google.com/")))
        #expect(!WebStoreButton.isStore(nil))
    }

    // MARK: What's asked

    @Test func requestsNeedARealExtensionID() {
        #expect(WebStoreButton.Request(["kind": "list"]) == .list)
        #expect(WebStoreButton.Request(["kind": "status", "id": id]) == .status(id))
        #expect(WebStoreButton.Request(["kind": "install", "id": id]) == .install(id))
        #expect(WebStoreButton.Request(["kind": "remove", "id": id]) == .remove(id))
        #expect(WebStoreButton.Request(["kind": "install"]) == nil)
        #expect(WebStoreButton.Request(["kind": "install", "id": "BCJINDCCCAAGFPAPJJMAFAPMMGKKHGOA"]) == nil)
        #expect(WebStoreButton.Request(["kind": "install", "id": "bcjindcccaagfpapjjmafapmmgkkhgoz"]) == nil)
        #expect(WebStoreButton.Request(["kind": "install", "id": "../../etc"]) == nil)
        #expect(WebStoreButton.Request(["kind": "install", "id": 42]) == nil)
        #expect(WebStoreButton.Request(["kind": "setEnabled", "id": id]) == nil)
        #expect(WebStoreButton.Request("install") == nil)
        #expect(WebStoreButton.Request([id]) == nil)
    }

    @Test func statusIsChromesWord() {
        #expect(WebStoreButton.status(installed: false, enabled: false) == "installable")
        #expect(WebStoreButton.status(installed: true, enabled: true) == "enabled")
        #expect(WebStoreButton.status(installed: true, enabled: false) == "disabled")
    }

    @Test func theListingsIDIsReadFromItsAddress() {
        #expect(ExtensionStore.webStoreID(from: URL(string: "https://chromewebstore.google.com/detail/json-formatter/\(id)")) == id)
        #expect(ExtensionStore.webStoreID(from: URL(string: "https://chromewebstore.google.com/detail/\(id)?hl=en")) == id)
        #expect(ExtensionStore.webStoreID(from: URL(string: "https://chromewebstore.google.com/category/extensions")) == nil)
        #expect(ExtensionStore.webStoreID(from: URL(string: "https://example.com/detail/x/\(id)")) == nil)
    }

    // MARK: The page script

    /// Runs web-store.js in a stand-in page at `href`, with a handler that answers as Zigzag would.
    /// `buttons` are the store's install buttons on the page, as their jsname (nil for none) and label.
    private func page(_ href: String, framed: Bool = false, installed: Bool = false, buttons: [(jsname: String?, label: String)] = []) throws -> JSContext {
        let source = WebStoreButton.source
        let location = try #require(URL(string: href))
        let context = try #require(JSContext())
        context.evaluateScript("""
        var window = this;
        window.top = \(framed ? "{}" : "window");
        var location = { protocol: '\(location.scheme ?? ""):', host: '\(location.host ?? "")' };
        var Node = { TEXT_NODE: 3 }, NodeFilter = { SHOW_TEXT: 4 };
        var MutationObserver = function () { this.observe = () => {}; };
        var __buttons = \(try buttonsJS(buttons));
        var document = { documentElement: {}, visibilityState: 'visible', adoptedStyleSheets: [], addEventListener: () => {},
          querySelectorAll: (selector) => selector === '[jscontroller="ri2s0b"] button' ? __buttons : [] };
        var __posted = [], __installed = \(installed);
        window.webkit = { messageHandlers: { zigzagWebStore: { postMessage: (m) => {
          __posted.push(m.kind);
          if (m.kind === 'list') return Promise.resolve(__installed ? [{ id: '\(id)', name: 'JSON Formatter', version: '1', enabled: true }] : []);
          if (m.kind === 'status') return Promise.resolve(__installed ? 'enabled' : 'installable');
          if (m.kind === 'install') { __installed = true; return Promise.resolve(true); }
          if (m.kind === 'remove') return Promise.resolve(false);
          return Promise.resolve(null);
        } } } };
        """)
        context.evaluateScript(source)
        #expect(context.exception == nil)
        return context
    }

    /// Stand-ins for the store's buttons: a jsname, and the span that holds its words.
    private func buttonsJS(_ buttons: [(jsname: String?, label: String)]) throws -> String {
        let items = try buttons.map { button -> String in
            let jsname = try String(data: JSONSerialization.data(withJSONObject: button.jsname as Any, options: .fragmentsAllowed), encoding: .utf8) ?? "null"
            let label = try String(data: JSONSerialization.data(withJSONObject: button.label, options: .fragmentsAllowed), encoding: .utf8) ?? "''"
            return "(() => { const text = { nodeType: 3, data: \(label) }; const span = { original: text, firstChild: text, childNodes: [text], get textContent() { return this.firstChild.data; }, set textContent(v) { this.firstChild = { nodeType: 3, data: v }; this.childNodes = [this.firstChild]; } }; return { getAttribute: (n) => n === 'jsname' ? \(jsname) : null, "
                + "querySelector: (q) => q === 'span[jsname=\"V67aGc\"]' ? span : null, span }; })()"
        }
        return "[" + items.joined(separator: ", ") + "]"
    }

    @Test func otherSitesAndFramesGetNoChrome() throws {
        for (href, framed) in [("https://example.com/", false), ("https://chrome.google.com/webstore", false),
                               ("http://chromewebstore.google.com/", false), ("https://chromewebstore.google.com/", true)] {
            let context = try page(href, framed: framed)
            #expect(context.evaluateScript("typeof window.chrome")?.toString() == "undefined", "\(href) framed: \(framed)")
        }
    }

    @Test func theStoreGetsChromesInstallAPI() throws {
        let context = try page("https://chromewebstore.google.com/detail/json-formatter/\(id)")
        // What the store checks before it turns its button on.
        #expect(context.evaluateScript("!!(window.chrome.management && window.chrome.webstorePrivate && window.chrome.webstorePrivate.beginInstallWithManifest3)")?.toBool() == true)
        #expect(context.evaluateScript("typeof chrome.management.getAll + typeof chrome.management.uninstall + typeof chrome.management.onInstalled.addListener")?.toString() == "functionfunctionfunction")
        context.evaluateScript("var __status; chrome.webstorePrivate.getExtensionStatus('\(id)', null, (s) => { __status = s; });")
        #expect(context.evaluateScript("__status")?.toString() == "installable")
    }

    @Test func addingAnswersAsChromeDoesAndTellsTheStore() throws {
        let context = try page("https://chromewebstore.google.com/detail/json-formatter/\(id)")
        context.evaluateScript("""
        var __result, __completed = false, __heard = [];
        chrome.management.onInstalled.addListener((info) => __heard.push(info.id));
        chrome.webstorePrivate.beginInstallWithManifest3({ id: '\(id)', manifest: '{}' }, (r) => {
          __result = r;
          chrome.webstorePrivate.completeInstall('\(id)', () => { __completed = !chrome.runtime.lastError; });
        });
        """)
        #expect(context.evaluateScript("__result")?.toString() == "")
        #expect(context.evaluateScript("__completed")?.toBool() == true)
        #expect(context.evaluateScript("__heard.join()")?.toString() == id)
        #expect(context.evaluateScript("__posted.includes('install')")?.toBool() == true)
    }

    @Test func aRemovalNotConfirmedIsChromesCancel() throws {
        let context = try page("https://chromewebstore.google.com/detail/json-formatter/\(id)", installed: true)
        context.evaluateScript("""
        var __error = null, __gone = false;
        chrome.management.onUninstalled.addListener(() => { __gone = true; });
        chrome.management.uninstall('\(id)', { showConfirmDialog: true }, () => { __error = chrome.runtime.lastError && chrome.runtime.lastError.message; });
        """)
        #expect(context.evaluateScript("__error")?.toString() == "User cancelled uninstall")
        #expect(context.evaluateScript("__gone")?.toBool() == false)
        // Only while the callback runs, as in Chrome.
        #expect(context.evaluateScript("typeof chrome.runtime.lastError")?.toString() == "undefined")
    }

    @Test func theStoreHearsZigzagsChromeVersion() throws {
        #expect(!WebStoreButton.source.contains("const config = {};"))
        let context = try page("https://chromewebstore.google.com/detail/json-formatter/\(id)")
        context.evaluateScript("var __version; chrome.webstorePrivate.getFullChromeVersion((v) => { __version = v.version_number; });")
        #expect(context.evaluateScript("__version")?.toString() == ExtensionStore.chromeVersion + ".0.0")
    }

    @Test func theButtonSaysZigzagsOwnWordsByWhichButtonItIs() throws {
        let add = try #require(WebStoreButton.config["add"]), remove = try #require(WebStoreButton.config["remove"])
        // In another language the store's words don't say Chrome where they'd be swapped: the button's name decides.
        let context = try page("https://chromewebstore.google.com/detail/json-formatter/\(id)", buttons: [
            ("wQO0od", "Zu Chrome hinzufügen"), ("ajZLRd", "Aus Chrome entfernen"), (nil, "Add to Chrome"), ("somethingElse", "Adding…"),
        ])
        #expect(context.evaluateScript("__buttons.map((b) => b.span.textContent).join('|')")?.toString() == [add, remove, add, "Adding…"].joined(separator: "|"))
        // Changed in place: the store keeps its own text node, and may write to it again when it redraws.
        #expect(context.evaluateScript("__buttons.every((b) => b.span.firstChild === b.span.original)")?.toBool() == true)
    }
}
