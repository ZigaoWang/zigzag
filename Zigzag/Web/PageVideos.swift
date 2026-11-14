import Foundation
import WebKit

/// Every frame says which videos it has and how they're playing, in Zigzag's own script world (the page can't see
/// it): as a video starts, stops or changes size, and as the page scrolls while one plays. A page with no video never
/// says anything. While its tab is in the mini player, the frame with its video reports four times a second, so the
/// card follows the video and its time. The mini player plays, pauses and seeks through the same script.
final class PageVideos: NSObject, WKScriptMessageHandler {
    static let shared = PageVideos()
    static let messageName = "zigzagVideo"

    static let script = WKUserScript(source: """
    (() => {
      if (window.__zigzagVideos) return;
      const id = Math.random().toString(36).slice(2);
      const main = window === window.top;
      const post = (m) => { try { window.webkit.messageHandlers.\(messageName).postMessage(m); } catch (e) {} };
      let list = [], last = '[]', timer = 0, ticking = 0, saved = null;
      // The videos you started or changed the sound of yourself: one that plays or changes volume within a second of
      // your own press or key on the page. A press on a link goes somewhere rather than plays, so it doesn't count:
      // a card's preview playing under the pointer as you click through to its page isn't one you started.
      const started = new WeakSet();
      let pressed = -Infinity;
      const press = (e) => {
        if (!e.isTrusted) return;
        const t = e.target;
        if (t && t.closest && t.closest('a[href]')) return;
        pressed = performance.now();
      };
      addEventListener('pointerdown', press, true);
      addEventListener('keydown', press, true);
      const engage = (e) => { if (e.target && e.target.tagName === 'VIDEO' && performance.now() - pressed < 1000) started.add(e.target); };
      const describe = () => {
        list = Array.from(document.querySelectorAll('video')).slice(0, 12);
        return list.map((v, i) => {
          const r = v.getBoundingClientRect();
          return { i, x: r.left, y: r.top, w: r.width, h: r.height, vw: v.videoWidth, vh: v.videoHeight,
                   playing: !v.paused && !v.ended && v.readyState >= 2, ended: v.ended, muted: v.muted || v.volume === 0,
                   loop: v.loop, autoplay: v.autoplay, controls: v.controls, user: started.has(v), link: !!v.closest('a[href]'), fit: getComputedStyle(v).objectFit || 'contain',
                   t: v.currentTime || 0, d: isFinite(v.duration) ? v.duration : -1 };
        });
      };
      const report = (always) => {
        const videos = describe();
        const pip = !!document.pictureInPictureElement || list.some((v) => v.webkitPresentationMode === 'picture-in-picture');
        const fs = !!(document.fullscreenElement || document.webkitFullscreenElement);
        // Nothing to say on a page with no video, however it resizes.
        const key = videos.length === 0 && !pip && !fs ? '[]'
          : JSON.stringify(videos.map((v) => [v.x | 0, v.y | 0, v.w | 0, v.h | 0, v.vw, v.vh, v.playing, v.ended, v.muted, v.user])) + pip + fs + innerWidth + 'x' + innerHeight;
        if (!always && key === last) return;
        last = key;
        post({ id, main, vw: innerWidth, vh: innerHeight, videos, pip, fs });
      };
      const soon = () => { if (!timer) timer = setTimeout(() => { timer = 0; report(false); }, 150); };
      document.addEventListener('play', engage, true);
      document.addEventListener('volumechange', engage, true);
      for (const kind of ['play', 'playing', 'pause', 'ended', 'emptied', 'loadedmetadata', 'resize', 'volumechange',
                          'enterpictureinpicture', 'leavepictureinpicture', 'webkitpresentationmodechanged']) {
        document.addEventListener(kind, soon, true);
      }
      addEventListener('scroll', () => { if (list.some((v) => !v.paused)) soon(); }, { capture: true, passive: true });
      addEventListener('resize', soon);
      document.addEventListener('fullscreenchange', soon);
      document.addEventListener('webkitfullscreenchange', soon);
      addEventListener('pagehide', () => { last = '[]'; post({ id, main, vw: innerWidth, vh: innerHeight, videos: [], gone: true }); });
      const finite = (v) => v && isFinite(v.duration);
      const mark = 'data-zigzag-mini';
      const css = `:not([${mark}]) { visibility: hidden !important; }
        [${mark}]::before, [${mark}]::after { visibility: hidden !important; }
        [${mark}="path"] { background: #000 !important; color: transparent !important; border-color: transparent !important;
          box-shadow: none !important; outline: none !important; text-shadow: none !important; scrollbar-width: none !important; }
        [${mark}="video"]::-webkit-media-controls { display: none !important; }`;
      let isolated = null;
      const unisolate = () => {
        if (!isolated) return false;
        for (const [e, before] of isolated.marked) { if (before === null) e.removeAttribute(mark); else e.setAttribute(mark, before); }
        isolated.styles.forEach((s) => s.remove());
        // The video's own controls back, where they were among its attributes: the ones after it go behind it again.
        const c = isolated.controls;
        if (c && !c.attr.ownerElement && !c.target.hasAttribute('controls')) {
          c.target.setAttributeNode(c.attr);
          for (const a of c.after) if (a.ownerElement === c.target) { c.target.removeAttributeNode(a); c.target.setAttributeNode(a); }
        }
        isolated = null;
        return true;
      };
      const alone = (target) => {
        if (!target) return false;
        // Still alone where it was: nothing to do. Moved (a player laid out again elsewhere), it's done afresh.
        let whole = isolated && isolated.target === target && target.getAttribute(mark) === 'video';
        for (let e = target.parentElement; whole && e; e = e.parentElement) whole = e.getAttribute(mark) === 'path';
        if (whole && target.isConnected) return true;
        unisolate();
        const marked = [], styles = [];
        // A video with the browser's own controls would show them over the card when paused, and no style reaches
        // WebKit's newer ones: they're turned off while it's in the card (#230). Not when a src comes after them,
        // as putting that back in its place would load the video again.
        let controls = null;
        const attr = target.localName === 'video' ? target.getAttributeNode('controls') : null;
        if (attr) {
          const all = Array.from(target.attributes);
          const after = all.slice(all.indexOf(attr) + 1);
          if (!after.some((a) => a.name === 'src')) { controls = { target, attr, after }; target.removeAttributeNode(attr); }
        }
        const put = (e, value) => { marked.push([e, e.getAttribute(mark)]); e.setAttribute(mark, value); };
        const style = document.createElement('style');
        style.setAttribute(mark, 'style');
        style.textContent = css;
        document.documentElement.appendChild(style);
        styles.push(style);
        put(target, 'video');
        for (let e = target.parentElement; e; e = e.parentElement) put(e, 'path');
        isolated = { target, marked, styles, controls };
        return true;
      };
      window.__zigzagVideos = {
        report: () => { report(true); return true; },
        watch: (on) => { clearInterval(ticking); ticking = on ? setInterval(() => report(true), 250) : 0; if (on) report(true); return true; },
        toggle: (i) => {
          const v = list[i];
          if (!v) return null;
          if (v.paused || v.ended) { v.play().catch(() => {}); } else { v.pause(); }
          return true;
        },
        pause: (i) => { if (list[i]) list[i].pause(); return true; },
        seek: (i, by) => { const v = list[i]; if (finite(v)) v.currentTime = Math.max(0, Math.min(v.duration, v.currentTime + by)); return true; },
        seekTo: (i, f) => { const v = list[i]; if (finite(v)) v.currentTime = Math.max(0, Math.min(1, f)) * v.duration; return true; },
        // Into view if it's partly out of it (you scrolled on to the comments), where you were kept for coming back.
        reveal: (i) => {
          const v = list[i];
          if (!v) return false;
          const r = v.getBoundingClientRect();
          if (r.top >= 0 && r.left >= 0 && r.bottom <= innerHeight && r.right <= innerWidth) return false;
          const spots = [];
          for (let e = v.parentElement; e; e = e.parentElement) {
            if (e.scrollHeight > e.clientHeight || e.scrollWidth > e.clientWidth) spots.push([e, e.scrollLeft, e.scrollTop]);
          }
          saved = { x: scrollX, y: scrollY, spots };
          v.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
          report(true);
          return true;
        },
        restore: () => {
          if (!saved) return false;
          for (const [e, x, y] of saved.spots) { e.scrollLeft = x; e.scrollTop = y; }
          scrollTo(saved.x, saved.y);
          saved = null;
          return true;
        },
        // Only the video shows while it's in the mini player: everything else on the page (the site's own player
        // controls, its title and end cards, the article around it) is made invisible, without moving or resizing
        // anything, so the page never reflows. The video and the elements it sits in stay, the latter on black.
        // Called as often as the page reports; the same video again changes nothing.
        isolate: (i) => alone(list[i]),
        // A frame's video: the frame itself is what stays, found by where its content starts. A video's own controls
        // (its controls attribute) are hidden by the style too: the card has its own.
        isolateFrame: (x, y) => alone(Array.from(document.querySelectorAll('iframe')).find((f) => {
          const r = f.getBoundingClientRect();
          return Math.abs(r.left + f.clientLeft - x) <= 2 && Math.abs(r.top + f.clientTop - y) <= 2;
        })),
        // Everything exactly as it was: no marks, no style.
        unisolate: () => unisolate(),
        isolated: () => !!isolated,
        // The page's frames as it lays them out, so a frame's videos can be placed in it.
        frames: () => Array.from(document.querySelectorAll('iframe')).map((f) => {
          const r = f.getBoundingClientRect();
          let host = '';
          try { host = new URL(f.src, location.href).host; } catch (e) {}
          return [r.left + f.clientLeft, r.top + f.clientTop, f.clientWidth, f.clientHeight, host];
        }),
      };
    })();
    """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient)

