import AppKit

/// The one extension Zigzag knows how to set up: 1Password. It comes from the Chrome Web Store,
/// the same package Chrome users get, and stays updated weekly.
enum KnownExtension {
    static let onePasswordID = "aeblfdkhhhdcdjpifhhbdiojplfjncoa"
    private static let lastUpdateKey = "OnePasswordExtensionUpdated"

    static var directory: URL { Paths.directory("Extensions") }
    static var onePasswordDirectory: URL { directory.appendingPathComponent(onePasswordID, isDirectory: true) }

    static var isOnePasswordAppInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.1password.1password") != nil
            || FileManager.default.fileExists(atPath: "/Applications/1Password.app")
    }

    static var isOnePasswordInstalled: Bool {
        FileManager.default.fileExists(atPath: onePasswordDirectory.appendingPathComponent("manifest.json").path)
    }

    static func installedDirectories() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return items.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }
    }

    /// Sets up 1Password automatically when the 1Password app is on this Mac, and refreshes it weekly.
    static func setUpIfNeeded() {
        guard #available(macOS 15.4, *), isOnePasswordAppInstalled else { return }
        let last = UserDefaults.standard.object(forKey: lastUpdateKey) as? Date ?? .distantPast
        if !isOnePasswordInstalled || Date().timeIntervalSince(last) > 7 * 24 * 3600 {
            Task { await installOnePassword(reload: isOnePasswordInstalled) }
        }
    }

    @discardableResult
    static func installOnePassword(reload: Bool = false) async -> Bool {
        guard #available(macOS 15.4, *) else { return false }
        var components = URLComponents(string: "https://clients2.google.com/service/update2/crx")!
        components.queryItems = [
            .init(name: "response", value: "redirect"),
            .init(name: "prodversion", value: "140.0"),
            .init(name: "acceptformat", value: "crx2,crx3"),
            .init(name: "x", value: "id=\(onePasswordID)&uc"),
        ]
        guard let url = components.url, let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, let zip = zipPayload(ofCRX: data) else { return false }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("zigzag-ext-\(UUID().uuidString)")
        let zipFile = staging.appendingPathExtension("zip")
        do {
            try zip.write(to: zipFile)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-x", "-k", zipFile.path, staging.path]
            try unzip.run()
            unzip.waitUntilExit()
            guard unzip.terminationStatus == 0,
                  FileManager.default.fileExists(atPath: staging.appendingPathComponent("manifest.json").path) else { return false }
            if FileManager.default.fileExists(atPath: onePasswordDirectory.path) {
                _ = try FileManager.default.replaceItemAt(onePasswordDirectory, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: onePasswordDirectory)
            }
            try? FileManager.default.removeItem(at: zipFile)
        } catch {
            return false
        }
        patch(onePasswordDirectory)
        UserDefaults.standard.set(Date(), forKey: lastUpdateKey)
        // A fresh install loads right away; an update takes effect on next launch.
        if !reload { await ExtensionHost.shared.load(from: onePasswordDirectory) }
        return true
    }

    /// Chrome-only APIs that WebKit's extension engine doesn't provide get small stand-ins, loaded before the
    /// extension's own background script, so it starts up instead of stopping at the first missing API.
    static func patch(_ dir: URL) {
        let manifestURL = dir.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              var manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var background = manifest["background"] as? [String: Any],
              var worker = background["service_worker"] as? String else { return }
        if worker == "zigzag-background.js" {
            // Already patched: refresh the shim, keep the original entry.
            worker = (background["zigzag_original_worker"] as? String) ?? "background/background.js"
        }
        background["zigzag_original_worker"] = worker
        let entry = """
        import './zigzag-shim.js';
        import './\(worker)';
        """
        try? entry.write(to: dir.appendingPathComponent("zigzag-background.js"), atomically: true, encoding: .utf8)
        try? shim.write(to: dir.appendingPathComponent("zigzag-shim.js"), atomically: true, encoding: .utf8)
        background["service_worker"] = "zigzag-background.js"
        manifest["background"] = background
        if let out = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted]) {
            try? out.write(to: manifestURL)
        }
    }

    private static let shim = """
    const api = globalThis.chrome || globalThis.browser;
    globalThis.__zigzagReport = (message) => {
      try { api.runtime.sendNativeMessage('app.zigzag.log', { message: String(message).slice(0, 4000) }); } catch (e) {}
    };
    self.addEventListener('error', (e) => __zigzagReport('error: ' + (e.error && e.error.stack || e.message)));
    self.addEventListener('unhandledrejection', (e) => __zigzagReport('rejection: ' + (e.reason && ((e.reason.message || '') + ' @ ' + (e.reason.stack || '').split('\\n')[0]) || e.reason)));
    const noop = () => {};
    const event = () => ({ addListener: noop, removeListener: noop, hasListener: () => false });
    const missing = [];
    const shims = {};
    function ensure(name, value) { if (!api[name]) { shims[name] = value; missing.push(name); } }
    ensure('management', {
      getSelf: async () => ({ id: api.runtime.id, name: '1Password', version: api.runtime.getManifest().version, installType: 'normal', enabled: true, type: 'extension' }),
      getAll: async () => [], onEnabled: event(), onDisabled: event(), onInstalled: event(), onUninstalled: event(),
    });
    ensure('privacy', { services: { passwordSavingEnabled: { get: async () => ({ value: false, levelOfControl: 'not_controllable' }), set: async () => {}, clear: async () => {} },
                                     autofillAddressEnabled: { get: async () => ({ value: false }), set: async () => {} },
                                     autofillCreditCardEnabled: { get: async () => ({ value: false }), set: async () => {} } } });
    ensure('idle', { queryState: async () => 'active', setDetectionInterval: noop, onStateChanged: event() });
    ensure('notifications', { create: async () => '', clear: async () => true, getAll: async () => ({}), onClicked: event(), onClosed: event(), onButtonClicked: event() });
    ensure('downloads', { download: async () => 0, onChanged: event() });
    ensure('offscreen', { createDocument: async () => {}, closeDocument: async () => {}, hasDocument: async () => false });
    // Events missing from namespaces WebKit does have become harmless no-ops.
    const events = {
      webNavigation: ['onCreatedNavigationTarget', 'onReferenceFragmentUpdated', 'onHistoryStateUpdated', 'onTabReplaced', 'onErrorOccurred', 'onBeforeNavigate', 'onCommitted', 'onDOMContentLoaded', 'onCompleted'],
      webRequest: ['onBeforeRedirect', 'onAuthRequired', 'onBeforeRequest', 'onCompleted', 'onErrorOccurred', 'onHeadersReceived', 'onResponseStarted', 'onSendHeaders', 'onBeforeSendHeaders'],
      windows: ['onFocusChanged', 'onCreated', 'onRemoved', 'onBoundsChanged'],
      tabs: ['onCreated', 'onUpdated', 'onRemoved', 'onActivated', 'onReplaced', 'onMoved', 'onAttached', 'onDetached', 'onHighlighted', 'onZoomChange'],
      runtime: ['onInstalled', 'onStartup', 'onMessage', 'onMessageExternal', 'onConnect', 'onConnectExternal', 'onSuspend', 'onUpdateAvailable', 'onRestartRequired'],
      contextMenus: ['onClicked'],
      storage: ['onChanged'],
      permissions: ['onAdded', 'onRemoved'],
      alarms: ['onAlarm'],
      commands: ['onCommand'],
    };
    const additions = {};
    for (const [name, list] of Object.entries(events)) {
      for (const prop of list) {
        if (api[name] && api[name][prop]) continue;
        (additions[name] = additions[name] || {})[prop] = event();
        missing.push(name + '.' + prop);
      }
    }
    const managed = { get: async () => ({}), getBytesInUse: async () => 0, onChanged: event() };
    const constants = {
      windows: { WINDOW_ID_NONE: -1, WINDOW_ID_CURRENT: -2 },
      tabs: { TAB_ID_NONE: -1 },
      storage: { managed: managed },
    };
    const extras = { ...shims };
    const wrappedCache = {};
    function wrap(name, target) {
      if (!target && !extras[name] && !additions[name]) return target;
      if (wrappedCache[name]) return wrappedCache[name];
      const base = target || extras[name] || {};
      const added = { ...(additions[name] || {}), ...(constants[name] || {}) };
      return (wrappedCache[name] = new Proxy(base, {
        get(t, prop) {
          const value = Reflect.get(t, prop);
          if (value !== undefined) return typeof value === 'function' ? value.bind(t) : value;
          return added[prop];
        },
        has(t, prop) { return prop in t || prop in added; }
      }));
    }
    const realChrome = api;
    const proxy = new Proxy(realChrome, {
      get(t, prop) {
        const value = Reflect.get(t, prop);
        if (typeof prop !== 'string') return value;
        if (value === undefined && extras[prop]) return extras[prop];
        if (events[prop] || constants[prop]) return wrap(prop, value);
        return value;
      }
    });
    try { Object.defineProperty(globalThis, 'chrome', { value: proxy, configurable: true, writable: true }); } catch (e) { missing.push('!chrome-not-replaced'); }
    try { Object.defineProperty(globalThis, 'browser', { value: proxy, configurable: true, writable: true }); } catch (e) {}
    setTimeout(() => { if (missing.length) __zigzagReport('shimmed: ' + missing.join(', ')); }, 3000);
    """

    /// A CRX file is a small signed header followed by a plain zip.
    static func zipPayload(ofCRX data: Data) -> Data? {
        guard data.count > 16, data.prefix(4) == Data("Cr24".utf8) else { return nil }
        let version = data.subdata(in: 4..<8).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        if version == 3 {
            let headerSize = Int(data.subdata(in: 8..<12).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })
            return data.subdata(in: (12 + headerSize)..<data.count)
        }
        if version == 2 {
            let keyLength = Int(data.subdata(in: 8..<12).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })
            let sigLength = Int(data.subdata(in: 12..<16).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })
            return data.subdata(in: (16 + keyLength + sigLength)..<data.count)
        }
        return nil
    }
}
