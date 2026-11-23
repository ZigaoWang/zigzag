import AppKit

/// Address text for display (pane strip, hover card, command bar rows, link pill). The host always uses WebKit's form
/// ("xn--" for IDNs), so lookalike names read the same everywhere.
nonisolated enum AddressText {
    /// Strips "user:pass@", which can spoof the host: "paypal.com@evil.example".
    static func withoutUserInfo(_ url: URL) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.percentEncodedUser != nil || parts.percentEncodedPassword != nil
        else { return url }
        parts.percentEncodedUser = nil
        parts.percentEncodedPassword = nil
        return parts.url ?? url
    }

    /// Decodes percent escapes for reading, except ones that change how the address reads: separators ("/", "?", "#",
    /// "@", ":", "\", "%"), spaces, controls, and bidi or invisible marks.
    static func readable(_ text: String) -> String {
        let bytes = Array(text.utf8)
        var out = ""
        var i = 0
        func hex(_ b: UInt8) -> UInt8? {
            switch b {
            case 0x30...0x39: b - 0x30
            case 0x41...0x46: b - 0x41 + 10
            case 0x61...0x66: b - 0x61 + 10
            default: nil
            }
        }
        while i < bytes.count {
            // Decodes a run of escapes together; one character can span several bytes.
            var run: [UInt8] = [], raw = ""
            var j = i
            while j + 2 < bytes.count, bytes[j] == 0x25, let high = hex(bytes[j + 1]), let low = hex(bytes[j + 2]) {
                run.append(high << 4 | low)
                raw += String(decoding: bytes[j...(j + 2)], as: UTF8.self)
                j += 3
            }
            guard !run.isEmpty else {
                // Copies up to the next escape.
                var k = i + 1
                while k < bytes.count, bytes[k] != 0x25 { k += 1 }
                out += String(decoding: bytes[i..<k], as: UTF8.self)
                i = k
                continue
            }
            if let decoded = String(validating: run, as: UTF8.self) {
                // Keeps the original escapes for characters that must stay escaped.
                var offset = 0
                for character in decoded {
                    let length = String(character).utf8.count
                    let escapes = raw.utf8.dropFirst(offset * 3).prefix(length * 3)
                    out += character.unicodeScalars.contains(where: staysEscaped) ? String(decoding: escapes, as: UTF8.self) : String(character)
                    offset += length
                }
            } else {
                out += raw
            }
            i = j
        }
        return out
    }

    /// Adds a word joiner after hyphens in host names so lines don't break "custom-progress-bar.com" into two.
    static func keepingHostsWhole(_ text: String) -> String {
        guard text.contains("-") else { return text }
        let pattern = #"[\p{L}\p{N}](?:[\p{L}\p{N}-]*[\p{L}\p{N}])?(?:\.[\p{L}\p{N}](?:[\p{L}\p{N}-]*[\p{L}\p{N}])?)+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let whole = text as NSString
        var out = "", last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: whole.length)) {
            out += whole.substring(with: NSRange(location: last, length: match.range.location - last))
            out += whole.substring(with: match.range).replacingOccurrences(of: "-", with: "-\u{2060}")
            last = match.range.location + match.range.length
        }
        return out + whole.substring(from: last)
    }

    private static func staysEscaped(_ scalar: Unicode.Scalar) -> Bool {
        if "/?#@:\\%".unicodeScalars.contains(scalar) { return true }
        if scalar.properties.isWhitespace { return true }
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .spaceSeparator, .privateUse, .surrogate, .unassigned: return true
        default: return false
        }
    }
}

/// A full address where there's room (pop-ups, Zigzag Mini's strip), as Chrome shows it: no "https://" or "www.", host
/// in normal ink, the rest quiet. http(s) only; other pages keep their name (`AddressView.name(of:)`). The host is
/// WebKit's form, never with user info.
nonisolated enum FullAddress {
    struct Parts: Equatable {
        /// Host plus any non-default port: "linux.do", "localhost:3000", "[::1]:8080".
        var host: String
        /// Decoded path, query and fragment (`AddressText.readable`); empty on a front page.
        var rest: String
        var whole: String { host + rest }
    }

    /// Cap on `rest`; queries can run to megabytes.
    static let longestRest = 1000

    static func parts(of url: URL?) -> Parts? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let raw = url.host(percentEncoded: false), !raw.isEmpty,
              // Non-ASCII hosts fall back to the name.
              raw.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 0x20 && $0.value != 0x7F }) else { return nil }
        var host = raw.lowercased().withoutWWW
        if host.contains(":") { host = "[\(host)]" }
        let usual = scheme == "https" ? 443 : 80
        if let port = url.port, port != usual { host += ":\(port)" }
        let path = url.path(percentEncoded: true)
        let query = url.query(percentEncoded: true)
        let fragment = url.fragment(percentEncoded: true)
        var rest = path == "/" && query == nil && fragment == nil ? "" : path
        if let query { rest += (rest.isEmpty ? "/" : "") + "?" + query }
        if let fragment { rest += (rest.isEmpty ? "/" : "") + "#" + fragment }
        if rest.count > longestRest { rest = String(rest.prefix(longestRest)) }
        return Parts(host: host, rest: AddressText.readable(rest))
    }

    /// How the address fits `room`: whole with the rest truncated while the host and `leastRest` characters fit; else
    /// the host alone (`AddressView.lineBreak(forName:)`). The host is never squeezed for the rest. `measure` returns
    /// text width.
    enum Shown: Equatable { case whole, host }

    /// Fewer characters read as noise.
    static let leastRest = 4

    static func shown(_ parts: Parts, room: CGFloat, measure: (String) -> CGFloat) -> Shown {
        if parts.rest.isEmpty || measure(parts.whole) <= room { return .whole }
        return measure(parts.host + parts.rest.prefix(leastRest) + HostText.ellipsis) <= room ? .whole : .host
    }

    /// Styled address: host in `color`, rest in `quiet`, truncated with "…".
    @MainActor static func styled(_ parts: Parts, font: NSFont, color: NSColor = Tokens.Color.textPrimary,
                                  quiet: NSColor = Tokens.Color.textSecondary, alignment: NSTextAlignment = .natural) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = alignment
        // Always left to right, host first, even in RTL languages.
        paragraph.baseWritingDirection = .leftToRight
        let base: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
        let text = NSMutableAttributedString(string: parts.host, attributes: base.merging([.foregroundColor: color]) { $1 })
        text.append(NSAttributedString(string: parts.rest, attributes: base.merging([.foregroundColor: quiet]) { $1 }))
        return text
    }

    /// Sets the address in `label` for `room` (excluding insets): whole, or the host alone in `color` when it doesn't
    /// fit (`shown`). No-op when unchanged, since the field relayouts throughout a load.
    @MainActor static func show(_ parts: Parts, in label: Label, room: CGFloat, color: NSColor = Tokens.Color.textPrimary,
                                quiet: NSColor = Tokens.Color.textSecondary) {
        let font = label.font ?? Tokens.Font.body()
        let wanted: NSAttributedString
        switch shown(parts, room: room, measure: { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) }) {
        case .whole:
            wanted = styled(parts, font: font, color: color, quiet: quiet, alignment: label.alignment)
        case .host:
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = AddressView.lineBreak(forName: parts.host)
            paragraph.alignment = label.alignment
            wanted = NSAttributedString(string: parts.host, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
        }
        if !label.attributedStringValue.isEqual(to: wanted) { label.attributedStringValue = wanted }
    }
}

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
        return Fit(size: smallest, lead: lead, domain: String(label.prefix(1)) + ellipsis + ending)
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
