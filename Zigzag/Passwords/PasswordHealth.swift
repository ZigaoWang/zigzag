import CryptoKit
import Foundation

/// Weak and reused passwords, worked out on this Mac only. Reuse is found by comparing salted hashes made for
/// this one check, so passwords are never compared or kept as text.
nonisolated enum PasswordHealth {
    /// Passwords people pick most, and words that make a password easy to guess.
    private static let common: Set<String> = [
        "123456", "123456789", "12345678", "12345", "1234567", "1234567890", "111111", "000000", "123123", "654321",
        "password", "password1", "password123", "qwerty", "qwerty123", "qwertyuiop", "abc123", "letmein", "welcome",
        "iloveyou", "admin", "login", "monkey", "dragon", "sunshine", "princess", "football", "baseball", "master",
        "shadow", "superman", "trustno1", "passw0rd", "starwars", "whatever", "freedom", "hello", "secret",
    ]

    /// Short, from one kind of character, a common password, or too little randomness to stand up to guessing.
    static func isWeak(_ password: SecretString) -> Bool {
        password.withUnsafeString { text in
            let lower = text.lowercased()
            if text.count < 8 || common.contains(lower) { return true }
            if lower.contains("password") || lower.contains("qwerty") || lower.contains("123456") { return true }
            if Set(text).count <= 3 { return true }
            var pool = 0
            if text.contains(where: \.isLowercase) { pool += 26 }
            if text.contains(where: \.isUppercase) { pool += 26 }
            if text.contains(where: \.isNumber) { pool += 10 }
            if text.contains(where: { !$0.isLetter && !$0.isNumber }) { pool += 33 }
            let bits = Double(text.count) * log2(Double(max(pool, 2)))
            return bits < 50
        }
    }

    /// Groups of logins that share a password across different sites.
    static func reused(_ passwords: [(id: UUID, origin: Origin, password: SecretString)]) -> [[UUID]] {
        let salt = SymmetricKey(size: .bits256)
        var groups: [Data: [(UUID, Origin)]] = [:]
        for entry in passwords {
            let digest = entry.password.withUnsafeString { Data(HMAC<SHA256>.authenticationCode(for: Data($0.utf8), using: salt)) }
            groups[digest, default: []].append((entry.id, entry.origin))
        }
        return groups.values.filter { Set($0.map(\.1)).count > 1 }.map { $0.map(\.0) }
    }
}
