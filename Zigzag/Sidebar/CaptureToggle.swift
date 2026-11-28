import WebKit

/// The address bar's camera and microphone buttons (#545): a device the page is using shows one, and a click silences
/// it without ending the stream, which is the thing a call needs. A kept Block ends the device outright instead
/// (`LivePermissions`), so that isn't a toggle.
enum CaptureToggle {
    /// Whether the button shows for this device: in use, muted included.
    static func shows(_ state: WKMediaCaptureState) -> Bool {
        state != .none
    }

    static func isMuted(_ state: WKMediaCaptureState) -> Bool {
        state == .muted
    }
}
