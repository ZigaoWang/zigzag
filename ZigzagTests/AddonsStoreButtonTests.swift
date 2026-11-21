import Foundation
import Testing
import WebKit
@testable import Zigzag

@MainActor
struct AddonsStoreButtonTests {
    private final class Loading: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    }

    private static let file = "https://addons.mozilla.org/firefox/downloads/file/5257481/ublock_origin-1.76.4.xpi"

    /// AMO's install button as the store serves it.
    private static func button(_ label: String = "Add to Firefox", href: String = file) -> String {
        #"<div class="AMInstallButton AMInstallButton--noDownloadLink"><a class="Button Button--action AMInstallButton-button Button--puffy" href="\#(href)">\#(label)</a></div>"#
    }

    private static func listing(_ type: String = "extension", _ inside: String = button()) -> String {
        #"<div class="Addon Addon-\#(type)"><p class="prose">Add to Firefox, made for Firefox.</p>\#(inside)<a class="InstallButtonWrapper-download-link" href="\#(file)">Download file</a></div>"#
    }

    /// The words of every link on `html`, loaded at `address` with the script.
    private func words(_ html: String, at address: String, then script: String? = nil) async throws -> [String] {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(AddonsStoreButton.script)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let loading = Loading()
        webView.navigationDelegate = loading
        await withCheckedContinuation { done in
            loading.done = done
            webView.loadHTMLString(html, baseURL: URL(string: address))
        }
        withExtendedLifetime(loading) {}
        if let script { _ = try await webView.callAsyncJavaScript(script, contentWorld: .page) }
        let read = "return [...document.querySelectorAll('a, .prose')].map((e) => e.textContent)"
        return try #require(try await webView.callAsyncJavaScript(read, contentWorld: .page) as? [String])
    }

    private var add: String { AddonsStoreButton.config["add"] ?? "" }

    @Test func theInstallButtonSaysZigzagAndNothingElseChanges() async throws {
        let shown = try await words(Self.listing(), at: "https://addons.mozilla.org/en-US/firefox/addon/ublock-origin/")
        #expect(shown == ["Add to Firefox, made for Firefox.", add, "Download file"])
        #expect(add == WebStoreButton.config["add"])
        #expect(!add.isEmpty)
    }

    @Test func anyLanguageAndALocalePath() async throws {
        let shown = try await words(Self.listing("extension", Self.button("Zu Firefox hinzufügen", href: "/de/firefox/downloads/file/1/x.xpi")),
                                    at: "https://addons.mozilla.org/de/firefox/addon/ublock-origin/")
        #expect(shown[1] == add)
    }

    @Test func aRedrawnButtonIsRenamedAgain() async throws {
        let shown = try await words(Self.listing(), at: "https://addons.mozilla.org/en-US/firefox/addon/ublock-origin/",
                                    then: "document.querySelector('.AMInstallButton-button').firstChild.data = 'Add to Firefox'; await new Promise((r) => setTimeout(r, 50))")
        #expect(shown[1] == add)
    }

    @Test func themesAndPagesThatDontSayWhatTheyListKeepTheirWords() async throws {
        let address = "https://addons.mozilla.org/en-US/firefox/addon/dark-space-theme/"
        #expect(try await words(Self.listing("statictheme Addon-theme", Self.button("Install Theme")), at: address)[1] == "Install Theme")
        // The versions page: no Addon-extension around the button.
        #expect(try await words(Self.button(), at: address + "versions/") == ["Add to Firefox"])
    }

    @Test func onlyALinkToTheStoresFileWithJustWords() async throws {
        let address = "https://addons.mozilla.org/en-US/firefox/addon/ublock-origin/"
        for inside in [Self.button(href: "https://example.com/firefox/downloads/file/1/x.xpi"),
                       Self.button(href: "/en-US/firefox/addon/ublock-origin/"),
                       Self.button("<span>Add to Firefox</span>")] {
            #expect(try await words(Self.listing("extension", inside), at: address)[1] == "Add to Firefox", "\(inside)")
        }
    }

    @Test func otherSitesAreLeftAsTheyAre() async throws {
        for address in ["https://example.com/firefox/addon/x/", "http://addons.mozilla.org/en-US/firefox/addon/x/",
                        "https://addons.mozilla.org.example.com/en-US/firefox/addon/x/"] {
            #expect(try await words(Self.listing(), at: address)[1] == "Add to Firefox", "\(address)")
        }
    }

    @Test func framesAreLeftAsTheyAre() {
        #expect(AddonsStoreButton.script.isForMainFrameOnly)
        #expect(AddonsStoreButton.source.contains("window.top !== window"))
        #expect(!AddonsStoreButton.source.contains("const config = {};"))
    }

    // MARK: Get Extensions

    @Test func getExtensionsOffersBothStores() {
        #expect(ExtensionStore.Shop.allCases == [.chromeWebStore, .firefoxAddons])
        #expect(ExtensionStore.Shop.chromeWebStore.url == ExtensionStore.webStoreURL)
        #expect(ExtensionStore.Shop.firefoxAddons.url.absoluteString == "https://addons.mozilla.org/firefox/extensions/")
        #expect(ExtensionStore.Shop.allCases.map(\.title) == ["Chrome Web Store", "Firefox Add-ons"])
    }
}
