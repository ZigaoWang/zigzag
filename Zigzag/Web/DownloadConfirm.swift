import AppKit

/// Asked when a file arrives whose type has no standing answer: open it in the Mac's own app for that type, or leave
/// it saved? The answer can hold for this file, for its type, or for every download — "Always" here means more, not
/// longer, which is why the card's three entries are its own rather than a site's.
@MainActor
enum DownloadConfirm {
    enum Handling: String, Sendable {
        case open, save
    }

    /// What the card's durations mean. `PermissionScope` is only how the card carries the choice back; nothing is
    /// written under a site, so the three stand for this file, this type, and every type.
    static func durations(for label: String) -> [(title: String, scope: PermissionScope)] {
        [
            (String(localized: "This time", comment: "Duration choice on the download question: the answer applies to this file only."), .once),
            (String(localized: "Always for \(label)", comment: "Duration choice on the download question: the answer is kept for this file type. The placeholder is the type, like PDF."), .site),
            (String(localized: "Always", comment: "Duration choice on the download question: the answer is kept for every file type."), .rule)
        ]
    }

    /// The type as the question names it: PDF, ZIP, EPUB. Nil when there is no extension to name.
    static func label(for type: String) -> String? {
        let trimmed = type.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.uppercased()
    }

    /// Asks. Nil is a question put off: the file is saved as if nothing had asked.
    static func ask(type: String, origin: String?, window: NSWindow?, tab: Tab?) async -> (Handling, PermissionScope)? {
        guard let label = label(for: type), let window,
              let controller = WindowManager.shared.promptHost(for: window) else { return nil }
        let host = origin.map(SiteOrigin.label)
            ?? String(localized: "This download", comment: "Who asks on the download question when the file has no site, like a file on this Mac.")
        let answer = await PermissionPrompt.ask(
            host: host, origin: origin, what: "downloads", symbol: "arrow.down.circle",
            in: controller, tab: tab,
            title: String(localized: "Open this \(label)", comment: "The download question, without its question mark: whether this file opens in the Mac's app. The placeholder is the file's type, like PDF."),
            actions: [.alternate("save", String(localized: "Save", comment: "Button on the download question: keep the file where downloads go.")),
                      .alternate("open", String(localized: "Open", comment: "Button on the download question: open the file in the Mac's app for its type."))],
            durations: durations(for: label))
        guard let answer else { return nil }
        return (answer.action == "open" ? .open : .save, answer.scope)
    }

    /// What an answer stands for, as one value, so the writing-down can be tested without a card.
    enum Decision: Equatable {
        case once(Handling)
        case type(Handling, String)
        case everyType(Handling)
    }

    static func decision(handling: Handling, scope: PermissionScope, type: String) -> Decision {
        switch scope {
        case .once: .once(handling)
        case .site: .type(handling, type.lowercased())
        case .rule: .everyType(handling)
        }
    }

    /// Writes the standing part of an answer down: a rule for one type, or the answer for every type. "This time"
    /// writes nothing — it belongs to the download that asked.
    static func record(_ decision: Decision, label: String) {
        switch decision {
        case .once:
            break
        case .type(let handling, let type):
            var action = DownloadRuleAction(kind: handling == .open ? .openFile : .saveToFolder)
            if handling == .save { action.folderPath = DownloadManager.folder.path }
            let rule = DownloadRule(name: label, applies: .downloads, match: .fileType, pattern: type, action: action)
            // In front: the answer just given is the one that should decide the next file of this type.
            DownloadRulesStore.shared.add(rule, at: 0)
        case .everyType(let handling):
            DownloadManager.handlesEveryType = handling
        }
    }
}
