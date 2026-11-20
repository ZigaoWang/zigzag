import Foundation
import Testing

/// Every `Test: Suite.test` line in specs/*.md names a test that exists, so a spec never points at a renamed or
/// removed test.
struct SpecLinksTests {
    private static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    /// Each test source file's text.
    private static func testSources() throws -> [String] {
        let folder = repo.appendingPathComponent("ZigzagTests")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".swift") }
        return try names.map { try String(contentsOf: folder.appendingPathComponent($0), encoding: .utf8) }
    }

    /// The suite's body: its declaration and every `extension` of it in any file, each up to the next type declared at
    /// the top level. Nil when no file declares the suite.
    private static func body(of suite: String, in sources: [String]) -> String? {
        let declaration = try! NSRegularExpression(pattern: "^(?:@\\w+(?:\\([^)]*\\))? )*(?:final )?(?:struct|class) \(suite)\\b", options: .anchorsMatchLines)
        let part = try! NSRegularExpression(pattern: "^(?:@\\w+(?:\\([^)]*\\))? )*(?:(?:final )?(?:struct|class)|extension) \(suite)\\b", options: .anchorsMatchLines)
        let next = try! NSRegularExpression(pattern: "^(?:@\\w+(?:\\([^)]*\\))? )*(?:final |private |fileprivate )*(?:struct|class|enum|extension) ", options: .anchorsMatchLines)
        var declared = false
        var bodies: [Substring] = []
        for text in sources {
            let all = NSRange(text.startIndex..., in: text)
            if declaration.firstMatch(in: text, range: all) != nil { declared = true }
            for found in part.matches(in: text, range: all) {
                guard let start = Range(found.range, in: text) else { continue }
                let rest = NSRange(start.upperBound..., in: text)
                let end = next.firstMatch(in: text, range: rest).flatMap { Range($0.range, in: text)?.lowerBound } ?? text.endIndex
                bodies.append(text[start.lowerBound..<end])
            }
        }
        return declared ? bodies.joined(separator: "\n") : nil
    }

    @Test func everySpecTestExists() throws {
        let specs = Self.repo.appendingPathComponent("specs")
        let files = try FileManager.default.contentsOfDirectory(atPath: specs.path).filter { $0.hasSuffix(".md") }
        #expect(!files.isEmpty)
        let sources = try Self.testSources()
        var links = 0
        for file in files {
            let text = try String(contentsOf: specs.appendingPathComponent(file), encoding: .utf8)
            var inExample = false
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // The format shown in a code block is an example, not a link.
                if trimmed.hasPrefix("```") { inExample.toggle() }
                guard !inExample, trimmed.hasPrefix("Test: ") else { continue }
                let name = trimmed.dropFirst("Test: ".count).trimmingCharacters(in: .whitespaces)
                let parts = name.split(separator: ".")
                guard parts.count == 2 else {
                    Issue.record("\(file): \"\(trimmed)\" isn't Suite.test")
                    continue
                }
                links += 1
                guard let body = Self.body(of: String(parts[0]), in: sources) else {
                    Issue.record("\(file): no suite \(parts[0]) in ZigzagTests")
                    continue
                }
                #expect(body.contains("func \(parts[1])("), "\(file): \(name) not found")
            }
        }
        #expect(links > 0)
    }
}
