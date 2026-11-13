import Foundation
import Testing
@testable import Zigzag

/// Developer Mode on a tab's row (#141): which parts get the dashed edge, and when the host's line shows.
struct DeveloperModeRowTests {
    @Test func aRowOfOnePageInDeveloperModeHasTheEdgeAndTheLine() {
        #expect(TabRowView.developerMarks(inMode: [true], renaming: false) == ([0], true))
        #expect(TabRowView.developerMarks(inMode: [false], renaming: false) == ([], false))
        // Renaming, the field has the row: the edge stays, the line goes.
        #expect(TabRowView.developerMarks(inMode: [true], renaming: true) == ([0], false))
    }

    @Test func aRowOfSeveralPagesEdgesEachPartInDeveloperModeWithoutTheLine() {
        #expect(TabRowView.developerMarks(inMode: [false, true], renaming: false) == ([1], false))
        #expect(TabRowView.developerMarks(inMode: [true, true], renaming: false) == ([0, 1], false))
        #expect(TabRowView.developerMarks(inMode: [true, false, false, true], renaming: false) == ([0, 3], false))
        #expect(TabRowView.developerMarks(inMode: [false, false, false], renaming: false) == ([], false))
    }

    @Test func theLineSaysTheHostWithItsPortAndWithoutWWW() {
        #expect(TabRowView.hostLineText(for: URL(string: "https://www.Example.com/docs?x=1")) == "example.com")
        #expect(TabRowView.hostLineText(for: URL(string: "http://localhost:3000/admin")) == "localhost:3000")
        #expect(TabRowView.hostLineText(for: URL(string: "https://app.example.com:8443/")) == "app.example.com:8443")
        #expect(TabRowView.hostLineText(for: URL(string: "http://[::1]:5173/")) == "[::1]:5173")
        #expect(TabRowView.hostLineText(for: nil) == nil)
        #expect(TabRowView.hostLineText(for: URL(string: "file:///tmp/index.html")) == nil)
    }

    /// A page whose title is its host already (a dev server's error page, a bare page) isn't said twice.
    @Test func aTitleThatIsTheHostIsNotSaidTwice() {
        #expect(TabRowView.hostLineText(for: URL(string: "http://localhost:3000/"), title: "localhost:3000") == nil)
        #expect(TabRowView.hostLineText(for: URL(string: "http://localhost:3000/"), title: "My App") == "localhost:3000")
    }
}
