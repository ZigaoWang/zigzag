import AppKit
import WebKit

enum WebKitSetup {
    /// Sites like Google refuse sign-in from "embedded" web views. A Safari version token
    /// (matching the installed Safari, since we run the same engine) makes us a real browser to them.
    static let applicationNameForUserAgent: String = {
        let fallback = "26.0"
        let plist = URL(fileURLWithPath: "/Applications/Safari.app/Contents/Info.plist")
        var version = fallback
        if let info = NSDictionary(contentsOf: plist), let full = info["CFBundleShortVersionString"] as? String {
            let parts = full.split(separator: ".")
            version = parts.count >= 2 ? "\(parts[0]).\(parts[1])" : (parts.first.map { "\($0).0" } ?? fallback)
        }
        return "Version/\(version) Safari/605.1.15"
    }()

    /// The whole user agent a page here sends, for a request made outside a web view.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) \(applicationNameForUserAgent)"

    /// WebKit otherwise copies a user script's source into every page process once per granted match pattern; Safari
    /// opts into sharing one copy, and so does Zigzag (#485). On macOS 27.2 the call changes nothing else.
    static func shareUserScriptSources() {
        // Sharing is new in macOS 27's WebKit; on older ones the call would only change other behaviors.
        guard #available(macOS 27, *), let pool = NSClassFromString("WKProcessPool") as AnyObject? else { return }
        let share = NSSelectorFromString("_setLinkedOnOrAfterEverything")
        if pool.responds(to: share) { _ = pool.perform(share) }
    }

