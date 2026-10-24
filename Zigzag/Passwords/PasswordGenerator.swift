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

        /// Reads `passwordrules`, e.g. "minlength: 8; maxlength: 16; required: upper; required: [-_]; allowed: lower, digit;".
        init(passwordRules: String = "", minLength: Int = -1, maxLength: Int = -1) {
            if minLength > 0 { self.minLength = minLength }
            if maxLength > 0 { self.maxLength = maxLength }
            var specials: [Character]? = nil
            for clause in passwordRules.split(separator: ";") {
                let parts = clause.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                guard parts.count == 2 else { continue }
                let (name, value) = (parts[0], parts[1])
                switch name {
                case "minlength": if let n = Int(value) { self.minLength = max(self.minLength, n) }
                case "maxlength": if let n = Int(value) { self.maxLength = min(self.maxLength, n) }
                case "required", "allowed":
                    if specials == nil { specials = [] }
                    var classes = value
                    // Custom character sets in brackets.
                    while let open = classes.firstIndex(of: "["), let close = classes[open...].firstIndex(of: "]") {
                        let custom = classes[classes.index(after: open)..<close].filter { !$0.isLetter && !$0.isNumber }
                        specials? += custom
                        if name == "required", !custom.isEmpty { requiresSpecial = true }
                        classes.removeSubrange(open...close)
                    }
                    for item in classes.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                        if item == "special" || item == "ascii-printable" || item == "unicode" {
                            specials? += PasswordGenerator.specials
                            if name == "required", item == "special" { requiresSpecial = true }
                        }
                    }
                default: break
                }
            }
            allowedSpecials = specials.map { Array(Set($0)).sorted() }
        }

        var allowsDash: Bool { allowedSpecials?.contains("-") ?? true }
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
        let grouped = !plain && rules.allowsDash && rules.minLength <= 20 && rules.maxLength >= 20
        let length = grouped ? 20 : min(max(20, rules.minLength), rules.maxLength)
        let symbols = rules.allowedSpecials ?? (plain ? [] : specials)
        let needsSpecial = rules.requiresSpecial && !grouped
        while true {
            var characters: [Character] = []
            if grouped {
                for group in 0..<3 {
                    if group > 0 { characters.append("-") }
                    for _ in 0..<6 { characters.append(alphabet[randomIndex(below: alphabet.count)]) }
                }
            } else {
                for _ in 0..<length { characters.append(alphabet[randomIndex(below: alphabet.count)]) }
                if needsSpecial, !symbols.isEmpty, length > 1 {
                    characters[1 + randomIndex(below: length - 1)] = symbols[randomIndex(below: symbols.count)]
                }
            }
            guard characters.contains(where: \.isUppercase), characters.contains(where: \.isNumber), characters.contains(where: \.isLowercase) || length < 4
            else { continue }
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
