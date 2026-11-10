import AppKit
import ObjectiveC
import WebKit

// A streamed tab's sound (Media Source, as on YouTube) never reaches Web Audio, so tab capture can hear it only
// where WebKit plays it: its GPU process, which plays every page's sound, other tabs' and private windows' as well.
// What's heard there goes to an extension only while the captured tab is the one page in Zigzag with sound. The
// moment any other page has some, the capture pauses: nothing more is handed over, the tap is taken down (so nothing
// is even recorded), and the tab plays as usual. It carries on once the tab has been alone for a moment.

/// Every web view in Zigzag, whoever made it: tabs in every window (private ones and Zigzag Mini included), pop-up
/// windows, Peek, extensions' popups, side panels, offscreen and background pages, and Zigzag's own hidden ones.
/// WebKit plays all their sound in the one GPU process, so the guard on a shared capture looks at all of them, and
/// counting them where they're made means none is missed, including those WebKit makes itself.
@MainActor
enum WebViews {
    private static let all = NSHashTable<WKWebView>.weakObjects()
    private static var watching = false

    static var live: [WKWebView] { all.allObjects }

    /// Installed first thing (main.swift), before any web view exists: each one made from then on is counted.
    static func watchAll() {
        guard !watching, let method = class_getInstanceMethod(WKWebView.self, #selector(WKWebView.init(frame:configuration:))) else { return }
        watching = true
        install(on: method)
    }

    /// `init` takes its object and returns one retained, so both pass through untouched, as unmanaged references.
    private nonisolated static func install(on method: Method) {
        typealias Init = @convention(c) (Unmanaged<WKWebView>, Selector, CGRect, WKWebViewConfiguration) -> Unmanaged<WKWebView>?
        let original = unsafeBitCast(method_getImplementation(method), to: Init.self)
        let selector = method_getName(method)
        let counted: @convention(block) (Unmanaged<WKWebView>, CGRect, WKWebViewConfiguration) -> Unmanaged<WKWebView>? = { object, frame, configuration in
            let made = original(object, selector, frame, configuration)
            // WebKit makes web views on the main thread only.
            if let made, Thread.isMainThread {
                let view = made.takeUnretainedValue()
                MainActor.assumeIsolated { all.add(view) }
            }
            return made
        }
        method_setImplementation(method, imp_implementationWithBlock(counted))
    }

    /// Whether WebKit says the page is playing sound (what the sidebar's speaker shows). Where WebKit doesn't say,
    /// it counts as playing: the guard fails closed.
    static func isPlayingSound(_ webView: WKWebView) -> Bool {
        guard webView.responds(to: NSSelectorFromString("_isPlayingAudio")) else { return true }
        return (webView.value(forKey: "_isPlayingAudio") as? Bool) ?? true
    }

    static func isInPictureInPicture(_ webView: WKWebView) -> Bool {
        let selector = NSSelectorFromString("_isPictureInPictureActive")
        guard webView.responds(to: selector) else { return false }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(webView.method(for: selector), to: Getter.self)(webView, selector)
    }
}

/// One web view's sound, as the guard sees it.
nonisolated struct SoundSource: Sendable, Equatable {
    var isPlaying: Bool
    /// Floating in Picture in Picture: counted as sound even before WebKit says it plays.
    var isPictureInPicture = false
    /// The captured tab's own page.
    var isCaptured = false
    /// One of the capturing extension's own pages: its offscreen page plays the capture back, through Zigzag.
    var isCapturingExtension = false

    /// What each web view in Zigzag is playing, for a capture of `captured` by the extension at `extensionHost`.
    @MainActor
    static func all(capturing captured: WKWebView?, extensionHost: String?) -> [SoundSource] {
        WebViews.live.map { view in
            let url = view.url
            let ownPage = extensionHost != nil && url?.scheme == "webkit-extension" && url?.host() == extensionHost
            return SoundSource(isPlaying: WebViews.isPlayingSound(view), isPictureInPicture: WebViews.isInPictureInPicture(view),
                               isCaptured: captured != nil && view === captured, isCapturingExtension: ownPage)
        }
    }
}

/// When a capture that hears WebKit's shared sound may hand it over. Times are on Core Audio's clock, in seconds.
nonisolated struct SharedSoundGate: Sendable {
    /// What's heard waits this long before going to the extension, and goes only if nothing else had sound
    /// meanwhile: WebKit says a page plays a moment after its sound starts, so nothing from that moment slips out.
    static let hold: TimeInterval = 0.08
    /// After the last other sound stops, the tab must be alone this long before the capture carries on, so the end
    /// of another page's sound (still on its way through WebKit) isn't handed over either.
    static let resumeAfter: TimeInterval = 0.5

    /// Whether any page but the captured tab (and the capturing extension's own) has sound: another tab in any
    /// window, a private window's, Zigzag Mini's, a video floating in Picture in Picture, another extension's page.
    static func othersHaveSound(_ sources: [SoundSource]) -> Bool {
        sources.contains { !$0.isCaptured && !$0.isCapturingExtension && ($0.isPlaying || $0.isPictureInPicture) }
    }

    enum Change: Equatable { case paused, resumed }

    /// Since when the captured tab has been the only page with sound; nil while another has some.
    private(set) var aloneSince: TimeInterval?
    /// Whether the capture is handing sound over (alone for long enough, since the last look).
    private(set) var isLive = false

    /// Starts waiting: even alone, a capture carries on only once it has been for `resumeAfter`.
    init(_ sources: [SoundSource], now: TimeInterval) {
        aloneSince = Self.othersHaveSound(sources) ? nil : now
    }

    /// The latest look at every page's sound. Pauses the moment another page has sound (whether or not it was live
    /// yet), resumes once the tab has been alone for `resumeAfter`.
    mutating func update(_ sources: [SoundSource], now: TimeInterval) -> Change? {
        if Self.othersHaveSound(sources) {
            let wasOpen = aloneSince != nil
            aloneSince = nil
            isLive = false
            return wasOpen ? .paused : nil
        }
        let since = aloneSince ?? now
        aloneSince = since
        guard !isLive, now - since >= Self.resumeAfter else { return nil }
        isLive = true
        return .resumed
    }

    enum Delivery: Equatable { case wait, deliver, drop }

    /// What becomes of sound captured from `start` to `end`, as of the last look: dropped unless all of it was
    /// captured once the tab had been alone for `resumeAfter`, and it's still alone now; handed over once its last
    /// sample has waited `hold`.
    func delivery(capturedFrom start: TimeInterval, to end: TimeInterval, now: TimeInterval) -> Delivery {
        guard isLive, let since = aloneSince, start >= since + Self.resumeAfter else { return .drop }
        return now - end >= Self.hold ? .deliver : .wait
    }
}

/// A capture of a streamed tab through WebKit's shared sound, guarded: the tap runs only while the gate is live, and
/// what it hears is handed over buffer by buffer, each on the gate's latest look.
@MainActor
final class SharedSoundCapture {
    /// What hears the sound (SystemAudioTap; tests give their own).
    protocol Tap: AnyObject { func stop() }
    struct Chunk: Sendable, Equatable {
        let rate: Double
        let pcm: String
        /// When its first sample was captured, and when its last one ended.
        let from: TimeInterval
        let until: TimeInterval
    }
    /// Starts a tap that sends each chunk it hears to `receive`, from any thread.
    typealias StartTap = (_ receive: @escaping @Sendable (Chunk) -> Void) throws -> Tap

