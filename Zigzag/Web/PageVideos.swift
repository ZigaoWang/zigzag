import Foundation
import WebKit

/// Every frame says which videos it has and how they're playing, in Zigzag's own script world (the page can't see
/// it): as a video starts, stops or changes size, as its sound or an audio's starts or stops, and as the page scrolls
/// while one plays. A page with no video or sound never says anything. While its tab is in the mini player, the frame with its video reports four times a second, so the
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
                   loop: v.loop, autoplay: v.autoplay, controls: v.controls, user: started.has(v), link: !!v.closest('a[href]'), nopip: !!v.disablePictureInPicture, fit: getComputedStyle(v).objectFit || 'contain',
                   t: v.currentTime || 0, d: isFinite(v.duration) ? v.duration : -1 };
        });
      };
      // A video or audio on the page playing with its sound on.
      const sounding = () => Array.from(document.querySelectorAll('video, audio'))
        .some((m) => !m.paused && !m.ended && !m.muted && m.volume > 0);
      const report = (always) => {
        const videos = describe();
        const pip = !!document.pictureInPictureElement || list.some((v) => v.webkitPresentationMode === 'picture-in-picture');
        const fs = !!(document.fullscreenElement || document.webkitFullscreenElement);
        const sound = sounding();
        // Nothing to say on a page with no video or sound, however it resizes.
        const key = videos.length === 0 && !pip && !fs && !sound ? '[]'
          : JSON.stringify(videos.map((v) => [v.x | 0, v.y | 0, v.w | 0, v.h | 0, v.vw, v.vh, v.playing, v.ended, v.muted, v.user])) + pip + fs + sound + innerWidth + 'x' + innerHeight;
        if (!always && key === last) return;
        last = key;
        post({ id, main, vw: innerWidth, vh: innerHeight, videos, pip, fs, sound });
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
        // Restores the controls attribute in its original position, reinserting the attributes after it.
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
        // Native controls would show over the card when paused, and no style reaches WebKit's newer ones, so they're
        // off while in the card (#230). Not when a src follows them, since restoring that would reload the video.
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
        /// A video or audio in it plays with its sound on.
        var playsSound: Bool
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

    /// A video or audio in one of the page's frames plays with its sound on.
    func playsSound(in webView: WKWebView) -> Bool {
        frames(in: webView).contains(where: \.playsSound)
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
                                     videos: videos, pictureInPicture: body["pip"] as? Bool ?? false, fullScreen: body["fs"] as? Bool ?? false,
                                     playsSound: body["sound"] as? Bool ?? false)
        }
        // Many ad frames come and go; the newest few dozen are plenty.
        if entry.frames.count > 32, let drop = entry.frames.values.first(where: { !$0.isMain && $0.videos.isEmpty && !$0.playsSound }) { entry.frames[drop.id] = nil }
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
        guard let list = try? await webView.runOwnScript("return window.__zigzagVideos ? window.__zigzagVideos.frames() : [];", asFunction: true,
                                                               world: .defaultClient) as? [[Any]] else { return nil }
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

/// A page's own previous and next, as it sets them through the Media Session API
/// (`navigator.mediaSession.setActionHandler('previoustrack' / 'nexttrack')`), for the mini player's Previous and
/// Next buttons, as Safari's and Chrome's picture in picture windows offer them (#565). WebKit keeps a page's handlers
/// where no other world can read them, so a script in the page's own world notes them as the page sets them and runs
/// them when asked; the page's calls go through unchanged. Each frame has its own.
final class MediaSessionActions: NSObject, WKScriptMessageHandler {
    static let shared = MediaSessionActions()
    static let messageName = "zigzagMediaSession"

    enum Action: String, CaseIterable, Sendable {
        case previous = "previoustrack"
        case next = "nexttrack"
    }

    /// A frame of the page set or took away one of the two.
    let changed = Signal<WKWebView>()

