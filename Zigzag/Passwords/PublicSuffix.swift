import Foundation

/// The registrable domain of a host ("netflix.com" for www.netflix.com, "bbc.co.uk" for news.bbc.co.uk, and
/// "alice.github.io" for alice.github.io, which is someone else's site from bob.github.io), from the Public
/// Suffix List that every browser uses. Used to offer a password across one site's subdomains, never further.
nonisolated enum PublicSuffix {
    private struct Rules: Sendable {
        var exact: Set<String> = []
        var wildcard: Set<String> = []
        var exception: Set<String> = []
    }

    private static let rules: Rules = {
        var rules = Rules()
        guard let url = Bundle.main.url(forResource: "public_suffix_list", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return rules }
        for line in text.split(whereSeparator: \.isNewline) {
            let rule = line.trimmingCharacters(in: .whitespaces).lowercased()
            if rule.isEmpty || rule.hasPrefix("//") { continue }
            if rule.hasPrefix("!") { rules.exception.insert(String(rule.dropFirst())) }
            else if rule.hasPrefix("*.") { rules.wildcard.insert(String(rule.dropFirst(2))) }
            else { rules.exact.insert(rule) }
        }
        return rules
    }()

    /// Whether the list is there; without it nothing is shared across subdomains.
    static var isLoaded: Bool { !rules.exact.isEmpty }

    /// The registrable domain, or nil when there isn't a safe answer: an IP address, a bare public suffix, a host
    /// with international labels (the list spells those in Unicode), or no list.
    static func registrableDomain(_ host: String) -> String? {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard isLoaded, !host.isEmpty, !host.contains(":"), host.contains("."),
              !host.split(separator: ".").contains(where: { $0.hasPrefix("xn--") }),
              host.rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789.").inverted) != nil else { return nil }
        let labels = host.split(separator: ".").map(String.init)
        // The longest rule that matches; an exception rule cuts one label off its own length.
        var suffixLength = 1
        for i in 0..<labels.count {
            let candidate = labels[i...].joined(separator: ".")
            let length = labels.count - i
            if rules.exception.contains(candidate) { suffixLength = length - 1; break }
            if rules.exact.contains(candidate) { suffixLength = max(suffixLength, length) }
            if i + 1 < labels.count, rules.wildcard.contains(labels[(i + 1)...].joined(separator: ".")) { suffixLength = max(suffixLength, length) }
        }
        guard labels.count > suffixLength else { return nil }
        return labels.suffix(suffixLength + 1).joined(separator: ".")
    }
}
