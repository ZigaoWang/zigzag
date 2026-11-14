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

    static func print(_ webView: WKWebView, in window: NSWindow?, completion: @escaping () -> Void) {
        guard let window = window ?? webView.window, !printing.contains(ObjectIdentifier(window)) else { completion(); return }
        printing.insert(ObjectIdentifier(window))
        let operation = webView.printOperation(with: info())
        operation.view?.frame = webView.bounds
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        let done = Done { [weak window] in
            if let window { printing.remove(ObjectIdentifier(window)) }
            completion()
        }
        operation.runModal(for: window, delegate: done, didRun: #selector(Done.printOperationDidRun(_:success:contextInfo:)),
                           contextInfo: Unmanaged.passRetained(done).toOpaque())
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
