import AppKit
import SwiftUI

/// The single source of truth for every visual decision in Zigzag.
/// Views never use literal numbers or colors; they reach in here.
enum Tokens {

    // MARK: - Spacing (4pt grid)

    enum Space {
        static let grid: CGFloat = 4
        static let x1: CGFloat = 4
        static let x2: CGFloat = 8
        static let x3: CGFloat = 12
        static let x4: CGFloat = 16
        static let x5: CGFloat = 20
        static let x6: CGFloat = 24
        static let x8: CGFloat = 32
        static let x10: CGFloat = 40
        static let x12: CGFloat = 48
        static let x16: CGFloat = 64

        /// Rounds a value onto the 4pt grid.
        static func snap(_ value: CGFloat) -> CGFloat { (value / grid).rounded() * grid }
    }

    // MARK: - Corner radii

    enum Radius {
        /// The web page card. Concentric with the window corner at an 8pt inset.
        static let card: CGFloat = 8
        static let row: CGFloat = 8
        static let control: CGFloat = 6
        static let small: CGFloat = 4
        /// Floating surfaces: command bar, peek, previews, switcher.
        static let panel: CGFloat = 12
        static let thumbnail: CGFloat = 8
    }

    // MARK: - Layout metrics

    enum Metric {
        static let cardInset: CGFloat = Space.x2
        static let sidebarWidth: CGFloat = 240
        static let sidebarMinWidth: CGFloat = 192
        static let sidebarMaxWidth: CGFloat = 400
        static let sidebarPadding: CGFloat = Space.x2
        /// Height of the sidebar's top row (traffic lights + navigation).
        static let topRowHeight: CGFloat = Space.x10
        static let rowHeight: CGFloat = Space.x8
        static let addressHeight: CGFloat = Space.x8 + Space.x1
        static let iconButton: CGFloat = Space.x6 + Space.x1
        static let favicon: CGFloat = Space.x4
        static let sectionGap: CGFloat = Space.x3
        static let edgeRevealWidth: CGFloat = Space.x2
        static let resizeHandleWidth: CGFloat = Space.x2
        static let hairline: CGFloat = 1
        static let commandBarWidth: CGFloat = 640
        static let commandBarFieldHeight: CGFloat = Space.x12 + Space.x2
        static let commandBarRowHeight: CGFloat = Space.x10
        static let commandBarMaxRows: Int = 8
        static let previewWidth: CGFloat = 320
        static let switcherThumbWidth: CGFloat = 224
        static let peekInsetRatio: CGFloat = 0.08
        static let bottomBarHeight: CGFloat = Space.x10
        static let findBarWidth: CGFloat = 320
        static let popupDefaultSize = NSSize(width: 520, height: 640)
        static let windowDefaultSize = NSSize(width: 1280, height: 820)
        static let windowMinSize = NSSize(width: 560, height: 400)
        static let deskCardWidth: CGFloat = 256
    }

    // MARK: - Type (SF Pro, three sizes only)

    enum TypeSize {
        static let small: CGFloat = 11
        static let body: CGFloat = 13
        static let large: CGFloat = 18
    }

