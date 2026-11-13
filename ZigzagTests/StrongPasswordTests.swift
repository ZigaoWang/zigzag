import Foundation
import Testing
import WebKit
@testable import Zigzag

/// A strong password from Use Strong Password: kept pending on its own until the site takes it, never over the
/// account's. Every test runs on a vault held in memory, never the keychain.
@MainActor
struct StrongPasswordTests {
    private func memoryVault() -> PasswordStore { PasswordStore(label: "Zigzag Test memory", synchronizable: false) }

    @Test func aStrongPasswordReplacesTheOldOneOnlyOnceTheSiteTakesIt() async throws {
        let store = memoryVault()
        let site = try #require(Origin(URL(string: "https://example.com")))
        let old = SecretString("old password"), strong = SecretString("Strong-Generated-1")
        let account = try await store.save(origin: site, username: "sam@example.com", password: old)
        // Filled: kept on its own, pending, the account's password untouched.
        let pending = try await PasswordCapture.keepGenerated(strong, origin: site, username: "", replacing: nil, in: store)
        #expect(pending.isPendingGenerated && pending.username.isEmpty)
        #expect(try await store.password(for: account.id).matches(old))
        #expect(try await store.credentials(for: site).count == 2)
        // A password that wasn't one Zigzag made goes the usual way.
        #expect(await !PasswordCapture.settleGenerated(origin: site, username: "sam@example.com", password: SecretString("typed"), in: store))
        // The site took it: the account has the new password, and the pending one goes.
        #expect(await PasswordCapture.settleGenerated(origin: site, username: "Sam@example.com", password: strong, in: store))
        let after = try await store.credentials(for: site)
        #expect(after.map(\.id) == [account.id])
        #expect(try await store.password(for: account.id).matches(strong))
    }

    @Test func aStrongPasswordForANewAccountGetsItsName() async throws {
        let store = memoryVault()
        let site = try #require(Origin(URL(string: "https://signup.example.com")))
        let strong = SecretString("Strong-Generated-2")
        let pending = try await PasswordCapture.keepGenerated(strong, origin: site, username: "", replacing: nil, in: store)
        #expect(await PasswordCapture.settleGenerated(origin: site, username: "newbie", password: strong, in: store))
        let after = try await store.credentials(for: site)
        #expect(after.count == 1 && after.first?.id == pending.id && after.first?.username == "newbie")
        #expect(after.first?.isPendingGenerated == false)
    }

    @Test func withNoUsernameItStaysPendingWhenTheSiteHasOtherAccounts() async throws {
        let store = memoryVault()
        let site = try #require(Origin(URL(string: "https://two.example.com")))
        let strong = SecretString("Strong-Generated-3")
        try await store.save(origin: site, username: "a", password: SecretString("pa"))
        try await store.save(origin: site, username: "b", password: SecretString("pb"))
        let pending = try await PasswordCapture.keepGenerated(strong, origin: site, username: "", replacing: nil, in: store)
        #expect(await PasswordCapture.settleGenerated(origin: site, username: "", password: strong, in: store))
        let kept = try #require(try await store.credentials(for: site).first { $0.id == pending.id })
        #expect(kept.isPendingGenerated)
        #expect(kept.shownUsername == String(localized: "Generated password"))
        // The site's only login, with no username to go by, simply becomes it.
        let solo = try #require(Origin(URL(string: "https://solo.example.com")))
        let only = try await PasswordCapture.keepGenerated(strong, origin: solo, username: "", replacing: nil, in: store)
        #expect(await PasswordCapture.settleGenerated(origin: solo, username: "", password: strong, in: store))
        #expect(try await store.credentials(for: solo).map(\.isPendingGenerated) == [false])
        #expect(try await store.credentials(for: solo).map(\.id) == [only.id])
    }

    /// The form's username, kept with the pending password, says which account it's for even when the form that
    /// sends it (or the page after it) doesn't.
    @Test func thePendingPasswordRemembersTheFormsUsername() async throws {
        let store = memoryVault()
        let site = try #require(Origin(URL(string: "https://linked.example.com")))
        let old = SecretString("old"), strong = SecretString("Strong-Generated-4")
        let sam = try await store.save(origin: site, username: "sam", password: old)
        try await store.save(origin: site, username: "alex", password: SecretString("alex's"))
        let pending = try await PasswordCapture.keepGenerated(strong, origin: site, username: "sam", replacing: nil, in: store)
        #expect(pending.generatedFor == "sam" && pending.username.isEmpty)
        #expect(pending.shownUsername.contains("sam"))
        #expect(await PasswordCapture.settleGenerated(origin: site, username: "", password: strong, in: store))
        #expect(try await store.password(for: sam.id).matches(strong))
        #expect(try await store.credentials(for: site).count == 2)
    }

