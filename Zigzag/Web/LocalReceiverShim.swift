import Foundation
import WebKit

/// The page's side of the local-receiver door. It puts the page's own `fetch`, `XMLHttpRequest` and `WebSocket`
/// aside for a loopback address and asks Zigzag to make the call. The page cannot say who it is: native reads the
/// frame's own origin and the site's switch from Site Controls, and a site that is off gets the same failure WebKit's
/// block would have given it.
@MainActor
enum LocalReceiverShim {
    static let name = "localReceivers"

    /// Whether a page at `origin` may use this door: the Settings switch and the site's own. The script goes only
    /// into such pages, so every other page keeps WebKit's own `fetch`, `XMLHttpRequest` and `WebSocket` untouched
    /// (a localhost dev page keeps its own `/api` and HMR socket), and nothing of this door is visible to it.
    @MainActor
    static func serves(origin: String) -> Bool {
        LocalReceivers.allowsSite(origin: origin)
    }

    /// Adds the page script and the handler that answers it, for a page at `origin` the person has allowed. Every
    /// other page keeps WebKit's own `fetch`, `XMLHttpRequest` and `WebSocket` untouched. A page made by another page
    /// gets them too; an extension's own page and a private tab do not. The handler comes back so the tab can end a
    /// page's sockets when it leaves.
    @discardableResult
    static func attach(to configuration: WKWebViewConfiguration, tab: Tab, origin: String? = nil,
                       isPrivate: Bool) -> LocalReceiverMessages? {
        let controller = configuration.userContentController
        // The script is per page, not per tab: a page that navigates to another site is decided again.
        guard !controller.userScripts.contains(where: { $0.source.hasPrefix(marker) }) else { return nil }
        guard !isPrivate, tab.profile.getsYourData, let origin, serves(origin: origin) else { return nil }
        let messages = LocalReceiverMessages(tab: tab)
        controller.addScriptMessageHandler(messages, contentWorld: .page, name: name)
        controller.addUserScript(WKUserScript(source: source(for: origin), injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: .page))
        return messages
    }

    /// Puts the door in, or takes it out, for the page a web view is about to be or has just become. `origin` is where
    /// it is going (or went). `owns` says this tab made the web view's configuration: a page WebKit opened for another
    /// page shares its opener's script and handler, so its controller is left alone, and the script's own origin check
    /// keeps it inert on any page that isn't the one it was put in for.
    ///
    /// At the navigation decision the new page has not started, so a script added here is in place before its own code
    /// runs. At commit the same call confirms what landed; a page that left the site it was allowed on has the script
    /// and the handler taken out, so it keeps WebKit's own `fetch`, `XMLHttpRequest` and `WebSocket`.
    @discardableResult
    static func sync(_ webView: WKWebView?, tab: Tab, origin: String?, isPrivate: Bool, owns: Bool,
                     current: LocalReceiverMessages?) -> LocalReceiverMessages? {
        // A page WebKit opened for another shares its opener's controller: nothing here may change it, and the script's
        // own origin check keeps it inert on the page that isn't the one it was put in for.
        guard let webView, owns else { return current }
        return sync(controller: webView.configuration.userContentController, tab: tab, origin: origin,
                    isPrivate: isPrivate, current: current)
    }

    /// The same, on a controller alone: what a test drives, and what the web view version delegates to. Without a tab
    /// no handler is added, so a test can watch the scripts and the handler's absence without a window.
    @discardableResult
    static func sync(controller: WKUserContentController, tab: Tab?, origin: String?, isPrivate: Bool,
                     current: LocalReceiverMessages? = nil) -> LocalReceiverMessages? {
        // Never in AI apps' pages: the switch is yours (`Profile.getsYourData`).
        guard !isPrivate, tab?.profile.getsYourData != false, let origin, serves(origin: origin) else {
            // The page has left the site it was allowed on (or is private): the script and the handler go, so the
            // page it becomes keeps WebKit's own fetch, XHR and WebSocket, with nothing of this door in reach.
            current?.closeAllSockets()
            OwnScripts.remove(from: controller, where: { $0.source.hasPrefix(marker) })
            controller.removeScriptMessageHandler(forName: name, contentWorld: .page)
            return nil
        }
        // One script, for this origin: an older page's script is not this page's door.
        let wanted = source(for: origin)
        OwnScripts.remove(from: controller, where: { $0.source.hasPrefix(marker) && $0.source != wanted })
        if !controller.userScripts.contains(where: { $0.source == wanted }) {
            controller.addUserScript(WKUserScript(source: wanted, injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: true, in: .page))
        }
        if let current { return current }
        guard let tab else { return nil }
        let messages = LocalReceiverMessages(tab: tab)
        controller.addScriptMessageHandler(messages, contentWorld: .page, name: name)
        return messages
    }

