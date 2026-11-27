import AppKit
import WebKit

/// Menu actions. Every one of these is reachable from the menu bar with its shortcut shown.
extension BrowserWindowController: NSMenuItemValidation {
    var selectedTab: Tab? { tabManager.selectedTab }
    /// The page on screen; nil while another sharing window shows it (#162).
    var selectedWebView: WKWebView? { selectedTab.flatMap { tabManager.isShownElsewhere($0) ? nil : $0.webView } }

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
        // Autohide's bar comes back first, so the address is edited where it is (#359).
        revealAutohide()
        commandBar.show(mode: .editCurrent)
    }
    /// Select All after a sidebar click with no field or page to take it: select its tabs (#302).
    override func selectAll(_ sender: Any?) {
        if (window as? BrowserWindow)?.selectAllInSidebar() != true { NSSound.beep() }
    }
    @objc func closeTab(_ sender: Any?) {
        if inPageMini.closeShown() { return }
        if commandBar.isVisible { commandBar.dismiss(); return }
        // On the desk, the card you're on.
        if desk.isVisible { desk.closeFocused(); return }
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

    /// Copies a link without tracking parameters, with its title as rich text, and shows a toast.
    func copyLink(_ url: URL, title: String?) {
        CleanLink.write(url, title: title)
        Toast.show(String(localized: "Link copied", comment: "Toast after the page's address is copied."), symbol: "link", in: self)
    }

    @objc func showDownloads(_ sender: Any?) {
        // From the sidebar's Downloads button; with the sidebar hidden, from its stand-in in the same corner, and the
        // sidebar stays hidden, as you left it.
        if !(root.chromeSidebarShown || root.isSidebarFloatingVisible) {
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
    @objc func reopenClosedTab(_ sender: Any?) { WindowManager.shared.reopenLastClosed(from: tabManager) }

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
        guard let webView = printableWebView, let window else { return }
        // A PDF prints as itself, page for page, from WebKit's copy underneath Zigzag's viewer: WebKit reads it in
        // the page's sandboxed process, and paper is never dark.
        if webView === selectedWebView, selectedTab?.showsPDF == true {
            let operation = webView.printOperation(with: NSPrintInfo.shared.copy() as! NSPrintInfo)
            operation.view?.frame = webView.bounds
            operation.showsPrintPanel = true
            operation.showsProgressPanel = true
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
            return
        }
        PagePrinting.print(webView, in: window, completion: {})
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

    /// File › Capture… (⇧⌘2): Capture's mode over the page, or out of it again.
    @objc func takePageScreenshot(_ sender: Any?) {
        capture.toggle()
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
        let picker = NSSharingServicePicker(items: [CleanLink.clean(url) as NSURL])
        picker.show(relativeTo: anchor.rect, of: anchor.view, preferredEdge: .maxY)
    }

    /// File › Save Page As…: the page as a web archive, pictures and all, that opens offline; a PDF or picture open in
    /// the tab is saved as itself.
    @objc func savePageAs(_ sender: Any?) {
        if let pdf = selectedTab?.pdfViewer { pdf.save(); return }
        guard let webView = selectedWebView, let window, let tab = selectedTab, let url = tab.url else { return }
        let ext = url.pathExtension.lowercased()
        let isFile = tab.showsPDF || ["pdf", "png", "jpg", "jpeg", "gif", "webp", "svg", "mp4", "mov", "txt"].contains(ext)
        let panel = NSSavePanel()
        let name = tab.displayTitle.replacingOccurrences(of: "/", with: "-")
        if isFile {
            // A PDF at an address without its file name is still saved as a PDF.
            let file = url.lastPathComponent
            panel.nameFieldStringValue = tab.showsPDF && !file.lowercased().hasSuffix(".pdf") ? name + ".pdf" : file
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
        guard let tab = selectedTab, let url = tab.url else { return }
        copyLink(url, title: tab.displayTitle)
    }

    @objc func copyPageURLAsMarkdown(_ sender: Any?) {
        guard let tab = selectedTab, let url = tab.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(CleanLink.markdown(url, title: tab.displayTitle), forType: .string)
        Toast.show(String(localized: "Markdown link copied", comment: "Toast after the page's title and address are copied as a Markdown link."), symbol: "link", in: self)
    }

    @objc func showFindBar(_ sender: Any?) {
        if let webView = selectedWebView, HistoryPage.isHistory(webView.url) { HistoryPage.focusSearch(in: webView); return }
        findBar.toggle()
    }
    @objc func findNextMatch(_ sender: Any?) { findBar.next(backwards: false) }
    @objc func findPreviousMatch(_ sender: Any?) { findBar.next(backwards: true) }
    @objc func useSelectionForFind(_ sender: Any?) {
        selectedWebView?.runOwnScript("window.getSelection().toString()") { [weak self] answer in
            let result = try? answer.get()
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
        selectedWebView?.runOwnScript(script)
    }

    // MARK: View

    @objc func toggleBrowserSidebar(_ sender: Any?) {
        // The Whole Screen keeps the sidebar out of the way: it slides out over the page, and its setting stays.
        if root.isImmersive { root.reveal(!root.isSidebarFloatingVisible); return }
        root.setSidebarVisible(!root.sidebarVisible, animated: true)
        // With the sidebar back, the update card returns there.
        if root.sidebarVisible { Updater.shared.stopFloating() }
        onStateChange?()
    }

    /// View › Move Sidebar to Right (or Left): the same as Settings › Appearance › Sidebar position, for every window.
    @objc func toggleSidebarSide(_ sender: Any?) {
        BrowserRootView.sidebarOnRight.toggle()
    }

    @objc func reloadPage(_ sender: Any?) { selectedTab?.reload() }
    @objc func reloadPageFromOrigin(_ sender: Any?) { selectedTab?.reloadFromOrigin() }
    @objc func stopLoading(_ sender: Any?) { selectedTab?.stopLoading() }

    @objc func zoomIn(_ sender: Any?) {
        if zoomReader(1) { return }
        if let pdf = selectedTab?.pdfViewer { pdf.zoomIn(); return }
        guard let webView = selectedWebView else { return }
        setZoom(ZoomLevels.step(webView.pageZoom, by: 1))
    }

    @objc func zoomOut(_ sender: Any?) {
        if zoomReader(-1) { return }
        if let pdf = selectedTab?.pdfViewer { pdf.zoomOut(); return }
        guard let webView = selectedWebView else { return }
        setZoom(ZoomLevels.step(webView.pageZoom, by: -1))
    }

    @objc func actualSize(_ sender: Any?) {
        if zoomReader(0) { return }
        if let pdf = selectedTab?.pdfViewer { pdf.actualSize(); return }
        setZoom(ZoomLevels.defaultZoom)
        selectedWebView?.magnification = 1
    }

    private func setZoom(_ zoom: CGFloat) {
        guard let webView = selectedWebView, let url = selectedTab?.url else { return }
        webView.pageZoom = zoom
        // A private window's zoom lasts only as long as the page: nothing about the site is saved.
        if !tabManager.isPrivate { ZoomLevels.set(zoom, for: url) }
        Toast.show(ZoomLevels.percent(zoom), symbol: zoom < 1 ? "minus.magnifyingglass" : zoom > 1 ? "plus.magnifyingglass" : "magnifyingglass", in: self)
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

    // MARK: Developer tools (#141)

    /// View › Developer › Turn On Developer Mode for This Site, or Turn Off (⌥⇧⌘D), and the same in the command bar
    /// and Site Controls: the list in Settings › Developer. It takes effect at once (the tools come or go on every
    /// tab of the site) and says what it did, with Undo, by the name on the list: turning it off takes off what
    /// covered the site, which may be its parent domain.
    @objc func toggleDevelopmentSite(_ sender: Any?) {
        guard let tab = selectedTab, DeveloperTool.site.isOffered(for: tab, isPrivate: tabManager.isPrivate) else { return }
        setDeveloperMode(for: tab.url, on: !DevelopmentSites.covers(tab.url))
    }

    /// Developer Mode on or off for the site of a page at `url`, with the toast that says so. Nothing when it's
    /// that way already.
    func setDeveloperMode(for url: URL?, on: Bool) {
        guard DeveloperTools.isOn, DevelopmentSites.isOffered(for: url, isPrivate: tabManager.isPrivate),
              DevelopmentSites.covers(url) != on, let change = DevelopmentSites.toggle(for: url) else { return }
        Toast.show(Self.developerModeToast(change), symbol: DeveloperTool.modeSymbol,
                   action: (String(localized: "Undo", comment: "Button in a toast: undoes what the toast says happened."), { DevelopmentSites.undo(change) }), duration: Toast.undoDuration, in: self)
    }

    /// What the toast after turning Developer Mode on or off says.
    static func developerModeToast(_ change: DevelopmentSites.Change) -> String {
        change.isOn ? String(localized: "Developer Mode on for \(change.site)", comment: "Toast after Developer Mode is turned on for a site. The site is a host, like example.com or localhost.")
            : String(localized: "Developer Mode off for \(change.site)", comment: "Toast after Developer Mode is turned off for a site. The site is a host, like example.com or localhost.")
    }

    @objc func pageAppearanceFollowsMac(_ sender: Any?) { chooseForDevelopment { $0.appearance = .followsMac } }
    @objc func pageAppearanceLight(_ sender: Any?) { chooseForDevelopment { $0.appearance = .light } }
    @objc func pageAppearanceDark(_ sender: Any?) { chooseForDevelopment { $0.appearance = .dark } }
    @objc func togglePrintStyles(_ sender: Any?) { chooseForDevelopment { $0.printStyles.toggle() } }

    @objc func toggleJavaScript(_ sender: Any?) { chooseForDevelopment { $0.javaScriptOff.toggle() } }
    @objc func toggleImages(_ sender: Any?) { chooseForDevelopment { $0.imagesOff.toggle() } }
    @objc func toggleStyles(_ sender: Any?) { chooseForDevelopment { $0.stylesOff.toggle() } }
    @objc func toggleOutlines(_ sender: Any?) { chooseForDevelopment { $0.outlines.toggle() } }
    @objc func userAgentZigzag(_ sender: Any?) { chooseForDevelopment { $0.userAgent = .zigzag } }
    @objc func userAgentPhone(_ sender: Any?) { chooseForDevelopment { $0.userAgent = .iPhone } }
    @objc func userAgentTablet(_ sender: Any?) { chooseForDevelopment { $0.userAgent = .iPad } }
    @objc func userAgentChrome(_ sender: Any?) { chooseForDevelopment { $0.userAgent = .chrome } }
    @objc func userAgentFirefox(_ sender: Any?) { chooseForDevelopment { $0.userAgent = .firefox } }

    /// Whether the page you're on is one of a split's: a page's own size isn't for those.
    private var selectedIsInSplit: Bool { selectedTab.flatMap { tabManager.split(for: $0) } != nil }

    /// View › Developer › Page Size › Toggle Page Size (⌥⇧⌘M): the last size the page had, or a phone's, and back.
    @objc func togglePageSize(_ sender: Any?) {
        guard let tab = selectedTab, !selectedIsInSplit else { return }
        let next = tab.developer.size == nil ? (tab.developerLastSize ?? PageSizes.firstToggled) : nil
        chooseForDevelopment { $0.size = next }
    }

    /// View › Developer › Page Size › one of the sizes listed in Settings › Developer, by its place in the list.
    @objc func pageSizeListed(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        let sizes = PageSizes.all
        guard sizes.indices.contains(item.tag) else { return }
        setPageSize(sizes[item.tag].size)
    }

    @objc func pageSizeFill(_ sender: Any?) { if !selectedIsInSplit { chooseForDevelopment { $0.size = nil } } }
    @objc func rotatePage(_ sender: Any?) { if !selectedIsInSplit { chooseForDevelopment { $0.size = $0.rotatedSize } } }
    @objc func pageSizeCustom(_ sender: Any?) {
        guard let tab = selectedTab, tab.isDevelopment, !selectedIsInSplit else { return }
        // From the size it has, or the room it fills now.
        let current = tab.developer.size ?? tab.webView.map { CGSize(width: floor($0.bounds.width), height: floor($0.bounds.height)) }
        // Still a development tab once you've typed: the choice is for one.
        PageSizeSheet.custom(in: root.overlay, current: current) { [weak tab] size in
            guard let tab, tab.isDevelopment else { return }
            tab.developer.size = size
        }
    }
    /// One of the listed sizes (Settings › Developer), from Page Size’s menu above the page.
    func setPageSize(_ size: CGSize) { if !selectedIsInSplit { chooseForDevelopment { $0.size = size } } }

    /// A choice made with the developer tools for the tab you're on, which is the tab's alone (`DeveloperState`).
    private func chooseForDevelopment(_ change: (inout DeveloperState) -> Void) {
        guard let tab = selectedTab, tab.isDevelopment else { return }
        change(&tab.developer)
    }

    /// View › Developer › Open on Your Phone…: the page's address for a phone on the same network, as a QR code. A
    /// page on this Mac is given at the Mac's network address; with none, a toast says so.
    @objc func openOnPhone(_ sender: Any?) {
        guard let tab = selectedTab, DeveloperTool.phone.isOffered(for: tab, isPrivate: tabManager.isPrivate), let page = tab.url else { return }
        guard let url = PhoneLink.url(for: page, lanAddress: PhoneLink.lanAddress()) else {
            Toast.show(String(localized: "This Mac isn’t on a network a phone can reach", comment: "Toast after Open on Your Phone in the developer tools, when this Mac has no address on a local network."), symbol: "wifi.slash", in: self)
            return
        }
        PhoneLinkSheet.show(in: root.overlay, url: url) { [weak self] in
            guard let self else { return }
            Toast.show(String(localized: "Address copied", comment: "Toast after Copy Address in the Open on Your Phone sheet of the developer tools."), symbol: "doc.on.doc", in: self)
        }
    }

    @objc func showDeveloperSettings(_ sender: Any?) { SettingsPage.open(.developer, in: self) }

    @objc func clearSiteCache(_ sender: Any?) { clearSite(.cache, as: .clearCache) }
    @objc func clearSiteCookies(_ sender: Any?) { clearSite(.cookies, as: .clearCookies) }

    private func clearSite(_ kind: WebsiteData.Kind, as tool: DeveloperTool) {
        guard let tab = selectedTab, tool.isOffered(for: tab, isPrivate: tabManager.isPrivate) else { return }
        confirmClear(kind, of: tab)
    }

    @objc func viewSource(_ sender: Any?) {
        guard let url = selectedTab?.url, url.scheme?.hasPrefix("http") == true else { return }
        selectedWebView?.runOwnScript("document.documentElement.outerHTML") { [weak self] answer in
            let result = try? answer.get()
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

    /// Puts a parted grid's lines back in the middle: the standard even grid, and its plain drags move whole lines
    /// again (#316).
    @objc func resetTileLayout(_ sender: Any?) {
        guard let tab = selectedTab, var shape = tabManager.split(for: tab)?.shape, shape.isParted else { return }
        let before = shape
        shape.evenOut()
        applyTileShape(shape, undoTo: before)
    }

    @objc func toggleReader(_ sender: Any?) { toggleReader() }
    @objc func showReaderOptions(_ sender: Any?) { toggleReaderOptions() }
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

    /// View › Developer: Settings › Developer › Tools above the page, the bar over a page in Developer Mode (#405).
    @objc func toggleDeveloperBar(_ sender: Any?) { DeveloperTools.showsInBar.toggle() }

    static func developerBarTitle(shown: Bool) -> String {
        shown ? String(localized: "Hide Tools Above the Page", comment: "View › Developer menu item: hides the bar of developer tools above a page in Developer Mode.")
              : String(localized: "Show Tools Above the Page", comment: "View › Developer menu item: shows the bar of developer tools above a page in Developer Mode.")
    }

    @objc func closeSplitView(_ sender: Any?) {
        if let tab = selectedTab { unsplitWithUndo(tab) }
    }

    // MARK: History

    @objc func goBack(_ sender: Any?) {
        selectedTab?.goBack()
    }
    @objc func goForward(_ sender: Any?) {
        selectedTab?.goForward()
    }

    // MARK: Saving

    /// Whether ⇧ is held as a pin runs: the three ways in ask where, and only there (#326).
    static var shiftHeld: Bool { NSEvent.modifierFlags.contains(.shift) }

    /// File › Pin Tab (⌘D): the quick pin, into the space you're in at the end of its Pinned pages. ⇧⌘D is its own
    /// item, `savePageToFolder`.
    @objc func toggleBookmark(_ sender: Any?) {
        guard let tab = selectedTab else { return }
        // A menu item's click keeps ⇧ held while it runs: the tab menu's Pin Tab asks where, like ⇧⌘D. Keys given to
        // Pin Tab in Settings may hold ⇧ themselves, so a key press never asks.
        save(tab, request: SavePath.request(for: .savePageCommand, shiftHeld: Self.shiftAsks(event: NSApp.currentEvent?.type, shiftHeld: Self.shiftHeld)))
    }

    /// Whether ⇧ makes Pin Tab ask where: on a click, not on its keys.
    nonisolated static func shiftAsks(event: NSEvent.EventType?, shiftHeld: Bool) -> Bool {
        shiftHeld && event != .keyDown
    }

    /// File › Pin Tab to Folder… (⇧⌘D): asks where in the space the page goes, with a folder or a new one, and its
    /// name. No other space is offered.
    @objc func savePageToFolder(_ sender: Any?) {
        guard let tab = selectedTab else { return }
        save(tab, request: .picker)
    }

    /// The star at the end of the address (#326): a quick pin, or with ⇧ held the picker ⇧⌘D opens.
    func saveFromStar() {
        guard let tab = selectedTab else { return }
        save(tab, request: SavePath.request(for: .star, shiftHeld: Self.shiftHeld))
    }

    /// A quick pin from a tab's menu, or the picker with ⇧ held; also how an unsaved page is pinned from the command
    /// bar's Unpin, so both ends share one path.
    @discardableResult
    func saveFromPageMenu(_ tab: Tab) -> Bool {
        save(tab, request: SavePath.request(for: .pageMenu, shiftHeld: Self.shiftHeld))
    }

    /// A pinned page out of Pinned, back among the tabs, and an unpinned one pinned: what the command bar and a pinned
    /// page's menu run. Pins and favorites are shared, so a private window never writes.
    @discardableResult
    func toggleSavedState(of tab: Tab) -> Bool {
        guard !tabManager.isPrivate else { return false }
        guard let bookmarkID = tab.bookmarkID else { return saveFromPageMenu(tab) }
        if tab.isFavorite {
            unfavoriteWithUndo(bookmarkID, to: 0)
            Toast.show(String(localized: "Moved to Tabs", comment: "Toast after a favorite moves back to the tabs."), symbol: "star.slash", in: self)
        } else {
            unbookmarkWithUndo(bookmarkID, to: 0)
            Toast.show(String(localized: "Unpinned", comment: "Toast after a pinned page is taken out of Pinned, back among the tabs."), symbol: "star.slash", in: self)
        }
        refreshSavedState(of: tab)
        return true
    }

    /// The star shows the selected tab's saved state. Saving reloads the list and the favorites, not the address row,
    /// so the row is told directly here (#326).
    private func refreshSavedState(of tab: Tab) {
        guard tab === tabManager.selectedTab else { return }
        refreshAddress(for: tab)
    }

    /// Every save ends here (#326), so no two ways in can drift: `request` says whether it was the quick save or the
    /// picker, and both land in `SavePath.save` as one ⌘Z.
    @discardableResult
    func save(_ tab: Tab, request: SavePath.Request, at index: Int? = nil, then done: (() -> Void)? = nil) -> Bool {
        guard !tabManager.isPrivate else { return false }
        // A saved page's quick save is its unsave, as the star and ⌘D have always toggled, whatever it shows now.
        if request != .picker, tab.bookmarkID != nil { return toggleSavedState(of: tab) }
        guard let page = SavePath.Page(tab: tab) else { return false }
        guard request == .picker else {
            // A tab in a group saves as the group, as it has since #325: one folder, one undo.
            if tab.bookmarkID == nil, tabManager.pinsGroup(tab) {
                bookmarkWithUndo(tab, at: index, in: tab.spaceID)
                showPinnedToast(for: tab)
                refreshSavedState(of: tab)
                done?()
                return true
            }
            // No sheet, no question: the end of this space's Pinned pages.
            guard save(page, to: SavePath.quickPlace(in: tab.spaceID)) else { return false }
            showPinnedToast(for: tab)
            refreshSavedState(of: tab)
            done?()
            return true
        }
        SavePlaceSheet.show(page: page, kind: SavePath.kind(of: tab, in: tabManager), spaceID: tab.spaceID, in: root.overlay) { [weak self] answer in
            guard let self, self.save(page, to: answer.place, named: answer.name) else { return }
            self.showPinnedToast(for: tab)
            self.refreshSavedState(of: tab)
            done?()
        }
        return true
    }

    /// What the toast after a pin acts on: the pin it announced and the space it was made in, both taken when it was
    /// made, so its menu moves that pin in that space whatever space or tab you're on by the time you use it.
    struct PinnedItem: Equatable {
        /// A page of the pin: the page itself, a page of its split view, or a page in its group's folder.
        let bookmarkID: UUID
        let spaceID: UUID
    }

    /// The pin `tab` just became, as the toast keeps it.
    func pinnedItem(of tab: Tab) -> PinnedItem? {
        guard let id = tab.bookmarkID else { return nil }
        return PinnedItem(bookmarkID: id, spaceID: Library.shared.spaceID(ofBookmark: id) ?? tab.spaceID)
    }

    /// The Pinned toast, with a menu of the places that pin can move to.
    private func showPinnedToast(for tab: Tab) {
        let item = pinnedItem(of: tab)
        Toast.show(String(localized: "Pinned", comment: "Toast after a page is pinned."), symbol: "star.fill",
                   actionMenu: { [weak self, weak tab] in item.flatMap { self?.savedPlacesMenu(for: $0, tab: tab) } },
                   duration: Toast.undoDuration, in: self)
    }

    /// The places the pin just made can move to, from the toast that says it was made (#326): every folder of its
    /// space, the top of that space's Pinned pages and Add to Favorites, with the one it is in ticked. A tab group
    /// moves as its folder, into another folder or to the top, and isn't a favorite.
    func savedPlacesMenu(for item: PinnedItem, tab: Tab?) -> NSMenu? {
        let id = item.bookmarkID, spaceID = item.spaceID
        guard !tabManager.isPrivate, Library.shared.bookmark(id) != nil, Library.shared.space(spaceID) != nil else { return nil }
        let kind = SavePath.kind(ofPinned: id)
        let folders = SavePath.folders(in: spaceID, for: kind)
        let menu = NSMenu()
        for entry in SavePath.placeEntries(of: id, in: spaceID) {
            let line: NSMenuItem
            switch entry.kind {
            case .everySpace:
                line = SidebarMenus.Item(String(localized: "Add to Favorites", comment: "Menu item on a pinned page: it shows in every space of the profile.")) { [weak self] in
                    self?.moveSaved(item, to: .everySpace)
                }
            case .top:
                line = SidebarMenus.Item(String(localized: "Top of Pinned", comment: "Menu item on a saved page: it sits at the top of the space's Pinned pages.")) { [weak self] in
                    self?.moveSaved(item, to: .top)
                }
            case .folder(let folder):
                line = SidebarMenus.Item(folders.first { $0.id == folder }?.name ?? "") { [weak self] in
                    self?.moveSaved(item, to: .folder(folder))
                }
            }
            line.state = entry.isOn ? .on : .off
            menu.addItem(line)
        }
        menu.addItem(.separator())
        menu.addItem(SidebarMenus.Item(String(localized: "New Folder…", comment: "Menu item beside a pinned page: pins it into a folder named as typed.")) { [weak self] in
            self?.askNewFolder(for: item)
        })
        if let tab, tab.bookmarkID == id {
            menu.addItem(SidebarMenus.Item(String(localized: "Unpin Tab", comment: "Menu item on the toast after pinning: takes the page out of Pinned, back among the tabs.")) { [weak self] in
                self?.toggleSavedState(of: tab)
            })
        }
        return menu
    }

    /// New Folder… in the toast: one field for the name, then the pin goes into it, in its own space, as one ⌘Z. The
    /// picker's own new-folder row is for a page being pinned; this is for one already pinned.
    private func askNewFolder(for item: PinnedItem) {
        let field = FilledField(placeholder: String(localized: "Name", comment: "Placeholder of the name field in the sheet that names a new folder for a pinned page."))
        FormSheet.show(in: root.overlay,
                       title: String(localized: "New Folder", comment: "Title of the sheet that names a new folder for a pinned page, from its toast."),
                       symbol: "folder.badge.plus",
                       rows: [.init(label: nil, view: field)],
                       confirmTitle: SavePath.saveName,
                       canConfirm: { !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { [weak self] confirmed in
            guard confirmed, let self else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            self.moveSaved(item, to: .newFolder(name))
        }
    }

    enum SavedPlace: Equatable { case everySpace, top, folder(UUID), newFolder(String) }

    /// Where the toast's chevron says the pin should be, through the same moves the picker and the sidebar use, in
    /// the pin's own space, each one ⌘Z.
    func moveSaved(_ item: PinnedItem, to place: SavedPlace) {
        guard !tabManager.isPrivate, Library.shared.bookmark(item.bookmarkID) != nil else { return }
        let id = item.bookmarkID, spaceID = item.spaceID
        let name: String
        if case .group = SavePath.kind(ofPinned: id) {
            name = String(localized: "Move Group", comment: "Undo action name, shown in the Edit menu as Undo Move Group.")
        } else if place == .everySpace {
            name = String(localized: "Add to Favorites", comment: "Undo action name, shown in the Edit menu as Undo Add to Favorites.")
        } else {
            name = String(localized: "Move Pinned Tab", comment: "Undo action name, shown in the Edit menu as Undo Move Pinned Tab.")
        }
        let profile = Library.shared.profileID(ofSpace: spaceID)
        pageChange(name) {
            switch place {
            case .everySpace:
                if Library.shared.isFavorite(id) {
                    _ = SavePath.keepInThisSpace(id, spaceID: spaceID)
                } else {
                    _ = SavePath.keepInEverySpace(id, profile: profile)
                }
            case .top:
                _ = SavePath.moveToTop(id, in: spaceID)
            case .folder(let folder):
                _ = SavePath.move(id, to: SavePath.place(in: spaceID, folder: folder))
            case .newFolder(let typed):
                _ = SavePath.move(id, to: SavePath.place(in: spaceID, folder: nil, newFolder: typed))
            }
        }
        if let shown = tabManager.selectedTab { refreshSavedState(of: shown) }
    }

    /// Saves a page to a place as one ⌘Z, and remembers where in the space it was filed, for the picker to open on.
    @discardableResult
    func save(_ page: SavePath.Page, to place: SavePath.Place, named name: String? = nil) -> Bool {
        guard !tabManager.isPrivate else { return false }
        var saved = false
        pageChange(SavePath.saveName) { [tabManager] in
            saved = SavePath.save(page, to: place, in: tabManager, name: name) != nil
        }
        guard saved else { return false }
        Tutorial.complete("pin")
        SavePath.remember(place)
        return true
    }

    /// Pin Link in a link's right-click menu (#326): the link is pinned without being opened, at the end of Pinned,
    /// or with ⇧ held where the picker says.
    @discardableResult
    func saveLinkToPins(_ url: URL, title: String = "", shiftHeld: Bool = false) -> Bool {
        guard !tabManager.isPrivate else { return false }
        let page = SavePath.Page(url: url, title: title)
        let space = tabManager.currentSpaceID
        guard SavePath.request(for: .linkMenu, shiftHeld: shiftHeld) == .picker else {
            guard save(page, to: SavePath.quickPlace(in: space)) else { return false }
            Toast.show(String(localized: "Pinned", comment: "Toast after a link is pinned from its right-click menu, without opening it."), symbol: "star.fill", in: self)
            return true
        }
        SavePlaceSheet.show(page: page, spaceID: space, in: root.overlay) { [weak self] answer in
            guard let self, self.save(page, to: answer.place, named: answer.name) else { return }
            Toast.show(String(localized: "Pinned", comment: "Toast after a link is pinned from its right-click menu, without opening it."), symbol: "star.fill", in: self)
        }
        return true
    }

    @objc func addToFavorites(_ sender: Any?) {
        // Favorites are shared by every window: a private one adds none, pinned or not.
        guard let tab = selectedTab, tab.url != nil, !tab.isFavorite, !tabManager.isPrivate, tabManager.canPin(tab, keepingGroup: false) else { return }
        favoriteWithUndo(tab)
        Toast.show(String(localized: "Added to Favorites", comment: "Toast after the tab is added to Favorites."), symbol: "heart.fill", in: self)
    }

    /// File › Install as App…: the site as an app of its own, with its own Dock icon (#165).
    @objc func installAsApp(_ sender: Any?) {
        guard let tab = selectedTab else { return }
        WebAppInstallSheet.show(for: tab, in: self)
    }
    @objc func moveTabToNewWindow(_ sender: Any?) {
        guard let tab = selectedTab else { return }
        moveToNewWindow(tab)
    }

    // MARK: Tabs

    /// ⌃⇧↑ and ⌃⇧↓: the tab you're on one row up or down, for reordering without a mouse. A split moves only by drag.
    @objc func moveTabUp(_ sender: Any?) { if let target = tabMoveTarget(by: -1), let tab = selectedTab { moveWithUndo(tab, to: target, in: tab.spaceID) } }
    @objc func moveTabDown(_ sender: Any?) { if let target = tabMoveTarget(by: 1), let tab = selectedTab { moveWithUndo(tab, to: target, in: tab.spaceID) } }

    /// ⌃⇧→ and ⌃⇧←: the tab you're on a level in, under the tab above it, or a level out (#523).
    @objc func nestTab(_ sender: Any?) { nestSelectedTab(deeper: true) }
    @objc func unnestTab(_ sender: Any?) { nestSelectedTab(deeper: false) }

    private func nestSelectedTab(deeper: Bool) {
        guard let tab = selectedTab, tabManager.nestedArrangement(of: tab, deeper: deeper) != nil else { return }
        pageChange(String(localized: "Move Tab", comment: "Undo action name, shown in the Edit menu as Undo Move Tab.")) { [weak self] in
            self?.tabManager.nest(tab, deeper: deeper)
        }
    }

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

    @objc func selectNextTab(_ sender: Any?) { selectAdjacentRow(by: 1) }

    /// A Vim key (`VimKeys`). With the command bar open, ⌃J and ⌃K step its list, and ⌃H and ⌃L stay its field's.
    func handleVimKey(_ move: VimKeys.Move) -> Bool {
        if commandBar.isVisible {
            switch move {
            case .nextTab: commandBar.step(1)
            case .previousTab: commandBar.step(-1)
            case .previousSpace, .nextSpace: return false
            }
            return true
        }
        switch move {
        case .nextTab: selectNextTab(nil)
        case .previousTab: selectPreviousTab(nil)
        case .previousSpace: previousSpace(nil)
        case .nextSpace: nextSpace(nil)
        }
        return true
    }
    @objc func selectPreviousTab(_ sender: Any?) { selectAdjacentRow(by: -1) }

    /// The stops ⌥⌘↑/↓ and ⇧⌘[/] walk, top to bottom: open favorites, then the sidebar's rows as shown.
    var tabRowStops: [SidebarItem] {
        let favorites = Library.shared.favoriteTiles(in: tabManager.profile.id).filter { tile in
            ([tile.0] + tile.partners).contains { tabManager.bookmarkTab(for: $0.id) != nil }
        }
        return favorites.map { SidebarItem.bookmark($0.0.id) } + sidebar.pinnedTiles.tileIDs.map(SidebarItem.bookmark) + sidebar.list.pageRows
    }

    /// The pages a stop stands for: a split's are all of them.
    func pages(of stop: SidebarItem) -> [Tab] {
        switch stop {
        case .tab(let id): return tabManager.tab(with: id).map(tabManager.panes(of:)) ?? []
        case .bookmark(let id):
            let ids = Library.shared.pinnedSplit(containing: id)?.ids ?? Library.shared.favoriteSplits.first(where: { $0.ids.contains(id) })?.ids ?? [id]
            let open = ids.compactMap(tabManager.bookmarkTab(for:))
            return open.flatMap(tabManager.panes(of:)).reduce(into: []) { list, tab in if !list.contains(where: { $0 === tab }) { list.append(tab) } }
        default: return []
        }
    }

    /// Next or previous row in this space's sidebar, as shown, wrapping at the ends as Chrome does. A split is one
    /// stop; going to it shows the page of it you were on last.
    func selectAdjacentRow(by offset: Int) {
        let stops = tabRowStops
        guard !stops.isEmpty else { return }
        let current = tabManager.selectedTab
        let index = current.flatMap { tab in stops.firstIndex { pages(of: $0).contains { $0 === tab } } }
        let target = index.map { (($0 + offset) % stops.count + stops.count) % stops.count } ?? (offset > 0 ? 0 : stops.count - 1)
        let stop = stops[target]
        let recent = tabManager.recentTabIDs
        if let page = pages(of: stop).min(by: { (recent.firstIndex(of: $0.id) ?? .max) < (recent.firstIndex(of: $1.id) ?? .max) }) {
            tabManager.select(page)
        } else if case .bookmark(let id) = stop, let bookmark = Library.shared.bookmark(id) {
            tabManager.openBookmark(bookmark)
        }
    }
    /// ⌘1–⌘9: numbered as the sidebar shows them, each favorite tile, then each pinned and tab row, open or not.
    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        // In the tab overview, the number picks the card in that place, as you see them.
        if desk.isVisible { desk.openCard(number: sender.tag); return }
        let rows = Library.shared.favoriteTiles(in: tabManager.profile.id).map { SidebarItem.bookmark($0.0.id) }
            + sidebar.pinnedTiles.tileIDs.map(SidebarItem.bookmark) + sidebar.list.pageRows
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
    @objc func suspendPage(_ sender: Any?) {
        guard let tab = selectedTab else { return }
        suspendWithToast([tab])
    }

    /// Suspend Page: each tab that can sleep does; a toast says what kept one awake (#342). No undo: the tab stays in
    /// the list and loads again on a click.
    func suspendWithToast(_ tabs: [Tab]) {
        var kept = 0
        tabManager.suspend(chosen: tabs) { [weak self] _, why in
            guard let self else { return }
            kept += 1
            let text = kept == 1 ? why.note
                : String(localized: "\(kept) pages not put to sleep while they play or have text you typed", comment: "Toast after Suspend N Pages in the sidebar's menu: some of the picked pages stay awake, because they play sound, are in a call, play in the mini player or Picture in Picture, or hold text you typed.")
            Toast.show(text, symbol: "moon.zzz", duration: 3, in: self)
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
        let spaces = tabManager.listedSpaces
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
        let own = Library.newSpacesGetOwnProfile
        libraryChange(String(localized: "New Space", comment: "Undo action name, shown in the Edit menu as Undo New Space.")) {
            created = Library.shared.addSpace(profile: tabManager.profile.id, ownProfile: own)
        }
        guard let space = created else { return }
        // Its own profile when Settings › Spaces gives new spaces one (#291).
        let madeProfile = own ? Library.shared.profileID(ofSpace: space.id) : nil
        let previous = tabManager.currentSpaceID
        // Into the new space first: that move isn't the guide's "go back" step, which only starts once this one counts.
        tabManager.switchToSpace(space.id)
        Tutorial.complete("space")
        // At the button or menu row it came from; from the menu bar or command bar, beside the space's name.
        openSpaceEditor(tabManager.currentSpaceID, anchor: sender as? NSView)
        if let madeProfile { SpaceEditorPanel.current?.follow(madeProfile: madeProfile) }
        // Esc while naming it: never mind. Back where you were, without the space, and the guide still asks for one.
        SpaceEditorPanel.current?.onCancel = { [weak self] in
            guard let self, Library.shared.space(space.id) != nil else { return }
            Tutorial.undo("space")
            if Library.shared.space(previous) != nil { tabManager.switchToSpace(previous) }
            // Nothing was in it yet, so there's nothing for ⌘Z to bring back.
            Library.shared.removeSpace(space.id)
            // Remove the profile made for it too, unless another space uses it.
            if let madeProfile, madeProfile != Profile.defaultID, Library.shared.spaces(in: madeProfile).isEmpty {
                Task { await Profiles.shared.remove(madeProfile) }
            }
        }
    }
    @objc func renameSpace(_ sender: Any?) {
        openSpaceEditor(tabManager.currentSpaceID)
    }
    @objc func collapseAllFolders(_ sender: Any?) { setAllFoldersOpen(in: tabManager.currentSpaceID, false) }
    @objc func expandAllFolders(_ sender: Any?) { setAllFoldersOpen(in: tabManager.currentSpaceID, true) }

    // MARK: Validation

    /// Pin Tab and Pin Tab to Folder…: by the rule the tab's menu and the command bar use, so Zigzag's own views
    /// (Settings, History) don't offer a pin that does nothing.
    func canPinFromMenu(_ tab: Tab?) -> Bool {
        guard let tab, tab.url != nil, !tabManager.isPrivate else { return false }
        return tabManager.canPin(tab)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let tab = selectedTab
        // ⌘← and ⌘→ (the hidden Back and Forward) in a text field or a page: BrowserWindow decides whether they move
        // the cursor, and the menu mustn't take them first.
        if item.isHidden, item.action == #selector(goBack(_:)) || item.action == #selector(goForward(_:)),
           window?.firstResponder is NSText || window?.firstResponder is WKWebView {
            return false
        }
        switch item.action {
        case #selector(selectAll(_:)): return (window as? BrowserWindow)?.sidebarHasTheClick == true
        case #selector(openDocument(_:)):
            // Zigzag Mini names it Open in Zigzag while it's in front; here it's itself again.
            item.title = Self.openFileTitle
            return true
        case #selector(goBack(_:)): return tab?.canGoBackOrReturn ?? false
        case #selector(goForward(_:)): return tab?.canGoForward ?? false
        case #selector(takePageScreenshot(_:)): return capture.isActive || capture.canBegin
        case #selector(reloadPage(_:)), #selector(reloadPageFromOrigin(_:)), #selector(copyPageURL(_:)), #selector(copyPageURLAsMarkdown(_:)),
             #selector(printPage(_:)), #selector(exportAsPDF(_:)), #selector(showFindBar(_:)), #selector(zoomIn(_:)), #selector(zoomOut(_:)),
             #selector(actualSize(_:)), #selector(showWebInspector(_:)), #selector(showJavaScriptConsole(_:)), #selector(inspectElement(_:)),
             #selector(viewSource(_:)), #selector(duplicateTab(_:)),
             #selector(useSelectionForFind(_:)), #selector(jumpToSelection(_:)):
            return tab != nil
        case #selector(findNextMatch(_:)), #selector(findPreviousMatch(_:)):
            return tab != nil && findBar.hasQuery
        case #selector(stopLoading(_:)): return tab?.isLoading ?? false
        case #selector(suspendPage(_:)): return tab.map(tabManager.maySuspend) ?? false
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
        case #selector(reopenClosedTab(_:)): return WindowManager.shared.canReopenLastClosed(from: tabManager)
        case #selector(toggleBrowserSidebar(_:)):
            let shown = root.chromeSidebarShown || (root.isImmersive && root.isSidebarFloatingVisible)
            item.title = shown ? String(localized: "Hide Sidebar", comment: "Menu bar item: hides the sidebar.")
                               : String(localized: "Show Sidebar", comment: "Menu bar item: shows the sidebar.")
            return true
        case #selector(toggleDeveloperBar(_:)):
            item.title = Self.developerBarTitle(shown: DeveloperTools.showsInBar)
            return DeveloperTools.isOn
        case #selector(toggleSidebarSide(_:)):
            item.title = BrowserRootView.sidebarOnRight
                ? String(localized: "Move Sidebar to Left", comment: "View menu item: puts the sidebar back along the window's left edge.")
                : String(localized: "Move Sidebar to Right", comment: "View menu item: puts the sidebar along the window's right edge.")
            return true
        case #selector(toggleBookmark(_:)):
            // Same names as the sidebar menus.
            let pinsPair = tab.map(tabManager.pinsSplit) ?? false
            item.title = tab?.isFavorite == true ? String(localized: "Move to Tabs", comment: "Menu bar item: moves the favorite back to the tabs.")
                : tab?.bookmarkID.flatMap(Library.shared.pinnedGroup(containing:)) != nil ? String(localized: "Unpin Group", comment: "Menu bar item: unpins the whole pinned group the tab is in.")
                : tab?.bookmarkID.flatMap(Library.shared.pinnedSplit(containing:)) != nil ? String(localized: "Unpin Split View", comment: "Item in a pinned tab's context menu in the sidebar: takes both pages of a pinned split view out of Pinned.")
                : tab?.bookmarkID != nil ? String(localized: "Unpin Tab", comment: "Menu bar item: unpins the tab.")
                : tab.map(tabManager.pinsGroup) == true ? String(localized: "Pin Group", comment: "Menu bar item: pins the whole group of tabs the tab is in, as a folder.")
                : pinsPair ? String(localized: "Pin Split View", comment: "Menu bar item: pins both pages of the split view.")
                : String(localized: "Pin Tab", comment: "Menu bar item: pins the tab.")
            return canPinFromMenu(tab)
        case #selector(savePageToFolder(_:)):
            // ⇧⌘D: the same save, asking where in the space it goes. One word for the verb, everywhere.
            item.title = String(localized: "Pin Tab to Folder…", comment: "File menu item, with ⇧⌘D: pins the page you're on, asking which folder of the space it goes in and what it's called.")
            return canPinFromMenu(tab)
        case #selector(addToFavorites(_:)):
            return tab?.url != nil && tab.map { tabManager.canPin($0, keepingGroup: false) } == true && tab?.isFavorite != true && !tabManager.isPrivate
        case #selector(toggleDevelopmentSite(_:)):
            item.title = DeveloperTool.siteTitle(listed: DevelopmentSites.covers(tab?.url))
            return DeveloperTool.site.isOffered(for: tab, isPrivate: tabManager.isPrivate)
        case #selector(pageAppearanceFollowsMac(_:)), #selector(pageAppearanceLight(_:)), #selector(pageAppearanceDark(_:)), #selector(togglePrintStyles(_:)),
             #selector(pageSizeFill(_:)), #selector(pageSizeCustom(_:)), #selector(rotatePage(_:)), #selector(togglePageSize(_:)),
             #selector(toggleJavaScript(_:)), #selector(toggleImages(_:)), #selector(toggleStyles(_:)), #selector(toggleOutlines(_:)),
             #selector(userAgentZigzag(_:)), #selector(userAgentPhone(_:)),
             #selector(userAgentTablet(_:)), #selector(userAgentChrome(_:)), #selector(userAgentFirefox(_:)):
            guard let tool = DeveloperTool(action: item.action) else { return false }
            let state = tab?.developerInEffect ?? DeveloperState()
            item.state = tab != nil && tab?.isDevelopment == true && tool.isChecked(in: state) ? .on : .off
            return tool.isOffered(for: tab, isPrivate: tabManager.isPrivate, inSplit: selectedIsInSplit) && tool.applies(in: state)
        case #selector(pageSizeListed(_:)):
            let sizes = PageSizes.all
            let state = tab?.developerInEffect ?? DeveloperState()
            item.state = sizes.indices.contains(item.tag) && PageSizes.named(state.size) == sizes[item.tag] ? .on : .off
            return DeveloperTool.sizeFill.isOffered(for: tab, isPrivate: tabManager.isPrivate, inSplit: selectedIsInSplit)
        case #selector(openOnPhone(_:)): return DeveloperTool.phone.isOffered(for: tab, isPrivate: tabManager.isPrivate)
        case #selector(clearSiteCache(_:)): return DeveloperTool.clearCache.isOffered(for: tab, isPrivate: tabManager.isPrivate)
        case #selector(clearSiteCookies(_:)): return DeveloperTool.clearCookies.isOffered(for: tab, isPrivate: tabManager.isPrivate)
        case #selector(installAsApp(_:)): return WebAppInstallSheet.canInstall(tab, isPrivate: tabManager.isPrivate)
        case #selector(moveTabToNewWindow(_:)): return tab != nil && tab?.bookmarkID == nil && !tabManager.isPrivate
        case #selector(newSpace(_:)), #selector(renameSpace(_:)): return !tabManager.isPrivate
        case #selector(collapseAllFolders(_:)): return !tabManager.isPrivate && Self.hasFolders(in: tabManager.currentSpaceID, isOpen: true)
        case #selector(expandAllFolders(_:)): return !tabManager.isPrivate && Self.hasFolders(in: tabManager.currentSpaceID, isOpen: false)
        case #selector(sharePage(_:)), #selector(savePageAs(_:)), #selector(togglePictureInPicture(_:)): return tab?.url != nil
        case #selector(showReaderOptions(_:)): return isReaderOnHere
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
        case #selector(nestTab(_:)): return selectedTab.flatMap { tabManager.nestedArrangement(of: $0, deeper: true) } != nil
        case #selector(unnestTab(_:)): return selectedTab.flatMap { tabManager.nestedArrangement(of: $0, deeper: false) } != nil
        case #selector(closeOtherTabs(_:)): return !otherTabs.isEmpty
        case #selector(closeTabsBelow(_:)): return !tabsBelow.isEmpty
        case #selector(selectSpaceByNumber(_:)):
            return SpaceNumbers.index(for: item.tag, count: tabManager.listedSpaces.count) != nil
        case #selector(nextSpace(_:)), #selector(previousSpace(_:)): return tabManager.listedSpaces.count > 1
        case #selector(showSpaceSwitcher(_:)): return tabManager.listedSpaces.count > 1 && !tabManager.isPrivate
        default: return true
        }
    }
}

/// Per-site zoom, remembered.
enum ZoomLevels {
    private static let key = "ZoomLevels"

    /// The zooms ⌘+ and ⌘− go through, and Site Controls' stepper.
    static let steps: [CGFloat] = [0.5, 0.67, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    /// The next step in (`by` 1) or out (-1) from `zoom`, which needn't be a step itself (a pinch, an old level); at
    /// either end it stays there. `levels` holds the steps of what's stepped: a page's zoom, or the sidebar's size.
    static func step(_ zoom: CGFloat, by direction: Int, in levels: [CGFloat] = steps) -> CGFloat {
        direction > 0 ? levels.first { $0 > zoom + 0.001 } ?? levels.last! : levels.last { $0 < zoom - 0.001 } ?? levels.first!
    }

    /// Whether there's a step further that way.
    static func canStep(_ zoom: CGFloat, by direction: Int, in levels: [CGFloat] = steps) -> Bool {
        direction > 0 ? zoom < levels.last! - 0.001 : zoom > levels.first! + 0.001
    }

    /// A zoom as people read it: "125%".
    static func percent(_ zoom: CGFloat) -> String { "\(Int((zoom * 100).rounded()))%" }

    /// A typed zoom as a value: "130%", "130" or " 130 % ". Nil when it isn't a number above zero; the caller
    /// keeps it within its own levels.
    static func typed(_ text: String) -> CGFloat? {
        let plain = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: "％", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let percent = Double(plain), percent.isFinite, percent > 0 else { return nil }
        return CGFloat(percent / 100)
    }

    /// Zoom for sites without their own: Settings › Appearance › Page zoom (100% by default). Actual Size resets to it,
    /// as in Chrome and Safari.
    static var defaultZoom: CGFloat {
        get {
            let zoom = UserDefaults.standard.double(forKey: defaultKey)
            return steps.contains { abs($0 - zoom) < 0.001 } ? CGFloat(zoom) : 1
        }
        set {
            let old = defaultZoom
            if abs(newValue - 1) < 0.001 { UserDefaults.standard.removeObject(forKey: defaultKey) } else { UserDefaults.standard.set(Double(newValue), forKey: defaultKey) }
            defaultZoomChanged(from: old)
        }
    }

    /// The default zoom as `value` holds it (a synced preference before it changed).
    static func defaultZoom(_ value: SettingValue?) -> CGFloat {
        let zoom: Double = switch value {
        case .double(let v)?: v
        case .int(let v)?: Double(v)
        default: 1
        }
        return steps.contains { abs($0 - zoom) < 0.001 } ? CGFloat(zoom) : 1
    }

    /// Open pages at the old default switch now to the new one. Manually zoomed pages keep their zoom.
    static func defaultZoomChanged(from old: CGFloat) {
        let new = defaultZoom
        guard abs(new - old) >= 0.001 else { return }
        for tab in WindowManager.shared.everyOpenTab {
            guard let webView = tab.webView, let url = tab.url, !hasOwnZoom(url),
                  abs(webView.pageZoom - old) < 0.001 else { continue }
            webView.pageZoom = new
        }
    }
    private static let defaultKey = "DefaultZoom"

    static func zoom(for url: URL) -> CGFloat {
        CGFloat(all[HistoryStore.normalizedHost(url)] ?? Double(defaultZoom))
    }

    /// Whether the site has its own zoom.
    static func hasOwnZoom(_ url: URL) -> Bool { all[HistoryStore.normalizedHost(url)] != nil }

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
        // The default isn't stored; anything else (100% too, if not default) is the site's.
        if abs(zoom - defaultZoom) < 0.001 { levels[host] = nil } else { levels[host] = Double(zoom) }
        UserDefaults.standard.set(levels, forKey: key)
    }
}

extension BrowserWindowController: SideButtonHistory {
    func sideButtonHistory(back: Bool) -> NSMenu? { Self.historyMenu(of: selectedWebView, back: back) }
}

/// Calls on WebKit's private inspector object, each checked first, so a name WebKit drops does nothing rather than crash.
extension NSObject {
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
