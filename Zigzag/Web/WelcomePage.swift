import AppKit
import WebKit

/// "Getting started": the first tab after onboarding. Five things worth trying, each ticking itself off when you
/// actually do it in the browser, the way you learn a new app by using it.
enum Tutorial {
    static let url = URL(string: "zigzag://welcome")!

    struct Task {
        let id: String
        let title: String
        /// What it's for, in a sentence.
        let why: String
        /// Exactly what to do now, building on the step before.
        let how: String
        let keys: [String]
    }

    /// In order: each step uses what the one before left on screen.
    static let tasks: [Task] = [
        Task(id: "newTab", title: "Open a website",
             why: "One field for addresses and searches, from anywhere.",
             how: "Press ⌘T, type wikipedia.org, and press Return.", keys: ["⌘", "T"]),
        Task(id: "pin", title: "Pin it",
             why: "Pinned pages stay at the top of the sidebar, even after you close them.",
             how: "With that page open, press ⌘D.", keys: ["⌘", "D"]),
        Task(id: "peek", title: "Peek at a link",
             why: "Look at a link without leaving the page you’re on.",
             how: "Hold Shift and click any link on the page. Press Esc to close it.", keys: ["⇧", "Click"]),
        Task(id: "split", title: "See two pages at once",
             why: "Split view puts two pages side by side in one window.",
             how: "Right-click Getting started in the sidebar and choose Open in Split View.", keys: ["Right-click"]),
        Task(id: "space", title: "Make a space",
             why: "A space for each part of your life, each with its own tabs and pins.",
             how: "Click + at the bottom of the sidebar, next to the dots.", keys: ["+"]),
    ]

