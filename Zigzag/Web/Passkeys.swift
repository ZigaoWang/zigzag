import WebKit

/// Passkeys in a third-party Mac browser need Apple's browser passkey entitlement, which Zigzag doesn't have yet.
/// Without it, WebKit can only offer a phone over Bluetooth, and sign-ins like Google's end on "Something went
/// wrong". Until then, pages are told there are no passkeys here, so they go straight to a password or another way.
/// A password manager (1Password and the like) brings its own passkeys, so with one on, pages are left alone.
enum Passkeys {
    /// Flip on once the entitlement is granted and in Zigzag.entitlements.
    static let available = false

    /// Every page's scripts this has been asked about, so turning a password manager on or off reaches them.
    private static let controllers = NSHashTable<WKUserContentController>.weakObjects()

    static func attach(to configuration: WKWebViewConfiguration) {
        guard !available else { return }
        let controller = configuration.userContentController
        controllers.add(controller)
        if !passwordManagerOn { install(in: controller) }
    }

    /// Puts the shim in or takes it out after a password manager is turned on or off. Pages see it from their next load.
    static func refresh() {
        guard !available else { return }
        let wanted = !passwordManagerOn
        for controller in controllers.allObjects where has(controller) != wanted {
            if wanted {
                install(in: controller)
            } else {
                let others = controller.userScripts.filter { !$0.source.hasPrefix(marker) }
                controller.removeAllUserScripts()
                others.forEach(controller.addUserScript)
            }
        }
    }

    /// Read from what's installed and turned on rather than what's loaded, so pages restored at launch, before
    /// extensions finish loading, already get it right.
    private static var passwordManagerOn: Bool {
        guard #available(macOS 15.4, *) else { return false }
        return PasswordManagers.extensionIDs.contains { ExtensionStore.isEnabled($0) && ExtensionStore.isInstalled($0) }
    }

    private static func has(_ controller: WKUserContentController) -> Bool {
        controller.userScripts.contains { $0.source.hasPrefix(marker) }
    }

    private static func install(in controller: WKUserContentController) {
        guard !has(controller) else { return }
        controller.addUserScript(WKUserScript(source: marker + "\n" + shim, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
    }

    private static let marker = "/* zigzag passkeys */"

    private static let shim = """
    (() => {
      try {
        Object.defineProperty(window, 'PublicKeyCredential', { value: undefined, configurable: true, writable: true });
        const credentials = navigator.credentials;
        if (credentials) {
          const unsupported = () => Promise.reject(new DOMException('Passkeys are not available in this browser.', 'NotSupportedError'));
          for (const name of ['get', 'create']) {
            const original = credentials[name] && credentials[name].bind(credentials);
            if (!original) continue;
            credentials[name] = (options) => options && options.publicKey ? unsupported() : original(options);
          }
        }
      } catch (_) {}
    })();
    """
}
