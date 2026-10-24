import AppKit
import WebKit

/// "Getting started": the first tab after onboarding. Five things worth trying, each ticking itself off when you
/// actually do it in the browser, the way you learn a new app by using it.
enum Tutorial {
    static let url = URL(string: "zigzag://welcome")!

    struct Task {
        let id: String
        let title: String
        let how: String
        let keys: [String]
    }

    static let tasks: [Task] = [
        Task(id: "newTab", title: "Open a new website", how: "Press ⌘T, type an address or a search, and press Return.", keys: ["⌘", "T"]),
        Task(id: "pin", title: "Pin a page you use a lot", how: "On any page, press ⌘D. It stays at the top of your sidebar, even after you close it.", keys: ["⌘", "D"]),
        Task(id: "peek", title: "Peek at a link", how: "Hold Shift and click a link. It opens over the page, and Esc puts it away.", keys: ["⇧", "Click"]),
        Task(id: "split", title: "Put two pages side by side", how: "Drag a tab from the sidebar onto the page, or right-click a tab and choose Open in Split View.", keys: ["Drag"]),
        Task(id: "space", title: "Make a space", how: "Click + next to the dots at the bottom of the sidebar. Each space keeps its own tabs and pins.", keys: ["⌥", "⌘", "N"]),
    ]

    private static let key = "TutorialDone"
    static var done: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: key) }
    }

    static func isWelcome(_ url: URL?) -> Bool { url?.scheme == "zigzag" && url?.host() == "welcome" }

    /// You did one: remember it, and tick it on any Getting started page that's open.
    @MainActor static func complete(_ id: String) {
        guard !done.contains(id), tasks.contains(where: { $0.id == id }) else { return }
        done.insert(id)
        for controller in WindowManager.shared.controllers {
            for tab in controller.tabManager.allTabs where isWelcome(tab.url) {
                tab.webView?.evaluateJavaScript("window.zzDone && zzDone('\(id)')")
            }
        }
    }

    // MARK: The page

    static func html() -> String {
        let done = self.done
        let rows = tasks.map { task in
            let keys = task.keys.map { "<kbd>\($0)</kbd>" }.joined()
            return """
            <li class="task\(done.contains(task.id) ? " done" : "")" id="\(task.id)">
              <span class="check"><svg viewBox="0 0 16 16"><path d="M4 8.5l2.6 2.6L12 5.6"/></svg></span>
              <div class="text"><h3>\(task.title)</h3><p>\(task.how)</p></div>
              <span class="keys">\(keys)</span>
            </li>
            """
        }.joined(separator: "\n")
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>Getting started</title>
        <meta name="color-scheme" content="light dark">
        <style>
          :root { --bg: #F4F6FA; --card: #FFFFFF; --ink: #16202E; --dim: #5B6676; --line: rgba(22,32,46,.08);
                  --accent: #2F5C93; --accent-soft: rgba(47,92,147,.10); --key: #EEF1F6; }
          @media (prefers-color-scheme: dark) {
            :root { --bg: #151A22; --card: #1D232D; --ink: #E6ECF4; --dim: #98A3B3; --line: rgba(255,255,255,.07);
                    --accent: #9CB9DE; --accent-soft: rgba(156,185,222,.12); --key: #262E3A; }
          }
          * { box-sizing: border-box; }
          body { margin: 0; background: var(--bg); color: var(--ink); font: 15px/1.45 -apple-system, system-ui;
                 -webkit-font-smoothing: antialiased; }
          main { max-width: 640px; margin: 0 auto; padding: 72px 28px 96px; }
          .eyebrow { color: var(--accent); font-weight: 600; font-size: 13px; letter-spacing: .02em; margin: 0 0 10px; }
          h1 { font-size: 34px; line-height: 1.1; font-weight: 800; letter-spacing: -.02em; margin: 0 0 10px; }
          .lead { color: var(--dim); font-size: 16px; margin: 0 0 28px; }
          .progress { display: flex; align-items: center; gap: 12px; margin: 0 0 18px; color: var(--dim); font-size: 13px; font-weight: 500; }
          .bar { flex: 1; height: 6px; border-radius: 3px; background: var(--line); overflow: hidden; }
          .bar i { display: block; height: 100%; background: var(--accent); border-radius: 3px; transition: width .5s cubic-bezier(.25,.8,.25,1); }
          ol { list-style: none; margin: 0; padding: 0; background: var(--card); border-radius: 16px; border: 1px solid var(--line);
               overflow: hidden; }
          .task { display: flex; align-items: center; gap: 16px; padding: 18px 20px; }
          .task + .task { border-top: 1px solid var(--line); }
          .check { flex: none; width: 24px; height: 24px; border-radius: 50%; border: 1.5px solid var(--line);
                   display: grid; place-items: center; transition: background .3s, border-color .3s; }
          .check svg { width: 14px; height: 14px; fill: none; stroke: #fff; stroke-width: 2; stroke-linecap: round; stroke-linejoin: round;
                       stroke-dasharray: 14; stroke-dashoffset: 14; transition: stroke-dashoffset .35s .1s ease-out; }
          .done .check { background: var(--accent); border-color: var(--accent); }
          .done .check svg { stroke-dashoffset: 0; }
          @media (prefers-color-scheme: dark) { .check svg { stroke: #151A22; } }
          .text { flex: 1; min-width: 0; }
          h3 { margin: 0 0 2px; font-size: 15px; font-weight: 600; transition: color .3s; }
          p { margin: 0; color: var(--dim); font-size: 13.5px; }
          .done h3 { color: var(--dim); }
          .keys { flex: none; display: flex; gap: 4px; }
          kbd { font: 600 12px -apple-system, system-ui; min-width: 26px; height: 26px; padding: 0 7px; border-radius: 7px;
                background: var(--key); color: var(--ink); display: grid; place-items: center; border: 1px solid var(--line); }
          .finished { display: none; margin-top: 22px; padding: 16px 20px; border-radius: 14px; background: var(--accent-soft); color: var(--ink); }
          .all .finished { display: block; }
          footer { margin-top: 28px; color: var(--dim); font-size: 13px; }
        </style></head>
        <body class="\(done.count == tasks.count ? "all" : "")"><main>
          <p class="eyebrow">Getting started</p>
          <h1>Five things worth trying</h1>
          <p class="lead">Each one ticks itself off when you do it. Start with the first: it’s the one you’ll use most.</p>
          <div class="progress"><span id="count">\(done.count) of \(tasks.count)</span><div class="bar"><i id="fill" style="width:\(Int(Double(done.count) / Double(tasks.count) * 100))%"></i></div></div>
          <ol>
          \(rows)
          </ol>
          <div class="finished"><strong>You’ve got it.</strong> Close this tab with ⌘W whenever you like; it’s pinned, so it’s here if you want it again.</div>
          <footer>Every shortcut is in Settings › Shortcuts, and you can change any of them there.</footer>
        </main>
        <script>
          const total = \(tasks.count);
          window.zzDone = (id) => {
            const el = document.getElementById(id);
            if (!el || el.classList.contains('done')) return;
            el.classList.add('done');
            const n = document.querySelectorAll('.task.done').length;
            document.getElementById('count').textContent = n + ' of ' + total;
            document.getElementById('fill').style.width = (n / total * 100) + '%';
            if (n === total) document.body.classList.add('all');
          };
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
