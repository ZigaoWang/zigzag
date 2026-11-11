import Foundation
import JavaScriptCore
import Testing
@testable import Zigzag

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
    private func page(_ href: String, framed: Bool = false, installed: Bool = false) throws -> JSContext {
        let url = try #require(Bundle.main.url(forResource: "web-store", withExtension: "js"))
        let source = try String(contentsOf: url, encoding: .utf8)
        let location = try #require(URL(string: href))
        let context = try #require(JSContext())
        context.evaluateScript("""
        var window = this;
        window.top = \(framed ? "{}" : "window");
        var location = { protocol: '\(location.scheme ?? ""):', host: '\(location.host ?? "")' };
        var Node = { TEXT_NODE: 3 }, NodeFilter = { SHOW_TEXT: 4 };
        var MutationObserver = function () { this.observe = () => {}; };
        var document = { documentElement: {}, visibilityState: 'visible', adoptedStyleSheets: [], addEventListener: () => {}, querySelectorAll: () => [] };
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
}