    /// What one frame last said.
    struct Frame {
        let id: String
        var info: WKFrameInfo
        var isMain: Bool
        /// Its viewport, in CSS pixels.
        var viewport: CGSize
        var videos: [PageVideo]
        var pictureInPicture: Bool
        var fullScreen: Bool
    }

    private struct Entry {
        weak var webView: WKWebView?
        var frames: [String: Frame] = [:]
    }
    private var entries: [ObjectIdentifier: Entry] = [:]
    /// A page said something new about its videos.
    let reported = Signal<WKWebView>()

    func frames(in webView: WKWebView) -> [Frame] {
        guard let entry = entries[ObjectIdentifier(webView)], entry.webView === webView else { return [] }
        return Array(entry.frames.values)
    }

    /// The video that would follow you out of this page, and the frame it's in: one you were watching. `any`: any
    /// video playing a picture, for a page the mini player already has.
    func playing(in webView: WKWebView, any: Bool = false) -> (frame: Frame, video: PageVideo)? {
        let all = frames(in: webView)
        return MiniPlayerLayout.best(in: all.map { ($0.viewport, $0.videos) }, by: any ? MiniPlayerLayout.plays : MiniPlayerLayout.follows)
            .map { (frame: all[$0.frame], video: $0.video) }
    }

    /// The video leaving this page takes along, by `MiniPlayerLayout.followed`.
    func followed(in webView: WKWebView, leavingPage: Bool) -> (frame: Frame, video: PageVideo)? {
        let all = frames(in: webView)
        return MiniPlayerLayout.followed(in: all.map { ($0.viewport, $0.videos) }, leavingPage: leavingPage, presentingItself: isPresentingItself(webView))
            .map { (frame: all[$0.frame], video: $0.video) }
    }

