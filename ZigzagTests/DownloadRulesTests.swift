import Foundation
import Testing
@testable import Zigzag

/// Download and link rules: what they match, the values a token becomes, the cookies file a manager reads, and the
/// bodies a JSON-RPC or XML-RPC service is sent.
struct DownloadRuleTests {
    private func rule(_ match: DownloadRule.Match, _ pattern: String = "", applies: DownloadRule.Applies = .downloads,
                      enabled: Bool = true, caseSensitive: Bool = false) -> DownloadRule {
        var rule = DownloadRule(name: "Test", applies: applies, match: match, pattern: pattern,
                                isCaseSensitive: caseSensitive, action: DownloadRuleAction(kind: .openURL))
        rule.isEnabled = enabled
        return rule
    }

    private let video = URL(string: "https://www.youtube.com/watch?v=abc")!
    private let file = URL(string: "https://example.com/files/report.pdf")!

    // MARK: Matching

    @Test func eachMatchKind() {
        #expect(rule(.startsWith, "https://www.youtube").matches(video))
        #expect(!rule(.startsWith, "youtube").matches(video))
        #expect(rule(.contains, "youtube.com/watch").matches(video))
        #expect(rule(.endsWith, "watch?v=abc").matches(video))
        #expect(!rule(.endsWith, "watch?v=ab").matches(video))
        #expect(rule(.regex, #"youtube\.com/watch\?v=\w+"#).matches(video))
        #expect(rule(.any).matches(video))
        #expect(rule(.any).matches(file))
    }

    @Test func caseFollowsTheRule() {
        #expect(rule(.contains, "YOUTUBE").matches(video))
        #expect(!rule(.contains, "YOUTUBE", caseSensitive: true).matches(video))
        #expect(rule(.contains, "YOUTUBE", caseSensitive: true).matches(URL(string: "https://YOUTUBE.com/")!))
    }

    @Test func aPatternIsAlwaysApartFromTheAddress() {
        // A bare host in the pattern never matches by magic: the whole address is what's compared.
        #expect(!rule(.startsWith, "youtube").matches(video))
        #expect(!rule(.contains, "").matches(video))
        #expect(rule(.any).matches(video))
    }

    @Test func aBrokenRegexNeverMatches() {
        #expect(!rule(.regex, "([").matches(video))
        #expect(!rule(.regex, "([").isValidPattern)
        #expect(rule(.regex, "youtube").isValidPattern)
    }

    @Test func disabledRulesAreSkipped() {
        #expect(!rule(.any, enabled: false).matches(video))
    }

    // MARK: Order and what a rule catches

    @Test func firstMatchWinsTopToBottom() {
        let specific = rule(.contains, "youtube.com/watch", applies: .linksAndDownloads)
        let catchAll = rule(.any, applies: .linksAndDownloads)
        #expect(DownloadRulesStore.firstMatch(in: [specific, catchAll], url: video, appliesToLinks: true)?.id == specific.id)
        // Reversed, the catch-all is first and takes it.
        #expect(DownloadRulesStore.firstMatch(in: [catchAll, specific], url: video, appliesToLinks: true)?.id == catchAll.id)
        #expect(DownloadRulesStore.firstMatch(in: [specific], url: file, appliesToLinks: true) == nil)
    }

    @Test func anewRuleCatchesDownloadsOnly() {
        let downloadOnly = rule(.any)
        #expect(DownloadRulesStore.firstMatch(in: [downloadOnly], url: video, appliesToLinks: false)?.id == downloadOnly.id)
        #expect(DownloadRulesStore.firstMatch(in: [downloadOnly], url: video, appliesToLinks: true) == nil)
        let linksToo = rule(.any, applies: .linksAndDownloads)
        #expect(DownloadRulesStore.firstMatch(in: [linksToo], url: video, appliesToLinks: true)?.id == linksToo.id)
    }

    // MARK: Tokens

    @Test func encodedLinkIsOneQueryValue() {
        let encoded = DownloadTokens.encoded(video)
        #expect(encoded.contains("%3F"))
        #expect(encoded.contains("%3D"))
        #expect(!encoded.contains("?"))
        #expect(!encoded.contains("&"))
        let withAmpersand = DownloadTokens.encoded(URL(string: "https://example.com/a?x=1&y=2")!)
        #expect(withAmpersand.contains("%26"))
        #expect(!withAmpersand.contains("&"))
    }

    @Test func filenamesAreSafe() {
        #expect(DownloadTokens.filename(for: file, suggested: "report.pdf") == "report.pdf")
        #expect(DownloadTokens.filename(for: file, suggested: "") == "report.pdf")
        #expect(DownloadTokens.filename(for: file, suggested: "../evil/name") == "_-evil-name")
        #expect(DownloadTokens.filename(for: file, suggested: "-rf") == "_-rf")
        #expect(DownloadTokens.filename(for: file, suggested: ".hidden") == "hidden")
        #expect(!DownloadTokens.filename(for: file, suggested: "a\u{0}b").contains("\u{0}"))
        #expect(DownloadTokens.filename(for: URL(string: "https://example.com/")!, suggested: "") == "example.com")
    }

