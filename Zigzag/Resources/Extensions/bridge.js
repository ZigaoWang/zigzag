// Chrome extension APIs WebKit doesn't have, answered by Zigzag itself (ExtensionBridge.swift).
//
// Runs before an extension's own code, in its background and in its pages. Each namespace here is installed only
// when the extension asked for its permission in its manifest, and only when WebKit doesn't already provide it. Calls
// travel as native messages to "zigzag.bridge"; events come back over a port opened once something listens.
(() => {
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

  install('sidePanel', {
    setOptions: method('sidePanel', 'setOptions'),
    getOptions: method('sidePanel', 'getOptions'),
    setPanelBehavior: method('sidePanel', 'setPanelBehavior'),
    getPanelBehavior: method('sidePanel', 'getPanelBehavior'),
    open: method('sidePanel', 'open'),
    close: method('sidePanel', 'close'),
    onOpened: event('sidePanel.onOpened'),
    onClosed: event('sidePanel.onClosed'),
  });

  // A capture that switches to Zigzag's own sound (streamed video, whose sound Web Audio can't reach) leaves the tab
  // playing, so whatever the extension sends from it to the speakers would be heard twice, and come back around into
  // the capture as an echo. From then on such paths go through a silent node: the extension's processing still runs
  // (a recorder's ScriptProcessor needs a path to the speakers to run at all), but nothing more is heard.
  const captures = new WeakMap();   // MediaStream -> { live, edges, elements }
  const reaching = new WeakMap();   // AudioNode fed by a captured stream -> its capture
  const silent = new WeakMap();     // AudioContext -> a gain of 0 into its speakers
  let connectQuietly = null;
  if (typeof AudioNode !== 'undefined' && typeof AudioContext !== 'undefined') {
    const connect = AudioNode.prototype.connect;
    const silence = (context) => {
      let node = silent.get(context);
      if (!node) { node = context.createGain(); node.gain.value = 0; connect.call(node, context.destination); silent.set(context, node); }
      return node;
    };
    connectQuietly = (node, destination) => connect.call(node, silence(destination.context));
    const createSource = AudioContext.prototype.createMediaStreamSource;
    AudioContext.prototype.createMediaStreamSource = function (stream) {
      const node = createSource.call(this, stream);
      const capture = captures.get(stream);
      if (capture) reaching.set(node, capture);
      return node;
    };
    AudioNode.prototype.connect = function (destination, ...rest) {
      const capture = reaching.get(this);
      if (capture && destination instanceof AudioNode) {
        if (destination instanceof AudioDestinationNode) {
          if (capture.live) { connectQuietly(this, destination); return destination; }
          capture.edges.push([new WeakRef(this), destination]);
        } else {
          reaching.set(destination, capture);
        }
      }
      return connect.call(this, destination, ...rest);
    };
    const srcObject = typeof HTMLMediaElement !== 'undefined' && Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'srcObject');
    if (srcObject && srcObject.set) {
      Object.defineProperty(HTMLMediaElement.prototype, 'srcObject', {
        configurable: true, enumerable: srcObject.enumerable, get: srcObject.get,
        set(value) {
          const capture = value && captures.get(value);
          if (capture) { capture.elements.add(this); if (capture.live) this.muted = true; }
          srcObject.set.call(this, value);
        },
      });
    }
  }
  const quiet = (capture) => {
    capture.live = true;
    for (const [ref, destination] of capture.edges) {
      const node = ref.deref();
      if (!node) continue;
      try { node.disconnect(destination); } catch (e) {}
      try { connectQuietly && connectQuietly(node, destination); } catch (e) {}
    }
    capture.edges = [];
    for (const element of capture.elements) element.muted = true;
  };

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
    const capture = { live: false, edges: [], elements: new Set() };
    const receive = (tap, rate, pcm, at, live) => {
      if (tap !== id) return;
      if (live && !capture.live) quiet(capture);
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
    // Collected from Zigzag about fifty times a second while the stream lives.
    let live = true;
    const collect = async () => {
      if (!live) return;
      try {
        const chunks = await send('tabCapture', 'read', [id]);
        // Nothing at all (not even an empty list): the capture has ended.
        if (chunks == null) { live = false; return; }
        for (const chunk of chunks) receive(id, ...chunk);
      } catch (e) {}
      setTimeout(collect, 20);
    };
    collect();
    const stream = destination.stream;
    captures.set(stream, capture);
    for (const track of stream.getAudioTracks()) {
      const stop = track.stop.bind(track);
      track.stop = () => {
        stop();
        live = false;
        player.disconnect();
        context.close().catch(() => {});
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

  // runtime.getContexts: Zigzag knows which of the extension's pages are open (its offscreen page, popup, side panel).
  if (typeof api.runtime.getContexts !== 'function') {
    try { api.runtime.getContexts = method('contexts', 'getContexts'); } catch (e) {}
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
