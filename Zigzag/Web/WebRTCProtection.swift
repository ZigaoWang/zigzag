import AppKit
import WebKit

/// Stops WebRTC from leaking the real IP address (#229): its connections bypass proxy and VPN proxy settings, and
/// WebKit hides only local addresses. With Settings › Privacy › Protect IP address from WebRTC on, pages get no
/// `RTCPeerConnection` except on sites allowed in Site Controls (Meet, Zoom, Teams, Discord). Off by default; then
/// only blocked sites lose it. Uses WKPreferences' private `peerConnectionEnabled`, set per page on navigation, so a
/// change takes a reload. If WebKit drops the switch, nothing is offered. Private windows follow the setting and kept
/// choices; anything allowed there is for that tab only.
@MainActor
final class WebRTCProtection: NSObject, WKScriptMessageHandler {
    static let shared = WebRTCProtection()
    static let messageName = "zigzagWebRTC"
    private static let settingKey = "ProtectsIPFromWebRTC"
    private static let setter = NSSelectorFromString("_setPeerConnectionEnabled:")
    private static let getter = NSSelectorFromString("_peerConnectionEnabled")
    private static let preferenceKey = "peerConnectionEnabled"

    /// Without WebKit's switch there's nothing to offer.
    static let isAvailable: Bool = {
        let preferences = WKPreferences()
        return preferences.responds(to: setter) && preferences.responds(to: getter)
    }()

    /// Stored with site permissions (`SitePermissions.defaults`). Off by default.
    static var isOn: Bool {
        get { isAvailable && SitePermissions.defaults.bool(forKey: settingKey) }
        set { SitePermissions.defaults.set(newValue, forKey: settingKey) }
    }

    /// A private tab's choice first, then the site's kept choice, then the setting.
    nonisolated static func allows(protectionOn: Bool, kept: Bool?, here: Bool?) -> Bool {
        here ?? kept ?? !protectionOn
    }

    /// Pages with no site (about:blank, file:, data:) follow the setting.
    static func allows(_ url: URL?, in tab: Tab?) -> Bool { allows(url, here: tab?.webRTCHere) }

    /// With a private tab's choices (`Tab.webRTCHere`), as a pop-up keeps its opener's.
    static func allows(_ url: URL?, here choices: [String: Bool]?) -> Bool {
        guard isAvailable else { return true }
        let origin = SiteOrigin.of(url)
        return allows(protectionOn: isOn, kept: origin.flatMap(SitePermissions.webRTC(origin:)),
                      here: origin.flatMap { choices?[$0] })
    }

    /// Allow or Block, never Ask, since nothing asks first.
    /// Allow, Don't Allow, or Ask, like every other permission (#545): Ask is what a site with nothing kept reads, so
    /// its row can offer the same three as the rest.
    static func choice(origin: String, in tab: Tab?) -> PermissionChoice {
        if let here = tab?.webRTCHere[origin] { return here ? .allow : .block }
        if let kept = SitePermissions.webRTC(origin: origin) { return kept ? .allow : .block }
        // Protection off: nothing to ask about, since every page gets it.
        return isOn ? .ask : .allow
    }

    /// Ask: forgets the kept answer so the next attempt asks again, as the other permissions' Ask does.
    static func forget(origin: String) {
        SitePermissions.setChoice(.ask, for: .webRTC, origin: origin)
    }

    /// Kept for the site, or in a private window for `tab` only. The site's pages in `tab` reload now; other tabs
    /// pick it up on their next load.
    static func choose(_ allowed: Bool, origin: String, in tab: Tab?) {
        let before = tab.map { allows(page(of: $0), in: $0) }
        keep(allowed, origin: origin, in: tab)
        guard let tab, SiteOrigin.of(page(of: tab)) == origin, let before, before != allows(page(of: tab), in: tab) else { return }
        Diagnostics.note("WebRTC", site: SiteOrigin.label(origin), allowed ? "allowed, reloaded" : "blocked, reloaded", isPrivate: tab.isPrivate)
        tab.reload()
    }