    @Test func aServiceOffThisMacGetsNoCookies() {
        #expect(DownloadHandoff.serviceIsOnThisMac("http://127.0.0.1:6800/jsonrpc"))
        #expect(DownloadHandoff.serviceIsOnThisMac("http://localhost:8080/RPC2"))
        #expect(DownloadHandoff.serviceIsOnThisMac("http://[::1]:6800/jsonrpc"))
        #expect(!DownloadHandoff.serviceIsOnThisMac("https://seedbox.example/rpc"))
        #expect(!DownloadHandoff.serviceIsOnThisMac("not a url"))
    }

    @Test func zigzagsOwnURLsAreNotHandoffs() {
        #expect(!DownloadHandoff.isHandoffable(URL(string: "zigzag-proceed://example.com")!))
        #expect(!DownloadHandoff.isHandoffable(URL(string: "zigzag://history")!))
        #expect(!DownloadHandoff.isHandoffable(URL(string: "file:///Users/me/x")!))
        #expect(!DownloadHandoff.isHandoffable(URL(string: "chrome-extension://abc/page")!))
        #expect(DownloadHandoff.isHandoffable(URL(string: "https://example.com/file")!))
        #expect(DownloadHandoff.isHandoffable(URL(string: "magnet:?xt=urn:btih:abc")!))
    }

    @Test func anUnknownRuleValueDoesNotThrowAwayTheList() throws {
        let json = """
        [
          {"name":"Known","match":"contains","pattern":"a","action":{"kind":"openURL","urlTemplate":"x://{link}"}},
          {"name":"Future","match":"fileType","pattern":"pdf","action":{"kind":"saveToFolder","folderPath":"/tmp"}},
          {"name":"Broken","applies":7,"match":{},"action":{"kind":"nonsense"}}
        ]
        """
        let rules = try JSONDecoder().decode([DownloadRule].self, from: Data(json.utf8))
        #expect(rules.count == 3)
        #expect(rules[0].match == .contains)
        #expect(rules[1].match == .contains)
        #expect(rules[1].action.kind == .openURL)
        #expect(rules[2].applies == .downloads)
        #expect(rules[2].action.kind == .openURL)
    }

    @Test func aResponseNameKeepsItsCaseAndItsPieces() {
        #expect(Tab.filename(from: #"attachment; filename="Report.PDF""#) == "Report.PDF")
        #expect(Tab.filename(from: #"attachment; FILENAME="Report.PDF""#) == "Report.PDF")
        #expect(Tab.filename(from: "attachment; filename*=UTF-8''two%20words.pdf") == "two words.pdf")
        #expect(Tab.filename(from: #"attachment; filename="../../Library/x""#) == "../../Library/x")
        #expect(DownloadTokens.filename(for: file, suggested: Tab.filename(from: #"attachment; filename="../../Library/x""#)!) == "_-..-Library-x")
    }

    @Test func everyTokenIsFilledIn() {
        let values = HandoffValues(link: video, referrer: URL(string: "https://www.youtube.com/")!,
                                   filename: "video.mp4", mime: "video/mp4", space: "Work",
                                   cookieHeader: "a=1; b=2", cookieFile: "/tmp/cookies.txt")
        let expanded = DownloadTokens.expand("{link}|{encoded_link}|{referrer}|{filename}|{mime}|{space}|{cookie_header}|{cookies}",
                                             with: values)
        #expect(expanded.contains(video.absoluteString))
        #expect(expanded.contains("https://www.youtube.com/"))
        #expect(expanded.contains("video.mp4"))
        #expect(expanded.contains("video/mp4"))
        #expect(expanded.contains("Work"))
        #expect(expanded.contains("a=1; b=2"))
        #expect(expanded.contains("/tmp/cookies.txt"))
        #expect(!expanded.contains("{link}"))
    }

    /// The link's own parts, so a rule can send an address somewhere else: the host, the path and the query on their
    /// own, exactly as the address has them.
    @Test func theLinksOwnPartsAreTokensOfTheirOwn() {
        let values = HandoffValues(link: URL(string: "https://www.google.com/search/deep?a=1&b=two%20words")!)
        let expanded = DownloadTokens.expand("https://www.bing.com{path}?{query}", with: values)
        #expect(expanded == "https://www.bing.com/search/deep?a=1&b=two%20words")
        #expect(DownloadTokens.expand("{host}", with: values) == "www.google.com")
        #expect(DownloadTokens.expand("{path}", with: values) == "/search/deep")
        #expect(DownloadTokens.expand("{query}", with: values) == "a=1&b=two%20words")

        let bare = HandoffValues(link: URL(string: "https://example.com")!)
        #expect(DownloadTokens.expand("{host}|{path}|{query}", with: bare) == "example.com||")
        let spaced = HandoffValues(link: URL(string: "https://example.com/a%20b/c")!)
        #expect(DownloadTokens.expand("{path}", with: spaced) == "/a%20b/c")
    }