    /// Making another strong password for the same form replaces the pending one, so trying a few leaves one behind.
    @Test func regeneratingReplacesThePendingPassword() async throws {
        let store = memoryVault()
        let site = try #require(Origin(URL(string: "https://again.example.com")))
        let old = SecretString("old")
        let account = try await store.save(origin: site, username: "sam", password: old)
        let first = try await PasswordCapture.keepGenerated(SecretString("Strong-A"), origin: site, username: "sam", replacing: nil, in: store)
        let second = try await PasswordCapture.keepGenerated(SecretString("Strong-B"), origin: site, username: "sam", replacing: first.id, in: store)
        #expect(second.id == first.id)
        let all = try await store.credentials(for: site)
        #expect(all.count == 2)
        #expect(try await store.password(for: first.id).matches(SecretString("Strong-B")))
        // The one replaced is no longer there to settle; the account keeps its password until the new one is taken.
        #expect(await !PasswordCapture.settleGenerated(origin: site, username: "sam", password: SecretString("Strong-A"), in: store))
        #expect(try await store.password(for: account.id).matches(old))
        // A login that isn't pending (deleted, or settled meanwhile) is never written over: a new pending one is made.
        let settled = try await store.save(origin: site, username: "other", password: SecretString("x"))
        let third = try await PasswordCapture.keepGenerated(SecretString("Strong-C"), origin: site, username: "", replacing: settled.id, in: store)
        #expect(third.id != settled.id)
        #expect(try await store.password(for: settled.id).matches(SecretString("x")))
    }

    /// Saving a typed login never lands on a pending one, which has no username of its own.
    @Test func savingWithNoUsernameLeavesThePendingOneAlone() async throws {
        let store = memoryVault()
        let site = try #require(Origin(URL(string: "https://blank.example.com")))
        let pending = try await PasswordCapture.keepGenerated(SecretString("Strong-D"), origin: site, username: "", replacing: nil, in: store)
        let typed = try await store.save(origin: site, username: "", password: SecretString("typed"))
        #expect(typed.id != pending.id)
        #expect(try await store.password(for: pending.id).matches(SecretString("Strong-D")))
    }

    /// Settling doesn't wait for Offer to save: choosing Use Strong Password was choosing to keep it.
    @Test func aStrongPasswordIsWatchedEvenWithOfferToSaveOff() {
        #expect(PasswordCapture.watches(offersToSave: false, isGenerated: true))
        #expect(PasswordCapture.watches(offersToSave: true, isGenerated: false))
        #expect(!PasswordCapture.watches(offersToSave: false, isGenerated: false))
    }

    /// A page that sends the form by script: settled by the next page or address, but only right after a press that
    /// may have sent it, and only when the form has gone the way a taken login's does.
    @Test func aScriptSentFormSettlesOnlyAfterAPressAndTheFormGoing() {
        let now = Date()
        let gone = PasswordCapture.PageAfterLogin(host: "app.example.com", hasPasswordField: false, passwordFilled: false)
        let back = PasswordCapture.PageAfterLogin(host: "app.example.com", hasPasswordField: true, passwordFilled: false)
        let elsewhere = PasswordCapture.PageAfterLogin(host: "other.org", hasPasswordField: true, passwordFilled: false)
        let pressed = now.addingTimeInterval(-3)
        #expect(PasswordCapture.settlesGenerated(attempted: pressed, now: now, loginHost: "app.example.com", page: gone))
        #expect(PasswordCapture.settlesGenerated(attempted: pressed, now: now, loginHost: "app.example.com", page: elsewhere))
        // The form back, empty: the site turned it down.
        #expect(!PasswordCapture.settlesGenerated(attempted: pressed, now: now, loginHost: "app.example.com", page: back))
        // No press: a link followed, or an address typed, never settles it.
        #expect(!PasswordCapture.settlesGenerated(attempted: nil, now: now, loginHost: "app.example.com", page: gone))
        // A press long before isn't this page's cause.
        let stale = now.addingTimeInterval(-(PasswordCapture.attemptCountsFor + 1))
        #expect(!PasswordCapture.settlesGenerated(attempted: stale, now: now, loginHost: "app.example.com", page: gone))
    }

    /// The update prompt giving the account the strong password by hand clears the pending one.
    @Test func updatingTheAccountByHandDropsThePendingOne() async throws {
        let store = memoryVault()
        let site = try #require(Origin(URL(string: "https://prompt.example.com")))
        let strong = SecretString("Strong-E")
        try await store.save(origin: site, username: "sam", password: SecretString("old"))
        _ = try await PasswordCapture.keepGenerated(strong, origin: site, username: "", replacing: nil, in: store)
        await PasswordCapture.dropGenerated(origin: site, password: SecretString("not it"), in: store)
        #expect(try await store.credentials(for: site).count == 2)
        await PasswordCapture.dropGenerated(origin: site, password: strong, in: store)
        #expect(try await store.credentials(for: site).map(\.username) == ["sam"])
    }
}