    /// The page script for one origin: it installs only in that origin's page.
    static func source(for origin: String) -> String {
        sourceTemplate.replacingOccurrences(of: "__ZIGZAG_SERVED_ORIGIN__", with: quoted(origin))
    }

    /// `text` as a JavaScript string literal, so an origin can't end the string it is written into.
    private static func quoted(_ text: String) -> String {
        // No escaped slashes: the script reads `"https://…"`, not `"https:\/\/…"`, so it can be compared as it
        // is written and read by anyone looking at it.
        let data = (try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes]))
            ?? Data("[]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    private static let marker = "/* zigzag local receivers */"

    private static let sourceTemplate = #"""
    /* zigzag local receivers */
    (() => {
      // Only the page this script was put in for: one left in a tab that has moved on, or handed to a page WebKit
      // opened for another, installs nothing anywhere else.
      if (location.origin !== __ZIGZAG_SERVED_ORIGIN__) return;
      if (window.__zigzagLocalReceivers) return;
      const messages = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.localReceivers;
      if (!messages) return;
      // Looked up per call: a page back from the back-forward cache gets a new handler.
      const door = () => window.webkit.messageHandlers.localReceivers || messages;
      // Not a page-visible name to enumerate or copy: the script only marks that it has already run.
      Object.defineProperty(window, '__zigzagLocalReceivers', { value: true, configurable: true });
      const nativeFetch = window.fetch.bind(window);

      // This Mac by the names loopback is reached by; http only, because that is what WebKit blocks from https.
      const isLoopback = (url) => {
        if (url.protocol !== 'http:') return false;
        let host = url.hostname.toLowerCase();
        if (host.startsWith('[') && host.endsWith(']')) host = host.slice(1, -1);
        if (host.endsWith('.')) host = host.slice(0, -1);
        if (host === 'localhost' || host.endsWith('.localhost')
            || host === '::1' || host === '0:0:0:0:0:0:0:1') return true;
        const parts = host.split('.');
        return parts.length === 4 && parts.every((p) => /^\d{1,3}$/.test(p) && Number(p) <= 255)
          && parts[0] === '127';
      };

      const encode = (buffer) => {
        const bytes = new Uint8Array(buffer);
        let binary = '';
        for (let i = 0; i < bytes.length; i += 0x8000) {
          binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
        }
        return btoa(binary);
      };
      const decode = (text) => {
        const binary = atob(text);
        const bytes = new Uint8Array(binary.length);
        for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
        return bytes;
      };
      const failed = () => new TypeError('Load failed');
      const aborted = () => new DOMException('The user aborted a request.', 'AbortError');

      window.fetch = async (input, init) => {
        // Where it goes is read first: making a Request from another one takes its body, which WebKit's fetch needs.
        let url;
        try { url = new URL(input instanceof Request ? input.url : String(input), location.href); } catch (error) { return nativeFetch(input, init); }
        if (!isLoopback(url)) return nativeFetch(input, init);
        let request;
        try { request = new Request(input, init); } catch (error) { return nativeFetch(input, init); }
        if (request.mode === 'no-cors' || request.mode === 'navigate' || request.redirect === 'manual') {
          return nativeFetch(input, init);
        }
        if (request.signal.aborted) throw aborted();
        let body = null;
        try {
          if (request.method !== 'GET' && request.method !== 'HEAD') {
            body = encode(await request.arrayBuffer());
          }
        } catch (error) {
          return nativeFetch(input, init);
        }
        let answer;
        try {
          answer = await door().postMessage({
            kind: 'fetch', url: request.url, method: request.method,
            headers: Array.from(request.headers), body, credentials: request.credentials,
          });
        } catch (error) {
          throw failed();
        }
        if (request.signal.aborted) throw aborted();
        if (!answer || answer.error) throw failed();
        const noBody = answer.status === 204 || answer.status === 205 || answer.status === 304;
        const response = new Response(noBody ? null : decode(answer.body), {
          status: answer.status, statusText: answer.statusText, headers: answer.headers,
        });
        Object.defineProperties(response, {
          url: { value: answer.url },
          redirected: { value: answer.redirected },
          type: { value: 'cors' },
        });
        return response;
      };

      // XMLHttpRequest to this Mac, over the same door. Everything else keeps WebKit's own XHR, and a synchronous
      // request is left to WebKit: it cannot be answered from here.
      const NativeXHR = window.XMLHttpRequest;
      const xhrEvents = ['readystatechange', 'loadstart', 'progress', 'load', 'error', 'abort', 'timeout', 'loadend'];
      class LocalXHR {
        constructor() {
          this.native = new NativeXHR();
          this._loopback = false;
          this._listeners = Object.create(null);
          this._handlers = Object.create(null);
          this._ready = 0;
          this._status = 0;
          this._statusText = '';
          this._body = null;
          this._headers = null;
          this._responseType = '';
          this._responseURL = '';
          this._timedOut = false;
          this._aborted = false;
          this._sent = false;
          this._timeout = 0;
          this._withCredentials = false;
          this._upload = { addEventListener() {}, removeEventListener() {}, onprogress: null, onload: null, onerror: null };
          // The native object's own events go to the same listeners while this is a real request.
          for (const type of xhrEvents) {
            this.native.addEventListener(type, (event) => { if (!this._loopback) this._emit(type, event); });
          }
        }
        // A real request's upload is WebKit's own, so progress reaches the page as before; a loopback call has none.
        get upload() { return this._loopback ? this._upload : this.native.upload; }
        get readyState() { return this._loopback ? this._ready : this.native.readyState; }
        get status() { return this._loopback ? this._status : this.native.status; }
        get statusText() { return this._loopback ? this._statusText : this.native.statusText; }
        get responseURL() { return this._loopback ? this._responseURL : this.native.responseURL; }
        get responseType() { return this._loopback ? this._responseType : this.native.responseType; }
        set responseType(value) {
          if (this._loopback) this._responseType = value; else this.native.responseType = value;
        }
        get timeout() { return this._loopback ? this._timeout : this.native.timeout; }
        set timeout(value) { this._timeout = value; this.native.timeout = value; }
        get withCredentials() { return this._loopback ? this._withCredentials : this.native.withCredentials; }
        set withCredentials(value) { this._withCredentials = value; this.native.withCredentials = value; }
        get response() {
          if (!this._loopback) return this.native.response;
          if (this._responseType === '' || this._responseType === 'text') return this.responseText;
          if (this._responseType === 'json') {
            if (this._body === null) return null;
            try { return JSON.parse(new TextDecoder().decode(this._body)); } catch (error) { return null; }
          }
          if (this._responseType === 'document') return null;
          if (this._body === null) return null;
          if (this._responseType === 'arraybuffer') return this._body.buffer.slice(this._body.byteOffset, this._body.byteOffset + this._body.byteLength);
          if (this._responseType === 'blob') return new Blob([this._body], { type: this.getResponseHeader('content-type') || '' });
          return this._body;
        }
        get responseText() {
          if (!this._loopback) return this.native.responseText;
          if (this._responseType !== '' && this._responseType !== 'text') {
            throw new DOMException('The value is only accessible if the response type is text.', 'InvalidStateError');
          }
          if (this._body === null) return '';
          return new TextDecoder().decode(this._body);
        }
        get responseXML() { return this._loopback ? null : this.native.responseXML; }
        open(method, url, async = true, user, password) {
          this._loopback = false;
          this._ready = 0; this._status = 0; this._statusText = ''; this._body = null; this._headers = null;
          this._responseURL = ''; this._sent = false; this._aborted = false; this._timedOut = false;
          let target = null;
          try {
            const parsed = new URL(url, location.href);
            // Only an asynchronous request: a synchronous one has to block, which this side cannot do.
            if (async !== false && isLoopback(parsed)) target = parsed;
          } catch (error) { target = null; }
          if (!target) return this.native.open(method, url, async, user, password);
          this._loopback = true;
          this._request = {
            method: String(method || 'GET').toUpperCase(),
            url: target.href,
            headers: Object.create(null),
          };
          this._setState(1);
          return undefined;
        }
        setRequestHeader(name, value) {
          if (!this._loopback) return this.native.setRequestHeader(name, value);
          const key = String(name).toLowerCase();
          this._request.headers[key] = this._request.headers[key] ? this._request.headers[key] + ', ' + value : String(value);
        }
        overrideMimeType(type) { if (!this._loopback) this.native.overrideMimeType(type); }
        getResponseHeader(name) {
          if (!this._loopback) return this.native.getResponseHeader(name);
          if (!this._headers) return null;
          const key = String(name).toLowerCase();
          const found = this._headers.find((pair) => String(pair[0]).toLowerCase() === key);
          return found ? found[1] : null;
        }
        getAllResponseHeaders() {
          if (!this._loopback) return this.native.getAllResponseHeaders();
          if (!this._headers) return '';
          return this._headers.map((pair) => pair[0] + ': ' + pair[1]).join('\r\n') + '\r\n';
        }
        send(body) {
          if (!this._loopback) return this.native.send(body);
          if (this._ready !== 1 || this._sent) throw new DOMException('The object is in an invalid state.', 'InvalidStateError');
          this._sent = true;
          this._emit('loadstart', new ProgressEvent('loadstart'));
          const request = this._request;
          const run = async () => {
            let payload = null;
            let contentType = null;
            if (request.method !== 'GET' && request.method !== 'HEAD' && body != null) {
              if (typeof body === 'string') {
                payload = encode(new TextEncoder().encode(body).buffer);
                contentType = 'text/plain;charset=UTF-8';
              } else if (body instanceof URLSearchParams) {
                payload = encode(new TextEncoder().encode(body.toString()).buffer);
                contentType = 'application/x-www-form-urlencoded;charset=UTF-8';
              } else if (body instanceof Blob) {
                payload = encode(await body.arrayBuffer());
                contentType = body.type || null;
              } else if (body instanceof ArrayBuffer) {
                payload = encode(body);
              } else if (ArrayBuffer.isView(body)) {
                payload = encode(body.buffer.slice(body.byteOffset, body.byteOffset + body.byteLength));
              } else {
                payload = encode(new TextEncoder().encode(String(body)).buffer);
                contentType = 'text/plain;charset=UTF-8';
              }
            }
            const headers = Object.entries(request.headers);
            if (contentType && !request.headers['content-type']) headers.push(['content-type', contentType]);
            if (this.timeout > 0) {
              setTimeout(() => {
                if (this._ready === 4 || this._aborted) return;
                this._timedOut = true;
                this._finishError('timeout');
              }, this.timeout);
            }
            let answer;
            try {
              answer = await door().postMessage({
                kind: 'fetch', url: request.url, method: request.method,
                headers, body: payload, credentials: this.withCredentials ? 'include' : 'same-origin',
              });
            } catch (error) { answer = null; }
            if (this._aborted || this._timedOut || this._ready === 4) return;
            if (!answer || answer.error) { this._finishError('error'); return; }
            const noBody = answer.status === 204 || answer.status === 205 || answer.status === 304;
            const bytes = noBody ? new Uint8Array(0) : decode(answer.body || '');
            this._status = answer.status;
            this._statusText = answer.statusText || '';
            this._headers = answer.headers || [];
            this._body = bytes;
            this._responseURL = answer.url || request.url;
            this._setState(2);
            this._setState(3);
            this._setState(4);
            const event = new ProgressEvent('load', { loaded: bytes.length, total: bytes.length, lengthComputable: true });
            this._emit('load', event);
            this._emit('loadend', event);
          };
          run().catch(() => { if (!this._aborted && !this._timedOut) this._finishError('error'); });
        }
        abort() {
          if (!this._loopback) return this.native.abort();
          if (this._ready === 4) return;
          this._aborted = true;
          this._ready = 4;
          this._status = 0;
          this._statusText = '';
          this._emit('readystatechange', new Event('readystatechange'));
          this._emit('abort', new ProgressEvent('abort'));
          this._emit('loadend', new ProgressEvent('loadend'));
        }
        _setState(state) {
          this._ready = state;
          this._emit('readystatechange', new Event('readystatechange'));
        }
        _finishError(type) {
          if (this._ready === 4) return;
          this._ready = 4;
          this._status = 0;
          this._statusText = '';
          this._emit('readystatechange', new Event('readystatechange'));
          this._emit(type, new ProgressEvent(type));
          this._emit('loadend', new ProgressEvent('loadend'));
        }
        _emit(type, event) {
          const handler = this._handlers[type] || this['on' + type];
          if (typeof handler === 'function') {
            try { handler.call(this, event); } catch (error) { setTimeout(() => { throw error; }); }
          }
          for (const listener of (this._listeners[type] || []).slice()) {
            try { listener.call(this, event); } catch (error) { setTimeout(() => { throw error; }); }
          }
        }
        addEventListener(type, listener) {
          const list = this._listeners[type] || (this._listeners[type] = []);
          if (!list.includes(listener)) list.push(listener);
        }
        removeEventListener(type, listener) {
          const list = this._listeners[type];
          if (!list) return;
          const at = list.indexOf(listener);
          if (at >= 0) list.splice(at, 1);
        }
        dispatchEvent(event) { this._emit(event.type, event); return true; }
      }
      for (const [key, value] of Object.entries({ UNSENT: 0, OPENED: 1, HEADERS_RECEIVED: 2, LOADING: 3, DONE: 4 })) {
        LocalXHR[key] = value;
        LocalXHR.prototype[key] = value;
      }
      window.XMLHttpRequest = LocalXHR;

      // WebSocket to this Mac, over the same door. The page's own WebSocket stays for everything else.
      const NativeWebSocket = window.WebSocket;
      const sockets = Object.create(null);
      const held = Symbol('zigzagListeners');
      const wsURL = (value) => {
        try {
          const url = new URL(value, location.href);
          if (url.protocol !== 'ws:') return null;
          if (!isLoopback({ protocol: 'http:', hostname: url.hostname })) return null;
          return url;
        } catch (error) { return null; }
      };
      const encodeData = async (data) => {
        if (typeof data === 'string') return { text: data };
        if (data instanceof Blob) return { base64: encode(await data.arrayBuffer()) };
        if (data instanceof ArrayBuffer) return { base64: encode(data) };
        if (ArrayBuffer.isView(data)) {
          return { base64: encode(data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength)) };
        }
        return { text: String(data) };
      };
      window.__zigzagLocalSocketEvent = (id, event) => {
        const socket = sockets[id];
        if (socket) socket.dispatch(event);
      };
      class LocalWebSocket {
        constructor(url, protocols) {
          const target = wsURL(url);
          if (!target) return new NativeWebSocket(url, protocols);
          this.url = target.href;
          this.readyState = 0;
          this.protocol = '';
          this.extensions = '';
          this.bufferedAmount = 0;
          this.binaryType = 'blob';
          this.onopen = this.onmessage = this.onerror = this.onclose = null;
          this[held] = Object.create(null);
          const id = (window.crypto && crypto.randomUUID) ? crypto.randomUUID()
            : String(Date.now()) + String(Math.random()).slice(2);
          this.id = id;
          const list = protocols == null ? [] : (typeof protocols === 'string' ? [protocols] : Array.from(protocols));
          sockets[id] = this;
          door().postMessage({ kind: 'socket-open', id, url: this.url, protocols: list })
            .then((answer) => {
              if (!answer || answer.error) { this.fail(); return; }
              if (this.readyState !== 0) return;
              this.protocol = answer.protocol || '';
              this.readyState = 1;
              this.emit('open', new Event('open'));
            })
            .catch(() => this.fail());
        }
        emit(type, event) {
          const on = this['on' + type];
          if (typeof on === 'function') {
            try { on.call(this, event); } catch (error) { setTimeout(() => { throw error; }); }
          }
          const list = this[held][type];
          if (!list) return;
          for (const listener of list.slice()) {
            try { listener.call(this, event); } catch (error) { setTimeout(() => { throw error; }); }
          }
        }
        dispatch(event) {
          if (event.type === 'message') {
            const data = event.text != null ? event.text : binaryFor(this, event.base64 || '');
            this.emit('message', new MessageEvent('message', { data }));
          } else if (event.type === 'error') {
            this.emit('error', new Event('error'));
          } else if (event.type === 'close') {
            if (this.readyState === 3) return;
            // A socket that never opened gets error before close, as WebKit's does.
            if (this.readyState === 0) this.emit('error', new Event('error'));
            this.readyState = 3;
            delete sockets[this.id];
            this.emit('close', new CloseEvent('close', { code: event.code || 1006, reason: event.reason || '',
                                                         wasClean: event.clean === true }));
          }
        }
        fail() {
          if (this.readyState === 3) return;
          if (this.readyState !== 0) this.emit('error', new Event('error'));
          this.dispatch({ type: 'close', code: 1006, reason: '', clean: false });
        }
        addEventListener(type, listener) {
          const list = this[held][type] || (this[held][type] = []);
          if (!list.includes(listener)) list.push(listener);
        }
        removeEventListener(type, listener) {
          const list = this[held][type];
          if (!list) return;
          const at = list.indexOf(listener);
          if (at >= 0) list.splice(at, 1);
        }
        dispatchEvent(event) { this.emit(event.type, event); return true; }
        send(data) {
          if (this.readyState === 0) throw new DOMException('Still connecting', 'InvalidStateError');
          if (this.readyState !== 1) return;
          encodeData(data).then((payload) => {
            door().postMessage({ kind: 'socket-send', id: this.id, text: payload.text, base64: payload.base64 })
              .catch(() => this.fail());
          }).catch(() => this.fail());
        }
        close(code, reason) {
          if (this.readyState === 3) return;
          if (this.readyState === 0) { this.readyState = 2; return; }
          this.readyState = 2;
          door().postMessage({ kind: 'socket-close', id: this.id, code, reason })
            .catch(() => this.fail());
        }
      }
      const binaryFor = (socket, text) => {
        const bytes = decode(text);
        return socket.binaryType === 'arraybuffer' ? bytes.buffer : new Blob([bytes]);
      };
      for (const key of ['CONNECTING', 'OPEN', 'CLOSING', 'CLOSED']) {
        LocalWebSocket[key] = NativeWebSocket[key];
      }
      window.WebSocket = LocalWebSocket;
    })();
    """#
}

/// Answers one page's loopback calls, for the tab that page is in.
@MainActor
final class LocalReceiverMessages: NSObject, WKScriptMessageHandlerWithReply {
    private weak var tab: Tab?
    private var sockets: [String: LocalReceiverSocket] = [:]

    init(tab: Tab) {
        self.tab = tab
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let tab, message.frameInfo.isMainFrame,
              let origin = SiteOrigin.of(message.frameInfo.securityOrigin),
              !tab.isPrivate, tab.profile.getsYourData,
              LocalReceivers.allowsSite(origin: origin) else {
            replyHandler(["error": "denied"], nil)
            return
        }
        guard let body = message.body as? [String: Any] else {
            replyHandler(["error": "unknown"], nil)
            return
        }
        switch body["kind"] as? String {
        case "fetch":
            fetch(body, from: origin, webView: message.webView, reply: replyHandler)
        case "socket-open":
            openSocket(body, from: origin, webView: message.webView, reply: replyHandler)
        case "socket-send":
            guard let id = body["id"] as? String, let socket = sockets[id] else {
                replyHandler(["error": "unknown"], nil)
                return
            }
            socket.send(text: body["text"] as? String, base64: body["base64"] as? String)
            replyHandler(["ok": true], nil)
        case "socket-close":
            guard let id = body["id"] as? String, let socket = sockets[id] else {
                replyHandler(["error": "unknown"], nil)
                return
            }
            socket.close(code: body["code"] as? Int, reason: body["reason"] as? String)
            replyHandler(["ok": true], nil)
        default:
            replyHandler(["error": "unknown"], nil)
        }
    }

    /// Ends every socket this page opened: a page that is going away has nothing left to talk to.
    func closeAllSockets() {
        for socket in sockets.values { socket.cancelForNavigation() }
        sockets.removeAll()
    }

    private func openSocket(_ body: [String: Any], from origin: String, webView: WKWebView?,
                            reply: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let id = body["id"] as? String, let text = body["url"] as? String, let url = URL(string: text),
              url.scheme?.lowercased() == "ws", LocalReceivers.isLoopback(url), LocalReceivers.blockedPort(of: url) == nil else {
            reply(["error": "refused"], nil)
            return
        }
        let socket = LocalReceiverSocket(id: id, url: url, protocols: (body["protocols"] as? [String]) ?? [],
                                         origin: origin, webView: webView, reply: reply)
        track(socket, id: id)
    }

    /// Keeps a socket this page opened until it closes or the page goes.
    func track(_ socket: LocalReceiverSocket, id: String) {
        socket.onClose = { [weak self] id in self?.sockets[id] = nil }
        sockets[id] = socket
    }

    var openSocketCount: Int { sockets.count }

    private func fetch(_ body: [String: Any], from origin: String, webView: WKWebView?,
                       reply: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let text = body["url"] as? String, let url = URL(string: text), LocalReceivers.isLoopback(url) else {
            reply(["error": "refused"], nil)
            return
        }
        let credentials = Self.credentials(body["credentials"])
        var request = LocalReceivers.Request(url: url,
                                             method: (body["method"] as? String) ?? "GET",
                                             headers: Self.headers(body["headers"]),
                                             body: (body["body"] as? String).flatMap { Data(base64Encoded: $0) },
                                             credentials: credentials)
        Task { @MainActor in
            // The same store the page's own WebKit requests use, so a helper sees one set of cookies however it is
            // reached, and what it sets is kept for the page and the next call.
            let store = webView?.configuration.websiteDataStore
            if credentials.sendsCookies, let cookie = await LocalReceivers.cookies(for: url, in: store, crossSite: true) {
                request.headers["Cookie"] = cookie
            }
            do {
                let answer = try await LocalReceivers.send(request, as: .site(origin: origin))
                if credentials.sendsCookies { await LocalReceivers.store(answer, for: url, in: store) }
                reply(Self.reply(answer, to: request), nil)
            } catch {
                reply(["error": "failed"], nil)
            }
        }
    }

    /// The page's headers, without the ones only native code may set. The page's `Origin` is not its to choose.
    private static func headers(_ raw: Any?) -> [String: String] {
        guard let pairs = raw as? [[String]] else { return [:] }
        var out: [String: String] = [:]
        for pair in pairs where pair.count == 2 {
            let name = pair[0].lowercased()
            if ["host", "cookie", "origin", "referer", "content-length", "connection", "transfer-encoding",
                "upgrade", "keep-alive", "expect", "te", "trailer"].contains(name) { continue }
            if name.hasPrefix("proxy-") || name.hasPrefix("sec-") { continue }
            out[pair[0]] = pair[1]
        }
        return out
    }

    private static func credentials(_ raw: Any?) -> LocalReceivers.Credentials {
        switch raw as? String {
        case "omit": .omit
        case "include": .include
        default: .sameOrigin
        }
    }

    /// What the page may read: the CORS-safelisted response headers and whatever the helper exposed, which is what a
    /// browser would show it. The helper's cookies are Zigzag's to keep, never the page's to see.
    private static let visibleHeaders: Set<String> = [
        "cache-control", "content-language", "content-length", "content-type", "expires", "last-modified", "pragma",
    ]
    /// Never shown, whatever the helper exposes, as in a browser.
    private static let hiddenHeaders: Set<String> = ["set-cookie", "set-cookie2"]

    static func reply(_ answer: LocalReceivers.Response, to request: LocalReceivers.Request) -> [String: Any] {
        let exposed = Set((answer.header("access-control-expose-headers") ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        let headers = answer.headers
            .filter { visibleHeaders.contains($0.key) || (exposed.contains($0.key) && !hiddenHeaders.contains($0.key)) }
            .map { [$0.key, $0.value] }
        return [
            "status": answer.status,
            "statusText": HTTPURLResponse.localizedString(forStatusCode: answer.status),
            "headers": headers,
            "body": answer.body.base64EncodedString(),
            "url": answer.url.absoluteString,
            "redirected": answer.url != request.url,
        ]
    }
}

/// One WebSocket a page opened to this Mac: Zigzag makes the connection and pushes what arrives back into the page.
@MainActor
final class LocalReceiverSocket: NSObject, URLSessionWebSocketDelegate {
    private let id: String
    private weak var webView: WKWebView?
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var reply: (@MainActor @Sendable (Any?, String?) -> Void)?
    private var opened = false
    private var closed = false
    var onClose: ((String) -> Void)?

    init(id: String, url: URL, protocols: [String], origin: String, webView: WKWebView?,
         reply: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        self.id = id
        self.webView = webView
        self.reply = reply
        super.init()
        var request = URLRequest(url: url)
        request.setValue(origin, forHTTPHeaderField: "Origin")
        if !protocols.isEmpty {
            request.setValue(protocols.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        self.session = session
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        receive()
    }

    func send(text: String?, base64: String?) {
        guard !closed else { return }
        if let text {
            task?.send(.string(text)) { _ in }
        } else if let base64, let data = Data(base64Encoded: base64) {
            task?.send(.data(data)) { _ in }
        }
    }

    func close(code: Int?, reason: String?) {
        guard !closed else { return }
        let closeCode = code.flatMap { URLSessionWebSocketTask.CloseCode(rawValue: $0) } ?? .normalClosure
        task?.cancel(with: closeCode, reason: reason?.data(using: .utf8))
        finish(code: closeCode.rawValue, reason: reason ?? "", clean: closeCode == .normalClosure)
    }

    /// The page is navigating away: no close frame to send, just the connection ended.
    func cancelForNavigation() {
        guard !closed else { return }
        closed = true
        task?.cancel(with: .goingAway, reason: nil)
        // The session holds this socket as its delegate: ended here, or it would outlive the page.
        session?.invalidateAndCancel()
        onClose = nil
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didOpenWithProtocol subprotocol: String?) {
        MainActor.assumeIsolated {
            guard !closed else { return }
            opened = true
            reply?(["protocol": subprotocol ?? ""], nil)
            reply = nil
        }
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        MainActor.assumeIsolated {
            let text = reason.map { String(decoding: $0, as: UTF8.self) } ?? ""
            finish(code: closeCode.rawValue, reason: text,
                   clean: closeCode == .normalClosure || closeCode == .goingAway)
        }
    }

    /// Refused, as for fetch: a redirect could move the socket off this Mac.
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                                newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            guard error != nil else { return }
            if opened {
                finish(code: 1006, reason: "", clean: false)
            } else {
                reply?(["error": "failed"], nil)
                reply = nil
                finish(code: 1006, reason: "", clean: false)
            }
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.closed else { return }
                    switch result {
                    case .success(.string(let text)):
                        self.push(["type": "message", "text": text])
                        self.receive()
                    case .success(.data(let data)):
                        self.push(["type": "message", "base64": data.base64EncodedString()])
                        self.receive()
                    case .failure:
                        self.finish(code: 1006, reason: "", clean: false)
                    @unknown default:
                        self.finish(code: 1006, reason: "", clean: false)
                    }
                }
            }
        }
    }

    private func finish(code: Int, reason: String, clean: Bool) {
        guard !closed else { return }
        closed = true
        session?.invalidateAndCancel()
        if !opened {
            reply?(["error": "failed"], nil)
            reply = nil
        }
        push(["type": "close", "code": code, "reason": reason, "clean": clean])
        onClose?(id)
        onClose = nil
    }

    private func push(_ event: [String: Any]) {
        guard let webView, JSONSerialization.isValidJSONObject(event),
              let payload = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: payload, encoding: .utf8) else { return }
        let idJSON = "\"" + id.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        webView.evaluateJavaScript("window.__zigzagLocalSocketEvent && window.__zigzagLocalSocketEvent(\(idJSON), \(text))",
                                   completionHandler: nil)
    }
}