    private static let key = "TutorialDone"
    static var done: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: key) }
    }

    /// The step to do now: the first in order that isn't done.
    static var current: Task? { tasks.first { !done.contains($0.id) } }

    /// Closed from the guide card; Help › Getting Started opens it again.
    static var isHidden: Bool {
        get { UserDefaults.standard.bool(forKey: "TutorialHidden") }
        set { UserDefaults.standard.set(newValue, forKey: "TutorialHidden") }
    }

    /// Sent when a step is done, skipped, or the guide is shown or hidden.
    @MainActor static let changed = Signal<Void>()

    static func isWelcome(_ url: URL?) -> Bool { url?.scheme == "zigzag" && url?.host() == "welcome" }

    /// You did one: remember it, and move any open Getting started page on to the next step.
    @MainActor static func complete(_ id: String) {
        guard !done.contains(id), tasks.contains(where: { $0.id == id }) else { return }
        done.insert(id)
        for controller in WindowManager.shared.controllers {
            for tab in controller.tabManager.allTabs where isWelcome(tab.url) {
                tab.webView?.evaluateJavaScript("window.zzStep && zzStep(\(stepJSON()))")
            }
        }
        changed.send(())
    }

    /// The step to show, as the page's script reads it.
    static func stepJSON() -> String {
        guard let task = current, let i = tasks.firstIndex(where: { $0.id == task.id }) else { return "null" }
        let payload: [String: Any] = ["n": i + 1, "total": tasks.count, "title": task.title, "how": task.how, "why": task.why, "keys": task.keys]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("null".utf8)
        return String(data: data, encoding: .utf8) ?? "null"
    }

    @MainActor static func skip() { if let current { complete(current.id) } }

    // MARK: The page

    /// One step, big and centered, and nothing else. It changes in place when you've done it.
    static func html() -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>Getting started</title>
        <meta name="color-scheme" content="light dark">
        <style>
          :root { --bg: #F4F6FA; --ink: #16202E; --dim: #6A7585; --line: rgba(22,32,46,.10); --accent: #2F5C93; --key: #FFFFFF; }
          @media (prefers-color-scheme: dark) {
            :root { --bg: #151A22; --ink: #E6ECF4; --dim: #8F9AAA; --line: rgba(255,255,255,.10); --accent: #9CB9DE; --key: #222A35; }
          }
          html, body { height: 100%; }
          body { margin: 0; background: var(--bg); color: var(--ink); font: 16px/1.5 -apple-system, system-ui; -webkit-font-smoothing: antialiased;
                 display: grid; place-items: center; }
          main { width: min(560px, 86vw); text-align: center; transition: opacity .25s ease; }
          main.out { opacity: 0; }
          .dots { display: flex; gap: 8px; justify-content: center; margin-bottom: 18px; }
          .dots i { width: 8px; height: 8px; border-radius: 50%; background: var(--line); transition: background .3s; }
          .dots i.on { background: var(--accent); }
          .step { color: var(--dim); font-size: 13px; font-weight: 600; letter-spacing: .02em; margin: 0 0 10px; }
          h1 { font-size: 40px; line-height: 1.1; font-weight: 800; letter-spacing: -.02em; margin: 0 0 22px; }
          .keys { display: flex; gap: 8px; justify-content: center; margin-bottom: 22px; }
          kbd { font: 600 20px -apple-system, system-ui; min-width: 52px; height: 52px; padding: 0 14px; border-radius: 12px;
                display: grid; place-items: center; background: var(--key); border: 1px solid var(--line);
                box-shadow: 0 2px 0 var(--line); }
          .how { font-size: 19px; font-weight: 500; margin: 0 0 8px; }
          .why { color: var(--dim); font-size: 15px; margin: 0; }
          .skip { display: inline-block; margin-top: 40px; color: var(--dim); font-size: 13px; text-decoration: none; }
          .skip:hover { color: var(--ink); }
          .check { width: 64px; height: 64px; margin: 0 auto 20px; border-radius: 50%; background: var(--accent); display: grid; place-items: center; }
          .check svg { width: 30px; height: 30px; fill: none; stroke: var(--bg); stroke-width: 2.4; stroke-linecap: round; stroke-linejoin: round; }
        </style></head>
        <body><main id="main"></main>
        <script>
          const render = (s) => {
            const m = document.getElementById('main');
            if (!s) {
              m.innerHTML = `<div class="check"><svg viewBox="0 0 24 24"><path d="M6 12.5l4 4L18 8"/></svg></div>
                <h1>You’re all set</h1>
                <p class="why">That’s the basics. Close this tab with ⌘W, and find this again in Help › Getting Started.</p>`;
              return;
            }
            const dots = Array.from({length: s.total}, (_, i) => `<i class="${i < s.n ? 'on' : ''}"></i>`).join('');
            const keys = s.keys.map(k => `<kbd>${k}</kbd>`).join('');
            m.innerHTML = `<div class="dots">${dots}</div>
              <p class="step">Step ${s.n} of ${s.total}</p>
              <h1>${s.title}</h1>
              <div class="keys">${keys}</div>
              <p class="how">${s.how}</p>
              <p class="why">${s.why}</p>
              <a class="skip" href="zigzag://welcome?skip">Skip this step</a>`;
          };
          // A short fade between steps, so the change is noticed.
          window.zzStep = (s) => {
            const m = document.getElementById('main');
            m.classList.add('out');
            setTimeout(() => { render(s); m.classList.remove('out'); }, 250);
          };
          // After Skip, the address goes back to plain, so reloading doesn't skip again.
          if (location.search) history.replaceState(null, '', 'zigzag://welcome');
          render(\(stepJSON()));
        </script></body></html>
        """
    }
}

/// Serves Zigzag's own pages at zigzag:// addresses.
final class InternalPages: NSObject, WKURLSchemeHandler {
    static let shared = InternalPages()
    static let scheme = "zigzag"

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, Tutorial.isWelcome(url) else {
            task.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist))
            return
        }
        // "Skip this step" links back here with ?skip.
        if url.query() == "skip" { MainActor.assumeIsolated { Tutorial.skip() } }
        let data = Data(Tutorial.html().utf8)
        task.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// Straight after onboarding: Getting started pinned and open, and, on a Mac with nothing brought over, a few
/// sample favorites so the sidebar shows what pins and favorites are before you make your own.
enum FirstRun {
    @MainActor static func prepare(_ controller: BrowserWindowController) {
        let library = Library.shared
        let space = controller.tabManager.currentSpaceID
        let nothingYet = library.favorites.isEmpty && library.spaces.allSatisfy { $0.bookmarks.isEmpty }
        if nothingYet {
            let samples: [(String, String)] = [("https://www.google.com", "Google"), ("https://www.youtube.com", "YouTube"), ("https://www.wikipedia.org", "Wikipedia")]
            library.appendFavorites(samples.compactMap { url, title in URL(string: url).map { Bookmark(url: $0, title: title) } })
            for (url, _) in samples { if let url = URL(string: url) { FaviconStore.shared.prefetch(for: url) } }
        }
        let pinned = library.spaces.first { $0.id == space }?.bookmarks.first { Tutorial.isWelcome($0.url) }
            ?? library.addBookmark(url: Tutorial.url, title: "Getting started", to: space, at: 0)
        if let pinned { controller.tabManager.openBookmark(pinned) }
    }
}
