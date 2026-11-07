// Notes which of a page's Web Audio nodes play to the speakers, so an extension's chrome.tabCapture can hear a page
// that routes its sound through Web Audio (YouTube's Stable Volume, music sites). Added to pages only while an
// installed extension can capture tabs. It records, never changes, what the page connects.
(() => {
  const key = Symbol.for('zigzag.audioRoutes');
  if (window[key] || typeof AudioNode === 'undefined') return;
  const routes = [];
  const native = AudioNode.prototype.connect;
  function connect(destination, ...rest) {
    if (destination instanceof AudioDestinationNode && !routes.some((route) => route.deref() === this)) {
      for (let i = routes.length - 1; i >= 0; i--) if (!routes[i].deref()) routes.splice(i, 1);
      if (routes.length < 500) routes.push(new WeakRef(this));
    }
    return native.call(this, destination, ...rest);
  }
  Object.defineProperty(AudioNode.prototype, 'connect', { value: connect, writable: true, configurable: true });
  Object.defineProperty(window, key, { value: () => routes.map((route) => route.deref()).filter(Boolean) });
})();
