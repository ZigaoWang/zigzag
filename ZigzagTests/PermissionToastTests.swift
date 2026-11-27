import Foundation
import Testing
@testable import Zigzag

/// The toast after a permission is allowed (#545): one line saying where it can be changed. A change reaches the page
/// that is open, without a reload; one kept for the page alone has the page ask again next time.
@MainActor
@Suite(.serialized)
struct PermissionToastTests {
    @Test func aRememberedAnswerSaysItCanBeChanged() {
        let line = PermissionToast.line(name: "Camera", remembered: true)
        #expect(line.contains("Camera"))
        #expect(line.contains("change this"))
        #expect(line.contains("Site Controls"))
    }

    @Test func aPageOnlyAnswerSaysItCanBeChanged() {
        let line = PermissionToast.line(name: "Microphone", remembered: false)
        #expect(line.contains("Microphone"))
        #expect(line.contains("this page"))
        #expect(line.contains("change this"))
        // The toast says what is true of a page-only answer and points at the one place that changes it.
        #expect(line == "Microphone allowed for this page. You can change this in Site Controls.")
    }

    @Test func everyLivePermissionHasAName() {
        #expect(PermissionToast.name("camera") == "Camera")
        #expect(PermissionToast.name("microphone") == "Microphone")
        #expect(PermissionToast.name("location") == "Location")
        #expect(PermissionToast.name(PermissionSubject.notifications) == "Notifications")
        #expect(PermissionToast.name(PermissionSubject.screen) == "Screen Sharing")
        // Nothing sensible to say for the rest.
        #expect(PermissionToast.name("popups") == nil)
        #expect(PermissionToast.name("apps") == nil)
    }
}
