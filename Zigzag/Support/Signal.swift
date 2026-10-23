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

/// Coalesces bursts of calls into one, after a delay.
final class Debouncer {
    private let delay: TimeInterval
    private var work: DispatchWorkItem?

    init(delay: TimeInterval) { self.delay = delay }

    func call(_ action: @escaping () -> Void) {
        work?.cancel()
        let item = DispatchWorkItem { MainActor.assumeIsolated { action() } }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func cancel() { work?.cancel(); work = nil }
}
