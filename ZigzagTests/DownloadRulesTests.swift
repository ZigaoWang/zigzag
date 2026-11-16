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
        // A bidi override can make "invoicefdp.exe" read as a PDF name; it is a format character, so it goes.
        #expect(DownloadTokens.filename(for: file, suggested: "invoice\u{202E}fdp.exe") == "invoicefdp.exe")
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
        // A field of the wrong type is not a rule either: `.contains` with no pattern would catch every address.
        #expect(!rules[3].isEnabled)
        #expect(!rules[4].isEnabled)
        // No action would decode as an Open URL rule with nothing to open; a catch-all prompt is worse than no rule.
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

    @Test func aQuestionIsOnlyAskedWhereItCanBeSeen() {
        #expect(DownloadHandoff.questionCanShow(tabIsInFront: true, windowIsVisible: true, windowIsKey: true))
        #expect(DownloadHandoff.questionCanShow(tabIsInFront: nil, windowIsVisible: true, windowIsKey: true))
        // A background tab, a window behind another, or Zigzag in the background holds the question unseen.
        #expect(!DownloadHandoff.questionCanShow(tabIsInFront: false, windowIsVisible: true, windowIsKey: true))
        #expect(!DownloadHandoff.questionCanShow(tabIsInFront: true, windowIsVisible: false, windowIsKey: true))
        #expect(!DownloadHandoff.questionCanShow(tabIsInFront: true, windowIsVisible: true, windowIsKey: false))
        // A pop-up is key while its opener's window is not: its own links wait for a window that can ask.
        #expect(!DownloadHandoff.questionCanShow(tabIsInFront: true, windowIsVisible: true, windowIsKey: false))
        #expect(!DownloadHandoff.questionCanShow(tabIsInFront: nil, windowIsVisible: true, windowIsKey: false))
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
        // A host-only cookie stays on its host; one with a leading dot is for the domain.
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
        // Nothing token-like is added to a service that doesn't take one.
        #expect(DownloadHandoff.jsonParameters(parameters, method: "other.method", secret: "s3cret").first as? String == nil)
    }

    /// An Open URL template fills each token as one query value: a filename or title with `&` or `=` in it can't add
    /// a parameter of its own. `{path}` and `{query}` are the address's own parts and are not encoded twice.
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
        // Exactly the five asked for: the filename added no sixth.
        #expect(items.count == 5)

        // The redirect case keeps the address's own path and query as they are.
        #expect(DownloadTokens.expand("https://www.bing.com{path}?{query}", with: values, query: true)
                == "https://www.bing.com/a?b=c&d=e")
    }

    /// A MIME type is the server's, not an option: one that starts with `-` is passed with a `_` before it.
    @Test func aMimeTypeCannotBeReadAsAnOption() {
        let values = HandoffValues(link: URL(string: "https://site.example/f")!, mime: "-o/tmp/x")
        #expect(DownloadTokens.expand("{mime}", with: values) == "_-o/tmp/x")
    }

    /// Cookies go only to a target on this Mac: a script or app runs here, an RPC service must be local, and an Open
    /// URL may be a custom scheme or a local http(s) address. A remote address gets none.
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
        #expect(!DownloadHandoff.targetIsOnThisMac(action(.jsonRPC) { $0.rpcEndpoint = "https://evil.example/rpc" }, values: values))
        #expect(DownloadHandoff.targetIsOnThisMac(action(.jsonRPC) { $0.rpcEndpoint = "http://127.0.0.1:6800/jsonrpc" }, values: values))
    }

    /// A boolean is a boolean over XML-RPC, not an integer: JSONSerialization gives both back as NSNumbers.
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

    /// A per-extension destination as the panel makes one: a download rule whose match is the file's type, and an
    /// action that says where a file of it lands.
    private func destination(_ extensions: String, _ kind: DownloadRuleAction.Kind = .saveToFolder,
                             folder: String = "/Users/me/Documents", enabled: Bool = true) -> DownloadRule {
        var action = DownloadRuleAction(kind: kind)
        action.folderPath = kind == .saveToFolder ? folder : ""
        var rule = DownloadRule(name: "", applies: .downloads, match: .fileType, pattern: extensions, action: action)
        rule.isEnabled = enabled
        return rule
    }

    /// A file's type is its own name, never the address: that is what lets a per-extension destination be written as
    /// an ordinary rule and still read the right thing.
    @Test func aFileTypeMatchesByNameAndNeverByAddress() {
        let type = rule(.fileType, "pdf, epub")
        #expect(type.matches(filename: "report.pdf"))
        #expect(type.matches(filename: "report.PDF"))
        #expect(type.matches(filename: "book.EPUB"))
        #expect(!type.matches(filename: "report.txt"))
        // An address on its own is never a file's name, so a type rule catches nothing without one.
        #expect(!type.matches(file))
        #expect(!type.matches(file, filename: ""))
    }

    @Test func aFileTypeTakesADotAndTwoParts() {
        #expect(rule(.fileType, ".pdf").matches(filename: "a.pdf"))
        #expect(rule(.fileType, "pdf").matches(filename: "a.pdf"))
        #expect(rule(.fileType, "pdf,epub").matches(filename: "b.epub"))
        #expect(rule(.fileType, "tar.gz").matches(filename: "backup.tar.gz"))
        #expect(!rule(.fileType, "gz").matches(filename: "backup.tar.xz"))
        // The dot is what makes an extension an extension.
        #expect(!rule(.fileType, "pdf").matches(filename: "pdf"))
        #expect(!rule(.fileType, "").matches(filename: "a.pdf"))
        #expect(!rule(.fileType, "pdf", enabled: false).matches(filename: "a.pdf"))
    }

    @Test func aFileTypeFollowsTheCaseSwitch() {
        #expect(rule(.fileType, "PDF", caseSensitive: true).matches(filename: "a.PDF"))
        #expect(!rule(.fileType, "PDF", caseSensitive: true).matches(filename: "a.pdf"))
        #expect(rule(.fileType, "PDF", caseSensitive: false).matches(filename: "a.pdf"))
    }

    /// The download path reads the file's name, so a type rule catches its download — and, since a link has no name,
    /// never a link.
    @Test func aDownloadIsCaughtByItsTypeAndALinkIsNot() {
        let type = rule(.fileType, "pdf")
        #expect(DownloadRulesStore.firstMatch(in: [type], url: file, filename: "report.pdf", appliesToLinks: false)?.id == type.id)
        #expect(DownloadRulesStore.firstMatch(in: [type], url: file, filename: "", appliesToLinks: false) == nil)
        #expect(DownloadRulesStore.firstMatch(in: [type], url: file, filename: "report.pdf", appliesToLinks: true) == nil)
    }

    /// Where a download lands is the first destination that matches, in the same order a handoff is tried — and a
    /// handoff rule for the same file is not a destination, so it is left to the handoff path.
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

    /// A folder destination saves into the folder the rule names, under the file's own name; there is nothing to
    /// decide when the folder is empty or has gone, and Zigzag's own showing saves where it always would.
    @Test func aDestinationIsReadAsAPlaceToSave() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zz-dest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let there = DownloadManager.place(for: .folder(folder.path), folder: folder.path, filename: "report.pdf")
        #expect(there?.destination == folder.appendingPathComponent("report.pdf"))
        #expect(there?.openWhenFinished == false, "a folder destination saves, it never opens")

        // The file's name is made safe, as every download's is.
        #expect(DownloadManager.place(for: .folder(folder.path), folder: folder.path, filename: "a/b:c.pdf")?.destination
                == folder.appendingPathComponent("a-b-c.pdf"))

        // A name already taken there is not overwritten.
        let taken = folder.appendingPathComponent("report.pdf")
        try Data("one".utf8).write(to: taken)
        let second = DownloadManager.place(for: .folder(folder.path), folder: folder.path, filename: "report.pdf")
        #expect(second?.destination == folder.appendingPathComponent("report 2.pdf"))

        // A folder still being downloaded into is not chosen either.
        let busy = DownloadManager.place(for: .folder(folder.path), folder: folder.path, filename: "report.pdf",
                                         avoiding: [folder.appendingPathComponent("report 2.pdf").path])
        #expect(busy?.destination == folder.appendingPathComponent("report 3.pdf"))

        // Nothing to decide: no folder named, one that doesn't exist, and one that is really a file.
        #expect(DownloadManager.place(for: .folder(""), folder: "", filename: "a.pdf") == nil)
        #expect(DownloadManager.place(for: .folder("/no/such/folder"), folder: "/no/such/folder", filename: "a.pdf") == nil)
        let aFile = folder.appendingPathComponent("notafolder")
        try Data("x".utf8).write(to: aFile)
        #expect(DownloadManager.place(for: .folder(aFile.path), folder: aFile.path, filename: "a.pdf") == nil)

        // Open saves where it would have gone anyway, and says to open it once it's here.
        let shown = DownloadManager.place(for: .open, folder: "ignored", filename: "report.pdf")
        #expect(shown?.openWhenFinished == true)
        #expect(shown?.destination.lastPathComponent == "report.pdf")
        // A private window keeps the file but never hands it to another app, unless the rule was let in.
        #expect(DownloadManager.place(for: .open, folder: "", filename: "report.pdf", canOpen: false)?.openWhenFinished == false)
    }
    /// A destination is a destination, and needs what it needs: a folder to save into, nothing to be opened by the
    /// Mac's own app.
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

    /// A torrent preset catches what it is for — a magnet link, or an address carrying a `.torrent` — and nothing else.
    /// aria2 and Motrix stay general unless the torrents variant is the one chosen.
    @Test func aTorrentPresetCatchesTorrentsAndMagnets() {
        let torrent = DownloadPreset.torrents.rule
        #expect(torrent.name == "rTorrent")
        #expect(torrent.matches(URL(string: "magnet:?xt=urn:btih:abc")!))
        #expect(torrent.matches(URL(string: "https://site.example/file.torrent")!))
        #expect(!torrent.matches(URL(string: "https://site.example/file.zip")!))
        #expect(DownloadPreset.aria2.rule.match == .any)
        // The service dropdown is the whole difference: same catch pattern, another protocol.
        #expect(TorrentService.rTorrent.style == .xmlrpc)
        #expect(TorrentService.aria2.style == .json)
        #expect(TorrentService.motrix.endpoint == "http://127.0.0.1:16800/jsonrpc")
        #expect(TorrentService.custom.endpoint.isEmpty)
    }

    @Test func aDestinationReadsAsASentence() {
        #expect(destination("pdf, epub", folder: "/Users/me/Documents").destinationSentence
                == "Files of type pdf, epub are saved to Documents")
        #expect(destination("pdf", .openFile).destinationSentence == "Files of type pdf open in your Mac’s app")
    }

    /// A file-type Open never offers or performs an app, a script, an installer or an archive. The lookup skips such
    /// a rule, and a later Save rule for the same type still decides where the file lands.
    @Test func anOpenNeverTakesAnAppScriptOrArchive() {
        #expect(DownloadOpening.isRefused("dmg"))
        #expect(DownloadOpening.isRefused("APP"))
        #expect(DownloadOpening.isRefused(""))
        #expect(!DownloadOpening.isRefused("pdf"))
        #expect(DownloadOpening.isRefused(pattern: "pdf, dmg"))

        let url = URL(string: "https://example.com/tool.dmg")!
        var open = destination("dmg", .openFile)
        open.name = "Open"
        #expect(DownloadRulesStore.destination(in: [open], url: url, filename: "tool.dmg") == nil)

        var save = destination("dmg", .saveToFolder, folder: "/tmp")
        save.name = "Save"
        let found = DownloadRulesStore.destination(in: [open, save], url: url, filename: "tool.dmg")
        #expect(found?.rule.name == "Save")
        #expect(found?.destination == .folder("/tmp"))
    }

    /// A file type is named by its extensions, so it needs no name of its own — where an address rule has nothing to
    /// read without one — and only the destination that saves the file needs a folder to save it into.
    @Test func aFileTypeNeedsItsExtensionsAndOnlyAFolderToSaveInto() {
        var save = destination("", .saveToFolder, folder: "")
        #expect(save.pattern.isEmpty)
        #expect(!save.action.isComplete)
        save.pattern = "pdf, epub"
        #expect(!save.action.isComplete)
        save.action.folderPath = "/Users/me/Downloads/PDFs"
        #expect(save.action.isComplete)

        // Opening the file needs nothing more than the type.
        var show = destination("pdf", .openFile)
        show.name = ""
        #expect(show.action.isComplete)
        #expect(show.name.isEmpty)
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
        for preset in [DownloadPreset.aria2, .motrix, .torrents, .ytdlp] {
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

    /// A page that already answered keeps that answer even where no question could be shown: the answer is the
    /// page's, and the tab it was given in may be in the background (or here, in no window at all).
    @Test func aKeptAnswerHoldsWhereNoQuestionCouldShow() async {
        let rule = DownloadRule(name: "aria2", applies: .downloads, match: .contains, pattern: "example.com",
                                action: DownloadRuleAction(kind: .openURL))
        let tab = Tab(url: URL(string: "https://example.com/page")!, title: "Example", spaceID: UUID())
        let origin = "https://example.com"
        let kind = DownloadHandoff.handoffKind(rule)
        let request = DownloadHandoff.Request(url: URL(string: "https://example.com/file.zip")!, pageOrigin: origin)

        tab.permissionAnswers.note("deny", key: origin, kind: kind)
        #expect(await DownloadHandoff.decide(rule, request: request, tab: tab, forDownload: true) == .cancel)
        tab.permissionAnswers.note("handOff", key: origin, kind: kind)
        #expect(await DownloadHandoff.decide(rule, request: request, tab: tab, forDownload: true) == .handOff)
        tab.permissionAnswers.note("browser", key: origin, kind: kind)
        #expect(await DownloadHandoff.decide(rule, request: request, tab: tab, forDownload: true) == .browser)
    }

    /// A page with no site of its own (a file, a data URL) is asked every time: an answer kept against the target's
    /// site must not be borrowed for it.
    @Test func aPageWithNoSiteBorrowsNoAnswer() async {
        let rule = DownloadRule(name: "aria2", applies: .downloads, match: .contains, pattern: "example.com",
                                action: DownloadRuleAction(kind: .openURL))
        let tab = Tab(url: URL(string: "file:///Users/me/page.html")!, title: "File", spaceID: UUID())
        let kind = DownloadHandoff.handoffKind(rule)
        tab.permissionAnswers.note("deny", key: "https://example.com", kind: kind)
        let request = DownloadHandoff.Request(url: URL(string: "https://example.com/file.zip")!)
        #expect(await DownloadHandoff.decide(rule, request: request, tab: tab, forDownload: true) == .browser)
    }

    /// A pop-up may not ask (its window can sit behind the browser's), but a page's kept answer still holds there.
    @Test func aPopupAsksNothingButReadsAKeptAnswer() async {
        let rule = DownloadRule(name: "aria2", applies: .downloads, match: .contains, pattern: "example.com",
                                action: DownloadRuleAction(kind: .openURL))
        let tab = Tab(url: URL(string: "https://example.com/page")!, title: "Example", spaceID: UUID())
        let kind = DownloadHandoff.handoffKind(rule)
        var quiet = DownloadHandoff.Request(url: URL(string: "https://example.com/file.zip")!,
                                            pageOrigin: "https://example.com")
        quiet.mayAsk = false
        #expect(await DownloadHandoff.decide(rule, request: quiet, tab: tab, forDownload: true) == .browser)
        tab.permissionAnswers.note("deny", key: "https://example.com", kind: kind)
        #expect(await DownloadHandoff.decide(rule, request: quiet, tab: tab, forDownload: true) == .cancel)
    }
}
