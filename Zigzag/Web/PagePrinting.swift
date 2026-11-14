import AppKit
import WebKit

/// Printing a page: its print panel as a sheet on its window, laid out as Zigzag's Print… does (fit to the page's
/// width, half-inch margins). Used by the File menu's Print… and by a page's own Print button (`window.print()`).
@MainActor enum PagePrinting {
    static func info() -> NSPrintInfo {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.topMargin = 36; info.bottomMargin = 36; info.leftMargin = 36; info.rightMargin = 36
        return info
    }

    /// One print at a time per window: a page asking again while its panel is up waits for nothing.
    private static var printing: Set<ObjectIdentifier> = []
    /// When each page's last print sheet closed, so a page that calls print() again straight away (some do, in a
    /// loop) doesn't put the sheet straight back up. Held weakly: a closed tab's page lets go of its entry.
    private static let lastClosed = NSMapTable<WKWebView, NSDate>.weakToStrongObjects()
    /// How long after its sheet closes a page's own print() is let be.
    nonisolated static let pause: TimeInterval = 2

    /// WebKit's (unpublished) print of one frame, as Safari prints an iframe's `contentWindow.print()`.
    static let framePrint = NSSelectorFromString("_printOperationWithPrintInfo:forFrame:")

    /// A page's own `print()`, from its main frame or from an iframe (`frame`, WebKit's handle for it). Only a page you
    /// can see gets a print sheet: a background tab's is finished at once, as is one asking again within `pause` of
    /// its last sheet closing.
    static func printForPage(_ webView: WKWebView, frame: AnyObject?, in window: NSWindow?, completion: @escaping () -> Void) {
        guard mayPrint(shown: isShown(webView, in: window), lastClosed: lastClosed.object(forKey: webView) as Date?, now: Date()) else {
            completion(); return
        }
        print(webView, frame: frame, in: window) { [weak webView] in
            if let webView { lastClosed.setObject(Date() as NSDate, forKey: webView) }
            completion()
        }
    }

    /// Whether a page's own print() gets a sheet: it's on screen, and its last sheet didn't just close.
    nonisolated static func mayPrint(shown: Bool, lastClosed: Date?, now: Date) -> Bool {
        guard shown else { return false }
        if let lastClosed, now.timeIntervalSince(lastClosed) < pause { return false }
        return true
    }

    /// On screen in its window: not a background tab (whose page has no window), not a pane hidden behind a zoomed
    /// one, not in a window that's minimized or hidden.
    static func isShown(_ webView: WKWebView, in window: NSWindow?) -> Bool {
        guard let own = webView.window, window == nil || own === window else { return false }
        return own.isVisible && !own.isMiniaturized && !webView.isHiddenOrHasHiddenAncestor
    }

    static func print(_ webView: WKWebView, frame: AnyObject? = nil, in window: NSWindow?, completion: @escaping () -> Void) {
        guard let window = window ?? webView.window else { completion(); return }
        // Kept by id, not by the window: a window freed while its sheet was up still lets go of its place.
        let id = ObjectIdentifier(window)
        guard !printing.contains(id) else { completion(); return }
        printing.insert(id)
        let operation = operation(for: webView, frame: frame)
        operation.view?.frame = webView.bounds
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        let done = Done {
            printing.remove(id)
            completion()
        }
        operation.runModal(for: window, delegate: done, didRun: #selector(Done.printOperationDidRun(_:success:contextInfo:)),
                           contextInfo: Unmanaged.passRetained(done).toOpaque())
    }

    /// The frame that asked, when WebKit can print one frame on its own; otherwise the whole page.
    static func operation(for webView: WKWebView, frame: AnyObject?) -> NSPrintOperation {
        if let frame, webView.responds(to: framePrint),
           let operation = webView.perform(framePrint, with: info(), with: frame)?.takeUnretainedValue() as? NSPrintOperation {
            return operation
        }
        return webView.printOperation(with: info())
    }

    /// Hears the print sheet close, then lets itself go (it was kept by `contextInfo` until then).
    private final class Done: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
            action()
            if let contextInfo { Unmanaged<Done>.fromOpaque(contextInfo).release() }
        }
    }
}
