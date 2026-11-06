import AppKit

/// About Zigzag › Acknowledgments: Zigzag's own license and marks, then every work by others that ships in the app,
/// each with its license, then the Apache License in full. Read from the files the repository keeps (LICENSE and
/// THIRD_PARTY_NOTICES.md), bundled as they are, so what the app says is what the source says, offline.
final class AcknowledgementsWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: AcknowledgementsWindowController?

    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let shared {
            shared.window?.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Tokens.Welcome.acknowledgementsSize),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        window.title = "Acknowledgments"
        // The page says its own name, large, as About does.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 420, height: 320)
        window.backgroundColor = Tokens.Color.formBackground
        window.contentView = AcknowledgementsView(frame: NSRect(origin: .zero, size: Tokens.Welcome.acknowledgementsSize))
        window.center()
        let controller = AcknowledgementsWindowController(window: window)
        window.delegate = controller
        shared = controller
        controller.showWindow(nil)
    }

    func windowWillClose(_ notification: Notification) { Self.shared = nil }
}

private final class AcknowledgementsView: NSView {
    private let scroll = NSScrollView()
    private let text = NSTextView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.autoresizingMask = [.width, .height]
        // Clear of the title bar, which the content runs under.
        scroll.frame = NSRect(x: 0, y: 0, width: frame.width, height: frame.height - Tokens.Space.x8)
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: Tokens.Space.x8, height: Tokens.Space.x6)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.linkTextAttributes = [.foregroundColor: Tokens.Color.accent, .cursor: NSCursor.pointingHand]
        text.textStorage?.setAttributedString(Acknowledgements.text())
        scroll.documentView = text
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// The acknowledgements as styled text.
enum Acknowledgements {
    static func text() -> NSAttributedString {
        let out = NSMutableAttributedString()
        let style = NoticeStyle()
        out.append(style.title("Acknowledgments"))
        out.append(style.paragraph("Zigzag is made by Zigao Wang and is open source under the Apache License, Version 2.0. "
                                   + "It builds on the work of others, listed below with their licenses. Thank you."))

        // What NOTICE and TRADEMARKS.md say, in a sentence each.
        out.append(style.heading("Zigzag", level: 2))
        out.append(style.paragraph("Copyright \(Calendar.current.component(.year, from: Date())) Zigao Wang. The code is licensed under the "
                                   + "Apache License, Version 2.0, in full at the end."))
        out.append(style.paragraph("The Zigzag name, the app icon and the logo are trademarks of Zigao Wang, all rights reserved. "
                                   + "They aren’t covered by the Apache License: see [TRADEMARKS.md](TRADEMARKS.md)."))

        // The works shipped in the app, and the note on names and marks; what's only used to build or test stays in
        // the repository's copy.
        if let notices = bundled("THIRD_PARTY_NOTICES", "md") {
            let shown = sections(of: notices, keeping: ["Shipped in the app", "Names and marks"])
                .replacingOccurrences(of: "## Shipped in the app", with: "## Works by others")
            out.append(style.markdown(shown))
        }

        if let license = bundled("LICENSE", "") {
            out.append(style.heading("Apache License, Version 2.0", level: 2))
            out.append(style.code(license.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return out
    }

    private static func bundled(_ name: String, _ ext: String) -> String? {
        Bundle.main.url(forResource: name, withExtension: ext.isEmpty ? nil : ext).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    /// The `## ` sections named, in order, with what's under each.
    static func sections(of markdown: String, keeping names: [String]) -> String {
        var kept: [String] = [], keeping = false
        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("## ") { keeping = names.contains(String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)) }
            if keeping { kept.append(line) }
        }
        return kept.joined(separator: "\n")
    }
}

/// The notices' look: the app's type, headings a step apart, license texts in a quiet monospaced block, links in the
/// accent. Only what the notices use of Markdown: headings, paragraphs, lists, fenced blocks, `code` and links.
private struct NoticeStyle {
    private let body = Tokens.Font.body()
    private let mono = NSFont.monospacedSystemFont(ofSize: Tokens.TypeSize.small, weight: .regular)

    private func paragraphStyle(before: CGFloat, after: CGFloat, indent: CGFloat = 0) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = before
        p.paragraphSpacing = after
        p.lineSpacing = 2
        p.headIndent = indent
        return p
    }

    func title(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text + "\n", attributes: [.font: Tokens.Font.voice(Tokens.TypeSize.title + 6),
                                                             .foregroundColor: Tokens.Color.textPrimary,
                                                             .paragraphStyle: paragraphStyle(before: 0, after: Tokens.Space.x3)])
    }

