// addons.mozilla.org's install button says "Add to Zigzag"; nothing else on the page changes.
(() => {
  if (location.protocol !== 'https:' || location.host !== 'addons.mozilla.org' || window.top !== window) return;
  // Filled in by Zigzag (AddonsStoreButton.source).
  const config = {};
  if (!config.add) return;

  // The store's file endpoint, as ExtensionStore.isAddonsFile takes it.
  const isFile = (href) => {
    try {
      const url = new URL(href, location.href);
      return url.protocol === 'https:' && url.host === 'addons.mozilla.org' && /^\/(?:[^/]+\/)?firefox\/downloads\//.test(url.pathname);
    } catch (e) { return false; }
  };
  // Only an extension's listing: themes, the versions page and "Download file" links keep the store's words.
  const rename = (root) => {
    for (const button of root.querySelectorAll('.Addon-extension .AMInstallButton a.AMInstallButton-button[href]')) {
      if (!isFile(button.getAttribute('href'))) continue;
      const texts = [...button.childNodes].filter((node) => node.nodeType === Node.TEXT_NODE && node.data.trim());
      if (texts.length !== 1 || button.children.length > 0) continue;
      // In place, so the store's own text node stays the one it redraws.
      if (texts[0].data !== config.add) texts[0].data = config.add;
    }
  };
  const observer = new MutationObserver(() => rename(document));
  const start = () => {
    rename(document);
    observer.observe(document.documentElement, { childList: true, subtree: true, characterData: true });
  };
  if (document.documentElement) start(); else document.addEventListener('readystatechange', start, { once: true });
})();
