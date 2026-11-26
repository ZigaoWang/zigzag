import Foundation
import WebKit
import Testing
@testable import Zigzag

/// Download and link rules: matching, token values, the cookies file, and JSON-RPC / XML-RPC bodies.
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
        // A bare host doesn't match; the whole URL is compared.
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
        // Reversed, the catch-all matches first.
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
        // A bidi override is a format character, so it's stripped.
        #expect(DownloadTokens.filename(for: file, suggested: "invoice\u{202E}fdp.exe") == "invoicefdp.exe")
        #expect(DownloadTokens.filename(for: URL(string: "https://example.com/")!, suggested: "") == "example.com")
    }

    /// A script name alone resolves to Zigzag's Scripts folder in Application Support; a path is used as given.
    @Test func aRuleNamesAScriptInItsOneFolder() {
        let folder = Paths.scripts.standardizedFileURL
        #expect(folder == Paths.support.appendingPathComponent("Scripts", isDirectory: true).standardizedFileURL)

        // A bare name is in the folder; a path is used as is, `~` included.
        #expect(Paths.script(named: "yt-dlp.sh").standardizedFileURL == folder.appendingPathComponent("yt-dlp.sh"))
        #expect(Paths.script(named: "/opt/tools/dl.sh").path == "/opt/tools/dl.sh")
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        #expect(Paths.script(named: "~/bin/dl.sh").standardizedFileURL == home.appendingPathComponent("bin/dl.sh"))

        // Scripts picked from the folder are stored by name; others keep their path.
        #expect(Paths.scriptName(for: folder.appendingPathComponent("yt-dlp.sh")) == "yt-dlp.sh")
        #expect(Paths.scriptName(for: URL(fileURLWithPath: "/opt/tools/dl.sh")) == "/opt/tools/dl.sh")
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
        #expect(!DownloadHandoff.isHandoffable(URL(string: "zigzag-webapp://notes")!))
        #expect(!DownloadHandoff.isHandoffable(URL(string: "file:///Users/me/x")!))
        #expect(!DownloadHandoff.isHandoffable(URL(string: "chrome-extension://abc/page")!))
        #expect(DownloadHandoff.isHandoffable(URL(string: "https://example.com/file")!))
        #expect(DownloadHandoff.isHandoffable(URL(string: "magnet:?xt=urn:btih:abc")!))
    }

    @Test func anUnknownRuleValueDoesNotThrowAwayTheList() throws {
        let json = """
        [
          {"name":"Known","match":"contains","pattern":"a","action":{"kind":"openURL","urlTemplate":"x://{link}"}},
          {"name":"Future","match":"futureMatch","pattern":"pdf","action":{"kind":"futureKind","folderPath":"/tmp"}},
          {"name":"Broken","applies":7,"match":{},"action":{"kind":"nonsense"}},
          {"name":"WrongMatch","match":7,"pattern":"","action":{"kind":"openURL","urlTemplate":"x://{link}"}},
          {"name":"WrongKind","match":"contains","pattern":"x","action":{"kind":7}},
          {"name":"NoAction","match":"contains","pattern":"x"},
          "not a rule"
        ]
        """
        let rules = try JSONDecoder().decode([DownloadRule].self, from: Data(json.utf8))
        #expect(rules.count == 7)
        #expect(rules[0].match == .contains)
        #expect(rules[1].match == .contains)
        #expect(rules[1].action.kind == .openURL)
        #expect(!rules[1].isEnabled)
        #expect(rules[2].applies == .downloads)
        #expect(rules[2].action.kind == .openURL)
        #expect(!rules[2].isEnabled)
        // A wrongly typed field disables the rule: `.contains` with no pattern would match everything.
        #expect(!rules[3].isEnabled)
        #expect(!rules[4].isEnabled)
        // A missing action would decode as an empty Open URL rule; a catch-all prompt is worse than no rule.
        #expect(!rules[5].isEnabled)
        #expect(!rules[6].isEnabled)
        #expect(rules[6].name.isEmpty)
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

    /// A script notice shows progress while running, then green on exit 0, else the script's last output.
    @Test func aScriptNoticeSaysHowItWent() {
        let running = ScriptNotice(script: "yt-dlp.sh", state: .running)
        #expect(running.title == "Running script: yt-dlp.sh")
        #expect(running.detail == nil)
        #expect(running.symbol == "terminal")
        #expect(running.tone == .plain)
        #expect(!running.isOver)

        let ran = ScriptNotice(script: "yt-dlp.sh", state: .ran)
        #expect(ran.title == "Ran script: yt-dlp.sh")
        #expect(ran.detail == nil)
        #expect(ran.symbol == "checkmark.circle.fill")
        #expect(ran.tone == .good)
        #expect(ran.isOver)

        let failed = ScriptNotice(script: "yt-dlp.sh", state: .failed("  ERROR: no such video\n"))
        #expect(failed.title == "Script failed: yt-dlp.sh")
        #expect(failed.detail == "ERROR: no such video")
        #expect(failed.symbol == "exclamationmark.triangle.fill")
        #expect(failed.tone == .bad)
        #expect(failed.isOver)

        // No output: no detail line.
        #expect(ScriptNotice(script: "yt-dlp.sh", state: .failed("   \n")).detail == nil)
    }

    /// Host, path and query tokens, exactly as in the URL.
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

    @Test func aQuestionIsOnlyAskedWhereItCanBeSeen() {
        #expect(DownloadHandoff.questionCanShow(tabIsInFront: true, windowIsVisible: true, windowIsKey: true))
        #expect(DownloadHandoff.questionCanShow(tabIsInFront: nil, windowIsVisible: true, windowIsKey: true))
        // A background tab, a hidden window, or Zigzag in the background holds the question.
        #expect(!DownloadHandoff.questionCanShow(tabIsInFront: false, windowIsVisible: true, windowIsKey: true))
        #expect(!DownloadHandoff.questionCanShow(tabIsInFront: true, windowIsVisible: false, windowIsKey: true))
        #expect(!DownloadHandoff.questionCanShow(tabIsInFront: true, windowIsVisible: true, windowIsKey: false))
        // A key popup with an unfocused opener waits for a window that can ask.
        #expect(!DownloadHandoff.questionCanShow(tabIsInFront: true, windowIsVisible: true, windowIsKey: false))
        #expect(!DownloadHandoff.questionCanShow(tabIsInFront: nil, windowIsVisible: true, windowIsKey: false))
    }

    @Test func aValueCannotNameAnotherToken() {
        let values = HandoffValues(link: file, filename: "{secret}.mp4")
        #expect(DownloadTokens.expand("{filename}|{secret}", with: values, secret: "tok") == "{secret}.mp4|tok")
        let linkish = HandoffValues(link: file, filename: "{link}")
        #expect(DownloadTokens.expand("{filename}", with: linkish) == "{link}")
    }

    @Test func aQuoteInANameCannotBreakTheBody() {
        // Parameters are parsed as JSON first and filled in after, so no token is ever text in a body and nothing has
        // to be escaped for one: a quote in a filename stays in the filename.
        let values = HandoffValues(link: video, filename: "a \"quoted\" \\ name.mp4")
        let filled = DownloadHandoff.parameters(#"["{filename}"]"#, values: values, secret: "")
        #expect(filled?.first as? String == "a \"quoted\" \\ name.mp4")
    }

    @Test func aFileTokenIsBytesInABody() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sample.torrent")
        try Data("d4:infod4:name6:samplee".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let values = HandoffValues(link: video, file: file)
        let filled = DownloadHandoff.parameters(#"["", "{file_raw}"]"#, values: values, secret: "")
        #expect(filled?.count == 2)
        // The value is the file's base64, not its path and not an empty string.
        let raw = try #require(filled?[1] as? FileRaw)
        #expect(raw.base64 == Data("d4:infod4:name6:samplee".utf8).base64EncodedString())
    }

    @Test func anxmlrpcBodyCarriesTheFileAsBase64() throws {
        // rTorrent reads the binary type; base64 sent as a string is a path it can't open.
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sample2.torrent")
        try Data("d4:info".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let body = DownloadHandoff.xmlRPC(method: "load.raw_start",
                                          parameters: ["", FileRaw(file)])
        #expect(body.contains("<base64>\(Data("d4:info".utf8).base64EncodedString())</base64>"))
        #expect(!body.contains("<string>d4:info</string>"))
    }

    @Test func theOlderFileTokensAreUnchanged() throws {
        // Compatibility: `{file}` is still the path and `{file_url}` still the file URL, so rules written against a
        // launch build keep meaning what they meant.
        let file = URL(fileURLWithPath: "/tmp/a.torrent")
        let values = HandoffValues(link: video, file: file)
        #expect(DownloadTokens.expand("{file}", with: values) == "/tmp/a.torrent")
        #expect(DownloadTokens.expand("{file_url}", with: values) == "file:///tmp/a.torrent")
    }

    @Test func aRuleThatSendsBytesSaysSoWhenThereAreNone() {
        // A link handoff has no file: better a plain reason than an empty <base64> the service refuses obscurely.
        let values = HandoffValues(link: video)
        let raw = FileRaw(values.file)
        #expect(raw.problem == .noFile)
        #expect(raw.base64 == nil)
    }

    @Test func aFileTooLargeToSendIsRefusedRatherThanRead() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("big.bin")
        try Data(count: FileRaw.limit + 1).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let raw = FileRaw(file)
        #expect(raw.problem == .tooLarge(FileRaw.limit + 1))
        #expect(raw.base64 == nil)
    }

    @Test func aJsonBodyCarriesTheBytesAsBase64Text() throws {
        // JSON has no binary type, so the same token goes as base64 text: aria2.addTorrent takes it that way.
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sample3.torrent")
        try Data("d4:info".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let values = HandoffValues(link: video, file: file)
        let filled = DownloadHandoff.parameters(#"["torrent", "{file_raw}"]"#, values: values, secret: "")
        let ready = DownloadHandoff.jsonReady(filled ?? []) as? [Any]
        #expect(ready?.count == 2)
        #expect(ready?[1] as? String == Data("d4:info".utf8).base64EncodedString())
    }

    @Test func anEndpointHandsItsCredentialsOver() {
        // `user:pass@` in an address becomes the two fields, so the rules file keeps an address and nothing else.
        let split = HandoffSecrets.endpointWithoutCredentials("https://me:p%40ss@daemon.example:8080/RPC2")
        #expect(split?.endpoint == "https://daemon.example:8080/RPC2")
        #expect(split?.user == "me")
        #expect(split?.password == "p@ss")
    }

    @Test func anEndpointWithoutCredentialsIsLeftAlone() {
        #expect(HandoffSecrets.endpointWithoutCredentials("http://127.0.0.1:8080/RPC2") == nil)
        #expect(HandoffSecrets.endpointWithoutCredentials("") == nil)
    }

    // MARK: Presets

    @Test func theRTorrentPresetSendsTheMetafileItself() {
        // A tracker passkey is a cookie: rTorrent fetching the address itself would be refused, so the file is sent.
        let rule = DownloadPreset.rTorrent.rule
        #expect(rule.match == .fileType)
        #expect(rule.pattern == "torrent")
        #expect(rule.handoffType == .file)
        #expect(rule.action.rpcMethod == "load.raw_start")
        #expect(rule.action.rpcParameters.contains("{file_raw}"))
        #expect(rule.applies == .downloads)
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
        // A host-only cookie stays on its host; a leading dot means the domain.
        let hostOnly = HandoffCookie(name: "h", value: "6", domain: "example.com")
        #expect(hostOnly.applies(to: file, now: now))
        #expect(!hostOnly.applies(to: URL(string: "https://sub.example.com/")!, now: now))
        let forDomain = HandoffCookie(name: "d", value: "7", domain: ".example.com")
        #expect(forDomain.applies(to: URL(string: "https://sub.example.com/")!, now: now))
    }

    @Test func headerAndNetscapeFile() {
        let cookies = [HandoffCookie(name: "sid", value: "abc", domain: ".example.com", isSecure: true, isHTTPOnly: true),
                       HandoffCookie(name: "theme", value: "dark", domain: "example.com", expires: Date(timeIntervalSince1970: 2_000_000))]
        let matching = HandoffCookies.matching(cookies, for: file, now: Date(timeIntervalSince1970: 1_000_000))
        #expect(HandoffCookies.header(matching) == "sid=abc; theme=dark")
        let text = HandoffCookies.netscape(matching)
        #expect(text.contains("# Netscape HTTP Cookie File"))
        #expect(text.contains("#HttpOnly_.example.com\tTRUE\t/\tTRUE\t0\tsid\tabc"))
        #expect(text.contains("example.com\tFALSE\t/\tFALSE\t2000000\ttheme\tdark"))
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
        // No secret is added for a service that doesn't take one.
        #expect(DownloadHandoff.jsonParameters(parameters, method: "other.method", secret: "s3cret").first as? String == nil)
    }

    /// Each Open URL token is one query value, so `&` or `=` can't add parameters; `{path}` and `{query}` aren't double-encoded.
    @Test func openURLTokensAreOneQueryValue() throws {
        let values = HandoffValues(link: URL(string: "https://site.example/a?b=c&d=e")!,
                                   referrer: URL(string: "https://ref.example/x y")!,
                                   filename: "x&url=https://evil.example/", mime: "video/mp4", space: "Work")
        let text = DownloadTokens.expand("myapp://add?url={encoded_link}&name={filename}&ref={referrer}&mime={mime}&space={space}",
                                         with: values, query: true)
        let items = try #require(URLComponents(string: text)?.queryItems)
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(byName["url"] == values.link.absoluteString)
        #expect(byName["name"] == values.filename)
        #expect(byName["ref"] == values.referrer?.absoluteString)
        #expect(byName["mime"] == "video/mp4")
        // Exactly five; the filename added none.
        #expect(items.count == 5)

        // `{path}` and `{query}` are kept as is.
        #expect(DownloadTokens.expand("https://www.bing.com{path}?{query}", with: values, query: true)
                == "https://www.bing.com/a?b=c&d=e")
    }

    /// A MIME type starting with `-` gets a `_` prefix so it can't be read as an option.
    @Test func aMimeTypeCannotBeReadAsAnOption() {
        let values = HandoffValues(link: URL(string: "https://site.example/f")!, mime: "-o/tmp/x")
        #expect(DownloadTokens.expand("{mime}", with: values) == "_-o/tmp/x")
    }

    /// Cookies only go to local targets: scripts, apps, local RPC, custom schemes or local http(s). Remote addresses get none.
    @Test func cookiesOnlyGoToATargetOnThisMac() {
        let values = HandoffValues(link: URL(string: "https://site.example/f")!)
        func action(_ kind: DownloadRuleAction.Kind, _ field: (inout DownloadRuleAction) -> Void) -> DownloadRuleAction {
            var action = DownloadRuleAction(kind: kind)
            field(&action)
            return action
        }
        #expect(DownloadHandoff.targetIsOnThisMac(action(.runScript) { $0.scriptPath = "/tmp/x.sh" }, values: values))
        #expect(DownloadHandoff.targetIsOnThisMac(action(.openURL) { $0.urlTemplate = "myapp://add?u={encoded_link}" }, values: values))
        #expect(DownloadHandoff.targetIsOnThisMac(action(.openURL) { $0.urlTemplate = "http://127.0.0.1:8080/add?u={encoded_link}" }, values: values))
        #expect(!DownloadHandoff.targetIsOnThisMac(action(.openURL) { $0.urlTemplate = "https://evil.example/?c={cookie_header}" }, values: values))
        #expect(!DownloadHandoff.targetIsOnThisMac(action(.jsonRPC) { $0.rpcEndpoint = "https://seedbox.example/rpc" }, values: values))
        #expect(DownloadHandoff.targetIsOnThisMac(action(.jsonRPC) { $0.rpcEndpoint = "http://127.0.0.1:6800/jsonrpc" }, values: values))
    }

    /// XML-RPC booleans stay booleans; JSONSerialization returns both as NSNumber.
    @Test func xmlRPCBodySendsBooleansAsBooleans() {
        let body = DownloadHandoff.xmlRPC(method: "d.load", parameters: [true, 3, "x"])
        #expect(body.contains("<boolean>1</boolean>"))
        #expect(body.contains("<int>3</int>"))
        #expect(!body.contains("<int>1</int>"))
        #expect(body.contains("<boolean>0</boolean>") == false)
        let no = DownloadHandoff.xmlRPC(method: "d.load", parameters: [false])
        #expect(no.contains("<boolean>0</boolean>"))
    }

    @Test func xmlRPCBodyEscapesItsValues() {
        let body = DownloadHandoff.xmlRPC(method: "load.start", parameters: ["", "https://example.com/a?x=1&y=2"])
        #expect(body.contains("<methodName>load.start</methodName>"))
        #expect(body.contains("&amp;"))
        #expect(!body.contains("x=1&y=2"))
        #expect(body.contains("<string></string>"))
    }

    // MARK: Per-extension destinations

    /// A per-extension destination as the panel creates it: a file-type rule plus a save action.
    private func destination(_ extensions: String, _ kind: DownloadRuleAction.Kind = .saveToFolder,
                             folder: String = "/Users/me/Documents", enabled: Bool = true) -> DownloadRule {
        var action = DownloadRuleAction(kind: kind)
        action.folderPath = kind == .saveToFolder ? folder : ""
        var rule = DownloadRule(name: "", applies: .downloads, match: .fileType, pattern: extensions, action: action)
        rule.isEnabled = enabled
        return rule
    }

    /// File-type rules match the filename, never the URL.
    @Test func aFileTypeMatchesByNameAndNeverByAddress() {
        let type = rule(.fileType, "pdf, epub")
        #expect(type.matches(filename: "report.pdf"))
        #expect(type.matches(filename: "report.PDF"))
        #expect(type.matches(filename: "book.EPUB"))
        #expect(!type.matches(filename: "report.txt"))
        // A URL alone has no filename, so a type rule matches nothing.
        #expect(!type.matches(file))
        #expect(!type.matches(file, filename: ""))
    }

    @Test func aFileTypeTakesADotAndTwoParts() {
        #expect(rule(.fileType, ".pdf").matches(filename: "a.pdf"))
        #expect(rule(.fileType, "pdf").matches(filename: "a.pdf"))
        #expect(rule(.fileType, "pdf,epub").matches(filename: "b.epub"))
        #expect(rule(.fileType, "tar.gz").matches(filename: "backup.tar.gz"))
        #expect(!rule(.fileType, "gz").matches(filename: "backup.tar.xz"))
        // An extension needs a dot.
        #expect(!rule(.fileType, "pdf").matches(filename: "pdf"))
        #expect(!rule(.fileType, "").matches(filename: "a.pdf"))
        #expect(!rule(.fileType, "pdf", enabled: false).matches(filename: "a.pdf"))
    }

    @Test func aFileTypeFollowsTheCaseSwitch() {
        #expect(rule(.fileType, "PDF", caseSensitive: true).matches(filename: "a.PDF"))
        #expect(!rule(.fileType, "PDF", caseSensitive: true).matches(filename: "a.pdf"))
        #expect(rule(.fileType, "PDF", caseSensitive: false).matches(filename: "a.pdf"))
    }

    /// Downloads match by filename; links have none, so type rules never match links.
    @Test func aDownloadIsCaughtByItsTypeAndALinkIsNot() {
        let type = rule(.fileType, "pdf")
        #expect(DownloadRulesStore.firstMatch(in: [type], url: file, filename: "report.pdf", appliesToLinks: false)?.id == type.id)
        #expect(DownloadRulesStore.firstMatch(in: [type], url: file, filename: "", appliesToLinks: false) == nil)
        #expect(DownloadRulesStore.firstMatch(in: [type], url: file, filename: "report.pdf", appliesToLinks: true) == nil)
    }

    /// A handoff can be chosen by the download's own type, whatever the address says: a tracker's download.php
    /// carries no file name, so an address pattern can't catch it. Links have no name, so they never match one.
    @Test func aFileTypeHandoffMatchesTheDownloadsNameAndNeverALink() {
        var send = DownloadRuleAction(kind: .jsonRPC)
        send.rpcEndpoint = "http://127.0.0.1:5000/RPC2"
        send.rpcMethod = "load.start"
        let type = DownloadRule(name: "Torrents", applies: .downloads, match: .fileType, pattern: "torrent", action: send)
        let tracker = URL(string: "https://tracker.example.com/download.php?id=42")!

        #expect(type.matches(tracker, filename: "Some.Movie.torrent"))
        #expect(!type.matches(tracker))
        #expect(!type.matches(tracker, filename: ""))
        #expect(DownloadRulesStore.firstHandoffMatch(in: [type], url: tracker, filename: "Some.Movie.torrent",
                                                     appliesToLinks: false)?.id == type.id)
        #expect(DownloadRulesStore.firstHandoffMatch(in: [type], url: tracker, filename: "Some.Movie.torrent",
                                                     appliesToLinks: true) == nil)
    }

    /// A file-type handoff reads as the files it catches, not as a destination with a folder.
    @Test func aFileTypeHandoffReadsAsItsFiles() {
        var send = DownloadRuleAction(kind: .jsonRPC)
        send.rpcEndpoint = "http://127.0.0.1:5000/RPC2"
        send.rpcMethod = "load.start"
        let type = DownloadRule(name: "Torrents", applies: .downloads, match: .fileType, pattern: "torrent, pdf", action: send)
        #expect(type.summarySentence == "Files of type torrent, pdf go to 127.0.0.1 (load.start)")

        var open = DownloadRuleAction(kind: .openApp)
        open.appPath = "/Applications/rTorrent.app"
        let show = DownloadRule(name: "Torrents", match: .fileType, pattern: "torrent", action: open)
        #expect(show.summarySentence == "Files of type torrent open in rTorrent")
    }

    /// The first matching destination wins, in handoff order; a handoff rule for the same file isn't a destination.
    @Test func aDestinationIsTheFirstThatMatches() {
        let pdf = destination("pdf", folder: "/Users/me/Documents")
        let books = destination("pdf, epub", .openFile)
        #expect(DownloadRulesStore.destination(in: [pdf, books], url: file, filename: "a.pdf")?.destination == .folder("/Users/me/Documents"))
        #expect(DownloadRulesStore.destination(in: [books, pdf], url: file, filename: "a.pdf")?.destination == .open)
        #expect(DownloadRulesStore.destination(in: [rule(.fileType, "pdf")], url: file, filename: "a.pdf") == nil)
        #expect(DownloadRulesStore.destination(in: [], url: file, filename: "a.pdf") == nil)
        #expect(DownloadRulesStore.destination(in: [destination("pdf")], url: file, filename: "a.epub") == nil)
        #expect(DownloadRulesStore.destination(in: [destination("pdf", enabled: false)], url: file, filename: "a.pdf") == nil)
    }

    // MARK: Where a destination puts the file

    /// A folder destination saves there under the file's name; empty or missing folders decide nothing, and Open saves to the default place.
    @Test func aDestinationIsReadAsAPlaceToSave() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zz-dest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let there = DownloadManager.place(for: .folder(folder.path), folder: folder.path, filename: "report.pdf")
        #expect(there?.destination == folder.appendingPathComponent("report.pdf"))
        #expect(there?.openWhenFinished == false, "a folder destination saves, it never opens")

        // The filename is sanitized.
        #expect(DownloadManager.place(for: .folder(folder.path), folder: folder.path, filename: "a/b:c.pdf")?.destination
                == folder.appendingPathComponent("a-b-c.pdf"))

        // Existing files aren't overwritten.
        let taken = folder.appendingPathComponent("report.pdf")
        try Data("one".utf8).write(to: taken)
        let second = DownloadManager.place(for: .folder(folder.path), folder: folder.path, filename: "report.pdf")
        #expect(second?.destination == folder.appendingPathComponent("report 2.pdf"))

        // Nor files still downloading.
        let busy = DownloadManager.place(for: .folder(folder.path), folder: folder.path, filename: "report.pdf",
                                         avoiding: [folder.appendingPathComponent("report 2.pdf").path])
        #expect(busy?.destination == folder.appendingPathComponent("report 3.pdf"))

        // No folder, a missing one, or a file instead of a folder: nothing decided.
        #expect(DownloadManager.place(for: .folder(""), folder: "", filename: "a.pdf") == nil)
        #expect(DownloadManager.place(for: .folder("/no/such/folder"), folder: "/no/such/folder", filename: "a.pdf") == nil)
        let aFile = folder.appendingPathComponent("notafolder")
        try Data("x".utf8).write(to: aFile)
        #expect(DownloadManager.place(for: .folder(aFile.path), folder: aFile.path, filename: "a.pdf") == nil)

        // Open saves to the default place and opens when finished.
        let shown = DownloadManager.place(for: .open, folder: "ignored", filename: "report.pdf")
        #expect(shown?.openWhenFinished == true)
        #expect(shown?.destination.lastPathComponent == "report.pdf")
        // Private windows keep the file but don't open it in another app unless the rule is allowed there.
        #expect(DownloadManager.place(for: .open, folder: "", filename: "report.pdf", canOpen: false)?.openWhenFinished == false)
    }
    /// Destinations need a folder to save into; Open needs nothing.
    @Test func aDestinationSaysWhatItIsAndNeedsItsFolder() {
        #expect(DownloadRuleAction.Kind.saveToFolder.isDestination)
        #expect(DownloadRuleAction.Kind.openFile.isDestination)
        #expect(!DownloadRuleAction.Kind.openURL.isDestination)
        #expect(!DownloadRuleAction.Kind.runScript.isDestination)

        var folder = DownloadRuleAction(kind: .saveToFolder)
        #expect(!folder.isComplete)
        folder.folderPath = "/Users/me/Documents"
        #expect(folder.isComplete)
        #expect(DownloadRuleAction(kind: .openFile).isComplete)
    }

    @Test func aDestinationReadsAsASentence() {
        #expect(destination("pdf, epub", folder: "/Users/me/Documents").destinationSentence
                == "Files of type pdf, epub are saved to Documents")
        #expect(destination("pdf", .openFile).destinationSentence == "Files of type pdf open in your Mac’s app")
    }

    /// File-type Open never runs apps, scripts, installers or archives; the lookup skips it and a later Save rule decides.
    @Test func anOpenNeverTakesAnAppScriptOrArchive() {
        #expect(DownloadOpening.isRefused("dmg"))
        #expect(DownloadOpening.isRefused("APP"))
        #expect(DownloadOpening.isRefused("mpkg"))
        #expect(DownloadOpening.isRefused("iso"))
        #expect(DownloadOpening.isRefused("xip"))
        #expect(DownloadOpening.isRefused("tar.gz"))
        #expect(DownloadOpening.isRefused("pdf,dmg"))
        #expect(DownloadOpening.isRefused(""))
        #expect(!DownloadOpening.isRefused("pdf"))
        #expect(DownloadOpening.isRefused(pattern: "pdf, tar.gz"))
        #expect(DownloadOpening.isRefused("report.pdf,dmg"))
        #expect(DownloadOpening.isRefused(pattern: "pdf, dmg"))
        #expect(!DownloadOpening.isRefused("pdf"))

        // Other types that run, load, or navigate when opened: location files, web pages, plug-ins, workflows, macro documents.
        for type in ["fileloc", "inetloc", "webloc", "url", "html", "svg", "webarchive", "js", "wflow", "shortcut",
                     "scptd", "plugin", "dylib", "qtz", "jnlp", "class", "ipa", "docm", "xlsm", "term", "tool"] {
            #expect(DownloadOpening.isRefused(type), "\(type) must not open")
        }
        #expect(DownloadOpening.isRefused(pattern: "epub, fileloc"))
        // Unlisted types are refused when UTType says script or archive.
        for type in ["sparseimage", "cpgz", "xar", "phtml", "pyc"] {
            #expect(!DownloadOpening.refused.contains(type))
            #expect(DownloadOpening.isRefused(type), "\(type) must not open")
        }
        // Ordinary documents and media are allowed.
        for type in ["pdf", "epub", "txt", "rtf", "md", "csv", "json", "png", "jpg", "heic", "mp3", "mp4", "mov",
                     "docx", "xlsx", "pptx", "pages", "key", "numbers", "ics", "vcf"] {
            #expect(!DownloadOpening.isRefused(type), "\(type) should be able to open")
        }

        let url = URL(string: "https://example.com/tool.dmg")!
        var open = destination("dmg", .openFile)
        open.name = "Open"
        #expect(DownloadRulesStore.destination(in: [open], url: url, filename: "tool.dmg") == nil)

        var save = destination("dmg", .saveToFolder, folder: "/tmp")
        save.name = "Save"
        let found = DownloadRulesStore.destination(in: [open, save], url: url, filename: "tool.dmg")
        #expect(found?.rule.name == "Save")
        #expect(found?.destination == .folder("/tmp"))

        // Same for installers and compound archives.
        let installer = URL(string: "https://example.com/tool.mpkg")!
        let installerOpen = destination("mpkg", .openFile)
        #expect(DownloadRulesStore.destination(in: [installerOpen], url: installer, filename: "tool.mpkg") == nil)
        let archive = URL(string: "https://example.com/bundle.tar.gz")!
        let archiveOpen = destination("tar.gz", .openFile)
        #expect(DownloadRulesStore.destination(in: [archiveOpen], url: archive, filename: "bundle.tar.gz") == nil)
    }

    /// One list order: a file type before a catch-all wins, and a refused Open doesn't match, so a later handoff can take it.
    @Test func aTypeRuleBeforeACatchAllHandoffWins() {
        var type = destination("pdf", .saveToFolder, folder: "/tmp")
        type.name = "Type"
        var catchAll = rule(.any)
        catchAll.name = "Catch-all"
        let url = URL(string: "https://example.com/file.pdf")!
        #expect(DownloadRulesStore.firstHandoffMatch(in: [type, catchAll], url: url, filename: "file.pdf",
                                                     appliesToLinks: false) == nil)
        #expect(DownloadRulesStore.firstHandoffMatch(in: [catchAll, type], url: url, filename: "file.pdf",
                                                     appliesToLinks: false)?.name == "Catch-all")

        var refused = destination("dmg", .openFile)
        refused.name = "Open DMG"
        #expect(DownloadRulesStore.firstHandoffMatch(in: [refused, catchAll],
                                                     url: URL(string: "https://example.com/x.dmg")!, filename: "x.dmg",
                                                     appliesToLinks: false)?.name == "Catch-all")

        // A Save destination applies in private windows even with the switch off; only Open and handoffs need it.
        var privateCatchAll = catchAll
        privateCatchAll.runsInPrivateWindows = true
        #expect(DownloadRulesStore.firstHandoffMatch(in: [type, privateCatchAll], url: url, filename: "file.pdf",
                                                     appliesToLinks: false, isPrivate: true) == nil)

        // A hand-edited link destination isn't a download destination and doesn't block a handoff.
        var linkDestination = destination("pdf", .saveToFolder, folder: "/tmp")
        linkDestination.applies = .linksAndDownloads
        linkDestination.name = "Link destination"
        #expect(DownloadRulesStore.firstHandoffMatch(in: [linkDestination, catchAll], url: url, filename: "file.pdf",
                                                     appliesToLinks: false)?.name == "Catch-all")
    }

    /// Open saves apps, scripts, installers, archives and untyped files instead; a PDF may open.
    @Test func aNewFileTypeGoesBeforeTheHandoffRules() {
        var aria2 = rule(.any)
        aria2.name = "aria2"
        var pdf = destination("pdf", .openFile)
        pdf.name = "PDF"
        var epub = destination("epub", .saveToFolder, folder: "/tmp")
        epub.name = "EPUB"
        #expect(DownloadRulesStore.placeForNewFileType(in: []) == 0)
        #expect(DownloadRulesStore.placeForNewFileType(in: [aria2]) == 0)
        #expect(DownloadRulesStore.placeForNewFileType(in: [pdf, aria2]) == 1)
        #expect(DownloadRulesStore.placeForNewFileType(in: [pdf, epub]) == 2)

        // A type added behind a downloader preset's catch-all still handles its files.
        var rules = [aria2]
        rules.insert(pdf, at: DownloadRulesStore.placeForNewFileType(in: rules))
        #expect(DownloadRulesStore.firstHandoffMatch(in: rules, url: URL(string: "https://example.com/a.pdf")!,
                                                     filename: "a.pdf", appliesToLinks: false) == nil)
        #expect(DownloadRulesStore.firstHandoffMatch(in: rules, url: URL(string: "https://example.com/a.zip")!,
                                                     filename: "a.zip", appliesToLinks: false)?.name == "aria2")
    }

    @MainActor @Test func placingAnOpenNeverOpensARefusedType() {
        let unique = UUID().uuidString
        #expect(DownloadManager.place(for: .open, folder: "", filename: "zz-\(unique).pdf")?.openWhenFinished == true)
        #expect(DownloadManager.place(for: .open, folder: "", filename: "zz-\(unique).dmg")?.openWhenFinished == false)
        #expect(DownloadManager.place(for: .open, folder: "", filename: "zz-\(unique).mpkg")?.openWhenFinished == false)
        #expect(DownloadManager.place(for: .open, folder: "", filename: "zz-\(unique)")?.openWhenFinished == false)
    }

    /// File types need extensions but no name; only save destinations need a folder.
    @Test func aFileTypeNeedsItsExtensionsAndOnlyAFolderToSaveInto() {
        var save = destination("", .saveToFolder, folder: "")
        #expect(save.pattern.isEmpty)
        #expect(!save.action.isComplete)
        save.pattern = "pdf, epub"
        #expect(!save.action.isComplete)
        save.action.folderPath = "/Users/me/Downloads/PDFs"
        #expect(save.action.isComplete)

        // Opening needs only the type.
        var show = destination("pdf", .openFile)
        show.name = ""
        #expect(show.action.isComplete)
        #expect(show.name.isEmpty)
    }

    /// The editor offers every match kind to a handoff, file type included; a destination only file type.
    @Test func theSheetOffersFileTypeToHandoffsToo() {
        #expect(DownloadRuleSheet.matchChoices(isDestination: true) == [.fileType])
        #expect(DownloadRuleSheet.matchChoices(isDestination: false) == DownloadRule.Match.allCases)
        #expect(DownloadRuleSheet.matchChoices(isDestination: false).contains(.fileType))
        // The pattern field asks for extensions or for an address, following the match.
        #expect(DownloadRuleSheet.patternPlaceholder(for: .fileType) == "pdf, epub")
        #expect(DownloadRuleSheet.patternPlaceholder(for: .contains) == "example.com/files/")
    }

    /// A handoff by file type needs its extensions and a name, as any handoff does.
    @Test func aFileTypeHandoffNeedsItsExtensionsAndItsName() {
        var mine = rule(.fileType, "", applies: .downloads)
        mine.name = "Torrents"
        mine.action.urlTemplate = "https://example.com/{filename}"
        #expect(DownloadRuleSheet.heldUp(mine, all: true).map(\.field) == [.pattern])
        mine.pattern = "torrent"
        #expect(DownloadRuleSheet.heldUp(mine, all: true).isEmpty)
        mine.name = ""
        #expect(DownloadRuleSheet.heldUp(mine, all: true).map(\.field) == [.name])
    }

    @Test func aDestinationSurvivesItsJSON() throws {
        var rule = destination("pdf")
        rule.action.folderPath = "/Users/me/Downloads/PDFs"
        let data = try JSONEncoder().encode([rule])
        let decoded = try JSONDecoder().decode([DownloadRule].self, from: data)
        #expect(decoded == [rule])
        #expect(decoded.first?.action.kind == .saveToFolder)
        #expect(decoded.first?.action.destination == .folder("/Users/me/Downloads/PDFs"))
    }

    // MARK: Handing off the file

    /// Off unless asked for; rules saved before the choice keep handing off their address.
    @Test func aFileHandoffIsOptInAndOlderRulesKeepTheURL() throws {
        var rule = DownloadRule(name: "Torrents", applies: .downloads, match: .fileType, pattern: "torrent",
                                action: DownloadRuleAction(kind: .jsonRPC))
        #expect(rule.handoffType == .url)
        rule.handoffType = .file
        let data = try JSONEncoder().encode([rule])
        #expect(try JSONDecoder().decode([DownloadRule].self, from: data).first?.handoffType == .file)

        let older = #"[{"name":"Old","action":{"kind":"openURL","urlTemplate":"mpv://{link}"}}]"#
        let decoded = try JSONDecoder().decode([DownloadRule].self, from: Data(older.utf8))
        #expect(decoded.first?.handoffType == .url)
    }

    /// `{file}` is the saved path and `{file_url}` its file URL; both are empty when no file was handed off. `{link}`
    /// stays the source address.
    @Test func fileTokensAreTheSavedFileAndNothingWithoutOne() {
        let link = URL(string: "https://tracker.example/download.php?id=42")!
        let noFile = HandoffValues(link: link)
        #expect(DownloadTokens.expand("{file}|{file_url}|{link}", with: noFile) == "||\(link.absoluteString)")
        #expect(DownloadTokens.names.contains("{file}"))
        #expect(DownloadTokens.names.contains("{file_url}"))

        let saved = URL(fileURLWithPath: "/Users/me/Downloads/Some Movie.torrent")
        let file = HandoffValues(link: link, file: saved)
        #expect(file.filename == "Some Movie.torrent")
        #expect(DownloadTokens.expand("{file}", with: file) == saved.path)
        #expect(DownloadTokens.expand("{file_url}", with: file) == saved.absoluteString)
        #expect(DownloadTokens.expand("{link}", with: file) == link.absoluteString)
        // In an Open URL template each value is one query value, as `{link}` is.
        #expect(DownloadTokens.expand("{file}", with: file, query: true)
                == "/Users/me/Downloads/Some%20Movie.torrent")
    }

    /// The Settings row says the download is saved first, and that only downloads wait for it.
    @Test func aFileHandoffReadsAsSavedFirst() {
        var send = DownloadRuleAction(kind: .jsonRPC)
        send.rpcEndpoint = "http://127.0.0.1:5000/RPC2"
        send.rpcMethod = "load.start"
        var rule = DownloadRule(name: "Torrents", applies: .downloads, match: .endsWith, pattern: ".torrent", action: send)
        #expect(rule.summarySentence == "Files ending in .torrent go to 127.0.0.1 (load.start)")
        rule.handoffType = .file
        #expect(rule.summarySentence == "Downloads ending in .torrent are saved first, then go to 127.0.0.1 (load.start)")

        var open = DownloadRuleAction(kind: .openApp)
        open.appPath = "/Applications/rTorrent.app"
        var show = DownloadRule(name: "Torrents", applies: .downloads, match: .fileType, pattern: "torrent", action: open)
        show.handoffType = .file
        #expect(show.summarySentence == "Files of type torrent are saved first, then open in rTorrent")

        var script = DownloadRuleAction(kind: .runScript)
        script.scriptPath = "yt-dlp.sh"
        var links = DownloadRule(name: "Videos", applies: .linksAndDownloads, match: .any, action: script)
        links.handoffType = .file
        #expect(links.summarySentence == "Downloads are saved first, then passed to yt-dlp.sh; links hand off just their address")
        links.applies = .downloads
        #expect(links.summarySentence == "Downloads are saved first, then passed to yt-dlp.sh")
        links.applies = .linksAndDownloads
        links.action = open
        #expect(links.summarySentence == "Downloads are saved first, then open in rTorrent; links hand off just their address")
        links.action = send
        links.match = .endsWith
        links.pattern = ".torrent"
        #expect(links.summarySentence == "Downloads ending in .torrent are saved first, then go to 127.0.0.1 (load.start); links hand off just their address")
        // A type rule never catches links, so it says nothing of them.
        show.applies = .linksAndDownloads
        #expect(show.summarySentence == "Files of type torrent are saved first, then open in rTorrent")
    }

    /// A link never waits for a file; the same rule hands its address off as before.
    @Test func onlyDownloadsHandOffASavedFile() {
        var rule = DownloadRule(name: "Torrents", match: .any, action: DownloadRuleAction(kind: .openApp))
        #expect(!DownloadHandoff.defersToSavedFile(rule, forDownload: true))
        rule.handoffType = .file
        #expect(DownloadHandoff.defersToSavedFile(rule, forDownload: true))
        #expect(!DownloadHandoff.defersToSavedFile(rule, forDownload: false))
    }

    /// The Hand off choice is a file, as in Finder, not the File menu (German Datei, not Ablage).
    @Test func theFileChoiceIsAFileNotTheMenu() throws {
        let bundle = try #require(Bundle.main.path(forResource: "de", ofType: "lproj").flatMap(Bundle.init(path:)))
        #expect(bundle.localizedString(forKey: "handoff.file", value: nil, table: nil) == "Datei")
        #expect(bundle.localizedString(forKey: "File", value: nil, table: nil) == "Ablage")
        #expect(DownloadRule.HandoffType.file.title == String(localized: "handoff.file", defaultValue: "File", comment: ""))
    }

    /// A File handoff's download you cancel or remove goes quietly; only a failure says the download didn't finish.
    @MainActor @Test func aCancelledFileHandoffSaysNothing() {
        let rule = DownloadRule(name: "Quiet \(UUID().uuidString)", match: .any, action: DownloadRuleAction(kind: .openApp), handoffType: .file)
        let pending = PendingFileHandoff(rule: rule, request: DownloadHandoff.Request(url: URL(string: "https://example.com/a.torrent")!))
        let cancelled = DownloadItem(filename: "a.torrent", sourceURL: nil, isPrivate: false)
        DownloadManager.shared.debugSetFileHandoff(pending, on: cancelled)
        DownloadManager.shared.cancel(cancelled)
        let removed = DownloadItem(filename: "b.torrent", sourceURL: nil, isPrivate: false)
        DownloadManager.shared.debugSetFileHandoff(pending, on: removed)
        DownloadManager.shared.remove(removed)
        #expect(cancelled.fileHandoff == nil && removed.fileHandoff == nil)
        #expect(!Diagnostics.events.contains { $0.kind == "Handoff failed" && ($0.detail ?? "").contains(rule.name) })
    }

    /// The site refused the download after Hand Off: its File handoff is dropped at once, others stay.
    @MainActor @Test func aRefusedDownloadDropsItsFileHandoff() {
        let rule = DownloadRule(name: "Torrents", match: .any, action: DownloadRuleAction(kind: .openApp), handoffType: .file)
        let webView = WKWebView()
        let refused = URL(string: "https://example.com/a.torrent")!, other = URL(string: "https://example.com/b.torrent")!
        DownloadManager.shared.expectFileHandoff(rule, request: DownloadHandoff.Request(url: refused), from: webView)
        DownloadManager.shared.expectFileHandoff(rule, request: DownloadHandoff.Request(url: other), from: webView)
        DownloadManager.shared.dropFileHandoff(for: refused, from: webView)
        #expect(DownloadManager.shared.debugPendingFileHandoffs(from: webView) == [other])
        DownloadManager.shared.dropFileHandoff(for: other, from: webView)
        #expect(DownloadManager.shared.debugPendingFileHandoffs(from: webView).isEmpty)
    }

    /// An Open App action gets the saved file once there is one; a link still gets the address.
    @Test func anAppIsGivenTheSavedFileAfterAFileHandoff() {
        let link = URL(string: "https://tracker.example/download.php?id=42")!
        let saved = URL(fileURLWithPath: "/Users/me/Downloads/a.torrent")
        #expect(DownloadHandoff.appTarget(HandoffValues(link: link, file: saved)) == saved)
        #expect(DownloadHandoff.appTarget(HandoffValues(link: link)) == link)
    }

    // MARK: Where an Open URL rule opens

    /// Only web URLs open in Zigzag; others go to their app (mpv, IINA).
    @Test func aWebAddressIsZigzagsAndAnythingElseItsAppsOwn() {
        #expect(OpenInZigzag.handles(URL(string: "https://example.com/a?b=c")!))
        #expect(OpenInZigzag.handles(URL(string: "http://example.com/a")!))
        #expect(OpenInZigzag.handles(URL(string: "HTTPS://example.com/a")!))
        #expect(!OpenInZigzag.handles(URL(string: "mpv://example.com/a")!))
        #expect(!OpenInZigzag.handles(URL(string: "iina://weblink?url=x")!))
        #expect(!OpenInZigzag.handles(URL(string: "magnet:?xt=urn:btih:abc")!))
        #expect(!OpenInZigzag.handles(URL(string: "mailto:someone@example.com")!))
        #expect(!OpenInZigzag.handles(URL(string: "file:///Users/me/a.pdf")!))
    }

    /// New rules ask where to open; rules saved before the choice existed keep using the default browser.
    @Test func aRuleRemembersWhereItsWebAddressOpens() throws {
        var rule = DownloadRule(name: "Mirror", applies: .linksAndDownloads, match: .contains, pattern: "example.com",
                                action: DownloadRuleAction(kind: .openURL))
        rule.action.urlTemplate = "https://mirror.example.com/{filename}"
        #expect(rule.action.openIn == .ask)

        let plain = try JSONEncoder().encode([rule])
        #expect(String(decoding: plain, as: UTF8.self).contains("\"openIn\":\"ask\""))
        let told = try JSONDecoder().decode([DownloadRule].self, from: plain)
        #expect(told == [rule])
        #expect(told.first?.action.openIn == .ask)

        rule.action.openIn = .mini
        let data = try JSONEncoder().encode([rule])
        let again = try JSONDecoder().decode([DownloadRule].self, from: data)
        #expect(again == [rule])
        #expect(again.first?.action.openIn == .mini)

        // Older files have no openIn and keep the default browser. Removed from the object since JSONEncoder key order isn't fixed.
        var objects = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        var action = try #require(objects[0]["action"] as? [String: Any])
        #expect(action.removeValue(forKey: "openIn") != nil)
        objects[0]["action"] = action
        let older = try JSONSerialization.data(withJSONObject: objects)
        let fromOlder = try JSONDecoder().decode([DownloadRule].self, from: older)
        #expect(fromOlder.first?.action.openIn == .defaultBrowser)
    }

    @Test func everyPlaceIsOneTheQuestionKnows() {
        #expect(OpenInZigzag.Place.allCases.map(\.rawValue) == ["thisTab", "newTab", "mini"])
        #expect(OpenInZigzag.Place(rawValue: "thisTab") == .thisTab)
        #expect(OpenInZigzag.Place(rawValue: "mini") == .mini)
        // "deny" and its viewer aren't places, so the rule keeps asking.
        #expect(OpenInZigzag.Place(rawValue: "deny") == nil)
        #expect(OpenInZigzag.Place(rawValue: "viewer") == nil)
        #expect(OpenInZigzag.Place(rawValue: "") == nil)
        #expect(OpenInZigzag.Place.allCases.allSatisfy { !$0.title.isEmpty })

        // Rules add Ask and the default browser; the question offers destinations only.
        #expect(OpenInZigzag.Choice.allCases.map(\.rawValue) == ["ask", "defaultBrowser", "thisTab", "newTab", "mini"])
        #expect(OpenInZigzag.Choice.destinations.map(\.rawValue) == ["defaultBrowser", "thisTab", "newTab", "mini"])
        #expect(OpenInZigzag.Choice.ask.place == nil)
        #expect(OpenInZigzag.Choice.defaultBrowser.place == nil)
        #expect(OpenInZigzag.Choice.mini.place == .mini)
        #expect(OpenInZigzag.Choice.allCases.allSatisfy { !$0.title.isEmpty })
    }

    /// Where an Open URL opens always has an answer (ask), so it never blocks Add.
    @Test func whereAWebAddressOpensNeverHoldsTheRuleBack() {
        var action = DownloadRuleAction(kind: .openURL)
        #expect(!action.isComplete)
        action.urlTemplate = "https://example.com/{filename}"
        #expect(action.isComplete)
        #expect(DownloadRuleSheet.actionHoldUp(action) == nil)
        #expect(action.openIn == .ask)
        // Only the match can block it.
        var mine = DownloadRule(name: "Mirror", match: .any, action: action)
        #expect(DownloadRuleSheet.heldUp(mine, all: true).isEmpty)
        mine.action.openIn = .newTab
        #expect(DownloadRuleSheet.heldUp(mine, all: true).isEmpty)
    }

    // MARK: The place the hand-off card asks for

    /// The hand-off card asks only when the rule hasn't decided; its dropdown starts on This Tab, which a quick press sends. The question and rule sheet keep the browser first.
    @Test func theHandOffCardStartsWithThisTabInZigzag() {
        #expect(DownloadHandoff.cardPlaces.map(\.rawValue) == ["thisTab", "defaultBrowser", "newTab", "mini"])
        #expect(DownloadHandoff.cardPlaces.first == .thisTab)
        // `DropdownButton` selects index 0 until touched, and the card reads it on Hand Off.
        let dropdown = DropdownButton()
        dropdown.options = DownloadHandoff.cardPlaces.map { DropdownButton.Option(title: $0.title) }
        #expect(dropdown.selectedIndex == 0)
        #expect(dropdown.options.first?.title == OpenInZigzag.Choice.thisTab.title)
        // The rule's question and sheet are unchanged: browser first, Ask first in the sheet.
        #expect(OpenInZigzag.Choice.destinations.map(\.rawValue) == ["defaultBrowser", "thisTab", "newTab", "mini"])
        #expect(OpenInZigzag.Choice.allCases.map(\.rawValue) == ["ask", "defaultBrowser", "thisTab", "newTab", "mini"])
    }

    /// A place picked in the card applies to that hand-off only; the rule stays `.ask`.
    @Test func aCardsPlaceOpensOneHandOffAndNeverBecomesTheRules() {
        var rule = DownloadRule(name: "Mirror", applies: .linksAndDownloads, match: .contains, pattern: "example.com",
                                action: DownloadRuleAction(kind: .openURL))
        rule.action.urlTemplate = "https://mirror.example.com/{filename}"
        #expect(rule.action.openIn == .ask)

        let request = DownloadHandoff.Request(url: URL(string: "https://example.com/a.zip")!, place: .thisTab)
        #expect(DownloadHandoff.opening(rule, at: request.place) == .thisTab, "this hand-off opens where the card says")
        #expect(DownloadHandoff.ruleToKeep(rule, choice: .thisTab, always: false) == nil, "nothing is written on the rule")
        #expect(rule.action.openIn == .ask, "and the rule is still asking")

        // A rule told in its sheet opens there without a card; a card choice still overrides once.
        var told = rule
        told.action.openIn = .mini
        #expect(DownloadHandoff.opening(told, at: nil) == .mini)
        #expect(DownloadHandoff.opening(told, at: .newTab) == .newTab)
        #expect(told.action.openIn == .mini)
    }

    /// Always saves the place on the rule; Once opens and leaves the rule asking. Returns a rule for the caller to save.
    @Test func onlyAlwaysKeepsThePlaceOnTheRule() {
        var rule = DownloadRule(name: "Mirror", applies: .linksAndDownloads, match: .contains, pattern: "example.com",
                                action: DownloadRuleAction(kind: .openURL))
        rule.action.urlTemplate = "https://mirror.example.com/{filename}"
        #expect(rule.action.openIn == .ask)

        #expect(DownloadHandoff.ruleToKeep(rule, choice: .mini, always: false) == nil)
        let kept = DownloadHandoff.ruleToKeep(rule, choice: .mini, always: true)
        #expect(kept?.id == rule.id)
        #expect(kept?.action.openIn == .mini)
        #expect(rule.action.openIn == .ask, "the rule the question asked about is not changed in place")
    }

    /// One list drives both the Add button's text and the marked fields, in form order.
    @Test func aRuleSaysEverythingHoldingAddBack() {
        var mine = rule(.contains, "")
        mine.name = ""
        #expect(DownloadRuleSheet.heldUp(mine, all: true).map(\.field) == [.name, .pattern, .action(.url)])

        // While typing, only fields already filled in wrong are reported.
        mine.name = "Torrents"
        #expect(DownloadRuleSheet.heldUp(mine, all: false).map(\.field) == [.action(.url)])
        #expect(DownloadRuleSheet.heldUp(mine, all: true).map(\.field) == [.pattern, .action(.url)])

        mine.pattern = "torrent"
        mine.action.urlTemplate = "mpd://{link}"
        #expect(DownloadRuleSheet.heldUp(mine, all: true).isEmpty)

        // A broken regex is reported regardless of hover.
        mine.match = .regex
        mine.pattern = "(["
        #expect(DownloadRuleSheet.heldUp(mine, all: false).map(\.field) == [.pattern])

        // `any` needs no pattern.
        mine.match = .any
        mine.pattern = ""
        #expect(DownloadRuleSheet.heldUp(mine, all: true).isEmpty)
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
        // Players handle clicked links and media files.
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
        // A clicked link may carry the page's cookies.
        var clicked = elsewhere
        clicked.wasClicked = true
        #expect(DownloadHandoff.maySendCookies(clicked))
        // No page, no cookies.
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

    /// A kept answer holds even where no question can show, e.g. a background tab or no window.
    @Test func aKeptAnswerHoldsWhereNoQuestionCouldShow() async {
        let rule = DownloadRule(name: "aria2", applies: .downloads, match: .contains, pattern: "example.com",
                                action: DownloadRuleAction(kind: .openURL))
        let tab = Tab(url: URL(string: "https://example.com/page")!, title: "Example", spaceID: UUID())
        let origin = "https://example.com"
        let kind = DownloadHandoff.handoffKind(rule)
        let request = DownloadHandoff.Request(url: URL(string: "https://example.com/file.zip")!, pageOrigin: origin)

        tab.permissionAnswers.note("deny", key: origin, kind: kind)
        #expect(await DownloadHandoff.decide(rule, request: request, tab: tab, forDownload: true).gate == .cancel)
        tab.permissionAnswers.note("handOff", key: origin, kind: kind)
        #expect(await DownloadHandoff.decide(rule, request: request, tab: tab, forDownload: true).gate == .handOff)
        tab.permissionAnswers.note("browser", key: origin, kind: kind)
        #expect(await DownloadHandoff.decide(rule, request: request, tab: tab, forDownload: true).gate == .browser)
    }

    /// Pages without a site (file, data URL) are asked every time and never borrow a kept answer.
    @Test func aPageWithNoSiteBorrowsNoAnswer() async {
        let rule = DownloadRule(name: "aria2", applies: .downloads, match: .contains, pattern: "example.com",
                                action: DownloadRuleAction(kind: .openURL))
        let tab = Tab(url: URL(string: "file:///Users/me/page.html")!, title: "File", spaceID: UUID())
        let kind = DownloadHandoff.handoffKind(rule)
        tab.permissionAnswers.note("deny", key: "https://example.com", kind: kind)
        let request = DownloadHandoff.Request(url: URL(string: "https://example.com/file.zip")!)
        #expect(await DownloadHandoff.decide(rule, request: request, tab: tab, forDownload: true).gate == .browser)
    }

    /// Popups don't ask, but kept answers still apply.
    @Test func aPopupAsksNothingButReadsAKeptAnswer() async {
        let rule = DownloadRule(name: "aria2", applies: .downloads, match: .contains, pattern: "example.com",
                                action: DownloadRuleAction(kind: .openURL))
        let tab = Tab(url: URL(string: "https://example.com/page")!, title: "Example", spaceID: UUID())
        let kind = DownloadHandoff.handoffKind(rule)
        var quiet = DownloadHandoff.Request(url: URL(string: "https://example.com/file.zip")!,
                                            pageOrigin: "https://example.com")
        quiet.mayAsk = false
        #expect(await DownloadHandoff.decide(rule, request: quiet, tab: tab, forDownload: true).gate == .browser)
        tab.permissionAnswers.note("deny", key: "https://example.com", kind: kind)
        #expect(await DownloadHandoff.decide(rule, request: quiet, tab: tab, forDownload: true).gate == .cancel)
    }

    // MARK: The App field's menu

    /// The App field lists Applications one level deep: bundles only, deduplicated, sorted.
    @Test func theAppMenuListsApplicationsOneLevelDeep() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("apps-\(UUID().uuidString)")
        let mac = root.appendingPathComponent("Mac"), mine = root.appendingPathComponent("Mine")
        try FileManager.default.createDirectory(at: mac.appendingPathComponent("Zeta.app"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mine.appendingPathComponent("Alpha.app"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Not a bundle.
        try Data().write(to: mine.appendingPathComponent("notes.txt"))
        // Nested bundles aren't scanned.
        try FileManager.default.createDirectory(at: mac.appendingPathComponent("Zeta.app/Contents/PlugIns/Inner.app"),
                                                withIntermediateDirectories: true)

        // Duplicate folders give one entry; sorted by name.
        let named = Applications.named(in: [mac.path, mine.path, mine.path])
        #expect(named.map(\.name) == ["Alpha", "Zeta"])
        #expect(named.first?.path == mine.appendingPathComponent("Alpha.app").path)
    }

    // MARK: A rule that can't be saved yet

    /// An action that can't run names the field to fix, e.g. `bing.com` without a scheme marks the address field.
    @Test func anActionThatCannotRunNamesTheFieldHoldingItUp() {
        var open = DownloadRuleAction(kind: .openURL)
        #expect(DownloadRuleSheet.actionHoldUp(open)?.field == .url)
        open.urlTemplate = "bing.com"
        #expect(DownloadRuleSheet.actionHoldUp(open)?.field == .url)
        open.urlTemplate = "mpv://{encoded_link}"
        #expect(DownloadRuleSheet.actionHoldUp(open) == nil)

        var app = DownloadRuleAction(kind: .openApp)
        #expect(DownloadRuleSheet.actionHoldUp(app)?.field == .app)
        app.appPath = "/Applications/VLC.app"
        #expect(DownloadRuleSheet.actionHoldUp(app) == nil)

        var script = DownloadRuleAction(kind: .runScript)
        #expect(DownloadRuleSheet.actionHoldUp(script)?.field == .script)
        script.scriptPath = "/usr/bin/true"
        #expect(DownloadRuleSheet.actionHoldUp(script) == nil)

        var rpc = DownloadRuleAction(kind: .jsonRPC)
        #expect(DownloadRuleSheet.actionHoldUp(rpc)?.field == .endpoint)
        rpc.rpcEndpoint = "not an address"
        #expect(DownloadRuleSheet.actionHoldUp(rpc)?.field == .endpoint)
        rpc.rpcEndpoint = "http://127.0.0.1:6800/jsonrpc"
        #expect(DownloadRuleSheet.actionHoldUp(rpc)?.field == .method)
        rpc.rpcMethod = "aria2.addUri"
        #expect(DownloadRuleSheet.actionHoldUp(rpc) == nil)
    }

    /// A service's place leads and its method follows in brackets (#367), without a dot between them.
    @MainActor @Test func aServiceReadsAsItsPlaceThenItsMethod() {
        var send = DownloadRuleAction(kind: .jsonRPC)
        send.rpcEndpoint = "http://127.0.0.1:5000/RPC2"
        send.rpcMethod = "load.start"
        #expect(send.summary == "127.0.0.1 (load.start)")
        let rule = DownloadRule(name: "Send to rTorrent", applies: .downloads, match: .endsWith, pattern: ".torrent", action: send)
        #expect(rule.summarySentence == "Files ending in .torrent go to 127.0.0.1 (load.start)")
        send.rpcEndpoint = ""
        #expect(send.summary == "load.start")
        let kept = SettingsView.handoffAnswerRow(ruleNamed: "YouTube", answer: "Hand Off", sites: "youtube.com")
        #expect(kept.detail == "youtube.com: Hand Off")
        #expect(!send.summary.contains("·") && !rule.summarySentence.contains("·") && !kept.detail.contains("·"))
    }

    // MARK: What an automation says for itself

    /// Only otherwise invisible handoffs are announced (app, service, default browser, another app's URL), once per rule.
    @Test func onlyTheHandoffsYouCantSeeAreAnnounced() {
        func action(_ kind: DownloadRuleAction.Kind) -> DownloadRuleAction { DownloadRuleAction(kind: kind) }

        var app = action(.openApp)
        app.appPath = "/Applications/mpv.app"
        var service = action(.jsonRPC)
        service.rpcEndpoint = "http://127.0.0.1:6800/jsonrpc"
        service.rpcMethod = "aria2.addUri"
        var script = action(.runScript)
        script.scriptPath = "yt-dlp.sh"
        var web = action(.openURL)
        web.urlTemplate = "{link}"

        // An app or service handoff gets a line.
        #expect(HandoffNotice.line(for: DownloadRule(name: "Videos", action: app), elsewhere: .app("mpv")) == "Videos: handed this link to mpv")
        #expect(HandoffNotice.line(for: DownloadRule(name: "Videos", action: service), elsewhere: .service("127.0.0.1 (aria2.addUri)")) == "Videos: sent this link to 127.0.0.1 (aria2.addUri)")
        // An unnamed rule gets a generic line.
        #expect(HandoffNotice.line(for: DownloadRule(name: "", action: app), elsewhere: .app("mpv")) == "handed this link to mpv")
        // Visible results get none: script card, tab, Mini, question, download.
        #expect(HandoffNotice.line(for: DownloadRule(name: "Videos", action: script), elsewhere: nil) == nil)
        #expect(HandoffNotice.line(for: DownloadRule(name: "Videos", action: web), elsewhere: nil) == nil)
        // No rule, no line.
        #expect(HandoffNotice.line(for: nil, elsewhere: .app("mpv")) == nil)
    }

    /// One announcement per rule per session.
    @Test func aRuleSaysItsLineOnceASession() {
        HandoffNotice.forgetSaid()
        defer { HandoffNotice.forgetSaid() }
        let rule = DownloadRule(name: "Videos", match: .any, action: DownloadRuleAction(kind: .openApp))
        #expect(HandoffNotice.takeLine(for: rule, elsewhere: .app("mpv")) == "Videos: handed this link to mpv")
        #expect(HandoffNotice.takeLine(for: rule, elsewhere: .app("mpv")) == nil)
        // Another rule gets its own.
        let other = DownloadRule(name: "Music", match: .any, action: DownloadRuleAction(kind: .openApp))
        #expect(HandoffNotice.takeLine(for: other, elsewhere: .app("mpv")) == "Music: handed this link to mpv")
        // A rule with nothing to say doesn't use up its announcement.
        let quiet = DownloadRule(name: "Quiet", match: .any, action: DownloadRuleAction(kind: .runScript))
        #expect(HandoffNotice.takeLine(for: quiet, elsewhere: nil) == nil)
        #expect(HandoffNotice.takeLine(for: quiet, elsewhere: .app("mpv")) == "Quiet: handed this link to mpv")
    }

    /// The card's answer, else the rule's, decided in one place so notice and action agree.
    @Test func aWebAddressOpensWhereTheRuleSaysItDoes() {
        var web = DownloadRuleAction(kind: .openURL)
        let rule = DownloadRule(name: "Videos", match: .any, action: web)

        for choice in OpenInZigzag.Choice.allCases {
            web.openIn = choice
            let told = DownloadRule(name: "Videos", match: .any, action: web)
            #expect(DownloadHandoff.opening(told, at: nil) == choice)
            #expect(DownloadHandoff.opening(told, at: .mini) == .mini)
        }

        // Ask opens nothing until answered.
        web.openIn = .ask
        #expect(DownloadHandoff.opening(rule, at: nil) == .ask)
        #expect(DownloadHandoff.opening(rule, at: nil).place == nil)
        #expect(DownloadHandoff.opening(rule, at: .defaultBrowser).place == nil)
    }

    // MARK: The order the rules are in
    /// Drops name the target row, not an index, since the list hides file types; the rule moves just before the target.
    @Test func aRuleMovesToSitBeforeTheOneItWasDroppedOn() {
        let a = rule(.any)
        let b = rule(.any)
        let c = rule(.any)
        let type = destination("pdf")

        func order(_ rules: [DownloadRule]) -> [UUID] { rules.map(\.id) }
        func moved(_ rules: [DownloadRule], _ id: UUID, before: UUID?) -> [UUID] {
            order(DownloadRulesStore.moved(rules, id: id, before: before))
        }

        // Down, up, and to the end.
        #expect(moved([a, b, c], c.id, before: a.id) == order([c, a, b]))
        #expect(moved([a, b, c], a.id, before: c.id) == order([b, a, c]))
        #expect(moved([a, b, c], a.id, before: nil) == order([b, c, a]))
        // Dropped in place: no change.
        #expect(moved([a, b, c], a.id, before: b.id) == order([a, b, c]))
        #expect(moved([a, b, c], b.id, before: c.id) == order([a, b, c]))
        // A file type between them stays put.
        #expect(moved([a, type, b], b.id, before: a.id) == order([b, a, type]))
        // An unknown rule leaves the order alone.
        #expect(moved([a, b], c.id, before: a.id) == order([a, b]))
        #expect(moved([], a.id, before: nil) == [])
    }
}

extension DownloadRuleTests {
    @Test func storedHandoffAnswersMapToGates() {
        #expect(DownloadHandoff.gate(stored: "handOff") == .handOff)
        #expect(DownloadHandoff.gate(stored: "browser") == .browser)
        #expect(DownloadHandoff.gate(stored: "deny") == .cancel)
        #expect(DownloadHandoff.gate(stored: nil) == .browser)
    }

    /// "Always on this site" is kept per site and applies to every page there; the rule's own answer travels with it, even into private windows.
    @MainActor @Test func aSitesHandoffAnswerStandsForEveryPageOfIt() async throws {
        let suite = "zigzag-download-rules-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let before = SitePermissions.defaults
        SitePermissions.defaults = defaults
        defer {
            SitePermissions.defaults = before
            defaults.removePersistentDomain(forName: suite)
        }
        let rule = DownloadRule(name: "Files", applies: .downloads, match: .contains, pattern: "file.zip",
                                action: DownloadRuleAction(kind: .openURL))
        SitePermissions.remember("deny", subject: PermissionSubject.handoff(rule.id), origin: "https://site.example")
        let request = DownloadHandoff.Request(url: URL(string: "https://cdn.example/file.zip")!,
                                              referrer: URL(string: "https://site.example/other")!,
                                              pageOrigin: "https://site.example")
        #expect(await DownloadHandoff.decide(rule, request: request).gate == .cancel)

        var privateRequest = request
        privateRequest.isPrivate = true
        #expect(await DownloadHandoff.decide(rule, request: privateRequest).gate == .browser,
                "a private window is not the site the answer was given to")
    }

    /// A rule-level answer applies to every site; private windows still need the rule allowed there.
    @MainActor @Test func aRulesOwnAnswerStandsForEverySite() async {
        var rule = DownloadRule(name: "Files", applies: .downloads, match: .contains, pattern: "file.zip",
                                action: DownloadRuleAction(kind: .openURL))
        let request = DownloadHandoff.Request(url: URL(string: "https://cdn.example/file.zip")!,
                                              referrer: URL(string: "https://site.example/page")!,
                                              pageOrigin: "https://site.example")
        // Never answered and no window to ask: the rule doesn't run.
        #expect(await DownloadHandoff.decide(rule, request: request).gate == .browser)

        rule.handoffAnswer = "handOff"
        #expect(await DownloadHandoff.decide(rule, request: request).gate == .handOff)
        rule.handoffAnswer = "deny"
        #expect(await DownloadHandoff.decide(rule, request: request).gate == .cancel)

        var privateRequest = request
        privateRequest.isPrivate = true
        #expect(await DownloadHandoff.decide(rule, request: privateRequest).gate == .browser,
                "a private window runs no rule that hasn't been let in")
        rule.runsInPrivateWindows = true
        #expect(await DownloadHandoff.decide(rule, request: privateRequest).gate == .cancel)
        rule.handoffAnswer = "handOff"
        #expect(await DownloadHandoff.decide(rule, request: privateRequest).gate == .handOff)
    }

    /// The site answer outranks the rule's; the rule's is still saved with it.
    @MainActor @Test func aSitesAnswerOutranksTheRulesOwn() async throws {
        let suite = "zigzag-download-rules-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let before = SitePermissions.defaults
        SitePermissions.defaults = defaults
        defer {
            SitePermissions.defaults = before
            defaults.removePersistentDomain(forName: suite)
        }
        var rule = DownloadRule(name: "Files", applies: .downloads, match: .contains, pattern: "file.zip",
                                action: DownloadRuleAction(kind: .openURL))
        rule.handoffAnswer = "handOff"
        SitePermissions.remember("deny", subject: PermissionSubject.handoff(rule.id), origin: "https://site.example")
        let request = DownloadHandoff.Request(url: URL(string: "https://cdn.example/file.zip")!,
                                              referrer: URL(string: "https://site.example/page")!,
                                              pageOrigin: "https://site.example")
        #expect(await DownloadHandoff.decide(rule, request: request).gate == .cancel)
    }

    /// The rule's answer survives JSON; no answer decodes as none.
    @Test func aRulesOwnAnswerSurvivesItsJSON() throws {
        var rule = DownloadRule(name: "Files", applies: .downloads, match: .contains, pattern: "zip",
                                action: DownloadRuleAction(kind: .openURL))
        #expect(try JSONDecoder().decode(DownloadRule.self, from: JSONEncoder().encode(rule)).handoffAnswer == nil)
        rule.handoffAnswer = "handOff"
        let read = try JSONDecoder().decode(DownloadRule.self, from: JSONEncoder().encode(rule))
        #expect(read.handoffAnswer == "handOff")
    }

    /// The third duration choice names the rule, or "this rule" when unnamed.
    @Test func theThirdDurationChoiceNamesTheRule() {
        let named = DownloadRule(name: "YouTube", applies: .downloads, match: .contains, pattern: "youtube",
                                 action: DownloadRuleAction(kind: .openURL))
        #expect(DownloadHandoff.alwaysFor(named).contains("YouTube"))
        let unnamed = DownloadRule(name: "   ", applies: .downloads, match: .contains, pattern: "youtube",
                                   action: DownloadRuleAction(kind: .openURL))
        #expect(!DownloadHandoff.alwaysFor(unnamed).contains("“”"))
        #expect(DownloadHandoff.alwaysFor(unnamed) != DownloadHandoff.alwaysFor(named))
    }

    @Test func aHandoffQuestionUsesThePageOrigin() {
        let request = DownloadHandoff.Request(url: URL(string: "https://cdn.example/file.zip")!,
                                              referrer: URL(string: "https://site.example/page")!,
                                              pageOrigin: "https://site.example")
        #expect(DownloadHandoff.questionOrigin(for: request) == "https://site.example")
    }

    @Test func aHandoffQuestionFallsBackToTheReferrerThenTheTarget() {
        let referred = DownloadHandoff.Request(url: URL(string: "https://cdn.example/file.zip")!,
                                               referrer: URL(string: "https://site.example/page")!)
        #expect(DownloadHandoff.questionOrigin(for: referred) == "https://site.example")
        let bare = DownloadHandoff.Request(url: URL(string: "https://cdn.example/file.zip")!)
        #expect(DownloadHandoff.questionOrigin(for: bare) == "https://cdn.example")
    }
}

