import Testing
@testable import Zigzag

struct PasswordGeneratorTests {
    @Test func shape() {
        for _ in 0..<200 {
            let password = PasswordGenerator.generate().withUnsafeString { String($0) }
            let groups = password.split(separator: "-")
            #expect(groups.count == 3)
            #expect(groups.allSatisfy { $0.count == 6 })
            #expect(password.contains { $0.isUppercase })
            #expect(password.contains { $0.isLowercase })
            #expect(password.contains { $0.isNumber })
            #expect(password.allSatisfy { $0 == "-" || PasswordGenerator.alphabet.contains($0) })
        }
    }

    @Test func noRepeats() {
        var seen = Set<String>()
        for _ in 0..<2000 { seen.insert(PasswordGenerator.generate().withUnsafeString { String($0) }) }
        #expect(seen.count == 2000)
    }
}

struct PasswordRulesTests {
    @Test func readsPasswordRules() {
        let rules = PasswordGenerator.Rules(passwordRules: "minlength: 8; maxlength: 16; required: upper; required: digit; required: [-_]; allowed: lower;")
        #expect(rules.minLength == 8)
        #expect(rules.maxLength == 16)
        #expect(rules.requiresSpecial)
        #expect(rules.allowedSpecials == ["-", "_"])
    }

    @Test func honorsMaxLengthAndRequiredSymbol() {
        let rules = PasswordGenerator.Rules(passwordRules: "required: lower; required: upper; required: digit; required: [!#];", maxLength: 12)
        for _ in 0..<100 {
            let password = PasswordGenerator.generate(rules).withUnsafeString { String($0) }
            #expect(password.count == 12)
            #expect(password.contains { "!#".contains($0) })
            #expect(!password.contains("-"))
        }
    }

    @Test func noSymbolsWhenOnlyLettersAndDigitsAllowed() {
        let rules = PasswordGenerator.Rules(passwordRules: "allowed: upper, lower, digit;")
        for _ in 0..<100 {
            let password = PasswordGenerator.generate(rules).withUnsafeString { String($0) }
            #expect(password.allSatisfy { $0.isLetter || $0.isNumber })
            #expect(password.count == 20)
        }
    }

    @Test func longerWhenMinLengthAsks() {
        let password = PasswordGenerator.generate(PasswordGenerator.Rules(minLength: 32)).withUnsafeString { String($0) }
        #expect(password.count == 32)
    }
}
