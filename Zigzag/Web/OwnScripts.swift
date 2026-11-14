import WebKit

/// Taking some of Zigzag's own page scripts out of a web view's set, leaving every other script where it is.
///
/// WebKit's only public way is `removeAllUserScripts` and putting the rest back. But the set also holds what
/// extensions inject (WKWebExtension puts their content scripts there), and those came back as copies of Zigzag's
/// own, beside the ones the extension then put in again. With an extension on, a web view's set grew by a few hundred
/// kilobytes most times a page changed site, and every page made in a new process is sent the whole set: in time it
/// was more than WebKit could send, and Zigzag crashed going back, forward or to a link (#178).
enum OwnScripts {
    private static let removeOne = NSSelectorFromString("_removeUserScript:")

    /// Takes out the scripts `matching` picks. Returns how many there were.
    @discardableResult
    static func remove(from controller: WKUserContentController, where matching: (WKUserScript) -> Bool) -> Int {
        // Picked out first, into a list of Zigzag's own: the one WebKit hands over is its live set, and changes with it.
        let picked = controller.userScripts.filter(matching)
        guard !picked.isEmpty else { return 0 }
        if controller.responds(to: removeOne) {
            for script in picked { controller.perform(removeOne, with: script) }
        } else {
            let others = controller.userScripts.filter { !matching($0) }
            controller.removeAllUserScripts()
            others.forEach(controller.addUserScript)
        }
        return picked.count
    }
}

/// Zigzag's own scripts that it runs in a page by itself (to read its icons, to ask whether it's a PDF, to tell it of
/// a changed setting). WebKit runs a script it's asked to as if you had just clicked: whatever the page's code does
/// then (a getter or function it redefined that Zigzag happens to call) could open a window, start a download or
/// launch an app with no click of yours. So these run without that, where WebKit allows it, and in an isolated world
/// (`.defaultClient`) unless they must reach the page's own code, where the page can't redefine what they call.
extension WKWebView {
    private static let evaluateQuietly = NSSelectorFromString("_evaluateJavaScript:asAsyncFunction:withSourceURL:withArguments:forceUserGesture:inFrame:inWorld:completionHandler:")

    /// Whether this WebKit can run a script without the user gesture.
    static var runsScriptsWithoutGesture: Bool { instancesRespond(to: evaluateQuietly) }

    /// Runs `source` as Zigzag's own, with no user gesture. `asFunction`: the source is an async function's body, with
    /// `arguments` as its variables, as `callAsyncJavaScript` takes it; otherwise an expression, as
    /// `evaluateJavaScript` takes it.
    func runOwnScript(_ source: String, asFunction: Bool = false, arguments: [String: Any] = [:], in frame: WKFrameInfo? = nil,
                      world: WKContentWorld = .defaultClient, completion: ((Result<Any?, Error>) -> Void)? = nil) {
        if Self.runsScriptsWithoutGesture, let method = method(for: Self.evaluateQuietly) {
            let done: @convention(block) (AnyObject?, NSError?) -> Void = { value, error in
                MainActor.assumeIsolated {
                    if let error { completion?(.failure(error)) } else { completion?(.success(value is NSNull ? nil : value)) }
                }
            }
            typealias Evaluate = @convention(c) (AnyObject, Selector, NSString, Bool, NSURL?, NSDictionary?, Bool, WKFrameInfo?, WKContentWorld,
                                                 @convention(block) (AnyObject?, NSError?) -> Void) -> Void
            unsafeBitCast(method, to: Evaluate.self)(self, Self.evaluateQuietly, source as NSString, asFunction, nil,
                                                       asFunction ? arguments as NSDictionary : nil, false, frame, world, done)
            return
        }
        // An older WebKit without it: the isolated world still keeps the page's code out of the way.
        if asFunction {
            callAsyncJavaScript(source, arguments: arguments, in: frame, in: world) { result in completion?(result.map { $0 is NSNull ? nil : $0 }) }
        } else {
            evaluateJavaScript(source, in: frame, in: world) { result in completion?(result.map { $0 is NSNull ? nil : $0 }) }
        }
    }

    /// The same, awaited.
    func runOwnScript(_ source: String, asFunction: Bool = false, arguments: [String: Any] = [:], in frame: WKFrameInfo? = nil,
                      world: WKContentWorld = .defaultClient) async throws -> Any? {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<ScriptValue, Error>) in
            runOwnScript(source, asFunction: asFunction, arguments: arguments, in: frame, world: world) { done.resume(with: $0.map(ScriptValue.init)) }
        }.value
    }

    /// What a script answered (plain values WebKit made from JavaScript's), carried back to the awaiting caller.
    struct ScriptValue: @unchecked Sendable { let value: Any? }

    /// The user agent the page is loaded with, as WebKit sends it: never asked of the page, which could answer anything.
    var sentUserAgent: String? {
        if let custom = customUserAgent, !custom.isEmpty { return custom }
        guard responds(to: NSSelectorFromString("_userAgent")) else { return nil }
        return (value(forKey: "_userAgent") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}
