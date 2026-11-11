// Zigzag's ad blocking on YouTube, which serves its video ads from the same servers as its videos, beyond any blocklist.
//
// Runs in YouTube's pages (and its players embedded elsewhere) as they start, while ad blocking is on for them (it
// asks Zigzag: allowing ads on YouTube turns it off, and so does an ad blocker extension, which then handles YouTube
// itself). It does what established blockers do there (uBlock Origin's and AdGuard's YouTube filters), and no more:
// - What YouTube sends about a video has its ads taken out before the page reads it: the keys YouTube keeps them
//   under (adPlacements, adSlots, playerAds), and the blocker warning's (under auxiliaryUi.messageRenderers), at those
//   places only, in its responses (fetch and XHR), in what the page parses and in the data built into the page. A
//   Short that is an ad is taken out of the list of Shorts. Anything that doesn't read as expected reaches the page
//   exactly as YouTube sent it.
// - The places ads take in the page (in the feed, beside a video, the banner on Home) are hidden with a stylesheet.
// - YouTube's own dialogs, overlays, scrolling and controls are never hidden, closed or changed: hiding its blocker
//   warning left the page gray and taking no clicks (#86), then closing it left it not scrolling (#113). A warning
//   that still shows is left whole, so it can be closed.
// - Should an ad play anyway (YouTube changes often), it's muted and played through at 16× (jumping to its end can
//   stall YouTube's ad player), its Skip pressed as soon as there is one; then the sound and speed are put back
//   exactly as they were. Only while YouTube's player shows an ad, never the video itself.
// Nothing here throws into YouTube's code: each change is tried, and on any error the page gets what it would have.
(() => {
  try {
    if (!/(^|\.)(youtube|youtube-nocookie|youtubekids)\.com$/.test(location.hostname) || window.__zigzagYouTubeAds) return;
    Object.defineProperty(window, '__zigzagYouTubeAds', { value: true });
  } catch (e) { return; }

  let blocking = true;
  try {
    const answer = window.webkit.messageHandlers.zigzagAds.postMessage('blocking');
    Promise.resolve(answer).then((value) => { blocking = value !== false; style(); if (!blocking) putBack(); }, () => {});
  } catch (e) {}

  // MARK: What YouTube sends

  // Where a player response keeps its ads, and the places a player response is found. `[]` is every item of a list.
  const adKeys = [
    'adPlacements', 'adSlots', 'playerAds',
    'auxiliaryUi.messageRenderers.enforcementMessageViewModel', 'auxiliaryUi.messageRenderers.bkaEnforcementMessageViewModel',
  ];
  const holders = ['', 'playerResponse.', '[].playerResponse.', 'endpoint.watchEndpoint.unserializedPrefetchData.playerResponse.'];
  const paths = holders.flatMap((holder) => adKeys.map((key) => (holder + key).split('.')));
  const owns = (node, key) => Object.prototype.hasOwnProperty.call(node, key);

  // Removes what's at one path, if it's there. True when something was removed.
  const removeAt = (node, keys, index) => {
    if (!node || typeof node !== 'object') return false;
    const key = keys[index];
    if (key === '[]') {
      if (!Array.isArray(node)) return false;
      let removed = false;
      for (const item of node) removed = removeAt(item, keys, index + 1) || removed;
      return removed;
    }
    if (Array.isArray(node) || !owns(node, key)) return false;
    if (index < keys.length - 1) return removeAt(node[key], keys, index + 1);
    return delete node[key];
  };

  // Shorts that are ads, from the list of Shorts the page plays through.
  const isAdShort = (entry) => {
    try { return !!(entry && entry.command && entry.command.reelWatchEndpoint && entry.command.reelWatchEndpoint.adClientParams.isAd); } catch (e) { return false; }
  };
  const dropAdShorts = (node) => {
    let removed = false;
    for (const owner of [node, node.reelWatchSequenceResponse]) {
      const entries = owner && typeof owner === 'object' && owns(owner, 'entries') ? owner.entries : null;
      if (!Array.isArray(entries)) continue;
      for (let i = entries.length - 1; i >= 0; i--) if (isAdShort(entries[i])) { entries.splice(i, 1); removed = true; }
    }
    return removed;
  };

  // Takes the ads out of what YouTube sent, in place. True when anything was taken out; never throws.
  const prune = (value) => {
    if (!blocking || !value || typeof value !== 'object') return false;
    let removed = false;
    try {
      for (const keys of paths) removed = removeAt(value, keys, 0) || removed;
      removed = dropAdShorts(value) || removed;
    } catch (e) {}
    return removed;
  };

  // Text of a response, with the ads taken out; the same text when it isn't JSON or has none.
  const nativeParse = JSON.parse;
  const nativeStringify = JSON.stringify;
  const pruneText = (text) => {
    if (!blocking || typeof text !== 'string' || text.length < 2) return text;
    try {
      const value = nativeParse(text);
      return prune(value) ? nativeStringify(value) : text;
    } catch (e) {
      return text;
    }
  };

  // The requests that bring a video's player response, or the list of Shorts.
  const carriesAds = (url) => {
    try {
      return /\/youtubei\/v1\/(player|get_watch|reel\/reel_watch_sequence|navigation\/resolve_url)\b|\/(watch|playlist)\?/.test(String(url || ''));
    } catch (e) {
      return false;
    }
  };

  // Each change to the page's own functions is a Proxy around the original, as blockers make them: it still calls
  // the original, and still reads as the browser's own to the page.
  const wrap = (owner, name, handler) => {
    try {
      const original = owner[name];
      if (typeof original === 'function') owner[name] = new Proxy(original, handler);
    } catch (e) {}
  };

  // What the page parses itself.
  wrap(JSON, 'parse', {
    apply(target, self, args) {
      const value = Reflect.apply(target, self, args);
      prune(value);
      return value;
    },
  });

  // fetch: a response that carried ads is handed on without them, otherwise the one YouTube sent.
  const edited = async (response) => {
    try {
      if (!blocking || !(response instanceof Response) || response.bodyUsed) return response;
      const original = await response.clone().text();
      const text = pruneText(original);
      if (text === original) return response;
      const headers = new Headers(response.headers);
      headers.delete('content-length');
      const copy = new Response(text, { status: response.status, statusText: response.statusText, headers });
      for (const name of ['url', 'redirected', 'type']) {
        try { Object.defineProperty(copy, name, { value: response[name] }); } catch (e) {}
      }
      return copy;
    } catch (e) {
      return response;
    }
  };
  wrap(window, 'fetch', {
    apply(target, self, args) {
      const pending = Reflect.apply(target, self, args);
      let url = '';
      try { url = typeof args[0] === 'string' ? args[0] : (args[0] && args[0].url) || String(args[0]); } catch (e) {}
      if (!blocking || !carriesAds(url) || !pending || typeof pending.then !== 'function') return pending;
      return pending.then(edited);
    },
  });

  // XHR: what the page reads of a finished response, without the ads. Worked out once for each response.
  const requested = new WeakMap();
  const read = new WeakMap();
  wrap(XMLHttpRequest.prototype, 'open', {
    apply(target, self, args) {
      try { requested.set(self, carriesAds(args[1])); read.delete(self); } catch (e) {}
      return Reflect.apply(target, self, args);
    },
  });
  for (const name of ['responseText', 'response']) {
    try {
      const descriptor = Object.getOwnPropertyDescriptor(XMLHttpRequest.prototype, name);
      if (!descriptor || typeof descriptor.get !== 'function' || !descriptor.configurable) continue;
      const getter = new Proxy(descriptor.get, {
        apply(target, self, args) {
          const value = Reflect.apply(target, self, args);
          try {
            if (!blocking || !requested.get(self) || self.readyState !== 4) return value;
            if (value && typeof value === 'object') { prune(value); return value; }
            if (typeof value !== 'string') return value;
            const known = read.get(self);
            if (known && known.original === value) return known.text;
            const text = pruneText(value);
            read.set(self, { original: value, text });
            return text;
          } catch (e) {
            return value;
          }
        },
      });
      Object.defineProperty(XMLHttpRequest.prototype, name, { ...descriptor, get: getter });
    } catch (e) {}
  }

  // The data built into the page: set as it loads, and read by the page after. Something else that already watches
  // the same name (another blocker) keeps doing so, and is handed what this leaves.
  const watch = (name) => {
    try {
      const before = Object.getOwnPropertyDescriptor(window, name);
      if (before && !before.configurable) return;
      let held;
      if (before && 'value' in before) { held = before.value; prune(held); }
      Object.defineProperty(window, name, {
        configurable: true,
        enumerable: before ? before.enumerable : true,
        get() { return before && before.get ? before.get.call(this) : held; },
        set(value) {
          prune(value);
          if (before && before.set) before.set.call(this, value); else held = value;
        },
      });
    } catch (e) {}
  };
  watch('ytInitialPlayerResponse');
  watch('ytInitialReelWatchSequenceResponse');

  // MARK: What shows

  // Only the places ads take. Never a dialog, overlay or control of YouTube's own.
  const adPlaces = [
    'ytd-ad-slot-renderer', 'ytd-rich-item-renderer:has(> #content > ytd-ad-slot-renderer)', 'ytd-in-feed-ad-layout-renderer',
    'ytd-display-ad-renderer', 'ytd-promoted-sparkles-web-renderer', 'ytd-promoted-video-renderer', 'ytd-search-pyv-renderer',
    'ytd-companion-slot-renderer', 'ytd-player-legacy-desktop-watch-ads-renderer', 'ytd-banner-promo-renderer', '#masthead-ad',
    'ytd-rich-section-renderer:has(ytd-statement-banner-renderer)', 'ytd-merch-shelf-renderer',
    'ytd-engagement-panel-section-list-renderer[target-id="engagement-panel-ads"]',
    'ytm-promoted-sparkles-web-renderer', 'ad-slot-renderer', '.ytp-ad-overlay-slot', '.ytp-ad-overlay-container',
  ];
  let sheet = null;
  const style = () => {
    try {
      if (!blocking) { if (sheet) sheet.remove(); sheet = null; return; }
      if (sheet || !document.documentElement) return;
      sheet = document.createElement('style');
      sheet.textContent = adPlaces.join(',\n') + ' { display: none !important; }';
      document.documentElement.appendChild(sheet);
    } catch (e) {}
  };
  style();
  try { document.addEventListener('DOMContentLoaded', style); } catch (e) {}

  // MARK: If one plays anyway

  // YouTube's player marks itself while it plays an ad, and shows the ad's own badge or countdown; both are needed,
  // so a mark left behind on the video never speeds it up.
  const adShowing = (player) => (player.classList.contains('ad-showing') || player.classList.contains('ad-interrupting'))
    && !!player.querySelector('.ytp-ad-player-overlay, .ytp-ad-player-overlay-layout, .ytp-ad-preview-container, .ytp-ad-badge, .ytp-ad-simple-ad-badge, .ytp-ad-duration-remaining, .ytp-ad-text');
  // The video's own sound and speed, while an ad plays faster and muted; and what was set for the ad, to tell a
  // change you made meanwhile (which stays) from Zigzag's own.
  let saved = null;
  const putBack = () => {
    if (!saved) return;
    const { video, muted, rate, mutedByUs } = saved;
    saved = null;
    try { if (video.playbackRate === 16 && video.playbackRate !== rate) video.playbackRate = rate; } catch (e) {}
    try { if (mutedByUs && video.muted && !muted) video.muted = false; } catch (e) {}
  };
  const check = () => {
    try {
      if (!blocking) { putBack(); return; }
      const player = document.querySelector('.html5-video-player');
      const video = player && player.querySelector('video');
      if (!player || !video || !adShowing(player)) { putBack(); return; }
      if (saved && saved.video !== video) putBack();
      if (!saved) {
        saved = { video, muted: video.muted, rate: video.playbackRate, mutedByUs: !video.muted };
        if (!video.muted) video.muted = true;
      }
      if (video.playbackRate !== 16) { try { video.playbackRate = 16; } catch (e) {} }
      // The ad's Skip, by YouTube's names for it.
      for (const button of player.querySelectorAll('.ytp-skip-ad-button, .ytp-ad-skip-button, .ytp-ad-skip-button-modern')) {
        try { button.click(); } catch (e) {}
      }
    } catch (e) {}
  };
  // Media events don't bubble, but reach the document first: an ad is caught as it starts, and its end at the next
  // moment the video plays on.
  try { for (const name of ['loadstart', 'playing', 'timeupdate', 'ratechange']) document.addEventListener(name, check, true); } catch (e) {}
})();
