import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Zigzag

/// The empty page: a soft wash of the space's own color, a lighter sidebar, and the picture chosen for it, kept as
/// Zigzag's own copy at the size the screen needs.
struct EmptyPageTests {
    private static let light = NSAppearance(named: .aqua)!
    private static let dark = NSAppearance(named: .darkAqua)!

    private func resolved(_ color: NSColor, _ appearance: NSAppearance) -> NSColor {
        var out = color
        appearance.performAsCurrentDrawingAppearance { out = color.usingColorSpace(.sRGB) ?? color }
        return out
    }

    private func luminance(_ color: NSColor) -> CGFloat { 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent }

    // MARK: The wash

    @Test func aColoredSpaceWashesItsPageInItsOwnHue() {
        for color in SpaceColor.allCases where !color.isNeutral {
            let space = SpaceInfo(name: "S", color: color)
            let ground = EmptyPage.ground(for: space, isPrivate: false)
            for appearance in [Self.light, Self.dark] {
                #expect(resolved(ground, appearance) == resolved(Brand.Theme.of(space).wash, appearance))
            }
            // The sidebar's own family: the wash leans toward the frame's hue, by day and at night.
            for appearance in [Self.light, Self.dark] {
                let wash = resolved(ground, appearance), frame = resolved(space.background, appearance)
                if frame.saturationComponent > 0.05, wash.saturationComponent > 0.01 {
                    let gap = abs(wash.hueComponent - frame.hueComponent)
                    #expect(min(gap, 1 - gap) < 0.08, "\(color) \(appearance.name.rawValue): wash hue \(wash.hueComponent), frame \(frame.hueComponent)")
                }
            }
        }
    }

    @Test func theWashIsALighterSidebarByDayAndDeepAtNight() {
        for color in SpaceColor.allCases where !color.isNeutral {
            let space = SpaceInfo(name: "S", color: color)
            let ground = EmptyPage.ground(for: space, isPrivate: false)
            let day = resolved(ground, Self.light), night = resolved(ground, Self.dark)
            // Lighter than the sidebar by day, never quite white, and calm: hardly any chroma.
            #expect(luminance(day) > luminance(resolved(space.background, Self.light)))
            #expect(luminance(day) < 0.999)
            #expect(day.saturationComponent < 0.12)
            // Deep at night, a step under the sidebar's own deep tint, as dark as a page there: never a bright color.
            #expect(luminance(night) < luminance(resolved(space.background, Self.dark)))
            #expect(night.brightnessComponent < 0.25)
        }
    }

    @Test func neutralSpacesAndPrivateWindowsKeepThePlainCard() {
        #expect(EmptyPage.ground(for: SpaceInfo(name: "W", color: .snow, tint: 0), isPrivate: false) == Tokens.Color.cardBackground)
        #expect(EmptyPage.ground(for: SpaceInfo(name: "G", color: .graphite, tint: 0), isPrivate: false) == Tokens.Color.cardBackground)
        #expect(EmptyPage.ground(for: SpaceInfo(name: "S", color: .sky), isPrivate: true) == Tokens.Color.cardBackground)
        #expect(EmptyPage.ground(for: nil, isPrivate: false) == Tokens.Color.cardBackground)
        var space = SpaceInfo(name: "S", color: .rose)
        space.backgroundImage = "x.jpg"
        #expect(EmptyPage.picture(for: space, isPrivate: false) == "x.jpg")
        #expect(EmptyPage.picture(for: space, isPrivate: true) == nil)
    }

    @Test func aCustomHueWashesInThatHue() {
        var space = SpaceInfo(name: "C", color: .sky)
        space.hue = 0.33
        let day = resolved(EmptyPage.ground(for: space, isPrivate: false), Self.light)
        let frame = resolved(space.background, Self.light)
        let gap = abs(day.hueComponent - frame.hueComponent)
        #expect(min(gap, 1 - gap) < 0.08)
    }

    // MARK: Keeping the picture

