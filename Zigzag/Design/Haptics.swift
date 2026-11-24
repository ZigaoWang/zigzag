import AppKit

/// The trackpad's small taps, used sparingly: only when something being dragged snaps onto a place it can land,
/// the way Finder and Keynote do. Nothing taps for ordinary movement.
enum Haptics {
    static func snap() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// A finger's hold lifted something to drag.
    static func lift() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }
}
