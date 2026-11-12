import AppKit
import WebKit

/// Notices a tab you're not looking at that keeps a CPU core busy and says so, with two minutes to keep it awake
/// before it sleeps (it wakes where it was when you go back to it). Nothing sleeps without that warning. The page
/// in front isn't flagged: you can see what it's doing, and a busy one is usually busy on purpose (an animation, a
/// game). Nor is an extension blamed just for being on the page: password managers are on every page, so naming one
/// would mostly be wrong. Nothing about the page is recorded; only how busy its process is.
@MainActor
final class EnergyWatch {
    static let shared = EnergyWatch()
    /// Settings › Tabs. Off, a busy background tab is left alone and nothing is said.
    static var sleepsBusyTabs: Bool {
        get { UserDefaults.standard.object(forKey: "SleepsBusyTabs") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "SleepsBusyTabs") }
    }

    /// Busy, as a share of one core, for long enough to be more than a page finishing its load.
    private static let busy = 0.7
    private static let interval: TimeInterval = 10
    /// Three minutes busy out of sight: long past a load or a burst of live updates (a forum, a feed), long enough to
    /// be the page's habit. Pages out of sight already have their timers slowed by WebKit, so one still this busy is
    /// stuck, not merely live.
    nonisolated static let rounds = 18
    /// A page you left this recently stays awake, so a reply you were writing in it isn't lost.
    private static let recentlySeen: TimeInterval = 2 * 60
    /// How long after the warning a still-busy tab sleeps, unless you keep it awake.
    nonisolated static let grace: TimeInterval = 2 * 60
    /// The reason a tab slept, as `Tab.suspend` is told.
    static let sleepReason = "using a lot of energy"

    private var timer: Timer?
    /// Each page process's CPU seconds at the last look, and how many looks in a row it's been busy.
    private var last: [Int32: Double] = [:]
    private var streak: [Int32: Int] = [:]
    /// When the last look was, since a timer with slack doesn't fire exactly on the interval.
    private var lastLook: Date?
    /// Sites already told about, so it's said once however many of their tabs are open.
    private var told: Set<String> = []
    /// Processes warned about, and when their tabs sleep if they're still busy then.
    private var pending: [Int32: Date] = [:]
    /// Tabs you chose to keep awake from the warning: left alone for as long as Zigzag is open.
    private var spared: Set<UUID> = []

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { _ in
            MainActor.assumeIsolated { EnergyWatch.shared.look() }
        }
        // It's a slow watch: let the system batch it with other wake-ups.
        timer?.tolerance = 2.5
    }

    /// What one look decides for a page process: nothing, warn that its tabs will sleep, or sleep them now.
    enum Step: Equatable { case none, warn, sleep, calm }

    /// `busy`: past the share of a core, out of sight, with nothing in its process playing or in a call.
    /// `deadline`: when a warning already given runs out, if one was.
    nonisolated static func step(streak: Int, busy: Bool, deadline: Date?, now: Date) -> Step {
        if let deadline { return !busy ? .calm : now >= deadline ? .sleep : .none }
        return busy && streak >= rounds ? .warn : .none
    }

    private func look() {
        guard Self.sleepsBusyTabs else { last = [:]; streak = [:]; lastLook = nil; pending = [:]; return }
        var seen: Set<Int32> = []
        let now = Date()
        let elapsed = lastLook.map { now.timeIntervalSince($0) } ?? Self.interval
        lastLook = now
        // Pages share processes: one that also runs a page on screen, or one playing or in a call, may be busy with that
        // page, so none of its tabs is blamed.
        var excused: Set<Int32> = []
        for controller in WindowManager.shared.controllers {
            for tab in controller.tabManager.allTabs {
                guard let webView = tab.webView, let pid = Self.processID(of: webView) else { continue }
                if Self.isOnScreen(tab, in: controller) || tab.isPlayingAudio || tab.isInUse || tab.isInMiniPlayer { excused.insert(pid) }
            }
        }
        // Every tab once, in the window it's in: every window shows the same tabs (#162).
        for tab in WindowManager.shared.openTabs {
            guard let controller = WindowManager.shared.window(of: tab) else { continue }
            do {
                guard let webView = tab.webView, let pid = Self.processID(of: webView), pid > 0,
                      seen.insert(pid).inserted else { continue }
                let cpu = ProcessCPU.seconds(pid)
                defer { last[pid] = cpu }
                guard let before = last[pid] else { continue }
                let share = (cpu - before) / max(elapsed, 1)
                // Time on screen doesn't count: a page has to stay busy for a while after you've left it.
                let busy = share >= Self.busy && !excused.contains(pid)
                streak[pid] = busy ? (streak[pid] ?? 0) + 1 : 0
                guard let url = tab.url else { continue }
                switch Self.step(streak: streak[pid] ?? 0, busy: busy, deadline: pending[pid], now: now) {
                case .none: break
                case .calm: pending[pid] = nil
                case .warn:
                    streak[pid] = 0
                    warnSoon(pid, tab: tab, url: url, in: controller)
                case .sleep:
                    pending[pid] = nil
                    streak[pid] = 0
                    sleep(pid, tab: tab, url: url, in: controller)
                }
            }
        }
        // Forget processes that have gone.
        last = last.filter { seen.contains($0.key) }
        streak = streak.filter { seen.contains($0.key) }
        pending = pending.filter { seen.contains($0.key) }
    }

    /// In front in its window, either side of a split counted.
    private static func isOnScreen(_ tab: Tab, in controller: BrowserWindowController) -> Bool {
        guard controller.window?.isVisible == true, controller.window?.occlusionState.contains(.visible) == true else { return false }
        let manager = controller.tabManager
        guard let front = manager.selectedTab else { return false }
        return manager.panes(of: front).contains { $0 === tab }
    }

    /// The page's process, if WebKit still says (it's not public API, so asked carefully).
    static func processID(of webView: WKWebView) -> Int32? {
        let key = NSSelectorFromString("_webProcessIdentifier")
        guard webView.responds(to: key) else { return nil }
        return webView.value(forKey: "_webProcessIdentifier") as? Int32
    }

    private static func window(holding tab: Tab) -> BrowserWindowController? { WindowManager.shared.window(of: tab) }

    /// Whether a busy background tab is only pointed out, not put to sleep: an extension's own page, one playing or in
    /// a call, a site that notifies, a favorite, a site kept awake in its site controls, or one with something typed.
    nonisolated static func staysAwake(extensionPage: Bool, playing: Bool, inUse: Bool, notifies: Bool, favorite: Bool,
                                       keptAwake: Bool, typed: Bool) -> Bool {
        extensionPage || playing || inUse || notifies || favorite || keptAwake || typed
    }

    /// A busy process's background tabs: those that may sleep, those that must stay awake, and whether one was only
    /// just left (it gets a later look). Tabs of a site share a process, so all of that site's background tabs count.
    private func tabs(of pid: Int32, url: URL) -> (sleepers: [Tab], awake: [Tab], soon: Bool) {
        let now = Date()
        var sleepers: [Tab] = [], awake: [Tab] = [], soon = false
        // Each window's own page (and its split partner) never sleeps here, even in a covered or minimized window:
        // it would only load again at once, losing what it was doing. The windows show the same tabs (#162): one any
        // of them has chosen stays.
        let windows = WindowManager.shared.controllers
        let kept = windows.flatMap { owner in owner.tabManager.selectedTab.map { owner.tabManager.panes(of: $0) } ?? [] }
        do {
            for tab in WindowManager.shared.openTabs where tab.webView.flatMap(Self.processID) == pid && !kept.contains(where: { $0 === tab }) {
                let mustStay = spared.contains(tab.id)
                    || Self.staysAwake(extensionPage: url.scheme == "webkit-extension", playing: tab.isPlayingAudio, inUse: tab.isInUse,
                                       notifies: tab.notifiesUser, favorite: tab.isFavorite, keptAwake: KeepAwake.isOn(for: tab.url),
                                       typed: tab.pageState?.hasTypedText == true)
                if mustStay { awake.append(tab) } else if now.timeIntervalSince(tab.lastActivated) <= Self.recentlySeen { soon = true } else { sleepers.append(tab) }
            }
        }
        return (sleepers, awake, soon)
    }

    /// Busy for a while: says so, and that its tabs sleep in two minutes, with a way to keep them awake. A process
    /// whose tabs can't sleep is only pointed out, once per site.
    private func warnSoon(_ pid: Int32, tab busiest: Tab, url: URL, in controller: BrowserWindowController) {
        let found = tabs(of: pid, url: url)
        guard !found.sleepers.isEmpty else {
            // One you only just left gets a later look.
            if !found.soon { warnAwake(about: found.awake.first ?? busiest, url: url, in: controller) }
            return
        }
        pending[pid] = Date().addingTimeInterval(Self.grace)
        let site = Self.site(of: url)
        let minutes = Int((Self.grace / 60).rounded())
        let text = String(localized: "A tab on \(site) is using a lot of energy. It’ll sleep in \(minutes) minutes.", comment: "Toast when a background tab keeps the Mac busy. The site is a domain, like example.com; the number is how many minutes until the tab sleeps. A sleeping tab wakes where it was when you open it.")
        let ids = found.sleepers.map(\.id)
        Toast.show(text, symbol: "bolt",
                   action: (String(localized: "Keep Awake", comment: "Button in the toast saying a busy tab will sleep soon: keeps it awake."), { [weak self] in
                       guard let self else { return }
                       self.spared.formUnion(ids)
                       self.pending[pid] = nil
                   }), duration: 30, closes: true, in: controller)
    }

    /// The warning ran out and the tabs are still busy: they sleep now, and it says so, with a way to find one.
    private func sleep(_ pid: Int32, tab busiest: Tab, url: URL, in controller: BrowserWindowController) {
        let found = tabs(of: pid, url: url)
        guard let first = found.sleepers.first else { return }
        for tab in found.sleepers {
            // A few at a time: a site's tabs share a process, and there can be dozens.
            TabSleep.queue.add(tab.id) { [weak tab] in
                guard let tab, TabManager.mayStillSleep(tab) else { return }
                tab.suspend(because: Self.sleepReason)
            }
        }
        let site = Self.site(of: url)
        Toast.show(String(localized: "A tab on \(site) was using a lot of energy, so it’s asleep now", comment: "Toast after Zigzag put a background tab to sleep because it used a lot of energy. The site is a domain, like example.com. The tab wakes when you open it."),
                   symbol: "bolt", action: Self.showTab(first, in: controller), duration: 12, closes: true, in: controller)
    }

    private static func site(of url: URL) -> String {
        ContentBlocker.site(of: url) ?? url.host() ?? url.absoluteString
    }

    private static func showTab(_ tab: Tab, in controller: BrowserWindowController) -> (title: String, run: () -> Void) {
        (String(localized: "Show Tab", comment: "Button in the toast about a tab using a lot of energy: switches to that tab."), { [weak controller, weak tab] in
            guard let tab, !tab.isClosed, let owner = Self.window(holding: tab) ?? controller else { return }
            owner.tabManager.select(tab)
            owner.window?.makeKeyAndOrderFront(nil)
        })
    }

    /// Busy, but nothing of it may sleep: only pointed out, once per site (an extension's own page, once per page).
    private func warnAwake(about tab: Tab, url: URL, in controller: BrowserWindowController) {
        let site = Self.site(of: url)
        guard told.insert(url.scheme == "webkit-extension" ? "\(tab.id)" : site).inserted else { return }
        // An extension's own page: name the extension, and offer to close the page.
        if url.scheme == "webkit-extension", #available(macOS 15.4, *) {
            let name = ExtensionCenter.webExtension(ofPage: url)?.displayName
            Toast.show(name.map { String(localized: "\($0)’s page is using a lot of energy", comment: "Toast when an extension's own page uses a lot of energy. The name is the extension's.") }
                           ?? String(localized: "An extension’s page is using a lot of energy", comment: "Toast when the page of an extension with no name uses a lot of energy."),
                       symbol: "bolt",
                       action: (String(localized: "Close Tab", comment: "Button in the toast about a tab using a lot of energy: closes that tab."), { [weak controller, weak tab] in
                           guard let tab, !tab.isClosed else { return }
                           // The window it's in now: it may have been moved to another since.
                           // Only the page using the energy, not tabs folded under it.
                           (Self.window(holding: tab) ?? controller)?.closeWithUndo(tab, alone: true)
                       }), duration: 15, in: controller)
            return
        }
        Toast.show(String(localized: "A tab on \(site) is using a lot of energy in the background", comment: "Toast when a tab in the background uses a lot of energy. The site is a domain, like example.com."),
                   symbol: "bolt", action: Self.showTab(tab, in: controller), duration: 12, closes: true, in: controller)
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
