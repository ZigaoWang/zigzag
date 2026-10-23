import AppKit

final class CommandBarController {
    enum Mode { case newTab, editCurrent, history }
    private weak var window: BrowserWindowController?
    private(set) var isVisible = false

    init(window: BrowserWindowController) { self.window = window }

    func show(mode: Mode) {}
    func dismiss() {}
}

extension CommandBarController {
    func debugType(_ text: String) {}
}
