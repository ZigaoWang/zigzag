import Foundation
import Testing
@testable import Zigzag

struct PasswordHealthTests {
    @Test func weak() {
        for text in ["123456", "Password1!", "abc", "aaaaaaaaaaaa", "sunshine", "qwerty2024"] {
            #expect(PasswordHealth.isWeak(SecretString(text)), "\(text.count)-character sample should be weak")
        }
    }

    @Test func strong() {
        #expect(!PasswordHealth.isWeak(PasswordGenerator.generate()))
        #expect(!PasswordHealth.isWeak(SecretString("correct-horse-battery-staple")))
    }

    @Test func reusedAcrossSitesOnly() throws {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let github = try #require(Origin(URL(string: "https://github.com")))
        let apple = try #require(Origin(URL(string: "https://apple.com")))
        let groups = PasswordHealth.reused([
            (a, github, SecretString("same-one")), (b, apple, SecretString("same-one")),
            (c, github, SecretString("other")), (d, github, SecretString("other")),
        ])
        #expect(groups.count == 1)
        #expect(Set(groups[0]) == [a, b])
    }
}
