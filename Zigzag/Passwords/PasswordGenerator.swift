import Foundation
import Security

/// Strong passwords in the shape sites accept and people can read: three groups of six, like
/// "kHw7rq-Nfb2xT-pa9eMz". Letters and digits only (no characters that look alike), with at least one capital
/// and one digit, about 100 bits of randomness, from the system's secure random source.
nonisolated enum PasswordGenerator {
    static let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    static func generate() -> SecretString {
        while true {
            var characters: [Character] = []
            for group in 0..<3 {
                if group > 0 { characters.append("-") }
                for _ in 0..<6 { characters.append(alphabet[randomIndex(below: alphabet.count)]) }
            }
            guard characters.contains(where: \.isUppercase), characters.contains(where: \.isNumber), characters.contains(where: \.isLowercase) else { continue }
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
