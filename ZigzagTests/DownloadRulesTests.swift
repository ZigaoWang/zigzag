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

    /// The link's own parts, so a rule can send an address somewhere else: the host, the path and the query on their
    /// own, exactly as the address has them.
    /// A rule names its script, and a name alone means the scripts folder in your Documents: one place for them, which
    /// is what makes them findable, and a script kept elsewhere is still reachable by its own path.
    @Test func aRuleNamesAScriptInItsOneFolder() {
        let folder = Paths.scripts.standardizedFileURL
        #expect(folder.deletingLastPathComponent().lastPathComponent == "Zigzag")
        #expect(folder.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Documents")
        #expect(folder.lastPathComponent == "Scripts")

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

    /// A script rule's notice says what it is doing while it runs, and how it went when it stops: green when it exited
    /// 0, the script's own last words when it didn't.
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

        // A script that said nothing has nothing to show under the title.
        #expect(ScriptNotice(script: "yt-dlp.sh", state: .failed("   \n")).detail == nil)
    }

    /// The parts of a link on their own, as tokens: a rule can build a new address from the old one's host, path or
    /// query without the whole of it.
    @Test func theLinksOwnPartsAreTokensOfTheirOwn() {
        let values = HandoffValues(link: URL(string: "https://www.google.com/search/deep?a=1&b=two%20words")!)
        let expanded = DownloadTokens.expand("https://www.bing.com{path}?{query}", with: values)
        #expect(expanded == "https://www.bing.com/search/deep?a=1&b=two%20words")
        #expect(DownloadTokens.expand("{host}", with: values) == "www.google.com")
        #expect(DownloadTokens.expand("{path}", with: values) == "/search/deep")
        #expect(DownloadTokens.expand("{query}", with: values) == "a=1&b=two%20words")

        // An address with no path and no query has neither to give, and one with a space in its path keeps the
        // address's own spelling, so what is put back together is still one valid URL.
        let bare = HandoffValues(link: URL(string: "https://example.com")!)
        #expect(DownloadTokens.expand("{host}|{path}|{query}", with: bare) == "example.com||")
        let spaced = HandoffValues(link: URL(string: "https://example.com/a%20b/c")!)
        #expect(DownloadTokens.expand("{path}", with: spaced) == "/a%20b/c")
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

    // MARK: Where a destination puts the file

    /// A folder destination saves into the folder the rule names, under the file's own name; there is nothing to
    /// decide when the folder is empty or has gone, and Zigzag's own showing saves where it always would.
    @Test func aDestinationIsReadAsAPlaceToSave() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zz-dest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let there = DownloadManager.place(for: .folder(folder.path), folder: folder.path, filename: "report.pdf")
        #expect(there?.destination == folder.appendingPathComponent("report.pdf"))
        #expect(there?.show == false, "a folder destination saves, it never opens")

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

        // Show in Zigzag saves where it would have gone anyway, and says to show it once it's here.
        let shown = DownloadManager.place(for: .show, folder: "ignored", filename: "report.pdf")
        #expect(shown?.show == true)
        #expect(shown?.destination.lastPathComponent == "report.pdf")
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

    /// A file type is named by its extensions, so it needs no name of its own — where an address rule has nothing to
    /// read without one — and only the destination that saves the file needs a folder to save it into.
    @Test func aFileTypeNeedsItsExtensionsAndOnlyAFolderToSaveInto() {
        var save = destination("", .saveToFolder, folder: "")
        #expect(DownloadRuleSheet.heldUp(save, all: true).map(\.field) == [.pattern, .action(.folder)])
        save.pattern = "pdf, epub"
        // The folder is what's left holding it, and it is asked for whether or not the pointer is over Add: a folder
        // you haven't reached is still one the rule can't run without.
        #expect(DownloadRuleSheet.heldUp(save, all: false).map(\.field) == [.action(.folder)])
        #expect(DownloadRuleSheet.heldUp(save, all: true).map(\.field) == [.action(.folder)])
        save.action.folderPath = "/Users/me/Downloads/PDFs"
        #expect(DownloadRuleSheet.heldUp(save, all: true).isEmpty)

        // Zigzag showing the file needs nothing more than the type.
        var show = destination("pdf", .showInZigzag)
        show.name = ""
        #expect(DownloadRuleSheet.heldUp(show, all: true).isEmpty)

        // An address rule is still held back by an empty name.
        var address = rule(.contains, "example.com/files")
        address.name = ""
        let held = DownloadRuleSheet.heldUp(address, all: true)
        #expect(held.map(\.field).contains(.name))
        address.name = "Files"
        #expect(!DownloadRuleSheet.heldUp(address, all: true).map(\.field).contains(.name))
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

    // MARK: What a script says back

    /// A script's own output names one action to run in the rule's place, written as the rule's own action JSON. One
    /// level only — a script that named another script would be a way to make one run another — and a destination is
    /// refused too, since it says where a file lands rather than being an action. A refusal is said, not swallowed.
    @Test func aScriptsAnswerNamesOneActionAndNeverAnotherScript() {
        func action(named output: String) -> DownloadRuleAction? {
            if case .action(let action) = ScriptSays.named(in: output) { return action }
            return nil
        }

        var play = DownloadRuleAction(kind: .openApp)
        play.appPath = "/Applications/mpv.app"
        #expect(action(named: #"{"kind":"openApp","appPath":"/Applications/mpv.app"}"#) == play)
        #expect(action(named: #"{"kind":"openURL","urlTemplate":"{link}","openIn":"mini"}"#)?.openIn == .mini)

        var rpc = DownloadRuleAction(kind: .jsonRPC)
        rpc.rpcEndpoint = "http://127.0.0.1:6800/jsonrpc"
        rpc.rpcMethod = "aria2.addUri"
        rpc.rpcParameters = #"[["{link}"]]"#
        #expect(action(named: #"{"kind":"jsonRPC","rpcEndpoint":"http://127.0.0.1:6800/jsonrpc","rpcMethod":"aria2.addUri","rpcParameters":"[[\"{link}\"]]"}"#) == rpc)

        // The two refusals, each said for its own reason.
        #expect(ScriptSays.named(in: #"{"kind":"runScript","scriptPath":"again.sh"}"#) == .refused("A script can’t name another script."))
        #expect(ScriptSays.named(in: #"{"kind":"saveToFolder","folderPath":"/Users/me/Music"}"#) == .refused("A script can’t choose where a download is saved."))
        #expect(ScriptSays.named(in: #"{"kind":"showInZigzag"}"#) == .refused("A script can’t choose where a download is saved."))

        // Saying nothing, or nothing that names an action the handler knows: nothing happens, and the run stands.
        #expect(ScriptSays.named(in: "") == .nothing)
        #expect(ScriptSays.named(in: "downloading…\n   \n") == .nothing)
        #expect(ScriptSays.named(in: #"{"kind":"log","n":3}"#) == .nothing)
        #expect(ScriptSays.named(in: #"{"kind":"nonsense"}"#) == .nothing)
        // A JSON object with no `kind` is not an answer: a script's own JSON must not read as one.
        #expect(ScriptSays.named(in: #"{"appPath":"/Applications/mpv.app"}"#) == .nothing)
        #expect(ScriptSays.named(in: "[1,2,3]") == .nothing)

        // A script may log as it likes, and the first line that names an action is the answer — but a line it may not
        // name ends it there, rather than sliding on to the next one.
        #expect(action(named: "started\n   \n{\"kind\":\"openURL\",\"urlTemplate\":\"{link}\"}\nand some more\n")?.kind == .openURL)
        #expect(ScriptSays.named(in: "{\"kind\":\"runScript\"}\n{\"kind\":\"openApp\",\"appPath\":\"/x\"}")
                == .refused("A script can’t name another script."))
    }

    // MARK: The order the rules are in
    /// A drag in the rules list names the row it was dropped on, not a position, because that list shows only the
    /// handoffs: its numbering leaves the file types out, so a place in it isn't a place in the store. The rule lands
    /// just before the one it was dropped on, and everything else stays where it was — a file type between the two,
    /// included.
    @Test func aRuleMovesToSitBeforeTheOneItWasDroppedOn() {
        let a = rule(.any)
        let b = rule(.any)
        let c = rule(.any)
        let type = destination("pdf")

        func order(_ rules: [DownloadRule]) -> [UUID] { rules.map(\.id) }
        func moved(_ rules: [DownloadRule], _ id: UUID, before: UUID?) -> [UUID] {
            order(DownloadRulesStore.moved(rules, id: id, before: before))
        }

        // Down the list, up the list, and to the end.
        #expect(moved([a, b, c], c.id, before: a.id) == order([c, a, b]))
        #expect(moved([a, b, c], a.id, before: c.id) == order([b, a, c]))
        #expect(moved([a, b, c], a.id, before: nil) == order([b, c, a]))
        // Dropped where it already is, nothing moves: it is already just before that rule.
        #expect(moved([a, b, c], a.id, before: b.id) == order([a, b, c]))
        #expect(moved([a, b, c], b.id, before: c.id) == order([a, b, c]))
        // A file type sitting between them stays where it is: the handoff is placed before its neighbour, not last.
        #expect(moved([a, type, b], b.id, before: a.id) == order([b, a, type]))
        // A rule that isn't in the list it was dropped into leaves the order alone.
        #expect(moved([a, b], c.id, before: a.id) == order([a, b]))
        #expect(moved([], a.id, before: nil) == [])
    }
}

extension DownloadRuleTests {
    @Test func storedHandoffAnswersMapToGates() {
        #expect(DownloadHandoff.gate(stored: "handOff", isPrivate: false) == .handOff)
        #expect(DownloadHandoff.gate(stored: "browser", isPrivate: false) == .browser)
        #expect(DownloadHandoff.gate(stored: "deny", isPrivate: false) == .cancel)
        #expect(DownloadHandoff.gate(stored: nil, isPrivate: false) == .ask)
        #expect(DownloadHandoff.gate(stored: "handOff", isPrivate: true) == .ask)
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
        #expect(await DownloadHandoff.decide(rule, request: request, tab: tab) == .browser)
        #expect(DownloadHandoff.handoffKind(rule) == "handoff:\(rule.id.uuidString)")
    }
}
