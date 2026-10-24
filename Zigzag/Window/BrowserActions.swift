import AppKit
import WebKit

/// Menu actions. Every one of these is reachable from the menu bar with its shortcut shown.
extension BrowserWindowController: NSMenuItemValidation {
    var selectedTab: Tab? { tabManager.selectedTab }
    var selectedWebView: WKWebView? { selectedTab?.webView }

    // MARK: File

    /// Pressing the same shortcut again closes the command bar, like Raycast.
    @objc func newTab(_ sender: Any?) {
        if commandBar.isVisible && commandBar.mode == .newTab { commandBar.dismiss(); return }
        commandBar.show(mode: .newTab)
    }
    @objc func openLocation(_ sender: Any?) {
        if commandBar.isVisible && commandBar.mode == .editCurrent { commandBar.dismiss(); return }
        commandBar.show(mode: .editCurrent)
    }
    @objc func closeTab(_ sender: Any?) {
        if commandBar.isVisible { commandBar.dismiss(); return }
        if dismissFloatingContent() { return }
        guard let tab = selectedTab else {
            window?.performClose(sender)
            return
        }
        closeWithUndo(tab)
    }
    @objc func closeWindow(_ sender: Any?) { window?.performClose(sender) }

    /// Copies a link and says so, wherever the copy came from.
    func copyLink(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        Toast.show("Link copied", symbol: "link", in: self)
    }

    @objc func showDownloads(_ sender: Any?) {
        // From the sidebar's Downloads button when it's there; from the address otherwise.
        let anchor = sidebar.downloadsAnchor.isHidden ? sidebar.address : sidebar.downloadsAnchor
        if !root.sidebarVisible { toggleBrowserSidebar(sender) }
        DownloadsPanel.show(from: anchor, in: self)
    }

    @objc func clearCache(_ sender: Any?) {
        Task { @MainActor in
            await WebsiteData.clear(.cache)
            Toast.show("Cache cleared. Pages load fresh.", symbol: "arrow.clockwise", duration: 2, in: self)
        }
    }

    @objc func clearCookies(_ sender: Any?) { confirmClearCookies() }

    /// History can't come back once it's gone, so it asks first.
    @objc func clearHistory(_ sender: Any?) {
        ConfirmSheet.show(in: root.overlay, title: "Clear all history?",
                          message: "Every page you’ve visited is forgotten on this Mac, and the command bar stops suggesting them. Tabs, bookmarks and passwords stay.",
                          confirmTitle: "Clear History", destructive: true) { [weak self] confirmed in
            guard confirmed, let self else { return }
            HistoryStore.shared.clearAll()
            Toast.show("History cleared", symbol: "clock.arrow.circlepath", duration: 2, in: self)
        }
    }
    @objc func reopenClosedTab(_ sender: Any?) { tabManager.reopenClosedTab() }

