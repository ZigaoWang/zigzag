import Foundation
import Security

/// Strong passwords in the shape sites accept and people can read: three groups of six, like
/// "kHw7rq-Nfb2xT-pa9eMz". Letters and digits only (no characters that look alike), with at least one capital
/// and one digit, about 100 bits of randomness, from the system's secure random source.
///
/// A site's own rules come first: `passwordrules` (Apple's format), and the field's `minlength` and `maxlength`.
nonisolated enum PasswordGenerator {
    static let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    static let specials = Array("-!@#$%&*_.")

    struct Rules: Equatable {
        var minLength = 0
        var maxLength = Int.max
        /// Nil: no limits stated. Otherwise the symbols the site allows (empty: none).
        var allowedSpecials: [Character]?
        var requiresSpecial = false
        /// Nil: no limits stated. Otherwise the letter and digit classes the site allows ("upper", "lower", "digit").
        var allowedClasses: Set<String>?

        /// Reads `passwordrules`, e.g. "minlength: 8; maxlength: 16; required: upper; required: [-_]; allowed: lower, digit;".
        init(passwordRules: String = "", minLength: Int = -1, maxLength: Int = -1) {
            if minLength > 0 { self.minLength = minLength }
            if maxLength > 0 { self.maxLength = maxLength }
            var specials: [Character]? = nil
            var letterClasses: Set<String>? = nil
            for clause in passwordRules.split(separator: ";") {
                let parts = clause.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                guard parts.count == 2 else { continue }
                let (name, value) = (parts[0], parts[1])
                switch name {
                case "minlength": if let n = Int(value) { self.minLength = max(self.minLength, n) }
                case "maxlength": if let n = Int(value) { self.maxLength = min(self.maxLength, n) }
                case "required", "allowed":
                    if specials == nil { specials = [] }
                    if letterClasses == nil { letterClasses = [] }
                    var classes = value
                    // Custom character sets in brackets.
                    while let open = classes.firstIndex(of: "["), let close = classes[open...].firstIndex(of: "]") {
                        let custom = classes[classes.index(after: open)..<close].filter { !$0.isLetter && !$0.isNumber }
                        specials? += custom
                        if name == "required", !custom.isEmpty { requiresSpecial = true }
                        classes.removeSubrange(open...close)
                    }
                    for item in classes.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                        if ["upper", "lower", "digit"].contains(item) { letterClasses?.insert(item) }
                        if item == "ascii-printable" || item == "unicode" { letterClasses?.formUnion(["upper", "lower", "digit"]) }
                        if item == "special" || item == "ascii-printable" || item == "unicode" {
                            specials? += PasswordGenerator.specials
                            if name == "required", item == "special" { requiresSpecial = true }
                        }
                    }
                default: break
                }
            }
            allowedSpecials = specials.map { Array(Set($0)).sorted() }
            // Only symbols stated: letters and digits are still fine.
            allowedClasses = letterClasses.flatMap { $0.isEmpty ? nil : $0 }
            // A page's numbers are only hints: never shorter than 4 or longer than 128, and never an impossible range.
            self.minLength = min(max(self.minLength, 0), 128)
            self.maxLength = min(max(self.maxLength, 4), 128)
            if self.maxLength < self.minLength { self.maxLength = self.minLength }
        }

        var allowsDash: Bool { allowedSpecials?.contains("-") ?? true }

        func allows(_ kind: String) -> Bool { allowedClasses?.contains(kind) ?? true }

        /// The letters and digits to draw from: the site's classes, or all of them.
        var letters: [Character] {
            let pool = PasswordGenerator.alphabet.filter {
                ($0.isUppercase && allows("upper")) || ($0.isLowercase && allows("lower")) || ($0.isNumber && allows("digit"))
            }
            return pool.isEmpty ? PasswordGenerator.alphabet : pool
        }
    }

    /// The default shape, or the nearest one the rules allow.
    static func generate(_ rules: Rules = Rules()) -> SecretString {
        candidates(rules, count: 1)[0]
    }

    /// Several passwords in different shapes, for a page to check against its own `pattern`.
    static func candidates(_ rules: Rules, count: Int) -> [SecretString] {
        (0..<count).map { index in make(rules, plain: index % 2 == 1) }
    }

    private static func make(_ rules: Rules, plain: Bool) -> SecretString {
        let grouped = !plain && rules.allowedClasses == nil && rules.allowsDash && rules.minLength <= 20 && rules.maxLength >= 20
        let length = grouped ? 20 : min(max(20, rules.minLength), rules.maxLength)
        let letters = rules.letters
        let symbols = rules.allowedSpecials ?? (plain ? [] : specials)
        let needsSpecial = rules.requiresSpecial && !grouped
        // Each allowed class at least once, when there's room; a bounded number of draws, never an endless loop.
        let wanted: [(Character) -> Bool] = [
            rules.allows("upper") ? { $0.isUppercase } : nil,
            rules.allows("lower") ? { $0.isLowercase } : nil,
            rules.allows("digit") ? { $0.isNumber } : nil,
        ].compactMap { $0 }
        var attempt = 0
        while true {
            attempt += 1
            var characters: [Character] = []
            if grouped {
                for group in 0..<3 {
                    if group > 0 { characters.append("-") }
                    for _ in 0..<6 { characters.append(letters[randomIndex(below: letters.count)]) }
                }
            } else {
                for _ in 0..<length { characters.append(letters[randomIndex(below: letters.count)]) }
                if needsSpecial, !symbols.isEmpty, length > 1 {
                    characters[1 + randomIndex(below: length - 1)] = symbols[randomIndex(below: symbols.count)]
                }
            }
            let complete = length < wanted.count + (needsSpecial ? 1 : 0) + 1 || wanted.allSatisfy { test in characters.contains(where: test) }
            guard complete || attempt >= 64 else { continue }
            let password = SecretString(String(characters))
            characters.removeAll()
            return password
        }
    }

    /// Unbiased: values past the last whole multiple of `bound` are drawn again.
    private static func randomIndex(below bound: Int) -> Int {
        let limit = UInt8.max - UInt8((Int(UInt8.max) + 1) % bound)
        while true {
            var byte: UInt8 = 0
            guard SecRandomCopyBytes(kSecRandomDefault, 1, &byte) == errSecSuccess else { continue }
            if byte <= limit { return Int(byte) % bound }
        }
    }
}