    /// What a page in this profile is made with: the profile's website data and its extensions.
    static func makeConfiguration(for profile: Profile) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configure(configuration, for: profile)
        return configuration
    }

    /// A configuration WebKit hands over for an opened page (tab or pop-up) shares the opener's preferences object,
    /// so per-page changes (WebRTC switch, Disable Styles) would leak across sites. Gives each web view its own copy,
    /// identical otherwise, with developer-tools changes reset to WebKit's defaults; the page then applies its own
    /// settings. Feature flags apply as to any open page (`FeatureFlags`).
    static func separatePreferences(of configuration: WKWebViewConfiguration) {
        guard let own = configuration.preferences.copy() as? WKPreferences else { return }
        PageStyles.set(true, in: own)
        // A new page starts at the chosen frame rate, even when its opener was held near 60 fps.
        FeatureFlags.applyOwn(to: own)
        configuration.preferences = own
    }

    /// This page's media with sound waits for a click or key in it; muted media still plays. WebKit's per-page policy
    /// (`_WKWebsiteAutoplayPolicyAllowWithoutSound`), what Safari's Stop Media with Sound sets.
    static func autoplayWithoutSound(_ preferences: WKWebpagePreferences) {
        guard preferences.responds(to: NSSelectorFromString("_setAutoplayPolicy:")) else { return }
        preferences.setValue(2, forKey: "autoplayPolicy")
    }

    /// Sets a private WebKit preference by KVC key (`_set<Key>:`) if it exists and differs (reading only where the
    /// getter exists too).
    static func setIfAvailable(_ on: Bool, key: String, in preferences: WKPreferences) {
        guard hasPreference(key) else { return }
        if preferences.responds(to: NSSelectorFromString("_" + key)), preferences.value(forKey: key) as? Bool == on { return }
        preferences.setValue(on, forKey: key)
    }

    /// Whether this WebKit has a private preference with this KVC key.
    static func hasPreference(_ key: String) -> Bool {
        WKPreferences.instancesRespond(to: NSSelectorFromString("_set" + key.prefix(1).uppercased() + key.dropFirst() + ":"))
    }

    /// WKWebView still goes Back on ⌫ (Forward on ⇧⌫) with no field focused; Safari and Chrome dropped that years
    /// ago.
    static func turnOffBackspaceNavigation(_ preferences: WKPreferences) {
        setIfAvailable(false, key: "backspaceKeyNavigationEnabled", in: preferences)
    }

    /// Applies our defaults. Popup configurations handed to us by WebKit already carry most of these.
    static func configure(_ configuration: WKWebViewConfiguration, for profile: Profile) {
        configuration.websiteDataStore = profile.store
        configuration.applicationNameForUserAgent = applicationNameForUserAgent
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true
        // PopupNotice decides which pop-ups open.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        #if DEBUG
        // Testing on video sites: nothing plays until clicked, so nothing makes a sound.
        if UserDefaults.standard.bool(forKey: "DebugNoAutoplay") { configuration.mediaTypesRequiringUserActionForPlayback = .all }
        #endif
        // WKWebView disables page-initiated Picture in Picture by default (Safari enables it), so sites like Bilibili
        // say they "don't support it" and View › Picture in Picture finds nothing. Pages still need a click.
        setIfAvailable(true, key: "allowsPictureInPictureMediaPlayback", in: configuration.preferences)
        turnOffBackspaceNavigation(configuration.preferences)
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.upgradeKnownHostsToHTTPS = true
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        // The WebKit feature flags changed in Settings › Developer (#173), after Zigzag's own preferences above.
        FeatureFlags.apply(to: configuration.preferences)
        if profile.isHeadless { Headless.prepare(configuration) }
        if #available(macOS 15.4, *), configuration.webExtensionController == nil {
            configuration.webExtensionController = profile.extensions.controller
        }
        if configuration.userContentController.userScripts.isEmpty {
            for script in PageScripts.all + Reader.scripts { configuration.userContentController.addUserScript(script) }
            // Runs in its own world, invisible to the page.
            configuration.userContentController.add(PageMessages.shared, contentWorld: .defaultClient, name: "zigzagHover")
            configuration.userContentController.add(ScrollMessages.shared, contentWorld: .defaultClient, name: ScrollMessages.messageName)
            configuration.userContentController.add(PageMessages.shared, contentWorld: .defaultClient, name: "zigzagLinkClick")
            configuration.userContentController.add(PageMessages.shared, contentWorld: .defaultClient, name: "zigzagIcons")
            configuration.userContentController.addUserScript(PasswordCapture.script)
            configuration.userContentController.add(PasswordCapture.shared, contentWorld: .defaultClient, name: PasswordCapture.messageName)
            configuration.userContentController.addUserScript(Autofill.script)
            configuration.userContentController.add(Autofill.shared, contentWorld: .defaultClient, name: Autofill.messageName)
            // Safari's key icon in sign-in fields, where WebKit lets an app draw it.
            if #available(macOS 27, *) { AutofillKeyIcon.install(in: configuration.userContentController) }
            configuration.userContentController.addUserScript(PageFrames.script)
            configuration.userContentController.add(PageFrames.shared, contentWorld: .defaultClient, name: PageFrames.messageName)
            // One passkey request at a time, where passkeys are the system's. Here, not with the tab's other passkey
            // script, so an extension's sign-in window and its pop-ups on a site have it too. It asks PageFrames' frames.
            if Passkeys.available { Passkeys.attachRequests(to: configuration.userContentController) }
            FramePacing.attach(to: configuration.userContentController)
            configuration.userContentController.addUserScript(PageVideos.script)
            configuration.userContentController.add(PageVideos.shared, contentWorld: .defaultClient, name: PageVideos.messageName)
            configuration.userContentController.addUserScript(SwipeAnswers.script)
            configuration.userContentController.addUserScript(PageState.script)
            // The same note of what was a password, in the world AI apps read pages in (#214).
            configuration.userContentController.addUserScript(MCPPageScript.watch)
            configuration.userContentController.add(SwipeAnswers.shared, contentWorld: .defaultClient, name: SwipeAnswers.messageName)
            ContentBlocker.attach(to: configuration)
            // Cookie consent pop-ups answered with no (#175), in Zigzag's own world, apart from ad blocking.
            CookieBanners.attach(to: configuration.userContentController)
            WebStoreButton.attach(to: configuration)
            AddonsStoreButton.attach(to: configuration)
            // Extension pages only: their uncaught errors go to the extensions log, so a page that stalls says why.
            configuration.userContentController.addUserScript(PageErrors.script)
            configuration.userContentController.add(PageErrors.shared, contentWorld: .page, name: PageErrors.messageName)
            configuration.userContentController.addUserScript(ExtensionPageErrors.script)
            configuration.userContentController.add(ExtensionPageErrors.shared, contentWorld: .page, name: ExtensionPageErrors.messageName)
            // An extension's own page in a frame on a site (1Password's sign-in banner, Bitwarden's autofill menu)
            // answers as Chrome's would, as its pages elsewhere do.
            configuration.userContentController.addUserScript(WKUserScript(
                source: "if (location.protocol === 'webkit-extension:') {\n\(ExtensionBridgeScript.differences)\n}",
                injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
            configuration.userContentController.addScriptMessageHandler(FramedExtensionPopups.shared, contentWorld: .page, name: FramedExtensionPopups.messageName)
        }
        // Sites an extension lets message it get Chrome's name for that messaging; other pages get no `browser`.
        if #available(macOS 15.4, *) {
            let script = PageScripts.chromeRuntime(matching: profile.installs.externallyConnectablePatterns())
            PageScripts.replaceChromeRuntime(with: script, in: configuration.userContentController)
        }
        // With an extension that can capture tabs (Shazam), pages note where their Web Audio plays, so it can hear them.
        if #available(macOS 15.4, *), profile.installs.someEnabledExtensionDeclares("tabCapture"),
           !configuration.userContentController.userScripts.contains(BridgeTabCapture.routesScript) {
            configuration.userContentController.addUserScript(BridgeTabCapture.routesScript)
        }
    }

    /// WebKit's tracking prevention keeps cookies from any site embedded in another, as Safari does by default. That
    /// breaks sign-ins that check quietly in a hidden frame: Teams' Assignments asks Microsoft's sign-in page whether
    /// you're signed in, hears no, and its Continue gives up without opening anything. Chrome and Arc send them, and
    /// so does Zigzag; the content blocker still stops trackers loading at all. Each store has its own setting, so
    /// each profile's is told once, when the profile is made. Private windows keep their own store, untouched.
    static func allowCrossSiteCookies(in store: WKWebsiteDataStore) {
        // Not public API, but how Safari's own "Prevent cross-site tracking" switch is made.
        let statistics = NSSelectorFromString("_setResourceLoadStatisticsEnabled:")
        if store.responds(to: statistics) {
            typealias SetEnabled = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(store.method(for: statistics), to: SetEnabled.self)(store, statistics, false)
        }
        let blocking = NSSelectorFromString("_setThirdPartyCookieBlockingMode:onlyOnSitesWithoutUserInteraction:completionHandler:")
        if store.responds(to: blocking) {
            typealias SetMode = @convention(c) (AnyObject, Selector, Bool, Bool, @escaping @convention(block) () -> Void) -> Void
            unsafeBitCast(store.method(for: blocking), to: SetMode.self)(store, blocking, false, false) {}
        }
        // With the two above alone, a site you've never opened on its own still gets no cookies when embedded:
        // the store only takes cookies from sites it already has some for. Claude loads an artifact in a frame on
        // such a site, which then says "This browser isn't supported". Every site's cookies are taken now.
        let accept = NSSelectorFromString("_setCookieAcceptPolicy:completionHandler:")
        let cookies = store.httpCookieStore
        if cookies.responds(to: accept) {
            typealias SetPolicy = @convention(c) (AnyObject, Selector, UInt, @escaping @convention(block) () -> Void) -> Void
            unsafeBitCast(cookies.method(for: accept), to: SetPolicy.self)(cookies, accept, HTTPCookie.AcceptPolicy.always.rawValue) {}
        }
    }
}

