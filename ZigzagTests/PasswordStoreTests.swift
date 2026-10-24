import Foundation
import OSLog
import Testing
@testable import Zigzag

/// The vault against the real data protection keychain. Each test uses its own label and no iCloud sync, so the
/// person's saved passwords are never seen, changed or synced, and everything is deleted afterwards.
@Suite(.serialized) struct PasswordStoreTests {
    let store = PasswordStore(label: "Zigzag Tests \(UUID().uuidString)", synchronizable: false)
    let github = Origin(URL(string: "https://github.com/login"))!

    @Test func savesListsAndReadsALogin() async throws {
        defer { Task { await store.deleteAll() } }
        let secret = SecretString("correct horse battery staple")
        let saved = try await store.save(origin: github, username: "octocat", password: secret)
        let all = try await store.all()
        #expect(all.map(\.id) == [saved.id])
        #expect(all.first?.username == "octocat")
        #expect(try await store.password(for: saved.id).matches(secret))
        await store.deleteAll()
    }

    @Test func savingTheSameLoginAgainUpdatesIt() async throws {
        let first = try await store.save(origin: github, username: "octocat", password: SecretString("old"))
        let second = try await store.save(origin: github, username: "octocat", password: SecretString("new"))
        #expect(first.id == second.id)
        #expect(try await store.all().count == 1)
        #expect(try await store.password(for: first.id).matches(SecretString("new")))
        await store.deleteAll()
    }

    @Test func findsOnlyTheExactOrigin() async throws {
        try await store.save(origin: github, username: "octocat", password: SecretString("a"))
        try await store.save(origin: Origin(URL(string: "https://gist.github.com"))!, username: "octocat", password: SecretString("b"))
        try await store.save(origin: Origin(URL(string: "http://github.com"))!, username: "octocat", password: SecretString("c"))
        #expect(try await store.credentials(for: github).count == 1)
        #expect(try await store.credentials(for: Origin(URL(string: "https://github.com.evil.test"))!).isEmpty)
        await store.deleteAll()
    }

    @Test func deletesALogin() async throws {
        let saved = try await store.save(origin: github, username: "octocat", password: SecretString("a"))
        try await store.delete(saved.id)
        #expect(try await store.all().isEmpty)
        await #expect(throws: PasswordStore.Failure.self) { try await store.password(for: saved.id) }
        await store.deleteAll()
    }

    @Test func remembersNeverSaveForASite() async throws {
        #expect(await !store.neverSaves(on: github))
        await store.setNeverSave(true, on: github)
        #expect(await store.neverSaves(on: github))
        await store.setNeverSave(false, on: github)
        #expect(await !store.neverSaves(on: github))
        await store.deleteAll()
    }

    // MARK: Never in plain text

    @Test func secretsNeverPrint() {
        let secret = SecretString("hunter2-\(UUID().uuidString)")
        #expect("\(secret)" == "<redacted>")
        #expect(String(describing: secret) == "<redacted>")
        #expect(String(reflecting: secret) == "<redacted>")
        var dumped = ""
        dump(secret, to: &dumped)
        secret.withUnsafeString { #expect(!dumped.contains($0)) }
    }

    /// Fails if a password Zigzag handled shows up in its unified log or in any file it writes.
    @Test func passwordsNeverReachLogsOrFiles() async throws {
        let marker = "zz-secret-\(UUID().uuidString)"
        let start = Date()
        let saved = try await store.save(origin: github, username: "octocat", password: SecretString(marker))
        _ = try await store.password(for: saved.id)
        let updated = try await store.save(origin: github, username: "octocat", password: SecretString(marker + "-changed"))
        _ = try await store.password(for: updated.id)
        try await store.delete(saved.id)
        await store.deleteAll()

        let logStore = try OSLogStore(scope: .currentProcessIdentifier)
        let entries = try logStore.getEntries(at: logStore.position(date: start))
        #expect(!entries.contains { $0.composedMessage.contains(marker) })

        let support = Paths.support
        let files = FileManager.default.enumerator(at: support, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = files?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
            #expect(data.range(of: Data(marker.utf8)) == nil, "found in \(url.lastPathComponent)")
        }
    }
}

struct OriginTests {
    @Test func defaultPortsAreTheSameOrigin() {
        #expect(Origin(URL(string: "https://example.com:443/a")) == Origin(URL(string: "https://example.com/b")))
        #expect(Origin(URL(string: "http://example.com:80")) == Origin(URL(string: "http://example.com")))
        #expect(Origin(URL(string: "https://example.com:8443")) != Origin(URL(string: "https://example.com")))
    }

    @Test func schemeAndHostMustMatch() {
        #expect(Origin(URL(string: "http://example.com")) != Origin(URL(string: "https://example.com")))
        #expect(Origin(URL(string: "https://EXAMPLE.com")) == Origin(URL(string: "https://example.com")))
        #expect(Origin(URL(string: "https://example.com.evil.test")) != Origin(URL(string: "https://example.com")))
    }

    @Test func onlyWebPagesHaveOrigins() {
        #expect(Origin(URL(string: "file:///Users/me/a.html")) == nil)
        #expect(Origin(URL(string: "webkit-extension://abc/popup.html")) == nil)
        #expect(Origin(nil) == nil)
    }
}