extension DownloadRuleTests {
    /// "Open in Browser" this time holds for the page, so its download isn't asked again.
    @MainActor @Test func aHandoffAnsweredThisTimeIsNotAskedAgain() async {
        let rule = DownloadRule(name: "Files", applies: .downloads, match: .contains, pattern: "file.zip",
                                action: DownloadRuleAction(kind: .openURL))
        let tab = Tab(url: URL(string: "https://site.example/page"), spaceID: UUID())
        tab.permissionAnswers.note("browser", key: "https://site.example", kind: DownloadHandoff.handoffKind(rule))
        let request = DownloadHandoff.Request(url: URL(string: "https://cdn.example/file.zip")!,
                                              referrer: URL(string: "https://site.example/page")!,
                                              pageOrigin: "https://site.example")
        #expect(await DownloadHandoff.decide(rule, request: request, tab: tab).gate == .browser)
        #expect(DownloadHandoff.handoffKind(rule) == "handoff:\(rule.id.uuidString)")
    }
}

/// Changing a rule's script or URL clears its answers; renaming or other fields don't.
extension DownloadRuleTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "DownloadRuleKeptAnswerTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let before = SitePermissions.defaults
        SitePermissions.defaults = defaults
        defer {
            SitePermissions.defaults = before
            defaults.removePersistentDomain(forName: suite)
        }
        try body(defaults)
    }

    /// A temp rules file, never the real one.
    private func rulesFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("zigzag-download-rules-\(UUID().uuidString).json")
    }

    @MainActor @Test func changingAScriptsPathForgetsOnlyThatRulesAnswers() throws {
        try withDefaults { _ in
            let file = rulesFile()
            defer { try? FileManager.default.removeItem(at: file) }
            var rule = DownloadRule(name: "Files", applies: .downloads, match: .contains, pattern: "file.zip",
                                    action: DownloadRuleAction(kind: .runScript))
            rule.action.scriptPath = "/usr/bin/true"
            rule.handoffAnswer = "handOff"
            var other = DownloadRule(name: "Other", applies: .downloads, match: .contains, pattern: "other.zip",
                                     action: DownloadRuleAction(kind: .runScript))
            other.action.scriptPath = "/usr/bin/true"
            other.handoffAnswer = "browser"
            let store = DownloadRulesStore(file: file)
            store.add(rule)
            store.add(other)
            SitePermissions.remember("browser", subject: PermissionSubject.handoff(rule.id), origin: "https://a.example")
            SitePermissions.remember("deny", subject: PermissionSubject.handoff(other.id), origin: "https://b.example")

            var edited = rule
            edited.action.scriptPath = "/usr/bin/false"
            store.update(edited)

            #expect(store.rules.first { $0.id == rule.id }?.handoffAnswer == nil)
            #expect(SitePermissions.decisions(prefix: PermissionSubject.handoff(rule.id)).isEmpty)
            // Other rules' answers and this rule's row are untouched.
            #expect(store.rules.first { $0.id == other.id }?.handoffAnswer == "browser")
            #expect(SitePermissions.decisions(prefix: PermissionSubject.handoff(other.id)).count == 1)
        }
    }

    @MainActor @Test func changingAURLTemplateForgetsThatRulesAnswers() throws {
        try withDefaults { _ in
            let file = rulesFile()
            defer { try? FileManager.default.removeItem(at: file) }
            var rule = DownloadRule(name: "Video", applies: .linksAndDownloads, match: .contains, pattern: "video",
                                    action: DownloadRuleAction(kind: .openURL))
            rule.action.urlTemplate = "mpv://{encoded_link}"
            rule.handoffAnswer = "deny"
            let store = DownloadRulesStore(file: file)
            store.add(rule)
            SitePermissions.remember("handOff", subject: PermissionSubject.handoff(rule.id), origin: "https://video.example")

            var edited = rule
            edited.action.urlTemplate = "iina://{encoded_link}"
            store.update(edited)

            #expect(store.rules.first { $0.id == rule.id }?.handoffAnswer == nil)
            #expect(SitePermissions.decisions(prefix: PermissionSubject.handoff(rule.id)).isEmpty)
        }
    }

    /// Changing what the rule hands off, like changing its script or URL, makes answers given for the old behavior stale.
    @MainActor @Test func changingAHandoffsTypeForgetsThatRulesAnswers() throws {
        try withDefaults { _ in
            let file = rulesFile()
            defer { try? FileManager.default.removeItem(at: file) }
            var rule = DownloadRule(name: "Torrents", applies: .downloads, match: .fileType, pattern: "torrent",
                                    action: DownloadRuleAction(kind: .jsonRPC))
            rule.action.rpcEndpoint = "http://127.0.0.1:5000/RPC2"
            rule.action.rpcMethod = "load.start"
            rule.handoffAnswer = "handOff"
            let store = DownloadRulesStore(file: file)
            store.add(rule)
            SitePermissions.remember("deny", subject: PermissionSubject.handoff(rule.id), origin: "https://tracker.example")

            var edited = rule
            edited.handoffType = .file
            store.update(edited)

            #expect(store.rules.first { $0.id == rule.id }?.handoffAnswer == nil)
            #expect(SitePermissions.decisions(prefix: PermissionSubject.handoff(rule.id)).isEmpty)
        }
    }

    @MainActor @Test func renamingARuleOrChangingAnUnrelatedFieldKeepsItsAnswers() throws {
        try withDefaults { _ in
            let file = rulesFile()
            defer { try? FileManager.default.removeItem(at: file) }
            var rule = DownloadRule(name: "Video", applies: .linksAndDownloads, match: .contains, pattern: "video",
                                    action: DownloadRuleAction(kind: .openURL))
            rule.action.urlTemplate = "mpv://{encoded_link}"
            rule.handoffAnswer = "handOff"
            let store = DownloadRulesStore(file: file)
            store.add(rule)
            SitePermissions.remember("browser", subject: PermissionSubject.handoff(rule.id), origin: "https://video.example")

            var edited = rule
            edited.name = "Renamed"
            // Other action fields (like a later `openIn`) don't count as changing what runs.
            edited.action.arguments = ["--unrelated"]
            store.update(edited)

            #expect(store.rules.first { $0.id == rule.id }?.handoffAnswer == "handOff")
            #expect(SitePermissions.decisions(prefix: PermissionSubject.handoff(rule.id)).count == 1)
        }
    }

    @MainActor @Test func removingARuleForgetsTheAnswersKeptForIt() throws {
        try withDefaults { _ in
            let file = rulesFile()
            defer { try? FileManager.default.removeItem(at: file) }
            var rule = DownloadRule(name: "Files", applies: .downloads, match: .contains, pattern: "file.zip",
                                    action: DownloadRuleAction(kind: .openURL))
            rule.handoffAnswer = "handOff"
            let store = DownloadRulesStore(file: file)
            store.add(rule)
            SitePermissions.remember("deny", subject: PermissionSubject.handoff(rule.id), origin: "https://a.example")

            store.remove(id: rule.id)

            #expect(store.rules.isEmpty)
            #expect(SitePermissions.decisions(prefix: PermissionSubject.handoff(rule.id)).isEmpty)
        }
    }
}