/// Small scripts injected into every page.
enum PageScripts {
    static var all: [WKUserScript] {
        // Picture in Picture lives in the site panel and View › Picture in Picture (⌥⌘P), not as a pill drawn over
        // videos: pages lay out their own players, and a pill placed from outside drifts off them.
        [WKUserScript(source: linkHover, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: .defaultClient), applePayMark,
         modifiedLinkClicks, ScrollMessages.script, iconWatch]
    }

    /// Tells the browser when the page changes its icon links, as GitHub does for dark mode, so the tab's icon follows (#386).
    static let iconWatch = WKUserScript(source: """
    (() => {
      if (!/^https?:$/.test(location.protocol)) return;
      const isIcon = (n) => n && n.localName === 'link' && /icon/i.test(n.getAttribute('rel') || '');
      let timer = 0;
      const tell = () => {
        clearTimeout(timer);
        timer = setTimeout(() => { try { window.webkit.messageHandlers.zigzagIcons.postMessage(''); } catch (e) {} }, 300);
      };
      const watch = () => {
        new MutationObserver((changes) => {
          if (changes.some((c) => isIcon(c.target) || [...c.addedNodes, ...c.removedNodes].some(isIcon))) tell();
        }).observe(document.head || document.documentElement, { subtree: true, childList: true, attributes: true, attributeFilter: ['href', 'rel', 'sizes', 'type'] });
      };
      if (document.head) watch(); else document.addEventListener('DOMContentLoaded', watch, { once: true });
    })();
    """, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient)

