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
        // An extension that replaces the new tab page (Momentum, say) gets a real tab, as in Chrome; ⌘L still searches.
        if #available(macOS 15.4, *), let page = tabManager.extensionHost?.newTabOverride() {
            tabManager.newTab(url: page)
            return
        }
        commandBar.show(mode: .newTab)
    }
    @objc func openLocation(_ sender: Any?) {
        if commandBar.isVisible && commandBar.mode == .editCurrent { commandBar.dismiss(); return }
        commandBar.show(mode: .editCurrent)
    }
    @objc func closeTab(_ sender: Any?) {
        if commandBar.isVisible { commandBar.dismiss(); return }
        // On the desk, the card you're on.
        if desk.isVisible { desk.closeFocused(); return }
        if dismissFloatingContent() { return }
        // Rows picked in the sidebar, with the keys still there: all of them, as one step.
        if sidebar.list.marksHaveFocus { closeMarked(sidebar.list.marked); return }
        guard let tab = selectedTab else {
            // An empty space in a window that still has tabs in other spaces: closing the window would take those
            // too, so ⌘W stops here. With nothing open anywhere, it closes the window as on any Mac.
            if tabManager.allTabs.contains(where: { $0.bookmarkID == nil }) { NSSound.beep(); return }
            window?.performClose(sender)
            return
        }
        closeWithUndo(tab)
    }

    /// Copies a link and says so, wherever the copy came from.
    func copyLink(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        Toast.show(String(localized: "Link copied", comment: "Toast after the page's address is copied."), symbol: "link", in: self)
    }

    @objc func showDownloads(_ sender: Any?) {
        // From the sidebar's Downloads button; with the sidebar hidden, from its stand-in in the same corner, and the
        // sidebar stays hidden, as you left it.
        if !(root.sidebarVisible || root.isSidebarFloatingVisible) {
            showFloatingDownloads()
            floatingDownloads.layoutSubtreeIfNeeded()
            DownloadsPanel.show(from: floatingDownloadsButton, in: self)
            return
        }
        let anchor = sidebar.downloadsAnchor.isHidden ? sidebar.address : sidebar.downloadsAnchor
        DownloadsPanel.show(from: anchor, in: self)
    }

    @objc func clearCache(_ sender: Any?) { confirmClearCache() }

    @objc func clearCookies(_ sender: Any?) { confirmClearCookies() }

    /// It's all of it, so it asks first; ⌘Z (or Undo on the toast) brings it back.
    @objc func clearHistory(_ sender: Any?) {
        ConfirmSheet.show(in: root.overlay, title: HistoryPage.clearTitle, message: Words.sentences(HistoryPage.clearMessage, HistoryPage.whoseNote(tabManager.profile.id)),
                          confirmTitle: String(localized: "Clear History", comment: "Button that clears all history, in the sheet that asks first."), destructive: true) { [weak self] confirmed in
            guard confirmed, let self else { return }
            self.historyChange(String(localized: "Clear History", comment: "Undo action name, shown in the Edit menu as Undo Clear History.")) { [tabManager] in tabManager.profile.history.remove() }
            HistoryPage.clearedToast(in: self)
        }
    }
    @objc func reopenClosedTab(_ sender: Any?) { tabManager.reopenClosedTab() }

    static var openFileTitle: String { String(localized: "Open File…", comment: "File menu item.") }

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
        // A PDF prints as itself, page for page.
        if !(peekController?.isVisible ?? false), !isReaderOpen, let pdf = selectedTab?.pdfViewer { pdf.print(); return }
        guard let webView = printableWebView, let window else { return }
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
        guard let webView = printableWebView, let window, let tab = selectedTab else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let title = webView === selectedWebView ? tab.displayTitle : (webView.title ?? tab.displayTitle)
        panel.nameFieldStringValue = title.replacingOccurrences(of: "/", with: "-") + ".pdf"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            // Paged like a printout (Letter or A4, whichever this Mac uses), not one endless strip.
            let info = NSPrintInfo.shared.copy() as! NSPrintInfo
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
            info.horizontalPagination = .fit
            info.verticalPagination = .automatic
            info.isHorizontallyCentered = false
            let operation = webView.printOperation(with: info)
            operation.view?.frame = webView.bounds
            operation.showsPrintPanel = false
            operation.showsProgressPanel = false
            operation.runModal(for: window, delegate: self, didRun: #selector(self.exported(_:success:contextInfo:)), contextInfo: nil)
        }
    }

    @objc func takePageScreenshot(_ sender: Any?) {
        guard let tab = selectedTab else { return }
        PageScreenshot.take(tab, in: self)
    }

    @objc private func exported(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        Toast.show(success ? String(localized: "Exported as PDF", comment: "Toast after the page is exported as a PDF.") : String(localized: "Couldn’t export the PDF", comment: "Toast when exporting the page as a PDF fails."),
                    symbol: success ? "doc.richtext" : "exclamationmark.triangle", in: self)
    }

    /// File › Share…: the page's address and title to Messages, Mail, AirDrop, Notes and the rest, from the address bar.
    @objc func sharePage(_ sender: Any?) {
        guard let tab = selectedTab, let url = tab.url else { return }
        // From the address bar, or the top of the page with the sidebar hidden, which stays hidden.
        let anchor = addressAnchor
        let picker = NSSharingServicePicker(items: [url as NSURL])
        picker.show(relativeTo: anchor.rect, of: anchor.view, preferredEdge: .maxY)
    }

    /// File › Save Page As…: the page as a web archive, pictures and all, that opens offline; a PDF or picture open in
    /// the tab is saved as itself.
    @objc func savePageAs(_ sender: Any?) {
        if let pdf = selectedTab?.pdfViewer { pdf.save(); return }
        guard let webView = selectedWebView, let window, let tab = selectedTab, let url = tab.url else { return }
        let ext = url.pathExtension.lowercased()
        let isFile = ["pdf", "png", "jpg", "jpeg", "gif", "webp", "svg", "mp4", "mov", "txt"].contains(ext)
        let panel = NSSavePanel()
        let name = tab.displayTitle.replacingOccurrences(of: "/", with: "-")
        if isFile {
            panel.nameFieldStringValue = url.lastPathComponent
        } else {
            panel.allowedContentTypes = [.webArchive]
            panel.nameFieldStringValue = name + ".webarchive"
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let destination = panel.url else { return }
            if isFile {
                // Downloaded again with the page's own cookies, so a signed-in PDF saves too.
                webView.startDownload(using: URLRequest(url: url)) { download in
                    DownloadManager.shared.track(download, window: window, saveTo: destination)
                }
                return
            }
            webView.createWebArchiveData { result in
                MainActor.assumeIsolated {
                    do {
                        try result.get().write(to: destination)
                        Toast.show(String(localized: "Page saved", comment: "Toast after File › Save Page As saves the page."), symbol: "square.and.arrow.down", in: self)
                    } catch {
                        Toast.show(SaveFailure.message(String(localized: "Couldn’t save the page", comment: "Toast when saving the page fails; a reason may follow as its own sentence."), error), symbol: "exclamationmark.triangle", duration: 4, in: self)
                    }
                }
            }
        }
    }

    // MARK: Edit

    @objc func copyPageURL(_ sender: Any?) {
        guard let url = selectedTab?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        Toast.show(String(localized: "Link copied", comment: "Toast after the page's address is copied."), symbol: "link", in: self)
    }

    @objc func copyPageURLAsMarkdown(_ sender: Any?) {
        guard let tab = selectedTab, let url = tab.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("[\(tab.displayTitle)](\(url.absoluteString))", forType: .string)
        Toast.show(String(localized: "Markdown link copied", comment: "Toast after the page's title and address are copied as a Markdown link."), symbol: "link", in: self)
    }

    @objc func showFindBar(_ sender: Any?) { findBar.toggle() }
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

    /// Edit › Find › Jump to Selection: the page scrolls back to what's selected on it, as in Safari.
    @objc func jumpToSelection(_ sender: Any?) {
        let script = "(() => { const s = getSelection(); if (!s || s.rangeCount === 0 || s.isCollapsed) return false;"
            + " const node = s.getRangeAt(0).startContainer; const el = node.nodeType === 1 ? node : node.parentElement;"
            + " if (el) el.scrollIntoView({ block: 'center', behavior: 'smooth' }); return true; })()"
        selectedWebView?.evaluateJavaScript(script, completionHandler: nil)
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
        if zoomReader(1) { return }
        if let pdf = selectedTab?.pdfViewer { pdf.zoomIn(); return }
        guard let webView = selectedWebView else { return }
        let next = Self.zoomSteps.first { $0 > webView.pageZoom + 0.001 } ?? Self.zoomSteps.last!
        setZoom(next)
    }

    @objc func zoomOut(_ sender: Any?) {
        if zoomReader(-1) { return }
        if let pdf = selectedTab?.pdfViewer { pdf.zoomOut(); return }
        guard let webView = selectedWebView else { return }
        let next = Self.zoomSteps.last { $0 < webView.pageZoom - 0.001 } ?? Self.zoomSteps.first!
        setZoom(next)
    }

    @objc func actualSize(_ sender: Any?) {
        if zoomReader(0) { return }
        if let pdf = selectedTab?.pdfViewer { pdf.actualSize(); return }
        setZoom(1)
        selectedWebView?.magnification = 1
    }

    private func setZoom(_ zoom: CGFloat) {
        guard let webView = selectedWebView, let url = selectedTab?.url else { return }
        webView.pageZoom = zoom
        // A private window's zoom lasts only as long as the page: nothing about the site is saved.
        if !tabManager.isPrivate { ZoomLevels.set(zoom, for: url) }
        Toast.show("\(Int((zoom * 100).rounded()))%", symbol: zoom < 1 ? "minus.magnifyingglass" : zoom > 1 ? "plus.magnifyingglass" : "magnifyingglass", in: self)
    }

    /// The page in front's Web Inspector. There is no public API to open it; WebKit's private one is stable and widely used.
    private var selectedInspector: NSObject? {
        let inspectorSelector = NSSelectorFromString("_inspector")
        guard let webView = selectedWebView, webView.responds(to: inspectorSelector) else { return nil }
        return webView.perform(inspectorSelector)?.takeUnretainedValue() as? NSObject
    }

    /// ⌥⌘I again puts it away, as in Safari and Chrome.
    @objc func showWebInspector(_ sender: Any?) {
        guard let inspector = selectedInspector else { return }
        inspector.callIfPresent(inspector.inspectorFlag("isVisible") ? "close" : "show")
    }

    @objc func showJavaScriptConsole(_ sender: Any?) {
        selectedInspector?.callIfPresent("showConsole")
    }

    /// Pick an element on the page to see it in the inspector, as Chrome's ⌥⌘C does. Again, and picking stops.
    @objc func inspectElement(_ sender: Any?) {
        guard let inspector = selectedInspector else { return }
        if !inspector.inspectorFlag("isVisible") { inspector.callIfPresent("show") }
        inspector.callIfPresent("toggleElementSelection")
    }

    @objc func viewSource(_ sender: Any?) {
        guard let url = selectedTab?.url, url.scheme?.hasPrefix("http") == true else { return }
        selectedWebView?.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let html = result as? String, let self else { return }
                let escaped = html.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                let page = "<!doctype html><meta charset=utf-8><title>\(String(localized: "Source of \(url.host() ?? "")", comment: "Title of the tab that shows a page's HTML source. The host is the site's, like example.com."))</title><style>:root{color-scheme:light dark}body{margin:16px;font:12px ui-monospace,monospace;white-space:pre-wrap;word-break:break-all}</style>\(escaped)"
                let tab = self.tabManager.newTab(url: nil, title: url.host().map { String(localized: "Source of \($0)", comment: "Title of the tab that shows a page's HTML source. The host is the site's, like example.com.") }
                                                         ?? String(localized: "Source of page", comment: "Title of the tab that shows a page's HTML source, for a page with no host."))
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
            Toast.show(String(localized: "Point at a video and choose Picture in Picture", comment: "Toast when Picture in Picture finds no video to float."), symbol: "pip", duration: 2.5, in: self)
        }
    }

    /// Zoom Pane (⇧⌘↩): the pane you're in, enlarged over the rest of its split or group, or put back (#160).
    @objc func zoomPane(_ sender: Any?) {
        if let tab = selectedTab { toggleZoom(tab) }
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

    // MARK: Bookmarks

    @objc func addToFavorites(_ sender: Any?) {
        guard let tab = selectedTab, tab.url != nil, !tab.isFavorite, tab.bookmarkID != nil || !tabManager.isPrivate else { return }
        favoriteWithUndo(tab)
        Toast.show(String(localized: "Added to Favorites", comment: "Toast after the tab is added to Favorites."), symbol: "star.fill", in: self)
    }
    @objc func moveTabToNewWindow(_ sender: Any?) {
        guard let tab = selectedTab else { return }
        moveToNewWindow(tab)
    }

    @objc func toggleBookmark(_ sender: Any?) {
        // Pins and favorites are shared by every window: a private one neither adds nor takes them away.
        guard let tab = selectedTab, !tabManager.isPrivate else { return }
        if let bookmarkID = tab.bookmarkID, tab.isFavorite {
            // A favorite stays open as a tab; ⌘Z puts it back in Favorites.
            unfavoriteWithUndo(bookmarkID, to: 0)
            Toast.show(String(localized: "Moved to Tabs", comment: "Toast after a favorite moves back to the tabs."), symbol: "star.slash", in: self)
        } else if let bookmarkID = tab.bookmarkID {
            unbookmarkWithUndo(bookmarkID, to: 0)
            Toast.show(String(localized: "Unpinned", comment: "Toast after a pinned tab is unpinned."), symbol: "pin.slash", in: self)
        } else {
            bookmarkWithUndo(tab, at: nil, in: tab.spaceID)
            Toast.show(String(localized: "Pinned", comment: "Toast after a tab is pinned."), symbol: "pin", in: self)
        }
    }

    // MARK: Tabs

    /// ⌃⇧↑ and ⌃⇧↓: the tab you're on one row up or down, for reordering without a mouse. A split moves only by drag.
    @objc func moveTabUp(_ sender: Any?) { if let target = tabMoveTarget(by: -1), let tab = selectedTab { moveWithUndo(tab, to: target, in: tab.spaceID) } }
    @objc func moveTabDown(_ sender: Any?) { if let target = tabMoveTarget(by: 1), let tab = selectedTab { moveWithUndo(tab, to: target, in: tab.spaceID) } }

    /// Where the tab you're on goes one row up or down, or nil at the end of the list, on a pinned page, or beside a split.
    /// A nested tab moves past the tab beside it at its own level, each with the tabs under it, and stays in its group.
    func tabMoveTarget(by offset: Int) -> Int? {
        guard let tab = selectedTab, tab.bookmarkID == nil, tabManager.split(for: tab) == nil else { return nil }
        let tabs = tabManager.currentTabs
        guard let index = tabs.firstIndex(where: { $0 === tab }), tabs.indices.contains(index + offset),
              tabManager.split(for: tabs[index + offset]) == nil else { return nil }
        guard tabs.contains(where: { $0.parentID != nil }) else { return index + offset }
        return tabManager.siblingMoveTarget(tab, by: offset)
    }

    @objc func selectNextTab(_ sender: Any?) { tabManager.selectNext(offset: 1) }
    @objc func selectPreviousTab(_ sender: Any?) { tabManager.selectNext(offset: -1) }
    /// ⌘1–⌘9: numbered as the sidebar shows them, each favorite tile, then each pinned and tab row, open or not.
    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        // In the tab overview, the number picks the card in that place, as you see them.
        if desk.isVisible { desk.openCard(number: sender.tag); return }
        let rows = Library.shared.favoriteTiles(in: tabManager.profile.id).map { SidebarItem.bookmark($0.0.id) } + sidebar.list.pageRows
        // Cmd+9 always means the last tab, like every browser. An index past the end means the last too.
        guard let index = TabNumbers.index(for: sender.tag, count: rows.count) else { return }
        switch rows[index] {
        case .bookmark(let id): if let bookmark = Library.shared.bookmark(id) { tabManager.openBookmark(bookmark) }
        case .tab(let id): if let tab = tabManager.tab(with: id) { tabManager.select(tab) }
        default: break
        }
    }
    @objc func duplicateTab(_ sender: Any?) {
        guard let tab = selectedTab else { return }
        duplicate(tab)
    }

    /// A copy of a tab, with its back and forward history, opened next to it.
    func duplicate(_ tab: Tab) {
        let copy = tabManager.newTab(url: nil, title: tab.displayTitle)
        if let state = tab.interactionStateForSaving {
            copy.restoreState(state)
        } else if let url = tab.url {
            copy.load(url)
        }
    }
    @objc func toggleMute(_ sender: Any?) {
        guard let tab = selectedTab else { return }
        tab.setMuted(!tab.isMuted)
    }
    @objc func closeOtherTabs(_ sender: Any?) { closeManyWithUndoToast(otherTabs) }
    @objc func closeTabsBelow(_ sender: Any?) { closeManyWithUndoToast(tabsBelow) }

    /// The space's tabs but the one you're on and its split partner. Pinned pages never count: on one, it's every tab.
    var otherTabs: [Tab] {
        guard let tab = selectedTab else { return [] }
        let panes = tabManager.panes(of: tab)
        return tabManager.currentTabs.filter { page in !panes.contains { $0 === page } }
    }

    /// The tabs under the one you're on. Every tab is under a pinned page or favorite.
    var tabsBelow: [Tab] {
        guard let tab = selectedTab else { return [] }
        let tabs = tabManager.currentTabs
        let panes = tabManager.panes(of: tab)
        let last = tabs.lastIndex { page in panes.contains { $0 === page } }
        return Array(tabs.dropFirst(last.map { $0 + 1 } ?? 0))
    }

    /// Several tabs closing at once say how many, with the Undo that brings them back, as Clear does.
    func closeManyWithUndoToast(_ tabs: [Tab]) {
        guard !tabs.isEmpty else { return }
        closeManyWithUndo(tabs)
        showClosedToast(tabs.count)
    }

    // MARK: Spaces

    @objc func nextSpace(_ sender: Any?) { tabManager.switchSpace(by: 1) }
    @objc func previousSpace(_ sender: Any?) { tabManager.switchSpace(by: -1) }
    /// View › Switch Space…: the spaces in a list, to pick one with the keyboard.
    @objc func showSpaceSwitcher(_ sender: Any?) { spaceSwitcher.toggle() }
    @objc func selectSpaceByNumber(_ sender: NSMenuItem) {
        let spaces = Library.shared.spaces
        guard let index = SpaceNumbers.index(for: sender.tag, count: spaces.count) else { return }
        tabManager.switchToSpace(spaces[index].id)
    }
    /// Help › Getting Started: the guide, from the first step.
    @objc func showGettingStarted(_ sender: Any?) {
        Tutorial.restart()
        GuidedTour.start(in: self)
    }
    /// Help › Send Feedback: email or a GitHub issue.
    @objc func sendFeedback(_ sender: Any?) { Feedback.show(in: self) }
    @objc func reportProblem(_ sender: Any?) { ProblemReport.show(in: self) }
    @objc func showWhatsNew(_ sender: Any?) { WhatsNew.show(in: self) }

    @objc func newSpace(_ sender: Any?) {
        // Spaces are kept for good; a private window keeps nothing.
        guard !tabManager.isPrivate else { return }
        var created: SpaceInfo?
        libraryChange(String(localized: "New Space", comment: "Undo action name, shown in the Edit menu as Undo New Space.")) { created = Library.shared.addSpace(profile: tabManager.profile.id) }
        guard let space = created else { return }
        let previous = tabManager.currentSpaceID
        // Into the new space first: that move isn't the guide's "go back" step, which only starts once this one counts.
        tabManager.switchToSpace(space.id)
        Tutorial.complete("space")
        renameSpace(nil)
        // Esc while naming it: never mind. Back where you were, without the space, and the guide still asks for one.
        SpaceEditorPanel.current?.onCancel = { [weak self] in
            guard let self, Library.shared.space(space.id) != nil else { return }
            Tutorial.undo("space")
            if Library.shared.space(previous) != nil { tabManager.switchToSpace(previous) }
            // Nothing was in it yet, so there's nothing for ⌘Z to bring back.
            Library.shared.removeSpace(space.id)
        }
    }
    @objc func renameSpace(_ sender: Any?) {
        openSpaceEditor(tabManager.currentSpaceID)
    }

    // MARK: Validation

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let tab = selectedTab
        // ⌘← and ⌘→ (the hidden Back and Forward) in a text field or a page: BrowserWindow decides whether they move
        // the cursor, and the menu mustn't take them first.
        if item.isHidden, item.action == #selector(goBack(_:)) || item.action == #selector(goForward(_:)),
           window?.firstResponder is NSText || window?.firstResponder is WKWebView {
            return false
        }
        switch item.action {
        case #selector(openDocument(_:)):
            // Zigzag Mini names it Open in Zigzag while it's in front; here it's itself again.
            item.title = Self.openFileTitle
            return true
        case #selector(goBack(_:)): return (peekController?.isVisible == true) || (tab?.canGoBackOrReturn ?? false)
        case #selector(goForward(_:)): return (peekController?.isVisible == true) || (tab?.canGoForward ?? false)
        case #selector(takePageScreenshot(_:)): return PageScreenshot.canTake(tab)
        case #selector(reloadPage(_:)), #selector(reloadPageFromOrigin(_:)), #selector(copyPageURL(_:)), #selector(copyPageURLAsMarkdown(_:)),
             #selector(printPage(_:)), #selector(exportAsPDF(_:)), #selector(showFindBar(_:)), #selector(zoomIn(_:)), #selector(zoomOut(_:)),
             #selector(actualSize(_:)), #selector(showWebInspector(_:)), #selector(showJavaScriptConsole(_:)), #selector(inspectElement(_:)),
             #selector(viewSource(_:)), #selector(duplicateTab(_:)),
             #selector(useSelectionForFind(_:)), #selector(jumpToSelection(_:)):
            return tab != nil
        case #selector(findNextMatch(_:)), #selector(findPreviousMatch(_:)):
            return tab != nil && findBar.hasQuery
        case #selector(stopLoading(_:)): return tab?.isLoading ?? false
        case #selector(closeSplitView(_:)): return tab.map { tabManager.split(for: $0) != nil } ?? false
        case #selector(zoomPane(_:)):
            item.title = PaneHeaderView.zoomTitle(paneZoom.isZoomed)
            return tab.map { tabManager.split(for: $0) != nil } ?? false
        case #selector(toggleSplitOrientation(_:)):
            // Named for what it does, as the pane's own button is.
            let split = tab.flatMap { tabManager.split(for: $0) }
            item.title = split?.vertical == true ? String(localized: "Side by Side", comment: "Menu bar item: lays the split view's two pages side by side.")
                                                 : String(localized: "Stack Vertically", comment: "Menu bar item: stacks the split view's two pages one above the other.")
            // A tile group's pages keep the places they were dropped in.
            return split != nil && split?.isGroup == false
        case #selector(closeTab(_:)):
            // Says how many when ⌘W would close several picked rows.
            let count = sidebar.list.marksHaveFocus ? closingCount(sidebar.list.marked) : 1
            item.title = count > 1 ? String(localized: "Close \(count) Tabs", comment: "File menu item while several sidebar rows are picked")
                : String(localized: "Close Tab", comment: "File menu item")
            return true
        case #selector(reopenClosedTab(_:)): return tabManager.canReopenClosedTab
        case #selector(toggleBrowserSidebar(_:)):
            item.title = root.sidebarVisible ? String(localized: "Hide Sidebar", comment: "Menu bar item: hides the sidebar.")
                                              : String(localized: "Show Sidebar", comment: "Menu bar item: shows the sidebar.")
            return true
        case #selector(toggleBookmark(_:)):
            // As the sidebar names them: a favorite moves back to the tabs, and half of a split pins with its other half.
            let pinsPair = tab.flatMap { tabManager.partner(of: $0) }.map { $0.bookmarkID == nil && $0.url != nil } ?? false
            item.title = tab?.isFavorite == true ? String(localized: "Move to Tabs", comment: "Menu bar item: moves the favorite back to the tabs.")
                : tab?.bookmarkID != nil ? String(localized: "Unpin Tab", comment: "Menu bar item: unpins the tab.")
                : pinsPair ? String(localized: "Pin Split View", comment: "Menu bar item: pins both pages of the split view.")
                : String(localized: "Pin Tab", comment: "Menu bar item: pins the tab.")
            return tab?.url != nil && !tabManager.isPrivate
        case #selector(addToFavorites(_:)): return tab?.url != nil && tab?.isFavorite != true && (tab?.bookmarkID != nil || !tabManager.isPrivate)
        case #selector(moveTabToNewWindow(_:)): return tab != nil && tab?.bookmarkID == nil && !tabManager.isPrivate
        case #selector(newSpace(_:)), #selector(renameSpace(_:)): return !tabManager.isPrivate
        case #selector(sharePage(_:)), #selector(savePageAs(_:)), #selector(togglePictureInPicture(_:)): return tab?.url != nil
        case #selector(toggleReader(_:)):
            item.title = isReaderOpen ? String(localized: "Hide Reader", comment: "Menu bar item: closes Reader.") : String(localized: "Show Reader", comment: "Menu bar item: opens the page in Reader.")
            return tab?.url != nil
        case #selector(translatePage(_:)):
            item.title = tab?.isTranslated == true ? String(localized: "Show Original", comment: "Menu bar item: shows the translated page as it was.")
                                                  : String(localized: "Translate Page", comment: "Menu bar item: translates the page.")
            return tab?.url != nil
        case #selector(toggleMute(_:)):
            item.title = tab?.isMuted == true ? String(localized: "Unmute Tab", comment: "Menu bar item: turns the tab's sound back on.") : String(localized: "Mute Tab", comment: "Menu bar item: silences the tab.")
            return tab != nil
        case #selector(moveTabUp(_:)): return tabMoveTarget(by: -1) != nil
        case #selector(moveTabDown(_:)): return tabMoveTarget(by: 1) != nil
        case #selector(closeOtherTabs(_:)): return !otherTabs.isEmpty
        case #selector(closeTabsBelow(_:)): return !tabsBelow.isEmpty
        case #selector(selectSpaceByNumber(_:)):
            return SpaceNumbers.index(for: item.tag, count: Library.shared.spaces.count) != nil
        case #selector(nextSpace(_:)), #selector(previousSpace(_:)): return Library.shared.spaces.count > 1
        case #selector(showSpaceSwitcher(_:)): return Library.shared.spaces.count > 1 && !tabManager.isPrivate
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

    /// Every site with its own zoom, by host.
    static var all: [String: Double] { UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:] }

    static func forget(host: String) {
        var levels = all
        levels[host] = nil
        UserDefaults.standard.set(levels, forKey: key)
    }

    static func set(_ zoom: CGFloat, for url: URL) {
        var levels = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        let host = HistoryStore.normalizedHost(url)
        if abs(zoom - 1) < 0.001 { levels[host] = nil } else { levels[host] = Double(zoom) }
        UserDefaults.standard.set(levels, forKey: key)
    }
}

/// Calls on WebKit's private inspector object, each checked first, so a name WebKit drops does nothing rather than crash.
private extension NSObject {
    func callIfPresent(_ name: String) {
        let selector = NSSelectorFromString(name)
        if responds(to: selector) { perform(selector) }
    }

    func inspectorFlag(_ name: String) -> Bool {
        let selector = NSSelectorFromString(name)
        guard responds(to: selector) else { return false }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(method(for: selector), to: Getter.self)(self, selector)
    }
}
