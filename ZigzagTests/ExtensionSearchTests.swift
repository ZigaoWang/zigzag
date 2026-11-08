import Foundation
import Testing
@testable import Zigzag

/// Search engines extensions give (`chrome_settings_overrides.search_provider`). None of these reads the library.
struct ExtensionSearchTests {
    /// The search provider of OpenAI's "ChatGPT search" (ejcfepkfckglbgocfkanmcdngdijcgld), as its manifest has it.
    static let chatGPT: [String: Any] = [
        "manifest_version": 3,
        "name": "ChatGPT search",
        "chrome_settings_overrides": ["search_provider": [
            "name": "ChatGPT",
            "keyword": "chatgpt.com",
            "favicon_url": "https://chatgpt.com/faviconDark.ico",
            "search_url": "https://chatgpt.com/?q={searchTerms}&hints=search&ref=ext",
            "encoding": "UTF-8",
            "is_default": true,
        ] as [String: Any]],
    ]

    static func manifest(_ provider: [String: Any]) -> [String: Any] {
        ["manifest_version": 3, "chrome_settings_overrides": ["search_provider": provider]]
    }

    @Test func chatGPTSearchIsRead() throws {
        let provider = try #require(ExtensionSearchProvider(manifest: Self.chatGPT, extensionID: "ejcfepkfckglbgocfkanmcdngdijcgld"))
        #expect(provider.name == "ChatGPT")
        #expect(provider.extensionID == "ejcfepkfckglbgocfkanmcdngdijcgld")
        #expect(provider.suggestTemplate == nil)
        #expect(provider.homeURL.absoluteString == "https://chatgpt.com")
        #expect(provider.searchURL("shanghai metro")?.absoluteString == "https://chatgpt.com/?q=shanghai%20metro&hints=search&ref=ext")
        #expect(provider.suggestionsURL("shanghai") == nil)
    }

    /// Words that mean something in an address stay words: they can't add a parameter or end the query.
    @Test func wordsAreEncoded() {
        let template = "https://example.com/search?q={searchTerms}&src=ext"
        #expect(ExtensionSearchProvider.expand(template, query: "a&b=c+d?#e")?.absoluteString == "https://example.com/search?q=a%26b%3Dc%2Bd%3F%23e&src=ext")
        #expect(ExtensionSearchProvider.expand(template, query: "上海 地铁")?.absoluteString == "https://example.com/search?q=%E4%B8%8A%E6%B5%B7%20%E5%9C%B0%E9%93%81&src=ext")
        #expect(ExtensionSearchProvider.expand(template, query: "100%")?.absoluteString == "https://example.com/search?q=100%25&src=ext")
    }

    @Test func onlyAnHTTPSAddressWithAPlaceForTheWords() {
        #expect(ExtensionSearchProvider.isSafe("https://chatgpt.com/?q={searchTerms}"))
        #expect(!ExtensionSearchProvider.isSafe("http://chatgpt.com/?q={searchTerms}"))
        #expect(!ExtensionSearchProvider.isSafe("javascript:alert({searchTerms})"))
        #expect(!ExtensionSearchProvider.isSafe("data:text/html,{searchTerms}"))
        #expect(!ExtensionSearchProvider.isSafe("https://chatgpt.com/"))
        // A placeholder Zigzag doesn't fill would be sent as it is.
        #expect(!ExtensionSearchProvider.isSafe("{google:baseURL}search?q={searchTerms}"))
        #expect(!ExtensionSearchProvider.isSafe("https://example.com/?q={searchTerms}&ie={inputEncoding}"))
        #expect(ExtensionSearchProvider.expand("http://example.com/?q={searchTerms}", query: "x") == nil)
    }

    @Test func onlyAProviderThatAsksToBeTheDefault() {
        let base: [String: Any] = ["name": "Example", "search_url": "https://example.com/?q={searchTerms}"]
        #expect(ExtensionSearchProvider(manifest: Self.manifest(base.merging(["is_default": true]) { $1 }), extensionID: "x") != nil)
        #expect(ExtensionSearchProvider(manifest: Self.manifest(base), extensionID: "x") == nil)
        #expect(ExtensionSearchProvider(manifest: Self.manifest(base.merging(["is_default": false]) { $1 }), extensionID: "x") == nil)
        #expect(ExtensionSearchProvider(manifest: ["manifest_version": 3, "name": "Dark Reader"], extensionID: "x") == nil)
    }

    @Test func unsafeOrUnreadableProvidersAreLeftOut() {
        func read(_ fields: [String: Any]) -> ExtensionSearchProvider? {
            ExtensionSearchProvider(manifest: Self.manifest(fields.merging(["is_default": true]) { $1 }), extensionID: "x")
        }
        #expect(read(["name": "Plain", "search_url": "http://example.com/?q={searchTerms}"]) == nil)
        #expect(read(["name": "None"]) == nil)
        #expect(read(["name": "Other", "search_url": "https://example.com/?q={searchTerms}", "encoding": "Shift_JIS"]) == nil)
        #expect(read(["name": "Same", "search_url": "https://example.com/?q={searchTerms}", "encoding": "utf-8"]) != nil)
    }

    @Test func nameFallsBackOnTheSite() {
        func name(_ value: Any?) -> String? {
            var fields: [String: Any] = ["search_url": "https://www.example.com/s?q={searchTerms}", "is_default": true]
            fields["name"] = value
            return ExtensionSearchProvider(manifest: Self.manifest(fields), extensionID: "x")?.name
        }
        #expect(name("Example Search") == "Example Search")
        #expect(name(nil) == "example.com")
        #expect(name("  ") == "example.com")
        #expect(name("__MSG_searchName__") == "example.com")
    }

    @Test func suggestionsOnlyFromASafeAddress() throws {
        let fields: [String: Any] = ["name": "Example", "search_url": "https://example.com/?q={searchTerms}", "is_default": true,
                                     "suggest_url": "https://example.com/suggest?q={searchTerms}"]
        let provider = try #require(ExtensionSearchProvider(manifest: Self.manifest(fields), extensionID: "x"))
        #expect(provider.suggestionsURL("a b")?.absoluteString == "https://example.com/suggest?q=a%20b")
        let plain = try #require(ExtensionSearchProvider(manifest: Self.manifest(fields.merging(["suggest_url": "http://example.com/s?q={searchTerms}"]) { $1 }), extensionID: "x"))
        #expect(plain.suggestionsURL("a b") == nil)
    }

    /// The custom engine and an extension's encode the words the same way.
    @Test func customAndExtensionEnginesEncodeAlike() {
        #expect(SearchEngine.encodedWords("a b&c") == "a%20b%26c")
        #expect(!SearchEngine.builtIn.contains(.fromExtension))
        #expect(SearchEngine.builtIn.count == SearchEngine.allCases.count - 1)
    }
}