    /// ⌘-click on a web link is stopped before the page (#317); ⇧ and ⌥ reach the page and are reported, so the
    /// page's navigation right after becomes Zigzag Mini or a download (#322). A ⌘ or middle press on an anchor whose
    /// href was taken off on purpose puts back its `data-zigzag-href` for WebKit to follow (#517, docs/extensions.md).
    static let modifiedLinkClicks = WKUserScript(source: """
    (() => {
      if (!/^https?:$/.test(location.protocol)) return;
      // The web link clicked, unless it's editable, a download or a same-page anchor.
      const target = (e) => {
        const link = e.composedPath().find((n) => n instanceof Element && (n.localName === 'a' || n.localName === 'area') &&
                                              (n.hasAttribute('href') || n.hasAttribute('xlink:href')));
        if (!link || link.hasAttribute('download') || link.isContentEditable) return null;
        let url;
        try { url = new URL(link.getAttribute('href') ?? link.getAttribute('xlink:href'), document.baseURI); } catch (error) { return null; }
        if (!/^https?:$/.test(url.protocol)) return null;
        if (url.hash && url.href.split('#')[0] === location.href.split('#')[0]) return null;
        return url;
      };
      const tell = (url, e) => {
        try { window.webkit.messageHandlers.zigzagLinkClick.postMessage({ url: url.href, shift: e.shiftKey, alt: e.altKey }); } catch (error) {}
      };
      addEventListener('click', (e) => {
        if (!e.isTrusted || e.button !== 0 || e.ctrlKey) return;
        const url = target(e);
        if (!url) return;
        if (e.metaKey) { e.stopImmediatePropagation(); return; }
        if (e.shiftKey || e.altKey) tell(url, e);
      }, true);
      const restored = new WeakMap();
      addEventListener('mousedown', (e) => {
        if (!e.isTrusted || !(e.button === 1 || (e.button === 0 && e.metaKey))) return;
        const link = e.composedPath().find((n) => n instanceof Element && n.localName === 'a' && n.hasAttribute('data-zigzag-href'));
        if (!link || !link.isConnected) return;
        const href = link.getAttribute('data-zigzag-href');
        try { if (!/^https?:$/.test(new URL(href, document.baseURI).protocol)) return; } catch (error) { return; }
        // The mark tells the page's own click handlers this press is the browser's.
        link.setAttribute('data-zigzag-modified', '');
        link.setAttribute('href', href);
        clearTimeout(restored.get(link));
        restored.set(link, setTimeout(() => {
          restored.delete(link);
          link.removeAttribute('data-zigzag-modified');
          if (link.getAttribute('href') === href && link.getAttribute('data-zigzag-href') === href) link.removeAttribute('href');
        }, 2000));
      }, true);
    })();
    """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient)

    /// The Apple Store checkout should show one Apple Pay mark (#235). WebKit gives Apple Pay only to Safari, so the
    /// store uses Apple's script for other browsers, adds `supports-applepay-ac` and writes the mark as text. Its
    /// option also has a `-webkit-named-image` logo only WebKit draws, so Zigzag showed both. Hide the logo in that
    /// case, as the store does on its button.
    static let applePayMark = WKUserScript(source: """
    (() => {
      const host = location.hostname;
      if (host !== 'apple.com' && !host.endsWith('.apple.com')) return;
      const style = document.createElement('style');
      style.textContent = 'html.supports-applepay-ac .rf-paymentoptions-image-applepay { background-image: none !important; }';
      (document.head || document.documentElement).appendChild(style);
    })();
    """, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient)

