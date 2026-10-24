import AppKit

/// First launch, as its own moment: the onboarding in a clean window. The browser appears when it's done.
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    static var shared: WelcomeWindowController?
    private var onFinish: (() -> Void)?

    static func show(onFinish: @escaping () -> Void) {
        if let shared { shared.window?.makeKeyAndOrderFront(nil); return }
        let size = NSSize(width: 860, height: 580)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.title = "Welcome to Zigzag"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = Tokens.Color.formBackground
        let view = OnboardingView(frame: NSRect(origin: .zero, size: size))
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        let controller = WelcomeWindowController(window: window)
        controller.onFinish = onFinish
        view.onFinish = { [weak controller] in controller?.finish() }
        window.delegate = controller
        window.center()
        shared = controller
        controller.showWindow(nil)
    }

    private func finish() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: "ImportOfferDismissed")
        Self.shared = nil
        let done = onFinish
        onFinish = nil
        done?()
    }
}
