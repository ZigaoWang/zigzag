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
