import AppKit

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
        /// The height of a compact button in forms and panels.
        static let x7Height: CGFloat = 28

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
        static let deskCardWidth: CGFloat = 208
        static let deskCardMaxWidth: CGFloat = 440
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
        static let quick: TimeInterval = 0.1
        /// Most UI transitions: sidebar slide, command bar, row moves.
        static let standard: TimeInterval = 0.2
        /// Large surface moves: desk view zoom.
        static let large: TimeInterval = 0.3
        /// Delay before a hover preview appears.
        static let previewDelay: TimeInterval = 0.6
        /// How long the pointer can stray off the floating sidebar before it slides away.
        static let edgeHideDelay: TimeInterval = 0.05
        /// Sidebar slides in and out: fast enough to feel attached to the pointer.
        static let slideDuration: TimeInterval = 0.18

        /// A motion style: how long, and which curve. Every curve is a fast-out, no-overshoot spring shape,
        /// run by Core Animation on the render server so it stays smooth while pages are busy.
        struct Curve {
            let duration: TimeInterval
            /// When set, slides use a real spring with this much bounce instead of an eased curve.
            var bounce: CGFloat? = nil
            var timing: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1) }
        }

        static let snappy = Curve(duration: standard)
        static let slide = Curve(duration: slideDuration)
        /// Finishing a swipe: the fingers already did most of the travel, so the rest is quick.
        static let snap = Curve(duration: 0.14)
        /// Switching spaces: quick, with a small spring settle so it feels alive.
        static let spaceSwitch = Curve(duration: 0.26, bounce: 0.12)
        /// Letting go of a swipe between spaces: a critically damped spring that carries on at the fingers' speed
        /// and never overshoots, whether it lands on the next space or springs back.
        static let swipeSettle = Curve(duration: 0.15, bounce: 0)
        static let gentle = Curve(duration: large)
        static let feedback = Curve(duration: quick)

        /// True while handling ⌘T: a new tab is for typing at once, so it appears instantly. Every other shortcut
        /// (⌘W, switching tabs and spaces) animates like the same action done with the pointer, so you see what changed.
        static var isKeyboardDriven: Bool {
            guard let event = NSApp.currentEvent, event.type == .keyDown else { return false }
            // The T key wherever it is, in any keyboard layout, with Caps Lock on or off.
            return event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command && event.keyCode == 17
        }

        /// Runs AppKit animator() changes. Frames jump to their final values right away (so layout and
        /// hit-testing always see the truth); only what's drawn animates.
        /// `evenFromKeyboard`: for changes to the window's layout (the sidebar, a split), where seeing where things
        /// went matters more than a few milliseconds.
        static func animate(_ curve: Curve = snappy, evenFromKeyboard: Bool = false, _ changes: @escaping () -> Void, completion: (() -> Void)? = nil) {
            if isKeyboardDriven && !evenFromKeyboard {
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
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = curve.duration * debugSlowdown
                ctx.timingFunction = curve.timing
                ctx.allowsImplicitAnimation = true
                changes()
            }, completionHandler: completion)
        }

        static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

        /// Debug builds: ZIGZAG_SLOW_ANIMATIONS=10 plays animations ten times slower, to look at them.
        static let debugSlowdown: Double = {
            #if DEBUG
            return Double(ProcessInfo.processInfo.environment["ZIGZAG_SLOW_ANIMATIONS"] ?? "") ?? 1
            #else
            return 1
            #endif
        }()

        /// Slides a view horizontally into its current (final) position from `offset` points away, on the
        /// render server. Returns how long the slide takes, 0 if it was skipped.
        /// Vertical companion to `slide`, always animated (used for feedback like toasts).
        static func slideVertically(_ view: NSView, fromOffsetY offset: CGFloat, curve: Curve = snappy) {
            guard let layer = view.layer, !reduceMotion else { return }
            let animation = CABasicAnimation(keyPath: "transform.translation.y")
            animation.fromValue = view.isFlipped ? offset : -offset
            animation.toValue = 0
            animation.duration = curve.duration
            animation.timingFunction = curve.timing
            animation.fillMode = .backwards
            layer.add(animation, forKey: "slideY")
        }

        /// `velocity`: how fast the view is already moving, in points per second (positive is rightward), so a slide
        /// that takes over from the fingers doesn't stall or lurch. Springs only.
        @discardableResult
        static func slide(_ view: NSView, fromOffsetX offset: CGFloat, curve: Curve = snappy, fromKeyboard: Bool = false,
                          velocity: CGFloat = 0) -> TimeInterval {
            guard let layer = view.layer, fromKeyboard || !isKeyboardDriven, !reduceMotion else { return 0 }
            // Interrupting a slide carries on from where it is on screen, not from where it was headed.
            var offset = offset
            if layer.animation(forKey: "slide") != nil,
               let shown = layer.presentation()?.value(forKeyPath: "transform.translation.x") as? CGFloat {
                offset += shown
            }
            guard abs(offset) > 0.5 else { layer.removeAnimation(forKey: "slide"); return 0 }
            let animation: CABasicAnimation
            if let bounce = curve.bounce {
                let spring = CASpringAnimation(perceptualDuration: curve.duration, bounce: bounce)
                if velocity != 0 {
                    // The spring counts speed in whole distances per second, toward where it's going. Without bounce,
                    // starting faster than its natural frequency would carry it past the end, so it's capped there.
                    let natural = sqrt(spring.stiffness / spring.mass)
                    spring.initialVelocity = min(-velocity / offset, bounce == 0 ? natural : .greatestFiniteMagnitude)
                }
                spring.duration = spring.settlingDuration
                animation = spring
            } else {
                animation = CABasicAnimation()
                animation.duration = curve.duration
                animation.timingFunction = curve.timing
            }
            animation.keyPath = "transform.translation.x"
            animation.fromValue = offset
            animation.toValue = 0
            animation.fillMode = .backwards
            layer.add(animation, forKey: "slide")
            return animation.duration
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
        static let panelShadow = dynamic(light: hex(0x000000, alpha: 0.13), dark: hex(0x000000, alpha: 0.42))
        static let scrim = dynamic(light: hex(0x000000, alpha: 0.10), dark: hex(0x000000, alpha: 0.30))

        /// Zigzag's one accent: the space's own, so progress, focus, selection and actions agree everywhere.
        /// Native controls (switches, pop-ups) keep the system's.
        @MainActor static var accent: NSColor { Brand.Theme.current.accent }
        /// Counts on extension buttons: quiet, never competing with the page.
        static let badge = dynamic(light: hex(0x6E6E73), dark: hex(0x8E8E93))

        /// Settings: the window behind grouped rows, and the groups themselves (System Settings proportions).
        static let formBackground = dynamic(light: hex(0xF2F2F4), dark: hex(0x1E1E20))
        static let formGroup = dynamic(light: hex(0xFFFFFF), dark: hex(0x2A2A2D))
        static let formGroupEdge = dynamic(light: hex(0x000000, alpha: 0.06), dark: hex(0xFFFFFF, alpha: 0.06))
        static let progress = dynamic(light: hex(0x000000, alpha: 0.28), dark: hex(0xFFFFFF, alpha: 0.32))
        static let destructive = NSColor.systemRed
        /// Status: something to fix (a weak password, an import problem).
        static let warning = NSColor.systemOrange
        /// Status: worth knowing (a reused password). A deep amber on light backgrounds, where yellow can't be read.
        static let caution = dynamic(light: hex(0x9A5B00), dark: hex(0xF2C14E))
        /// Status: done and fine.
        static let success = NSColor.systemGreen
    }

    // MARK: - Shadows (purposeful only)

    enum Shadow {
        /// Card: barely there, separates page from frame.
        static let cardRadius: CGFloat = 2
        static let cardOffset = CGSize(width: 0, height: -1)
        /// Floating panels sit just above the page: a soft, short shadow that falls below them, never above.
        static let panelRadius: CGFloat = 16
        static let panelDrop: CGFloat = 3

        /// The drop as a layer offset: flipped views measure y downward, so the sign follows the view.
        static func panelOffset(flipped: Bool) -> CGSize { CGSize(width: 0, height: flipped ? panelDrop : -panelDrop) }
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}
