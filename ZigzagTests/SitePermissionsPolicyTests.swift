import Foundation
import Testing
@testable import Zigzag

@Suite(.serialized) struct SitePermissionsPolicyTests {
    let defaults = UserDefaults(suiteName: "SitePermissionsPolicyTests")!
    init() { defaults.removePersistentDomain(forName: "SitePermissionsPolicyTests"); SitePermissions.defaults = defaults }
    deinit { SitePermissions.defaults = .standard }

    @Test func remembersAnActionPerSubjectAndOrigin() {
        SitePermissions.remember("mini", subject: PermissionSubject.popups, origin: "https://example.com")
        #expect(SitePermissions.action(PermissionSubject.popups, origin: "https://example.com") == "mini")
        #expect(SitePermissions.action(PermissionSubject.popups, origin: "https://other.com") == nil)
    }

    @Test func forgetForgetsOnlyThatSubject() {
        SitePermissions.remember("deny", subject: PermissionSubject.location, origin: "https://example.com")
        SitePermissions.remember("allow", subject: PermissionSubject.notifications, origin: "https://example.com")
        SitePermissions.remember(nil, subject: PermissionSubject.location, origin: "https://example.com")
        #expect(SitePermissions.action(PermissionSubject.location, origin: "https://example.com") == nil)
        #expect(SitePermissions.action(PermissionSubject.notifications, origin: "https://example.com") == "allow")
    }

    @Test func migratesOldBoolsOnce() {
        defaults.set(["https://example.com|camera": true, "https://example.com|popups": false,
                      "https://example.com|app:zoommtg": true], forKey: "SitePermissions")
        SitePermissions.migrateAnswersToActions()
        #expect(SitePermissions.action(PermissionSubject.media(.camera), origin: "https://example.com") == "allow")
        #expect(SitePermissions.action(PermissionSubject.popups, origin: "https://example.com") == "deny")
        #expect(SitePermissions.action(PermissionSubject.app("zoommtg"), origin: "https://example.com") == "allow")
    }

    @Test func siteWideAppDenyWinsOverAPerAppAllow() {
        SitePermissions.remember("allow", subject: PermissionSubject.app("zoommtg"), origin: "https://example.com")
        SitePermissions.remember("deny", subject: PermissionSubject.apps, origin: "https://example.com")
        #expect(SitePermissions.action(PermissionSubject.app("zoommtg"), origin: "https://example.com") == "deny")
    }

    @Test func deletingARuleForgetsItsHandoffAnswers() {
        let rule = UUID()
        SitePermissions.remember("handOff", subject: PermissionSubject.handoff(rule), origin: "https://a.com")
        SitePermissions.remember("browser", subject: PermissionSubject.handoff(rule), origin: "https://b.com")
        SitePermissions.forgetActions(prefix: "handoff:\(rule.uuidString)")
        #expect(SitePermissions.actions(origin: "https://a.com").isEmpty)
        #expect(SitePermissions.actions(origin: "https://b.com").isEmpty)
    }
}
