import AppKit
import WebKit

/// Notices a page that keeps a CPU core busy, and says so once, with what to do: usually an extension stuck in a
/// loop on that site, sometimes the page itself. Nothing about the page is recorded; only how busy its process is.
@MainActor
final class EnergyWatch {
    static let shared = EnergyWatch()

    /// Busy, as a share of one core, for long enough to be more than a page finishing its load.
    private static let busy = 0.7
    private static let interval: TimeInterval = 10
    private static let rounds = 3

    private var timer: Timer?
    /// Each page process's CPU seconds at the last look, and how many looks in a row it's been busy.
    private var last: [Int32: Double] = [:]
    private var streak: [Int32: Int] = [:]
    /// Pages already told about, by tab and site, so it's said once.
    private var told: Set<String> = []

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { _ in
            MainActor.assumeIsolated { EnergyWatch.shared.look() }
        }
    }

    private func look() {
        var seen: Set<Int32> = []
        for controller in WindowManager.shared.controllers {
            for tab in controller.tabManager.allTabs {
                guard let webView = tab.webView, let pid = Self.processID(of: webView), pid > 0,
                      seen.insert(pid).inserted else { continue }
                let now = ProcessCPU.seconds(pid)
                defer { last[pid] = now }
                guard let before = last[pid] else { continue }
                let share = (now - before) / Self.interval
                streak[pid] = share >= Self.busy ? (streak[pid] ?? 0) + 1 : 0
                // Playing something is meant to work hard.
                guard streak[pid] ?? 0 >= Self.rounds, !tab.isPlayingAudio, let url = tab.url else { continue }
                warn(about: tab, url: url, in: controller)
            }
        }
        // Forget processes that have gone.
        last = last.filter { seen.contains($0.key) }
        streak = streak.filter { seen.contains($0.key) }
    }

    /// The page's process, if WebKit still says (it's not public API, so asked carefully).
    static func processID(of webView: WKWebView) -> Int32? {
        let key = NSSelectorFromString("_webProcessIdentifier")
        guard webView.responds(to: key) else { return nil }
        return webView.value(forKey: "_webProcessIdentifier") as? Int32
    }

    private func warn(about tab: Tab, url: URL, in controller: BrowserWindowController) {
        let site = ContentBlocker.site(of: url) ?? url.host() ?? url.absoluteString
        guard told.insert("\(tab.id)|\(site)").inserted else { return }
        // An extension's own page: name the extension, and offer to close the page.
        if url.scheme == "webkit-extension", #available(macOS 15.4, *) {
            let name = ExtensionHost.shared.contexts.first { $0.baseURL.host() == url.host() }?.webExtension.displayName ?? "An extension"
            Toast.show("\(name)’s page is using a lot of energy", symbol: "bolt.fill",
                       action: ("Close Tab", { controller.tabManager.close(tab) }), duration: 15, in: controller)
            return
        }
        var running: [String] = []
        if #available(macOS 15.4, *), !ExtensionStore.extensionsOffSites.contains(site) {
            running = ExtensionHost.shared.contexts.filter { $0.hasInjectedContent(for: url) }
                .compactMap { $0.webExtension.displayName }
        }
        if running.isEmpty {
            Toast.show("\(site) is using a lot of energy", symbol: "bolt.fill", action: ("Reload", { tab.reload() }),
                       duration: 12, in: controller)
        } else {
            let who = running.count == 1 ? running[0] : "An extension"
            Toast.show("\(who) may be slowing \(site) and using a lot of energy", symbol: "bolt.fill",
                       action: ("Turn Off Here", {
                           var sites = ExtensionStore.extensionsOffSites
                           sites.insert(site)
                           ExtensionStore.extensionsOffSites = sites
                           tab.reload()
                       }), duration: 15, in: controller)
        }
    }
}

/// How much CPU a process has used, from the kernel's own count.
enum ProcessCPU {
    static func seconds(_ pid: Int32) -> Double {
        var info = rusage_info_v2()
        let ok = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        guard ok == 0 else { return 0 }
        var base = mach_timebase_info_data_t()
        mach_timebase_info(&base)
        return Double(info.ri_user_time + info.ri_system_time) * Double(base.numer) / Double(base.denom) / 1_000_000_000
    }
}
