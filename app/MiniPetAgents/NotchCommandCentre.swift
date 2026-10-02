import AppKit
import QuartzCore

/// The notch command centre: a shelf pinned under the top edge of the screen
/// that holds every spawned pet, and expands on hover into a roster you can
/// pick from.
///
/// The illusion this rests on is that the shelf is the *same black as the
/// physical notch* and bleeds off the top of the screen, so hardware and
/// software read as one piece. Everything else follows from that: no border,
/// no shadow, no vibrancy, and the only light in the composition is a pet's
/// own glow.
///
/// Deliberately notch-**aware**, not notch-dependent. `safeAreaInsets.top` is
/// non-zero only on notched Macs; everywhere else the shelf docks to the top
/// edge at the same width and behaves identically. A feature that only exists
/// on recent MacBook Pros would be invisible to most of the people who install
/// this.
final class NotchCommandCentre {

    // MARK: Geometry

    /// At rest the shelf must not be wider than the hardware notch, or it
    /// eats menu-bar items either side of it — which it did at a fixed 420pt,
    /// covering the Window menu. On a notched Mac it matches the cut-out, so
    /// resting costs the user nothing; elsewhere it falls back to a narrow
    /// strip that reads as a deliberate tab rather than a bar across the menu.
    private static let restingFallbackWidth: CGFloat = 168
    /// How much wider than the cut-out the peek runs — enough for the active
    /// pet and the roster dots to sit on the visible strips either side.
    private static let peekPadding: CGFloat = 210
    private static let restingHeight: CGFloat = 36
    private static let expandedWidth: CGFloat = 620
    /// Activity needs room for several rows; Pets does not. Height follows the
    /// mode so neither one is padded out to fit the other.
    private static func expandedHeight(for mode: NotchShelfView.Mode) -> CGFloat {
        mode == .activity ? 320 : 188
    }
    /// Hover has to be deliberate — without a delay the shelf flickers open
    /// every time the pointer crosses the top of the screen on its way
    /// somewhere else.
    private static let hoverIntent: TimeInterval = 0.12
    private static let cornerRadius: CGFloat = 26

    /// Three stages, escalating with intent.
    ///
    /// `collapsed` is the whole UI when you are not using it: notch width, a
    /// single dot in the active pet's status colour. It costs no menu-bar
    /// space and still tells you at a glance whether anything is working.
    /// `peek` widens the shelf on hover to show who. `expanded` is a click,
    /// because opening a panel over someone's menu bar should be deliberate.
    enum Stage { case collapsed, peek, expanded }

    private(set) var stage: Stage = .collapsed
    var isExpanded: Bool { stage == .expanded }
    private weak var controller: PetAgentsController?
    private var window: NSWindow?
    private var hostView: NotchShelfView?
    private var hoverTimer: Timer?

    private var feedObserver: NSObjectProtocol?

    init(controller: PetAgentsController) {
        self.controller = controller
        feedObserver = NotificationCenter.default.addObserver(
            forName: ActivityStore.didChange, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            }
    }

    /// Height of the hardware notch, or 0 on a screen without one.
    static func notchHeight(for screen: NSScreen) -> CGFloat {
        screen.safeAreaInsets.top
    }

