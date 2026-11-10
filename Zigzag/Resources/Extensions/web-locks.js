// navigator.locks for an extension's own pages and workers.
// WebKit takes a lock request from an extension's address for an invalid message and kills its process
// (WebLockRegistryProxy_RequestLock), background and popup together. Rabby asks as its wallet unlocks. This keeps the
// API's rules, shared and exclusive, ifAvailable, abort and query, within this page or worker: it can't hold a lock
// against the extension's other pages. Stealing a lock is refused; nothing seen so far asks for it.
(() => {
  const mark = Symbol.for('zigzag.webLocks');
  if (globalThis[mark] || !globalThis.navigator || !('locks' in globalThis.navigator) || globalThis.location?.protocol !== 'webkit-extension:') return;
  const navigatorProto = Object.getPrototypeOf(globalThis.navigator);
  try { Object.defineProperty(globalThis, mark, { value: true }); } catch (e) { return; }
  const queues = new Map();
  const canHold = (queue, mode) => !queue.held.length || (mode === 'shared' && queue.held.every((lock) => lock.mode === 'shared'));
  const summary = (lock) => ({ name: lock.name, mode: lock.mode, clientId: '' });
  const advance = (name, queue) => {
    while (queue.pending.length && canHold(queue, queue.pending[0].mode)) start(name, queue, queue.pending.shift());
    if (!queue.held.length && !queue.pending.length) queues.delete(name);
  };
  const start = (name, queue, request) => {
    if (request.stopListening) request.stopListening();
    queue.held.push(request);
    Promise.resolve().then(() => request.callback({ name, mode: request.mode })).then(request.resolve, request.reject).then(() => {
      queue.held.splice(queue.held.indexOf(request), 1);
      advance(name, queue);
    });
  };
  const locks = {
    request(name, ...rest) {
      const callback = rest.pop();
      const options = rest[0] || {};
      const mode = options.mode === undefined ? 'exclusive' : options.mode;
      name = String(name);
      return new Promise((resolve, reject) => {
        if (typeof callback !== 'function') { reject(new TypeError('A lock request needs a callback.')); return; }
        if (mode !== 'exclusive' && mode !== 'shared') { reject(new TypeError(`'${mode}' is not a lock mode.`)); return; }
        if (name.startsWith('-')) { reject(new DOMException('A lock name cannot begin with "-".', 'NotSupportedError')); return; }
        if (options.steal) { reject(new DOMException('Stealing a lock is not supported here.', 'NotSupportedError')); return; }
        const { signal } = options;
        const aborted = () => signal.reason ?? new DOMException('The request was aborted.', 'AbortError');
        if (signal && signal.aborted) { reject(aborted()); return; }
        const queue = queues.get(name) || { held: [], pending: [] };
        queues.set(name, queue);
        if (options.ifAvailable && (queue.pending.length || !canHold(queue, mode))) {
          Promise.resolve().then(() => callback(null)).then(resolve, reject);
          return;
        }
        const request = { name, mode, callback, resolve, reject };
        if (signal) {
          const onAbort = () => { queue.pending.splice(queue.pending.indexOf(request), 1); advance(name, queue); reject(aborted()); };
          signal.addEventListener('abort', onAbort, { once: true });
          request.stopListening = () => signal.removeEventListener('abort', onAbort);
        }
        queue.pending.push(request);
        advance(name, queue);
      });
    },
    query: async () => {
      const all = [...queues.values()];
      return { held: all.flatMap((queue) => queue.held.map(summary)), pending: all.flatMap((queue) => queue.pending.map(summary)) };
    },
  };
  try { Object.defineProperty(navigatorProto, 'locks', { get: () => locks, configurable: true }); } catch (e) {}
})();
