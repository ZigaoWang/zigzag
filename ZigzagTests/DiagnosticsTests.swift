import Foundation
import Testing
@testable import Zigzag

/// The diagnostics record names sites, never addresses or anything personal a page's error might quote.
struct DiagnosticsTests {
    @Test func addressesShrinkToTheirSite() {
        let text = Diagnostics.clean("Failed to fetch https://login.example.com/oauth?token=secret#frag from page")
        #expect(text == "Failed to fetch login.example.com from page")
        #expect(!Diagnostics.clean("see http://a.b/c?d=e").contains("d=e"))
    }

    @Test func emailsAreHidden() {
        #expect(Diagnostics.clean("No account for sam@example.com") == "No account for (email)")
    }

    @Test func longTextIsCut() {
        let text = Diagnostics.clean(String(repeating: "x", count: 500))
        #expect(text.count == 201)
        #expect(text.hasSuffix("…"))
    }

    @Test func linesAreOne() {
        #expect(!Diagnostics.clean("one\ntwo").contains("\n"))
    }

    /// A private window's event keeps only its error code: the text could name the site.
    @Test func privateWindowsKeepOnlyTheCode() {
        let kind = "Test private \(UUID().uuidString)"
        let started = Date()
        defer { Diagnostics.forget(since: started) }
        Diagnostics.note(kind, site: "bank.example", "This server could be pretending to be “bank.example” (NSURLErrorDomain -1202)", isPrivate: true)
        let event = Diagnostics.events.last { $0.kind == kind }
        #expect(event?.site == nil)
        #expect(event?.detail == "(NSURLErrorDomain -1202)")
    }

    @Test func errorsNameTheirCode() {
        let error = NSError(domain: NSURLErrorDomain, code: -1200, userInfo: [NSLocalizedDescriptionKey: "Secure connection failed"])
        #expect(Diagnostics.describe(error) == "Secure connection failed (NSURLErrorDomain -1200)")
    }
}

/// An exception AppKit caught after it left a Swift job: test builds crash on it, the app notes it. Left to AppKit,
/// it leaves the concurrency runtime pointing at the job's freed frame, where a later isolated deinit crashed.
@MainActor
struct SwallowedExceptionTests {
    /// Keeps the frames its isolated deinit ran in.
    private final class Recorder {
        static var frames: [String] = []
        isolated deinit { Self.frames = Thread.callStackSymbols }
    }

    /// The frames of an isolated deinit run as a job: let go of off the main thread, it hops back as one.
    private func framesInADeinitJob() async throws -> [String] {
        Recorder.frames = []
        nonisolated(unsafe) var recorder: Recorder? = Recorder()
        DispatchQueue.global().async { recorder = nil }
        let end = Date().addingTimeInterval(5)
        while Recorder.frames.isEmpty, Date() < end { try await Task.sleep(for: .milliseconds(10)) }
        return try #require(Recorder.frames.isEmpty ? nil : Recorder.frames)
    }

    @Test func thrownInADeinitJobAndCaughtOutsideItCrashesTestBuilds() async throws {
        let thrownAt = try await framesInADeinitJob()
        let action = ZigzagApplication.jobException(name: "NSGenericException", reason: "gone", thrownAt: thrownAt,
                                                    caughtAt: Thread.callStackSymbols, crashes: true)
        guard case .crash(let message)? = action else { Issue.record("not a crash: \(String(describing: action))"); return }
        #expect(message.hasPrefix("Exception thrown out of a Swift job: NSGenericException: gone\n"))
        #expect(message.contains("swift_job_run"))
    }

    @Test func theAppNotesItForReportAProblem() async throws {
        let thrownAt = try await framesInADeinitJob()
        let action = ZigzagApplication.jobException(name: "NSGenericException", reason: "gone", thrownAt: thrownAt,
                                                    caughtAt: Thread.callStackSymbols, crashes: false)
        guard case .note(let kind, let detail)? = action else { Issue.record("not a note: \(String(describing: action))"); return }
        #expect(kind == "Exception thrown out of a Swift job")
        #expect(detail.hasPrefix("NSGenericException: gone | "))
        #expect(detail.components(separatedBy: " | ").count == 9)
    }

    @Test func caughtWhereItWasThrownIsLeftToAppKit() async throws {
        let here = Thread.callStackSymbols
        #expect(ZigzagApplication.jobException(name: "N", reason: nil, thrownAt: here, caughtAt: here, crashes: true) == nil)
        let inJob = try await framesInADeinitJob()
        #expect(ZigzagApplication.jobException(name: "N", reason: nil, thrownAt: inJob, caughtAt: inJob, crashes: true) == nil)
        #expect(ZigzagApplication.jobException(name: "N", reason: nil, thrownAt: [], caughtAt: inJob, crashes: false) == nil)
    }
}