    private static func keep(_ allowed: Bool, origin: String, in tab: Tab?) {
        if let tab, tab.isPrivate {
            tab.webRTCHere[origin] = allowed
        } else {
            SitePermissions.setChoice(allowed ? .allow : .block, for: .webRTC, origin: origin)
        }
    }

    /// Each tab's web view has its own preferences (`WebKitSetup.separatePreferences`), so this only affects its own
    /// page.
    static func apply(to webView: WKWebView, for url: URL?, in tab: Tab?) { apply(to: webView, for: url, here: tab?.webRTCHere) }

    static func apply(to webView: WKWebView, for url: URL?, here choices: [String: Bool]?) {
        guard isAvailable else { return }
        WebKitSetup.setIfAvailable(allows(url, here: choices), key: preferenceKey, in: webView.configuration.preferences)
    }

    // MARK: Telling when a page tries

    /// When WebRTC is off, reports lookups of `RTCPeerConnection` (which stays undefined, as WebKit leaves it) so
    /// Zigzag can offer to allow the site. After a click (Join, Call) it asks; a lookup during load (Meet does this)
    /// is reported once per frame for a quiet notice (`notice(in:isMainFrame:)`). Does nothing when WebRTC is on.
    private static let script = """
    (() => {
      if ('RTCPeerConnection' in window) return;
      let told = false, noted = false;
      for (const name of ['RTCPeerConnection', 'webkitRTCPeerConnection']) {
        try {
          Object.defineProperty(window, name, {
            configurable: true, enumerable: false,
            get() {
              const clicked = navigator.userActivation?.isActive !== false;
              if (clicked ? !told : !noted) {
                if (clicked) told = true; else noted = true;
                try { window.webkit.messageHandlers.\(messageName).postMessage({ clicked }); } catch (e) {}
              }
              return undefined;
            },
            set(value) { Object.defineProperty(window, name, { value, writable: true, configurable: true, enumerable: true }); }
          });
        } catch (e) {}
      }
    })();
    """

    private static let marker = "/* zigzag webrtc */"

