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
    static func allows(_ url: URL?, in tab: Tab?) -> Bool {
        guard isAvailable else { return true }
        let origin = SiteOrigin.of(url)
        return allows(protectionOn: isOn, kept: origin.flatMap(SitePermissions.webRTC(origin:)),
                      here: origin.flatMap { tab?.webRTCHere[$0] })
    }

    /// What Site Controls shows for the site in `tab`: Allow or Block, never Ask, since nothing asks first.
    static func choice(origin: String, in tab: Tab?) -> PermissionChoice {
        allows(protectionOn: isOn, kept: SitePermissions.webRTC(origin: origin), here: tab?.webRTCHere[origin]) ? .allow : .block
    }

    /// Allow or Block for the site, from Site Controls or the question: kept for it, or in a private window for `tab`
    /// alone. Pages of it open in `tab` reload into it at once; any other tab, once it next loads.
    static func choose(_ allowed: Bool, origin: String, in tab: Tab?) {
        let before = tab.map { allows(page(of: $0), in: $0) }
        if let tab, tab.isPrivate {
            tab.webRTCHere[origin] = allowed
        } else {
            SitePermissions.setChoice(allowed ? .allow : .block, for: .webRTC, origin: origin)
        }
        guard let tab, SiteOrigin.of(page(of: tab)) == origin, let before, before != allows(page(of: tab), in: tab) else { return }
        Diagnostics.note("WebRTC", site: SiteOrigin.label(origin), allowed ? "allowed, reloaded" : "blocked, reloaded", isPrivate: tab.isPrivate)
        tab.reload()
    }

    /// Sets the web view's switch for the page it's going to. Each tab's web view has its own preferences
    /// (`isolate`), so one page's choice never reaches another's.
    static func apply(to webView: WKWebView, for url: URL?, in tab: Tab?) {
        guard isAvailable else { return }
        let preferences = webView.configuration.preferences
        let wanted = allows(url, in: tab)
        if (preferences.value(forKey: preferenceKey) as? Bool) != wanted { preferences.setValue(wanted, forKey: preferenceKey) }
    }

    /// A page's new window comes with its opener's preferences, the same object: it gets a copy, so the switch set
    /// for one never changes the other.
    static func isolate(_ configuration: WKWebViewConfiguration) {
        guard isAvailable, let copy = configuration.preferences.copy() as? WKPreferences else { return }
        configuration.preferences = copy
    }

    // MARK: Telling when a page tries

    /// On a page without WebRTC, a call that starts after a click (Join, Call) is told, so Zigzag can offer to allow
    /// the site. `RTCPeerConnection` stays undefined, as WebKit leaves it: only looking it up right after a click or
    /// a key says so, once a frame, so a script that looks on its own (a fingerprinting one, as the page loads) changes
    /// nothing and asks nothing. Where WebRTC is on, it does nothing at all.
    private static let script = """
    (() => {
      if ('RTCPeerConnection' in window) return;
      let told = false;
      for (const name of ['RTCPeerConnection', 'webkitRTCPeerConnection']) {
        try {
          Object.defineProperty(window, name, {
            configurable: true, enumerable: false,
            get() {
              if (!told && navigator.userActivation?.isActive !== false) {
                told = true;
                try { window.webkit.messageHandlers.\(messageName).postMessage({}); } catch (e) {}
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
        guard message.name == Self.messageName, let webView = message.webView as? BrowserWebView, let tab = webView.owner,
              tab.webView === webView else { return }
        // Only right after a click or a key in a page: what the page says of itself isn't enough.
        guard Date().timeIntervalSince(UndoClock.lastPageInput) < 5 else { return }
        Task { _ = await Self.offer(in: tab) }
    }

    /// "Use WebRTC for calls?" for the page in `tab`, when WebRTC is off for it: once a page, Allow keeping it for
    /// the site (in a private window, the tab) and reloading the page into it. Says whether it was allowed.
    @discardableResult
    static func offer(in tab: Tab) async -> Bool {
        let here = page(of: tab)
        guard isAvailable, !allows(here, in: tab), let origin = SiteOrigin.of(here),
              tab.permissionAnswers.answer(key: origin, kind: kind) == nil else { return false }
        // Asked once a page, whatever the answer: a site trying again and again never asks again.
        tab.permissionAnswers.note(false, key: origin, kind: kind)
        SitePermissions.noteAsked(.webRTC, origin: origin, isPrivate: tab.isPrivate)
        guard let controller = WindowManager.shared.promptHost(for: tab.host?.hostWindow) else { return false }
        let answer = await PermissionPrompt.ask(host: SitePermissions.askerName(origin), origin: origin, what: "WebRTC", symbol: "phone.fill", in: controller, tab: tab,
                                                title: String(localized: "Use WebRTC for calls", comment: "A site's permission question, without its question mark: WebRTC is off for the site (Settings › Privacy › Protect IP address from WebRTC), and it tried to start a call. WebRTC is a name: keep it as it is."),
                                                allowTitle: String(localized: "Allow and Reload", comment: "Button on the question to use WebRTC for calls on a site: allows it for the site and reloads the page."))
        guard answer == .allow || answer == .always, SiteOrigin.of(page(of: tab)) == origin else { return false }
        choose(true, origin: origin, in: tab)
        return true
    }

    private static let kind = "webRTC"

    /// The page the tab shows, or the one it's going to before any.
    private static func page(of tab: Tab) -> URL? { tab.webView?.url ?? tab.url }
}
