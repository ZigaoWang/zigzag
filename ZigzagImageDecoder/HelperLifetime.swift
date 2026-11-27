import Foundation

// Built into both helpers. launchd ends a helper when its app's domain is torn down, which doesn't always happen when
// the app ends: helpers of ended test hosts ran for hours. So a helper also ends itself once its app is gone.

/// Counts a helper's connections and ends the helper when nobody is left to serve.
nonisolated final class HelperLifetime: @unchecked Sendable {
    /// With nobody connected and the app still running, how long a helper waits for the next connection before it
    /// ends. Long enough that launchd starts it again at once: it holds back a service that ran less than 10 s.
    static let idleTime: TimeInterval = 30
    /// How often a helper with nobody connected looks whether its app is still running.
    static let checkEvery: TimeInterval = 0.25

    private let lock = NSLock()
    private var open = 0
    /// Bumped by every connection opened or closed: a wait for the next connection stops once it changes.
    private var generation = 0
    private var endsWithLastConnection = false
    private let queue = DispatchQueue(label: "wang.zigao.zigzag.helper.lifetime", qos: .utility)
    private let end: @Sendable () -> Void

    init(end: @escaping @Sendable () -> Void = { exit(0) }) {
        self.end = end
    }

    /// A helper that serves one connection only (a PDF's own helper) ends as soon as it closes.
    func endWithLastConnection() { lock.withLock { endsWithLastConnection = true } }

    /// Counts a connection the listener accepted, until it closes.
    func opened(_ connection: NSXPCConnection) {
        let client = connection.processIdentifier
        lock.withLock {
            open += 1
            generation += 1
        }
        connection.invalidationHandler = { [self] in closed(client: client) }
    }

    private func closed(client: pid_t) {
        let (last, now, once) = lock.withLock {
            open -= 1
            generation += 1
            return (open == 0, generation, endsWithLastConnection)
        }
        guard last else { return }
        if once { end(); return }
        wait(client: client, generation: now, since: Date())
    }

    /// Ends the helper once its app is gone, or after `idleTime` with nobody connected, unless a connection comes first.
    private func wait(client: pid_t, generation expected: Int, since: Date) {
        queue.asyncAfter(deadline: .now() + Self.checkEvery) { [self] in
            guard lock.withLock({ generation == expected }) else { return }
            if Self.isGone(client) || Date().timeIntervalSince(since) >= Self.idleTime {
                end()
                return
            }
            wait(client: client, generation: expected, since: since)
        }
    }

    /// Whether the process has ended. The sandbox refuses signals to the app (EPERM) but not the check that it exists.
    static func isGone(_ pid: pid_t) -> Bool { pid > 0 && kill(pid, 0) != 0 && errno == ESRCH }
}
