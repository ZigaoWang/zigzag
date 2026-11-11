// Zigzag's ad blocking on YouTube, which serves its video ads from the same servers as its videos, beyond any blocklist.
//
// Runs in YouTube's pages (and its players embedded elsewhere) as they start, while ad blocking is on for them (it
// asks Zigzag; allowing ads on YouTube turns it off). It works the way established blockers do on YouTube:
// - What YouTube sends about each video is edited before the page reads it: its ad slots (adPlacements, adSlots,
//   playerAds) and its warnings about blockers (enforcementMessageViewModel) are renamed so nothing finds them. This
//   is done to the text of its responses (fetch and XHR to /youtubei/), and to the data built into the page.
// - The spaces ads take in the page are hidden, and so is YouTube's note blaming a blocker for slow loading.
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
    // Anything unexpected and the page gets YouTube's response as it came.
    try {
      const original = await response.clone().text();
      const text = rewrite(original);
      if (text === original) return response;
      const edited = new Response(text, { status: response.status, statusText: response.statusText, headers: response.headers });
      for (const name of ['url', 'redirected', 'type']) {
        try { Object.defineProperty(edited, name, { value: response[name] }); } catch (e) {}
      }
      return edited;
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

  // YouTube's note blaming a blocker for slow loading ("Experiencing interruptions? Find out why"): it's about this,
  // so it's left out. Matched by what it says and where it leads, so YouTube's other notes still show.
  const blockerNote = /interruptions|ad ?blockers?/i;
  const quietNotes = () => {
    for (const note of document.querySelectorAll('tp-yt-paper-toast, yt-notification-action-renderer, ytd-popup-container > *')) {
      if (note.dataset.zigzagQuiet) continue;
      const leadsToHelp = !!note.querySelector('a[href*="support.google.com"]');
      if (blockerNote.test(note.textContent || '') || (leadsToHelp && /why/i.test(note.textContent || ''))) {
        note.dataset.zigzagQuiet = '1';
        note.style.setProperty('display', 'none', 'important');
      }
    }
  };

  // A dialog hidden above (the blocker warning, or a note left out) keeps the dimmed backdrop YouTube opened for it,
  // and that backdrop takes every click: the page looks gray and nothing but the keyboard works. While no dialog
  // shows, the backdrop is let go and the page scrolls again; a dialog YouTube shows later brings it back.
  const shown = (element) => {
    if (!element.isConnected || element.dataset.zigzagQuiet) return false;
    if (element.querySelector('ytd-enforcement-message-view-model')) return false;
    const box = element.getBoundingClientRect();
    const look = getComputedStyle(element);
    return box.width > 0 && box.height > 0 && look.display !== 'none' && look.visibility !== 'hidden';
  };
  // The dialog itself is closed too, not only hidden: while YouTube's dialog thinks it's open it also locks the page's
  // scrolling (its overlay swallows the wheel and the scroll keys), so the page took clicks but wouldn't scroll.
  // Only a dialog Zigzag hid is closed: the blocker warning, or a note left out above; any dialog YouTube shows is
  // left alone.
  const ours = (dialog) => !!dialog.querySelector('ytd-enforcement-message-view-model') || !!dialog.dataset.zigzagQuiet
    || !!dialog.querySelector('[data-zigzag-quiet]') || !!dialog.closest('[data-zigzag-quiet]');
  const closeHiddenDialogs = () => {
    for (const dialog of document.querySelectorAll('tp-yt-paper-dialog')) {
      const open = dialog.opened === true || dialog.hasAttribute('opened');
      if (!open || !ours(dialog)) continue;
      try { if (typeof dialog.close === 'function') dialog.close(); else dialog.opened = false; } catch (e) {}
    }
  };
  const freePage = () => {
    closeHiddenDialogs();
    const backdrops = document.querySelectorAll('tp-yt-iron-overlay-backdrop');
    if (!backdrops.length) return;
    const dialogOpen = [...document.querySelectorAll('tp-yt-paper-dialog, ytd-popup-container > *')].some(shown);
    for (const backdrop of backdrops) {
      if (dialogOpen) {
        if (backdrop.dataset.zigzagFreed) { delete backdrop.dataset.zigzagFreed; backdrop.style.removeProperty('display'); }
      } else if (!backdrop.dataset.zigzagFreed && getComputedStyle(backdrop).display !== 'none') {
        backdrop.dataset.zigzagFreed = '1';
        backdrop.style.setProperty('display', 'none', 'important');
        for (const element of [document.documentElement, document.body]) {
          if (element && element.style.overflow === 'hidden') element.style.removeProperty('overflow');
        }
      }
    }
  };

  // MARK: If one plays anyway

  let before = null;
  const check = () => {
    queued = false;
    if (!blocking) return;
    quietNotes();
    freePage();
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