    static let script = WKUserScript(source: """
    (() => {
      const key = Symbol.for('zigzag.mediaSession');
      if (window[key] || typeof MediaSession === 'undefined' || !MediaSession.prototype.setActionHandler) return;
      const watched = ['previoustrack', 'nexttrack'];
      const handlers = new Map();
      const apply = Reflect.apply;
      const tell = () => { try { window.webkit.messageHandlers.\(messageName).postMessage(true); } catch (e) {} };
      MediaSession.prototype.setActionHandler = new Proxy(MediaSession.prototype.setActionHandler, {
        apply(target, self, args) {
          const result = apply(target, self, args);
          const action = args[0], handler = args[1];
          if (watched.includes(action)) {
            const had = handlers.has(action);
            if (typeof handler === 'function') handlers.set(action, handler); else handlers.delete(action);
            if (had !== handlers.has(action)) tell();
          }
          return result;
        }
      });
      Object.defineProperty(window, key, { value: Object.freeze({
        actions: () => watched.filter((a) => handlers.has(a)),
        run: (action) => {
          const handler = handlers.get(action);
          if (!handler) return false;
          try { apply(handler, undefined, [{ action }]); } catch (e) {}
          return true;
        },
      }) });
    })();
    """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)

    static func attach(to controller: WKUserContentController) {
        controller.addUserScript(script)
        controller.add(shared, contentWorld: .page, name: messageName)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.messageName, let webView = message.webView else { return }
        changed.send(webView)
    }

    /// Which of the two the frame (nil: the page itself) has now. Asked without a user gesture: it reaches page code.
    func actions(in frame: WKFrameInfo?, of webView: WKWebView) async -> Set<Action> {
        let source = "const s = window[Symbol.for('zigzag.mediaSession')]; return s ? s.actions() : [];"
        let list = (try? await webView.runOwnScript(source, asFunction: true, in: frame, world: .page)) as? [Any] ?? []
        return Set(list.compactMap { ($0 as? String).flatMap(Action.init(rawValue:)) })
    }

    /// Runs the page's own handler, as a press of yours: it may start the next video. Returns whether it had one.
    @discardableResult
    func run(_ action: Action, in frame: WKFrameInfo?, of webView: WKWebView) async -> Bool {
        let source = "const s = window[Symbol.for('zigzag.mediaSession')]; return s ? s.run(action) : false;"
        let result = try? await webView.callAsyncJavaScript(source, arguments: ["action": action.rawValue], in: frame, contentWorld: .page)
        return result as? Bool ?? false
    }
}

/// Whether a tab plays sound, from what WebKit says (`_isPlayingAudio`) and whether a video or audio on the page plays
/// with its sound on. WebKit goes on saying a page plays sound once a video or audio whose sound goes through Web Audio
/// is paused (TikTok's player), for as long as the page keeps its audio context running. So a sound that started with
/// a video or audio playing is over once none plays, after `hold`; a sound that started without one (Web Audio, an
/// audio element not on the page) lasts as long as WebKit says.
nonisolated struct PageSound: Equatable {
    /// How long none plays before the sound counts as over.
    static let hold: TimeInterval = 1.5
    /// How long after WebKit starts saying so a video or audio starting still counts as where the sound came from.
    static let started: TimeInterval = 2

    private(set) var webKit = false
    private var fromMedia = false
    private var since: Date?
    private var mediaStopped: Date?

    /// Takes what WebKit says now and whether a video or audio plays with sound; answers whether the tab plays sound
    /// and, while that's about to change, when to ask again.
    mutating func update(webKit: Bool, media: Bool, now: Date = Date()) -> (playing: Bool, recheck: TimeInterval?) {
        guard webKit else {
            self = PageSound()
            return (false, nil)
        }
        if !self.webKit {
            self.webKit = true
            since = now
            fromMedia = media
        }
        if media, !fromMedia, let since, now.timeIntervalSince(since) < Self.started { fromMedia = true }
        guard fromMedia, !media else {
            mediaStopped = nil
            return (true, nil)
        }
        let stopped = mediaStopped ?? now
        mediaStopped = stopped
        let quiet = now.timeIntervalSince(stopped)
        return quiet >= Self.hold ? (false, nil) : (true, Self.hold - quiet)
    }
}
