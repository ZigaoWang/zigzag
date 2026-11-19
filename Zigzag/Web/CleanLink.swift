import AppKit

/// Copy Link, as in Arc: the address minus known tracking parameters, copied as plain text and as the title linked to
/// it for rich-text apps.
enum CleanLink {
    /// Stripped on every site. From Firefox query stripping, Safari Link Tracking Protection and ClearURLs: click IDs
    /// and mail and ad campaign tags, never parameters a page needs.
    static let trackers: Set<String> = [
        // Ad click IDs: Google, Facebook, Microsoft, Yandex, TikTok, Twitter, LinkedIn.
        "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "gad_source", "srsltid", "fbclid", "mibextid", "msclkid", "yclid",
        "ysclid", "ttclid", "twclid", "li_fat_id", "epik", "rb_clickid", "wickedid", "_openstat",
        // Mail and marketing tools: Mailchimp, HubSpot, Marketo, Vero, Omeda, MailerLite, Adobe, Instagram, Alibaba.
        "mc_cid", "mc_eid", "_hsenc", "_hsmi", "__hssc", "__hstc", "__hsfp", "hsctatracking", "mkt_tok", "vero_id",
        "vero_conv", "oly_anon_id", "oly_enc_id", "__s", "ml_subscriber", "ml_subscriber_hash", "s_cid", "igshid", "spm",
    ]

    /// Every parameter starting with this, as utm_source and utm_campaign do.
    static let trackerPrefixes = ["utm_"]

    /// Stripped only on these sites, where the name means a share or referral; elsewhere it may be the page's own.
    static let siteTrackers: [(hosts: [String], names: Set<String>)] = [
        (["youtube.com", "youtu.be", "spotify.com"], ["si", "pp", "feature"]),
        (["twitter.com", "x.com"], ["ref_src", "ref_url"]),
        (["instagram.com"], ["igsh"]),
    ]

    /// Removes tracking parameters only; everything else (order, spelling, fragment) is untouched.
    static func clean(_ url: URL) -> URL {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let query = parts.percentEncodedQuery else { return url }
        let host = (parts.host ?? "").lowercased()
        let local = siteTrackers.filter { $0.hosts.contains { host == $0 || host.hasSuffix("." + $0) } }.reduce(into: Set<String>()) { $0.formUnion($1.names) }
        // Tweet share links: ?s=20&t=… only describe how it was shared.
        let tweet = ["twitter.com", "x.com"].contains { host == $0 || host.hasSuffix("." + $0) } && parts.path.contains("/status/")
        let pairs = query.split(separator: "&", omittingEmptySubsequences: false)
        let kept = pairs.filter { pair in
            let raw = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let name = (raw.removingPercentEncoding ?? raw).lowercased()
            if trackers.contains(name) || local.contains(name) { return false }
            if trackerPrefixes.contains(where: { name.hasPrefix($0) }) { return false }
            if tweet, name == "s" || name == "t" { return false }
            return true
        }
        guard kept.count != pairs.count else { return url }
        parts.percentEncodedQuery = kept.isEmpty ? nil : kept.joined(separator: "&")
        return parts.url ?? url
    }

    /// Plain address as text (terminals, text fields), and `title` linked to it as HTML and RTF (Notes, Mail, Slack,
    /// Docs).
    static func write(_ url: URL, title: String?, to pasteboard: NSPasteboard = .general) {
        let link = clean(url).absoluteString
        pasteboard.clearContents()
        pasteboard.setString(link, forType: .string)
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty, title != link else { return }
        pasteboard.setString(html(link, title: title), forType: .html)
        let rich = NSAttributedString(string: title, attributes: [.link: URL(string: link) ?? url])
        if let rtf = try? rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            pasteboard.setData(rtf, forType: .rtf)
        }
    }

    /// Markdown link with the clean address.
    static func markdown(_ url: URL, title: String) -> String { "[\(title)](\(clean(url).absoluteString))" }

    static func html(_ link: String, title: String) -> String { "<a href=\"\(escaped(link))\">\(escaped(title))</a>" }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