    /// Chrome's name for the messaging WebKit gives sites an extension lists (Resources/Extensions/chrome-runtime.js).
    static func chromeRuntime(matching patterns: [String: [String]]) -> WKUserScript {
        let json = (try? JSONSerialization.data(withJSONObject: patterns)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return WKUserScript(source: chromeRuntimeSource.replacingOccurrences(of: "__PATTERNS__", with: json),
                            injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
    }

    /// Once per controller: a popup shares its opener's, whose copy may name the sites from before an install.
    static func replaceChromeRuntime(with script: WKUserScript, in controller: WKUserContentController) {
        if controller.userScripts.contains(where: { $0.source == script.source }) { return }
        let head = chromeRuntimeSource.components(separatedBy: "__PATTERNS__")[0]
        if !head.isEmpty { OwnScripts.remove(from: controller) { $0.source.hasPrefix(head) } }
        controller.addUserScript(script)
    }

    private static let chromeRuntimeSource: String = {
        guard let url = Bundle.main.url(forResource: "chrome-runtime", withExtension: "js") else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

    /// Tells the browser which link the pointer is over, for the link preview in the corner.
    static let linkHover = """
    (() => {
      let current = null;
      const send = (a) => {
        const url = a ? a.href : null;
        if (url === current) return;
        current = url;
        const text = a ? ((a.getAttribute('aria-label') || a.textContent || '').trim().slice(0, 200)) : '';
        try { window.webkit.messageHandlers.zigzagHover.postMessage(url ? { url, text } : ''); } catch (e) {}
      };
      document.addEventListener('mouseover', (e) => {
        const a = e.target && e.target.closest ? e.target.closest('a[href], area[href]') : null;
        send(a);
      }, true);
      // The pointer is the only thing that decides: every move shows the link under it, or nothing. A move that
      // lands anywhere but a link clears the preview, so it can't stay over a page that isn't a link.
      document.addEventListener('mousemove', (e) => {
        const a = e.target && e.target.closest ? e.target.closest('a[href], area[href]') : null;
        send(a);
      }, true);
      document.addEventListener('mouseout', (e) => {
        const to = e.relatedTarget;
        const a = to && to.closest ? to.closest('a[href], area[href]') : null;
        if (!a) send(null);
      }, true);
      // A click can start a navigation before the page reports a mouseout, and moving away during the load then
      // leaves the pill showing the old address. Hide it as soon as the button goes down, and on the click itself.
      document.addEventListener('mousedown', () => send(null), true);
      document.addEventListener('click', () => send(null), true);
      // The page can move under a still pointer, taking the link away without a mouse event.
      window.addEventListener('scroll', () => send(null), true);
      window.addEventListener('blur', () => send(null));
      window.addEventListener('pagehide', () => send(null));
    })();
    """

    /// Collects the page's declared icons, best first.
    static let iconLinks = """
    (() => {
      const links = Array.from(document.querySelectorAll('link[rel~="icon"], link[rel="shortcut icon"], link[rel="apple-touch-icon"], link[rel="apple-touch-icon-precomposed"]'));
      // On the web or in the page itself only (FaviconStore checks again): never file: or another scheme.
      return links.filter(l => /^(https?|data):/i.test(l.href))
        .map(l => ({ href: l.href, sizes: l.getAttribute('sizes') || '', rel: l.rel, type: l.type || '' }));
    })();
    """
}

/// The page's own scrolls for Autohide: one report a frame, from the main frame only (#359).
final class ScrollMessages: NSObject, WKScriptMessageHandler {
    static let shared = ScrollMessages()
    static let messageName = "zigzagScroll"

    static let script = WKUserScript(source: """
    (() => {
      if (window.__zigzagScroll) return;
      window.__zigzagScroll = true;
      // The person's own input: a wheel, trackpad or finger, a scrolling key, or the scroll bar held.
      let input = 0, keyInput = 0, pressed = false;
      const mark = () => { input = Date.now(); };
      const markKey = () => { input = keyInput = Date.now(); };
      const keys = new Set(['ArrowUp', 'ArrowDown', 'PageUp', 'PageDown', 'Home', 'End', ' ']);
      const options = { capture: true, passive: true };
      window.addEventListener('wheel', (event) => { if (event.isTrusted) mark(); }, options);
      window.addEventListener('keydown', (event) => { if (event.isTrusted && keys.has(event.key)) markKey(); }, options);
      // On the scroll bar, not a click on the page: a link that jumps somewhere is the page scrolling.
      window.addEventListener('mousedown', (event) => {
        const html = document.documentElement;
        if (event.isTrusted && (event.target === html || event.clientX >= html.clientWidth)) pressed = true;
      }, options);
      window.addEventListener('mouseup', () => { pressed = false; }, options);
      window.addEventListener('blur', () => { pressed = false; }, options);
      const root = document.scrollingElement || document.documentElement;
      const y = () => Math.max(0, window.scrollY || root.scrollTop || 0);
      // A field has the focus: the bar stays where it is while the person types (a page's own field counts too).
      const editing = () => {
        const el = document.activeElement;
        if (!el) return false;
        if (el.isContentEditable) return true;
        const tag = el.localName;
        return tag === 'input' || tag === 'textarea' || tag === 'select' || !!el.closest?.('[contenteditable=""], [contenteditable="true"]');
      };
      // `dy` is the page's own movement since the last report, without the browser's scrolls back (`__zigzagScrollBy`).
      let pending = null, frame = 0, last = null;
      const report = (trusted) => {
        // Off unless the window's address bar is on Autohide.
        if (!window.__zigzagAutohide) { last = null; pending = null; return; }
        const now = y();
        const next = { y: now, dy: last == null ? 0 : now - last, trusted, key: Date.now() - keyInput < 400, editing: editing(), dragging: pressed };
        last = now;
        if (pending) {
          // The last place is the one that counts; a real gesture anywhere in the frame still marks it.
          next.dy += pending.dy;
          next.trusted = next.trusted || pending.trusted;
          next.key = next.key || pending.key;
        }
        pending = next;
        if (frame) return;
        frame = requestAnimationFrame(() => {
          frame = 0;
          const out = pending;
          pending = null;
          if (!out) return;
          try { window.webkit.messageHandlers.\(messageName).postMessage(out); } catch (e) {}
        });
      };
      window.__zigzagScrollBy = (dy) => {
        const before = y();
        window.scrollBy({ top: dy, behavior: 'instant' });
        if (last != null) last += y() - before;
      };
      window.addEventListener('scroll', (event) => {
        const target = event.target;
        // A page's own elements scroll inside it all the time; only the page itself moves the bar.
        if (target !== document && target !== document.documentElement && target !== root) return;
        // A key's smooth scroll runs on a little after the key, and a dragged scroll bar for as long as it's held.
        report(pressed || Date.now() - input < 400);
      }, options);
    })();
    """, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient)

    /// Turns a page's reports on or off; a new document starts with them off.
    static func setReporting(_ on: Bool, in webView: WKWebView) {
        webView.evaluateJavaScript("window.__zigzagAutohide = \(on)", in: nil, in: .defaultClient, completionHandler: nil)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.messageName,
              let webView = message.webView as? BrowserWebView, let tab = webView.owner,
              let body = message.body as? [String: Any], let y = (body["y"] as? NSNumber)?.doubleValue,
              let controller = webView.window?.windowController as? BrowserWindowController,
              let pane = controller.paneIndex(of: tab) else { return }
        controller.pageScrolled(to: CGFloat(y), by: (body["dy"] as? NSNumber).map { CGFloat($0.doubleValue) },
                                trusted: (body["trusted"] as? Bool) ?? false,
                                editing: (body["editing"] as? Bool) ?? false,
                                dragging: (body["dragging"] as? Bool) ?? false,
                                key: (body["key"] as? Bool) ?? false,
                                inPane: pane, tab: tab)
    }
}

/// Receives messages from our page scripts and routes them to the tab that sent them.
final class PageMessages: NSObject, WKScriptMessageHandler {
    static let shared = PageMessages()

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let webView = message.webView as? BrowserWebView, let tab = webView.owner else { return }
        switch message.name {
        case "zigzagHover":
            if let body = message.body as? [String: Any], let url = (body["url"] as? String).flatMap(URL.init(string:)) {
                tab.hoveredLinkChanged(url, title: body["text"] as? String)
            } else {
                let text = message.body as? String ?? ""
                tab.hoveredLinkChanged(text.isEmpty ? nil : URL(string: text))
            }
        case "zigzagLinkClick":
            guard let body = message.body as? [String: Any], let text = body["url"] as? String,
                  let url = URL(string: text) else { return }
            tab.modifiedClickFollowed(url, mini: body["shift"] as? Bool == true, download: body["alt"] as? Bool == true)
        case "zigzagIcons":
            guard message.frameInfo.isMainFrame, webView.owner === tab else { return }
            tab.pageIconsChanged()
        default:
            break
        }
    }
}

/// A website's uncaught errors and failed promises, and requests it makes that fail, for the diagnostics record: so
/// "I click it and nothing happens" comes with the error the page hit. Only the message and the site, never the page's
/// address or data (`Diagnostics.clean`), at most a few per page, and nothing from a private window.
///
/// A development tab counts its page's errors and failed promises too (`Tab.pageErrorCount`, #141), every one of
/// them: past the few it describes, the page says only how many more there were, at most twice a second, so a page
/// that throws in a loop costs two small messages a second. It says so only where someone listens for it
/// (`counts(in:)`, a development tab's pages): on every other page the script stops at those few, as it always has.
final class PageErrors: NSObject, WKScriptMessageHandler {
    static let shared = PageErrors()
    static let messageName = "zigzagPageError"
    /// What a development tab's pages say how many more errors on (`counts(in:)`).
    static let countName = "zigzagPageErrorCount"

    static let script = WKUserScript(source: """
    (() => {
      if (!/^https?:$/.test(location.protocol)) return;
      let sent = 0, more = 0, waiting = 0;
      // The page's own timers may be stood in for (a test's fake clock): the real one, from before the page ran.
      const later = window.setTimeout.bind(window);
      const tell = () => { waiting = 0; const count = more; more = 0; try { window.webkit.messageHandlers.\(countName).postMessage(count); } catch (e) {} };
      const post = (kind, text) => {
        if (++sent > 8) {
          // Counted on only where a development tab listens.
          if (kind !== 'http' && window.webkit.messageHandlers.\(countName)) { more++; if (!waiting) waiting = later(tell, 500); }
          return;
        }
        try { window.webkit.messageHandlers.\(messageName).postMessage({ kind, text: String(text || '').slice(0, 300) }); } catch (e) {}
      };
      const where = (file, line) => { try { return ' (' + new URL(file).host + ':' + line + ')'; } catch (e) { return ''; } };
      window.addEventListener('error', (e) => { if (e.message) post('error', e.message + where(e.filename, e.lineno)); });
      window.addEventListener('unhandledrejection', (e) => post('rejection', (e.reason && (e.reason.message || e.reason.name)) || e.reason));
      const failed = new Set();
      try {
        new PerformanceObserver((list) => {
          for (const entry of list.getEntries()) {
            if (entry.responseStatus >= 500 || entry.responseStatus === 401 || entry.responseStatus === 403) {
              let host = ''; try { host = new URL(entry.name).host; } catch (e) {}
              const key = entry.responseStatus + host;
              if (!failed.has(key)) { failed.add(key); post('http', entry.responseStatus + ' from ' + host); }
            }
          }
        }).observe({ type: 'resource', buffered: true });
      } catch (e) {}
    })();
    """, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)

    /// How many errors a message the page describes stands for: one for an error or a failed promise, none for a
    /// request that failed.
    static func errors(in body: [String: Any]) -> Int {
        switch body["kind"] as? String {
        case "error", "rejection": 1
        default: 0
        }
    }

    /// How many more a page says there were, past the ones it described.
    static func more(_ body: Any) -> Int { max(0, min(body as? Int ?? 0, 100_000)) }

    /// Hears a development tab's pages say how many more errors there were.
    private final class Counter: NSObject, WKScriptMessageHandler {
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            (message.webView as? BrowserWebView)?.owner?.countPageErrors(PageErrors.more(message.body))
        }
    }
    private static let counter = Counter()
    /// The sets of scripts the counter is in, so it's put in once and taken out once.
    private static let counting = NSHashTable<WKUserContentController>.weakObjects()
    /// Per set of scripts, the web views listened to. A page and the pop-ups it opened share one set: the counter
    /// stays in it while any of them is a development tab's, rather than one that isn't taking it from one that is.
    private static let listened = NSMapTable<WKUserContentController, NSHashTable<WKWebView>>.weakToStrongObjects()

    /// Whether the counter is in a web view's set of scripts.
    static func isCounting(in webView: WKWebView) -> Bool { counting.contains(webView.configuration.userContentController) }

    /// A web view's pages are listened to for the count, or no longer: a development tab's are. The page script
    /// looks for the listener each time it would count, so a page already open follows at once.
    static func counts(in webView: WKWebView, _ on: Bool) {
        let controller = webView.configuration.userContentController
        let webViews = listened.object(forKey: controller) ?? NSHashTable<WKWebView>.weakObjects()
        if on { webViews.add(webView) } else { webViews.remove(webView) }
        listened.setObject(webViews, forKey: controller)
        let wanted = !webViews.allObjects.isEmpty
        guard wanted != counting.contains(controller) else { return }
        if wanted {
            controller.add(counter, contentWorld: .page, name: countName)
            counting.add(controller)
        } else {
            controller.removeScriptMessageHandler(forName: countName, contentWorld: .page)
            counting.remove(controller)
        }
    }

    /// Max error text kept for Diagnostics (and problem reports).
    static let maxText = 300

    /// Keeps the start of the first line, minus characters that could pass for Zigzag's own report lines (line
    /// breaks, controls, bidi marks). The page controls this text.
    static func noteText(_ text: String) -> String {
        var kept = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            guard kept.count < maxText else { break }
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .unassigned, .privateUse: kept.append(" ")
            default: kept.append(scalar)
            }
        }
        return String(kept).trimmingCharacters(in: .whitespaces)
    }

    /// Only the tab's main document is logged; frames (ads) and unknown message kinds are ignored.
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let kind = body["kind"] as? String,
              ["error", "rejection", "http"].contains(kind), let text = body["text"] as? String, let webView = message.webView else { return }
        (webView as? BrowserWebView)?.owner?.countPageErrors(Self.errors(in: body))
        let title = kind == "http" ? "Request failed" : kind == "rejection" ? "Page error (promise)" : "Page error"
        Diagnostics.note(title, site: webView.url?.host() ?? message.frameInfo.securityOrigin.host, Self.noteText(text),
                         isPrivate: !webView.configuration.websiteDataStore.isPersistent)
    }
}

