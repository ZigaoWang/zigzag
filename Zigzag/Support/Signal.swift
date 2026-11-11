import Foundation

/// A tiny main-thread multicast event. Observers hold a token; dropping it unsubscribes.
final class Signal<Value> {
    private var handlers: [UUID: (Value) -> Void] = [:]

    func observe(_ handler: @escaping (Value) -> Void) -> SignalToken {
        let id = UUID()
        handlers[id] = handler
        return SignalToken { [weak self] in self?.handlers[id] = nil }
    }

    func send(_ value: Value) {
        for handler in Array(handlers.values) { handler(value) }
    }
}

extension Signal where Value == Void {
    func send() { send(()) }
}

final class SignalToken {
    private var cancelAction: (() -> Void)?

    init(_ cancel: @escaping () -> Void) { cancelAction = cancel }

    func cancel() {
        cancelAction?()
        cancelAction = nil
    }

    isolated deinit { cancel() }
}

/// Coalesces bursts of calls into one, after a delay. With `maxWait`, a burst that never pauses (a page rewriting
/// its address as you scroll) still runs it that long after the first call, so a save can't be put off forever.
final class Debouncer {
    private let delay: TimeInterval
    private let maxWait: TimeInterval?
    private var work: DispatchWorkItem?
    private var firstCall: Date?

    init(delay: TimeInterval, maxWait: TimeInterval? = nil) {
        self.delay = delay
        self.maxWait = maxWait
    }

    func call(_ action: @escaping () -> Void) {
        work?.cancel()
        let now = Date()
        let first = firstCall ?? now
        firstCall = first
        var wait = delay
        if let maxWait { wait = max(0, min(delay, maxWait - now.timeIntervalSince(first))) }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.firstCall = nil
                action()
            }
        }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: item)
    }

    func cancel() { work?.cancel(); work = nil; firstCall = nil }
}

/// Runs an action once for a burst of requests. The first request sets it for `delay` later (the next turn of the
/// run loop for none); the requests that come before it runs join it, and one asking for sooner brings it forward.
/// Unlike `Debouncer`, a burst that never pauses still runs it every `delay`, never later.
final class Coalescer {
    private var work: DispatchWorkItem?
    private var deadline: DispatchTime?

    var isPending: Bool { work != nil }

    func schedule(after delay: TimeInterval = 0, _ action: @escaping () -> Void) {
        let wanted = DispatchTime.now() + delay
        if let deadline, deadline <= wanted { return }
        work?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.work = nil
                self?.deadline = nil
                action()
            }
        }
        work = item
        deadline = wanted
        if delay <= 0 { DispatchQueue.main.async(execute: item) } else { DispatchQueue.main.asyncAfter(deadline: wanted, execute: item) }
    }

    func cancel() { work?.cancel(); work = nil; deadline = nil }
}
