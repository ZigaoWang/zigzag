// Zigzag's ad blocking on YouTube, which serves its video ads from the same servers as its videos, beyond any blocklist.
//
// Runs in YouTube's pages (and its players embedded elsewhere) as they start, while ad blocking is on for them (it
// asks Zigzag; allowing ads on YouTube turns it off). An ad that starts is muted, run to its end and skipped at once,
// and the video's own sound and speed come back as they were. Ads aren't taken out before they're scheduled: YouTube
// notices players that never get theirs, then slows videos down and says so ("Experiencing interruptions?").
// The spaces ads take in the page (the feed, beside the player) are hidden too.
(() => {
  if (!/(^|\.)(youtube|youtube-nocookie)\.com$/.test(location.hostname) || window.__zigzagYouTubeAds) return;
  Object.defineProperty(window, '__zigzagYouTubeAds', { value: true });
  let blocking = true;
  try {
    const answer = window.webkit.messageHandlers.zigzagAds.postMessage('blocking');
    Promise.resolve(answer).then((value) => { blocking = value !== false; style(); }, () => {});
  } catch (e) {}

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
      // While an ad is being skipped, nothing of it shows: its picture, its countdown, its labels.
      '.video-ads', '.ytp-ad-module', '.ytp-ad-player-overlay', '.ytp-ad-player-overlay-layout', '.ytp-ad-text', '.ytp-ad-preview-container',
      '.ytp-ad-message-container', '.ytp-ad-persistent-progress-bar-container',
    ].join(', ') + ' { display: none !important; }' +
      ' .html5-video-player.ad-showing video, .html5-video-player.ad-interrupting video { opacity: 0 !important; }';
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
      video.playbackRate = 16;
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
  // Some ads start with no change the observer sees: a light check alongside, a few times a second.
  setInterval(() => { if (document.visibilityState === 'visible' || before) check(); }, 300);
  const watch = () => new MutationObserver(soon).observe(document.documentElement, { subtree: true, childList: true, attributes: true, attributeFilter: ['class'] });
  if (document.documentElement) watch(); else document.addEventListener('DOMContentLoaded', watch);
})();
