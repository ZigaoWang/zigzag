import AppKit
import Carbon

/// Drops the spaces a pinyin input method puts between syllables when it commits them as letters, as Chrome does.
nonisolated enum IMECommit {
    struct Source: Equatable, Sendable {
        var id: String
        var languages: [String]

        /// A pinyin input method (Pinyin or Shuangpin, Apple's or a third party's), whose marked letters carry spaces.
        var isPinyin: Bool {
            Self.applePinyin.contains(id) || (!id.hasPrefix("com.apple.") && id.lowercased().contains("pinyin"))
        }

        /// Apple's pinyin modes; Zhuyin, Cangjie, Wubi and Stroke aren't.
        static let applePinyin: Set<String> = [
            "com.apple.inputmethod.SCIM.ITABC", "com.apple.inputmethod.SCIM.Shuangpin",
            "com.apple.inputmethod.TCIM.Pinyin", "com.apple.inputmethod.TCIM.Shuangpin",
        ]
    }

    /// The keyboard input source in use; tests put their own in.
    nonisolated(unsafe) static var currentSource: () -> Source? = systemSource

    /// `text` as it should land: the spaces gone from letters a pinyin input method commits from its marked text.
    static func cleaned(_ text: String, composing: Bool, source: Source?) -> String {
        guard composing, source?.isPinyin == true, isSpacedLetters(text) else { return text }
        return text.replacingOccurrences(of: " ", with: "")
    }

    /// `cleaned` for what `insertText` is given, a String or an attributed one.
    static func cleaned(_ text: Any, composing: Bool, source: Source?) -> Any {
        let plain = (text as? String) ?? (text as? NSAttributedString)?.string
        guard let plain else { return text }
        let result = cleaned(plain, composing: composing, source: source)
        return result == plain ? text : result
    }

    /// Only ASCII letters with single spaces between them, as in "ni hao".
    private static func isSpacedLetters(_ text: String) -> Bool {
        let words = text.split(separator: " ", omittingEmptySubsequences: false)
        return words.count > 1 && words.allSatisfy { word in
            !word.isEmpty && word.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("A"..."Z").contains($0) }
        }
    }

    private static func systemSource() -> Source? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        func property(_ key: CFString) -> AnyObject? {
            TISGetInputSourceProperty(source, key).map { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() }
        }
        let id = (property(kTISPropertyInputModeID) as? String) ?? (property(kTISPropertyInputSourceID) as? String) ?? ""
        return Source(id: id, languages: property(kTISPropertyInputSourceLanguages) as? [String] ?? [])
    }
}

/// The field editor of Zigzag's own text fields, which commits pinyin letters as `IMECommit` says.
final class IMEFieldEditor: NSTextView {
    private var composingSource: IMECommit.Source?

    /// Set up as the window's own field editor is.
    static func make() -> IMEFieldEditor {
        let editor = IMEFieldEditor()
        editor.isFieldEditor = true
        // ⌘Z in a field undoes typing, as the window's own field editor does.
        editor.allowsUndo = true
        editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.containerSize = NSSize(width: 9_000_000, height: 9_000_000)
        editor.textContainer?.lineFragmentPadding = 2
        return editor
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if !hasMarkedText() { composingSource = IMECommit.currentSource() }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let range = markedRange()
        let plain = (string as? String) ?? (string as? NSAttributedString)?.string
        // Only the marked letters themselves, committed: never dictation or a text replacement.
        let composing = hasMarkedText() && range.location != NSNotFound && NSMaxRange(range) <= (self.string as NSString).length
            && plain == (self.string as NSString).substring(with: range)
        let text = IMECommit.cleaned(string, composing: composing, source: composingSource ?? IMECommit.currentSource())
        composingSource = nil
        super.insertText(text, replacementRange: replacementRange)
    }

    override func unmarkText() {
        let range = markedRange()
        guard hasMarkedText(), range.location != NSNotFound, NSMaxRange(range) <= (string as NSString).length else {
            super.unmarkText(); return
        }
        let marked = (string as NSString).substring(with: range)
        let text = IMECommit.cleaned(marked, composing: true, source: composingSource ?? IMECommit.currentSource())
        guard text != marked else { composingSource = nil; super.unmarkText(); return }
        insertText(text, replacementRange: range)
    }
}
