import AppKit
import WebKit

/// Flags a background tab that keeps a CPU core busy, with two minutes to keep it awake before it sleeps (it resumes
/// when revisited). Nothing sleeps without that warning. The front page isn't flagged: it's visible, and usually busy
/// on purpose (animation, game). Extensions aren't blamed just for being present (password managers are everywhere),
/// only when caught looping (ExtensionStorms). Only process CPU is recorded, nothing about the page.
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
    /// Extensions already named, by profile and ID; each is named once per launch.
    private var toldExtensions: Set<String> = []

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
        // Includes the AI apps' background window: a page left busy there costs as much as any.
        for controller in WindowManager.shared.everyController {
            for tab in controller.tabManager.allTabs {
                guard let webView = tab.webView, let pid = Self.processID(of: webView) else { continue }
                if Self.isOnScreen(tab, in: controller) || tab.isPlayingAudio || tab.isInUse || tab.isInMiniPlayer { excused.insert(pid) }
            }
        }
        for controller in WindowManager.shared.everyController {
            for tab in controller.tabManager.allTabs {
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
                    // Name an extension caught looping there instead of the site.
                    if #available(macOS 15.4, *), let held = Self.heldBack(in: pid) {
                        extensionIsBusy(held.id, name: held.host.displayName(for: held.id), in: held.tab, host: held.host)
                        continue
                    }
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

    /// A tab in this process where a looping extension was held back, and which extension.
    @available(macOS 15.4, *)
    private static func heldBack(in pid: Int32) -> (tab: Tab, id: String, host: ExtensionHost)? {
        for tab in WindowManager.shared.everyOpenTab where tab.webView.flatMap(processID) == pid {
            guard !tab.isPrivate, let host = tab.profile.startedExtensions, let id = host.storms.extensions(in: tab).sorted().first else { continue }
            return (tab, id, host)
        }
        return nil
    }

    /// An extension caught reconnecting in a loop (ExtensionStorms): named once, with options to turn it off for the
    /// site or everywhere. Already held back, so nothing sleeps.
    @available(macOS 15.4, *)
    func extensionIsBusy(_ id: String, name: String, in tab: Tab, host: ExtensionHost) {
        guard Self.sleepsBusyTabs, let controller = Self.window(holding: tab), !controller.tabManager.isPrivate,
              toldExtensions.insert("\(host.profile.id)|\(id)").inserted else { return }
        let site = tab.url.flatMap { ContentBlocker.site(of: $0) }
        let text = site.map { String(localized: "\(name) is using a lot of energy on \($0)", comment: "Toast when an extension keeps a tab busy, caught in a loop there. The name is the extension's; the site is a domain, like example.com.") }
            ?? String(localized: "\(name) is using a lot of energy", comment: "Toast when an extension keeps a tab busy, caught in a loop there. The name is the extension's.")
        let installs = host.profile.installs
        let profile = host.profile
        Toast.show(text, symbol: "bolt",
                   action: (String(localized: "Turn Off…", comment: "Button in the toast saying an extension is using a lot of energy: shows where to turn it off, on the site or everywhere."), {
                       let menu = NSMenu()
                       menu.autoenablesItems = false
                       if let site {
                           menu.addItem(SidebarMenus.Item(String(localized: "Turn Off on \(site)", comment: "Menu item from the toast saying an extension is using a lot of energy: turns the extension off on this site only. The site is a domain.")) {
                               installs.setOff(id, on: site, true)
                               // Its scripts leave the site's open pages as they reload.
                               for tab in WindowManager.shared.everyOpenTab where tab.webView != nil && tab.profile === profile && ContentBlocker.site(of: tab.url) == site { tab.reload() }
                           })
                       }
                       menu.addItem(SidebarMenus.Item(String(localized: "Turn Off Everywhere", comment: "Menu item from the toast saying an extension is using a lot of energy: turns the extension off on every site.")) {
                           installs.setEnabled(id, false)
                       })
                       menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
                   }), duration: 20, closes: true, in: controller)
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
        // Each window's selected page (and split partner) never sleeps, even when covered or minimized: it would just
        // reload. Sharing windows (#162) list the same tabs; each is checked once and any window's selection is kept.
        // AI apps' own window too: out of sight it shows none (`TabManager.shownTabs`), so only use spares a tab there.
        // A page out in a Mini or the edge sidebar's preview is seen too.
        let kept = WindowManager.shared.everyController.flatMap(\.tabManager.shownTabs) + MiniWindowController.all.map(\.tab).filter(MiniWindowController.shows)
        do {
            for tab in WindowManager.shared.everyOpenTab where tab.webView.flatMap(Self.processID) == pid && !kept.contains(where: { $0 === tab }) {
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

/// How much memory a process holds, as Activity Monitor's Memory column counts it (its physical footprint).
enum ProcessMemory {
    static func footprint(_ pid: Int32) -> UInt64? {
        guard pid > 0 else { return nil }
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard ok == 0, info.ri_phys_footprint > 0 else { return nil }
        return info.ri_phys_footprint
    }
}
