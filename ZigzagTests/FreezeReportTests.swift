import Foundation
import Testing
@testable import Zigzag

/// A freeze note says what the main thread was running (#89): its stack read from another thread, named and cut
/// down to a line a report can carry.
struct FreezeReportTests {
    typealias Frame = MainThreadStack.Frame
    private let app = MainThreadStack.appImage

    @Test func swiftNamesComeOutShort() {
        #expect(MainThreadStack.shortName("Zigzag.BrowserWindowController.showPages(animated: Swift.Bool) -> ()") == "BrowserWindowController.showPages")
        #expect(MainThreadStack.shortName("static Zigzag.DarkPages.attach(to: __C.WKWebView) -> ()") == "DarkPages.attach")
        #expect(MainThreadStack.shortName("partial apply for closure #26 (Zigzag.TabManager.Change) -> () in Zigzag.BrowserWindowController.init(tabManager: Zigzag.TabManager) -> Zigzag.BrowserWindowController")
                == "BrowserWindowController.init")
        #expect(MainThreadStack.shortName("function signature specialization <Arg[1] = Dead> of static Zigzag.DarkPages.(isOurs in _3C1A2B)(__C.WKUserScript) -> Swift.Bool")
                == "DarkPages.isOurs")
        #expect(MainThreadStack.shortName("generic specialization <Swift.Array<Swift.Int>> of Zigzag.TabTree.levels(Swift.Array<Zigzag.TabTree.Node>) -> Swift.Dictionary<Foundation.UUID, Swift.Int>") == "TabTree.levels")
    }

    @Test func otherNamesKeepWhatTheySay() {
        #expect(MainThreadStack.shortName("-[NSApplication run]") == "-[NSApplication run]")
        #expect(MainThreadStack.shortName("WebKit::WebViewImpl::viewDidMoveToWindow()") == "WebKit::WebViewImpl::viewDidMoveToWindow")
        #expect(MainThreadStack.demangle("_ZN6WebKit11WebViewImpl19viewDidMoveToWindowEv") == "WebKit::WebViewImpl::viewDidMoveToWindow()")
        #expect(MainThreadStack.shortName("mach_msg2_trap") == "mach_msg2_trap")
    }

    @Test func theSummaryNamesZigzagsFramesAndWhatTheyWaitedIn() {
        let frames = [
            Frame(image: "libsystem_kernel.dylib", symbol: "__psynch_cvwait", offset: 1),
            Frame(image: "WebKit", symbol: "IPC::Connection::waitForMessage", offset: 2),
            Frame(image: "WebKit", symbol: "WebKit::WebViewImpl::viewDidMoveToWindow", offset: 3),
            Frame(image: app, symbol: "BrowserWebView.viewDidMoveToWindow", offset: 4),
            Frame(image: app, symbol: "PageCardView.show", offset: 5),
            Frame(image: "libswift_Concurrency.dylib", symbol: "Swift.MainActor.assumeIsolated<A>", offset: 6),
            Frame(image: app, symbol: "BrowserWindowController.showPages", offset: 7),
            Frame(image: app, symbol: "BrowserWindowController.showSelectedTab", offset: 8),
            Frame(image: app, symbol: "TabManager.select", offset: 9),
            Frame(image: app, symbol: "main", offset: 10),
        ]
        #expect(MainThreadStack.summary(frames) ==
                "BrowserWebView.viewDidMoveToWindow ← PageCardView.show ← BrowserWindowController.showPages ← BrowserWindowController.showSelectedTab | in WebKit::WebViewImpl::viewDidMoveToWindow (WebKit) → __psynch_cvwait (libsystem_kernel.dylib)")
    }

    /// A release build keeps no names of its own: the place in the app is given, to look up with the build's symbols.
    @Test func framesWithoutNamesGiveTheirPlace() {
        #expect(Frame(image: app, symbol: nil, offset: 0x1a2b).text == "\(app)+0x1a2b")
    }

    @Test func waitingForWorkIsNotAFreeze() {
        let idle = [Frame(image: "libsystem_kernel.dylib", symbol: "mach_msg2_trap", offset: 1),
                    Frame(image: "AppKit", symbol: "NSApplicationMain", offset: 2), Frame(image: app, symbol: "main", offset: 3)]
        #expect(MainThreadStack.isIdle(idle))
        let stuck = [Frame(image: "libsystem_kernel.dylib", symbol: "mach_msg2_trap", offset: 1),
                     Frame(image: app, symbol: "Tab.load", offset: 2), Frame(image: app, symbol: "main", offset: 3)]
        #expect(!MainThreadStack.isIdle(stuck))
    }

    @Test func mostLooksDecide() {
        let a = [Frame(image: app, symbol: "A.run", offset: 1)], b = [Frame(image: app, symbol: "B.run", offset: 2)]
        #expect(MainThreadStack.mostCommon([a, b, b, []]) == b)
        #expect(MainThreadStack.mostCommon([[], []]) == nil)
    }

    /// The look itself, from another thread while the main thread is busy: it finds this test's own code there.
    @Test @MainActor func aLookFindsWhatTheMainThreadIsRunning() {
        MainThreadStack.prepare()
        let found = FramesBox()
        let looked = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 0.05)
            found.set(MainThreadStack.frames(MainThreadStack.capture()))
            looked.signal()
        }
        // Busy on the main thread until the look is done.
        let deadline = Date().addingTimeInterval(3)
        while looked.wait(timeout: .now()) == .timedOut, Date() < deadline { busyWork() }
        let frames = found.get()
        #if arch(arm64)
        #expect(frames.count > 3)
        #expect(frames.contains { $0.symbol?.contains("aLookFindsWhatTheMainThreadIsRunning") == true || $0.symbol?.contains("busyWork") == true })
        #endif
    }

    @inline(never) private func busyWork() {
        var x = 0
        for i in 0..<10_000 { x &+= i &* 31 }
        if x == 42 { print(x) }
    }
}

/// Hands the look's frames back from the thread that took it.
nonisolated private final class FramesBox: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [MainThreadStack.Frame] = []
    func set(_ value: [MainThreadStack.Frame]) { lock.lock(); frames = value; lock.unlock() }
    func get() -> [MainThreadStack.Frame] { lock.lock(); defer { lock.unlock() }; return frames }
}
