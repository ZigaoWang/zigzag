import Foundation
import WebKit

/// One answer a permission question offers. Denial comes first and the ordinary affirmative last and prominent;
/// every alternative is plain between them.
nonisolated struct PermissionAction {
    let id: String
    let title: String
    let isDeny: Bool
    let isProminent: Bool

    static let deny = PermissionAction(
        id: "deny",
        title: String(localized: "Don’t Allow", comment: "Button on a site's permission question."),
        isDeny: true,
        isProminent: false
    )
    static let allow = PermissionAction(
        id: "allow",
        title: String(localized: "Allow", comment: "Button on a site's permission question."),
        isDeny: false,
        isProminent: true
    )

    static func alternate(_ id: String, _ title: String) -> PermissionAction {
        PermissionAction(id: id, title: title, isDeny: false, isProminent: false)
    }
}

/// The action chosen for a permission question and whether it is kept for the site or only its current page.
nonisolated struct PermissionAnswer {
    let action: String
    let remember: Bool
}

/// Stable identifiers under which permission actions are remembered.
nonisolated enum PermissionSubject {
    static let location = "location", notifications = "notifications", popups = "popups", apps = "apps"
    /// Screen sharing, whose yes is *which* picker macOS shows rather than a plain allow.
    static let screen = "screen"
    /// Whether a site may save files at all. The destination an allowed file goes to is a separate decision, made per
    /// file type by the download rules.
    static let downloads = "downloads"

    static func media(_ type: WKMediaCaptureType) -> String {
        switch type {
        case .camera: "camera"
        case .microphone: "microphone"
        default: "cameraAndMicrophone"
        }
    }

    static func app(_ scheme: String) -> String { "app:\(scheme)" }
}
