import WebKit

/// What wait_for waits for.
nonisolated enum MCPWaitCondition: Equatable, Sendable {
    case text(String), textGone(String), selector(String), selectorGone(String), load

    /// Its name, as wait_for's argument and in its answer.
    var name: String {
        switch self {
        case .text: "text"
        case .textGone: "text_gone"
        case .selector: "selector"
        case .selectorGone: "selector_gone"
        case .load: "load"
        }
    }

    var value: String? {
        switch self {
        case .text(let value), .textGone(let value), .selector(let value), .selectorGone(let value): value
        case .load: nil
        }
    }

    /// "the text “Saved” to appear", for what's said when the wait ends without it.
    var phrase: String {
        switch self {
        case .text(let text): "the text “\(text)” to appear"
        case .textGone(let text): "the text “\(text)” to go away"
        case .selector(let selector): "an element matching \(selector) to show"
        case .selectorGone(let selector): "no element matching \(selector) to show"
        case .load: "the page to finish loading"
        }
    }
}

/// One wait_for in a page. The page itself watches for the condition (`waitFor` in the page script: a
/// MutationObserver, and a check every quarter second besides); Zigzag keeps the time, and ends the wait early when
/// the tab loads another page, closes or goes to sleep, or AI access is stopped.
@MainActor
final class MCPWait {
    enum Outcome {
        case matched([String: Any], elapsedMs: Int)
        case failed(String)
    }

    /// The waits going on now, in every tab.
    private static var active: [ObjectIdentifier: MCPWait] = [:]

    static var count: Int { active.count }

    static let stoppedMessage = "AI apps were stopped from using Zigzag, so the wait ended."

    /// Stop, or AI access turned off: every wait ends, with `message`.
    static func cancelAll(_ message: String) {
        for wait in Array(active.values) { wait.finish(.failed(message)) }
    }

    let condition: MCPWaitCondition
    private let webView: WKWebView
    private let timeout: TimeInterval
    /// Why the wait can't go on (the tab closed, it was stopped), checked as it goes; nil while it can.
    private let ended: @MainActor () -> String?
    private let started = Date()
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var loading: NSKeyValueObservation?
    private var timers: [Task<Void, Never>] = []
    /// Set once the page is watching: a load from then on is the tab leaving the page.
    private var pageWaitID: String?

    init(_ condition: MCPWaitCondition, in webView: WKWebView, timeout: TimeInterval, ended: @escaping @MainActor () -> String? = { nil }) {
        self.condition = condition
        self.webView = webView
        self.timeout = timeout
        self.ended = ended
    }

    private var elapsedMs: Int { Int((Date().timeIntervalSince(started) * 1000).rounded()) }

    func run() async -> Outcome {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            Self.active[ObjectIdentifier(self)] = self
            if let reason = ended() { finish(.failed(reason)); return }
            let timeout = timeout
            timers.append(Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.finish(.failed("Timed out after \(Int(timeout * 1000)) ms waiting for \(self.condition.phrase)."))
            })
            // A tab closing or going to sleep says nothing to its old web view: looked for a few times a second.
            timers.append(Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard !Task.isCancelled, let self else { return }
                    if let reason = self.ended() { self.finish(.failed(reason)); return }
                }
            })
            loading = webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
                let isLoading = webView.isLoading
                MainActor.assumeIsolated { self?.loadingChanged(isLoading) }
            }
            // A page still on its way is waited for first: what to look for is on the page it brings.
            if !webView.isLoading { watch() }
        }
    }

    private func loadingChanged(_ isLoading: Bool) {
        guard continuation != nil else { return }
        if pageWaitID != nil {
            if isLoading {
                finish(.failed("The tab started loading another page while waiting for \(condition.phrase), so the wait ended."))
            }
        } else if !isLoading {
            watch()
        }
    }

    /// Hands the condition to the page, which answers once it holds.
    private func watch() {
        guard continuation != nil, pageWaitID == nil else { return }
        let id = UUID().uuidString
        pageWaitID = id
        var args: [String: Any] = ["condition": condition.name, "waitID": id, "timeoutMs": Int(timeout * 1000)]
        if let value = condition.value { args["value"] = value }
        MCPPageScript.start("waitFor", args, in: webView) { [weak self] result in
            guard let self, self.continuation != nil else { return }
            switch result {
            case .failure(let error):
                // The page went while it watched (its script world with it): said as leaving the page.
                if self.webView.isLoading || error.message == "The page gave no answer." {
                    self.finish(.failed("The tab left the page while waiting for \(self.condition.phrase), so the wait ended."))
                } else {
                    self.finish(.failed(error.message))
                }
            case .success(let object):
                if object["navigated"] != nil {
                    self.finish(.failed("The tab started loading another page while waiting for \(self.condition.phrase), so the wait ended."))
                } else if object["matched"] != nil {
                    // Matched on a page it may no longer use, or just after it was stopped: said as that.
                    if let reason = self.ended() { self.finish(.failed(reason)); return }
                    self.finish(.matched(object, elapsedMs: self.elapsedMs))
                } else if object["timedOut"] != nil {
                    self.finish(.failed("Timed out after \(Int(self.timeout * 1000)) ms waiting for \(self.condition.phrase)."))
                }
            }
        }
    }

    private func finish(_ outcome: Outcome) {
        guard let continuation else { return }
        self.continuation = nil
        Self.active[ObjectIdentifier(self)] = nil
        loading?.invalidate()
        loading = nil
        timers.forEach { $0.cancel() }
        timers = []
        // The page stops watching too, if it still is.
        if let id = pageWaitID, case .failed = outcome {
            MCPPageScript.start("cancelWait", ["waitID": id], in: webView) { _ in }
        }
        continuation.resume(returning: outcome)
    }
}
