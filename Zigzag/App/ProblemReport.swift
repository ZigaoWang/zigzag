import AppKit

/// Help › Report a Problem: a plain text report to go with an email, so a bug arrives with what's needed to find it.
/// It holds which Zigzag, macOS and Mac, how much is open, a few settings, the extensions, what went wrong lately and
/// on which sites (`Diagnostics`), and crash and freeze reports (`CrashReports`). Never a page's address, a tab, history
/// or anything you typed. It's written to a file you can read first, and goes nowhere until you send it.
@MainActor
enum ProblemReport {
    nonisolated static let file = CrashReports.folder.appendingPathComponent("Zigzag Problem Report.txt")

    static func show(in controller: BrowserWindowController) {
        ConfirmSheet.choose(in: controller.root.overlay, title: "Report a problem",
                            message: "Zigzag writes a short report for your email: its version, your Mac, what went wrong lately and on which sites, and crash and freeze reports. Never the pages’ addresses, your tabs or history. Show Report lets you read it first.",
                            confirmTitle: "Email Report", alternateTitle: "Show Report") { choice in
            guard choice != .cancel else { return }
            Task { @MainActor in
                // Written away from the window, so it never stops; anything slower than a moment says it's working.
                let notice = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    if !Task.isCancelled { Toast.working("Writing report…", in: controller) }
                }
                let report = await write()
                notice.cancel()
                Toast.hide(in: controller)
                guard let report else {
                    Toast.show("Couldn’t write the report", symbol: "exclamationmark.triangle", duration: 3, in: controller)
                    return
                }
                if choice == .confirm { email(report, in: controller) } else { NSWorkspace.shared.activateFileViewerSelecting([report]) }
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

    /// Writes the report and returns where, or nil if it couldn't be saved. What's open is read here, the rest
    /// (the crash reports on disk, the file itself) away from the main thread.
    static func write() async -> URL? {
        let summary = openNow
        let destination = file
        return await Task.detached(priority: .userInitiated) { () -> URL? in
            try? FileManager.default.createDirectory(at: CrashReports.folder, withIntermediateDirectories: true)
            let text = summary + recent + crashes + extensionLog
            return (try? Data(text.utf8).write(to: destination, options: .atomic)) == nil ? nil : destination
        }.value
    }

    /// Everything but the crash reports: versions, the Mac, what's open and the settings that matter.
    static var openNow: String {
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

        return lines.joined(separator: "\n") + "\n"
    }

    /// What went wrong lately, newest last: the heart of the report.
    nonisolated static var recent: String {
        let lines = Diagnostics.lines()
        return (["", "What happened recently"] + (lines.isEmpty ? ["Nothing went wrong that Zigzag noticed"] : lines))
            .joined(separator: "\n") + "\n"
    }

    /// The latest errors in the extensions log, when there are any: an extension that stalls usually says why there.
    nonisolated static var extensionLog: String {
        let name = Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true ? "Zigzag Dev" : "Zigzag"
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/\(name)/extensions.log")
        guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else { return "" }
        // Its errors only: the comings and goings of a password manager's connection are noise here.
        let problems = text.split(separator: "\n").map(String.init).filter { line in
            ["error", "rejection", "failed", "couldn", "crash", "http 4", "http 5", "invalid"].contains { line.localizedCaseInsensitiveContains($0) }
        }
        guard !problems.isEmpty else { return "" }
        return (["", "Extension errors, latest"] + problems.suffix(20).map(Diagnostics.clean)).joined(separator: "\n") + "\n"
    }

    /// The crash and freeze reports kept on this Mac, read from disk.
    nonisolated static var crashes: String {
        var lines = ["", "Crashes and freezes, last two weeks"]
        let reports = CrashReports.recent
        if reports.isEmpty { lines.append("None reported by macOS") }
        for report in reports {
            lines.append("\(report.date.formatted(date: .abbreviated, time: .shortened)): \(report.summary)")
        }
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

    private static func systemValue(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(cString: bytes)
    }
}
