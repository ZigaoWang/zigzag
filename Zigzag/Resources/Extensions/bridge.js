// Chrome extension APIs WebKit doesn't have, answered by Zigzag itself (ExtensionBridge.swift).
//
// Runs before an extension's own code, in its background and in its pages. Each namespace here is installed only
// when the extension asked for its permission in its manifest, and only when WebKit doesn't already provide it. Calls
// travel as native messages to "zigzag.bridge"; events come back over a port opened once something listens.
(() => {
  // Extensions here are Chrome Web Store builds, and several choose their code path from navigator.userAgent: told
  // "Safari", they take a Safari branch that expects Safari's own plumbing and stops. So their code reads Chrome, while
  // what they send to servers stays Zigzag's own, as servers that compare it with the connection expect.
  const nav = typeof navigator !== 'undefined' ? navigator : null;
  // What WebKit sends, for the requests Zigzag sends for the extension itself (extensionFetch below).
  const sentUserAgent = nav ? String(nav.userAgent) : '';
  if (nav && !/Chrome\//.test(nav.userAgent)) {
    const asChrome = nav.userAgent.replace(/Version\/[\d.]+ Safari\/[\d.]+/, 'Chrome/157.0.0.0 Safari/537.36');
    const proto = Object.getPrototypeOf(nav);
    for (const [key, value] of [['userAgent', asChrome], ['appVersion', asChrome.replace(/^Mozilla\//, '')]]) {
      try { Object.defineProperty(proto, key, { get: () => value, configurable: true, enumerable: true }); } catch (e) {}
    }
  }

  // Chrome's way to ask for a tab's (or the screen's) sound is getUserMedia with a `chromeMediaSource`. WebKit doesn't
  // know that field and would hear a plain request for the microphone, so such a request is never passed on: Zigzag
  // answers it with the tab, or refuses. Set up before anything else, so it holds even before the bridge can start.
  let tabStream = null;
  // On MediaDevices itself, so it holds however late the page's `navigator.mediaDevices` appears.
  const guard = () => {
    const proto = typeof MediaDevices !== 'undefined' && MediaDevices.prototype;
    if (!proto || typeof proto.getUserMedia !== 'function') return false;
    if (proto.getUserMedia.__zigzagGuard) return true;
    const getUserMedia = proto.getUserMedia;
    const source = (part) => (part && typeof part === 'object' ? (part.mandatory || {}).chromeMediaSource || part.chromeMediaSource : undefined);
    const refuse = (text, name) => Promise.reject(new DOMException(text, name));
    const guarded = function (constraints) {
      const audio = source(constraints && constraints.audio), video = source(constraints && constraints.video);
      if (audio === undefined && video === undefined) return getUserMedia.call(this, constraints);
      if (video !== undefined || audio !== 'tab') return refuse("Zigzag can capture a tab's sound, not its picture or your screen", 'NotSupportedError');
      if (!tabStream) start();
      if (!tabStream) return refuse('Tab capture is not available here', 'NotAllowedError');
      const part = constraints.audio;
      return tabStream((part.mandatory || {}).chromeMediaSourceId || part.chromeMediaSourceId);
    };
    Object.defineProperty(guarded, '__zigzagGuard', { value: true });
    Object.defineProperty(proto, 'getUserMedia', { value: guarded, configurable: true, writable: true });
    return true;
  };
  const inPage = typeof window !== 'undefined';
  const guarding = !inPage || guard();

  // WebKit sometimes hands an extension page its `chrome` a moment after this runs: until then, it tries again.
  const start = () => {
  const api = globalThis.chrome || globalThis.browser;
  if (globalThis.__zigzagBridge) return true;
  if (!api || !api.runtime || typeof api.runtime.sendNativeMessage !== 'function') return false;
  globalThis.__zigzagBridge = true;
  const HOST = 'zigzag.bridge';

  let manifest = {};
  try { manifest = api.runtime.getManifest() || {}; } catch (e) {}
  const asked = new Set([...(manifest.permissions || []), ...(manifest.optional_permissions || [])]);

  // Only what JSON carries crosses over: callbacks and undefined drop out.
  const clean = (value) => (value === undefined ? null : JSON.parse(JSON.stringify(value)));

  const send = (ns, fn, args) =>
    Promise.resolve(api.runtime.sendNativeMessage(HOST, { ns, fn, args: args.map(clean) })).then((reply) => {
      if (reply && typeof reply.error === 'string') throw new Error(reply.error);
      return reply ? reply.value : undefined;
    });

  // The icons of open tabs, by address, for the favIconUrl WebKit's tabs leave out (webkit-differences.js).
  Object.defineProperty(globalThis, '__zigzagFavicons', { value: (urls) => send('favicons', 'forPages', [urls]), configurable: true });

  // Context menu items persisted across relaunches, like Chrome (webkit-differences.js).
  Object.defineProperty(globalThis, '__zigzagContextMenus', {
    value: { change: (op, args) => send('contextMenusKept', 'change', [op, ...args]), restore: () => send('contextMenusKept', 'restore', []) },
    configurable: true,
  });

  // WebKit omits SameSite cookies from credentialed extension fetches even with site access. For buffered
  // reads, Zigzag can fetch in a blank page at the target origin. Writes use a temporary native session with
  // the sender's Chrome extension Origin and this profile's cookies, syncing response cookie changes back.
  // Native code checks current site access; without it, the original fetch runs. No vendor is singled out.
  // Upload streams, event streams, explicit referrers, integrity and manual redirects stay with WebKit.
  // A read that redirects to another origin or is too big to carry whole is answered { fallback } and runs
  // here as the original fetch; a write that would do either fails, as it may not be sent twice.
  // This Mac by the names loopback is reached by; http only, because that is what WebKit blocks. An extension
  // reaches it through the person's own switch for it, not through host access (a loopback address has none).
  const localLoopback = (url) => {
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

  if (typeof globalThis.fetch === 'function') {
    const nativeFetch = globalThis.fetch.bind(globalThis);
    const metadata = (response, answer) => {
      const clone = response.clone.bind(response);
      Object.defineProperties(response, {
        url: { value: answer.url }, redirected: { value: answer.redirected }, type: { value: 'basic' },
        clone: { value: () => metadata(clone(), answer) }
      });
      return response;
    };
    // The bytes of a body, base64, as the native side reads a loopback call.
    const encoded = (buffer) => {
      const bytes = new Uint8Array(buffer);
      let binary = '';
      for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
      return btoa(binary);
    };
    // ExtensionFetchRequests.responseLimit, the most a body carries across.
    const bodyLimit = 32 << 20;
    // The fewest bytes a body can be, known without reading it: a form's parts before its boundaries.
    const leastSize = (given) => {
      if (given instanceof Blob) return given.size;
      if (given instanceof ArrayBuffer || ArrayBuffer.isView(given)) return given.byteLength;
      if (given instanceof URLSearchParams) return given.toString().length;
      let size = 0;
      for (const [, value] of given) size += value instanceof Blob ? value.size : value.length;
      return size;
    };
    globalThis.fetch = async (input, init) => {
      const isRequest = input instanceof Request;
      const option = (name, fallback) => init && init[name] !== undefined ? init[name] : isRequest ? input[name] : fallback;
      const url = new URL(isRequest ? input.url : String(input), globalThis.location && location.href);
      const loopback = localLoopback(url);
      const method = String(option('method', 'GET')).toUpperCase();
      // A text body crosses as text; form data, a Blob or a buffer crosses as base64 bytes, read below from the
      // request itself, so its bytes match the Content-Type that request made (a form's boundary). A loopback call
      // always carries base64 bytes, a Request's own body included. Streams stay with WebKit.
      // A body over the native side's limit goes to WebKit before it is read or encoded.
      let body = null, asBytes = false;
      const given = init && init.body != null ? init.body : null;
      if (given != null) {
        if (typeof given === 'string') {
          if (!loopback) body = given.length > bodyLimit ? null : given;
          else { const bytes = new TextEncoder().encode(given); body = bytes.byteLength > bodyLimit ? null : encoded(bytes.buffer); }
          if (body == null) return nativeFetch(input, init);
        } else if (given instanceof FormData || given instanceof URLSearchParams || given instanceof Blob
                 || given instanceof ArrayBuffer || ArrayBuffer.isView(given)) {
          if (leastSize(given) > bodyLimit) return nativeFetch(input, init);
          asBytes = true;
        } else return nativeFetch(input, init);
      } else if (isRequest && input.body !== null) {
        if (!loopback) return nativeFetch(input, init);
        asBytes = true;
      }
      // Chrome sends a site's cookies with an extension's fetch to it, whether it says include or leaves the default,
      // and none with omit, past CORS either way (#478). A loopback call is the exception: it is another origin on this
      // Mac, and the helper is a plain server with no CORS reply of its own to read, so the switch alone decides and
      // the default credentials stand.
      const credentials = option('credentials', 'same-origin');
      if (!['http:', 'https:'].includes(url.protocol) || !['include', 'same-origin', 'omit'].includes(credentials)
          || !['GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS'].includes(method)
          || option('mode', 'cors') !== 'cors' || option('integrity', '') || option('keepalive', false)
          || !['', 'no-referrer'].includes(option('referrerPolicy', ''))
          || !['', 'about:client'].includes(option('referrer', 'about:client'))
          || option('redirect', 'follow') === 'manual' || option('cache', 'default') === 'only-if-cached') return nativeFetch(input, init);
      const headers = new Headers(option('headers', undefined));
      if (/text\/event-stream|application\/(?:x-ndjson|ndjson|stream\+json)/i.test(headers.get('accept') || '')) return nativeFetch(input, init);
      // From a copy, so a fallback can still send the caller's own request with its body.
      const request = new Request(isRequest ? input.clone() : input, init);
      const signal = request.signal;
      signal.throwIfAborted();
      if (asBytes) {
        const bytes = await request.clone().arrayBuffer();
        if (bytes.byteLength > bodyLimit) return nativeFetch(input, init);
        body = encoded(bytes);
      }
      const requestID = crypto.randomUUID();
      let abort;
      const aborted = new Promise((resolve, reject) => { abort = () => {
        try { send('extensionFetch', 'cancel', [requestID]).catch(() => {}); } catch (e) {}
        reject(signal.reason);
      }; });
      signal.addEventListener('abort', abort, { once: true });
      try {
        const answer = await Promise.race([send('extensionFetch', 'fetch', [{ requestID, url: request.url, method, credentials,
          headers: [...request.headers.entries()], body, encoding: !loopback && asBytes ? 'base64' : undefined, cache: request.cache, redirect: request.redirect, userAgent: sentUserAgent }]), aborted]);
        signal.throwIfAborted();
        if (answer.fallback) return nativeFetch(input, init);
        const binary = atob(answer.body), bytes = new Uint8Array(binary.length);
        for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
        return metadata(new Response(method === 'HEAD' || [204, 205, 304].includes(answer.status) ? null : bytes,
          { status: answer.status, statusText: answer.statusText, headers: answer.headers }), answer);
      } catch (error) {
        signal.throwIfAborted();
        throw new TypeError(error.message);
      } finally { signal.removeEventListener('abort', abort); }
    };
  }

  // The same door for an XMLHttpRequest, which an extension's own code uses for a helper that expects one. Every
  // request that is not an asynchronous one to this Mac stays WebKit's own: a synchronous request has to block, which
  // this side cannot do, so it is left to fail as it does today.
  if (typeof globalThis.XMLHttpRequest === 'function') {
    const NativeXHR = globalThis.XMLHttpRequest;
    const base = globalThis.location && location.href;
    const types = ['readystatechange', 'loadstart', 'progress', 'load', 'error', 'abort', 'timeout', 'loadend'];
    const bytesOf = (text) => {
      const binary = atob(text), bytes = new Uint8Array(binary.length);
      for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
      return bytes;
    };
    const textOf = (buffer) => {
      const bytes = new Uint8Array(buffer);
      let binary = '';
      for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
      return btoa(binary);
    };
    class LocalXHR {
      constructor() {
        this.native = new NativeXHR();
        this._local = false;
        this._listeners = Object.create(null);
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
        for (const type of types) {
          this.native.addEventListener(type, (event) => { if (!this._local) this._emit(type, event); });
        }
      }
      get upload() { return this._local ? this._upload : this.native.upload; }
      get readyState() { return this._local ? this._ready : this.native.readyState; }
      get status() { return this._local ? this._status : this.native.status; }
      get statusText() { return this._local ? this._statusText : this.native.statusText; }
      get responseURL() { return this._local ? this._responseURL : this.native.responseURL; }
      get responseType() { return this._local ? this._responseType : this.native.responseType; }
      set responseType(value) { if (this._local) this._responseType = value; else this.native.responseType = value; }
      get timeout() { return this._local ? this._timeout : this.native.timeout; }
      set timeout(value) { this._timeout = value; this.native.timeout = value; }
      get withCredentials() { return this._local ? this._withCredentials : this.native.withCredentials; }
      set withCredentials(value) { this._withCredentials = value; this.native.withCredentials = value; }
      get response() {
        if (!this._local) return this.native.response;
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
        if (!this._local) return this.native.responseText;
        if (this._responseType !== '' && this._responseType !== 'text') {
          throw new DOMException('The value is only accessible if the response type is text.', 'InvalidStateError');
        }
        if (this._body === null) return '';
        return new TextDecoder().decode(this._body);
      }
      get responseXML() { return this._local ? null : this.native.responseXML; }
      open(method, url, async = true, user, password) {
        this._local = false;
        this._ready = 0; this._status = 0; this._statusText = ''; this._body = null; this._headers = null;
        this._responseURL = ''; this._sent = false; this._aborted = false; this._timedOut = false;
        let target = null;
        try {
          const parsed = new URL(url, base);
          if (async !== false && localLoopback(parsed)) target = parsed;
        } catch (error) { target = null; }
        if (!target) return this.native.open(method, url, async, user, password);
        this._local = true;
        this._open = [method, url, async, user, password];
        this._request = { method: String(method || 'GET').toUpperCase(), url: target.href, headers: Object.create(null) };
        this._setState(1);
        return undefined;
      }
      setRequestHeader(name, value) {
        if (!this._local) return this.native.setRequestHeader(name, value);
        const key = String(name).toLowerCase();
        this._request.headers[key] = this._request.headers[key] ? this._request.headers[key] + ', ' + value : String(value);
      }
      overrideMimeType(type) { if (!this._local) this.native.overrideMimeType(type); }
      getResponseHeader(name) {
        if (!this._local) return this.native.getResponseHeader(name);
        if (!this._headers) return null;
        const key = String(name).toLowerCase();
        const found = this._headers.find((pair) => String(pair[0]).toLowerCase() === key);
        return found ? found[1] : null;
      }
      getAllResponseHeaders() {
        if (!this._local) return this.native.getAllResponseHeaders();
        if (!this._headers) return '';
        return this._headers.map((pair) => pair[0] + ': ' + pair[1]).join('\r\n') + '\r\n';
      }
      send(body) {
        if (!this._local) return this.native.send(body);
        if (this._ready !== 1 || this._sent) throw new DOMException('The object is in an invalid state.', 'InvalidStateError');
        this._sent = true;
        this._emit('loadstart', new ProgressEvent('loadstart'));
        const request = this._request;
        const requestID = crypto.randomUUID();
        this._requestID = requestID;
        const run = async () => {
          let payload = null;
          let contentType = null;
          if (request.method !== 'GET' && request.method !== 'HEAD' && body != null) {
            if (typeof body === 'string') {
              payload = textOf(new TextEncoder().encode(body).buffer);
              contentType = 'text/plain;charset=UTF-8';
            } else if (body instanceof URLSearchParams) {
              payload = textOf(new TextEncoder().encode(body.toString()).buffer);
              contentType = 'application/x-www-form-urlencoded;charset=UTF-8';
            } else if (body instanceof Blob) {
              payload = textOf(await body.arrayBuffer());
              contentType = body.type || null;
            } else if (body instanceof ArrayBuffer) {
              payload = textOf(body);
            } else if (ArrayBuffer.isView(body)) {
              payload = textOf(body.buffer.slice(body.byteOffset, body.byteOffset + body.byteLength));
            } else {
              payload = textOf(new TextEncoder().encode(String(body)).buffer);
              contentType = 'text/plain;charset=UTF-8';
            }
          }
          const headers = Object.entries(request.headers);
          if (contentType && !request.headers['content-type']) headers.push(['content-type', contentType]);
          if (this.timeout > 0) {
            setTimeout(() => {
              if (!this._local || this._ready === 4 || this._aborted) return;
              this._timedOut = true;
              try { send('extensionFetch', 'cancel', [requestID]).catch(() => {}); } catch (e) {}
              this._finishError('timeout');
            }, this.timeout);
          }
          let answer;
          try {
            answer = await send('extensionFetch', 'fetch', [{
              requestID, url: request.url, method: request.method, headers, body: payload,
              credentials: this.withCredentials ? 'include' : 'same-origin',
            }]);
          } catch (error) { answer = null; }
          if (this._aborted || this._timedOut || this._ready === 4) return;
          // With the switches off and no host access, WebKit's own XHR sends it, as before there was a door.
          if (answer && answer.fallback) { this._sendNatively(body); return; }
          if (!answer) { this._finishError('error'); return; }
          const noBody = answer.status === 204 || answer.status === 205 || answer.status === 304;
          const bytes = noBody ? new Uint8Array(0) : bytesOf(answer.body || '');
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
      _sendNatively(body) {
        this._local = false;
        const native = this.native;
        native.open(...this._open);
        for (const [name, value] of Object.entries(this._request.headers)) native.setRequestHeader(name, value);
        native.timeout = this._timeout;
        native.withCredentials = this._withCredentials;
        if (this._responseType) native.responseType = this._responseType;
        native.send(body);
      }
      abort() {
        if (!this._local) return this.native.abort();
        if (this._ready === 4) return;
        if (this._requestID) { try { send('extensionFetch', 'cancel', [this._requestID]).catch(() => {}); } catch (e) {} }
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
        const handler = this['on' + type];
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
    globalThis.XMLHttpRequest = LocalXHR;
  }

  // A Chrome-style method: a promise, or the trailing callback Chrome extensions often pass instead.
  const method = (ns, fn, { before, after } = {}) => (...args) => {
    const callback = typeof args[args.length - 1] === 'function' ? args.pop() : null;
    const result = send(ns, fn, before ? before(args) : args).then((value) => (after ? after(value, args) : value));
    if (!callback) return result;
    result.then((value) => callback(value), (error) => { console.warn(`chrome.${ns}.${fn}:`, error.message); callback(undefined); });
  };

  // Events: one port for all of them, opened the first time anything listens, reopened if it drops.
  const listeners = new Map();
  let port = null;
  const listen = (names) => { try { connect().postMessage({ listen: names }); } catch (e) {} };
  const connect = () => {
    if (port) return port;
    port = api.runtime.connectNative(HOST);
    port.onMessage.addListener((message) => {
      for (const listener of [...(listeners.get(message && message.event) || [])]) {
        try { listener(...(message.args || [])); } catch (e) { console.error(e); }
      }
    });
    port.onDisconnect.addListener(() => {
      port = null;
      if (listeners.size) setTimeout(() => listen([...listeners.keys()]), 1000);
    });
    return port;
  };
  const on = (name, listener) => {
    let set = listeners.get(name);
    if (!set) { set = new Set(); listeners.set(name, set); listen([name]); }
    set.add(listener);
  };
  const event = (name) => ({
    addListener(listener) { if (typeof listener === 'function') on(name, listener); },
    removeListener(listener) { const set = listeners.get(name); if (set) set.delete(listener); },
    hasListener(listener) { const set = listeners.get(name); return !!set && set.has(listener); },
    hasListeners() { const set = listeners.get(name); return !!set && set.size > 0; },
  });

  // Messages from websites: Chrome says which site sent each (sender.origin) and extensions check it before answering
  // (Claude answers only claude.ai). WebKit gives the address; the origin comes from it.
  const external = api.runtime.onMessageExternal;
  if (external && typeof external.addListener === 'function') {
    const add = external.addListener.bind(external);
    const wrapped = new WeakMap();
    external.addListener = (listener) => {
      if (typeof listener !== 'function') return add(listener);
      // Each message and when it's answered go to the extensions log (its type and the site, nothing it carries), so a
      // sign-in that never finishes shows where it stopped.
      const note = (text) => { try { api.runtime.sendNativeMessage('zigzag.diagnostics', { where: 'external', kind: 'message', text }); } catch (e) {} };
      const withOrigin = (message, sender, sendResponse) => {
        if (sender && !sender.origin && sender.url) { try { sender = Object.assign({}, sender, { origin: new URL(sender.url).origin }); } catch (e) {} }
        const kind = message && typeof message === 'object' && typeof message.type === 'string' ? message.type : typeof message;
        const started = Date.now();
        let answered = false;
        note(`${kind} from ${sender && sender.origin}`);
        const late = setTimeout(() => { if (!answered) note(`${kind}: no answer after 15 s`); }, 15000);
        const respond = (value) => {
          answered = true;
          clearTimeout(late);
          const ok = value && typeof value === 'object' && 'success' in value ? ` success=${value.success}${typeof value.error === 'string' ? ` (${value.error.slice(0, 120)})` : ''}` : '';
          note(`${kind} answered in ${Date.now() - started} ms${ok}`);
          return sendResponse(value);
        };
        return listener(message, sender, respond);
      };
      wrapped.set(listener, withOrigin);
      return add(withOrigin);
    };
    const remove = external.removeListener && external.removeListener.bind(external);
    if (remove) external.removeListener = (listener) => remove(wrapped.get(listener) || listener);
    const has = external.hasListener && external.hasListener.bind(external);
    if (has) external.hasListener = (listener) => has(wrapped.get(listener) || listener);
  }

  // Puts a namespace on chrome (and browser), unless WebKit has a working one of its own.
  const install = (name, value) => {
    if (!asked.has(name)) return;
    for (const target of new Set([globalThis.chrome, globalThis.browser])) {
      if (!target) continue;
      const existing = target[name];
      if (existing && typeof existing === 'object' && Object.keys(existing).length) continue;
      try { Object.defineProperty(target, name, { value, configurable: true, enumerable: true, writable: true }); } catch (e) {}
    }
  };

  install('history', {
    search: method('history', 'search'),
    getVisits: method('history', 'getVisits'),
    addUrl: method('history', 'addUrl'),
    deleteUrl: method('history', 'deleteUrl'),
    deleteRange: method('history', 'deleteRange'),
    deleteAll: method('history', 'deleteAll'),
    onVisited: event('history.onVisited'),
    onVisitRemoved: event('history.onVisitRemoved'),
  });

  install('topSites', { get: method('topSites', 'get') });

  install('sessions', {
    getRecentlyClosed: method('sessions', 'getRecentlyClosed'),
    getDevices: method('sessions', 'getDevices'),
    restore: method('sessions', 'restore'),
    onChanged: event('sessions.onChanged'),
    MAX_SESSION_RESULTS: 25,
  });

  install('bookmarks', {
    getTree: method('bookmarks', 'getTree'),
    getSubTree: method('bookmarks', 'getSubTree'),
    get: method('bookmarks', 'get'),
    getChildren: method('bookmarks', 'getChildren'),
    getRecent: method('bookmarks', 'getRecent'),
    search: method('bookmarks', 'search'),
    create: method('bookmarks', 'create'),
    update: method('bookmarks', 'update'),
    move: method('bookmarks', 'move'),
    remove: method('bookmarks', 'remove'),
    removeTree: method('bookmarks', 'removeTree'),
    onCreated: event('bookmarks.onCreated'),
    onRemoved: event('bookmarks.onRemoved'),
    onChanged: event('bookmarks.onChanged'),
    onMoved: event('bookmarks.onMoved'),
    onChildrenReordered: event('bookmarks.onChildrenReordered'),
    onImportBegan: event('bookmarks.onImportBegan'),
    onImportEnded: event('bookmarks.onImportEnded'),
    MAX_WRITE_OPERATIONS_PER_HOUR: 1000000,
    MAX_SUSTAINED_WRITE_OPERATIONS_PER_MINUTE: 1000000,
  });

  install('downloads', {
    download: method('downloads', 'download'),
    search: method('downloads', 'search'),
    pause: method('downloads', 'pause'),
    resume: method('downloads', 'resume'),
    cancel: method('downloads', 'cancel'),
    erase: method('downloads', 'erase'),
    removeFile: method('downloads', 'removeFile'),
    open: (id) => { send('downloads', 'open', [id]).catch((e) => console.warn('chrome.downloads.open:', e.message)); },
    show: (id) => { send('downloads', 'show', [id]).catch(() => {}); },
    showDefaultFolder: () => { send('downloads', 'showDefaultFolder', []).catch(() => {}); },
    getFileIcon: method('downloads', 'getFileIcon'),
    setUiOptions: method('downloads', 'setUiOptions'),
    setShelfEnabled: () => {},
    acceptDanger: method('downloads', 'acceptDanger'),
    onCreated: event('downloads.onCreated'),
    onChanged: event('downloads.onChanged'),
    onErased: event('downloads.onErased'),
    // Zigzag names files itself; an extension can't step in before it does.
    onDeterminingFilename: event('downloads.onDeterminingFilename'),
    State: { IN_PROGRESS: 'in_progress', INTERRUPTED: 'interrupted', COMPLETE: 'complete' },
  });

  install('notifications', {
    // create(id?, options): the ID comes back, made up when none was given.
    create: method('notifications', 'create'),
    update: method('notifications', 'update'),
    clear: method('notifications', 'clear'),
    getAll: method('notifications', 'getAll'),
    getPermissionLevel: method('notifications', 'getPermissionLevel'),
    onClicked: event('notifications.onClicked'),
    onClosed: event('notifications.onClosed'),
    onButtonClicked: event('notifications.onButtonClicked'),
    onShowSettings: event('notifications.onShowSettings'),
    TemplateType: { BASIC: 'basic', IMAGE: 'image', LIST: 'list', PROGRESS: 'progress' },
    PermissionLevel: { GRANTED: 'granted', DENIED: 'denied' },
  });

  install('idle', {
    queryState: method('idle', 'queryState'),
    setDetectionInterval: (seconds) => { send('idle', 'setDetectionInterval', [seconds]).catch(() => {}); },
    getAutoLockDelay: method('idle', 'getAutoLockDelay'),
    onStateChanged: event('idle.onStateChanged'),
    IdleState: { ACTIVE: 'active', IDLE: 'idle', LOCKED: 'locked' },
  });

  // tts.speak's options carry an onEvent callback; it stays here, and Zigzag reports events by utterance.
  const utterances = new Map();
  let utteranceCount = 0;
  const utteranceEvents = (id, event) => {
    const callback = utterances.get(id);
    if (!callback) return;
    try { callback(event); } catch (e) { console.error(e); }
    if (['end', 'interrupted', 'cancelled', 'error'].includes(event.type)) utterances.delete(id);
  };
  install('tts', {
    speak: method('tts', 'speak', {
      before: ([text, options]) => {
        const rest = Object.assign({}, options);
        if (typeof rest.onEvent === 'function') {
          const id = `u${++utteranceCount}`;
          utterances.set(id, rest.onEvent);
          on('tts.utterance', utteranceEvents);
          rest.__utterance = id;
        }
        delete rest.onEvent;
        return [text, rest];
      },
    }),
    stop: () => { send('tts', 'stop', []).catch(() => {}); },
    pause: () => { send('tts', 'pause', []).catch(() => {}); },
    resume: () => { send('tts', 'resume', []).catch(() => {}); },
    isSpeaking: method('tts', 'isSpeaking'),
    getVoices: method('tts', 'getVoices'),
    onEvent: event('tts.onEvent'),
  });

  install('offscreen', {
    createDocument: method('offscreen', 'createDocument'),
    closeDocument: method('offscreen', 'closeDocument'),
    hasDocument: method('offscreen', 'hasDocument'),
    Reason: Object.fromEntries(['TESTING', 'AUDIO_PLAYBACK', 'IFRAME_SCRIPTING', 'DOM_SCRAPING', 'BLOBS', 'DOM_PARSER', 'USER_MEDIA',
      'DISPLAY_MEDIA', 'WEB_RTC', 'CLIPBOARD', 'LOCAL_STORAGE', 'WORKERS', 'BATTERY_STATUS', 'MATCH_MEDIA', 'GEOLOCATION'].map((r) => [r, r])),
  });

  install('identity', {
    launchWebAuthFlow: method('identity', 'launchWebAuthFlow'),
    getRedirectURL: (path) => `https://${api.runtime.id}.chromiumapp.org/${path || ''}`,
    getAuthToken: (...args) => {
      const callback = typeof args[args.length - 1] === 'function' ? args.pop() : null;
      const error = new Error("Chrome's own account sign-in isn't available in Zigzag; use launchWebAuthFlow");
      if (callback) { setTimeout(() => callback(undefined), 0); return; }
      return Promise.reject(error);
    },
    removeCachedAuthToken: method('identity', 'getRedirectURL', { after: () => undefined }),
    clearAllCachedAuthTokens: () => Promise.resolve(),
    getProfileUserInfo: (...args) => {
      const callback = typeof args[args.length - 1] === 'function' ? args.pop() : null;
      const info = { email: '', id: '' };
      if (callback) { setTimeout(() => callback(info), 0); return; }
      return Promise.resolve(info);
    },
    getAccounts: () => Promise.resolve([]),
    onSignInChanged: event('identity.onSignInChanged'),
  });

  // Chrome lets a page click open the panel when the content script relays it. open() carries the last content script
  // message and its page; Zigzag checks for a recent click or key there (BridgeSidePanel). Registered before the
  // extension's listeners so it's set before they call open().
  let contentMessage = null;
  if (asked.has('sidePanel')) {
    const ownOrigin = globalThis.location ? String(globalThis.location.origin) : '';
    const note = (sender) => {
      if (!sender || sender.id !== api.runtime.id || !sender.tab) return;
      const hosts = [sender.url, sender.origin, sender.tab.url].flatMap((address) => {
        if (typeof address !== 'string' || (ownOrigin && address.startsWith(ownOrigin))) return [];
        try { const url = new URL(address); return /^https?:$/.test(url.protocol) ? [url.hostname] : []; } catch (e) { return []; }
      });
      if (hosts.length) contentMessage = { hosts, at: Date.now() };
    };
    try { if (api.runtime.onMessage) api.runtime.onMessage.addListener((message, sender) => { note(sender); return undefined; }); } catch (e) {}
  }
  const openPanel = method('sidePanel', 'open', {
    before: (args) => [args[0] === undefined ? {} : args[0],
      contentMessage ? { contentMessage: { hosts: contentMessage.hosts, age: Math.max(0, Date.now() - contentMessage.at) } } : {}],
  });

  install('sidePanel', {
    setOptions: method('sidePanel', 'setOptions'),
    getOptions: method('sidePanel', 'getOptions'),
    setPanelBehavior: method('sidePanel', 'setPanelBehavior'),
    getPanelBehavior: method('sidePanel', 'getPanelBehavior'),
    open: openPanel,
    close: method('sidePanel', 'close'),
    onOpened: event('sidePanel.onOpened'),
    onClosed: event('sidePanel.onClosed'),
  });

  // proxy.settings is one of Chrome's ChromeSettings. Zigzag follows fixed servers (BridgeProxy.swift); a setting it
  // can't follow, a PAC script, is refused and changes nothing.
  install('proxy', {
    settings: {
      get: method('proxy', 'settings.get'),
      set: method('proxy', 'settings.set'),
      clear: method('proxy', 'settings.clear'),
      onChange: event('proxy.settings.onChange'),
    },
    // WebKit doesn't say when a proxy fails, so this never fires.
    onProxyError: event('proxy.onProxyError'),
  });

  // Address bar keywords: the command bar tells an extension that declares one what's typed after it
  // (BridgeOmnibox.swift). onInputChanged's suggest callback stays here; Zigzag names the input it answers.
  const keyword = manifest.omnibox && typeof manifest.omnibox.keyword === 'string' ? manifest.omnibox.keyword.trim() : '';
  if (keyword) {
    const suggesting = event('omnibox.onInputChanged');
    const wrapped = new WeakMap();
    const wrap = (listener) => {
      if (!wrapped.has(listener)) {
        wrapped.set(listener, (text, request) => listener(text, (suggestions) => {
          send('omnibox', 'suggest', [request, Array.isArray(suggestions) ? suggestions : []]).catch(() => {});
        }));
      }
      return wrapped.get(listener);
    };
    const omnibox = {
      setDefaultSuggestion: method('omnibox', 'setDefaultSuggestion'),
      onInputStarted: event('omnibox.onInputStarted'),
      onInputChanged: {
        addListener(listener) { if (typeof listener === 'function') suggesting.addListener(wrap(listener)); },
        removeListener(listener) { if (wrapped.has(listener)) suggesting.removeListener(wrapped.get(listener)); },
        hasListener(listener) { return wrapped.has(listener) && suggesting.hasListener(wrapped.get(listener)); },
        hasListeners() { return suggesting.hasListeners(); },
      },
      onInputEntered: event('omnibox.onInputEntered'),
      onInputCancelled: event('omnibox.onInputCancelled'),
      // Zigzag's rows can't be deleted, so this never fires.
      onDeleteSuggestion: event('omnibox.onDeleteSuggestion'),
      OnInputEnteredDisposition: { CURRENT_TAB: 'currentTab', NEW_FOREGROUND_TAB: 'newForegroundTab', NEW_BACKGROUND_TAB: 'newBackgroundTab' },
      DescriptionStyleType: { URL: 'url', MATCH: 'match', DIM: 'dim' },
    };
    for (const target of new Set([globalThis.chrome, globalThis.browser])) {
      if (!target) continue;
      try { Object.defineProperty(target, 'omnibox', { value: omnibox, configurable: true, enumerable: true, writable: true }); } catch (e) {}
    }
  }

  // Sign-ins: Chrome asks webRequest.onAuthRequired listeners when a site or a proxy wants a name and password
  // (1Password and Bitwarden fill a site's, FoxyProxy its proxies'). WebKit's own listeners only watch, so Zigzag asks
  // these itself, with Chrome's details: a site's as it asks (BridgeWebRequest.swift), a proxy's as soon as the
  // extension sets it (BridgeProxy.swift). A listener answers as in Chrome, returning { authCredentials } or
  // { cancel: true } or calling back with it (asyncBlocking), or with a promise of it, as in Firefox. Each listener's
  // filter applies; the first to answer is the answer.
  const signsInSites = asked.has('webRequestAuthProvider') || asked.has('webRequestBlocking');
  if (asked.has('webRequest') && (asked.has('proxy') || signsInSites)) {
    const signIn = new Map();   // listener -> { callsBack, filter, headers }
    // Chrome's match patterns, enough for a filter's urls: scheme, host (with *. for subdomains) and path.
    const matchesPattern = (pattern, address) => {
      if (pattern === '<all_urls>') return /^(https?|wss?|ftp|file):/.test(address);
      const parts = /^(\*|https?|wss?|ftp|file):\/\/([^/]*)(\/.*)?$/.exec(String(pattern));
      let url;
      try { url = new URL(address); } catch (e) { return false; }
      if (!parts) return false;
      const scheme = url.protocol.slice(0, -1);
      if (parts[1] === '*' ? !['http', 'https', 'ws', 'wss'].includes(scheme) : parts[1] !== scheme) return false;
      const host = parts[2].replace(/:(\d+|\*)$/, '');
      if (host !== '*' && host !== url.hostname && !(host.startsWith('*.') && (url.hostname === host.slice(2) || url.hostname.endsWith(host.slice(1))))) return false;
      const path = new RegExp('^' + (parts[3] || '/*').split('*').map((piece) => piece.replace(/[.+?^${}()|[\]\\]/g, '\\$&')).join('.*') + '$');
      return path.test(url.pathname + url.search);
    };
    const wants = (filter, details) => {
      if (!filter || typeof filter !== 'object') return true;
      if (Array.isArray(filter.types) && !filter.types.includes(details.type)) return false;
      if (typeof filter.tabId === 'number' && filter.tabId !== details.tabId) return false;
      return !Array.isArray(filter.urls) || filter.urls.some((pattern) => matchesPattern(pattern, details.url));
    };
    // Every listener whose filter wants it, at once; the first that answers decides, and one that's said nothing in
    // `wait` ms counts as nothing. Resolves { authCredentials }, { cancel: true } or {}.
    const ask = (details, wait = 10000) => new Promise((resolve) => {
      const listening = [...signIn].filter(([, entry]) => wants(entry.filter, details));
      let left = listening.length;
      let done = false;
      const settle = (answer) => {
        if (done) return;
        const credentials = answer && answer.authCredentials;
        if (answer && answer.cancel === true) { done = true; resolve({ cancel: true }); return; }
        if (credentials && typeof credentials.username === 'string') {
          done = true;
          resolve({ authCredentials: { username: credentials.username, password: String(credentials.password == null ? '' : credentials.password) } });
          return;
        }
        if (--left <= 0) { done = true; resolve({}); }
      };
      if (!left) { resolve({}); return; }
      for (const [listener, entry] of listening) {
        let said = false;
        const say = (answer) => { if (!said) { said = true; settle(answer); } };
        const given = Object.assign({}, details);
        if (!entry.headers) delete given.responseHeaders;
        try {
          const returned = listener(given, entry.callsBack ? say : undefined);
          if (!entry.callsBack) Promise.resolve(returned).then(say, () => say(undefined));
        } catch (e) { say(undefined); }
        setTimeout(() => say(undefined), wait);
      }
    });
    // A site's sign-in names the tab asking by WebKit's ID, which only this extension's tabs.query knows: Zigzag
    // says where the tab is, and it's found here. 1Password keeps what you picked for a tab by that ID.
    const tabFor = async (hint) => {
      if (!hint || !api.tabs || typeof api.tabs.query !== 'function') return -1;
      try {
        const tabs = await api.tabs.query({});
        const there = tabs.filter((tab) => hint.url && (tab.url === hint.url || tab.pendingUrl === hint.url));
        const found = there.find((tab) => tab.index === hint.index && !!tab.active === !!hint.active) || (there.length === 1 ? there[0] : null);
        return found && typeof found.id === 'number' ? found.id : -1;
      } catch (e) { return -1; }
    };
    const askForSite = async (details) => {
      const hint = details.__zigzagTab;
      delete details.__zigzagTab;
      details.tabId = await tabFor(hint);
      // A site's can be answered while Zigzag's sheet asks, as 1Password does once you pick a login in its popup (#387).
      const answer = await ask(details, 10 * 60 * 1000);
      send('webRequest', 'authAnswer', [details.requestId, answer]).catch(() => {});
    };
    const askForProxy = async (details) => {
      const answer = await ask(details);
      if (answer.authCredentials) send('proxy', 'authAnswer', [details.requestId, answer.authCredentials]).catch(() => {});
    };
    // WebKit has its own onAuthRequired and won't let it be replaced here: webkit-differences.js, which can stand in
    // for it, tells this about each listener as it's added.
    Object.defineProperty(globalThis, '__zigzagSignIn', { value: {
      add(listener, filter, extraInfoSpec) {
        if (typeof listener !== 'function') return;
        const spec = Array.isArray(extraInfoSpec) ? extraInfoSpec : [];
        signIn.set(listener, { callsBack: spec.includes('asyncBlocking'), filter, headers: spec.includes('responseHeaders') });
        if (asked.has('proxy')) on('proxy.onAuthRequired', askForProxy);
        if (signsInSites) on('webRequest.onAuthRequired', askForSite);
      },
      remove(listener) { signIn.delete(listener); },
      has(listener) { return signIn.has(listener); },
    }, configurable: true });
  }

  // A capture of a streamed tab hears WebKit's own sound (SharedSoundGate.swift), muted at the source meanwhile, as
  // Chrome mutes a captured tab. What the extension then plays (Shazam passing the sound on, a booster's louder copy)
  // goes to Zigzag, which plays it itself (NativeAudioOut.swift): heard, and never captured again. So each audio
  // context in the page plays through a router: straight to the speakers normally, to Zigzag while such a capture
  // hears the tab (Zigzag says when it pauses and carries on). However the extension builds its sound, all of it
  // passes there.
  const hearing = new Set();   // captures hearing WebKit's sound right now
  const routes = [];           // one per audio context: { context, router, speakers, relay, source }
  const relayOn = (route) => {
    if (route.relay) return;
    const { context } = route;
    const relay = context.createScriptProcessor(1024, 1, 1);
    relay.onaudioprocess = (event) => {
      event.outputBuffer.getChannelData(0).fill(0);
      const id = hearing.values().next().value;
      if (!id) return;
      const input = event.inputBuffer.getChannelData(0);
      const samples = new Int16Array(input.length);
      for (let i = 0; i < input.length; i++) { const v = Math.max(-1, Math.min(1, input[i])); samples[i] = v < 0 ? v * 0x8000 : v * 0x7fff; }
      const bytes = new Uint8Array(samples.buffer);
      let binary = '';
      for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
      send('tabCapture', 'play', [id, route.source, context.sampleRate, btoa(binary)]).catch(() => {});
    };
    try { route.router.disconnect(); } catch (e) {}
    route.connect.call(route.router, relay);
    // A processor runs only while it leads somewhere; it writes silence.
    route.connect.call(relay, route.speakers);
    route.relay = relay;
  };
  const relayOff = (route) => {
    if (!route.relay) return;
    try { route.router.disconnect(); route.relay.disconnect(); } catch (e) {}
    route.relay.onaudioprocess = null;
    route.relay = null;
    route.connect.call(route.router, route.speakers);
  };
  const startHearing = (id) => { hearing.add(id); routes.forEach(relayOn); };
  const stopHearing = (id) => { hearing.delete(id); if (!hearing.size) routes.forEach(relayOff); };
  if (typeof BaseAudioContext !== 'undefined' && typeof AudioContext !== 'undefined' && asked.has('tabCapture')) {
    const destination = Object.getOwnPropertyDescriptor(BaseAudioContext.prototype, 'destination');
    const connect = AudioNode.prototype.connect;
    const routeOf = new WeakMap();
    if (destination && destination.get) {
      Object.defineProperty(BaseAudioContext.prototype, 'destination', {
        configurable: true, enumerable: destination.enumerable,
        get() {
          const speakers = destination.get.call(this);
          // Rendering offline plays nothing.
          if (!(this instanceof AudioContext)) return speakers;
          let route = routeOf.get(this);
          if (!route) {
            const router = this.createGain();
            try { Object.defineProperty(router, 'maxChannelCount', { value: speakers.maxChannelCount }); } catch (e) {}
            route = { context: this, router, speakers, relay: null, connect, source: 'c' + routes.length };
            connect.call(router, speakers);
            routeOf.set(this, route);
            routes.push(route);
            if (hearing.size) relayOn(route);
          }
          return route.router;
        },
      });
    }
  }

  // Chrome hands a capture over only after the messages the page had already sent were delivered, the page's own
  // included. Extensions rely on that order: Shazam's popup sends itself "stopRecording" each time it redraws, and
  // in Chrome that arrives before its recording exists. Zigzag's capture can come back sooner, so it waits for
  // them (briefly at most): a message sent before the capture never stops it.
  const sentEarlier = [];
  if (typeof window !== 'undefined' && api.runtime.onMessage && typeof api.runtime.sendMessage === 'function') {
    const sendMessage = api.runtime.sendMessage.bind(api.runtime);
    const key = (message) => { try { return JSON.stringify(message); } catch (e) { return ''; } };
    try {
      api.runtime.sendMessage = (...args) => {
        const message = typeof args[0] === 'string' && args.length > 1 && typeof args[1] !== 'function' ? args[1] : args[0];
        sentEarlier.push({ key: key(message), at: Date.now() });
        if (sentEarlier.length > 50) sentEarlier.shift();
        return sendMessage(...args);
      };
    } catch (e) {}
    api.runtime.onMessage.addListener((message) => {
      const index = sentEarlier.findIndex((sent) => sent.key === key(message));
      if (index >= 0) sentEarlier.splice(index, 1);
    });
  }
  const afterEarlierMessages = async () => {
    // Delivery can wait on WebKit waking the extension's background: up to a couple of seconds, the first time.
    const until = Date.now() + 2500;
    while (sentEarlier.some((sent) => Date.now() - sent.at < 2500) && Date.now() < until) {
      await new Promise((done) => setTimeout(done, 15));
    }
    // The extension's own listeners for the last of them run in the same turn: one more, and they've run.
    await new Promise((done) => setTimeout(done, 0));
  };

  // tabCapture: Zigzag sends the tab's samples; here they play into a MediaStream the extension uses as Chrome's.
  // Kept as close behind the tab as it can be (a few hundredths of a second), since the tab itself goes quiet and an
  // extension like a volume booster plays this in its place, under the tab's picture.
  const captureStream = (id) => {
    const context = new AudioContext();
    const destination = context.createMediaStreamDestination();
    const player = context.createScriptProcessor(512, 0, 1);
    const queue = [];
    let queued = 0, primed = false;
    // A small cushion before playing (and again after running dry), so uneven arrival doesn't crackle; never more
    // than a tenth of a second behind, so it can't drift away from the picture.
    const cushion = Math.round(context.sampleRate * 0.025), most = Math.round(context.sampleRate * 0.1);
    player.onaudioprocess = (event) => {
      const out = event.outputBuffer.getChannelData(0);
      if (!primed && queued < cushion) { out.fill(0); return; }
      primed = true;
      let i = 0;
      while (i < out.length && queue.length) {
        const chunk = queue[0];
        const take = Math.min(out.length - i, chunk.length - chunk.offset);
        out.set(chunk.subarray(chunk.offset, chunk.offset + take), i);
        chunk.offset += take; i += take; queued -= take;
        if (chunk.offset >= chunk.length) queue.shift();
      }
      if (i < out.length) { out.fill(0, i); primed = false; }
    };
    player.connect(destination);
    const receive = (tap, rate, pcm, at, live) => {
      if (tap !== id) return;
      // Sound that took too long to arrive would only put it further behind.
      if (at && Date.now() - at > 250) return;
      const binary = atob(pcm);
      const samples = new Int16Array(binary.length / 2);
      for (let i = 0; i < samples.length; i++) samples[i] = binary.charCodeAt(2 * i) | (binary.charCodeAt(2 * i + 1) << 8);
      // Resampled to this context's rate when the two differ.
      const ratio = rate / context.sampleRate;
      const length = Math.floor(samples.length / ratio);
      const chunk = new Float32Array(length);
      for (let i = 0; i < length; i++) chunk[i] = samples[Math.min(samples.length - 1, Math.floor(i * ratio))] / 0x8000;
      chunk.offset = 0;
      queue.push(chunk);
      queued += length;
      while (queued - (queue[0].length - queue[0].offset) >= most && queue.length > 1) {
        const dropped = queue.shift();
        queued -= dropped.length - dropped.offset;
      }
    };
    // While a capture of a streamed tab hears it, what this page plays goes through Zigzag (above); paused (another
    // tab has sound), it plays to the speakers again, and the stream carries silence.
    let heard = false;
    const hear = (on) => {
      if (on === heard) return;
      heard = on;
      if (on) startHearing(id); else stopHearing(id);
    };
    // Collected from Zigzag about fifty times a second while the stream lives.
    let collecting = true;
    const ended = () => {
      if (!collecting) return;
      collecting = false;
      hear(false);
      for (const track of destination.stream.getAudioTracks()) track.stop();
      player.disconnect();
      context.close().catch(() => {});
    };
    const collect = async () => {
      if (!collecting) return;
      try {
        const chunks = await send('tabCapture', 'read', [id]);
        // Nothing at all (not even an empty list): the capture has ended.
        if (chunks == null) { ended(); return; }
        for (const chunk of chunks) {
          if (Array.isArray(chunk)) receive(id, ...chunk);
          else if (chunk && typeof chunk.hearing === 'boolean') hear(chunk.hearing);
        }
      } catch (e) {}
      setTimeout(collect, 20);
    };
    collect();
    const stream = destination.stream;
    for (const track of stream.getAudioTracks()) {
      const stop = track.stop.bind(track);
      track.stop = () => {
        stop();
        ended();
        send('tabCapture', 'stop', [id]).catch(() => {});
      };
    }
    return stream;
  };
  // Chrome's second way in: getMediaStreamId names a tab, and the extension's page asks getUserMedia for it (above).
  tabStream = (streamId) => send('tabCapture', 'capture', [{ audio: true, streamId, page: location.pathname }])
    .then(async (tap) => { const stream = captureStream(tap.id); await afterEarlierMessages(); return stream; },
      (error) => { throw new DOMException(error.message, 'NotAllowedError'); });
  install('tabCapture', {
    capture: (options, callback) => {
      const result = send('tabCapture', 'capture', [{ ...(options || {}), page: location.pathname }]).then(async (tap) => { const stream = captureStream(tap.id); await afterEarlierMessages(); return stream; });
      if (typeof callback !== 'function') return result;
      result.then((stream) => callback(stream), (error) => { console.warn('chrome.tabCapture.capture:', error.message); callback(null); });
    },
    getCapturedTabs: method('tabCapture', 'getCapturedTabs'),
    getMediaStreamId: method('tabCapture', 'getMediaStreamId'),
    onStatusChanged: event('tabCapture.onStatusChanged'),
  });

  // runtime.getContexts: MV3 only, as in Chrome. Zigzag knows which extension pages are open (offscreen, popup, side
  // panel).
  if (manifest.manifest_version === 3 && typeof api.runtime.getContexts !== 'function') {
    try { api.runtime.getContexts = method('contexts', 'getContexts'); } catch (e) {}
  }

  // userScripts (BridgeUserScripts in Swift): Zigzag runs each user script in a world of its own, apart from the
  // page and from the extension's content scripts, as Chrome does. Calls run one at a time, as WebKit's would.
  // What a user script says reaches the extension from the content-script world of its frame, marked (MARK): it goes
  // to onUserScriptMessage and onUserScriptConnect only, never to onMessage or onConnect, as in Chrome.
  const scripting = api.scripting;
  if (asked.has('userScripts')) {
    const MARK = '__zigzagUserScript';
    let queue = Promise.resolve();
    const serial = (work) => { const run = queue.then(work); queue = run.catch(() => {}); return run; };
    // Chrome checks the arguments' shape before anything runs, and throws.
    const RUN_AT = ['document_end', 'document_idle', 'document_start'], WORLDS = ['MAIN', 'USER_SCRIPT'];
    const shape = (fn, scripts) => {
      const fail = (index, text) => { throw new TypeError(`Error in invocation of userScripts.${fn}(array scripts, optional function callback): Error at parameter 'scripts': ${index === null ? text : `Error at index ${index}: ${text}`}`); };
      if (!Array.isArray(scripts)) fail(null, 'Invalid type: expected array, found ' + typeof scripts + '.');
      scripts.forEach((script, index) => {
        if (!script || typeof script !== 'object') fail(index, 'Invalid type: expected object.');
        if (typeof script.id !== 'string') fail(index, "Error at property 'id': Invalid type: expected string, found " + typeof script.id + '.');
        if (script.runAt !== undefined && !RUN_AT.includes(script.runAt)) fail(index, `Error at property 'runAt': Value must be one of ${RUN_AT.join(', ')}.`);
        if (script.world !== undefined && !WORLDS.includes(script.world)) fail(index, `Error at property 'world': Value must be one of ${WORLDS.join(', ')}.`);
      });
    };
    // A promise, or the trailing callback; checks throw straight away, as Chrome's do.
    const call = (fn, check, work) => (...args) => {
      const callback = typeof args[args.length - 1] === 'function' ? args.pop() : null;
      if (check) check(...args);
      const result = serial(() => work(...args));
      if (!callback) return result;
      result.then((value) => callback(value), (error) => { console.warn(`chrome.userScripts.${fn}:`, error.message); callback(undefined); });
    };
    const inBackground = !inPage || (api.extension && typeof api.extension.getBackgroundPage === 'function' && api.extension.getBackgroundPage() === window);
    // Earlier versions registered user scripts with WebKit as content scripts ("zz-us-"); any still there go.
    if (inBackground) {
      serial(async () => {
        await send('userScripts', 'restore', []);
        if (!scripting || typeof scripting.getRegisteredContentScripts !== 'function') return;
        const old = (await scripting.getRegisteredContentScripts()).map((s) => s.id).filter((id) => id.startsWith('zz-us-'));
        if (old.length) await scripting.unregisterContentScripts({ ids: old });
      }).catch((e) => console.warn('chrome.userScripts:', e.message));
    }
    install('userScripts', {
      register: call('register', (scripts) => shape('register', scripts), async (scripts) => { await send('userScripts', 'register', [scripts]); }),
      update: call('update', (scripts) => shape('update', scripts), async (scripts) => { await send('userScripts', 'update', [scripts]); }),
      unregister: call('unregister', null, async (filter) => { await send('userScripts', 'unregister', [filter || {}]); }),
      getScripts: call('getScripts', null, (filter) => send('userScripts', 'getScripts', [filter || {}])),
      // Each frame scripting.executeScript reaches asks Zigzag, from the extension's content-script world, to run the
      // code in its user-script world, then the frames' results are collected.
      execute: call('execute', null, async (injection) => {
        if (!scripting || typeof scripting.executeScript !== 'function') throw new Error('userScripts.execute needs scripting');
        const { token } = await send('userScripts', 'execute', [injection]);
        const ask = (token) => {
          const nonce = Math.random().toString(36).slice(2) + Date.now().toString(36);
          try {
            const asked = globalThis.webkit.messageHandlers.zigzagUserScriptRelay.postMessage({ kind: 'execute', token, nonce });
            if (asked && asked.catch) asked.catch(() => {});
          } catch (e) { return null; }
          return nonce;
        };
        const frames = (await scripting.executeScript({ target: injection.target, world: 'ISOLATED', injectImmediately: !!injection.injectImmediately, func: ask, args: [token] })) || [];
        const results = await send('userScripts', 'executeResults', [token, frames.map((r) => r.result).filter((n) => typeof n === 'string')]);
        return frames.map((r) => {
          const done = (results && typeof r.result === 'string' && results[r.result]) || {};
          const out = { frameId: r.frameId, documentId: r.documentId };
          if ('value' in done) out.result = done.value;
          if (done.error || r.error) out.error = String(done.error || (r.error && r.error.message) || r.error);
          return out;
        });
      }),
      configureWorld: call('configureWorld', null, (properties) => send('userScripts', 'configureWorld', [properties || {}])),
      getWorldConfigurations: call('getWorldConfigurations', null, () => send('userScripts', 'getWorldConfigurations', [])),
      resetWorldConfiguration: call('resetWorldConfiguration', null, (worldId) => send('userScripts', 'resetWorldConfiguration', [worldId === undefined ? null : worldId])),
      ExecutionWorld: { MAIN: 'MAIN', USER_SCRIPT: 'USER_SCRIPT' },
    });

    // runtime.onUserScriptMessage and onUserScriptConnect, as Chrome's: what user scripts send, and only that.
    const localEvent = () => {
      const listeners = new Set();
      return {
        listeners,
        api: {
          addListener(f) { if (typeof f === 'function') listeners.add(f); },
          removeListener(f) { listeners.delete(f); },
          hasListener(f) { return listeners.has(f); },
          hasListeners() { return listeners.size > 0; },
        },
      };
    };
    // WebKit keeps its API objects only while something else does, and makes new ones, without what was set on them,
    // when asked again after they're gone (webkit-differences.js, setMember): every object changed here is kept, or
    // the extension could later be handed one where user scripts' messages aren't hidden.
    const held = (globalThis.__zigzagHeld = globalThis.__zigzagHeld || []);
    held.push(api, api.runtime, api.tabs);
    const userMessage = localEvent(), userConnect = localEvent();
    for (const [name, event] of [['onUserScriptMessage', userMessage], ['onUserScriptConnect', userConnect]]) {
      try { Object.defineProperty(api.runtime, name, { value: event.api, configurable: true, enumerable: true }); } catch (e) {}
    }
    const marked = (value) => value && typeof value === 'object' && value[MARK] && typeof value[MARK] === 'object' ? value[MARK] : null;
    const portInfo = (port) => {
      if (!port || typeof port.name !== 'string' || !port.name.startsWith(MARK)) return null;
      try { const info = JSON.parse(port.name.slice(MARK.length)); return info && typeof info === 'object' ? info : null; } catch (e) { return null; }
    };
    // Only from this extension, by WebKit's word: what its content-script worlds pass on.
    const fromItself = (sender) => !!sender && sender.id === api.runtime.id;

    // The extension's own onMessage and onConnect listeners never see what user scripts send.
    const hide = (event, test) => {
      if (!event || typeof event.addListener !== 'function') return;
      held.push(event);
      const add = event.addListener.bind(event);
      const remove = event.removeListener && event.removeListener.bind(event);
      const has = event.hasListener && event.hasListener.bind(event);
      const wrapped = new WeakMap();
      // Assigned, or defined when assignment fails; either way it must stick or nothing is hidden.
      const put = (name, value) => {
        try { event[name] = value; } catch (e) {}
        if (event[name] !== value) { try { Object.defineProperty(event, name, { value, configurable: true, writable: true }); } catch (e) {} }
        return event[name] === value;
      };
      const addListener = (listener, ...rest) => {
        if (typeof listener !== 'function') return add(listener, ...rest);
        const guarded = (first, ...more) => (test(first) ? undefined : listener(first, ...more));
        wrapped.set(listener, guarded);
        return add(guarded, ...rest);
      };
      if (!put('addListener', addListener)) console.warn('Zigzag: user scripts’ messages could not be kept from runtime listeners');
      if (remove) put('removeListener', (listener) => remove(wrapped.get(listener) || listener));
      if (has) put('hasListener', (listener) => has(wrapped.get(listener) || listener));
      return add;
    };
    // On both chrome and browser, in case WebKit gives each its own events.
    const runtimes = [...new Set([globalThis.chrome, globalThis.browser].map((target) => target && target.runtime).filter(Boolean))];
    held.push(...runtimes);
    const hideAll = (name, test) => [...new Set(runtimes.map((runtime) => runtime[name]))].map((event) => hide(event, test)).find(Boolean);
    const addMessage = hideAll('onMessage', marked);
    const addConnect = hideAll('onConnect', (port) => !!portInfo(port));
    if (addConnect) { try { Object.defineProperty(globalThis, '__zigzagConnectAll', { value: addConnect, configurable: true }); } catch (e) {} }

    if (addMessage) addMessage((message, sender, sendResponse) => {
      const packet = marked(message);
      if (!packet || !fromItself(sender)) return undefined;
      // A world that listens for its tab's messages: the background notes which tab and frame it's in.
      if (packet.kind === 'hello') {
        if (!inBackground || !sender.tab) return undefined;
        send('userScripts', 'frame', [{ key: packet.key, tabId: sender.tab.id, frameId: sender.frameId, documentId: sender.documentId }])
          .then(() => sendResponse(true), () => sendResponse(false));
        return true;
      }
      if (packet.kind !== 'message' || !userMessage.listeners.size) return undefined;
      let responded = false, waits = false;
      const respond = (value) => { if (!responded) { responded = true; sendResponse(value); } };
      for (const listener of [...userMessage.listeners]) {
        let result;
        try { result = listener(packet.message, sender, respond); } catch (e) { console.error(e); continue; }
        if (result === true) waits = true;
        else if (result && typeof result.then === 'function') { waits = true; result.then(respond, () => respond(undefined)); }
      }
      return waits && !responded ? true : undefined;
    });

    if (addConnect) addConnect((port) => {
      const info = portInfo(port);
      if (!info || !fromItself(port.sender)) return;
      // A port reaches every page of the extension, and WebKit ends it for all of them when one disconnects: only the
      // background turns away a port nothing listens for. Tampermonkey's popup, kept loaded, ended each port its
      // scripts opened, and they opened them again, over and over.
      if (!userConnect.listeners.size) { if (inBackground) { try { port.disconnect(); } catch (e) {} } return; }
      // The port as the user script named it; its events hand listeners this port, not WebKit's.
      const shown = { name: typeof info.name === 'string' ? info.name : '', sender: port.sender };
      const relayed = (event) => {
        const wrapped = new WeakMap();
        return {
          addListener(f) { if (typeof f !== 'function' || wrapped.has(f)) return; const w = (m) => (m === port ? f(shown) : f(m, shown)); wrapped.set(f, w); event.addListener(w); },
          removeListener(f) { const w = wrapped.get(f); if (w) { event.removeListener(w); wrapped.delete(f); } },
          hasListener(f) { return wrapped.has(f); },
          hasListeners() { return typeof event.hasListeners === 'function' ? event.hasListeners() : false; },
        };
      };
      Object.assign(shown, {
        onMessage: relayed(port.onMessage), onDisconnect: relayed(port.onDisconnect),
        postMessage: (message) => port.postMessage(message),
        disconnect: () => port.disconnect(),
      });
      for (const listener of [...userConnect.listeners]) { try { listener(shown); } catch (e) { console.error(e); } }
    });

    // tabs.sendMessage: Chrome hands it to the tab's user scripts too, when their world listens (Tampermonkey runs
    // its scripts and reloads its pages so). Zigzag sends it to those worlds while WebKit sends it to the content
    // scripts. As in Chrome, the first answer from any of them is the answer, without waiting on the rest: a user
    // script that keeps the channel open and never answers can't hold up a content script's answer. With no answer
    // once all are done, it's undefined, or WebKit's "Receiving end does not exist" only when nothing at all heard it.
    const tabs = api.tabs;
    if (tabs && typeof tabs.sendMessage === 'function') {
      const sendToTab = tabs.sendMessage.bind(tabs);
      const from = (() => { try { return { id: api.runtime.id, url: location.href, origin: location.origin }; } catch (e) { return { id: api.runtime.id }; } })();
      const callWithError = (callback, error) => {
        const runtime = api.runtime;
        const before = Object.getOwnPropertyDescriptor(runtime, 'lastError');
        try { Object.defineProperty(runtime, 'lastError', { get: () => ({ message: String((error && error.message) || error) }), configurable: true }); } catch (e) {}
        try { callback(); } finally { try { if (before) Object.defineProperty(runtime, 'lastError', before); else delete runtime.lastError; } catch (e) {} }
      };
      try {
        tabs.sendMessage = (tabId, message, ...rest) => {
          const callback = typeof rest[rest.length - 1] === 'function' ? rest.pop() : null;
          const options = rest[0] && typeof rest[0] === 'object' ? rest[0] : {};
          const answer = new Promise((resolve, reject) => {
            let script = null, world = null, done = false;
            const finish = (settle, value) => { if (!done) { done = true; settle(value); } };
            // Both sides done and neither answered.
            const unanswered = () => {
              if (done || !script || !world) return;
              if (script.error && !world.reached) finish(reject, script.error); else finish(resolve, undefined);
            };
            Promise.resolve().then(() => sendToTab(tabId, message, ...rest)).then(
              (value) => { if (value !== undefined) finish(resolve, value); else { script = {}; unanswered(); } },
              (error) => { script = { error }; unanswered(); });
            send('userScripts', 'tabMessage', [{ tabId, frameId: options.frameId, documentId: options.documentId }, message, from])
              .then((reply) => reply || { reached: 0 }, () => ({ reached: 0 }))
              .then((reply) => { if (reply.answered) finish(resolve, reply.value); else { world = reply; unanswered(); } });
          });
          if (!callback) return answer;
          answer.then((value) => callback(value), (error) => callWithError(callback, error));
          return undefined;
        };
      } catch (e) {}
    }
  }

  // system.display sits under chrome.system, beside any other system namespace WebKit has.
  if (asked.has('system.display')) {
    for (const target of new Set([globalThis.chrome, globalThis.browser])) {
      if (!target || (target.system && target.system.display)) continue;
      const system = Object.assign({}, target.system, { display: {
        getInfo: (...args) => method('system.display', 'getInfo')(...args.filter((a) => typeof a === 'function')),
        getDisplayLayout: method('system.display', 'getDisplayLayout'),
        onDisplayChanged: event('system.display.onDisplayChanged'),
      } });
      try { Object.defineProperty(target, 'system', { value: system, configurable: true, enumerable: true, writable: true }); } catch (e) {}
    }
  }

  install('power', {
    requestKeepAwake: (level) => { send('power', 'requestKeepAwake', [level]).catch(() => {}); },
    releaseKeepAwake: () => { send('power', 'releaseKeepAwake', []).catch(() => {}); },
    Level: { SYSTEM: 'system', DISPLAY: 'display' },
  });
  return true;
  };
  if (!start() || !guarding) {
    let tries = 0;
    const again = () => { const ready = start() & (!inPage || guard()); if (!ready && ++tries < 100) setTimeout(again, 20); };
    setTimeout(again, 0);
  }
})();