    @Test func aValueCannotNameAnotherToken() {
        let values = HandoffValues(link: file, filename: "{secret}.mp4")
        #expect(DownloadTokens.expand("{filename}|{secret}", with: values, secret: "tok") == "{secret}.mp4|tok")
        let linkish = HandoffValues(link: file, filename: "{link}")
        #expect(DownloadTokens.expand("{filename}", with: linkish) == "{link}")
    }

    @Test func jsonTokensAreQuotedForTheBody() {
        let values = HandoffValues(link: video, filename: "a \"quoted\" \\ name.mp4")
        let expanded = DownloadTokens.expand(#"{"name":"{filename}"}"#, with: values, json: true)
        let data = Data(expanded.utf8)
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        #expect(object?["name"] == "a \"quoted\" \\ name.mp4")
    }

    // MARK: Cookies

    @Test func aCookieAppliesToItsDomainPathSchemeAndExpiry() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let base = HandoffCookie(name: "a", value: "1", domain: ".example.com")
        #expect(base.applies(to: file, now: now))
        #expect(base.applies(to: URL(string: "https://news.example.com/")!, now: now))
        #expect(!base.applies(to: URL(string: "https://example.org/")!, now: now))
        let pathed = HandoffCookie(name: "b", value: "2", domain: "example.com", path: "/files")
        #expect(pathed.applies(to: file, now: now))
        #expect(!pathed.applies(to: URL(string: "https://example.com/other")!, now: now))
        let secure = HandoffCookie(name: "c", value: "3", domain: "example.com", isSecure: true)
        #expect(secure.applies(to: file, now: now))
        #expect(!secure.applies(to: URL(string: "http://example.com/")!, now: now))
        let old = HandoffCookie(name: "d", value: "4", domain: "example.com", expires: now.addingTimeInterval(-1))
        #expect(!old.applies(to: file, now: now))
        let session = HandoffCookie(name: "e", value: "5", domain: "example.com", expires: nil)
        #expect(session.applies(to: file, now: now))
    }

    @Test func headerAndNetscapeFile() {
        let cookies = [HandoffCookie(name: "sid", value: "abc", domain: ".example.com", isSecure: true, isHTTPOnly: true),
                       HandoffCookie(name: "theme", value: "dark", domain: "example.com", expires: Date(timeIntervalSince1970: 2_000_000))]
        let matching = HandoffCookies.matching(cookies, for: file, now: Date(timeIntervalSince1970: 1_000_000))
        #expect(HandoffCookies.header(matching) == "sid=abc; theme=dark")
        let text = HandoffCookies.netscape(matching)
        #expect(text.contains("# Netscape HTTP Cookie File"))
        #expect(text.contains("#HttpOnly_.example.com\tTRUE\t/\tTRUE\t0\tsid\tabc"))
        #expect(text.contains(".example.com\tFALSE\t/\tFALSE\t2000000\ttheme\tdark"))
        #expect(text.hasSuffix("\n"))
    }

    @Test func cookiesFileIsPrivate() throws {
        let file = try HandoffCookies.writeFile([HandoffCookie(name: "sid", value: "abc", domain: "example.com")])
        defer { HandoffCookies.removeFile(file) }
        #expect(FileManager.default.fileExists(atPath: file.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((try? String(contentsOf: file, encoding: .utf8))?.contains("sid\tabc") == true)
    }

    // MARK: Service bodies

    @Test func parametersAreFilledInSafely() {
        let values = HandoffValues(link: video, referrer: URL(string: "https://www.youtube.com/")!,
                                   filename: "a \"b\".mp4", space: "Work", cookieHeader: "sid=abc")
        let parameters = DownloadHandoff.parameters(#"[["{link}"], {"out":"{filename}","header":["Cookie: {cookie_header}","Referer: {referrer}"]}]"#,
                                                    values: values, secret: "")
        #expect(parameters?.count == 2)
        #expect((parameters?.first as? [String])?.first == video.absoluteString)
        let options = parameters?.last as? [String: Any]
        #expect(options?["out"] as? String == "a \"b\".mp4")
    }

