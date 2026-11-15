import AppKit

/// What an automation says for itself the moment it fires: one line over the page it was handed, naming the rule and
/// what it did. **Always answers whether a rule *asks*, never whether it *tells***: every firing is announced, every
/// time, and only the questions go quiet.
///
/// What the notice is for is exact. It is what makes a rule you didn't make **detectable** — it does not make one
/// impossible; signing or allow-listing scripts is a separate, larger thing. And it is why the questions may go quiet
/// without the automation going dark: an answer kept for a site means the next firing doesn't ask, and this is what
/// still says so.
@MainActor
enum HandoffNotice {
    /// The line for one firing, or nil where the firing shows something of its own and needs no notice — a script's
    /// card already says the script is running, and a web address with no place remembered asks where to open. A
    /// question is a sighting by itself, so only the firings that would otherwise be **silent** are announced.
    ///
    /// `rule` is the rule to name in the line; `askingOn` is the rule an Open URL would remember a chosen place on,
    /// which is nil for a script's answer (see `DownloadHandoff.announce`). They are the same rule for a rule's own
    /// firing, and only an Open URL can tell them apart.
    static func line(for rule: DownloadRule?, askingOn asker: DownloadRule?, action: DownloadRuleAction,
                     values: HandoffValues, secret: String, request: DownloadHandoff.Request) -> String? {
        guard let did = whatItDid(action, askingOn: asker, values: values, secret: secret, request: request) else { return nil }
        let named = rule?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // The rule's own name comes first: a notice you can't put a name to is the one thing it can't be. A rule that
        // was never given one says what happened without inventing a name for it.
        return named.isEmpty ? did
            : String(localized: "\(named): \(did)", comment: "An automation's notice over the page: the rule's name, then what it did. The placeholders are the rule's name and one of the “handed this link to …” lines.")
    }

    /// What one action did, in words. Nil for the actions that say so themselves.
    private static func whatItDid(_ action: DownloadRuleAction, askingOn asker: DownloadRule?,
                                  values: HandoffValues, secret: String, request: DownloadHandoff.Request) -> String? {
        switch action.kind {
        case .runScript:
            // The card over the page that says "Running script: yt-dlp.sh" *is* the notice; a line beside it would say
            // the same thing twice, and a run over in a moment would flash a notice it doesn't need.
            return nil
        case .openApp:
            return String(localized: "handed this link to \(action.summary)", comment: "An automation's notice over the page: what a rule did with the link. The placeholder is the app's own name, like mpv.")
        case .jsonRPC:
            return String(localized: "sent this link to \(action.summary)", comment: "An automation's notice over the page: what a rule did with the link. The placeholder names the service and the method, like aria2.addUri · 127.0.0.1.")
        case .openURL:
            guard let url = URL(string: DownloadTokens.expand(action.urlTemplate, with: values, secret: secret)),
                  let scheme = url.scheme else { return nil }
            guard OpenInZigzag.handles(url) else {
                // An address that isn't the web's belongs to its own app: name the app, as Settings › Downloads does.
                return String(localized: "handed this link to \(ExternalLinks.appName(forScheme: scheme))", comment: "An automation's notice over the page: what a rule did with the link. The placeholder is the app that opens the address's scheme, like mpv for mpv://.")
            }
            // The same decision the action will take, never a guess from the rule alone: a site's answer for this rule
            // decides it too. Refused means nothing happened, and asking means the question is the sighting.
            guard case .place(let place) = DownloadHandoff.openInDecision(action, rule: asker, request: request) else {
                return nil
            }
            switch place {
            case .thisTab: return String(localized: "opened this link in this tab", comment: "An automation's notice over the page: the rule opened the link where you already are.")
            case .newTab: return String(localized: "opened this link in a new tab", comment: "An automation's notice over the page: the rule opened the link in a tab of its own.")
            case .mini: return String(localized: "opened this link in Mini", comment: "An automation's notice over the page: the rule opened the link in Zigzag Mini.")
            }
        case .saveToFolder, .openFile:
            // A destination never runs as an action: it is read where WebKit makes the download, and a file landing in
            // a folder already shows in the downloads list. Announcing it is a deliberate later step, not an oversight.
            return nil
        }
    }
}
