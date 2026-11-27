import AppKit

#if DEBUG
// Tests only: a bare client of a helper, never the app (HelperProbe.swift).
HelperProbe.runIfAsked()
DevDefaults.isolate()
// -ZigzagPseudoLocalize YES: every string accented, bracketed and longer (docs/i18n/README.md).
PseudoLocale.startIfAsked()
// Debug builds only: a gesture recognizer stuck or missing an override crashes with a stack trace instead of being
// cancelled (TN3212). Off with ZIGZAG_GESTURE_CRASH=0, and while hosting tests. In memory, never saved.
if ProcessInfo.processInfo.environment["ZIGZAG_GESTURE_CRASH"] != "0", ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
    UserDefaults.standard.register(defaults: ["NSGestureRecognizerCrashOnMissingOverrides": true, "NSCrashOnStuckGestureTimeout": 2])
}
#endif
// Before any web view exists, so every page process starts with it.
WebKitSetup.shareUserScriptSources()
// Before any web view exists: the guard on tab capture's shared sound needs to know every one (SharedSoundGate.swift).
WebViews.watchAll()
let delegate = AppDelegate()
ZigzagApplication.shared.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
