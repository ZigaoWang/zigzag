import Foundation
import Testing
import WebKit
@testable import Zigzag

/// Help › Report a Problem tells a site that never answers from a slow one, by when each step of the load came (#548).
@MainActor
@Suite(.serialized)
struct LoadTimingsTests {
    nonisolated private static func respond(method: String, path: String) -> LocalPageServer.Reply? {
        path.hasPrefix("/stall") ? nil : .html("<!doctype html><title>page</title>")
    }

    private func notes(since start: Date) -> [Diagnostics.Event] {
        Diagnostics.events.filter { $0.date >= start && ["Page is slow to load", "Slow page load"].contains($0.kind) && $0.site == "127.0.0.1" }
    }

    @Test func aServerThatNeverAnswersIsNotedAsWaitingForIt() async throws {
        let server = try LocalPageServer(Self.respond)
        let site = try await server.start()
        defer { server.stop() }
        let start = Date()
        let tab = Tab(url: nil, spaceID: UUID())
        defer { tab.close() }
        tab.loadTimings.limits = .init(firstByte: 0.5, commit: 1)
        tab.load(URL(string: site.absoluteString + "/stall/secret-path?token=abc")!)
        _ = tab.ensureWebView()
        for _ in 0..<60 where notes(since: start).isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        let noted = try #require(notes(since: start).first)
        #expect(noted.kind == "Page is slow to load")
        #expect(noted.detail?.hasPrefix("waiting for the server for ") == true)
        let report = Diagnostics.lines(since: start).joined(separator: "\n")
        #expect(report.contains("Page is slow to load  127.0.0.1  waiting for the server for"))
        // The site only, never where on it.
        #expect(!report.contains("secret-path") && !report.contains("token"))
    }

    @Test func aNormalLoadNotesNothing() async throws {
        let server = try LocalPageServer(Self.respond)
        let site = try await server.start()
        defer { server.stop() }
        let start = Date()
        let tab = Tab(url: nil, spaceID: UUID())
        defer { tab.close() }
        tab.loadTimings.limits = .init(firstByte: 0.5, commit: 1)
        tab.load(URL(string: site.absoluteString + "/page")!)
        let page = tab.ensureWebView()
        for _ in 0..<100 where page.isLoading || page.title != "page" { try await Task.sleep(for: .milliseconds(50)) }
        #expect(page.title == "page")
        try await Task.sleep(for: .milliseconds(1500))
        #expect(notes(since: start).isEmpty)
    }

    @Test func aPrivateWindowsLoadIsNeverTimed() async throws {
        let server = try LocalPageServer(Self.respond)
        let site = try await server.start()
        defer { server.stop() }
        let start = Date()
        let timings = LoadTimings()
        timings.limits = .init(firstByte: 0.2, commit: 0.4)
        timings.started(nil, url: URL(string: site.absoluteString + "/stall")!, isPrivate: true)
        try await Task.sleep(for: .milliseconds(700))
        timings.finished(nil)
        #expect(notes(since: start).isEmpty)
    }

    @Test func eachStepIsSaidInSeconds() {
        var load = LoadTimings.Load()
        #expect(load.detail(at: 10) == "waiting for the server for 10.0 s")
        load.redirects = 2
        load.lastRedirect = 0.3
        #expect(load.detail(at: 12) == "waiting for the server for 12.0 s, 2 redirects, last at 0.3 s")
        load.firstByte = 14.06
        #expect(load.detail(at: 30) == "receiving the page for 30.0 s, 2 redirects, last at 0.3 s, answered at 14.1 s")
        load.commit = 31
        #expect(load.outcome("loaded", at: 33.4) == "loaded at 33.4 s, 2 redirects, answered at 14.1 s, shown at 31.0 s")
        #expect(LoadTimings.Load().outcome("failed", at: 60) == "failed at 60.0 s, no answer")
    }
}
