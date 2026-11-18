import Foundation

/// One line over the page when a rule hands a link somewhere you can't see: an app, a service, or another browser.
/// A tab, Mini, a script's card or a question show themselves, so they get no line. Each rule says it once a session.
@MainActor
enum HandoffNotice {
    /// Where a handoff went that you can't see from the page: an app on this Mac (or the Mac's own browser), or a
    /// service it was sent to. The name is what the line says after "handed this link to" or "sent this link to".
    enum Elsewhere: Equatable {
        case app(String)
        case service(String)
    }

    /// The rules that have said their line since Zigzag started: each says one, so a rule that fires again stays quiet.
    private static var said: Set<UUID> = []

    #if DEBUG
    /// For tests: forgets which rules have said their line, as a fresh launch would.
    static func forgetSaid() { said = [] }
    #endif

    /// The line for one handoff, or nil when it shouldn't say one: the handoff shows itself, or the rule has already
    /// said its line this session. Answers with a line at most once per rule, and only for what left Zigzag.
    static func takeLine(for rule: DownloadRule, elsewhere: Elsewhere?) -> String? {
        guard let elsewhere, !said.contains(rule.id) else { return nil }
        said.insert(rule.id)
        return line(for: rule, elsewhere: elsewhere)
    }

    /// The line for one handoff, without the once-a-session part: the rule's own name, then where it went. A rule that
    /// was never given a name says what happened without inventing one for it.
    static func line(for rule: DownloadRule?, elsewhere: Elsewhere?) -> String? {
        guard let rule, let elsewhere else { return nil }
        let did = switch elsewhere {
        case .app(let name):
            String(localized: "handed this link to \(name)", comment: "An automation's notice over the page: what a rule did with the link. The placeholder is the app's own name, like mpv.")
        case .service(let name):
            String(localized: "sent this link to \(name)", comment: "An automation's notice over the page: what a rule did with the link. The placeholder names the service and the method, like aria2.addUri · 127.0.0.1.")
        }
        let named = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return named.isEmpty ? did
            : String(localized: "\(named): \(did)", comment: "An automation's notice over the page: the rule's name, then what it did. The placeholders are the rule's name and one of the “handed this link to …” lines.")
    }
}
