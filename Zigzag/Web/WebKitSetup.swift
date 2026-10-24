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

    static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configure(configuration)
        return configuration
    }

    /// Applies our defaults. Popup configurations handed to us by WebKit already carry most of these.
    static func configure(_ configuration: WKWebViewConfiguration) {
        configuration.websiteDataStore = .default()
        configuration.applicationNameForUserAgent = applicationNameForUserAgent
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.upgradeKnownHostsToHTTPS = true
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        if #available(macOS 15.4, *), configuration.webExtensionController == nil {
            configuration.webExtensionController = ExtensionHost.shared.controller
        }
        if configuration.userContentController.userScripts.isEmpty {
            for script in PageScripts.all { configuration.userContentController.addUserScript(script) }
            // Runs in its own world, invisible to the page.
            configuration.userContentController.add(PageMessages.shared, contentWorld: .defaultClient, name: "zigzagHover")
            ContentBlocker.attach(to: configuration)
        }
    }
}

/// Small scripts injected into every page.
enum PageScripts {
    static var all: [WKUserScript] {
        [WKUserScript(source: linkHover, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: .defaultClient),
         WKUserScript(source: pictureInPicture, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: .defaultClient)]
    }

    /// Tells the browser which link the pointer is over, for the link preview in the corner.
    static let linkHover = """
    (() => {
      let current = null;
      const send = (url) => {
        if (url === current) return;
        current = url;
        try { window.webkit.messageHandlers.zigzagHover.postMessage(url || ''); } catch (e) {}
      };
      document.addEventListener('mouseover', (e) => {
        const a = e.target && e.target.closest ? e.target.closest('a[href], area[href]') : null;
        send(a ? a.href : null);
      }, true);
      document.addEventListener('mouseout', (e) => { if (!e.relatedTarget) send(null); }, true);
      window.addEventListener('blur', () => send(null));
      window.addEventListener('pagehide', () => send(null));
    })();
    """

    /// A small picture-in-picture button over a video while the pointer is on it. Clicking it is a real click in
    /// the page, which is what WebKit asks for before a video may float. Kept out of the page's way: its own
    /// shadow root, no effect on layout, and nothing for short clips, tiny videos or sites that opt out.
    static let pictureInPicture = """
    (() => {
      if (!document.pictureInPictureEnabled && !HTMLVideoElement.prototype.webkitSetPresentationMode) return;
      let host, button, target, hideTimer;
      const eligible = (v) => v && !v.disablePictureInPicture && !v.hasAttribute('disablepictureinpicture')
        && v.readyState > 0 && (v.duration > 15 || v.duration === Infinity) && v.clientWidth >= 200 && v.clientHeight >= 112;
      const build = () => {
        host = document.createElement('zigzag-pip');
        host.style.cssText = 'position:fixed;z-index:2147483647;top:0;left:0;width:0;height:0;pointer-events:none';
        const root = host.attachShadow({ mode: 'closed' });
        root.innerHTML = `<style>
          button { pointer-events: auto; position: fixed; display: flex; align-items: center; gap: 6px; height: 28px; padding: 0 10px;
            border: 0; border-radius: 14px; background: rgba(28,28,30,.72); color: #fff; font: 500 12px -apple-system, system-ui;
            -webkit-backdrop-filter: blur(20px) saturate(1.6); backdrop-filter: blur(20px) saturate(1.6);
            opacity: 0; transform: translateY(-2px); transition: opacity .15s ease, transform .15s ease; cursor: default; }
          button.shown { opacity: 1; transform: none; }
          button:hover { background: rgba(28,28,30,.86); }
          svg { width: 14px; height: 14px; }
        </style><button aria-label="Picture in Picture"><svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4">
          <rect x="1.5" y="2.5" width="13" height="10" rx="2"/><rect x="8" y="7.5" width="5" height="3.5" rx="1" fill="currentColor" stroke="none"/></svg>Picture in Picture</button>`;
        button = root.querySelector('button');
        button.addEventListener('click', async (e) => {
          e.preventDefault(); e.stopPropagation();
          const v = target;
          hide();
          if (!v) return;
          try {
            if (document.pictureInPictureElement === v) await document.exitPictureInPicture();
            else if (v.requestPictureInPicture) await v.requestPictureInPicture();
            else v.webkitSetPresentationMode(v.webkitPresentationMode === 'picture-in-picture' ? 'inline' : 'picture-in-picture');
          } catch (err) {
            try { v.webkitSetPresentationMode('picture-in-picture'); } catch (e2) {}
          }
        }, true);
        button.addEventListener('mouseenter', () => clearTimeout(hideTimer));
        (document.body || document.documentElement).appendChild(host);
      };
      const place = (v) => {
        const r = v.getBoundingClientRect();
        button.style.top = Math.max(8, r.top + 10) + 'px';
        button.style.left = (r.right - button.offsetWidth - 10) + 'px';
      };
      const show = (v) => {
        if (!host || !host.isConnected) build();
        target = v;
        clearTimeout(hideTimer);
        place(v);
        button.classList.add('shown');
      };
      const hide = () => { if (button) button.classList.remove('shown'); target = null; };
      document.addEventListener('mousemove', (e) => {
        if (host && e.composedPath().includes(host)) return;
        const v = (e.target && e.target.closest) ? e.target.closest('video') : null;
        const under = v || (target && (() => { const r = target.getBoundingClientRect();
          return e.clientX >= r.left && e.clientX <= r.right && e.clientY >= r.top && e.clientY <= r.bottom ? target : null; })())
          || [...document.querySelectorAll('video')].find((x) => { const r = x.getBoundingClientRect();
          return e.clientX >= r.left && e.clientX <= r.right && e.clientY >= r.top && e.clientY <= r.bottom; });
        if (eligible(under)) show(under);
        else if (target) { clearTimeout(hideTimer); hideTimer = setTimeout(hide, 400); }
      }, { passive: true, capture: true });
      document.addEventListener('scroll', () => { if (target) place(target); }, { passive: true, capture: true });
    })();
    """

    /// Collects the page's declared icons, best first.
    static let iconLinks = """
    (() => {
      const links = Array.from(document.querySelectorAll('link[rel~="icon"], link[rel="shortcut icon"], link[rel="apple-touch-icon"], link[rel="apple-touch-icon-precomposed"]'));
      return links.map(l => ({ href: l.href, sizes: l.getAttribute('sizes') || '', rel: l.rel, type: l.type || '' }));
    })();
    """
}

/// Receives messages from our page scripts and routes them to the tab that sent them.
final class PageMessages: NSObject, WKScriptMessageHandler {
    static let shared = PageMessages()

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "zigzagHover", let webView = message.webView as? BrowserWebView, let tab = webView.owner else { return }
        let text = message.body as? String ?? ""
        tab.hoveredLinkChanged(text.isEmpty ? nil : URL(string: text))
    }
}
