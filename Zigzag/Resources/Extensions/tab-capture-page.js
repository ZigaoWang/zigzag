// The page-world half of chrome.tabCapture (BridgeTabCapture.swift): the body of an async function given `tap` and
// `stop`. Taps the Web Audio nodes the page plays to its speakers (noted by audio-routes.js), mixes them down and
// hands 16-bit samples to Zigzag. While captured, those nodes stop playing directly, as a captured tab goes quiet in
// Chrome: the extension decides whether to play the sound (Shazam does). Stopping puts everything back.
const taps = (window[Symbol.for('zigzag.taps')] = window[Symbol.for('zigzag.taps')] || new Map());
if (stop) {
  const current = taps.get(tap);
  if (!current) return 'stopped';
  for (const { node, context } of current.muted) { try { node.connect(context.destination); } catch (e) {} }
  for (const part of current.parts) { part.processor.disconnect(); part.mix.disconnect(); }
  taps.delete(tap);
  return 'stopped';
}
const nodes = (window[Symbol.for('zigzag.audioRoutes')] || (() => []))();
const byContext = new Map();
for (const node of nodes) {
  if (node.context.state === 'closed') continue;
  if (!byContext.has(node.context)) byContext.set(node.context, []);
  byContext.get(node.context).push(node);
}
const parts = [], muted = [];
for (const [context, list] of byContext) {
  if (context.state !== 'running') continue;
  const mix = context.createGain();
  const processor = context.createScriptProcessor(512, 2, 1);
  mix.connect(processor);
  processor.connect(context.destination);
  for (const node of list) {
    try { node.connect(mix); node.disconnect(context.destination); muted.push({ node, context }); } catch (e) {}
  }
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
    window.webkit.messageHandlers.zigzagTap.postMessage({ tap, rate: context.sampleRate, pcm: btoa(binary), at: Date.now() });
  };
  parts.push({ mix, processor });
}
taps.set(tap, { parts, muted });
return muted.length;
