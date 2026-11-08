import Foundation
import Testing
@testable import Zigzag

/// How `chrome.userScripts` reads what an extension registers: Chrome's globs, and Chrome's checks.
@MainActor
struct UserScriptsTests {
    private func matches(_ glob: String, _ url: String) -> Bool {
        let regex = try? NSRegularExpression(pattern: BridgeUserScripts.globPattern(glob))
        return regex?.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
    }

    @Test func globsMatchTheWholeAddressAsChromeDoes() {
        #expect(matches("*://*.example.com/*", "https://www.example.com/page"))
        #expect(!matches("*://*.example.com/*", "https://example.org/page"))
        // `?` is one character, and everything else is itself, dots and all.
        #expect(matches("https://a.com/?.html", "https://a.com/x.html"))
        #expect(!matches("https://a.com/?.html", "https://a.com/xy.html"))
        #expect(!matches("https://a.com/*", "https://abcom/x"))
        #expect(matches("*greasyfork*", "https://greasyfork.org/scripts/1"))
    }

    @Test func codeIsLeftAsItIsWithoutGlobs() {
        #expect(BridgeUserScripts.fileText(code: "let a = 1;", includeGlobs: [], excludeGlobs: []) == "let a = 1;")
        let wrapped = BridgeUserScripts.fileText(code: "let a = 1;", includeGlobs: ["*a*"], excludeGlobs: [])
        #expect(wrapped.contains("let a = 1;") && wrapped.hasPrefix("if ("))
    }

    @Test func registeringChecksAsChromeDoes() {
        func error(_ scripts: [[String: Any]], existing: Set<String> = []) -> String? {
            do { try BridgeUserScripts.checkNew(scripts, existing: existing); return nil } catch { return (error as? BridgeError)?.message }
        }
        let good: [String: Any] = ["id": "a", "matches": ["<all_urls>"], "js": [["code": "1"]]]
        #expect(error([good]) == nil)
        #expect(error([good], existing: ["a"]) == "Duplicate script ID 'a'")
        #expect(error([good, good]) == "Duplicate script ID 'a'")
        #expect(error([["id": "_a", "matches": ["<all_urls>"], "js": [["code": "1"]]]]) == "Script's ID '_a' must not start with '_'")
        #expect(error([["id": "b", "matches": [String](), "js": [["code": "1"]]]]) == "Script with ID 'b' must specify at least one match.")
        #expect(error([["id": "c", "matches": ["<all_urls>"], "js": [["code": "1", "file": "x.js"]]]])?.contains("exactly one of 'code' or 'file'") == true)
    }

    @Test func withBothManagersOnAScriptAddressGoesToTampermonkey() {
        let vm = ExtensionProfile.violentmonkeyID, tm = ExtensionProfile.tampermonkeyID
        let confirm = URL(string: "webkit-extension://\(vm)/confirm/index.html#abc")!
        func leaves(_ tab: String, on: Bool = true, from id: String = ExtensionProfile.violentmonkeyID, url: URL? = nil) -> Bool {
            ExtensionProfile.leavesInstallToTampermonkey(id, loading: url ?? confirm, tabURL: URL(string: tab), tampermonkeyOn: on)
        }
        #expect(leaves("https://greasyfork.org/scripts/1/code/x.user.js"))
        #expect(leaves("webkit-extension://\(tm)/ask.html?aid=1"))
        // Only Violentmonkey: its page opens.
        #expect(!leaves("https://greasyfork.org/scripts/1/code/x.user.js", on: false))
        // Its own pages and other tabs, as from its dashboard's "Install from URL".
        #expect(!leaves("webkit-extension://\(vm)/options/index.html"))
        #expect(!leaves("https://example.com/"))
        // Anything else it opens, and any other extension.
        #expect(!leaves("https://a.test/x.user.js", url: URL(string: "webkit-extension://\(vm)/options/index.html")!))
        #expect(!leaves("https://a.test/x.user.js", from: tm, url: URL(string: "webkit-extension://\(tm)/ask.html")!))
    }
}
