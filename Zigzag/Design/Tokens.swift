import AppKit

/// The single source of truth for every visual decision in Zigzag. The system these values make, its layers,
/// materials, type, spacing, radii, states and motion, is written down in Design/DESIGN.md: build to it.
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

    /// One scale, a step apart: small 4, control 6, field 8, row 10, tile 12, panel 14, large 16.
    enum Radius {
        /// The web page card. Concentric with the window corner at an 8pt inset.
        static let card: CGFloat = 8
        /// The window's own corner. A page that meets the window's edges takes it, so the two curves match.
        static let window: CGFloat = 16
        /// A row in the sidebar or a floating list: soft enough that the selected one reads as a card.
        static let row: CGFloat = 10
        /// A favorite's tile.
        static let tile: CGFloat = 12
        static let control: CGFloat = 6
        /// Fields, pills, menu buttons and filter segments: a step rounder than a plain control.
        static let field: CGFloat = 8
        static let small: CGFloat = 4
        /// Grouped cards on a window's background: Settings and Passwords groups, the site panel's sections.
        static let group: CGFloat = 10
        /// Floating surfaces: command bar, peek, previews, menus.
        static let panel: CGFloat = 14
        /// Large floating surfaces that hold rounded things of their own: the tab switcher, Reader's options, the tour.
        static let large: CGFloat = 16
        static let thumbnail: CGFloat = 8
    }

    // MARK: - Layout metrics

    enum Metric {
        static let cardInset: CGFloat = Space.x2
        static let sidebarWidth: CGFloat = 240
        /// The narrowest the sidebar gets: room for the traffic lights and the toolbar's four icon buttons.
        static let sidebarMinWidth: CGFloat = 216
        static let sidebarMaxWidth: CGFloat = 400
        static let sidebarPadding: CGFloat = Space.x2
        /// Height of the sidebar's top row (traffic lights + navigation).
        static let topRowHeight: CGFloat = Space.x10
        /// A sidebar row: relaxed, with room around 14pt text. With `rowGap` the rows sit 36pt apart.
        static let rowHeight: CGFloat = Space.x8 + 2
        static let rowGap: CGFloat = 2
        /// A section's quiet label (the space's name, Tabs): the label sits low, with generous room above it.
        static let sectionLabelHeight: CGFloat = Space.x8
        static let addressHeight: CGFloat = Space.x8 + Space.x1
        /// Hit targets: one size for every icon button you reach for (the toolbar, the bottom bar, a pane's header,
        /// the find bar, a panel's close), and a compact one for buttons inside a row or a field (a tab's close, the
        /// address's Reader). The hover fill shows the whole target.
        static let iconButton: CGFloat = Space.x8
        static let compactIconButton: CGFloat = Space.x6
        /// One control height on pages and in panels: pill buttons, dropdowns, the search field, a menu's rows.
        static let controlHeight: CGFloat = Space.x7Height
        /// A row's picture: a favicon, or a symbol (`Symbol.row`) in its place. The same in the sidebar, on pages,
        /// in panels and in the command bar, so rows line up wherever they are.
        static let favicon: CGFloat = 18
        static let sectionGap: CGFloat = Space.x4
        static let edgeRevealWidth: CGFloat = Space.x2
        static let resizeHandleWidth: CGFloat = Space.x2
        static let hairline: CGFloat = 1
        /// Keyboard focus: the ring's width, and its gap outside the control.
        static let focusRing: CGFloat = 2
        static let focusGap: CGFloat = 2
        /// A drop target's accent edge (`Color.dropAlpha`), and how far a split's half sits inside the row or tile
        /// it would open beside.
        static let dropEdge: CGFloat = 1.5
        static let dropInset: CGFloat = 3
        /// Zigzag's switch (`Toggle`): track and knob.
        static let toggleSize = NSSize(width: 36, height: 22)
        static let toggleKnob: CGFloat = 18
        static let commandBarWidth: CGFloat = 640
        static let commandBarFieldHeight: CGFloat = Space.x12 + Space.x2
        static let commandBarRowHeight: CGFloat = Space.x10
        static let commandBarMaxRows: Int = 8
        static let previewWidth: CGFloat = 320
        static let switcherThumbWidth: CGFloat = 224
        static let peekInsetRatio: CGFloat = 0.08
        static let bottomBarHeight: CGFloat = Space.x10
        /// A space's dot in the bottom bar, and the longer one for the space you're in.
        static let spaceDot: CGFloat = 8
        static let currentSpaceDot: CGFloat = Space.x5
        static let findBarWidth: CGFloat = 320
        static let popupDefaultSize = NSSize(width: 520, height: 640)
        static let windowDefaultSize = NSSize(width: 1280, height: 820)
        static let windowMinSize = NSSize(width: 560, height: 400)
        static let deskCardWidth: CGFloat = 208
        static let deskCardMaxWidth: CGFloat = 440
        /// The find bar, a glass capsule over the page's top right.
        static let findBarHeight: CGFloat = Space.x10
        /// A toast, a glass capsule at the page's top; its action is a pill this tall, inset evenly.
        static let toastHeight: CGFloat = Space.x8 + Space.x1
        static let toastButtonHeight: CGFloat = Space.x7Height
        /// Where a hovered link goes: the small glass capsule in the page's bottom-left corner.
        static let linkStatusHeight: CGFloat = Space.x6
        /// A site's chip in front of the command bar's field while you search inside it; `chipHeightSmall` in the
        /// sidebar's address.
        static let chipHeight: CGFloat = Space.x6 + 2
        static let chipHeightSmall: CGFloat = Space.x5
        /// A keycap (`KeyCap`): Return on a chosen result, Tab beside "Search YouTube".
        static let keyCapHeight: CGFloat = Space.x5 - 2
        /// A small round button floating over a page edge on its own (swipe arrows, the stand-in Downloads button).
        static let floatingButton: CGFloat = Space.x8 + Space.x1
        /// The split pane's header strip: an icon button with 4pt around it.
        static let paneHeaderHeight: CGFloat = Space.x10
        /// A tab preview's caption under the picture, and Peek's top strip.
        static let previewCaptionHeight: CGFloat = Space.x12
        static let peekHeaderHeight: CGFloat = Space.x10
    }

    // MARK: - Pages

    /// Zigzag's built-in pages (History, Settings) and, from here on, its other surfaces: one plain surface, the
    /// small wordmark and a semibold title at the top left, the search field and actions at the top right, quiet
    /// rows under it. History's CSS is generated from these values (`PageStyle`), so the two never drift.
    enum Page {
        /// The page's edge to its content, and to the header's wordmark.
        static let gutter: CGFloat = Space.x6 + Space.x1
        /// The same, when the page is narrow (half of a split, a small window).
        static let narrowGutter: CGFloat = Space.x4
        /// Narrower than this, a page uses `narrowGutter`.
        static let narrowWidth: CGFloat = 640
        /// The header: its top and bottom padding, and the height of what's in it (title, search, buttons).
        static let headerTop: CGFloat = Space.x4
        static let headerBottom: CGFloat = Space.x3
        static let controlHeight: CGFloat = Metric.controlHeight
        static var headerHeight: CGFloat { headerTop + controlHeight + headerBottom }
        /// The widest the content gets; past it the page centers it.
        static let maxWidth: CGFloat = 880
        /// A row in a list: History's pages, Settings' sections. The sidebar's row, so the two read alike.
        static let rowHeight: CGFloat = Metric.rowHeight
        /// How far a row's hover fill reaches past its text, on each side.
        static let rowInset: CGFloat = Space.x2 + 2
        /// The wordmark in the header: about the title's cap height, so the two read as one line.
        static let wordmarkHeight: CGFloat = 16
        /// The search field in the header.
        static let searchWidth: CGFloat = 280
        /// A column of sections at the left (Settings).
        static let columnWidth: CGFloat = 240
        /// A row in a group on a page (Settings): one line of text, or more with its explanation under it.
        static let groupRowHeight: CGFloat = Space.x10 + Space.x1
        /// From a group's edge to the text and controls in its rows, and above and below a row's two lines.
        static let groupPad: CGFloat = Space.x4
        static let groupRowPad: CGFloat = Space.x3
        /// Between one group on a page and the next section.
        static let groupGap: CGFloat = Space.x6
        /// A page in a window of its own (Passwords): the strip its traffic lights sit in, above the header.
        static let windowTop: CGFloat = Space.x6 + Space.x1
        /// The middle column of a three-part page: the list of things in the chosen section (Passwords' logins).
        static let listWidth: CGFloat = 300
        /// A row of the middle list: a title over a quiet second line.
        static let tallRowHeight: CGFloat = Space.x10 + Space.x1
        /// The text column of a detail pane, so a wide window doesn't stretch its lines.
        static let detailWidth: CGFloat = 520
    }

    // MARK: - Dialogs

    /// Every question Zigzag asks over a window or a page (a confirmation, saving a password, a permission, adding
    /// an extension): one floating panel, the same padding, the same header and the same row of pill buttons.
    enum Dialog {
        static let width: CGFloat = 360
        /// From the panel's edge to everything in it.
        static let padding: CGFloat = Space.x5
        /// The picture at the start of the header: a site's icon, an extension's, or a symbol on a soft circle.
        static let iconSide: CGFloat = Space.x8
        /// Between the header and what's under it, and before the buttons.
        static let gap: CGFloat = Space.x4
        /// The space between two buttons in the row.
        static let buttonGap: CGFloat = Space.x2
        /// The narrowest a button in the row gets, so a short "OK" still reads as a button.
        static let minButtonWidth: CGFloat = Space.x16 + Space.x4
    }

    // MARK: - Brand moments

    /// First run, the welcome and the import window: the brand's blue frame and what floats on it.
    enum Welcome {
        /// The wordmark on the hello screen.
        static let wordmarkHeight: CGFloat = 72
        /// The wordmark heading a window of the app's own (About, Import).
        static let smallWordmarkHeight: CGFloat = 22
        /// The glass card a step's choice sits on.
        static let cardWidth: CGFloat = 560
        /// Its padding.
        static let cardPadding: CGFloat = Space.x5
        /// A step's big title, in display weight: the one place type is this large.
        static let titleSize: CGFloat = 30
        /// The progress dots: the dot, and the long one for the step you're on.
        static let dot: CGFloat = 6
        static let currentDot: CGFloat = Space.x5 + 2
        /// The main pill on a step and the welcome's one button.
        static let buttonHeight: CGFloat = Space.x10
        static let buttonWidth: CGFloat = 168
        /// A question's two answers.
        static let answerWidth: CGFloat = 200
        static let answerHeight: CGFloat = Space.x10 + Space.x1
        static let groupGap: CGFloat = Space.x6 + Space.x1
    }

    // MARK: - Type (SF Pro: six roles, one scale for the whole app)

    /// Every text in Zigzag is one of these. Pages, panels and the sidebar share them: the same role is the same size
    /// everywhere. DESIGN.md has the table.
    enum TypeSize {
        /// Small print, captions, counts, a keycap.
        static let small: CGFloat = 11
        /// A section's label and a group's heading (medium, gray); a row's explanation (regular).
        static let label: CGFloat = 12
        /// Panels, forms, menus, what a button or dropdown says.
        static let body: CGFloat = 13
        /// A row's title in any list: the sidebar's rows and address, Settings' sections and rows, History's pages.
        static let row: CGFloat = 14
        /// A panel's title, a section's title on a page.
        static let heading: CGFloat = 15
        /// A page's title in its header, a big panel's title, the command bar's field.
        static let title: CGFloat = 17
        /// Display headings in heavy type (`Brand.display`): a window's or a card's one big line.
        static let display: CGFloat = 22
        /// The count on an extension's button: the one place text has to fit a 10pt capsule.
        static let badge: CGFloat = 8
    }

    enum Font {
        static func small(_ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: TypeSize.small, weight: weight) }
        static func body(_ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: TypeSize.body, weight: weight) }
        static func row(_ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: TypeSize.row, weight: weight) }
        static func heading(_ weight: NSFont.Weight = .semibold) -> NSFont { .systemFont(ofSize: TypeSize.heading, weight: weight) }
        static func title(_ weight: NSFont.Weight = .semibold) -> NSFont { .systemFont(ofSize: TypeSize.title, weight: weight) }
        /// A quiet section label: "Tabs", the space's name over its pinned tabs, a group's heading on a page.
        static func label() -> NSFont { .systemFont(ofSize: TypeSize.label, weight: .medium) }
        /// A row's explanation under its title, in `textSecondary`.
        static func detail() -> NSFont { .systemFont(ofSize: TypeSize.label) }
        /// What a button or a dropdown says.
        static func control() -> NSFont { .systemFont(ofSize: TypeSize.body, weight: .medium) }
    }

    // MARK: - Symbols (one weight everywhere)

    enum Symbol {
        /// Regular, not medium: icons sit as lightly as the text beside them.
        static let weight: NSFont.Weight = .regular
        /// Four sizes, by where the symbol sits. In an icon button (`Metric.iconButton`): back, forward, reload,
        /// the bottom bar, a pane's header, the find bar, a panel's close. Big enough to be a pleasure to press.
        static let glyph: CGFloat = 17
        /// In a compact icon button (`Metric.compactIconButton`), inside a row or a field.
        static let compactGlyph: CGFloat = 14
        /// A row's picture where it's a symbol rather than a favicon: it fills the favicon's slot (`Metric.favicon`).
        static let row: CGFloat = 16
        /// A tiny mark inline with text: a lock, a disclosure chevron, a dropdown's arrows.
        static let inline: CGFloat = 11
        /// Beside body text (a pill button's symbol, a panel's line): the text's own size.
        static let pointSize: CGFloat = TypeSize.body

        static func image(_ name: String, size: CGFloat = pointSize) -> NSImage {
            let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            return image ?? NSImage()
        }

        /// How far a symbol's ink sits from the middle of its image, in points (x right, y up). A symbol's image
        /// keeps room for its neighbors in text, so a chevron leans toward the side it points to; a button
        /// moves it back so every icon in a row looks evenly spaced.
        @MainActor static func inkOffset(_ name: String, size: CGFloat = pointSize) -> CGSize {
            let key = "\(name) \(size)"
            if let known = inkOffsets[key] { return known }
            let image = Self.image(name, size: size)
            let scale: CGFloat = 4
            let w = Int(image.size.width * scale), h = Int(image.size.height * scale)
            var offset = CGSize.zero
            if w > 0, h > 0, let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                image.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
                NSGraphicsContext.restoreGraphicsState()
                var minX = w, maxX = -1, minY = h, maxY = -1
                if let data = rep.bitmapData {
                    for y in 0..<h {
                        for x in 0..<w where data[y * rep.bytesPerRow + x * 4 + 3] > 50 {
                            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                        }
                    }
                }
                if maxX >= minX {
                    // Bitmap rows run top down.
                    offset = CGSize(width: (CGFloat(minX + maxX + 1) / 2 - CGFloat(w) / 2) / scale,
                                    height: (CGFloat(h) / 2 - CGFloat(minY + maxY + 1) / 2) / scale)
                }
            }
            // Reload's arrowhead pokes out above its circle, so centering the ink leaves the circle low; it's the
            // circle that should line up with the chevrons beside it.
            if name == "arrow.clockwise" { offset.height -= size * 0.1 }
            inkOffsets[key] = offset
            return offset
        }
        @MainActor private static var inkOffsets: [String: CGSize] = [:]
    }

    // MARK: - Motion (short, spring based)

    enum Motion {
        /// Hover and press feedback.
        static let quick: TimeInterval = 0.1
        /// A change of selection in a list: the card settling onto the chosen row.
        static let selection: TimeInterval = 0.15
        /// Most UI transitions: sidebar slide, command bar, row moves.
        static let standard: TimeInterval = 0.2
        /// Large surface moves: the desk fading in and out.
        static let large: TimeInterval = 0.3
        /// The page shrinking into its card in desk view, and a card growing back into the page.
        static let zoom: TimeInterval = 0.28
        /// Delay before a hover preview appears.
        static let previewDelay: TimeInterval = 0.6
        /// How long the pointer can stray off the floating sidebar before it slides away.
        static let edgeHideDelay: TimeInterval = 0.05
        /// Sidebar slides in and out: fast enough to feel attached to the pointer.
        static let slideDuration: TimeInterval = 0.18

        /// The tactile press: a button or row eases down to this scale as it's pressed (`pressIn`, eased out) and
        /// springs back when let go (`pressOut`, critically damped, so it never overshoots). The action never waits on it.
        static let pressScale: CGFloat = 0.97
        static let pressIn: TimeInterval = 0.08
        static let pressOut: TimeInterval = 0.2
        /// A menu growing out of the control that opened it: from this scale with a fade, in `menuIn`, eased out;
        /// leaving is quicker and subtler (`menuOut`, toward `menuOutScale`).
        static let menuFrom: CGFloat = 0.96
        static let menuIn: TimeInterval = 0.18
        static let menuOut: TimeInterval = 0.12
        static let menuOutScale: CGFloat = 0.98
        /// One shared highlight gliding from row to row in a menu, and a selection gliding between a list's places
        /// or a filter's segments.
        static let highlightGlide: TimeInterval = 0.14

        /// A layer's transform scaling it by `k` around `point` (0 to 1 across its bounds, from its top left), whatever
        /// its anchor: what a press or a growing menu uses.
        static func scale(_ k: CGFloat, of layer: CALayer, around point: CGPoint = CGPoint(x: 0.5, y: 0.5), flipped: Bool = true) -> CATransform3D {
            let size = layer.bounds.size
            let px = (point.x - layer.anchorPoint.x) * size.width
            let py = ((flipped ? point.y : 1 - point.y) - layer.anchorPoint.y) * size.height
            return CATransform3DConcat(CATransform3DMakeScale(k, k, 1), CATransform3DMakeTranslation(px * (1 - k), py * (1 - k), 0))
        }

        /// A motion style: how long, and which curve. Every curve is a fast-out, no-overshoot spring shape,
        /// run by Core Animation on the render server so it stays smooth while pages are busy.
        struct Curve {
            let duration: TimeInterval
            /// When set, slides use a real spring with this much bounce instead of an eased curve.
            var bounce: CGFloat? = nil
            var timing: CAMediaTimingFunction { Motion.easeOut }
        }

        /// The one ease-out for anything arriving, leaving or settling: fast at first, so it answers at once, then a
        /// long soft finish (cubic-bezier(0.23, 1, 0.32, 1)). Never ease-in: it starts slow, right when you're looking.
        static let easeOut = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)

        /// Something moving from one place on screen to another: cubic-bezier(0.77, 0, 0.175, 1).
        static let easeInOut = CAMediaTimingFunction(controlPoints: 0.77, 0, 0.175, 1)

        static let snappy = Curve(duration: standard)
        static let slide = Curve(duration: slideDuration)
        /// Finishing a swipe: the fingers already did most of the travel, so the rest is quick.
        static let snap = Curve(duration: 0.14)
        /// Switching spaces: a quick slide that shows which way you went, eased out, with no bounce.
        static let spaceSwitch = Curve(duration: 0.22)
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

        /// True while handling any key press. Panels (find, downloads, a confirmation) opened or closed by a key appear
        /// and go at once; changes to the window's layout still move, so you see where things went.
        static var isFromKey: Bool { NSApp.currentEvent?.type == .keyDown }

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
            if reduceMotion {
                // Reduce Motion: things move to where they go at once; nothing slides.
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0
                    ctx.allowsImplicitAnimation = false
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

        static var reduceMotion: Bool {
            #if DEBUG
            if debugReduceMotion { return true }
            #endif
            return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
        #if DEBUG
        /// Debug builds: Reduce Motion for this app alone, for testing, without changing the Mac's setting.
        static var debugReduceMotion = false
        #endif

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

        /// Moves a view to `frame` at once, so layout and clicks see the truth, and lets the render server show it
        /// traveling there from wherever it's drawn right now. Smooth however busy the app is, and a move that
        /// changes course mid-way carries on from where it is on screen, never jumping back. For rows and tiles
        /// that make room for something being dragged.
        static func glide(_ view: NSView, to frame: NSRect, duration: TimeInterval = standard,
                          timing: CAMediaTimingFunction = easeInOut) {
            guard let layer = view.layer else { view.frame = frame; return }
            var shown = view.frame.origin
            if layer.animation(forKey: "glide") != nil, let drawn = layer.presentation()?.transform {
                shown.x += drawn.m41
                shown.y += drawn.m42
            }
            withoutAnimation { view.frame = frame }
            layer.removeAnimation(forKey: "glide")
            // A layer's y runs the way its view's superview does, so the offset carries over as it is.
            let dx = shown.x - frame.minX, dy = shown.y - frame.minY
            guard !reduceMotion, abs(dx) > 0.5 || abs(dy) > 0.5 else { return }
            let animation = CABasicAnimation(keyPath: "transform")
            animation.fromValue = CATransform3DMakeTranslation(dx, dy, 0)
            animation.toValue = CATransform3DIdentity
            animation.duration = duration * debugSlowdown
            animation.timingFunction = timing
            animation.fillMode = .backwards
            layer.add(animation, forKey: "glide")
        }

        /// Applies changes immediately with no implicit animation.
        static func withoutAnimation(_ changes: () -> Void) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            changes()
            CATransaction.commit()
        }

        /// A critically damped spring: it never overshoots, and runs until it has settled.
        static func springAnimation(keyPath: String, duration: TimeInterval = standard) -> CASpringAnimation {
            let spring = CASpringAnimation(perceptualDuration: duration * debugSlowdown, bounce: 0)
            spring.keyPath = keyPath
            spring.duration = spring.settlingDuration
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
        static let textTertiary = dynamic(light: hex(0x000000, alpha: 0.45), dark: hex(0xFFFFFF, alpha: 0.42))

        static let icon = dynamic(light: hex(0x000000, alpha: 0.62), dark: hex(0xFFFFFF, alpha: 0.66))

        /// Row and button overlays drawn on top of the window background.
        static let hoverFill = dynamic(light: hex(0x000000, alpha: 0.05), dark: hex(0xFFFFFF, alpha: 0.06))
        static let pressedFill = dynamic(light: hex(0x000000, alpha: 0.09), dark: hex(0xFFFFFF, alpha: 0.10))
        /// The selected row: a soft card floating on the sidebar, white or a lighter surface in dark mode, with a
        /// hairline edge (`selectedEdge`) and a faint shadow (`liftShadow`).
        static let selectedFill = dynamic(light: hex(0xFFFFFF, alpha: 0.9), dark: hex(0xFFFFFF, alpha: 0.13))
        static let selectedHoverFill = dynamic(light: hex(0xFFFFFF, alpha: 0.97), dark: hex(0xFFFFFF, alpha: 0.16))
        static let selectedEdge = dynamic(light: hex(0x000000, alpha: 0.06), dark: hex(0xFFFFFF, alpha: 0.07))
        static let liftShadow = dynamic(light: hex(0x000000, alpha: 0.07), dark: hex(0x000000, alpha: 0.3))
        /// A favorite's tile: soft glass, a see-through fill with a faint light edge.
        static let glassFill = dynamic(light: hex(0xFFFFFF, alpha: 0.32), dark: hex(0xFFFFFF, alpha: 0.06))
        static let glassHover = dynamic(light: hex(0xFFFFFF, alpha: 0.5), dark: hex(0xFFFFFF, alpha: 0.1))
        static let glassEdge = dynamic(light: hex(0xFFFFFF, alpha: 0.55), dark: hex(0xFFFFFF, alpha: 0.08))
        /// A tile whose page is open in the background: a fine darker edge in place of the light one.
        static let openEdge = dynamic(light: hex(0x000000, alpha: 0.14), dark: hex(0xFFFFFF, alpha: 0.2))
        /// The sidebar's address: quieter than a field, there without asking to be looked at.
        static let addressFill = dynamic(light: hex(0x000000, alpha: 0.035), dark: hex(0xFFFFFF, alpha: 0.05))
        /// The keyboard-selected row in floating lists (command bar, downloads).
        static let highlight = dynamic(light: hex(0x000000, alpha: 0.07), dark: hex(0xFFFFFF, alpha: 0.09))
        static let fieldFill = dynamic(light: hex(0x000000, alpha: 0.045), dark: hex(0xFFFFFF, alpha: 0.06))

        /// The secondary button, a dropdown, a page's search field: white with a hairline and a faint shadow, a lighter
        /// step of the surface in dark mode. Hover is a hair grayer, pressed a step darker; never a scale.
        static let controlFill = dynamic(light: hex(0xFFFFFF), dark: hex(0xFFFFFF, alpha: 0.09))
        static let controlHover = dynamic(light: hex(0xF6F6F7), dark: hex(0xFFFFFF, alpha: 0.13))
        static let controlPressed = dynamic(light: hex(0xECECEE), dark: hex(0xFFFFFF, alpha: 0.06))
        static let controlEdge = dynamic(light: hex(0x000000, alpha: 0.12), dark: hex(0xFFFFFF, alpha: 0.1))
        static let controlShadow = dynamic(light: hex(0x000000, alpha: 0.06), dark: hex(0x000000, alpha: 0.3))
        /// The one primary action on a surface: a dark filled pill (light in dark mode), whatever the space.
        static let primaryFill = dynamic(light: hex(0x1D1D1F), dark: hex(0xF2F2F4))
        static let primaryHover = dynamic(light: hex(0x343437), dark: hex(0xFFFFFF))
        static let primaryPressed = dynamic(light: hex(0x000000), dark: hex(0xD9D9DD))
        static let onPrimary = dynamic(light: hex(0xFFFFFF), dark: hex(0x1D1D1F))
        /// A switch that's off: a clear gray track, so on and off never look alike.
        static let toggleOff = dynamic(light: hex(0x000000, alpha: 0.14), dark: hex(0xFFFFFF, alpha: 0.2))
        /// Keyboard focus on a drawn control: a ring in the window's accent at this opacity, `Metric.focusRing` wide,
        /// `Metric.focusGap` outside the control.
        static let focusAlpha: CGFloat = 0.6

        static let separator = dynamic(light: hex(0x000000, alpha: 0.08), dark: hex(0xFFFFFF, alpha: 0.08))

        /// The page card when there is no page, and its edge.
        static let cardBackground = dynamic(light: hex(0xFFFFFF), dark: hex(0x1E1E20))
        static let cardEdge = dynamic(light: hex(0x000000, alpha: 0.07), dark: hex(0xFFFFFF, alpha: 0.07))
        /// Only shadow in the window: lifts the page off the frame.
        static let cardShadow = dynamic(light: hex(0x000000, alpha: 0.07), dark: hex(0x000000, alpha: 0.28))

        /// Floating surfaces (command bar, previews, switcher), where they're solid.
        static let panelBackground = dynamic(light: hex(0xFCFCFC), dark: hex(0x2A2A2D))
        /// The panel color washed over a floating panel's glass: enough to keep text calm and readable on any page,
        /// little enough that the glass still reads as glass.
        static let panelWash = dynamic(light: hex(0xFFFFFF, alpha: 0.8), dark: hex(0x1F1F22, alpha: 0.76))
        static let panelEdge = dynamic(light: hex(0x000000, alpha: 0.10), dark: hex(0xFFFFFF, alpha: 0.10))
        static let panelShadow = dynamic(light: hex(0x000000, alpha: 0.13), dark: hex(0x000000, alpha: 0.42))
        static let contactShadow = dynamic(light: hex(0x000000, alpha: 0.12), dark: hex(0x000000, alpha: 0.5))
        /// A floating menu's lit top edge: a faint light line inside its upper rim, so it reads as an object above the page.
        static let topHighlight = dynamic(light: hex(0xFFFFFF, alpha: 0.9), dark: hex(0xFFFFFF, alpha: 0.12))
        static let scrim = dynamic(light: hex(0x000000, alpha: 0.10), dark: hex(0x000000, alpha: 0.30))

        /// Zigzag's one accent. The rule: UI in a browser window takes that window's space accent, so progress,
        /// focus, selection and actions agree there; windows that belong to the app rather than a space (Settings,
        /// Passwords, Import, About, the welcome) take the brand's, `Brand.Theme.brand`. This is the front browser
        /// window's; a view that can show in either kind of window asks `Brand.Theme.for(self)` instead.
        @MainActor static var accent: NSColor { Brand.Theme.current.accent }
        /// Counts on extension buttons: quiet, never competing with the page.
        static let badge = dynamic(light: hex(0x6E6E73), dark: hex(0x8E8E93))

        /// A page's one surface (History, Settings), the same as the page card's.
        static let surface = cardBackground
        /// A group of rows on the surface, and its hairline edge.
        static let surfaceGroup = dynamic(light: hex(0xFFFFFF), dark: hex(0x2A2A2D))
        static let surfaceGroupEdge = dynamic(light: hex(0x000000, alpha: 0.08), dark: hex(0xFFFFFF, alpha: 0.06))
        /// Behind a PDF's pages and in its sidebar: a shade off the card, so each page stands out as paper.
        static let pdfBackdrop = dynamic(light: hex(0xEDEDF0), dark: hex(0x161618))
        /// Between a PDF's pages while they're drawn dark: a shade lighter than the dark paper, so each still reads as one.
        static let pdfBackdropDarkPages = hex(0x2A2A2D)
        /// Something chosen in a list (a section, a row reached with the keyboard), drawn in the accent at this opacity.
        static let selectionAlpha: CGFloat = 0.14
        /// The same, held down.
        static let selectionPressedAlpha: CGFloat = 0.22
        /// Where something carried would land (a folder, the first favorite's place, a split's half): the accent at
        /// this opacity, inside a `Metric.dropEdge` accent edge at `dropEdgeAlpha`. One look for every drop target.
        static let dropAlpha: CGFloat = 0.14
        static let dropEdgeAlpha: CGFloat = 0.7
        /// The header of the split pane you're not working in, faded to this, so the one you are reads first.
        static let unfocusedPaneAlpha: CGFloat = 0.45
        /// Selected text in our own fields (the command bar, its inline completion), in the accent at this opacity.
        static let textSelectionAlpha: CGFloat = 0.26
        /// A firmer dim than `scrim`, under Peek: a page above the page should read as a layer.
        static let peekScrim = dynamic(light: hex(0x000000, alpha: 0.2), dark: hex(0x000000, alpha: 0.42))
        /// A keycap's fill and edge (`KeyCap`): a touch of the field fill with a hairline, like a key seen from above.
        static let keyCapFill = dynamic(light: hex(0x000000, alpha: 0.04), dark: hex(0xFFFFFF, alpha: 0.07))
        static let keyCapEdge = dynamic(light: hex(0x000000, alpha: 0.1), dark: hex(0xFFFFFF, alpha: 0.1))

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

        /// Text on a color Zigzag doesn't choose (a site's brand on its search chip, a page's own top color in Peek):
        /// near-white on dark colors, near-black on light ones.
        static func ink(on color: NSColor) -> NSColor {
            guard let c = color.usingColorSpace(.sRGB) else { return textPrimary }
            let luminance = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
            return luminance < 0.58 ? hex(0xFFFFFF, alpha: 0.94) : hex(0x000000, alpha: 0.84)
        }

        /// How dark a color is, 0 to 1 by its luminance: for deciding whether a color we don't choose needs an edge.
        static func luminance(of color: NSColor) -> CGFloat {
            guard let c = color.usingColorSpace(.sRGB) else { return 0.5 }
            return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        }
        /// A status color's soft fill behind a note (a weak password's warning): the color at this opacity.
        static let statusFillAlpha: CGFloat = 0.12
        /// Light ink and fills on the brand's blue frame (the welcome, onboarding): the ribbon's own color, and how
        /// much of it a quiet line, a quiet fill and a lit fill take.
        static let onFrameSecondaryAlpha: CGFloat = 0.72
        static let onFrameFillAlpha: CGFloat = 0.1
        static let onFrameChosenAlpha: CGFloat = 0.2
    }

    // MARK: - Materials (the tactile kit in Materials.swift; Design/DESIGN.md, "Materials")

    /// One light, straight above: highlights sit on top edges, shadows fall straight down and are tinted with the
    /// navy, so they read as shade on a colored world rather than gray smudges.
    enum Material {
        /// A color for light and one for dark, resolved by the layer that draws it.
        struct Tone {
            let light: NSColor
            let dark: NSColor
            func cg(_ isDark: Bool) -> CGColor { (isDark ? dark : light).cgColor }
        }

        /// How far a thing stands off what's under it: a wide, soft ambient shadow and a tight contact one.
        struct Elevation {
            var ambientRadius: CGFloat, ambientDrop: CGFloat, ambientOpacity: Float
            var contactRadius: CGFloat, contactDrop: CGFloat, contactOpacity: Float

            /// The same elevation for a thing `factor` times the size it was drawn for.
            func scaled(_ factor: CGFloat) -> Elevation {
                Elevation(ambientRadius: ambientRadius * factor, ambientDrop: ambientDrop * factor, ambientOpacity: ambientOpacity,
                          contactRadius: contactRadius * factor, contactDrop: contactDrop * factor, contactOpacity: contactOpacity)
            }
        }

        private static func white(_ alpha: CGFloat) -> NSColor { Color.hex(0xFFFFFF, alpha: alpha) }
        private static func ink(_ alpha: CGFloat) -> NSColor { Color.hex(0x0B1A2E, alpha: alpha) }

        /// The color shadows are made of. Dark mode's are deeper (`darkShadowGain`), since dark surfaces need more to part.
        static let shadowInk = Tone(light: Color.hex(0x0B1A2E), dark: Color.hex(0x000000))
        static let darkShadowGain: Float = 2.2

        /// The specular rim along a raised or glass thing's top edge, and the fainter light caught at its bottom edge.
        static let rim = Tone(light: white(0.95), dark: white(0.30))
        static let rimCatch = Tone(light: white(0.5), dark: white(0.08))
        /// The darker bottom of a raised thing's bevel.
        static let bevelShade = Tone(light: ink(0.16), dark: Color.hex(0x000000, alpha: 0.5))
        /// A hairline just outside a raised or glass thing, so it parts from what's behind it.
        static let outline = Tone(light: ink(0.10), dark: Color.hex(0x000000, alpha: 0.55))

        /// Raised surfaces (a secondary button): lit at the top, a step deeper at the bottom.
        static let raisedTop = Tone(light: Color.hex(0xFFFFFF), dark: Color.hex(0x464A54))
        static let raisedBottom = Tone(light: Color.hex(0xEEF1F5), dark: Color.hex(0x30333B))
        /// The same pressed in: the gradient turned over, so the light seems to fall into it.
        static let pressedTop = Tone(light: Color.hex(0xE3E7ED), dark: Color.hex(0x2A2D34))
        static let pressedBottom = Tone(light: Color.hex(0xF4F6F9), dark: Color.hex(0x3A3D46))
        /// A tile's porcelain body, and a toggle's knob.
        static let porcelainTop = Tone(light: Color.hex(0xFAFBFD), dark: Color.hex(0xE2E7EE))
        static let porcelainBottom = Tone(light: Color.hex(0xE2E7EE), dark: Color.hex(0xB3BDCB))

        /// Recessed things (a field, a toggle's track): darker at the top where the lip shades them, an inner
        /// shadow under that lip, and the light caught on the lower lip outside.
        static let recessTop = Tone(light: ink(0.10), dark: Color.hex(0x000000, alpha: 0.42))
        static let recessBottom = Tone(light: ink(0.035), dark: Color.hex(0x000000, alpha: 0.26))
        static let recessShade = Tone(light: ink(0.30), dark: Color.hex(0x000000, alpha: 0.9))
        static let lip = Tone(light: white(0.9), dark: white(0.09))

        /// Glass: the wash over the frost, top to bottom, the glow just inside its edge, and the specular hot spot.
        static let glassWashTop = Tone(light: white(0.50), dark: white(0.07))
        static let glassWashBottom = Tone(light: white(0.20), dark: white(0.02))
        static let glassGlow = Tone(light: white(1), dark: white(0.5))
        static let sheen = Tone(light: white(0.85), dark: white(0.22))
        /// Text on a tactile primary, which keeps the deep accent in dark mode too, glossy and saturated.
        static let primaryInk = NSColor.white
        /// Grain over glass, so it reads as a material rather than a screen.
        static let grainOpacity: Float = 0.05

        /// Elevations: a raised control at rest, under the pointer and pressed; a 64pt tile at rest and lifted
        /// (scale with its side); a floating glass surface.
        static let raisedRest = Elevation(ambientRadius: 6, ambientDrop: 3, ambientOpacity: 0.12, contactRadius: 1, contactDrop: 1, contactOpacity: 0.2)
        static let raisedHover = Elevation(ambientRadius: 10, ambientDrop: 5, ambientOpacity: 0.16, contactRadius: 1.5, contactDrop: 1.5, contactOpacity: 0.18)
        static let raisedPressed = Elevation(ambientRadius: 2, ambientDrop: 1, ambientOpacity: 0.06, contactRadius: 0.5, contactDrop: 0.5, contactOpacity: 0.22)
        static let tileRest = Elevation(ambientRadius: 12, ambientDrop: 10, ambientOpacity: 0.2, contactRadius: 1.5, contactDrop: 1.5, contactOpacity: 0.24)
        static let tileLifted = Elevation(ambientRadius: 20, ambientDrop: 17, ambientOpacity: 0.24, contactRadius: 2.5, contactDrop: 2, contactOpacity: 0.16)
        static let floating = Elevation(ambientRadius: 44, ambientDrop: 26, ambientOpacity: 0.16, contactRadius: 1.5, contactDrop: 1, contactOpacity: 0.12)

        /// How far a raised thing rises under the pointer, how far a pressed one sinks, and a lifted tile's rise.
        static let lift: CGFloat = 1
        static let sink: CGFloat = 1
        static let tileLift: CGFloat = 3
        /// A pressed control shrinks a touch as it sinks, as a thing pushed away from you does.
        static let pressScale: CGFloat = 0.97
        /// The most a hero object turns toward the pointer, in degrees, and the depth it's seen from.
        static let tilt: CGFloat = 5
        static let perspective: CGFloat = -1 / 1100
        /// A material object rising, sinking or settling: the one hover that moves rather than appears, since it's
        /// a thing moving, not a fill changing. Pressing in is quicker than coming back.
        static let settle: TimeInterval = Motion.standard
        static let pressIn: TimeInterval = Motion.quick
        /// Turning to follow the pointer: slow enough to feel like weight.
        static let follow: TimeInterval = 0.6
        /// A tile's corner as a share of its side, as app icons have it.
        static let tileCorner: CGFloat = 0.2237
        /// A large glass surface on a brand moment, and the height of its tactile controls.
        static let heroRadius: CGFloat = 28
        static let controlHeight: CGFloat = Space.x10
        /// The one big action on a brand moment ("Get Started"), and its text.
        static let largeControlHeight: CGFloat = Space.x10 + Space.x1
        static let largeText: CGFloat = 15
        /// A brand moment's headline: one line saying what Zigzag is.
        static let headline: CGFloat = 30
    }

    // MARK: - Shadows (purposeful only)

    enum Shadow {
        /// Card: barely there, separates page from frame.
        static let cardRadius: CGFloat = 2
        static let cardOffset = CGSize(width: 0, height: -1)
        /// Floating panels sit just above the page: a soft, wide shadow that falls below them, never above.
        static let panelRadius: CGFloat = 24
        static let panelDrop: CGFloat = 4
        /// The selected row's card and a selected tile: a faint shadow just under them.
        static let liftRadius: CGFloat = 3
        static let liftDrop: CGFloat = 1
        /// A secondary button's faint shadow: just enough to sit on the white it's on.
        static let controlRadius: CGFloat = 1.5
        static let controlDrop: CGFloat = 0.5
        /// A menu's depth, in two layers: a tight contact shadow right under its edge, and the wide panel shadow around it.
        static let contactRadius: CGFloat = 1.5
        static let contactDrop: CGFloat = 1

        /// The drop as a layer offset: flipped views measure y downward, so the sign follows the view.
        static func panelOffset(flipped: Bool) -> CGSize { CGSize(width: 0, height: flipped ? panelDrop : -panelDrop) }
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}
