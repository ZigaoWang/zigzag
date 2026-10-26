import Foundation
import Testing
@testable import Zigzag

/// The notes the app shows after an update, read from the same file the release uses.
@MainActor
struct WhatsNewTests {
    @Test func parsesSections() {
        let sections = WhatsNew.parse("## New\n- One\n- Two\n\n## Fixed\n- Three\n\nA closing line.\n")
        #expect(sections.map(\.title) == ["New", "Fixed"])
        #expect(sections.map(\.items) == [["One", "Two"], ["Three"]])
    }

    @Test func shippedNotesAreThere() {
        #expect(!WhatsNew.sections.isEmpty)
    }
}
