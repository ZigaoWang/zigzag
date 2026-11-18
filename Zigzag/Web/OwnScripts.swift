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

/// Zigzag's own page scripts (reading icons, PDF checks, setting changes). WebKit runs evaluated scripts with a user
/// gesture, so page code they touch (a redefined getter or function) could open a window, start a download or launch
/// an app without a click. These run without the gesture where WebKit allows it, and in an isolated world
/// (`.defaultClient`) unless they must reach page code, so the page can't redefine what they call.
extension WKWebView {
    private static let evaluateQuietly = NSSelectorFromString("_evaluateJavaScript:asAsyncFunction:withSourceURL:withArguments:forceUserGesture:inFrame:inWorld:completionHandler:")

    /// Whether this WebKit can run a script without the user gesture.
    static var runsScriptsWithoutGesture: Bool { instancesRespond(to: evaluateQuietly) }

    /// Runs `source` with no user gesture. `asFunction`: `source` is an async function body with `arguments` as
    /// variables (`callAsyncJavaScript`); otherwise an expression (`evaluateJavaScript`).
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
        // Older WebKit without it: the isolated world still shields from page code.
        if asFunction {
            callAsyncJavaScript(source, arguments: arguments, in: frame, in: world) { result in completion?(result.map { $0 is NSNull ? nil : $0 }) }
        } else {
            evaluateJavaScript(source, in: frame, in: world) { result in completion?(result.map { $0 is NSNull ? nil : $0 }) }
        }
    }

    /// Async version.
    func runOwnScript(_ source: String, asFunction: Bool = false, arguments: [String: Any] = [:], in frame: WKFrameInfo? = nil,
                      world: WKContentWorld = .defaultClient) async throws -> Any? {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<ScriptValue, Error>) in
            runOwnScript(source, asFunction: asFunction, arguments: arguments, in: frame, world: world) { done.resume(with: $0.map(ScriptValue.init)) }
        }.value
    }

    /// A script's result (plain values converted by WebKit), carried back to the caller.
    struct ScriptValue: @unchecked Sendable { let value: Any? }

    /// The user agent WebKit actually sends; never asked of the page, which could lie.
    var sentUserAgent: String? {
        if let custom = customUserAgent, !custom.isEmpty { return custom }
        guard responds(to: NSSelectorFromString("_userAgent")) else { return nil }
        return (value(forKey: "_userAgent") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}
