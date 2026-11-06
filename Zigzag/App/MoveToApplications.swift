import AppKit

/// Zigzag opened straight from its disk image, or from a download macOS keeps apart (App Translocation), can't
/// update itself: Sparkle has nowhere to put the new version. So once it's open, it offers to move itself into
/// Applications and start again from there. Only release builds ask; a developer's build runs where it's built.
enum MoveToApplications {
    private static let destination = URL(fileURLWithPath: "/Applications/Zigzag.app")

    /// Once a browser window is up (after onboarding, on a first run from the disk image), the question is asked.
    static func offerWhenReady(tries: Int = 60) {
        #if !DEBUG
        guard needsMove(Bundle.main.bundleURL), tries > 0 else { return }
        if WelcomeWindowController.shared == nil, let controller = WindowManager.shared.keyController, controller.window?.isVisible == true {
            offerIfNeeded(in: controller)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { offerWhenReady(tries: tries - 1) }
        }
        #endif
    }

    static func offerIfNeeded(in controller: BrowserWindowController) {
        #if !DEBUG
        let here = Bundle.main.bundleURL
        guard needsMove(here) else { return }
        ConfirmSheet.show(in: controller.root.overlay, title: "Move Zigzag to Applications?",
                          message: "Zigzag is running from the disk image or a download, where it can’t update itself. In Applications, updates install on their own.",
                          confirmTitle: "Move to Applications") { confirmed in
            guard confirmed else { return }
            move(from: original(of: here), in: controller)
        }
        #endif
    }

    /// Running from somewhere it can't replace itself: a read-only disk (the disk image) or a translocated copy.
    static func needsMove(_ bundle: URL) -> Bool {
        guard !bundle.path.hasPrefix("/Applications/") else { return false }
        let readOnly = (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true
        return readOnly || bundle.path.contains("/AppTranslocation/")
    }

    /// Where a translocated copy really is (the Downloads folder, say), so that's what's moved.
    private static func original(of bundle: URL) -> URL {
        guard bundle.path.contains("/AppTranslocation/"),
              let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW),
              let symbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL") else { return bundle }
        typealias Original = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        let find = unsafeBitCast(symbol, to: Original.self)
        return find(bundle as CFURL, nil)?.takeRetainedValue() as URL? ?? bundle
    }

    private static func move(from source: URL, in controller: BrowserWindowController) {
        let manager = FileManager.default
        do {
            // An older Zigzag already there goes to the Trash, where it can still be taken back.
            if manager.fileExists(atPath: destination.path) { try manager.trashItem(at: destination, resultingItemURL: nil) }
            try manager.copyItem(at: source, to: destination)
        } catch {
            Toast.show(SaveFailure.message("Couldn’t move Zigzag to Applications", error), symbol: "exclamationmark.triangle",
                       duration: 6, in: controller)
            return
        }
        // Moved by Zigzag, not by Finder: without this, macOS would keep the new copy apart too. Its signature and
        // notarization were already checked when it first opened.
        let clear = Process()
        clear.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        clear.arguments = ["-dr", "com.apple.quarantine", destination.path]
        try? clear.run()
        clear.waitUntilExit()
        // A download, not a disk image: the old copy goes, so there's only one Zigzag.
        if !((try? source.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? true) {
            try? manager.trashItem(at: source, resultingItemURL: nil)
        }
        // The new copy can only start once this one has quit (one Zigzag per profile), so it waits for that.
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
                              destination.path, String(ProcessInfo.processInfo.processIdentifier)]
        try? relaunch.run()
        // Not a quit to ask about: Zigzag is starting again from its new place.
        AppDelegate.quitConfirmed = true
        NSApp.terminate(nil)
    }
}
