import Foundation

/// What an automation says for itself when it hands something somewhere you can't see: one line over the page it
/// fired on, naming the rule and where it went. **Only the handoffs that would otherwise be silent are announced** —
/// an app, a service, the Mac's own browser. A link opened in a tab or in Mini, a script's card and a question all
/// show themselves, so a line beside them would say the same thing twice. A rule says its line once a session, so a
/// rule that fires all afternoon doesn't bury the page in notices.
///
/// What the notice is for is exact. It is what makes a rule you didn't make **detectable** — it does not make one
/// impossible; signing or allow-listing scripts is a separate, larger thing.
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
        // The rule's own name comes first: a notice you can't put a name to is the one thing it can't be.
        let named = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return named.isEmpty ? did
            : String(localized: "\(named): \(did)", comment: "An automation's notice over the page: the rule's name, then what it did. The placeholders are the rule's name and one of the “handed this link to …” lines.")
    }
}