/// Uncaught errors and failed promises on an extension's own pages, as one line each in the extensions log: the
/// error's message and where it was thrown, nothing from the page's data. Ordinary websites never send these.
final class ExtensionPageErrors: NSObject, WKScriptMessageHandler {
    static let shared = ExtensionPageErrors()
    static let messageName = "zigzagExtensionError"

    static let script = WKUserScript(source: """
    (() => {
      if (location.protocol !== 'webkit-extension:') return;
      const post = (kind, text) => { try { window.webkit.messageHandlers.\(messageName).postMessage(kind + ': ' + String(text).slice(0, 240)); } catch (e) {} };
      window.addEventListener('error', (e) => post('error', (e.message || '') + ' @ ' + (e.filename || '').split('/').pop() + ':' + (e.lineno || 0)));
      window.addEventListener('unhandledrejection', (e) => post('rejection', (e.reason && (e.reason.message || e.reason.name)) || e.reason));
      const failed = new Set();
      new PerformanceObserver((list) => {
        for (const entry of list.getEntries()) {
          if (entry.responseStatus >= 400 && !failed.has(entry.name)) { failed.add(entry.name); let host = '?'; try { host = new URL(entry.name).host; } catch (e) {} post('http ' + entry.responseStatus, host); }
        }
      }).observe({ type: 'resource', buffered: true });
    })();
    """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)

