import AppKit

/// A permission just granted says where it can be taken back (#545). The moment someone allows something is the moment
/// they are thinking about it, and a remembered answer being revocable rather than permanent is the thing most people
/// never learn. One line, over the page, using the existing toast.
enum PermissionToast {
    /// The name the button and the toast use, from the stored subject.
    static func name(_ subject: String) -> String? {
        switch subject {
        case PermissionSubject.location:
            String(localized: "Location", comment: "Name of the location permission, in the toast after it is allowed.")
        case PermissionSubject.notifications:
            String(localized: "Notifications", comment: "Name of the notifications permission, in the toast after it is allowed.")
        case "camera":
            String(localized: "Camera", comment: "Name of the camera permission, in the toast after it is allowed.")
        case "microphone":
            String(localized: "Microphone", comment: "Name of the microphone permission, in the toast after it is allowed.")
        case "cameraAndMicrophone":
            String(localized: "Camera and Microphone", comment: "Name of the camera-and-microphone permission, in the toast after it is allowed.")
        case PermissionSubject.screen:
            String(localized: "Screen Sharing", comment: "Name of the screen-sharing permission, in the toast after it is allowed.")
        case PermissionSubject.downloads:
            String(localized: "Downloads", comment: "Name of the downloads permission, in the toast after it is allowed.")
        default:
            nil
        }
    }

    /// What a grant says. Remembered: it can be changed. For this page only: the page asks again next time. Both name
    /// Site Controls, which is where a change is made — and a change reaches the page that is open now.
    static func line(name: String, remembered: Bool) -> String {
        remembered
            ? String(localized: "\(name) allowed. You can change this in Site Controls.",
                     comment: "Toast after a permission is allowed for a site and remembered. The first placeholder is the permission's name, like Camera.")
            : String(localized: "\(name) allowed for this page. You can change this in Site Controls.",
                     comment: "Toast after a permission is allowed for this page only. The first placeholder is the permission's name, like Camera.")
    }

    /// Shows it, if the grant has a window to show it over and a name worth saying.
    static func show(_ subject: String, remembered: Bool, origin: String, tab: Tab?) {
        guard let name = name(subject), !(tab?.isPrivate ?? false) else { return }
        guard let controller = tab.flatMap(WindowManager.shared.window(of:))
            ?? WindowManager.shared.keyController ?? WindowManager.shared.controllers.first else { return }
        if let tab, !controller.promptShows(tab) { return }
        Toast.show(line(name: name, remembered: remembered), symbol: symbol(subject), duration: 3,
                   owner: controller.root.overlay, in: controller)
    }

    private static func symbol(_ subject: String) -> String {
        switch subject {
        case PermissionSubject.location: "location.fill"
        case PermissionSubject.notifications: "bell.fill"
        case "microphone", "cameraAndMicrophone": "mic.fill"
        case PermissionSubject.screen: "rectangle.on.rectangle"
        case PermissionSubject.downloads: "arrow.down.circle"
        default: "video.fill"
        }
    }
}
