import AppKit
import WebKit

/// Keeps WebRTC from showing sites your real IP address (#229). A page's WebRTC connections don't go through a proxy or
/// a VPN's proxy settings, so a site can learn the Mac's public address through them even while everything else goes
/// through the proxy. WebKit already hides local addresses, not the public one.
///
/// With Settings › Privacy › Protect IP address from WebRTC on, pages have no WebRTC at all (no `RTCPeerConnection`),
/// except on sites you allow in Site Controls, where calls (Meet, Zoom, Teams, Discord) work as before. Off, as it
/// starts, every site has it, unless you blocked one. It's WebKit's own switch for a web view's peer connections
/// (WKPreferences' unpublished `peerConnectionEnabled`), set for the page each time the tab goes to one: a page gets
/// WebRTC or not as it's made, so a change for the page you're on takes a reload. Without that switch (a WebKit that
/// dropped it), nothing is offered and WebRTC stays as WebKit has it.
///
/// A private window follows the setting and the choices made for sites elsewhere; what you allow in one is for that
/// tab only, never kept.
@MainActor
final class WebRTCProtection: NSObject, WKScriptMessageHandler {
    static let shared = WebRTCProtection()
    static let messageName = "zigzagWebRTC"
    private static let settingKey = "ProtectsIPFromWebRTC"
    private static let setter = NSSelectorFromString("_setPeerConnectionEnabled:")
    private static let getter = NSSelectorFromString("_peerConnectionEnabled")
    private static let preferenceKey = "peerConnectionEnabled"

    /// WebKit still has the switch: without it there's nothing to offer.
    static let isAvailable: Bool = {
        let preferences = WKPreferences()
        return preferences.responds(to: setter) && preferences.responds(to: getter)
    }()

    /// The setting, kept with the sites' permissions (`SitePermissions.defaults`). Off unless you turn it on.
    static var isOn: Bool {
        get { isAvailable && SitePermissions.defaults.bool(forKey: settingKey) }
        set { SitePermissions.defaults.set(newValue, forKey: settingKey) }
    }

    /// Whether a page may use WebRTC: a choice for this tab alone (a private window's) comes first, then the one kept
    /// for the site, then the setting.
    nonisolated static func allows(protectionOn: Bool, kept: Bool?, here: Bool?) -> Bool {
        here ?? kept ?? !protectionOn
    }

    /// Whether the page at `url` may use WebRTC in `tab`. A page with no site to keep a choice for (about:blank,
    /// file:, data:) follows the setting.
    static func allows(_ url: URL?, in tab: Tab?) -> Bool { allows(url, here: tab?.webRTCHere) }

    /// The same with a private tab's own choices given (`Tab.webRTCHere`), as a pop-up keeps its opener's.
    static func allows(_ url: URL?, here choices: [String: Bool]?) -> Bool {
        guard isAvailable else { return true }
        let origin = SiteOrigin.of(url)
        return allows(protectionOn: isOn, kept: origin.flatMap(SitePermissions.webRTC(origin:)),
                      here: origin.flatMap { choices?[$0] })
    }

    /// What Site Controls shows for the site in `tab`: Allow or Block, never Ask, since nothing asks first.
    static func choice(origin: String, in tab: Tab?) -> PermissionChoice {
        allows(protectionOn: isOn, kept: SitePermissions.webRTC(origin: origin), here: tab?.webRTCHere[origin]) ? .allow : .block
    }

    /// Allow or Block for the site, from Site Controls or the question: kept for it, or in a private window for `tab`
    /// alone. Pages of it open in `tab` reload into it at once; any other tab, once it next loads.
    static func choose(_ allowed: Bool, origin: String, in tab: Tab?) {
        let before = tab.map { allows(page(of: $0), in: $0) }
        keep(allowed, origin: origin, in: tab)
        guard let tab, SiteOrigin.of(page(of: tab)) == origin, let before, before != allows(page(of: tab), in: tab) else { return }
        Diagnostics.note("WebRTC", site: SiteOrigin.label(origin), allowed ? "allowed, reloaded" : "blocked, reloaded", isPrivate: tab.isPrivate)
        tab.reload()
    }

    /// The choice alone, kept for the site, or in a private window for `tab` alone.
    private static func keep(_ allowed: Bool, origin: String, in tab: Tab?) {
        if let tab, tab.isPrivate {
            tab.webRTCHere[origin] = allowed
        } else {
            SitePermissions.setChoice(allowed ? .allow : .block, for: .webRTC, origin: origin)
        }
    }

    /// Sets the web view's switch for the page it's going to. Each tab's web view has its own preferences
    /// (`WebKitSetup.separatePreferences`), so one page's choice never reaches another's.
    static func apply(to webView: WKWebView, for url: URL?, in tab: Tab?) { apply(to: webView, for: url, here: tab?.webRTCHere) }

    static func apply(to webView: WKWebView, for url: URL?, here choices: [String: Bool]?) {
        guard isAvailable else { return }
        WebKitSetup.setIfAvailable(allows(url, here: choices), key: preferenceKey, in: webView.configuration.preferences)
    }

    // MARK: Telling when a page tries

