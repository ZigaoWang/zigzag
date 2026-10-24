import AppKit

/// Extensions come from the Chrome Web Store, the same packages Chrome users get. 1Password is set up on its
/// own when its app is on this Mac; anything else you add from the store. All of them refresh weekly.
enum KnownExtension {
    static let onePasswordID = "aeblfdkhhhdcdjpifhhbdiojplfjncoa"
    private static let lastUpdateKey = "OnePasswordExtensionUpdated"
    private static let disabledKey = "DisabledExtensions"
    private static let removedKey = "RemovedExtensions"

    static var directory: URL { Paths.directory("Extensions") }
    static var onePasswordDirectory: URL { directory(for: onePasswordID) }
    static func directory(for id: String) -> URL { directory.appendingPathComponent(id, isDirectory: true) }

    static var isOnePasswordAppInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.1password.1password") != nil
            || FileManager.default.fileExists(atPath: "/Applications/1Password.app")
    }

    static var isOnePasswordInstalled: Bool { isInstalled(onePasswordID) }

    static func isInstalled(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: directory(for: id).appendingPathComponent("manifest.json").path)
    }

    static func installedDirectories() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return items.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: On and off

    static var disabledIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: disabledKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: disabledKey) }
    }

    static func isEnabled(_ id: String) -> Bool { !disabledIDs.contains(id) }

    /// Removing 1Password is remembered, so it isn't set up again behind your back.
    private static var removedIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: removedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: removedKey) }
    }

    // MARK: The Chrome Web Store

    static let webStoreURL = URL(string: "https://chromewebstore.google.com/category/extensions")!

    /// The extension id in a Chrome Web Store page address, e.g. chromewebstore.google.com/detail/ublock-origin-lite/ddkjiahejlhfcafbddmgiahcphecmpfh.
    static func webStoreID(from url: URL?) -> String? {
        guard let url, let host = url.host(), host == "chromewebstore.google.com" || host == "chrome.google.com" else { return nil }
        let parts = url.pathComponents
        guard let detail = parts.firstIndex(of: "detail") else { return nil }
        return parts[(detail + 1)...].first { $0.count == 32 && $0.allSatisfy { ("a"..."p").contains($0) } }
    }

    /// Sets up 1Password automatically when the 1Password app is on this Mac, and refreshes everything weekly.
    static func setUpIfNeeded() {
        guard #available(macOS 15.4, *) else { return }
        let last = UserDefaults.standard.object(forKey: lastUpdateKey) as? Date ?? .distantPast
        let stale = Date().timeIntervalSince(last) > 7 * 24 * 3600
        Task {
            if isOnePasswordAppInstalled, !isOnePasswordInstalled, !removedIDs.contains(onePasswordID) {
                await install(onePasswordID)
            }
            guard stale else { return }
            for dir in installedDirectories() { await install(dir.lastPathComponent, update: true) }
            UserDefaults.standard.set(Date(), forKey: lastUpdateKey)
        }
    }

    /// Downloads an extension from the Chrome Web Store and loads it. An update replaces the files and takes
    /// effect on the next launch. Returns the extension's name, or nil if it couldn't be installed.
    @discardableResult
    static func install(_ id: String, update: Bool = false) async -> String? {
        guard #available(macOS 15.4, *) else { return nil }
        var components = URLComponents(string: "https://clients2.google.com/service/update2/crx")!
        components.queryItems = [
            .init(name: "response", value: "redirect"),
            .init(name: "prodversion", value: "140.0"),
            .init(name: "acceptformat", value: "crx2,crx3"),
            .init(name: "x", value: "id=\(id)&uc"),
        ]
        guard let url = components.url, let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, let zip = zipPayload(ofCRX: data) else { return nil }
        let target = directory(for: id)
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
            try? FileManager.default.removeItem(at: zipFile)
            guard unzip.terminationStatus == 0,
                  FileManager.default.fileExists(atPath: staging.appendingPathComponent("manifest.json").path) else { return nil }
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: target)
            }
        } catch {
            return nil
        }
        patch(target)
        removedIDs.remove(id)
        if update { return id }
        let context = await ExtensionHost.shared.load(from: target)
        return context?.webExtension.displayName ?? id
    }

    /// Takes the extension out of Zigzag and deletes its files.
    static func uninstall(_ id: String) {
        guard #available(macOS 15.4, *) else { return }
        ExtensionHost.shared.unload(id)
        try? FileManager.default.removeItem(at: directory(for: id))
        disabledIDs.remove(id)
        removedIDs.insert(id)
        ExtensionHost.shared.forget(id)
    }

    static func setEnabled(_ id: String, _ enabled: Bool) {
        guard #available(macOS 15.4, *), isEnabled(id) != enabled else { return }
        if enabled {
            disabledIDs.remove(id)
            Task { await ExtensionHost.shared.load(from: directory(for: id)) }
        } else {
            disabledIDs.insert(id)
            ExtensionHost.shared.unload(id)
        }
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
        // Manifests write the worker as "js/background.js" or "/js/background.js"; both mean the extension's root.
        let path = worker.hasPrefix("/") ? String(worker.dropFirst()) : worker
        // A module worker imports; a classic one (which may itself call importScripts) loads both scripts in order.
        let entry = (background["type"] as? String) == "module" ? """
        import './zigzag-shim.js';
        import './\(path)';
        """ : """
        importScripts('zigzag-shim.js', '\(path)');
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
      getSelf: async () => ({ id: api.runtime.id, name: api.runtime.getManifest().name, version: api.runtime.getManifest().version, installType: 'normal', enabled: true, type: 'extension' }),
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
