import AppKit
import WebKit

/// Camera and microphone decisions, remembered per site. Asked once, in a sheet, never as a surprise popup.
enum SitePermissions {
    private static let key = "SitePermissions"

    private static func storageKey(host: String, type: WKMediaCaptureType) -> String {
        let kind: String
        switch type {
        case .camera: kind = "camera"
        case .microphone: kind = "microphone"
        default: kind = "cameraAndMicrophone"
        }
        return "\(host)|\(kind)"
    }

    static func decision(host: String, type: WKMediaCaptureType) -> Bool? {
        let all = UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] ?? [:]
        return all[storageKey(host: host, type: type)]
    }

    static func remember(_ allowed: Bool, host: String, type: WKMediaCaptureType) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] ?? [:]
        all[storageKey(host: host, type: type)] = allowed
        UserDefaults.standard.set(all, forKey: key)
    }

    static func forget(host: String) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] ?? [:]
        for k in all.keys where k.hasPrefix(host + "|") { all[k] = nil }
        UserDefaults.standard.set(all, forKey: key)
    }

    static func request(origin: WKSecurityOrigin, type: WKMediaCaptureType, window: NSWindow?, isPrivate: Bool) async -> WKPermissionDecision {
        let host = origin.host
        if let known = decision(host: host, type: type) { return known ? .grant : .deny }
        let what: String
        switch type {
        case .camera: what = "your camera"
        case .microphone: what = "your microphone"
        default: what = "your camera and microphone"
        }
        let alert = NSAlert()
        alert.messageText = "Allow \(host) to use \(what)?"
        alert.informativeText = isPrivate ? "Only for this private window." : "Zigzag will remember your choice for this site."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don’t Allow")
        let response: NSApplication.ModalResponse
        if let window {
            response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            response = alert.runModal()
        }
        let allowed = response == .alertFirstButtonReturn
        if !isPrivate { remember(allowed, host: host, type: type) }
        return allowed ? .grant : .deny
    }
}
