import WebKit

/// Passkeys in a third-party Mac browser need Apple's browser passkey entitlement, which Zigzag doesn't have yet.
/// Without it, WebKit can only offer a phone over Bluetooth, and sign-ins like Google's end on "Something went
/// wrong". Until then, pages are told there are no passkeys here, so they go straight to a password or another way.
enum Passkeys {
    /// Flip on once the entitlement is granted and in Zigzag.entitlements.
    static let available = false

    static func attach(to configuration: WKWebViewConfiguration) {
        guard !available else { return }
        let controller = configuration.userContentController
        guard !controller.userScripts.contains(where: { $0.source.hasPrefix(marker) }) else { return }
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
