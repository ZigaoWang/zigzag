import AppKit

// Before any web view exists: the guard on tab capture's shared sound needs to know every one (SharedSoundGate.swift).
WebViews.watchAll()
let delegate = AppDelegate()
ZigzagApplication.shared.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
