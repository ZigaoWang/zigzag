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

    /// A rule names its script, and a name alone means the scripts folder in your Documents: one place for them, which
    /// is what makes them findable, and a script kept elsewhere is still reachable by its own path.
    @Test func aRuleNamesAScriptInItsOneFolder() {
        let folder = Paths.scripts.standardizedFileURL
        #expect(folder == Paths.support.appendingPathComponent("Scripts", isDirectory: true).standardizedFileURL)

        // A bare name is in the folder; a path of its own is taken as it stands, `~` and all.
        #expect(Paths.script(named: "yt-dlp.sh").standardizedFileURL == folder.appendingPathComponent("yt-dlp.sh"))
        #expect(Paths.script(named: "/opt/tools/dl.sh").path == "/opt/tools/dl.sh")
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        #expect(Paths.script(named: "~/bin/dl.sh").standardizedFileURL == home.appendingPathComponent("bin/dl.sh"))

        // Picked from the folder, a script is stored by its name, so the rule reads `yt-dlp.sh` and goes on working;
        // picked anywhere else it keeps its path.
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
        #expect(!DownloadHandoff.targetIsOnThisMac(action(.jsonRPC) { $0.rpcEndpoint = "https://seedbox.example/rpc" }, values: values))
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

        // What else runs, loads, or sends the Mac somewhere when opened: location files, web pages, plug-ins,
        // workflows and macro documents.
        for type in ["fileloc", "inetloc", "webloc", "url", "html", "svg", "webarchive", "js", "wflow", "shortcut",
                     "scptd", "plugin", "dylib", "qtz", "jnlp", "class", "ipa", "docm", "xlsm", "term", "tool"] {
            #expect(DownloadOpening.isRefused(type), "\(type) must not open")
        }
        #expect(DownloadOpening.isRefused(pattern: "epub, fileloc"))
        // A type the list doesn't name is still refused when the Mac calls it a script or an archive.
        for type in ["sparseimage", "cpgz", "xar", "phtml", "pyc"] {
            #expect(!DownloadOpening.refused.contains(type))
            #expect(DownloadOpening.isRefused(type), "\(type) must not open")
        }
        // The ordinary documents and media Open is for.
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

        // The same for an installer and a compound archive, both of which the card would otherwise offer.
        let installer = URL(string: "https://example.com/tool.mpkg")!
        let installerOpen = destination("mpkg", .openFile)
        #expect(DownloadRulesStore.destination(in: [installerOpen], url: installer, filename: "tool.mpkg") == nil)
        let archive = URL(string: "https://example.com/bundle.tar.gz")!
        let archiveOpen = destination("tar.gz", .openFile)
        #expect(DownloadRulesStore.destination(in: [archiveOpen], url: archive, filename: "bundle.tar.gz") == nil)
    }

    /// The list has one order: a file type before a catch-all handoff decides, and a refused Open is no match, so a
    /// handoff behind it can still take the file.
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

        // A Save destination still stands in a private window even with its switch off: only Open and handoffs need it.
        var privateCatchAll = catchAll
        privateCatchAll.runsInPrivateWindows = true
        #expect(DownloadRulesStore.firstHandoffMatch(in: [type, privateCatchAll], url: url, filename: "file.pdf",
                                                     appliesToLinks: false, isPrivate: true) == nil)

        // A hand-edited links-and-downloads destination is not a download destination, so it cannot block a handoff.
        var linkDestination = destination("pdf", .saveToFolder, folder: "/tmp")
        linkDestination.applies = .linksAndDownloads
        linkDestination.name = "Link destination"
        #expect(DownloadRulesStore.firstHandoffMatch(in: [linkDestination, catchAll], url: url, filename: "file.pdf",
                                                     appliesToLinks: false)?.name == "Catch-all")
    }

    /// The last word on Open: an app, a script, an installer, an archive or a file with no type is saved, while a PDF
    /// may open.
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

        // Added that way, a type behind a downloader preset's catch-all still decides its own files.
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

    // MARK: Where an Open URL rule opens

    /// Which addresses are Zigzag's own to open, and which belong to the app that handles them. Only the web's own
    /// are Zigzag's: what you build a rule for to reach mpv or IINA must still reach mpv or IINA.
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

    /// A new rule asks where to open; a rule from before the choice existed keeps opening in the Mac's default
    /// browser, which is what every Open URL rule did before Zigzag had places of its own.
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

        // An older file has no openIn at all: those rules went to the default browser, and still do.
        // Taken out of the object itself: JSONEncoder's key order isn't fixed, so the text may not have a comma before it.
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
        // The pop-up question's "deny", and the viewer it keeps under that name, are not places to open in, so an
        // answer of those leaves the rule asking rather than taking a value it doesn't know.
        #expect(OpenInZigzag.Place(rawValue: "deny") == nil)
        #expect(OpenInZigzag.Place(rawValue: "viewer") == nil)
        #expect(OpenInZigzag.Place(rawValue: "") == nil)
        #expect(OpenInZigzag.Place.allCases.allSatisfy { !$0.title.isEmpty })

        // A rule's own choice adds Ask and the Mac's default browser, but the question only offers destinations.
        #expect(OpenInZigzag.Choice.allCases.map(\.rawValue) == ["ask", "defaultBrowser", "thisTab", "newTab", "mini"])
        #expect(OpenInZigzag.Choice.destinations.map(\.rawValue) == ["defaultBrowser", "thisTab", "newTab", "mini"])
        #expect(OpenInZigzag.Choice.ask.place == nil)
        #expect(OpenInZigzag.Choice.defaultBrowser.place == nil)
        #expect(OpenInZigzag.Choice.mini.place == .mini)
        #expect(OpenInZigzag.Choice.allCases.allSatisfy { !$0.title.isEmpty })
    }

    /// An Open URL rule that opens the web's own address still needs nothing but that address: where it opens has an
    /// answer from the moment the rule exists (Zigzag asks), so it can never hold Add back.
    @Test func whereAWebAddressOpensNeverHoldsTheRuleBack() {
        var action = DownloadRuleAction(kind: .openURL)
        #expect(!action.isComplete)
        action.urlTemplate = "https://example.com/{filename}"
        #expect(action.isComplete)
        #expect(DownloadRuleSheet.actionHoldUp(action) == nil)
        #expect(action.openIn == .ask)
        // Nothing to answer about where it opens, so the only thing a rule could be held up by is what it catches.
        var mine = DownloadRule(name: "Mirror", match: .any, action: action)
        #expect(DownloadRuleSheet.heldUp(mine, all: true).isEmpty)
        mine.action.openIn = .newTab
        #expect(DownloadRuleSheet.heldUp(mine, all: true).isEmpty)
    }

    // MARK: The place the hand-off card asks for

    /// The hand-off card asks where its web address opens only when the rule hasn't been told, and it is answered in a
    /// hurry: the dropdown's first entry is the answer a press of Hand Off sends without the dropdown being touched.
    /// That entry is This Tab, which keeps the link inside Zigzag; the Mac's browser is still offered. The separate
    /// "Where should this open" question and the rule sheet keep their order — the browser first — because they are
    /// about a rule, not about this one hand-off.
    @Test func theHandOffCardStartsWithThisTabInZigzag() {
        #expect(DownloadHandoff.cardPlaces.map(\.rawValue) == ["thisTab", "defaultBrowser", "newTab", "mini"])
        #expect(DownloadHandoff.cardPlaces.first == .thisTab)
        // The first entry is what the card's dropdown starts on: `DropdownButton` selects index 0 until it is touched,
        // and the card reads the selected entry when Hand Off is pressed.
        let dropdown = DropdownButton()
        dropdown.options = DownloadHandoff.cardPlaces.map { DropdownButton.Option(title: $0.title) }
        #expect(dropdown.selectedIndex == 0)
        #expect(dropdown.options.first?.title == OpenInZigzag.Choice.thisTab.title)
        // The question the rule itself asks, and the sheet, are unchanged: the browser is the first destination
        // offered, and Ask is still the sheet's first choice.
        #expect(OpenInZigzag.Choice.destinations.map(\.rawValue) == ["defaultBrowser", "thisTab", "newTab", "mini"])
        #expect(OpenInZigzag.Choice.allCases.map(\.rawValue) == ["ask", "defaultBrowser", "thisTab", "newTab", "mini"])
    }

    /// A place picked in the hand-off card opens that hand-off and nothing else: the rule is left exactly as it was,
    /// so a rule that hadn't been told (`.ask`) is still asking next time.
    @Test func aCardsPlaceOpensOneHandOffAndNeverBecomesTheRules() {
        var rule = DownloadRule(name: "Mirror", applies: .linksAndDownloads, match: .contains, pattern: "example.com",
                                action: DownloadRuleAction(kind: .openURL))
        rule.action.urlTemplate = "https://mirror.example.com/{filename}"
        #expect(rule.action.openIn == .ask)

        let request = DownloadHandoff.Request(url: URL(string: "https://example.com/a.zip")!, place: .thisTab)
        #expect(DownloadHandoff.opening(rule, at: request.place) == .thisTab, "this hand-off opens where the card says")
        #expect(DownloadHandoff.ruleToKeep(rule, choice: .thisTab, always: false) == nil, "nothing is written on the rule")
        #expect(rule.action.openIn == .ask, "and the rule is still asking")

        // Told in its sheet, the rule opens there without a card, and a card's place still overrides this one only.
        var told = rule
        told.action.openIn = .mini
        #expect(DownloadHandoff.opening(told, at: nil) == .mini)
        #expect(DownloadHandoff.opening(told, at: .newTab) == .newTab)
        #expect(told.action.openIn == .mini)
    }

    /// The separate question's two answers: Always keeps the place on the rule, Once opens it there and leaves the rule
    /// asking. The answer is a rule to save, never a rule changed in place — the caller writes it.
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

    /// Everything holding a rule's Add button back, in the order the form is filled in: the button's own words and the
    /// fields it marks come from this one list, so the two can never disagree.
    @Test func aRuleSaysEverythingHoldingAddBack() {
        var mine = rule(.contains, "")
        mine.name = ""
        #expect(DownloadRuleSheet.heldUp(mine, all: true).map(\.field) == [.name, .pattern, .action(.url)])

        // While you type, only what you have already filled in wrong is said: a pattern you haven't reached isn't.
        mine.name = "Torrents"
        #expect(DownloadRuleSheet.heldUp(mine, all: false).map(\.field) == [.action(.url)])
        #expect(DownloadRuleSheet.heldUp(mine, all: true).map(\.field) == [.pattern, .action(.url)])

        mine.pattern = "torrent"
        mine.action.urlTemplate = "mpd://{link}"
        #expect(DownloadRuleSheet.heldUp(mine, all: true).isEmpty)

        // A broken expression is worth saying whether or not you are hovering.
        mine.match = .regex
        mine.pattern = "(["
        #expect(DownloadRuleSheet.heldUp(mine, all: false).map(\.field) == [.pattern])

        // An `any` rule needs no pattern at all.
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
        #expect(await DownloadHandoff.decide(rule, request: request, tab: tab, forDownload: true).gate == .cancel)
        tab.permissionAnswers.note("handOff", key: origin, kind: kind)
        #expect(await DownloadHandoff.decide(rule, request: request, tab: tab, forDownload: true).gate == .handOff)
        tab.permissionAnswers.note("browser", key: origin, kind: kind)
        #expect(await DownloadHandoff.decide(rule, request: request, tab: tab, forDownload: true).gate == .browser)
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
        #expect(await DownloadHandoff.decide(rule, request: request, tab: tab, forDownload: true).gate == .browser)
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
        #expect(await DownloadHandoff.decide(rule, request: quiet, tab: tab, forDownload: true).gate == .browser)
        tab.permissionAnswers.note("deny", key: "https://example.com", kind: kind)
        #expect(await DownloadHandoff.decide(rule, request: quiet, tab: tab, forDownload: true).gate == .cancel)
    }

    // MARK: The App field's menu

    /// The App field lists what's in the Applications folders, **one level deep**: bundles only, each once, in the
    /// order a person expects. Anything else stays one Choose an App… away.
    @Test func theAppMenuListsApplicationsOneLevelDeep() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("apps-\(UUID().uuidString)")
        let mac = root.appendingPathComponent("Mac"), mine = root.appendingPathComponent("Mine")
        try FileManager.default.createDirectory(at: mac.appendingPathComponent("Zeta.app"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mine.appendingPathComponent("Alpha.app"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Not a bundle: never offered.
        try Data().write(to: mine.appendingPathComponent("notes.txt"))
        // A bundle inside a bundle: this reads one level, never into Contents.
        try FileManager.default.createDirectory(at: mac.appendingPathComponent("Zeta.app/Contents/PlugIns/Inner.app"),
                                                withIntermediateDirectories: true)

        // The same folder twice is still one entry, and the order is the names'.
        let named = Applications.named(in: [mac.path, mine.path, mine.path])
        #expect(named.map(\.name) == ["Alpha", "Zeta"])
        #expect(named.first?.path == mine.appendingPathComponent("Alpha.app").path)
    }

    // MARK: A rule that can't be saved yet

    /// The field a rule's action still needs something in, which its sheet marks so a greyed Add button says which
    /// one is holding it up. The plainest case is an address with no scheme: `bing.com` parses, but nothing could
    /// open it, so the rule isn't complete and the address field is the one to fill.
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
}

extension DownloadRuleTests {
    @Test func storedHandoffAnswersMapToGates() {
        #expect(DownloadHandoff.gate(stored: "handOff") == .handOff)
        #expect(DownloadHandoff.gate(stored: "browser") == .browser)
        #expect(DownloadHandoff.gate(stored: "deny") == .cancel)
        #expect(DownloadHandoff.gate(stored: nil) == .browser)
    }

    /// A handoff answered "Always on this site" is kept for the site and read back without asking again, in any page
    /// of that site. The rule's own answer travels with the rule, so a private window still reads it.
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

    /// The third scope: a rule answered for itself stands for every site. A private window still refuses a rule that
    /// was not let in there, and once it is, reads the rule's own answer, which belongs to the rule rather than to the
    /// site the session is on.
    @MainActor @Test func aRulesOwnAnswerStandsForEverySite() async {
        var rule = DownloadRule(name: "Files", applies: .downloads, match: .contains, pattern: "file.zip",
                                action: DownloadRuleAction(kind: .openURL))
        let request = DownloadHandoff.Request(url: URL(string: "https://cdn.example/file.zip")!,
                                              referrer: URL(string: "https://site.example/page")!,
                                              pageOrigin: "https://site.example")
        // Never told: with no window to ask in, the rule simply doesn't run.
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

    /// The site's answer is the more specific one, so it outranks the rule's own; the rule's is still saved with the
    /// rule, so it travels with it.
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

    /// The rule's own answer is saved with the rule, so it travels with it; a rule with none reads as none.
    @Test func aRulesOwnAnswerSurvivesItsJSON() throws {
        var rule = DownloadRule(name: "Files", applies: .downloads, match: .contains, pattern: "zip",
                                action: DownloadRuleAction(kind: .openURL))
        #expect(try JSONDecoder().decode(DownloadRule.self, from: JSONEncoder().encode(rule)).handoffAnswer == nil)
        rule.handoffAnswer = "handOff"
        let read = try JSONDecoder().decode(DownloadRule.self, from: JSONEncoder().encode(rule))
        #expect(read.handoffAnswer == "handOff")
    }

    /// The third duration choice names the rule, and says "this rule" where the rule has no name rather than "".
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
    /// A handoff answered "Open in Browser" this time holds for the page, so the download the same page starts is not
    /// asked the same question again.
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

/// What saving a rule does to the answers it kept: a different script or URL is a different rule's behaviour, while
/// its name or another field leaves the answers where they are.
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

    /// A rules file of its own, so a test never reads or writes the Mac's own list.
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
            // Another rule's answers, and this rule's own row, are not touched.
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
            // A field of the action that isn't the script or the URL — `openIn`'s place in a later build — is not a
            // change of what runs.
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
