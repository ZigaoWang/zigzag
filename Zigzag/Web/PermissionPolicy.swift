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

/// How long a question's answer holds: for the page that asked, for its site, or for the rule that asked. Every card
/// offers the same shape — "This time", "Always on this site", and, where an automation is what asked, "Always for"
/// it — and only what the answer lasts *on* changes.
nonisolated enum PermissionScope: String, Codable, CaseIterable, Sendable {
    /// The page that asked: its tab, until it loads another page or reloads.
    case once
    /// Every page of the site that asked.
    case site
    /// Every site, for the rule that asked. Only a question a download rule asks offers this.
    case rule
}

/// The action chosen for a permission question and how long it lasts.
nonisolated struct PermissionAnswer {
    let action: String
    let scope: PermissionScope
    /// The entry a question's own dropdown had chosen, where it offers one as a *chooser* rather than as the answer
    /// itself — "where should this open" picks a place, and the buttons then say how long it lasts. Nil for a question
    /// with no such dropdown, and for the answers that are the dropdown's own (a pop-up's destination).
    var choice: String? = nil

    init(action: String, scope: PermissionScope = .once, choice: String? = nil) {
        self.action = action
        self.scope = scope
        self.choice = choice
    }

    /// A question that has only this page and this site to keep its answer on, which is every question but a rule's
    /// own: "kept" there means the site.
    init(action: String, remember: Bool, choice: String? = nil) {
        self.init(action: action, scope: remember ? .site : .once, choice: choice)
    }

    /// Whether the answer is kept beyond the page — on the site, or on the rule. This is what a question *says*; where
    /// the answer is written reads `scope`, since only that tells the two apart.
    var remember: Bool { scope != .once }
}

/// Stable identifiers under which permission actions are remembered.
nonisolated enum PermissionSubject {
    static let location = "location", notifications = "notifications", popups = "popups", apps = "apps"
    /// Whether a site may save files at all. The destination an allowed file goes to is a separate decision, made per
    /// file type by the download rules.
    static let downloads = "downloads"
    /// Screen sharing, whose yes is *which* picker macOS shows rather than a plain allow.
    static let screen = "screen"

    static func media(_ type: WKMediaCaptureType) -> String {
        switch type {
        case .camera: "camera"
        case .microphone: "microphone"
        default: "cameraAndMicrophone"
        }
    }

    static func app(_ scheme: String) -> String { "app:\(scheme)" }
    static func handoff(_ rule: UUID) -> String { "handoff:\(rule.uuidString)" }
    /// Where this rule's web addresses open on one site, when the answer was kept for the site rather than the rule:
    /// a place's id, or "deny".
    static func openIn(_ rule: UUID) -> String { "openIn:\(rule.uuidString)" }
}
