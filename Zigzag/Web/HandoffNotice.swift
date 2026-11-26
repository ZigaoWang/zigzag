import Foundation

/// A one-line notice when a rule sends a link somewhere invisible: an app, a service or another browser. Tabs, Mini,
/// script cards and questions show themselves. Once per rule per session.
@MainActor
enum HandoffNotice {
    /// An invisible destination: an app (or the default browser) or a service. The name follows "handed this link to"
    /// or "sent this link to".
    enum Elsewhere: Equatable {
        case app(String)
        case service(String)
    }

    /// Rules that have shown their line since launch.
    private static var said: Set<UUID> = []

    #if DEBUG
    /// Tests: resets as a fresh launch would.
    static func forgetSaid() { said = [] }
    #endif

    /// The line, or nil when the handoff shows itself or the rule already showed its line this session.
    static func takeLine(for rule: DownloadRule, elsewhere: Elsewhere?, file: Bool = false) -> String? {
        guard let elsewhere, !said.contains(rule.id) else { return nil }
        said.insert(rule.id)
        return line(for: rule, elsewhere: elsewhere, file: file)
    }

    /// The line without the once-per-session check: the rule's name, then the destination. Unnamed rules get a line
    /// without a name.
    static func line(for rule: DownloadRule?, elsewhere: Elsewhere?, file: Bool = false) -> String? {
        guard let rule, let elsewhere else { return nil }
        let did = switch elsewhere {
        case .app(let name):
            file
                ? String(localized: "handed this file to \(name)", comment: "An automation's notice over the page: what a rule did with the file it downloaded first. The placeholder is the app's own name, like mpv.")
                : String(localized: "handed this link to \(name)", comment: "An automation's notice over the page: what a rule did with the link. The placeholder is the app's own name, like mpv.")
        case .service(let name):
            file
                ? String(localized: "sent this file to \(name)", comment: "An automation's notice over the page: what a rule did with the file it downloaded first. The placeholder names the service and the method, like 127.0.0.1 (aria2.addUri).")
                : String(localized: "sent this link to \(name)", comment: "An automation's notice over the page: what a rule did with the link. The placeholder names the service and the method, like 127.0.0.1 (aria2.addUri).")
        }
        let named = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return named.isEmpty ? did
            : String(localized: "\(named): \(did)", comment: "An automation's notice over the page: the rule's name, then what it did. The placeholders are the rule's name and one of the “handed this link to …” lines.")
    }
}
