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
        #expect(DownloadTokens.filename(for: file, suggested: "../evil/name") == "-evil-name")
        #expect(DownloadTokens.filename(for: file, suggested: ".hidden") == "hidden")
        #expect(!DownloadTokens.filename(for: file, suggested: "a\u{0}b").contains("\u{0}"))
        #expect(DownloadTokens.filename(for: URL(string: "https://example.com/")!, suggested: "") == "example.com")
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
        let books = destination("pdf, epub", .showInZigzag)
        #expect(DownloadRulesStore.destination(in: [pdf, books], url: file, filename: "a.pdf")?.destination == .folder("/Users/me/Documents"))
        #expect(DownloadRulesStore.destination(in: [books, pdf], url: file, filename: "a.pdf")?.destination == .show)
        #expect(DownloadRulesStore.destination(in: [rule(.fileType, "pdf")], url: file, filename: "a.pdf") == nil)
        #expect(DownloadRulesStore.destination(in: [], url: file, filename: "a.pdf") == nil)
        #expect(DownloadRulesStore.destination(in: [destination("pdf")], url: file, filename: "a.epub") == nil)
        #expect(DownloadRulesStore.destination(in: [destination("pdf", enabled: false)], url: file, filename: "a.pdf") == nil)
    }

    /// A destination is a destination, and needs what it needs: a folder to save into, nothing to be shown by Zigzag.
    @Test func aDestinationSaysWhatItIsAndNeedsItsFolder() {
        #expect(DownloadRuleAction.Kind.saveToFolder.isDestination)
        #expect(DownloadRuleAction.Kind.showInZigzag.isDestination)
        #expect(!DownloadRuleAction.Kind.openURL.isDestination)
        #expect(!DownloadRuleAction.Kind.runScript.isDestination)

        var folder = DownloadRuleAction(kind: .saveToFolder)
        #expect(!folder.isComplete)
        #expect(DownloadRuleSheet.actionHoldUp(folder)?.field == .folder)
        folder.folderPath = "/Users/me/Documents"
        #expect(folder.isComplete)
        #expect(DownloadRuleSheet.actionHoldUp(folder) == nil)
        #expect(DownloadRuleAction(kind: .showInZigzag).isComplete)
    }

    @Test func aDestinationReadsAsASentence() {
        #expect(destination("pdf, epub", folder: "/Users/me/Documents").summarySentence
                == "Files of type pdf, epub are saved to Documents")
        #expect(destination("pdf", .showInZigzag).summarySentence == "Files of type pdf open in Zigzag")
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

    /// A rule that hasn't been told where to open keeps nothing, and one that has keeps it across its file. The ids
    /// are the pop-up question's own ("thisTab", "newTab", "mini"), so an answer that question returns is one a rule
    /// can be given, and a value from anywhere else is not a place at all.
    @Test func aRuleRemembersWhereItsWebAddressOpens() throws {
        var rule = DownloadRule(name: "Mirror", applies: .linksAndDownloads, match: .contains, pattern: "example.com",
                                action: DownloadRuleAction(kind: .openURL))
        rule.action.urlTemplate = "https://mirror.example.com/{filename}"
        #expect(rule.action.openIn == nil)

        let plain = try JSONEncoder().encode([rule])
        #expect(!String(decoding: plain, as: UTF8.self).contains("openIn"))
        let told = try JSONDecoder().decode([DownloadRule].self, from: plain)
        #expect(told == [rule])
        #expect(told.first?.action.openIn == nil)

        rule.action.openIn = .mini
        let data = try JSONEncoder().encode([rule])
        let again = try JSONDecoder().decode([DownloadRule].self, from: data)
        #expect(again == [rule])
        #expect(again.first?.action.openIn == .mini)
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
    }

    /// An Open URL rule that opens the web's own address still needs nothing but that address: where it opens has an
    /// answer from the moment the rule exists (Zigzag asks), so it can never hold Add back.
    @Test func whereAWebAddressOpensNeverHoldsTheRuleBack() {
        var action = DownloadRuleAction(kind: .openURL)
        #expect(!action.isComplete)
        action.urlTemplate = "https://example.com/{filename}"
        #expect(action.isComplete)
        #expect(DownloadRuleSheet.actionHoldUp(action) == nil)
        #expect(action.openIn == nil)
        // Nothing to answer about where it opens, so the only thing a rule could be held up by is what it catches.
        var mine = DownloadRule(name: "Mirror", match: .any, action: action)
        #expect(DownloadRuleSheet.heldUp(mine, all: true).isEmpty)
        mine.action.openIn = .newTab
        #expect(DownloadRuleSheet.heldUp(mine, all: true).isEmpty)
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
        #expect(decoded.first?.stopsThePage == false)
        #expect(decoded.first?.action.kind == .openURL)
    }

    /// A rule lets the page it took a link from go on loading unless it is told not to, and being told survives the
    /// file it's saved in.
    @Test func aRuleLetsThePageGoOnUntilItIsToldNotTo() throws {
        var rule = DownloadRule(name: "Whole site", match: .any, action: DownloadRuleAction(kind: .openURL))
        rule.action.urlTemplate = "https://example.com/{link}"
        #expect(rule.stopsThePage == false)

        rule.stopsThePage = true
        let data = try JSONEncoder().encode([rule])
        let decoded = try JSONDecoder().decode([DownloadRule].self, from: data)
        #expect(decoded.first?.stopsThePage == true)
        #expect(decoded.first?.stopsThePage == rule.stopsThePage)
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
