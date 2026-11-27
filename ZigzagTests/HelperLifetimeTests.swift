import Foundation
import Testing
@testable import Zigzag

/// Zigzag's helpers end when the app they serve does, however it ends (HelperLifetime.swift).
@Suite(.serialized)
struct HelperLifetimeTests {
    /// This build started as a bare client of a helper (HelperProbe.swift), and the helper's process ID.
    private func probe(_ kind: String) throws -> (client: Process, helper: pid_t) {
        let client = Process()
        client.executableURL = try #require(Bundle.main.executableURL)
        // Nothing of the test host's: no test injection, no settings of its own.
        client.environment = ["ZIGZAG_HELPER_PROBE": kind, "HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"]
        let output = Pipe()
        client.standardOutput = output
        client.standardError = FileHandle.nullDevice
        try client.run()
        let read = Output()
        output.fileHandleForReading.readabilityHandler = { read.append($0.availableData) }
        defer { output.fileHandleForReading.readabilityHandler = nil }
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, client.isRunning {
            if let pid = read.helper { return (client, pid) }
            Thread.sleep(forTimeInterval: 0.05)
        }
        client.terminate()
        client.waitUntilExit()
        Issue.record("the \(kind) helper never answered")
        throw CancellationError()
    }

    @Test(arguments: ["picture", "pdf", "pdf-own"])
    func aHelperEndsWhenItsAppIsKilled(kind: String) async throws {
        let (client, helper) = try probe(kind)
        #expect(helper > 0 && helper != client.processIdentifier)
        #expect(SafePDFTests.isRunning(helper))
        kill(client.processIdentifier, SIGKILL)
        client.waitUntilExit()
        #expect(await SafePDFTests.ends(helper, within: 5))
    }
}

/// What a probe printed so far.
nonisolated private final class Output: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func append(_ data: Data) { lock.withLock { text += String(decoding: data, as: UTF8.self) } }

    var helper: pid_t? {
        lock.withLock {
            text.split(separator: "\n").lazy.compactMap { line in
                line.hasPrefix("helper ") ? pid_t(line.dropFirst("helper ".count)) : nil
            }.first
        }
    }
}
