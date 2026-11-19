import AppKit
import Testing
@testable import Zigzag

/// Image files as tab, pinned page or favorite icons (#303).
struct PageImageIconTests {
    private func scratch() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PageImageIconTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func pixels(_ image: NSImage) -> CGImage? {
        image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// The center pixel of a stored icon.
    private func middle(_ image: CGImage) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let rep = NSBitmapImageRep(cgImage: image)
        let c = rep.colorAt(x: image.width / 2, y: image.height / 2)?.usingColorSpace(.sRGB)
        func byte(_ v: CGFloat?) -> UInt8 { UInt8(((v ?? 0) * 255).rounded()) }
        return (byte(c?.redComponent), byte(c?.greenComponent), byte(c?.blueComponent), byte(c?.alphaComponent))
    }

    @Test func anSVGIsKeptAsASquarePNG() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let icon = try await PageImageIcon.store(SafePicturesTests.svg, in: folder)
        #expect(icon.hasPrefix(PageImageIcon.prefix))
        let name = try #require(PageImageIcon.name(of: icon))
        let file = folder.appendingPathComponent(name)
        #expect(PictureFormat.sniff(try Data(contentsOf: file)) == .png)
        let image = try #require(PageImageIcon.image(icon, points: 16, in: folder))
        #expect(image.size == NSSize(width: 16, height: 16))
        let cg = try #require(pixels(image))
        // 24x12 is fit to the width and centered in a square, never stretched.
        #expect(cg.width == PageImageIcon.side && cg.height == PageImageIcon.side)
        let blue = middle(cg)
        #expect(blue.b > 200 && blue.r < 40 && blue.a == 255)
        let corner = NSBitmapImageRep(cgImage: cg).colorAt(x: 0, y: 0)
        #expect((corner?.alphaComponent ?? 1) == 0)
    }

    @Test func aPNGIsKeptNoLargerThanItsSide() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let icon = try await PageImageIcon.store(SafePicturesTests.png(width: 512), in: folder)
        let cg = try #require(PageImageIcon.image(icon, points: 18, in: folder).flatMap(pixels))
        #expect(cg.width == PageImageIcon.side)
        #expect(middle(cg).r > 200)
        // Small images keep their size.
        let small = try await PageImageIcon.store(SafePicturesTests.png(width: 32), in: folder)
        #expect(try #require(PageImageIcon.image(small, points: 16, in: folder).flatMap(pixels)).width == 32)
    }

    @Test func aPDFsFirstPageIsAnIcon() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let icon = try await PageImageIcon.store(SafePicturesTests.pdf(), in: folder)
        #expect(middle(try #require(PageImageIcon.image(icon, points: 16, in: folder).flatMap(pixels))).r > 200)
    }

    @Test func aFileOverTheLimitIsTurnedAway() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        var big = SafePicturesTests.svg
        big.append(Data(repeating: 0x20, count: PageImageIcon.maxBytes))
        await #expect(throws: PageImageIcon.Failure.tooLarge) { try await PageImageIcon.store(big, in: folder) }
        let file = folder.appendingPathComponent("big.svg")
        try big.write(to: file)
        await #expect(throws: PageImageIcon.Failure.tooLarge) { try await PageImageIcon.store(file, in: folder) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["big.svg"])
    }

    @Test func aFileThatIsNoImageIsTurnedAway() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        await #expect(throws: PageImageIcon.Failure.unreadable) { try await PageImageIcon.store(Data("hello, not a picture".utf8), in: folder) }
        await #expect(throws: PageImageIcon.Failure.unreadable) { try await PageImageIcon.store(Data("<svg broken".utf8), in: folder) }
        await #expect(throws: PageImageIcon.Failure.unreadable) { try await PageImageIcon.store(Data(), in: folder) }
        await #expect(throws: PageImageIcon.Failure.unreadable) {
            try await PageImageIcon.store(folder.appendingPathComponent("missing.png"), in: folder)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test func anIconStringNamesOnlyAFileInTheFolder() {
        let name = UUID().uuidString + ".png"
        #expect(PageImageIcon.name(of: "image:" + name) == name)
        #expect(PageImageIcon.name(of: "image:../Library.json") == nil)
        #expect(PageImageIcon.name(of: "image:/etc/passwd") == nil)
        #expect(PageImageIcon.name(of: "image:\(UUID().uuidString).png/../x.png") == nil)
        #expect(PageImageIcon.name(of: name) == nil)
        #expect(!PageImageIcon.isImage("star.fill") && !PageImageIcon.isImage("🍋"))
        #expect(IconChoice.isEmoji("🍋") && !IconChoice.isEmoji("star.fill") && !IconChoice.isEmoji("image:" + name))
    }

    @Test func itShowsAsAChosenIconInItsOwnColors() async throws {
        let icon = try await PageImageIcon.store(SafePicturesTests.png(width: 64))
        defer { PageImageIcon.name(of: icon).map { try? FileManager.default.removeItem(at: PageImageIcon.folder.appendingPathComponent($0)) } }
        let image = IconChoice.pageIcon(icon)
        #expect(IconChoice.isPageIcon(image))
        #expect(!image.isTemplate)
        #expect(IconChoice.pageIcon(icon) === image)
        let tab = Tab(url: URL(string: "https://example.com")!, title: "E", spaceID: UUID())
        tab.customIcon = icon
        #expect(tab.displayIcon === image)
        #expect(Bookmark(url: URL(string: "https://example.com")!, title: "E", icon: icon).displayIcon === image)
        // Switching back to the site icon keeps the file for ⌘Z.
        tab.customIcon = nil
        #expect(tab.displayIcon !== image)
        #expect(PageImageIcon.image(icon, points: 16) != nil)
    }

    @Test func aGoneFileShowsTheGlobe() {
        let icon = "image:\(UUID().uuidString).png"
        #expect(IconChoice.pageIcon(icon) === IconChoice.pageIcon("globe"))
    }

    @Test func pruningKeepsWhatIsStillNamedAndWhatIsNew() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let kept = try await PageImageIcon.store(SafePicturesTests.png(width: 8), in: folder)
        let dropped = try await PageImageIcon.store(SafePicturesTests.png(width: 8), in: folder)
        try Data("not mine".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        let library = Data(#"{"favorites":[{"icon":"\#(kept)"}]}"#.utf8)
        // Created after the run began, so it's kept regardless of saved files.
        PageImageIcon.prune(keepingNamesIn: [library], before: .distantPast, in: folder)
        #expect(PageImageIcon.image(dropped, points: 16, in: folder) != nil)
        PageImageIcon.prune(keepingNamesIn: [library], before: .distantFuture, in: folder)
        #expect(PageImageIcon.image(kept, points: 16, in: folder) != nil)
        #expect(PageImageIcon.image(dropped, points: 16, in: folder) == nil)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("notes.txt").path))
    }
}
