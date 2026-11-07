// Zigzag's ad blocking on YouTube, which serves its video ads from the same servers as its videos, beyond any blocklist.
//
// Runs in YouTube's pages (and its players embedded elsewhere) as they start, while ad blocking is on for them (it
// asks Zigzag; allowing ads on YouTube turns it off). It works the way established blockers do on YouTube:
// - What YouTube sends about each video is edited before the page reads it: its ad slots (adPlacements, adSlots,
//   playerAds) and its warnings about blockers (enforcementMessageViewModel) are renamed so nothing finds them. This
//   is done to the text of its responses (fetch and XHR to /youtubei/), and to the data built into the page.
// - The spaces ads take in the page are hidden.
// - Should an ad start anyway (YouTube changes often), it's hidden and muted and plays through at 16× (jumping to its
//   end can stall YouTube's ad player), its Skip pressed as soon as there is one; then the video's own sound and
//   speed come back as they were.
(() => {
  if (!/(^|\.)(youtube|youtube-nocookie)\.com$/.test(location.hostname) || window.__zigzagYouTubeAds) return;
  Object.defineProperty(window, '__zigzagYouTubeAds', { value: true });
  let blocking = true;
  try {
    const answer = window.webkit.messageHandlers.zigzagAds.postMessage('blocking');
    Promise.resolve(answer).then((value) => { blocking = value !== false; style(); }, () => {});
  } catch (e) {}

  // MARK: What YouTube sends

  // Renamed, not removed: the rest of the response stays exactly as YouTube wrote it.
  const fields = ['adPlacements', 'adSlots', 'playerAds', 'adBreakHeartbeatParams', 'enforcementMessageViewModel'];
  const fieldPattern = new RegExp('"(' + fields.join('|') + ')"', 'g');
  const rewrite = (text) => (blocking && typeof text === 'string' && text.search(fieldPattern) >= 0 ? text.replace(fieldPattern, '"zz_$1"') : text);
  const isData = (url) => /\/youtubei\/v1\/(player|next|browse|reel|search|get_watch)/.test(String(url || ''));

  // fetch: the response for YouTube's data is handed on with the fields renamed.
  const nativeFetch = window.fetch;
  window.fetch = async function (input, init) {
    const response = await nativeFetch.apply(this, arguments);
    const url = typeof input === 'string' ? input : input && input.url;
    if (!blocking || !isData(url)) return response;
    try {
      const text = rewrite(await response.clone().text());
      return new Response(text, { status: response.status, statusText: response.statusText, headers: response.headers });
    } catch (e) {
      return response;
    }
  };

  // XHR: the same, for what the page reads of it.
  const open = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (method, url) {
    this.__zigzagData = isData(url);
    return open.apply(this, arguments);
  };
  for (const name of ['responseText', 'response']) {
    const descriptor = Object.getOwnPropertyDescriptor(XMLHttpRequest.prototype, name);
    if (!descriptor || !descriptor.get) continue;
    Object.defineProperty(XMLHttpRequest.prototype, name, {
      configurable: true, enumerable: descriptor.enumerable,
      get() {
        const value = descriptor.get.call(this);
        return this.__zigzagData && typeof value === 'string' ? rewrite(value) : value;
      },
    });
  }

  // The data built into the page, and anything it parses itself.
  const prune = (value, depth = 0) => {
    if (!blocking || !value || typeof value !== 'object' || depth > 6) return value;
    if (Array.isArray(value)) { for (const item of value) prune(item, depth + 1); return value; }
    for (const key of fields) if (key in value) { try { delete value[key]; } catch (e) {} }
    for (const key of ['playerResponse', 'response', 'auxiliaryUi', 'messageRenderers', 'playerConfig']) {
      if (value[key] && typeof value[key] === 'object') prune(value[key], depth + 1);
    }
    return value;
  };
  for (const name of ['ytInitialPlayerResponse', 'ytInitialData', 'ytInitialReelWatchSequenceResponse']) {
    let held;
    try { Object.defineProperty(window, name, { configurable: true, get: () => held, set: (value) => { held = prune(value); } }); } catch (e) {}
  }
  const parse = JSON.parse;
  JSON.parse = function (...args) {
    const value = parse.apply(this, args);
    return value && typeof value === 'object' && ('playerResponse' in value || 'adPlacements' in value || 'playerAds' in value) ? prune(value) : value;
  };

  // MARK: What shows

  let sheet = null;
  const style = () => {
    if (!blocking) { sheet && sheet.remove(); sheet = null; return; }
    if (sheet || !document.documentElement) return;
    sheet = document.createElement('style');
    sheet.textContent = [
      'ytd-ad-slot-renderer', 'ytd-in-feed-ad-layout-renderer', 'ytd-banner-promo-renderer', 'ytd-promoted-sparkles-web-renderer',
      'ytd-promoted-video-renderer', 'ytd-display-ad-renderer', 'ytd-companion-slot-renderer', 'ytd-player-legacy-desktop-watch-ads-renderer',
      'ytd-engagement-panel-section-list-renderer[target-id="engagement-panel-ads"]', '#player-ads', '#masthead-ad',
      'ytd-rich-item-renderer:has(ytd-ad-slot-renderer)', 'ytd-rich-section-renderer:has(ytd-statement-banner-renderer)',
      'ytm-promoted-sparkles-web-renderer', 'ad-slot-renderer', 'ytd-enforcement-message-view-model',
      '.ytp-ad-overlay-container', '.ytp-ad-overlay-slot', '.video-ads', '.ytp-ad-module', '.ytp-ad-player-overlay',
      '.ytp-ad-player-overlay-layout', '.ytp-ad-text', '.ytp-ad-preview-container', '.ytp-ad-message-container',
    ].join(', ') + ' { display: none !important; }' +
      ' .html5-video-player.ad-showing video, .html5-video-player.ad-interrupting video { opacity: 0 !important; }';
    document.documentElement.appendChild(sheet);
  };
  style();
  document.addEventListener('DOMContentLoaded', style);

  // MARK: If one plays anyway

  let before = null;
  const check = () => {
    queued = false;
    if (!blocking) return;
    const player = document.querySelector('.html5-video-player');
    const video = player && player.querySelector('video');
    if (!player || !video) return;
    if (player.classList.contains('ad-showing') || player.classList.contains('ad-interrupting')) {
      if (!before) before = { muted: video.muted, rate: video.playbackRate };
      video.muted = true;
      if (video.playbackRate !== 16) video.playbackRate = 16;
      if (video.paused && !video.ended) video.play().catch(() => {});
      // Skip, under whichever name YouTube gives it.
      player.querySelectorAll('button, [role="button"]').forEach((button) => {
        const name = (button.className || '') + ' ' + (button.getAttribute('aria-label') || '') + ' ' + (button.id || '');
        if (/skip/i.test(name) && !/skip-?navigation/i.test(name)) button.click();
      });
    } else if (before) {
      video.muted = before.muted;
      video.playbackRate = before.rate;
      before = null;
    }
  };
  let queued = false;
  const soon = () => { if (!queued) { queued = true; requestAnimationFrame(check); } };
  // An ad can start with no change the observer sees: a light check alongside.
  setInterval(() => { if (document.visibilityState === 'visible' || before) check(); }, 300);
  const watch = () => new MutationObserver(soon).observe(document.documentElement, { subtree: true, childList: true, attributes: true, attributeFilter: ['class'] });
  if (document.documentElement) watch(); else document.addEventListener('DOMContentLoaded', watch);
})();