    /// On a page without WebRTC, looking up `RTCPeerConnection` is told, so Zigzag can say so and offer to allow the
    /// site. It stays undefined, as WebKit leaves it. A call that starts after a click (Join, Call) is told as such,
    /// and asks; a page that looks on its own, as it loads (Meet does, and breaks), is told once a frame, for a quiet
    /// notice on the page itself (`notice(in:isMainFrame:)`). Where WebRTC is on, it does nothing at all.
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
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.messageName, let webView = message.webView else { return }
        let tab = (webView as? BrowserWebView)?.owner.flatMap { $0.webView === webView ? $0 : nil }
        // Asked only right after a click or a key in a page: what the page says of itself isn't enough. Otherwise
        // the page tried on its own, and its tab says so quietly.
        let clicked = (message.body as? [String: Any])?["clicked"] as? Bool ?? true
        guard clicked, Date().timeIntervalSince(UndoClock.lastPageInput) < 5 else {
            if let tab { Self.notice(in: tab, isMainFrame: message.frameInfo.isMainFrame) }
            return
        }
        if let tab {
            Task { _ = await Self.offer(in: tab) }
        } else if let popup = PopupWindowController.all.first(where: { $0.webView === webView }) {
            // A pop-up's page (a call that opens in a window of its own): asked in the window of the tab that
            // opened it, whose private choices it follows.
            Task { _ = await Self.offer(in: popup) }
        }
    }

    /// "Use WebRTC for calls?" for the page in `tab`, when WebRTC is off for it: once a page, Allow keeping it for
    /// the site (in a private window, the tab) and reloading the page into it. Says whether it was allowed.
    @discardableResult
    static func offer(in tab: Tab) async -> Bool {
        guard let origin = await ask(for: page(of: tab), in: tab) else { return false }
        guard SiteOrigin.of(page(of: tab)) == origin else { return false }
        choose(true, origin: origin, in: tab)
        return true
    }

    /// The same for a pop-up window's page, asked in its opener tab's window: Allow reloads the pop-up.
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

    /// Asks about the page at `here`, in `tab`'s window: the origin you allowed, or nil.
    private static func ask(for here: URL?, in tab: Tab, bringingForward: Bool = false) async -> String? {
        guard isAvailable, !allows(here, in: tab), let origin = SiteOrigin.of(here),
              tab.permissionAnswers.answer(key: origin, kind: kind) == nil,
              // A site you've chosen for (Block in Site Controls, or Don't Allow here) is never asked again; nor one
              // whose question you put away this session, in any tab: the switch is in Site Controls from then on.
              SitePermissions.webRTC(origin: origin) == nil, !putAway.contains(origin) else { return nil }
        // Asked once a page, whatever the answer: a site trying again and again never asks again.
        tab.permissionAnswers.note(false, key: origin, kind: kind)
        SitePermissions.noteAsked(.webRTC, origin: origin, isPrivate: tab.isPrivate)
        hideNotice(in: tab)
        guard let controller = WindowManager.shared.promptHost(for: tab.host?.hostWindow) else { return nil }
        // From a pop-up: the window that asks comes forward, so the question isn't hidden behind it.
        if bringingForward { controller.window?.makeKeyAndOrderFront(nil) }
        let answer = await PermissionPrompt.ask(host: SitePermissions.askerName(origin), origin: origin, answerKey: origin, what: "WebRTC", symbol: "phone.fill", in: controller, tab: tab,
                                                title: String(localized: "Use WebRTC for calls", comment: "A site's permission question, without its question mark: WebRTC is off for the site (Settings › Privacy › Protect IP address from WebRTC), and it tried to start a call. WebRTC is a name: keep it as it is."),
                                                actions: [.deny, PermissionAction(id: "allow", title: String(localized: "Allow and Reload", comment: "Button on the question to use WebRTC for calls on a site: allows it for the site and reloads the page."), isDeny: false, isProminent: true)],
                                                canRemember: false)
        switch answer?.action {
        case "allow": return origin
        // Don't Allow is the site's choice: kept, as Block in Site Controls would be.
        case "deny": keep(false, origin: origin, in: tab)
        // Put away (×, Esc, the tab went on): not asked again until Zigzag next opens.
        default: putAway.insert(origin)
        }
        return nil
    }

    /// Sites whose question or notice was put away without an answer, this session.
    private static var putAway: Set<String> = []
    /// Sites the notice has shown for this session: once each, since many sites look for WebRTC on every page load
    /// (analytics, fingerprinting) and a notice on each would get in the way. Site Controls still has the switch.
    private static var noticed: Set<String> = []

    private static let kind = "webRTC"
    private static let noticeKind = "webRTCNotice"

    // MARK: Saying so when a page tries on its own

    /// Whether a page that looked for WebRTC on its own, while it's blocked, says so: only the page itself (not a frame
    /// in it, an ad's), once a page load, never once the page asked (its question says it), and never for a site
    /// you've chosen Block for, or that has shown or put the notice away this session.
    nonisolated static func notices(allowed: Bool, chosen: Bool?, isMainFrame: Bool, noticedHere: Bool, askedHere: Bool,
                                    putAway: Bool) -> Bool {
        !allowed && chosen != false && isMainFrame && !noticedHere && !askedHere && !putAway
    }

    /// "This site tried to use WebRTC, which you've blocked.", over the page in `tab`, with Allow for This Site:
    /// kept for the site (in a private window, the tab alone) and the page reloaded into it, as in Site Controls.
    /// Noted in Diagnostics once a page, whether or not the tab is in front to show it. Says whether it noted it.
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

    /// What the notice is shown for, to take it down: not the tab, which would read as the offer to translate its page.
    private static let noticeOwner = NSObject()

    /// Takes the notice down for the question, which says the same and more.
    private static func hideNotice(in tab: Tab) {
        guard let controller = WindowManager.shared.window(of: tab) else { return }
        Toast.hide(for: noticeOwner, in: controller)
    }

    /// The page the tab shows, or the one it's going to before any.
    private static func page(of tab: Tab) -> URL? { tab.webView?.url ?? tab.url }
}