    func heading(_ text: String, level: Int) -> NSAttributedString {
        let size = level <= 2 ? Tokens.TypeSize.title : Tokens.TypeSize.heading
        return NSAttributedString(string: text + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: Tokens.Color.textPrimary,
            .paragraphStyle: paragraphStyle(before: level <= 2 ? Tokens.Space.x6 : Tokens.Space.x4, after: Tokens.Space.x2)])
    }

    func paragraph(_ text: String, indent: CGFloat = 0) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: inline(text))
        out.append(NSAttributedString(string: "\n"))
        out.addAttribute(.paragraphStyle, value: paragraphStyle(before: 0, after: Tokens.Space.x2, indent: indent),
                         range: NSRange(location: 0, length: out.length))
        return out
    }

    /// A license's own text, its lines as written: no space between them, room before and after the whole.
    func code(_ text: String) -> NSAttributedString {
        let out = NSMutableAttributedString(string: text + "\n", attributes: [.font: mono, .foregroundColor: Tokens.Color.textSecondary,
                                                                               .paragraphStyle: paragraphStyle(before: 0, after: 0)])
        out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: Tokens.Space.x2)]))
        return out
    }

    /// `code` and [links](https://…) inside a line.
    private func inline(_ text: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let plain: [NSAttributedString.Key: Any] = [.font: body, .foregroundColor: Tokens.Color.textSecondary]
        let pattern = try! NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^)\s]+)\)|`([^`]+)`"#)
        var at = text.startIndex
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            out.append(NSAttributedString(string: String(text[at..<range.lowerBound]), attributes: plain))
            if let label = Range(match.range(at: 1), in: text), let target = Range(match.range(at: 2), in: text) {
                var link = plain
                // A link to a file in the repository goes to it on GitHub.
                let href = String(text[target])
                link[.link] = URL(string: href.contains("://") ? href : "https://github.com/ZigaoWang/zigzag/blob/main/" + href)
                out.append(NSAttributedString(string: String(text[label]), attributes: link))
            } else if let code = Range(match.range(at: 3), in: text) {
                out.append(NSAttributedString(string: String(text[code]), attributes: [.font: mono, .foregroundColor: Tokens.Color.textSecondary]))
            }
            at = range.upperBound
        }
        out.append(NSAttributedString(string: String(text[at...]), attributes: plain))
        return out
    }

    func markdown(_ source: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var paragraph: [String] = [], fence: [String]?
        func flush() {
            guard !paragraph.isEmpty else { return }
            out.append(self.paragraph(paragraph.joined(separator: " ")))
            paragraph = []
        }
        for line in source.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if let open = fence { out.append(code(open.joined(separator: "\n"))); fence = nil } else { flush(); fence = [] }
                continue
            }
            if fence != nil { fence?.append(line); continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { flush(); continue }
            if let level = ["### ": 3, "## ": 2, "# ": 1].first(where: { trimmed.hasPrefix($0.key) }) {
                flush()
                out.append(heading(String(trimmed.dropFirst(level.key.count)), level: level.value))
            } else if trimmed.hasPrefix("- ") {
                flush()
                out.append(self.paragraph("•  " + trimmed.dropFirst(2), indent: Tokens.Space.x4))
            } else {
                paragraph.append(trimmed)
            }
        }
        flush()
        return out
    }
}
