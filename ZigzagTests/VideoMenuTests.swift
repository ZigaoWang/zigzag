import AppKit
import Testing
import WebKit
@testable import Zigzag

/// Download Video on a page whose video plays a stream, as OldTwitter's timeline videos do.
@MainActor
struct VideoMenuTests {
    private func made(_ source: String, file: String?) -> BrowserWebView.ContextVideo {
        BrowserWebView.ContextVideo(source: URL(string: source)!, file: file.flatMap(URL.init(string:)))
    }

    /// WebKit's own item already saves a file, so the page's menu is left alone.
    @Test func anMp4IsWebKitsToSave() {
        let video = made("https://video.example/a.mp4", file: "https://video.example/a.mp4")
        #expect(!video.needsOwnItem)
    }

    /// Safari plays the playlist of a timeline video, which WebKit would save as a text file. The page's mp4 is offered.
    @Test func aPlaylistGetsThePagesMp4() {
        #expect(made("https://video.example/a.m3u8?tag=1", file: "https://video.example/b.mp4").needsOwnItem)
    }

    /// A stream with no mp4 listed behind it has no file to save.
    @Test func aPlaylistWithNoMp4GetsNothing() {
        #expect(!made("https://video.example/a.m3u8", file: nil).needsOwnItem)
    }

    /// A blob is played from memory, so the page's mp4 is the file to save.
    @Test func aBlobGetsThePagesMp4() {
        #expect(made("blob:https://x.com/1234", file: "https://video.example/b.mp4").needsOwnItem)
    }

    /// Only a web address is saved, so a page can't point the menu at a file on the Mac.
    @Test func aLocalFileIsNoFileToSave() {
        #expect(!made("https://video.example/a.m3u8", file: "file:///etc/hosts").needsOwnItem)
    }

    private func pageMenu() -> NSMenu {
        let menu = NSMenu()
        for (title, identifier) in [("Play", nil), ("Download Video", "WKMenuItemIdentifierDownloadMedia"),
                                    ("Inspect Element", "WKMenuItemIdentifierInspectElement")] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.identifier = identifier.map { NSUserInterfaceItemIdentifier($0) }
            menu.addItem(item)
        }
        return menu
    }

    private func visibleTitles(_ menu: NSMenu) -> [String] {
        menu.items.filter { !$0.isSeparatorItem && !$0.isHidden }.map(\.title)
    }

    /// A stream's video shows one Download Video, in WebKit's place, and WebKit's own item for the playlist is hidden.
    @Test func aStreamShowsOneDownloadVideo() throws {
        let webView = BrowserWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.contextVideo = made("https://video.example/a.m3u8", file: "https://video.example/b.mp4")
        let menu = pageMenu()
        webView.addDownloadVideo(to: menu)

        #expect(visibleTitles(menu) == ["Play", "Download Video", "Inspect Element"])
        let shown = try #require(menu.items.first { !$0.isHidden && $0.title == "Download Video" })
        #expect(shown.action.map(NSStringFromSelector) == "downloadVideo:")
        #expect(shown.representedObject as? URL == URL(string: "https://video.example/b.mp4"))
        let webKitItem = try #require(menu.items.first { $0.identifier?.rawValue == "WKMenuItemIdentifierDownloadMedia" })
        #expect(webKitItem.isHidden)
        #expect(menu.index(of: shown) + 1 == menu.index(of: webKitItem))
    }

    /// A file's video is WebKit's to save, so the menu keeps WebKit's item and gains nothing.
    @Test func aFileIsLeftToWebKit() {
        let webView = BrowserWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.contextVideo = made("https://video.example/a.mp4", file: "https://video.example/a.mp4")
        let menu = pageMenu()
        webView.addDownloadVideo(to: menu)

        #expect(visibleTitles(menu) == ["Play", "Download Video", "Inspect Element"])
        #expect(menu.items[1].action == nil)
        #expect(webView.contextVideo == nil)
    }
}
