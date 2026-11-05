import Foundation
import MetricKit

/// Crash and freeze reports for Zigzag, as macOS collects them (MetricKit hands them over, usually the next day).
/// They're kept on this Mac only, in "Diagnostics", and go nowhere unless you attach them to a report yourself
/// (Help › Report a Problem). Only the last two weeks, and at most 20, are kept.
final class CrashReports: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashReports()
    static let folder = Paths.support.appendingPathComponent("Diagnostics", isDirectory: true)
    private static let keepFor: TimeInterval = 14 * 24 * 3600
    private static let keepAtMost = 20

    func start() {
        MXMetricManager.shared.add(self)
        // Some arrive before launch finishes: those already waiting are handed over too.
        save(MXMetricManager.shared.pastDiagnosticPayloads)
        Self.prune()
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let saved = payloads.map { ($0.timeStampEnd, $0.jsonRepresentation(), Self.summary(of: $0)) }
        Task { @MainActor in self.write(saved) }
    }

    private func save(_ payloads: [MXDiagnosticPayload]) {
        write(payloads.map { ($0.timeStampEnd, $0.jsonRepresentation(), Self.summary(of: $0)) })
    }

    private func write(_ payloads: [(Date, Data, String)]) {
        guard !payloads.isEmpty else { return }
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        for (date, json, summary) in payloads where !summary.isEmpty {
            let name = "\(Int(date.timeIntervalSince1970))"
            try? json.write(to: Self.folder.appendingPathComponent(name + ".json"), options: .atomic)
            try? Data(summary.utf8).write(to: Self.folder.appendingPathComponent(name + ".txt"), options: .atomic)
        }
        Self.prune()
    }

    /// "2 crashes, 1 freeze": what a payload holds, in words, or "" when it holds neither.
    nonisolated private static func summary(of payload: MXDiagnosticPayload) -> String {
        var parts: [String] = []
        for crash in payload.crashDiagnostics ?? [] {
            let meta = crash.metaData
            parts.append("Crash in Zigzag \(meta.applicationBuildVersion): \(crash.exceptionType.map { "exception \($0)" } ?? "")"
                + "\(crash.signal.map { " signal \($0)" } ?? "")\(crash.terminationReason.map { ", \($0)" } ?? "")")
        }
        for hang in payload.hangDiagnostics ?? [] {
            parts.append("Freeze of \(hang.hangDuration.formatted()) in Zigzag \(hang.metaData.applicationBuildVersion)")
        }
        return parts.joined(separator: "\n")
    }

    /// The reports kept now, newest first: when, and what happened.
    static var recent: [(date: Date, summary: String, json: URL)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "txt" }.compactMap { txt in
            guard let seconds = TimeInterval(txt.deletingPathExtension().lastPathComponent),
                  let summary = try? String(contentsOf: txt, encoding: .utf8) else { return nil }
            return (Date(timeIntervalSince1970: seconds), summary, txt.deletingPathExtension().appendingPathExtension("json"))
        }.sorted { $0.date > $1.date }
    }

    private static func prune() {
        let old = Date().addingTimeInterval(-keepFor)
        for (i, report) in recent.enumerated() where i >= keepAtMost || report.date < old {
            try? FileManager.default.removeItem(at: report.json)
            try? FileManager.default.removeItem(at: report.json.deletingPathExtension().appendingPathExtension("txt"))
        }
    }
}