    /// Extension pages are built from the extension's own setup, so they get this separately, once.
    static func attach(to configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        guard !controller.userScripts.contains(where: { $0.source == script.source }) else { return }
        controller.addUserScript(script)
        controller.removeScriptMessageHandler(forName: messageName, contentWorld: .page)
        controller.add(shared, contentWorld: .page, name: messageName)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.securityOrigin.protocol == "webkit-extension", let text = message.body as? String else { return }
        ExtensionLog.write("page \(message.frameInfo.securityOrigin.host.prefix(8)) \(text)")
    }
}

/// action.openPopup() from an extension page framed on a site (webkit-differences.js), which WebKit won't accept from
/// a site's process (#248). Only the extension's own frame can post this.
final class FramedExtensionPopups: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = FramedExtensionPopups()
    static let messageName = "zigzagOpenPopup"

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
        let origin = message.frameInfo.securityOrigin
        guard origin.protocol == "webkit-extension", !message.frameInfo.isMainFrame,
              let tab = (message.webView as? BrowserWebView)?.owner else {
            replyHandler(nil, "Not allowed")
            return
        }
        guard #available(macOS 15.4, *), let host = tab.extensionHost else {
            replyHandler("Extensions don't run here.", nil)
            return
        }
        replyHandler(host.openPopup(origin.host, from: tab), nil)
    }
}
