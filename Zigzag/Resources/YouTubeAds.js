// Zigzag's ad blocking on YouTube, which serves its video ads from the same servers as its videos, beyond any blocklist.
//
// Runs in YouTube's pages (and its players embedded elsewhere) as they start, while ad blocking is on for them (it
// asks Zigzag; allowing ads on YouTube turns it off). Two parts:
// - The ads are taken out of what the player is told to play: each video's details come with its ad slots, and those
//   are left out as the page reads them, so no ad is scheduled.
// - Should one start anyway (YouTube changes often), it's muted, run to its end and skipped, and the video's own
//   sound and speed come back as they were.
// The spaces ads take in the page (the feed, beside the player) are hidden too.
(() => {
  if (!/(^|\.)(youtube|youtube-nocookie)\.com$/.test(location.hostname) || window.__zigzagYouTubeAds) return;
  Object.defineProperty(window, '__zigzagYouTubeAds', { value: true });
  let blocking = true;
  try {
    const answer = window.webkit.messageHandlers.zigzagAds.postMessage('blocking');
    Promise.resolve(answer).then((value) => { blocking = value !== false; style(); }, () => {});
  } catch (e) {}

  // What the player is told: the ad parts are left out.
  const adKeys = ['adPlacements', 'adSlots', 'playerAds', 'adBreakHeartbeatParams', 'adBreakParams'];
  const prune = (value, depth = 0) => {
    if (!blocking || !value || typeof value !== 'object' || depth > 4) return value;
    if (Array.isArray(value)) { for (const item of value) prune(item, depth + 1); return value; }
    for (const key of adKeys) if (key in value) { try { delete value[key]; } catch (e) {} }
    if (value.playerResponse) prune(value.playerResponse, depth + 1);
    if (value.response) prune(value.response, depth + 1);
    return value;
  };
  const parse = JSON.parse;
  JSON.parse = function (...args) { return prune(parse.apply(this, args)); };
  const json = Response.prototype.json;
  Response.prototype.json = function () { return json.call(this).then((value) => prune(value)); };
  for (const name of ['ytInitialPlayerResponse', 'ytInitialData']) {
    let held;
    try { Object.defineProperty(window, name, { configurable: true, get: () => held, set: (value) => { held = prune(value); } }); } catch (e) {}
  }

  // The spaces ads take.
  let sheet = null;
  const style = () => {
    if (!blocking) { sheet && sheet.remove(); sheet = null; return; }
    if (sheet || !document.documentElement) return;
    sheet = document.createElement('style');
    sheet.textContent = [
      'ytd-ad-slot-renderer', 'ytd-in-feed-ad-layout-renderer', 'ytd-banner-promo-renderer', 'ytd-promoted-sparkles-web-renderer',
      'ytd-promoted-video-renderer', 'ytd-display-ad-renderer', 'ytd-companion-slot-renderer', 'ytd-player-legacy-desktop-watch-ads-renderer',
      'ytd-engagement-panel-section-list-renderer[target-id="engagement-panel-ads"]', '#player-ads', '#masthead-ad',
      '.ytp-ad-overlay-container', '.ytp-ad-overlay-slot', 'ytd-rich-item-renderer:has(ytd-ad-slot-renderer)',
      'ytm-promoted-sparkles-web-renderer', 'ad-slot-renderer',
    ].join(', ') + ' { display: none !important; }';
    document.documentElement.appendChild(sheet);
  };
  style();
  document.addEventListener('DOMContentLoaded', style);

  // Should an ad play anyway: muted, to its end, skipped; then the video as it was.
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
      if (Number.isFinite(video.duration) && video.duration > 0 && video.currentTime < video.duration - 0.1) video.currentTime = video.duration;
      document.querySelectorAll('.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button, .ytp-ad-skip-button-slot button').forEach((button) => button.click());
    } else if (before) {
      video.muted = before.muted;
      video.playbackRate = before.rate;
      before = null;
    }
  };
  let queued = false;
  const soon = () => { if (!queued) { queued = true; requestAnimationFrame(check); } };
  const watch = () => new MutationObserver(soon).observe(document.documentElement, { subtree: true, childList: true, attributes: true, attributeFilter: ['class'] });
  if (document.documentElement) watch(); else document.addEventListener('DOMContentLoaded', watch);
})();
