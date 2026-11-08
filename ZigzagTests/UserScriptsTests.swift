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
}