    private func scratch() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("EmptyPageTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A plain PNG of `width` by `height` pixels.
    private func picture(width: Int, height: Int, in dir: URL) -> URL {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = dir.appendingPathComponent("source-\(UUID().uuidString).png")
        let out = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(out, context.makeImage()!, nil)
        CGImageDestinationFinalize(out)
        return url
    }

    @Test func keptSizeStillCoversTheScreenAndNeverGrows() {
        let screen = CGSize(width: 3024, height: 1964)
        // A large landscape picture shrinks until its height meets the screen's.
        #expect(SpaceBackground.keptLongestSide(of: CGSize(width: 6000, height: 4000), covering: screen) == 3024)
        // A panorama keeps enough width that its short side still covers the screen's height.
        #expect(SpaceBackground.keptLongestSide(of: CGSize(width: 8000, height: 1000), covering: screen) == 8000)
        #expect(SpaceBackground.keptLongestSide(of: CGSize(width: 12000, height: 3000), covering: screen) == 7856)
        // A small one is kept as it is.
        #expect(SpaceBackground.keptLongestSide(of: CGSize(width: 800, height: 600), covering: screen) == 800)
        #expect(SpaceBackground.keptLongestSide(of: .zero, covering: screen) == 0)
    }

    @Test func storingCopiesAndShrinksThePicture() throws {
        let dir = scratch(), folder = dir.appendingPathComponent("Backgrounds", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = picture(width: 4000, height: 2000, in: dir)
        let id = UUID()
        let name = try #require(SpaceBackground.store(source, for: id, screen: CGSize(width: 1000, height: 800), in: folder))
        #expect(name.hasPrefix(id.uuidString))
        #expect(name.hasSuffix(".jpg"))
        // A copy: the original going away leaves it.
        try FileManager.default.removeItem(at: source)
        #expect(SpaceBackground.isKept(name, in: folder))
        let image = try #require(SpaceBackground.load(name, in: folder))
        // Shrunk so its 2000 high fits 800 high: 1600 by 800, still covering the 1000 wide screen.
        #expect(image.width == 1600)
        #expect(image.height == 800)
    }

    @Test func choosingAgainGivesANewNameAndANonPictureIsRefused() throws {
        let dir = scratch(), folder = dir.appendingPathComponent("Backgrounds", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = picture(width: 200, height: 100, in: dir)
        let id = UUID()
        let first = try #require(SpaceBackground.store(source, for: id, screen: CGSize(width: 100, height: 100), in: folder))
        let second = try #require(SpaceBackground.store(source, for: id, screen: CGSize(width: 100, height: 100), in: folder))
        #expect(first != second)
        let text = dir.appendingPathComponent("notes.txt")
        try "not a picture".write(to: text, atomically: true, encoding: .utf8)
        #expect(SpaceBackground.store(text, for: id, screen: CGSize(width: 100, height: 100), in: folder) == nil)
    }

    @Test func removeDeletesTheCopyAndOnlyIt() throws {
        let dir = scratch(), folder = dir.appendingPathComponent("Backgrounds", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = picture(width: 120, height: 80, in: dir)
        let name = try #require(SpaceBackground.store(source, for: UUID(), screen: CGSize(width: 100, height: 100), in: folder))
        // A name that isn't a plain file in the folder never deletes anything.
        SpaceBackground.remove("../" + source.lastPathComponent, in: folder)
        #expect(FileManager.default.fileExists(atPath: source.path))
        SpaceBackground.remove(name, in: folder)
        #expect(!SpaceBackground.isKept(name, in: folder))
        #expect(SpaceBackground.load(name, in: folder) == nil)
    }

    @Test func pruneKeepsOnlyPicturesASpaceNames() throws {
        let dir = scratch(), folder = dir.appendingPathComponent("Backgrounds", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = picture(width: 120, height: 80, in: dir)
        let kept = try #require(SpaceBackground.store(source, for: UUID(), screen: CGSize(width: 100, height: 100), in: folder))
        let orphan = try #require(SpaceBackground.store(source, for: UUID(), screen: CGSize(width: 100, height: 100), in: folder))
        SpaceBackground.prune(keeping: [kept], in: folder)
        #expect(SpaceBackground.isKept(kept, in: folder))
        #expect(!SpaceBackground.isKept(orphan, in: folder))
    }

    @Test func theSpaceKeepsItsPictureNameThroughSaving() throws {
        var space = SpaceInfo(name: "S", color: .sage)
        space.backgroundImage = "abc.jpg"
        let data = try JSONEncoder().encode(space)
        #expect(try JSONDecoder().decode(SpaceInfo.self, from: data).backgroundImage == "abc.jpg")
        // A library from before has none.
        let older = try JSONDecoder().decode(SpaceInfo.self, from: Data(#"{"id":"\#(UUID().uuidString)","name":"Old","color":"sky","bookmarks":[]}"#.utf8))
        #expect(older.backgroundImage == nil)
    }
}
