import Foundation
import WebKit

/// One answer a permission question offers. Deny first, the main affirmative last and prominent, alternatives plain
/// in between.
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
    /// Answers nothing, like Esc: the question is put off, never kept.
    static let cancel = PermissionAction(
        id: "cancel",
        title: String(localized: "Cancel", comment: "Button that closes a sheet without doing anything."),
        isDeny: true,
        isProminent: false
    )

    var isCancel: Bool { id == Self.cancel.id }

    static func alternate(_ id: String, _ title: String) -> PermissionAction {
        PermissionAction(id: id, title: title, isDeny: false, isProminent: false)
    }
}

/// The chosen action, and whether it's kept for the site or only the current page.
nonisolated struct PermissionAnswer {
    let action: String
    let remember: Bool
    /// The pick-only dropdown's entry (a rule's web address picks where to open; the buttons decide whether to go).
    /// Nil when there's no such dropdown, or when the dropdown itself answers (a pop-up's destination).
    let choice: String?
    /// Index of the chosen duration when more than two are offered. Zero is This time, so existing answers keep their
    /// meaning.
    let scopeIndex: Int

    init(action: String, remember: Bool, scopeIndex: Int = 0, choice: String? = nil) {
        self.action = action
        self.remember = remember
        self.scopeIndex = scopeIndex
        self.choice = choice
    }
}

/// Stable identifiers under which permission actions are remembered.
nonisolated enum PermissionSubject {
    static let location = "location", notifications = "notifications", popups = "popups", apps = "apps"
    /// Screen sharing; its yes picks which macOS picker shows.
    static let screen = "screen"
    /// Whether a site may download at all. Where files go is decided per type by download rules.
    static let downloads = "downloads"
    /// Whether a site's own scripts may reach a program listening on this Mac (`LocalReceivers`). A switch in Site
    /// Controls, never a question: a page cannot ask for it.
    static let localReceivers = "localReceivers"

    static func media(_ type: WKMediaCaptureType) -> String {
        switch type {
        case .camera: "camera"
        case .microphone: "microphone"
        default: "cameraAndMicrophone"
        }
    }

    static func app(_ scheme: String) -> String { "app:\(scheme)" }
    /// A handoff rule's kept answers, per site, under the rule's id.
    static func handoff(_ rule: UUID) -> String { "handoff:\(rule.uuidString)" }
}
