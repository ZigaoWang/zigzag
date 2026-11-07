// The media-element half of chrome.tabCapture (BridgeTabCapture.swift): the body of an async function given `tap`
// (the capture's ID) and `stop`. Runs in Zigzag's own script world, never the page's.
//
// Each <video> and <audio> is routed through Web Audio once. While a capture is on, its sound is mixed down, turned
// into 16-bit samples and handed to Zigzag, and stops playing directly, as a captured tab goes quiet in Chrome (the
// extension plays it if it wants to). Stopping puts the sound back. Elements whose sound comes from another site
// without permission are left alone: Web Audio would silence them. Encrypted (DRM) media gives only silence.
// Answers how many elements it tapped, or -1 when the page can't play sound yet.
const state = (window.__zigzagTap = window.__zigzagTap || { ctx: null, sources: new WeakMap(), taps: new Map() });
if (stop) {
  const current = state.taps.get(tap);
  if (!current) return 0;
  current.processor.disconnect();
  current.mix.disconnect();
  for (const source of current.muted) { try { source.connect(source.context.destination); } catch (e) {} }
  current.observer.disconnect();
  document.removeEventListener('play', current.onPlay, true);
  state.taps.delete(tap);
  return 0;
}
if (!state.ctx) state.ctx = new AudioContext();
const ctx = state.ctx;
// Routing an element through a context that isn't running would silence it: only tap once sound can flow. A new
// context takes a moment to start; one the page hasn't earned (no sound yet) never does.
if (ctx.state !== 'running') {
  try { await Promise.race([ctx.resume(), new Promise((done) => setTimeout(done, 800))]); } catch (e) {}
  if (ctx.state !== 'running') return -1;
}
const muted = new Set();
const mix = ctx.createGain();
const processor = ctx.createScriptProcessor(4096, 2, 1);
mix.connect(processor);
// A processor only runs while connected onward; it writes nothing, so this adds no sound.
processor.connect(ctx.destination);

const sameSite = (element) => {
  const src = element.currentSrc || element.src || '';
  if (!src || src.startsWith('blob:') || src.startsWith('data:')) return true;
  try { return new URL(src, location.href).origin === location.origin || !!element.crossOrigin; } catch (e) { return false; }
};
const attach = (element) => {
  if (!(element instanceof HTMLMediaElement)) return;
  let source = state.sources.get(element);
  if (!source) {
    if (!sameSite(element)) return;
    // Already taken by the page's own Web Audio (it can only be taken once): the page-world half hears it there.
    try { source = ctx.createMediaElementSource(element); } catch (e) { return; }
    source.connect(ctx.destination);
    state.sources.set(element, source);
  }
  source.connect(mix);
  try { source.disconnect(ctx.destination); muted.add(source); } catch (e) {}
};
document.querySelectorAll('video, audio').forEach(attach);
const onPlay = (event) => attach(event.target);
document.addEventListener('play', onPlay, true);
const observer = new MutationObserver((records) => {
  for (const record of records) for (const node of record.addedNodes) {
    if (node instanceof HTMLMediaElement) attach(node);
    else if (node.querySelectorAll) node.querySelectorAll('video, audio').forEach(attach);
  }
});
observer.observe(document.documentElement, { childList: true, subtree: true });

processor.onaudioprocess = (event) => {
  const input = event.inputBuffer;
  const left = input.getChannelData(0), right = input.numberOfChannels > 1 ? input.getChannelData(1) : left;
  const samples = new Int16Array(left.length);
  for (let i = 0; i < left.length; i++) {
    const s = Math.max(-1, Math.min(1, (left[i] + right[i]) / 2));
    samples[i] = s < 0 ? s * 0x8000 : s * 0x7fff;
  }
  const bytes = new Uint8Array(samples.buffer);
  let binary = '';
  for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  window.webkit.messageHandlers.zigzagTap.postMessage({ tap, rate: ctx.sampleRate, pcm: btoa(binary) });
};
state.taps.set(tap, { processor, mix, observer, onPlay, muted });
return muted.size;