    private(set) var gate: SharedSoundGate
    private(set) var tap: Tap?
    private var held: [Chunk] = []
    private let startTap: StartTap
    /// Each tap started counts up: what a tap already taken down still sends is passed over.
    private(set) var generation = 0
    /// The tap couldn't start (macOS refused, WebKit's audio isn't running).
    private(set) var failure: Error?

    init(_ sources: [SoundSource], now: TimeInterval, startTap: @escaping StartTap) {
        gate = SharedSoundGate(sources, now: now)
        self.startTap = startTap
    }

    var isHearing: Bool { tap != nil }

    /// The latest look at every page's sound: pausing takes the tap down and drops all it heard that's waiting;
    /// resuming starts it again.
    @discardableResult
    func update(_ sources: [SoundSource], now: TimeInterval) -> SharedSoundGate.Change? {
        let change = gate.update(sources, now: now)
        if !gate.isLive { takeDown() }
        if change == .resumed { startHearing() }
        return change
    }

    /// What's due to go to the extension now, per the last look (call `update` first). The rest waits or is dropped.
    func take(now: TimeInterval) -> [Chunk] {
        var due: [Chunk] = []
        held = held.filter { chunk in
            switch gate.delivery(capturedFrom: chunk.from, to: chunk.until, now: now) {
            case .deliver: due.append(chunk); return false
            case .wait: return true
            case .drop: return false
            }
        }
        return due
    }

    /// The capture ended: the tap goes, and with it everything waiting.
    func end() { takeDown() }

    /// A chunk the current tap heard, kept until it's due. Main thread.
    func receive(_ chunk: Chunk, generation: Int) {
        guard tap != nil, generation == self.generation else { return }
        held.append(chunk)
        // Never more than about a second waits.
        if held.count > 60 { held.removeFirst(held.count - 60) }
    }

    private func startHearing() {
        guard tap == nil else { return }
        generation += 1
        let current = generation
        do {
            tap = try startTap { [weak self] chunk in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(chunk, generation: current) } }
            }
        } catch {
            failure = error
        }
    }

    private func takeDown() {
        tap?.stop()
        tap = nil
        held = []
    }
}

extension SystemAudioTap: SharedSoundCapture.Tap {}

/// Gathers a tap's sound into chunks like the page taps send: about a fiftieth of a second of 16-bit mono, each
/// stamped with when it was captured.
nonisolated final class SharedSoundChunks: @unchecked Sendable {
    private var samples: [Int16] = []
    private var firstCaptured: TimeInterval?
    private var lastEnded: TimeInterval = 0
    private let send: @Sendable (SharedSoundCapture.Chunk) -> Void
    /// How loud it's been, for the extensions log: a capture macOS doesn't let Zigzag hear gets only silence.
    private(set) var peak: Float = 0
    private var sent = 0
    var report: (@Sendable (Float) -> Void)?

    init(send: @escaping @Sendable (SharedSoundCapture.Chunk) -> Void) { self.send = send }

    func add(_ buffer: UnsafeBufferPointer<Float>, rate: Double, capturedAt: TimeInterval) {
        if firstCaptured == nil { firstCaptured = capturedAt }
        lastEnded = capturedAt + Double(buffer.count) / max(1, rate)
        for value in buffer {
            peak = max(peak, abs(value))
            let clamped = max(-1, min(1, value))
            samples.append(Int16(clamped < 0 ? clamped * 0x8000 : clamped * 0x7fff))
        }
        let size = Int(rate / 48)
        guard samples.count >= size, let first = firstCaptured else { return }
        let pcm = samples.withUnsafeBufferPointer { Data(buffer: $0) }.base64EncodedString()
        samples.removeAll(keepingCapacity: true)
        firstCaptured = nil
        send(SharedSoundCapture.Chunk(rate: rate, pcm: pcm, from: first, until: lastEnded))
        sent += 1
        if sent == 150 { report?(peak) }
    }
}