    enum Font {
        static func small(_ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: TypeSize.small, weight: weight) }
        static func body(_ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: TypeSize.body, weight: weight) }
        static func large(_ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: TypeSize.large, weight: weight) }
    }

    // MARK: - Symbols (one weight everywhere)

    enum Symbol {
        static let weight: NSFont.Weight = .medium
        static let pointSize: CGFloat = TypeSize.body

        static func image(_ name: String, size: CGFloat = pointSize) -> NSImage {
            let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            return image ?? NSImage()
        }
    }

    // MARK: - Motion (short, spring based)

    enum Motion {
        /// Hover and press feedback.
        static let quick: TimeInterval = 0.12
        /// Most UI transitions: sidebar slide, command bar, row moves.
        static let standard: TimeInterval = 0.28
        /// Large surface moves: desk view zoom.
        static let large: TimeInterval = 0.38
        /// Delay before a hover preview appears.
        static let previewDelay: TimeInterval = 0.45
        /// Delay before the hidden sidebar slides in from the edge.
        static let edgeRevealDelay: TimeInterval = 0.06
        static let edgeHideDelay: TimeInterval = 0.25

        static var snappy: Animation { .spring(duration: standard, bounce: 0) }
        static var gentle: Animation { .spring(duration: large, bounce: 0.04) }
        static var feedback: Animation { .spring(duration: quick, bounce: 0) }

        /// True while handling a keypress. Keyboard actions take effect instantly; only pointer actions animate
        /// (the Raycast rule: the keyboard is for speed).
        static var isKeyboardDriven: Bool {
            guard let type = NSApp.currentEvent?.type else { return false }
            return type == .keyDown || type == .keyUp || type == .flagsChanged
        }

        /// Runs AppKit animator() changes with a spring.
        static func animate(_ animation: Animation = snappy, _ changes: @escaping () -> Void, completion: (() -> Void)? = nil) {
            if isKeyboardDriven {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0
                    ctx.allowsImplicitAnimation = false
                    changes()
                }, completionHandler: completion)
                return
            }
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = quick
                    ctx.allowsImplicitAnimation = true
                    changes()
                }, completionHandler: completion)
                return
            }
            NSAnimationContext.animate(animation, changes: changes, completion: completion)
        }

        /// Applies changes immediately with no implicit animation.
        static func withoutAnimation(_ changes: () -> Void) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            changes()
            CATransaction.commit()
        }

        static func springAnimation(keyPath: String, duration: TimeInterval = standard) -> CASpringAnimation {
            let spring = CASpringAnimation(perceptualDuration: duration, bounce: 0)
            spring.keyPath = keyPath
            return spring
        }
    }

    // MARK: - Opacity

    enum Opacity {
        static let disabled: CGFloat = 0.35
        /// Floor for tabs that have not been looked at in a long time.
        static let fadedFloor: CGFloat = 0.42
    }

    // MARK: - Fading

    enum Fade {
        /// Tabs start fading after this long without being looked at.
        static let start: TimeInterval = 6 * 60 * 60
        /// ...and reach the faded floor at this age.
        static let full: TimeInterval = 4 * 24 * 60 * 60
    }

    // MARK: - Colors (light and dark designed together)

    enum Color {
        static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
            NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            }
        }

        static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
            NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                    green: CGFloat((value >> 8) & 0xFF) / 255,
                    blue: CGFloat(value & 0xFF) / 255,
                    alpha: alpha)
        }

        static let textPrimary = dynamic(light: hex(0x000000, alpha: 0.86), dark: hex(0xFFFFFF, alpha: 0.92))
        static let textSecondary = dynamic(light: hex(0x000000, alpha: 0.54), dark: hex(0xFFFFFF, alpha: 0.56))
        static let textTertiary = dynamic(light: hex(0x000000, alpha: 0.32), dark: hex(0xFFFFFF, alpha: 0.32))

        static let icon = dynamic(light: hex(0x000000, alpha: 0.62), dark: hex(0xFFFFFF, alpha: 0.66))

        /// Row and button overlays drawn on top of the window background.
        static let hoverFill = dynamic(light: hex(0x000000, alpha: 0.05), dark: hex(0xFFFFFF, alpha: 0.06))
        static let pressedFill = dynamic(light: hex(0x000000, alpha: 0.09), dark: hex(0xFFFFFF, alpha: 0.10))
        static let selectedFill = dynamic(light: hex(0xFFFFFF, alpha: 0.78), dark: hex(0xFFFFFF, alpha: 0.11))
        static let selectedHoverFill = dynamic(light: hex(0xFFFFFF, alpha: 0.92), dark: hex(0xFFFFFF, alpha: 0.14))
        static let selectedEdge = dynamic(light: hex(0x000000, alpha: 0.06), dark: hex(0xFFFFFF, alpha: 0.04))
        /// The keyboard-selected row in floating lists (command bar, downloads).
        static let highlight = dynamic(light: hex(0x000000, alpha: 0.07), dark: hex(0xFFFFFF, alpha: 0.09))
        static let fieldFill = dynamic(light: hex(0x000000, alpha: 0.045), dark: hex(0xFFFFFF, alpha: 0.06))

        static let separator = dynamic(light: hex(0x000000, alpha: 0.08), dark: hex(0xFFFFFF, alpha: 0.08))

        /// The page card when there is no page, and its edge.
        static let cardBackground = dynamic(light: hex(0xFFFFFF), dark: hex(0x1E1E20))
        static let cardEdge = dynamic(light: hex(0x000000, alpha: 0.07), dark: hex(0xFFFFFF, alpha: 0.07))
        /// Only shadow in the window: lifts the page off the frame.
        static let cardShadow = dynamic(light: hex(0x000000, alpha: 0.07), dark: hex(0x000000, alpha: 0.28))

        /// Floating surfaces (command bar, previews, switcher).
        static let panelBackground = dynamic(light: hex(0xFCFCFC), dark: hex(0x2A2A2D))
        static let panelEdge = dynamic(light: hex(0x000000, alpha: 0.10), dark: hex(0xFFFFFF, alpha: 0.10))
        static let panelShadow = dynamic(light: hex(0x000000, alpha: 0.18), dark: hex(0x000000, alpha: 0.5))
        static let scrim = dynamic(light: hex(0x000000, alpha: 0.10), dark: hex(0x000000, alpha: 0.30))

        static let accent = NSColor.controlAccentColor
        static let progress = dynamic(light: hex(0x000000, alpha: 0.28), dark: hex(0xFFFFFF, alpha: 0.32))
        static let destructive = NSColor.systemRed
    }

    // MARK: - Shadows (purposeful only)

    enum Shadow {
        /// Card: barely there, separates page from frame.
        static let cardRadius: CGFloat = 2
        static let cardOffset = CGSize(width: 0, height: -1)
        /// Floating panels sit above the page and need real depth.
        static let panelRadius: CGFloat = 24
        static let panelOffset = CGSize(width: 0, height: -8)
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}
