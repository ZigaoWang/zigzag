import AppKit

/// A site's host as a header shows it (#189): its subdomains quiet, the registrable domain (google.com, bbc.co.uk) in
/// the text's own ink, as that's the part that proves whose site it is. Too long for its room, it first shrinks a
/// little, then drops whole subdomain labels from the start ("…mail." stays out, a cut word reads like another), and
/// only when the domain alone can't fit does it get smaller still and, last of all, lose the end of the domain's own
/// name, never its ending (".com").
nonisolated enum HostText {
    /// A host in its parts: what comes before the registrable domain, with its dot ("gemini."), the domain itself,
    /// and a port after it (":3000"). A name that isn't a domain (an IP address, localhost, "New Tab") is all
    /// `domain`, with nothing before it.
    struct Parts: Equatable {
        var subdomain: String
        var domain: String
        var port: String
        var whole: String { subdomain + domain + port }
    }

    static let ellipsis = "…"

    static func parts(of name: String) -> Parts {
        var host = name, port = ""
        // One colon followed by digits is a port; an IPv6 address has more than one.
        if let colon = name.lastIndex(of: ":"), name.filter({ $0 == ":" }).count == 1,
           name[name.index(after: colon)...].allSatisfy(\.isNumber), name.index(after: colon) < name.endIndex {
            host = String(name[..<colon])
            port = String(name[colon...])
        }
        guard let domain = registrableDomain(of: host), domain.count < host.count else { return Parts(subdomain: "", domain: host, port: port) }
        return Parts(subdomain: String(host.dropLast(domain.count)), domain: String(host.suffix(domain.count)), port: port)
    }

    /// The host's registrable domain, in the host's own spelling, or nil when it has none (an IP address, a single
    /// label, a public suffix by itself). The list spells international names in Unicode, so a punycode label
    /// ("xn--…") is stood in for by a plain one: only the count of labels the rules match matters.
    static func registrableDomain(of host: String) -> String? {
        guard !host.isEmpty, !host.contains(" "), !host.contains(":"), !host.hasPrefix("."), !host.hasSuffix(".") else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count > 1, !labels.contains(where: \.isEmpty) else { return nil }
        let masked = labels.map { $0.lowercased().hasPrefix("xn--") ? "zz-idn" : $0.lowercased() }.joined(separator: ".")
        guard let domain = PublicSuffix.registrableDomain(masked) else { return nil }
        let count = domain.split(separator: ".").count
        return labels.suffix(count).joined(separator: ".")
    }

    /// How a host shows in a width: at what size, what's left of the part before its domain, and of the domain.
    struct Fit: Equatable {
        var size: CGFloat
        var lead: String
        var domain: String
        var text: String { lead + domain }
    }

    /// Fits `name` into `width`, `measure` giving a text's width at a size. The whole name is tried from `size` down
    /// to `size - shrink`; at that floor, subdomain labels go from the start; then the domain alone ("…." before it,
    /// so it's clear there was more) from there down to `smallest`, and at `smallest` the end of its own name goes.
    static func fit(_ name: String, width: CGFloat, size: CGFloat, shrink: CGFloat = 2, smallest: CGFloat,
                    measure: (String, CGFloat) -> CGFloat) -> Fit {
        let parts = parts(of: name)
        let floor = max(size - shrink, smallest)
        let main = parts.domain + parts.port
        func fits(_ text: String, _ at: CGFloat) -> Bool { measure(text, at) <= width }
        for at in stride(from: size, through: floor, by: -1) where fits(parts.whole, at) {
            return Fit(size: at, lead: parts.subdomain, domain: main)
        }
        if !parts.subdomain.isEmpty {
            // "a.b.c." → "…b.c." → "…c." → "…."
            let labels = parts.subdomain.dropLast().split(separator: ".", omittingEmptySubsequences: false)
            for drop in 1...labels.count {
                let lead = ellipsis + labels.dropFirst(drop).map { $0 + "." }.joined() + (drop == labels.count ? "." : "")
                if fits(lead + main, floor) { return Fit(size: floor, lead: lead, domain: main) }
            }
        }
        let lead = parts.subdomain.isEmpty ? "" : ellipsis + "."
        for at in stride(from: floor - 1, through: smallest, by: -1) where fits(lead + main, at) {
            return Fit(size: at, lead: lead, domain: main)
        }
        // Last of all, the end of the domain's own name, keeping its ending and port: "physicsandm….com".
        let label: String, ending: String
        if let dot = parts.domain.firstIndex(of: "."), registrableDomain(of: parts.domain) != nil {
            label = String(parts.domain[..<dot])
            ending = String(parts.domain[dot...]) + parts.port
        } else {
            label = parts.domain + parts.port
            ending = ""
        }
        var kept = label.count - 1
        while kept > 1 {
            let domain = label.prefix(kept) + ellipsis + ending
            if fits(lead + domain, smallest) { return Fit(size: smallest, lead: lead, domain: String(domain)) }
            kept -= 1
        }
        return Fit(size: smallest, lead: lead, domain: label.prefix(1) + ellipsis + ending)
    }

    /// The fit as styled text: the lead quiet, the domain in `color`.
    @MainActor static func styled(_ fit: Fit, color: NSColor = Tokens.Color.textPrimary, quiet: NSColor = Tokens.Color.textSecondary,
                       font: (CGFloat) -> NSFont, kern: (CGFloat) -> CGFloat = { _ in 0 }) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let base: [NSAttributedString.Key: Any] = [.font: font(fit.size), .kern: kern(fit.size)]
        text.append(NSAttributedString(string: fit.lead, attributes: base.merging([.foregroundColor: quiet]) { $1 }))
        text.append(NSAttributedString(string: fit.domain, attributes: base.merging([.foregroundColor: color]) { $1 }))
        return text
    }
}
