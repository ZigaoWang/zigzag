import AppKit
import Testing
import WebKit
@testable import Zigzag

/// Pinyin letters committed by a switch to English mid-word land without the input method's spaces, as in Chrome.
@MainActor @Suite(.serialized) struct IMECommitTests {
    nonisolated static let pinyin = IMECommit.Source(id: "com.apple.inputmethod.SCIM.ITABC", languages: ["zh-Hans"])
    nonisolated static let english = IMECommit.Source(id: "com.apple.keylayout.ABC", languages: ["en"])
    nonisolated static let japanese = IMECommit.Source(id: "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese", languages: ["ja"])

    nonisolated struct Case: Sendable, CustomTestStringConvertible {
        var marked: String
        var source: IMECommit.Source?
        var expected: String
        var testDescription: String { "\(marked) with \(source?.id ?? "no source")" }
    }

    nonisolated static let cases = [
        Case(marked: "ni hao", source: pinyin, expected: "nihao"),
        Case(marked: "a b c", source: pinyin, expected: "abc"),
        Case(marked: "ni hao", source: IMECommit.Source(id: "com.sogou.inputmethod.sogou.pinyin", languages: ["zh-Hans"]), expected: "nihao"),
        Case(marked: "ni hao", source: english, expected: "ni hao"),
        Case(marked: "ni hao", source: nil, expected: "ni hao"),
        Case(marked: "ni hao", source: japanese, expected: "ni hao"),
        Case(marked: "你好", source: pinyin, expected: "你好"),
        Case(marked: "ni 好", source: pinyin, expected: "ni 好"),
        Case(marked: "ni, hao", source: pinyin, expected: "ni, hao"),
    ]

    private func using<T>(_ source: IMECommit.Source?, _ body: () async throws -> T) async rethrows -> T {
        let saved = IMECommit.currentSource
        IMECommit.currentSource = { source }
        defer { IMECommit.currentSource = saved }
        return try await body()
    }

    // MARK: Pages

    private final class Loading: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    }

    private struct Page {
        let webView: BrowserWebView
        let window: NSWindow
        var client: NSTextInputClient { webView as NSView as! NSTextInputClient }

        func value() async throws -> String {
            try await webView.evaluateJavaScript("document.getElementById('f').value") as? String ?? ""
        }
    }

    private func page() async throws -> Page {
        let webView = BrowserWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: WKWebViewConfiguration())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        let loading = Loading()
        webView.navigationDelegate = loading
        await withCheckedContinuation { done in
            loading.done = done
            webView.loadHTMLString("<input id=f>", baseURL: URL(string: "https://example.com/"))
        }
        window.makeFirstResponder(webView)
        _ = try await webView.evaluateJavaScript("document.getElementById('f').focus()")
        try await Task.sleep(for: .milliseconds(200))
        return Page(webView: webView, window: window)
    }

    private static let none = NSRange(location: NSNotFound, length: 0)

    private func compose(_ marked: String, in client: NSTextInputClient) async throws {
        for i in 1...marked.count {
            let part = String(marked.prefix(i))
            client.setMarkedText(part, selectedRange: NSRange(location: (part as NSString).length, length: 0), replacementRange: Self.none)
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(100))
    }

    @Test(arguments: cases, [false, true]) func aPageGetsTheLettersCommitted(_ test: Case, unmarking: Bool) async throws {
        let page = try await page()
        defer { page.window.close() }
        try await using(test.source) {
            try await compose(test.marked, in: page.client)
            if unmarking { page.client.unmarkText() } else { page.client.insertText(test.marked, replacementRange: Self.none) }
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(try await page.value() == test.expected)
    }

    /// By the commit the source can already be English; the one that composed decides.
    @Test func aPageKeepsTheSourceThatComposed() async throws {
        let page = try await page()
        defer { page.window.close() }
        try await using(Self.pinyin) { try await compose("ni hao", in: page.client) }
        try await using(Self.english) {
            page.client.unmarkText()
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(try await page.value() == "nihao")
    }

    @Test func typingWithoutMarkedTextIsLeftAlone() async throws {
        let page = try await page()
        defer { page.window.close() }
        try await using(Self.pinyin) {
            page.client.insertText("a b", replacementRange: Self.none)
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(try await page.value() == "a b")
    }

    // MARK: Zigzag's fields

    private final class Host: CommandBarHost {
        let window: NSWindow? = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        let overlay = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        init() { window?.isReleasedWhenClosed = false; window?.contentView = overlay }
        var commandBarOverlay: NSView { overlay }
        var commandBarPageFrame: NSRect { overlay.bounds }
        func commandBarAnchor(asked: NSView?) -> NSView? { asked }
        var commandBarTabs: TabManager? { nil }
        var commandBarProfile: Profile { Profiles.shared.default }
        var commandBarTab: Tab? { nil }
        var commandBarSpace: SpaceInfo? { nil }
        var commandBarIsPrivate: Bool { false }
        func commandBarWillShow() {}
        func commandBarRestoreFocus() {}
        func commandBarOpen(_ kind: CommandResult.Kind, modifiers: NSEvent.ModifierFlags, editing: Bool) -> Bool { true }
        func commandBarDidHide() {}
    }

    @Test(arguments: cases, [false, true]) func theCommandBarGetsTheLettersCommitted(_ test: Case, unmarking: Bool) async throws {
        let host = Host()
        let bar = CommandBarController(host: host)
        bar.show(mode: .newTab)
        defer { bar.dismiss(restoringFocus: false) }
        let editor = try #require(host.window?.firstResponder as? NSTextView)
        try await using(test.source) {
            try await compose(test.marked, in: editor)
            if unmarking { editor.unmarkText() } else { editor.insertText(test.marked, replacementRange: Self.none) }
        }
        #expect(editor.string == test.expected)
        #expect(bar.debugState["field"] as? String == test.expected)
    }

    @Test func theCommandBarKeepsTheSourceThatComposed() async throws {
        let host = Host()
        let bar = CommandBarController(host: host)
        bar.show(mode: .newTab)
        defer { bar.dismiss(restoringFocus: false) }
        let editor = try #require(host.window?.firstResponder as? NSTextView)
        try await using(Self.pinyin) { try await compose("ni hao", in: editor) }
        await using(Self.english) { editor.unmarkText() }
        #expect(editor.string == "nihao")
    }

    @Test func aFieldWithoutMarkedTextIsLeftAlone() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let field = PlainTextField(font: .systemFont(ofSize: 13), placeholder: "Find on page")
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        window.contentView?.addSubview(field)
        window.makeFirstResponder(field)
        let editor = try #require(field.currentEditor() as? NSTextView)
        await using(Self.pinyin) { editor.insertText("a b", replacementRange: Self.none) }
        #expect(field.stringValue == "a b")
        window.close()
    }

    /// A Zigzag field keeps ⌘Z for typing, as the window's own field editor does.
    @Test func aFieldStillUndoesTyping() {
        let editor = IMEFieldEditor.make()
        #expect(editor.allowsUndo)
        #expect(editor.isFieldEditor)
    }
}