    /// The page floats a video in Picture in Picture, or shows one in full screen, itself.
    func isPresentingItself(_ webView: WKWebView) -> Bool {
        webView.isPictureInPictureActive || webView.fullscreenState != .notInFullscreen
            || frames(in: webView).contains { $0.pictureInPicture || $0.fullScreen }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.messageName, let webView = message.webView, let body = message.body as? [String: Any],
              let id = body["id"] as? String else { return }
        // Closed pages are let go of here.
        entries = entries.filter { $0.value.webView != nil }
        let key = ObjectIdentifier(webView)
        var entry = entries[key].flatMap { $0.webView === webView ? $0 : nil } ?? Entry(webView: webView)
        let isMain = message.frameInfo.isMainFrame
        if body["gone"] as? Bool == true {
            // A page going away takes its frames with it.
            if isMain { entry.frames = [:] } else { entry.frames[id] = nil }
        } else {
            let videos = (body["videos"] as? [Any] ?? []).compactMap(PageVideo.init)
            func number(_ key: String) -> CGFloat { CGFloat((body[key] as? NSNumber)?.doubleValue ?? 0) }
            entry.frames[id] = Frame(id: id, info: message.frameInfo, isMain: isMain, viewport: CGSize(width: number("vw"), height: number("vh")),
                                     videos: videos, pictureInPicture: body["pip"] as? Bool ?? false, fullScreen: body["fs"] as? Bool ?? false)
        }
        // Many ad frames come and go; the newest few dozen are plenty.
        if entry.frames.count > 32, let drop = entry.frames.values.first(where: { !$0.isMain && $0.videos.isEmpty }) { entry.frames[drop.id] = nil }
        entries[key] = entry
        // A video gone into Picture in Picture, by the page's own button or WebKit's: its window floats (#210).
        if body["pip"] as? Bool == true { PictureInPicture.floatSoon() }
        reported.send(webView)
    }

    // MARK: Commands

    /// Runs one of the script's commands in the frame (nil: the page itself, whether or not it has said anything),
    /// with its arguments in order.
    @discardableResult
    func run(_ command: String, _ arguments: [(String, Any)] = [], in frame: Frame?, of webView: WKWebView) async -> Any? {
        let names = arguments.map(\.0).joined(separator: ", ")
        let source = "return window.__zigzagVideos ? window.__zigzagVideos.\(command)(\(names)) : null;"
        let values = Dictionary(arguments, uniquingKeysWith: { a, _ in a })
        return try? await webView.callAsyncJavaScript(source, arguments: values, in: frame?.info, contentWorld: .defaultClient)
    }

    /// Where a frame's viewport starts in the page, in CSS pixels: none for the page itself.
    func origin(of frame: Frame, in webView: WKWebView) async -> CGPoint? {
        if frame.isMain { return .zero }
        // The page itself is asked, whether or not it has said anything (it may have no video of its own).
        guard let list = try? await webView.callAsyncJavaScript("return window.__zigzagVideos ? window.__zigzagVideos.frames() : [];",
                                                               arguments: [:], in: nil, contentWorld: .defaultClient) as? [[Any]] else { return nil }
        return Self.origin(of: frame, among: list)
    }

    private static func origin(of frame: Frame, among list: [[Any]]) -> CGPoint? {
        let frames = list.compactMap { item -> (rect: CGRect, host: String)? in
            guard item.count == 5 else { return nil }
            let n = item.prefix(4).map { ($0 as? NSNumber)?.doubleValue ?? 0 }
            return (CGRect(x: n[0], y: n[1], width: n[2], height: n[3]), item[4] as? String ?? "")
        }
        return MiniPlayerLayout.frameOrigin(viewport: frame.viewport, host: frame.info.securityOrigin.host, among: frames)
    }
}