    @objc func openDocument(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.html, .pdf, .webArchive, .image, .plainText, .svg]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.tabManager.newTab(url: url)
        }
    }

    @objc func printPage(_ sender: Any?) {
        guard let webView = selectedWebView, let window else { return }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.topMargin = 36; info.bottomMargin = 36; info.leftMargin = 36; info.rightMargin = 36
        let operation = webView.printOperation(with: info)
        operation.view?.frame = webView.bounds
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    @objc func exportAsPDF(_ sender: Any?) {
        guard let webView = selectedWebView, let window, let tab = selectedTab else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = tab.displayTitle.replacingOccurrences(of: "/", with: "-") + ".pdf"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            webView.createPDF { result in
                if case .success(let data) = result { try? data.write(to: url) }
            }
        }
    }

    // MARK: Edit

    @objc func copyPageURL(_ sender: Any?) {
        guard let url = selectedTab?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        Toast.show("Link copied", symbol: "link", in: self)
    }

    @objc func copyPageURLAsMarkdown(_ sender: Any?) {
        guard let tab = selectedTab, let url = tab.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("[\(tab.displayTitle)](\(url.absoluteString))", forType: .string)
        Toast.show("Markdown link copied", symbol: "link", in: self)
    }

    @objc func showFindBar(_ sender: Any?) { findBar.show() }
    @objc func findNextMatch(_ sender: Any?) { findBar.next(backwards: false) }
    @objc func findPreviousMatch(_ sender: Any?) { findBar.next(backwards: true) }
    @objc func useSelectionForFind(_ sender: Any?) {
        selectedWebView?.evaluateJavaScript("window.getSelection().toString()") { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let text = result as? String, !text.isEmpty else { return }
                self?.findBar.show(query: text)
            }
        }
    }

    // MARK: View

    @objc func toggleBrowserSidebar(_ sender: Any?) {
        root.setSidebarVisible(!root.sidebarVisible, animated: true)
        onStateChange?()
    }

    @objc func reloadPage(_ sender: Any?) { selectedTab?.reload() }
    @objc func reloadPageFromOrigin(_ sender: Any?) { selectedTab?.reloadFromOrigin() }
    @objc func stopLoading(_ sender: Any?) { selectedTab?.stopLoading() }

    private static let zoomSteps: [CGFloat] = [0.5, 0.67, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    @objc func zoomIn(_ sender: Any?) {
        guard let webView = selectedWebView else { return }
        let next = Self.zoomSteps.first { $0 > webView.pageZoom + 0.001 } ?? Self.zoomSteps.last!
        setZoom(next)
    }

    @objc func zoomOut(_ sender: Any?) {
        guard let webView = selectedWebView else { return }
        let next = Self.zoomSteps.last { $0 < webView.pageZoom - 0.001 } ?? Self.zoomSteps.first!
        setZoom(next)
    }

    @objc func actualSize(_ sender: Any?) {
        setZoom(1)
        selectedWebView?.magnification = 1
    }

    private func setZoom(_ zoom: CGFloat) {
        guard let webView = selectedWebView, let url = selectedTab?.url else { return }
        webView.pageZoom = zoom
        ZoomLevels.set(zoom, for: url)
        Toast.show("\(Int((zoom * 100).rounded()))%", symbol: zoom < 1 ? "minus.magnifyingglass" : zoom > 1 ? "plus.magnifyingglass" : "magnifyingglass", in: self)
    }

    @objc func showWebInspector(_ sender: Any?) {
        guard let webView = selectedWebView else { return }
        // There is no public API to open the inspector; WebKit's private one is stable and widely used.
        let inspectorSelector = NSSelectorFromString("_inspector")
        guard webView.responds(to: inspectorSelector),
              let inspector = webView.perform(inspectorSelector)?.takeUnretainedValue() as? NSObject else { return }
        let show = NSSelectorFromString("show")
        if inspector.responds(to: show) { inspector.perform(show) }
    }

    @objc func viewSource(_ sender: Any?) {
        guard let url = selectedTab?.url, url.scheme?.hasPrefix("http") == true else { return }
        selectedWebView?.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let html = result as? String, let self else { return }
                let escaped = html.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                let page = "<!doctype html><meta charset=utf-8><title>Source of \(url.host() ?? "")</title><style>:root{color-scheme:light dark}body{margin:16px;font:12px ui-monospace,monospace;white-space:pre-wrap;word-break:break-all}</style>\(escaped)"
                let tab = self.tabManager.newTab(url: nil, title: "Source of \(url.host() ?? "page")")
                tab.ensureWebView().loadHTMLString(page, baseURL: nil)
            }
        }
    }

    @objc func toggleDeskView(_ sender: Any?) { desk.toggle() }

    @objc func toggleSplitOrientation(_ sender: Any?) {
        if let tab = selectedTab { tabManager.toggleSplitOrientation(for: tab) }
    }

    @objc func toggleReader(_ sender: Any?) { toggleReader() }
    @objc func translatePage(_ sender: Any?) { translatePage() }

    /// Floats the playing video. When WebKit can't tell which video that is, says how to do it from the page.
    @objc func togglePictureInPicture(_ sender: Any?) {
        guard let webView = selectedWebView else { return }
        if webView.canTogglePictureInPicture || webView.isPictureInPictureActive {
            webView.togglePictureInPicture()
        } else {
            Toast.show("Point at a video and choose Picture in Picture", symbol: "pip", duration: 2.5, in: self)
        }
    }

    @objc func closeSplitView(_ sender: Any?) {
        if let tab = selectedTab { unsplitWithUndo(tab) }
    }

    // MARK: History

    @objc func goBack(_ sender: Any?) {
        if let peek = peekController, peek.isVisible { peek.goBack(); return }
        selectedTab?.goBack()
    }
    @objc func goForward(_ sender: Any?) {
        if let peek = peekController, peek.isVisible { peek.goForward(); return }
        selectedTab?.goForward()
    }
    @objc func searchHistory(_ sender: Any?) {
        if commandBar.isVisible && commandBar.mode == .history { commandBar.dismiss(); return }
        commandBar.show(mode: .history)
    }

    // MARK: Bookmarks

    @objc func toggleBookmark(_ sender: Any?) {
        guard let tab = selectedTab else { return }
        if let bookmarkID = tab.bookmarkID {
            unbookmarkWithUndo(bookmarkID, to: 0)
            Toast.show("Bookmark removed", symbol: "bookmark.slash", in: self)
        } else {
            bookmarkWithUndo(tab, at: nil, in: tab.spaceID)
            Toast.show("Bookmarked", symbol: "bookmark.fill", in: self)
        }
    }

    // MARK: Tabs

    @objc func selectNextTab(_ sender: Any?) { tabManager.selectNext(offset: 1) }
    @objc func selectPreviousTab(_ sender: Any?) { tabManager.selectNext(offset: -1) }
    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        // Cmd+9 always means the last tab, like every browser.
        if sender.tag == 9 { tabManager.select(at: Int.max) } else { tabManager.select(at: sender.tag - 1) }
    }
    @objc func duplicateTab(_ sender: Any?) {
        guard let tab = selectedTab else { return }
        duplicate(tab)
    }

    /// A copy of a tab, with its back and forward history, opened next to it.
    func duplicate(_ tab: Tab) {
        let copy = tabManager.newTab(url: nil, title: tab.displayTitle)
        if let state = tab.interactionStateForSaving {
            copy.ensureWebView().interactionState = state as NSData
        } else if let url = tab.url {
            copy.load(url)
        }
    }
    @objc func toggleMute(_ sender: Any?) {
        guard let tab = selectedTab else { return }
        tab.setMuted(!tab.isMuted)
    }
    @objc func closeOtherTabs(_ sender: Any?) {
        guard let tab = selectedTab else { return }
        closeManyWithUndo(tabManager.currentTabs.filter { $0 !== tab })
    }
    @objc func closeTabsBelow(_ sender: Any?) {
        guard let tab = selectedTab, let index = tabManager.currentTabs.firstIndex(where: { $0 === tab }) else { return }
        closeManyWithUndo(Array(tabManager.currentTabs.dropFirst(index + 1)))
    }

    // MARK: Spaces

    @objc func nextSpace(_ sender: Any?) { tabManager.switchSpace(by: 1) }
    @objc func previousSpace(_ sender: Any?) { tabManager.switchSpace(by: -1) }
    @objc func selectSpaceByNumber(_ sender: NSMenuItem) {
        let spaces = Library.shared.spaces
        let index = sender.tag - 1
        guard spaces.indices.contains(index) else { return }
        tabManager.switchToSpace(spaces[index].id)
    }
    /// Help › Getting Started: the guide, from the first step.
    @objc func showGettingStarted(_ sender: Any?) {
        Tutorial.restart()
        GuidedTour.start(in: self)
    }

    @objc func newSpace(_ sender: Any?) {
        var created: SpaceInfo?
        libraryChange("New Space") { created = Library.shared.addSpace() }
        guard let space = created else { return }
        Tutorial.complete("space")
        tabManager.switchToSpace(space.id)
        renameSpace(nil)
    }
    @objc func renameSpace(_ sender: Any?) {
        openSpaceEditor(tabManager.currentSpaceID)
    }

    // MARK: Validation

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let tab = selectedTab
        switch item.action {
        case #selector(goBack(_:)): return (peekController?.isVisible == true) || (tab?.canGoBack ?? false)
        case #selector(goForward(_:)): return (peekController?.isVisible == true) || (tab?.canGoForward ?? false)
        case #selector(reloadPage(_:)), #selector(reloadPageFromOrigin(_:)), #selector(copyPageURL(_:)), #selector(copyPageURLAsMarkdown(_:)),
             #selector(printPage(_:)), #selector(exportAsPDF(_:)), #selector(showFindBar(_:)), #selector(zoomIn(_:)), #selector(zoomOut(_:)),
             #selector(actualSize(_:)), #selector(showWebInspector(_:)), #selector(viewSource(_:)), #selector(duplicateTab(_:)),
             #selector(useSelectionForFind(_:)):
            return tab != nil
        case #selector(findNextMatch(_:)), #selector(findPreviousMatch(_:)):
            return tab != nil && findBar.hasQuery
        case #selector(stopLoading(_:)): return tab?.isLoading ?? false
        case #selector(closeSplitView(_:)), #selector(toggleSplitOrientation(_:)): return tab.map { tabManager.split(for: $0) != nil } ?? false
        case #selector(reopenClosedTab(_:)): return tabManager.canReopenClosedTab
        case #selector(toggleBrowserSidebar(_:)):
            item.title = root.sidebarVisible ? "Hide Sidebar" : "Show Sidebar"
            return true
        case #selector(toggleBookmark(_:)):
            item.title = tab?.bookmarkID != nil ? "Remove Bookmark" : "Bookmark This Page"
            return tab?.url != nil
        case #selector(toggleMute(_:)):
            item.title = tab?.isMuted == true ? "Unmute Tab" : "Mute Tab"
            return tab != nil
        case #selector(closeOtherTabs(_:)), #selector(closeTabsBelow(_:)): return tab != nil && tab?.bookmarkID == nil
        case #selector(selectSpaceByNumber(_:)):
            let spaces = Library.shared.spaces
            let index = item.tag - 1
            return spaces.indices.contains(index)
        case #selector(nextSpace(_:)), #selector(previousSpace(_:)): return Library.shared.spaces.count > 1
        default: return true
        }
    }
}

/// Per-site zoom, remembered.
enum ZoomLevels {
    private static let key = "ZoomLevels"

    static func zoom(for url: URL) -> CGFloat {
        let levels = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        return CGFloat(levels[HistoryStore.normalizedHost(url)] ?? 1)
    }

    /// How many sites have their own zoom.
    static var count: Int { (UserDefaults.standard.dictionary(forKey: key) ?? [:]).count }

    static func resetAll() { UserDefaults.standard.removeObject(forKey: key) }

    static func set(_ zoom: CGFloat, for url: URL) {
        var levels = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        let host = HistoryStore.normalizedHost(url)
        if abs(zoom - 1) < 0.001 { levels[host] = nil } else { levels[host] = Double(zoom) }
        UserDefaults.standard.set(levels, forKey: key)
    }
}