    static func attach(to configuration: WKWebViewConfiguration) {
        guard isAvailable else { return }
        let controller = configuration.userContentController
        guard !controller.userScripts.contains(where: { $0.source.hasPrefix(marker) }) else { return }
        controller.addUserScript(WKUserScript(source: marker + "\n" + script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        controller.add(shared, contentWorld: .page, name: messageName)
        // Every connection the page makes, so a Block can close the ones that are up (#545). It passes the real
        // constructor through unchanged, so an allowed site sees no difference.
        if !controller.userScripts.contains(where: { $0.source.hasPrefix(trackerMarker) }) {
            controller.addUserScript(WKUserScript(source: trackerMarker + "\n" + tracker, injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: false, in: .page))
        }
    }

    private static let trackerMarker = "/* zigzag webrtc peers */"
    /// Records each `RTCPeerConnection` the page makes on `window.__zigzagPeers`, without changing what it returns.
    private static let tracker = """
    (() => {
      const P = window.RTCPeerConnection || window.webkitRTCPeerConnection;
      if (!P) return;
      if (window.__zigzagPeers && window.__zigzagPeers.__zigzagTracking) return;
      const peers = [];
      peers.__zigzagTracking = true;
      window.__zigzagPeers = peers;
      const Wrapped = function (...args) {
        const peer = new P(...args);
        try { peers.push(peer); } catch (e) {}
        return peer;
      };
      Wrapped.prototype = P.prototype;
      try { Object.defineProperty(Wrapped, 'name', { value: 'RTCPeerConnection' }); } catch (e) {}
      window.RTCPeerConnection = Wrapped;
      if (window.webkitRTCPeerConnection) window.webkitRTCPeerConnection = Wrapped;
    })();
    """

    /// For a page that is open now: close the connections that are up and refuse new ones until the page loads again,
    /// where the kept Block keeps it out. Measured against WebKit: the preference alone does nothing to a loaded page,
    /// and this does (`closed: true`, `canMakeAnother: false`).
    private static let blockScript = """
    (() => {
      for (const peer of (window.__zigzagPeers || [])) { try { peer.close(); } catch (e) {} }
      window.__zigzagPeers = [];
      const refuse = function () {
        throw new DOMException('WebRTC is blocked for this site.', 'NotAllowedError');
      };
      try {
        window.RTCPeerConnection = refuse;
        if (window.webkitRTCPeerConnection) window.webkitRTCPeerConnection = refuse;
      } catch (e) {}
      return true;
    })();
    """

    /// Takes WebRTC away from a page that has it now. A page that never had it is left alone.
    static func block(in tab: Tab) {
        guard isAvailable, let webView = tab.webView else { return }
        webView.evaluateJavaScript(blockScript) { _, _ in }
        Diagnostics.note("WebRTC", site: SiteOrigin.of(webView.url).map(SiteOrigin.label), "blocked on the open page", isPrivate: tab.isPrivate)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.messageName, let webView = message.webView else { return }
        let tab = (webView as? BrowserWebView)?.owner.flatMap { $0.webView === webView ? $0 : nil }
        // Only ask right after a real click or key; the page's own claim isn't trusted. Otherwise show the quiet
        // notice.
        let clicked = (message.body as? [String: Any])?["clicked"] as? Bool ?? true
        guard clicked, Date().timeIntervalSince(UndoClock.lastPageInput) < 5 else {
            if let tab { Self.notice(in: tab, isMainFrame: message.frameInfo.isMainFrame) }
            return
        }
        if let tab {
            Task { _ = await Self.offer(in: tab) }
        } else if let popup = PopupWindowController.all.first(where: { $0.webView === webView }) {
            // A call in a pop-up asks in its opener tab's window and follows its private choices.
            Task { _ = await Self.offer(in: popup) }
        }
    }

    /// "Use WebRTC for calls?" once per page while it's off. Allow keeps it for the site (a private window: the tab)
    /// and reloads. Returns whether it was allowed.
    @discardableResult
    static func offer(in tab: Tab) async -> Bool {
        guard let origin = await ask(for: page(of: tab), in: tab) else { return false }
        guard SiteOrigin.of(page(of: tab)) == origin else { return false }
        choose(true, origin: origin, in: tab)
        return true
    }

    /// For a pop-up, asked in its opener tab's window; Allow reloads the pop-up.
    @discardableResult
    static func offer(in popup: PopupWindowController) async -> Bool {
        guard let tab = popup.opener, let origin = await ask(for: popup.webView.url, in: tab, bringingForward: true) else { return false }
        keep(true, origin: origin, in: tab)
        let webView = popup.webView
        guard SiteOrigin.of(webView.url) == origin else { return true }
        Diagnostics.note("WebRTC", site: SiteOrigin.label(origin), "allowed in a pop-up, reloaded", isPrivate: tab.isPrivate)
        apply(to: webView, for: webView.url, here: popup.webRTCChoices)
        webView.reload()
        return true
    }

    /// Returns the allowed origin, or nil.
    private static func ask(for here: URL?, in tab: Tab, bringingForward: Bool = false) async -> String? {
        guard isAvailable, !allows(here, in: tab), let origin = SiteOrigin.of(here),
              tab.permissionAnswers.answer(key: origin, kind: kind) == nil,
              // Never asks again once you chose (Block or Don't Allow) or put the question away this session; Site
              // Controls has the switch.
              SitePermissions.webRTC(origin: origin) == nil, !putAway.contains(origin) else { return nil }
        // Once per page whatever the answer.
        tab.permissionAnswers.note(false, key: origin, kind: kind)
        SitePermissions.noteAsked(.webRTC, origin: origin, isPrivate: tab.isPrivate)
        hideNotice(in: tab)
        guard let controller = WindowManager.shared.promptHost(for: tab.host?.hostWindow) else { return nil }
        // Bring the asking window forward so the question isn't behind the pop-up.
        if bringingForward { controller.window?.makeKeyAndOrderFront(nil) }
        let answer = await PermissionPrompt.ask(host: SitePermissions.askerName(origin), origin: origin, answerKey: origin, what: "WebRTC", symbol: "phone.fill", in: controller, tab: tab,
                                                title: String(localized: "Use WebRTC for calls", comment: "A site's permission question, without its question mark: WebRTC is off for the site (Settings › Privacy › Protect IP address from WebRTC), and it tried to start a call. WebRTC is a name: keep it as it is."),
                                                actions: [.deny, .allow],
                                                canRemember: true,
                                                rememberTitle: String(localized: "Remember for this site", comment: "Checkbox on the question to use WebRTC for calls on a site: keeps the answer for the site, so it isn't asked again."))
        switch answer?.action {
        case "allow":
            // Remembered for the site, or for the tab in a private window; otherwise the answer holds for this page
            // only and a reload asks again, as every other permission does.
            if answer?.remember != true { tab.permissionAnswers.note(true, key: origin, kind: kind) }
            return origin
        case "deny":
            if answer?.remember == true { keep(false, origin: origin, in: tab) }
            else { tab.permissionAnswers.note(false, key: origin, kind: kind) }
            return nil
        // Put away (×, Esc, navigated): not asked again until relaunch.
        default: putAway.insert(origin)
        }
        return nil
    }

    /// Sites whose question or notice was dismissed without an answer this session.
    private static var putAway: Set<String> = []
    /// Shown once per site per session, since many sites probe WebRTC on every load (analytics, fingerprinting).
    private static var noticed: Set<String> = []

    private static let kind = "webRTC"
    private static let noticeKind = "webRTCNotice"

    // MARK: Saying so when a page tries on its own

    /// Only the main frame (not an ad's frame), once per load, not after the page asked, and never for a blocked site
    /// or one already noticed or dismissed this session.
    nonisolated static func notices(allowed: Bool, chosen: Bool?, isMainFrame: Bool, noticedHere: Bool, askedHere: Bool,
                                    putAway: Bool) -> Bool {
        !allowed && chosen != false && isMainFrame && !noticedHere && !askedHere && !putAway
    }

    /// "This site tried to use WebRTC, which you've blocked." with Allow for This Site (kept for the site, or the tab
    /// in a private window, then reloads). Logged to Diagnostics once per page even if the tab is in the background.
    /// Returns whether it was logged.
    @discardableResult
    static func notice(in tab: Tab, isMainFrame: Bool) -> Bool {
        let here = page(of: tab)
        guard isAvailable, let origin = SiteOrigin.of(here),
              notices(allowed: allows(here, in: tab), chosen: tab.webRTCHere[origin] ?? SitePermissions.webRTC(origin: origin),
                      isMainFrame: isMainFrame, noticedHere: tab.permissionAnswers.answer(key: origin, kind: noticeKind) != nil,
                      askedHere: tab.permissionAnswers.answer(key: origin, kind: kind) != nil,
                      putAway: putAway.contains(origin) || noticed.contains(origin))
        else { return false }
        tab.permissionAnswers.note(false, key: origin, kind: noticeKind)
        Diagnostics.note("WebRTC", site: SiteOrigin.label(origin), "blocked, the page tried to use it", isPrivate: tab.isPrivate)
        guard let controller = WindowManager.shared.window(of: tab),
              controller.promptShows(tab) else { return true }
        noticed.insert(origin)
        Toast.show(String(localized: "This site tried to use WebRTC, which you’ve blocked.", comment: "Notice over a page when WebRTC is off for it (Settings › Privacy › Protect IP address from WebRTC) and the page tried to use it, as a call site like Google Meet does. WebRTC is a name: keep it as it is."),
                   symbol: "phone.fill",
                   action: (String(localized: "Allow for This Site", comment: "Button on the notice that a site tried to use blocked WebRTC: allows WebRTC for the site and reloads the page."), { [weak tab] in
                       guard let tab, SiteOrigin.of(page(of: tab)) == origin else { return }
                       choose(true, origin: origin, in: tab)
                   }),
                   duration: 8, owner: noticeOwner, onClose: { putAway.insert(origin) }, in: controller)
        return true
    }

    /// Not the tab, which would match the translate offer's owner.
    private static let noticeOwner = NSObject()

    /// The question says the same and more.
    private static func hideNotice(in tab: Tab) {
        guard let controller = WindowManager.shared.window(of: tab) else { return }
        Toast.hide(for: noticeOwner, in: controller)
    }

    /// The shown page, or the pending one.
    private static func page(of tab: Tab) -> URL? { tab.webView?.url ?? tab.url }
}
