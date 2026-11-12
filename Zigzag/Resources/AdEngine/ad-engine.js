// Zigzag's side of its ad engine (Zigzag/Web/AdFilters.swift): what the app asks Ghostery's adblocker
// (ghostery-adblocker.js, evaluated after this) to do. It runs in a JavaScriptCore context of its own, never in a page.

// A bare JavaScriptCore context has no TextEncoder or TextDecoder, which the engine keeps its filters with.
if (typeof TextEncoder === 'undefined') {
  globalThis.TextEncoder = class TextEncoder {
    get encoding() { return 'utf-8'; }

    encode(string = '') {
      const bytes = new Uint8Array(string.length * 3);
      return bytes.subarray(0, this.encodeInto(string, bytes).written);
    }

    encodeInto(string, bytes) {
      let read = 0;
      let written = 0;
      for (let i = 0; i < string.length;) {
        let code = string.charCodeAt(i);
        let units = 1;
        if (code >= 0xd800 && code <= 0xdbff && i + 1 < string.length) {
          const low = string.charCodeAt(i + 1);
          if (low >= 0xdc00 && low <= 0xdfff) {
            code = 0x10000 + ((code - 0xd800) << 10) + (low - 0xdc00);
            units = 2;
          }
        }
        if (code >= 0xd800 && code <= 0xdfff) code = 0xfffd;
        const size = code < 0x80 ? 1 : code < 0x800 ? 2 : code < 0x10000 ? 3 : 4;
        if (written + size > bytes.length) break;
        if (size === 1) {
          bytes[written] = code;
        } else if (size === 2) {
          bytes[written] = 0xc0 | (code >> 6);
          bytes[written + 1] = 0x80 | (code & 0x3f);
        } else if (size === 3) {
          bytes[written] = 0xe0 | (code >> 12);
          bytes[written + 1] = 0x80 | ((code >> 6) & 0x3f);
          bytes[written + 2] = 0x80 | (code & 0x3f);
        } else {
          bytes[written] = 0xf0 | (code >> 18);
          bytes[written + 1] = 0x80 | ((code >> 12) & 0x3f);
          bytes[written + 2] = 0x80 | ((code >> 6) & 0x3f);
          bytes[written + 3] = 0x80 | (code & 0x3f);
        }
        written += size;
        read += units;
        i += units;
      }
      return { read, written };
    }
  };
}

if (typeof TextDecoder === 'undefined') {
  globalThis.TextDecoder = class TextDecoder {
    get encoding() { return 'utf-8'; }

    decode(input) {
      if (!input) return '';
      const bytes = input instanceof Uint8Array ? input : new Uint8Array(input.buffer || input);
      let out = '';
      let units = [];
      for (let i = 0; i < bytes.length;) {
        const byte = bytes[i];
        let code = 0xfffd;
        let size = 1;
        if (byte < 0x80) {
          code = byte;
        } else if (byte >= 0xc2 && byte < 0xe0 && i + 1 < bytes.length) {
          code = ((byte & 0x1f) << 6) | (bytes[i + 1] & 0x3f);
          size = 2;
        } else if (byte >= 0xe0 && byte < 0xf0 && i + 2 < bytes.length) {
          code = ((byte & 0x0f) << 12) | ((bytes[i + 1] & 0x3f) << 6) | (bytes[i + 2] & 0x3f);
          size = 3;
        } else if (byte >= 0xf0 && byte < 0xf5 && i + 3 < bytes.length) {
          code = ((byte & 0x07) << 18) | ((bytes[i + 1] & 0x3f) << 12) | ((bytes[i + 2] & 0x3f) << 6) | (bytes[i + 3] & 0x3f);
          size = 4;
        }
        if (code > 0xffff) {
          code -= 0x10000;
          units.push(0xd800 + (code >> 10), 0xdc00 + (code & 0x3ff));
        } else {
          units.push(code);
        }
        i += size;
        if (units.length > 8192) {
          out += String.fromCharCode.apply(null, units);
          units = [];
        }
      }
      return out + String.fromCharCode.apply(null, units);
    }
  };
}

var ZigzagAdEngine = (() => {
  // The lists are uBlock Origin's, written for uBlock Origin; Zigzag runs WebKit, as Safari does.
  const environment = new Map([
    ['ext_ublock', true], ['env_safari', true],
    ['env_chromium', false], ['env_firefox', false], ['env_edge', false], ['env_mobile', false],
    ['env_mv3', false], ['ext_ubol', false], ['ext_ghostery', false],
    ['cap_html_filtering', false], ['cap_replace_modifier', false], ['cap_user_stylesheet', false], ['cap_ipaddress', false],
  ]);
  let engine = null;
  // The scriptlets uBlock Origin runs apart from the page's own scripts; the others run beside them.
  let isolated = new Set();

  function adopt(built) {
    isolated = new Set(built.resources.scriptlets.filter((s) => s.executionWorld === 'ISOLATED').map((s) => s.name));
    engine = built;
  }

  return {
    version: () => GhosteryAdblocker.ENGINE_VERSION,

    // The lists as text, the scriptlets as JSON. Only what pages are handed for their own site is kept: Zigzag's
    // content blocker already stops the requests and hides what every site shares.
    build(lists, resources, checksum) {
      const built = GhosteryAdblocker.FiltersEngine.parse(lists.join('\n'), {
        loadNetworkFilters: false, loadCSPFilters: false, loadGenericCosmeticsFilters: false,
        enableHtmlFiltering: false, loadExtendedSelectors: false, enableCompression: false,
        loadPreprocessors: true,
      });
      built.updateEnv(environment);
      built.updateResources(resources, checksum);
      if (built.resources.scriptlets.length === 0) throw new Error('No scriptlets in the resources');
      adopt(built);
      return JSON.stringify({ filters: built.cosmetics.getFilters().length, scriptlets: built.resources.scriptlets.length });
    },

    serialize: () => engine.serialize(),

    load(bytes) {
      adopt(GhosteryAdblocker.FiltersEngine.deserialize(bytes));
    },

    // What a document at this address is given, for its own host: the scriptlets that run beside the page's
    // scripts, those that run apart from them, and a style sheet.
    page(url) {
      const out = { page: [], isolated: [], styles: '' };
      const { hostname, domain } = GhosteryAdblocker.parse(url);
      if (engine === null || !hostname) return JSON.stringify(out);
      const { matches } = engine.matchCosmeticFilters({
        url, hostname, domain: domain || '',
        getRulesFromDOM: false, getRulesFromHostname: true, getInjectionRules: true, getExtendedRules: false,
      });
      const hiding = [];
      const getScriptlet = engine.resources.getScriptlet.bind(engine.resources);
      for (const { filter, exception } of matches) {
        if (filter === undefined || exception !== undefined) continue;
        if (!filter.isScriptInject()) {
          hiding.push(filter);
          continue;
        }
        const parsed = filter.parseScript();
        const script = filter.getScript(getScriptlet);
        if (parsed === undefined || script === undefined) continue;
        (isolated.has(engine.resources.getScriptletCanonicalName(parsed.name)) ? out.isolated : out.page).push(script);
      }
      if (hiding.length !== 0) {
        out.styles = engine.injectCosmeticFilters(hiding, {
          url, injectScriptlets: false, injectExtended: false, allowGenericHides: false, getBaseRules: false,
        }).styles;
      }
      return JSON.stringify(out);
    },
  };
})();