    /// Width of the physical notch cut-out, or 0 when there isn't one.
    /// `auxiliaryTopLeftArea` is the usable strip left of the cut-out, so the
    /// cut-out is whatever sits between the two auxiliary areas.
    static func notchWidth(for screen: NSScreen) -> CGFloat {
        guard let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return 0 }
        return max(0, right.minX - left.maxX)
    }

    /// Resting width: the hardware cut-out where there is one, so the shelf
    /// costs the user no menu-bar space at all.
    private static func restingWidth(on screen: NSScreen) -> CGFloat {
        let notch = notchWidth(for: screen)
        return notch > 0 ? notch : restingFallbackWidth
    }

    private func frame(on screen: NSScreen, stage: Stage) -> NSRect {
        let notchH = Self.notchHeight(for: screen)
        let base = Self.restingWidth(on: screen)
        let w: CGFloat
        let h: CGFloat
        switch stage {
        case .collapsed:
            w = base
            h = max(Self.restingHeight, notchH)
        case .peek:
            w = base + Self.peekPadding
            h = max(Self.restingHeight, notchH)
        case .expanded:
            w = Self.expandedWidth
            h = Self.expandedHeight(for: hostView?.mode ?? .pets)
        }
        // Pinned to the very top of the full frame, not visibleFrame: the
        // shelf must run under the menu bar to meet the notch.
        return NSRect(x: screen.frame.midX - w / 2,
                      y: screen.frame.maxY - h,
                      width: w, height: h)
    }

    // MARK: Lifecycle

    func show(on screen: NSScreen) {
        if window == nil { build(on: screen) }
        guard let window = window else { return }
        window.setFrame(frame(on: screen, stage: stage), display: true)
        window.orderFrontRegardless()
        refresh()
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func build(on screen: NSScreen) {
        let win = NSWindow(contentRect: frame(on: screen, stage: .collapsed),
                           styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        // Above the menu bar, so the shelf can meet the notch rather than
        // being clipped under it.
        win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        win.ignoresMouseEvents = false

        let view = NotchShelfView(frame: NSRect(origin: .zero, size: win.frame.size))
        view.onHoverChanged = { [weak self] inside in self?.hoverChanged(inside) }
        view.onModeChanged = { [weak self] _ in self?.resizeForMode() }
        // A click is what opens the panel. Hover only ever peeks.
        view.onActivate = { [weak self] in
            guard let self = self else { return }
            if self.stage != .expanded { self.setStage(.expanded) }
        }
        win.contentView = view

        window = win
        hostView = view
    }

    // MARK: Hover

    private func hoverChanged(_ inside: Bool) {
        hoverTimer?.invalidate()
        if inside {
            // Only peek on hover, and only after the pointer has settled —
            // without the delay the shelf twitches every time someone crosses
            // the top of the screen on the way to a menu.
            guard stage == .collapsed else { return }
            hoverTimer = Timer.scheduledTimer(withTimeInterval: Self.hoverIntent, repeats: false) { [weak self] _ in
                self?.setStage(.peek)
            }
        } else {
            setStage(.collapsed)
        }
    }

    func setStage(_ newStage: Stage) {
        guard newStage != stage, let window = window,
              let screen = window.screen ?? NSScreen.main else { return }
        let growing = newStage != .collapsed && stage == .collapsed || newStage == .expanded
        stage = newStage
        let target = frame(on: screen, stage: newStage)

        // Spring, not a duration curve. Opening overshoots slightly so the
        // shelf reads as one piece of material stretching; closing does not,
        // because a shelf that bounces shut looks like a bug.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = growing ? 0.30 : 0.20
            ctx.timingFunction = growing
                ? CAMediaTimingFunction(controlPoints: 0.22, 1.2, 0.3, 1)
                : CAMediaTimingFunction(name: .easeIn)
            ctx.allowsImplicitAnimation = true
            window.animator().setFrame(target, display: true)
        }
        hostView?.setStage(newStage, size: target.size)
        refresh()
    }

    /// A mode change can change the shelf's height; animate it the same way
    /// the open does, so the two never look like different mechanisms.
    private func resizeForMode() {
        guard isExpanded, let window = window,
              let screen = window.screen ?? NSScreen.main else { return }
        let target = frame(on: screen, stage: .expanded)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.1, 0.3, 1)
            ctx.allowsImplicitAnimation = true
            window.animator().setFrame(target, display: true)
        }
        hostView?.setStage(.expanded, size: target.size)
        refresh()
    }

    // MARK: Content

    /// Push the current roster into the shelf. Cheap enough to call per tick.
    func refresh() {
        guard let controller = controller, let view = hostView else { return }
        let pets: [NotchShelfView.Entry] = controller.characters.compactMap { pet in
            guard let frameImage = pet.currentSpriteFrame() else { return nil }
            return NotchShelfView.Entry(slug: pet.petSlug,
                                        image: frameImage,
                                        tint: Self.statusColour(for: pet.spriteState),
                                        isBusy: pet.isAgentBusy)
        }
        view.update(entries: pets)

        let store = ActivityStore.shared
        let bySlug = Dictionary(uniqueKeysWithValues: controller.characters.map { ($0.petSlug, $0) })
        let rows = store.records.prefix(12).map { record -> NotchShelfView.ActivityRow in
            NotchShelfView.ActivityRow(
                name: record.petSlug,
                provider: record.provider.displayName,
                activity: record.activity,
                state: record.state,
                trailing: Self.trailing(for: record),
                remedy: record.remedy?.title,
                tint: Self.tint(for: record.state),
                image: bySlug[record.petSlug]?.currentSpriteFrame())
        }
        let totals = store.totals()
        view.update(rows: Array(rows),
                    summary: totals.turns == 0 ? ""
                        : "last 20 min · \(totals.turns) turns\(totals.failures > 0 ? " · \(totals.failures) failed" : "")")
    }

    /// Duration plus whatever the provider said about usage — never a number
    /// we worked out ourselves.
    static func trailing(for record: ActivityStore.Record) -> String {
        let seconds = Int(record.duration.rounded())
        let time = seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
        guard let usage = record.usageNote, !usage.isEmpty else { return time }
        return "\(time) · \(usage)"
    }

    static func tint(for state: ActivityStore.Record.State) -> NSColor {
        switch state {
        case .live:        return NSColor(srgbRed: 0.81, green: 0.89, blue: 0.96, alpha: 1)
        case .done:        return NSColor(srgbRed: 0.18, green: 0.84, blue: 0.66, alpha: 1)
        case .failed:      return NSColor(srgbRed: 1.00, green: 0.23, blue: 0.36, alpha: 1)
        case .interrupted: return NSColor(white: 0.55, alpha: 1)
        }
    }

    /// Status is carried by one colour per state — the same vocabulary the
    /// sprite already speaks, so the shelf and the pet never disagree.
    static func statusColour(for state: PetState) -> NSColor {
        switch state {
        case .failed:                 return NSColor(srgbRed: 1.00, green: 0.23, blue: 0.36, alpha: 1)
        case .waiting:                return NSColor(srgbRed: 1.00, green: 0.70, blue: 0.14, alpha: 1)
        case .review:                 return NSColor(srgbRed: 0.61, green: 0.42, blue: 1.00, alpha: 1)
        case .jumping:                return NSColor(srgbRed: 0.18, green: 0.84, blue: 0.66, alpha: 1)
        default:                      return NSColor(srgbRed: 0.81, green: 0.89, blue: 0.96, alpha: 1)
        }
    }

    deinit {
        hoverTimer?.invalidate()
        if let feedObserver { NotificationCenter.default.removeObserver(feedObserver) }
    }
}
