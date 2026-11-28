import AppKit
import Foundation
import Testing
import WebKit
@testable import Zigzag

/// Office and Apple documents in Quick Look, and folders as a list, in a tab (#566).
@MainActor
struct FileViewerTests {
    // MARK: Quick Look

    @Test func aDocxAndXlsxOnYourMacOpenInQuickLook() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let docx = folder.appendingPathComponent("Report.docx")
        try wordDocument().write(to: docx)
        let xlsx = folder.appendingPathComponent("Budget.xlsx")
        try spreadsheet(in: folder).write(to: xlsx)
        for file in [docx, xlsx] {
            let tab = Tab(url: nil, spaceID: UUID())
            defer { tab.close() }
            tab.load(file)
            let viewer = try await previewing(in: tab)
            #expect(viewer.source == file)
            #expect((viewer.preview?.previewItem as? NSURL) as URL? == file)
            #expect(QuickLookPage.source(of: tab.url) == file)
            #expect(tab.shownURL == file)
            #expect(AddressView.name(of: tab.url) == file.lastPathComponent)
            #expect(viewer.data == nil)
            let page = tab.ensureWebView()
            for _ in 0..<100 where page.isLoading || page.title != file.lastPathComponent { try await Task.sleep(for: .milliseconds(50)) }
            #expect(page.title == file.lastPathComponent, "\(String(describing: page.title)) \(String(describing: page.url))")
            #expect(try await page.evaluateJavaScript("document.scripts.length", in: nil, contentWorld: .defaultClient) as? Int == 0)
            #if DEBUG
            #expect(viewer.debugTitles.first == file.lastPathComponent)
            #expect(viewer.debugTitles.contains(String(localized: "Show in Finder", comment: "Button at the top of an Office or Apple document shown in a tab, for a file on the Mac.")))
            #endif
        }
    }

    @Test func aWebDocumentDownloadsThenPreviews() async throws {
        let document = try wordDocument()
        let server = try LocalPageServer { _, path in
            switch path {
            case "/files/report.docx":
                return .init(headers: ["Content-Type": "application/vnd.openxmlformats-officedocument.wordprocessingml.document"], body: document)
            case "/get?id=7":
                return .init(headers: ["Content-Type": "application/octet-stream", "Content-Disposition": "inline; filename=\"Minutes.docx\""], body: document)
            default:
                return .init(status: "404 Not Found", body: Data())
            }
        }
        let site = try await server.start()
        defer { server.stop() }
        for (path, name) in [("/files/report.docx", "report.docx"), ("/get?id=7", "Minutes.docx")] {
            let address = URL(string: site.absoluteString + path)!
            let tab = Tab(url: nil, spaceID: UUID())
            defer { tab.close() }
            tab.load(address)
            let viewer = try await previewing(in: tab)
            #expect(viewer.source == address)
            #expect(tab.shownURL == address)
            #expect(viewer.data == document)
            let copy = try #require(viewer.file)
            #expect(copy.lastPathComponent == name)
            #expect(copy.path.hasPrefix(QuickLookPage.copies.resolvingSymlinksInPath().path) || copy.path.hasPrefix(QuickLookPage.copies.path))
            #expect(try Data(contentsOf: copy) == document)
            // Marked as from the web, as a download is.
            #expect((try copy.resourceValues(forKeys: [.quarantinePropertiesKey])).quarantineProperties != nil)
            #expect((viewer.preview?.previewItem as? NSURL) as URL? == copy)
            // Its copy goes with the viewer.
            tab.load(URL(string: site.absoluteString + "/other")!)
            for _ in 0..<100 where tab.quickLookViewer != nil { try await Task.sleep(for: .milliseconds(50)) }
            #expect(tab.quickLookViewer == nil)
            #expect(!FileManager.default.fileExists(atPath: copy.path))
        }
    }

    @Test func responsesThatOpenInQuickLook() {
        func http(_ path: String, _ mime: String, status: Int = 200, headers: [String: String] = [:]) -> URLResponse {
            HTTPURLResponse(url: URL(string: "https://example.com" + path)!, statusCode: status, httpVersion: "HTTP/1.1",
                            headerFields: ["Content-Type": mime].merging(headers) { $1 })!
        }
        let docx = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        #expect(QuickLookPage.shows(http("/a/Report.docx", docx), isGet: true) == "Report.docx")
        #expect(QuickLookPage.shows(http("/download", docx), isGet: true) == "download.docx")
        #expect(QuickLookPage.shows(http("/sheet.xlsx", "application/octet-stream"), isGet: true) == "sheet.xlsx")
        #expect(QuickLookPage.shows(http("/talk.key", "application/x-iwork-keynote-sffkey"), isGet: true) == "talk.key")
        #expect(QuickLookPage.shows(http("/notes.rtf", "text/rtf"), isGet: true) == "notes.rtf")
        #expect(QuickLookPage.shows(http("/f", "application/octet-stream", headers: ["Content-Disposition": "inline; filename=Plan.pptx"]), isGet: true) == "Plan.pptx")
        // An attachment you asked to download still downloads; so does a form's reply, an error, or anything else.
        #expect(QuickLookPage.shows(http("/Report.docx", docx, headers: ["Content-Disposition": "attachment; filename=Report.docx"]), isGet: true) == nil)
        #expect(QuickLookPage.shows(http("/Report.docx", docx), isGet: false) == nil)
        #expect(QuickLookPage.shows(http("/Report.docx", docx, status: 404), isGet: true) == nil)
        #expect(QuickLookPage.shows(http("/app.zip", "application/zip"), isGet: true) == nil)
        #expect(QuickLookPage.shows(http("/page.html", "text/html"), isGet: true) == nil)
        let big = HTTPURLResponse(url: URL(string: "https://example.com/big.docx")!, statusCode: 200, httpVersion: "HTTP/1.1",
                                  headerFields: ["Content-Type": docx, "Content-Length": String(QuickLookPage.maxBytes + 1)])!
        #expect(QuickLookPage.shows(big, isGet: true) == nil)
        // On your Mac, by name.
        #expect(QuickLookPage.showsFile(URL(fileURLWithPath: "/tmp/a.PAGES")))
        #expect(QuickLookPage.showsFile(URL(fileURLWithPath: "/tmp/a.numbers", isDirectory: true)))
        #expect(!QuickLookPage.showsFile(URL(fileURLWithPath: "/tmp/a.html")))
        #expect(!QuickLookPage.showsFile(URL(string: "https://example.com/a.docx")!))
        // The address names the file, and nothing but a file or the web.
        let page = QuickLookPage.address(for: URL(string: "https://example.com/a%20b/x.docx?token=1&y=2")!, name: "x.docx")
        #expect(QuickLookPage.source(of: page) == URL(string: "https://example.com/a%20b/x.docx?token=1&y=2")!)
        #expect(QuickLookPage.name(of: page) == "x.docx")
        #expect(QuickLookPage.source(of: URL(string: "zigzag://quicklook?url=javascript:alert(1)")!) == nil)
        #expect(!QuickLookPage.name(of: QuickLookPage.address(for: URL(string: "https://example.com/x.docx")!, name: "../../evil.docx")).contains("/"))
        // Its blank page sends the tab nowhere.
        #expect(!FilePages.mayLink(fromHost: QuickLookPage.host, current: page, to: URL(string: "zigzag://settings")!))
    }

    // MARK: Folders

    @Test func aFolderListsSortsAndOpens() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(repeating: 65, count: 3000).write(to: folder.appendingPathComponent("b.txt"))
        try Data(repeating: 65, count: 10).write(to: folder.appendingPathComponent("a.txt"))
        try Data("x".utf8).write(to: folder.appendingPathComponent(".secret"))
        try wordDocument().write(to: folder.appendingPathComponent("c.docx"))
        try Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18)).write(to: folder.appendingPathComponent("d.zip"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Sub", isDirectory: true), withIntermediateDirectories: false)
        try Data("# In sub".utf8).write(to: folder.appendingPathComponent("Sub/inner.md"))

        let tab = Tab(url: nil, spaceID: UUID())
        defer { tab.close() }
        tab.load(folder)
        let page = try await listing(in: tab, folder: folder)
        #expect(tab.shownURL == FolderPage.asFolder(folder))
        #expect(try await ask(page, "document.scripts.length") as? Int == 0)
        #expect(try await names(page) == ["a.txt", "b.txt", "c.docx", "d.zip", "Sub"])
        #expect(try await ask(page, "document.title") as? String == folder.lastPathComponent)

        // Size: largest first, the folder, which has none, last.
        _ = try await ask(page, "document.querySelector('.head a.size').click()")
        try await waitFor(tab) { FolderPage.choice(of: $0).sort == .size }
        _ = try await listing(in: tab, folder: folder)
        let files = ["a.txt", "b.txt", "c.docx", "d.zip"]
        let size = { (name: String) in (try? folder.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        #expect(try await names(page) == files.sorted { size($0) > size($1) } + ["Sub"])
        #expect(try await ask(page, "document.querySelector('.head a.sorted').getAttribute('aria-sort')") as? String == "descending")
        // Name again, then turned around.
        _ = try await ask(page, "document.querySelector('.head a.name').click()")
        try await waitFor(tab) { FolderPage.choice(of: $0).sort == .name }
        _ = try await listing(in: tab, folder: folder)
        _ = try await ask(page, "document.querySelector('.head a.name').click()")
        try await waitFor(tab) { FolderPage.choice(of: $0).descending }
        _ = try await listing(in: tab, folder: folder)
        #expect(try await names(page) == ["Sub", "d.zip", "c.docx", "b.txt", "a.txt"])

        // Hidden files show with the toggle.
        _ = try await ask(page, "document.querySelector('.page-header a.button:last-child').click()")
        try await waitFor(tab) { FolderPage.choice(of: $0).hidden }
        _ = try await listing(in: tab, folder: folder)
        #expect(try await names(page).contains(".secret"))

        // A folder opens its list; a document opens in Quick Look; a file a tab doesn't show opens in Quick Look too.
        _ = try await ask(page, "[...document.querySelectorAll('.row')].find(r => r.textContent.includes('Sub')).click()")
        _ = try await listing(in: tab, folder: folder.appendingPathComponent("Sub", isDirectory: true))
        #expect(try await names(page) == ["inner.md"])
        tab.goBack()
        _ = try await listing(in: tab, folder: folder)
        _ = try await ask(page, "[...document.querySelectorAll('.row')].find(r => r.textContent.includes('c.docx')).click()")
        let document = try await previewing(in: tab)
        #expect(document.source.resolvingSymlinksInPath() == folder.appendingPathComponent("c.docx").resolvingSymlinksInPath())
        tab.goBack()
        _ = try await listing(in: tab, folder: folder)
        _ = try await ask(page, "[...document.querySelectorAll('.row')].find(r => r.textContent.includes('d.zip')).click()")
        let archive = try await previewing(in: tab)
        #expect(archive.source.resolvingSymlinksInPath() == folder.appendingPathComponent("d.zip").resolvingSymlinksInPath())
    }

    @Test func aFolderPageSendsItsTabOnlyToItselfOrItsFiles() {
        let folder = URL(fileURLWithPath: "/tmp/notes", isDirectory: true)
        let page = FolderPage.address(for: folder)
        #expect(FolderPage.source(of: page) == folder)
        #expect(FolderPage.source(of: FolderPage.address(for: URL(fileURLWithPath: "/tmp/notes"))) == folder)
        #expect(FolderPage.source(of: URL(string: "zigzag://folder?url=https://example.com/")!) == nil)
        let sorted = FolderPage.address(for: folder, .init(sort: .date, descending: true, hidden: true))
        #expect(FolderPage.choice(of: sorted) == .init(sort: .date, descending: true, hidden: true))
        #expect(FilePages.mayLink(fromHost: FolderPage.host, current: page, to: sorted))
        #expect(FilePages.mayLink(fromHost: FolderPage.host, current: page, to: QuickLookPage.address(for: folder.appendingPathComponent("a.zip"))))
        #expect(!FilePages.mayLink(fromHost: FolderPage.host, current: page, to: QuickLookPage.address(for: URL(fileURLWithPath: "/etc/a.zip"))))
        #expect(!FilePages.mayLink(fromHost: FolderPage.host, current: page, to: FolderPage.address(for: URL(fileURLWithPath: "/etc"))))
        #expect(!FilePages.mayLink(fromHost: FolderPage.host, current: page, to: URL(string: "zigzag://settings")!))
        // Its folders and the one it's in; a file in it, never one elsewhere.
        #expect(FilePages.mayLink(fromHost: FolderPage.host, current: page, to: FolderPage.address(for: URL(fileURLWithPath: "/tmp/notes/sub"))))
        #expect(FilePages.mayLink(fromHost: FolderPage.host, current: page, to: FolderPage.address(for: URL(fileURLWithPath: "/tmp"))))
        let opening = FolderPage.address(for: folder, opening: URL(fileURLWithPath: "/tmp/notes/a.txt"))
        #expect(FolderPage.opening(opening) == URL(fileURLWithPath: "/tmp/notes/a.txt"))
        #expect(FilePages.mayLink(fromHost: FolderPage.host, current: page, to: opening))
        let escaping = FolderPage.address(for: folder, opening: URL(fileURLWithPath: "/etc/hosts"))
        #expect(FolderPage.opening(escaping) == nil)
        #expect(!FilePages.mayLink(fromHost: FolderPage.host, current: page, to: escaping))
        #expect(FolderPage.opening(FolderPage.address(for: folder, opening: URL(fileURLWithPath: "/tmp/notes/sub/deeper.txt"))) == nil)
        #expect(FilePages.mayLink(fromHost: "history", current: HistoryPage.url, to: URL(string: "zigzag://settings")!))
        #expect(AddressView.name(of: page) == "notes")
        #expect(Tab.route(forPageLink: URL(fileURLWithPath: "/tmp/notes/a.txt"), from: page) == .load)
    }

    // MARK: Pictures

    /// With TEST_RUNNER_ZIGZAG_FILE_VIEWER_SHOTS set to a folder: the viewers in windows of their own, their numbers
    /// in windows.txt, held until a file named done appears, so they can be pictured from outside.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZIGZAG_FILE_VIEWER_SHOTS"] != nil))
    func viewersForPictures() async throws {
        let shots = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ZIGZAG_FILE_VIEWER_SHOTS"]!)
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let docs = folder.appendingPathComponent("Course Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: docs.appendingPathComponent("Week 1", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: docs.appendingPathComponent("Week 2", isDirectory: true), withIntermediateDirectories: true)
        try wordDocument().write(to: docs.appendingPathComponent("Syllabus.docx"))
        try spreadsheet(in: folder).write(to: docs.appendingPathComponent("Grades.xlsx"))
        try Data("# Reading list\n".utf8).write(to: docs.appendingPathComponent("Reading list.md"))
        try Data(repeating: 65, count: 48_000).write(to: docs.appendingPathComponent("Lecture 3.txt"))
        try MarkdownPageTests.pngData.write(to: docs.appendingPathComponent("Diagram.png"))
        try Data("x".utf8).write(to: docs.appendingPathComponent(".DS_Store"))

        var windows: [NSWindow] = []
        var tabs: [Tab] = []
        func show(_ view: NSView, _ size: NSSize, dark: Bool) -> NSWindow {
            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 80 + windows.count * 30, y: 80), size: size),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            view.frame = NSRect(origin: .zero, size: size)
            view.autoresizingMask = [.width, .height]
            window.contentView = NSView(frame: NSRect(origin: .zero, size: size))
            window.contentView?.addSubview(view)
            window.orderFrontRegardless()
            windows.append(window)
            return window
        }
        for (file, size, dark) in [(docs.appendingPathComponent("Syllabus.docx"), NSSize(width: 900, height: 640), false),
                                   (docs.appendingPathComponent("Grades.xlsx"), NSSize(width: 520, height: 640), true)] {
            let tab = Tab(url: nil, spaceID: UUID())
            tabs.append(tab)
            tab.load(file)
            let viewer = try await previewing(in: tab)
            _ = show(viewer, size, dark: dark)
        }
        for (size, dark) in [(NSSize(width: 900, height: 560), false), (NSSize(width: 900, height: 560), true), (NSSize(width: 460, height: 560), false)] {
            let tab = Tab(url: nil, spaceID: UUID())
            tabs.append(tab)
            let page = tab.ensureWebView()
            _ = show(page, size, dark: dark)
            tab.load(docs)
            _ = try await listing(in: tab, folder: docs)
        }
        try await Task.sleep(for: .seconds(2))
        try windows.map { String($0.windowNumber) }.joined(separator: "\n").write(to: shots.appendingPathComponent("windows.txt"), atomically: true, encoding: .utf8)
        let done = shots.appendingPathComponent("done")
        for _ in 0..<1200 where !FileManager.default.fileExists(atPath: done.path) { try await Task.sleep(for: .milliseconds(100)) }
        windows.forEach { $0.close() }
        tabs.forEach { $0.close() }
    }

    // MARK: Helpers

    /// The tab's Quick Look viewer once it shows its file.
    private func previewing(in tab: Tab, seconds: Double = 15) async throws -> QuickLookViewerView {
        for _ in 0..<Int(seconds * 20) where tab.quickLookViewer?.preview == nil { try await Task.sleep(for: .milliseconds(50)) }
        return try #require(tab.quickLookViewer.flatMap { $0.preview != nil ? $0 : nil })
    }

    /// The tab's page once it lists `folder`.
    private func listing(in tab: Tab, folder: URL) async throws -> WKWebView {
        let page = tab.ensureWebView()
        let wanted = FolderPage.asFolder(folder).standardizedFileURL
        for _ in 0..<200 where page.isLoading || FolderPage.source(of: page.url)?.standardizedFileURL != wanted {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(FolderPage.source(of: page.url)?.standardizedFileURL == wanted, "\(String(describing: page.url)) \(String(describing: tab.url))")
        return page
    }

    private func waitFor(_ tab: Tab, _ condition: (URL?) -> Bool) async throws {
        for _ in 0..<100 where !condition(tab.ensureWebView().url) { try await Task.sleep(for: .milliseconds(50)) }
        #expect(condition(tab.ensureWebView().url))
    }

    private func names(_ page: WKWebView) async throws -> [String] {
        try await ask(page, "[...document.querySelectorAll('.row .name span')].map(s => s.textContent)") as? [String] ?? []
    }

    private func ask(_ page: WKWebView, _ script: String) async throws -> Any? {
        try await page.evaluateJavaScript(script, in: nil, contentWorld: .defaultClient)
    }

    private func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FileViewers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.resolvingSymlinksInPath()
    }

    /// A Word document, written by macOS's own converter.
    private func wordDocument() throws -> Data {
        let text = NSAttributedString(string: "Quarterly report\n\nEverything is on track.", attributes: [.font: NSFont.systemFont(ofSize: 14)])
        return try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
    }

    /// The smallest Excel workbook: one sheet, two cells, zipped as Excel does.
    private func spreadsheet(in folder: URL) throws -> Data {
        let parts = folder.appendingPathComponent("xlsx-parts", isDirectory: true)
        let files: [String: String] = [
            "[Content_Types].xml": #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>"#,
            "_rels/.rels": #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>"#,
            "xl/workbook.xml": #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Budget" sheetId="1" r:id="rId1"/></sheets></workbook>"#,
            "xl/_rels/workbook.xml.rels": #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>"#,
            "xl/worksheets/sheet1.xml": #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>Rent</t></is></c><c r="B1"><v>1200</v></c></row></sheetData></worksheet>"#,
        ]
        for (path, text) in files {
            let file = parts.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }
        let zipped = folder.appendingPathComponent("sheet.zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = parts
        zip.arguments = ["-X", "-q", "-r", zipped.path, "[Content_Types].xml", "_rels", "xl"]
        try zip.run()
        zip.waitUntilExit()
        defer { try? FileManager.default.removeItem(at: parts); try? FileManager.default.removeItem(at: zipped) }
        return try Data(contentsOf: zipped)
    }
}
