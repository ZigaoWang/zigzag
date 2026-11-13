import Foundation
import Testing
import WebKit
@testable import Zigzag

/// A strong password from Use Strong Password: kept on its own until the site takes it, never over the account's.
@MainActor
struct StrongPasswordTests {
    @Test func aStrongPasswordReplacesTheOldOneOnlyOnceTheSiteTakesIt() async throws {
        let store = PasswordStore(label: "Zigzag Test memory", synchronizable: false)
        let site = try #require(Origin(URL(string: "https://example.com")))
        let old = SecretString("old password"), strong = SecretString("Strong-Generated-1")
        let account = try await store.save(origin: site, username: "sam@example.com", password: old)
        // Filled: kept on its own, the account's password untouched.
        try await store.save(origin: site, username: "", password: strong, replacingExisting: false)
        #expect(try await store.password(for: account.id).matches(old))
        #expect(try await store.credentials(for: site).count == 2)
        // A password that wasn't one Zigzag made goes the usual way.
        #expect(await !PasswordCapture.settleGenerated(origin: site, username: "sam@example.com", password: SecretString("typed"), in: store))
        // The site took it: the account has the new password, and the stand-in goes.
        #expect(await PasswordCapture.settleGenerated(origin: site, username: "Sam@example.com", password: strong, in: store))
        let after = try await store.credentials(for: site)
        #expect(after.map(\.id) == [account.id])
        #expect(try await store.password(for: account.id).matches(strong))
    }

    @Test func aStrongPasswordForANewAccountGetsItsName() async throws {
        let store = PasswordStore(label: "Zigzag Test memory", synchronizable: false)
        let site = try #require(Origin(URL(string: "https://signup.example.com")))
        let strong = SecretString("Strong-Generated-2")
        let stand = try await store.save(origin: site, username: "", password: strong, replacingExisting: false)
        // With no username to go by, it stays as it is.
        #expect(await PasswordCapture.settleGenerated(origin: site, username: "", password: strong, in: store))
        #expect(try await store.credentials(for: site).first?.username == "")
        #expect(await PasswordCapture.settleGenerated(origin: site, username: "newbie", password: strong, in: store))
        let after = try await store.credentials(for: site)
        #expect(after.count == 1 && after.first?.id == stand.id && after.first?.username == "newbie")
    }
}
