import AppKit
import OSLog

/// Help › Report a Problem: a plain text report to go with an email, so a bug arrives with what's needed to find it.
/// It holds which Zigzag, macOS and Mac, how much is open, a few settings, the extensions, crash and freeze reports
/// (`CrashReports`), and Zigzag's own recent log. Never a page, a tab's address, history or anything else from your
/// browsing. It's written to a file you can read first, and goes nowhere until you send it.
@MainActor
enum ProblemReport {
    static let file = CrashReports.folder.appendingPathComponent("Zigzag Problem Report.txt")

    static func show(in controller: BrowserWindowController) {
        ConfirmSheet.choose(in: controller.root.overlay, title: "Report a problem",
                            message: "Zigzag writes a short report for your email: its version, your Mac, crash and freeze reports, and its own recent log. Never your pages, tabs or history. Show Report lets you read it first.",
                            confirmTitle: "Email Report", alternateTitle: "Show Report") { choice in
            guard choice != .cancel, let report = write() else { return }
            switch choice {
            case .confirm: email(report, in: controller)
            case .alternate: NSWorkspace.shared.activateFileViewerSelecting([report])
            case .cancel: break
            }
        }
    }

    /// A new message in your mail app with the report attached, and the crash reports' own files with it. Without a
    /// mail app that takes attachments, a plain email opens and the report is shown in Finder, to drag in.
    private static func email(_ report: URL, in controller: BrowserWindowController) {
        let attachments = [report] + CrashReports.recent.prefix(5).map(\.json).filter { FileManager.default.fileExists(atPath: $0.path) }
        let body = "What happened, and what were you doing just before?\n\n\n" + Feedback.versions
        if let mail = NSSharingService(named: .composeEmail) {
            mail.recipients = [Feedback.address]
            mail.subject = "Zigzag problem report"
            let items: [Any] = [body] + attachments
            if mail.canPerform(withItems: items) { mail.perform(withItems: items); return }
        }
        var parts = URLComponents()
        parts.scheme = "mailto"
        parts.path = Feedback.address
        parts.queryItems = [URLQueryItem(name: "subject", value: "Zigzag problem report"), URLQueryItem(name: "body", value: body)]
        if let url = parts.url { NSWorkspace.shared.open(url) }
        NSWorkspace.shared.activateFileViewerSelecting([report])
        Toast.show("Attach the report from Finder to your email", symbol: "paperclip", duration: 6, in: controller)
    }

    /// Writes the report and returns where, or nil if it couldn't be saved.
    static func write() -> URL? {
        try? FileManager.default.createDirectory(at: CrashReports.folder, withIntermediateDirectories: true)
        do {
            try Data(text.utf8).write(to: file, options: .atomic)
            return file
        } catch {
            return nil
        }
    }

    static var text: String {
        var lines = ["Zigzag problem report", "Written \(Date().formatted(date: .abbreviated, time: .standard))", ""]
        lines.append(Feedback.versions.trimmingCharacters(in: .whitespacesAndNewlines))
        lines.append("Mac: \(systemValue("hw.model") ?? "unknown"), \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB memory, \(ProcessInfo.processInfo.activeProcessorCount) cores")
        lines.append("Zigzag running for \(Duration.seconds(ProcessInfo.processInfo.systemUptime - launchUptime).formatted(.units(allowed: [.hours, .minutes], width: .wide)))")

        let controllers = WindowManager.shared.controllers
        let tabs = controllers.flatMap(\.tabManager.allTabs)
        lines += ["", "Open now"]
        func count(_ n: Int, _ one: String) -> String { "\(n) \(one)\(n == 1 ? "" : "s")" }
        lines.append("\(count(controllers.count, "window")) (\(controllers.filter(\.tabManager.isPrivate).count) private), \(count(Library.shared.spaces.count, "space"))")
        lines.append("\(count(tabs.count, "tab")), \(tabs.filter { !$0.isSuspended }.count) loaded")

        lines += ["", "Settings"]
        lines.append("Ad blocking \(ContentBlocker.isEnabled ? "on" : "off")")
        lines.append("Reduce motion \(Tokens.Motion.reduceMotion ? "on" : "off")")

        lines += ["", "Extensions"]
        let ids = ExtensionStore.installedIDs
        if ids.isEmpty { lines.append("None") }
        for id in ids {
            let name = ExtensionHost.shared.context(for: id)?.webExtension.displayName ?? id
            let version = ExtensionStore.state(id)?.version ?? "?"
            lines.append("\(name) \(version), \(ExtensionStore.isEnabled(id) ? "on" : "off")")
        }

        lines += ["", "Crashes and freezes, last two weeks"]
        let reports = CrashReports.recent
        if reports.isEmpty { lines.append("None reported by macOS") }
        for report in reports {
            lines.append("\(report.date.formatted(date: .abbreviated, time: .shortened)): \(report.summary)")
        }

        lines += ["", "Zigzag’s log, last 30 minutes"]
        let log = recentLog
        lines += log.isEmpty ? ["Nothing logged"] : log
        return lines.joined(separator: "\n") + "\n"
    }

    /// When Zigzag started, as the system clock counts.
    private static let launchUptime: TimeInterval = {
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard Darwin.sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return ProcessInfo.processInfo.systemUptime }
        let started = Date(timeIntervalSince1970: TimeInterval(info.kp_proc.p_starttime.tv_sec))
        return ProcessInfo.processInfo.systemUptime - Date().timeIntervalSince(started)
    }()

    /// Zigzag's own messages only (not WebKit's or the system's), as macOS stored them: anything personal in them
    /// shows as <private>.
    private static var recentLog: [String] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return [] }
        let since = store.position(date: Date().addingTimeInterval(-30 * 60))
        let ours = NSPredicate(format: "subsystem BEGINSWITH %@", "wang.zigao.zigzag")
        guard let entries = try? store.getEntries(at: since, matching: ours) else { return [] }
        let lines = entries.compactMap { $0 as? OSLogEntryLog }.map { entry in
            "\(entry.date.formatted(date: .omitted, time: .standard)) [\(entry.category)] \(entry.composedMessage)"
        }
        return Array(lines.suffix(300))
    }

    private static func systemValue(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(cString: bytes)
    }
}