    @Test func aria2GetsItsTokenFirst() {
        let parameters: [Any] = [["https://example.com/file"], ["out": "file"]]
        let withToken = DownloadHandoff.jsonParameters(parameters, method: "aria2.addUri", secret: "s3cret")
        #expect(withToken.first as? String == "token:s3cret")
        #expect(DownloadHandoff.jsonParameters(parameters, method: "aria2.addUri", secret: "").first as? [String] != nil)
        // Nothing token-like is added to a service that doesn't take one.
        #expect(DownloadHandoff.jsonParameters(parameters, method: "other.method", secret: "s3cret").first as? String == nil)
    }

    @Test func xmlRPCBodyEscapesItsValues() {
        let body = DownloadHandoff.xmlRPC(method: "load.start", parameters: ["", "https://example.com/a?x=1&y=2"])
        #expect(body.contains("<methodName>load.start</methodName>"))
        #expect(body.contains("&amp;"))
        #expect(!body.contains("x=1&y=2"))
        #expect(body.contains("<string></string>"))
    }

    // MARK: The file a rule is saved in

    @Test func aRuleSurvivesItsJSON() throws {
        var rule = DownloadRule(name: "aria2", applies: .linksAndDownloads, match: .any, action: DownloadRuleAction(kind: .jsonRPC))
        rule.action.rpcEndpoint = "http://127.0.0.1:6800/jsonrpc"
        rule.action.rpcMethod = "aria2.addUri"
        rule.action.rpcParameters = #"[["{link}"]]"#
        let data = try JSONEncoder().encode([rule])
        let decoded = try JSONDecoder().decode([DownloadRule].self, from: data)
        #expect(decoded == [rule])
    }

    @Test func anOlderFileGetsTheDefaultsItLacks() throws {
        let json = #"[{"name":"Old","action":{"kind":"openURL","urlTemplate":"mpv://{link}"}}]"#
        let decoded = try JSONDecoder().decode([DownloadRule].self, from: Data(json.utf8))
        #expect(decoded.first?.applies == .downloads)
        #expect(decoded.first?.match == .contains)
        #expect(decoded.first?.isEnabled == true)
        #expect(decoded.first?.runsInPrivateWindows == false)
        #expect(decoded.first?.action.kind == .openURL)
    }

    // MARK: The handoff question

    @Test func downloadServicesTakeDownloadsOnly() {
        for preset in [DownloadPreset.aria2, .motrix, .rTorrent, .ytdlp] {
            #expect(preset.rule.applies == .downloads)
        }
        // A player is for the links you click, and for files that turn out to be media.
        for preset in [DownloadPreset.mpv, .iina] {
            #expect(preset.rule.applies == .linksAndDownloads)
        }
    }

    @Test func aHandoffAnswerReadsBackAsItsGate() {
        #expect(DownloadHandoff.gate(stored: "handOff") == .handOff)
        #expect(DownloadHandoff.gate(stored: "browser") == .browser)
        #expect(DownloadHandoff.gate(stored: "deny") == .cancel)
        #expect(DownloadHandoff.gate(stored: nil) == .browser)
    }

    @Test func cookiesGoOnlyToThePagesOwnSiteOrAClick() {
        let page = "https://news.example"
        let own = DownloadHandoff.Request(url: URL(string: "https://news.example/file.zip")!, pageOrigin: page)
        let elsewhere = DownloadHandoff.Request(url: URL(string: "https://other.example/file.zip")!, pageOrigin: page)
        #expect(DownloadHandoff.maySendCookies(own))
        #expect(!DownloadHandoff.maySendCookies(elsewhere))
        // A link you clicked may carry the page's sign-in to where it points.
        var clicked = elsewhere
        clicked.wasClicked = true
        #expect(DownloadHandoff.maySendCookies(clicked))
        // With no page to name, there is nothing to send.
        #expect(!DownloadHandoff.maySendCookies(DownloadHandoff.Request(url: own.url)))
    }

    @Test func privateWindowsRunOnlyTheRulesLetIn() {
        var rule = rule(.any)
        #expect(DownloadRulesStore.firstMatch(in: [rule], url: file, appliesToLinks: false) != nil)
        #expect(DownloadRulesStore.firstMatch(in: [rule], url: file, appliesToLinks: false, isPrivate: true) == nil)
        rule.runsInPrivateWindows = true
        #expect(DownloadRulesStore.firstMatch(in: [rule], url: file, appliesToLinks: false, isPrivate: true) != nil)
    }

    @Test func aPageKeepsAHandoffAction() {
        var answers = PagePermissionAnswers()
        let kind = DownloadHandoff.handoffKind(DownloadRule(name: "aria2", applies: .downloads, match: .any,
                                                             action: DownloadRuleAction(kind: .jsonRPC)))
        answers.note("handOff", key: "https://news.example", kind: kind)
        #expect(answers.action(key: "https://news.example", kind: kind) == "handOff")
        #expect(!answers.isEmpty)
        answers.forget()
        #expect(answers.isEmpty)
    }
}
