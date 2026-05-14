import AppKit
import QuartzCore

/// Persists popover size in `PetLibrary` whenever the user resizes the chat
/// window. One instance per `WalkerCharacter`.
final class PopoverWindowDelegate: NSObject, NSWindowDelegate {
    let slug: String
    init(slug: String) { self.slug = slug }
    func windowDidResize(_ notification: Notification) {
        guard let win = notification.object as? NSWindow else { return }
        PetLibrary.setPopoverSize(win.frame.size, for: slug)
    }
}

/// Backing view for the thinking / completion bubble. Routes mouseDown
/// to `onClick` (used by the completion bubble for click-to-dismiss).
final class ClickableBubbleView: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// Yellow "—" minimize chip in the chat title bar — visually mirrors the
/// macOS traffic-light minimize button.
final class MinimizeChip: NSView {
    var onClick: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let circle = NSBezierPath(ovalIn: r)
        NSColor(calibratedRed: 0.99, green: 0.78, blue: 0.30, alpha: 1).setFill()
        circle.fill()
        NSColor.black.withAlphaComponent(0.45).setStroke()
        let bar = NSBezierPath()
        bar.move(to: NSPoint(x: r.minX + 3, y: r.midY))
        bar.line(to: NSPoint(x: r.maxX - 3, y: r.midY))
        bar.lineWidth = 1.5
        bar.lineCapStyle = .round
        bar.stroke()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// Diagonal-stripe corner grip in the bottom-right of the chat window.
/// Drag to resize from the bottom-right; window's top-left stays anchored.
final class PopoverResizeGrip: NSView {
    weak var targetWindow: NSWindow?
    private var initialMouse: NSPoint = .zero
    private var initialFrame: NSRect = .zero

    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.withAlphaComponent(0.55).setStroke()
        let path = NSBezierPath()
        let step: CGFloat = 4
        var d: CGFloat = 3
        while d < bounds.width - 1 {
            path.move(to: NSPoint(x: bounds.maxX - d, y: bounds.minY + 2))
            path.line(to: NSPoint(x: bounds.maxX - 2, y: bounds.minY + d))
            d += step
        }
        path.lineWidth = 1.2
        path.lineCapStyle = .round
        path.stroke()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: NSCursor(image: NSCursor.arrow.image, hotSpot: .zero))
    }

    override func mouseDown(with event: NSEvent) {
        initialMouse = NSEvent.mouseLocation
        initialFrame = targetWindow?.frame ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard let win = targetWindow else { return }
        let cur = NSEvent.mouseLocation
        let dx = cur.x - initialMouse.x
        let dy = initialMouse.y - cur.y           // drag down → window grows down
        let minS = PetLibrary.minPopoverSize
        let maxS = PetLibrary.maxPopoverSize
        let newW = min(maxS.width,  max(minS.width,  initialFrame.width  + dx))
        let newH = min(maxS.height, max(minS.height, initialFrame.height + dy))
        // Anchor the top-left corner so the title bar stays put.
        let newOrigin = NSPoint(x: initialFrame.origin.x,
                                y: initialFrame.origin.y + (initialFrame.height - newH))
        win.setFrame(NSRect(origin: newOrigin, size: NSSize(width: newW, height: newH)),
                     display: true)
    }
}

/// `WalkerCharacter` is the on-screen, animated pet. It used to render an
/// HEVC video; this implementation drives a sprite-sheet animator instead.
/// The class name is preserved so the rest of the app (CharacterContentView,
/// PopoverTheme integration, the controller tick loop) keeps working.
class WalkerCharacter {
    // MARK: - Identity

    /// petdex slug, e.g. `noir-webling`. Empty for placeholder/onboarding.
    let petSlug: String
    /// Optional bundled pet pack to render. When `nil`, the character renders
    /// a single placeholder sprite frame.
    var petPack: PetPack?

    var window: NSWindow!
    var spriteLayer: CALayer!

    // MARK: - Sizing (global default + per-pet override in `PetLibrary`)

    var displayHeight: CGFloat { PetLibrary.displayHeight(for: petSlug) }
    var displayWidth: CGFloat { displayHeight }

    // MARK: - Walk timing (kept compatible with LilAgents tunables)

    /// Base walk-cycle duration (seconds). Effective duration = `videoDuration / walkSpeedMultiplier`.
    let videoDuration: CFTimeInterval = 10.0
    /// Per-tick scaling applied by placement strategies before consuming `videoDuration`.
    /// Defaults to 1.0; pulled from `PetLibrary.resolvedWalkSpeed` each tick.
    var walkSpeedMultiplier: Double = 1.0
    var accelStart: CFTimeInterval = 3.0
    var fullSpeedStart: CFTimeInterval = 3.75
    var decelStart: CFTimeInterval = 7.5
    var walkStop: CFTimeInterval = 8.25
    var walkAmountRange: ClosedRange<CGFloat> = 0.25...0.5
    var yOffset: CGFloat = 0
    var flipXOffset: CGFloat = 0
    /// Device RGB so `PopoverTheme.withCharacterColor` can read RGB components (`.gray` is grayscale and throws).
    var characterColor: NSColor = NSColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)

    // MARK: - Walk state

    var walkStartTime: CFTimeInterval = 0
    /// Speed-scaled elapsed time for the current walk, integrated per tick as
    /// `dt * walkSpeedMultiplier`. Decoupling from `(now - walkStartTime)`
    /// prevents velocity jumps when the multiplier changes mid-walk.
    var walkScaledElapsed: CFTimeInterval = 0
    private var walkLastTickTime: CFTimeInterval = 0
    /// Debounce: timestamp at which `shouldHoldForActivity` first became true.
    /// Single-tick session-state churn won't freeze movement.
    private var holdRequestStart: CFTimeInterval?
    private static let holdDebounceWindow: CFTimeInterval = 0.2
    var positionProgress: CGFloat = 0.0
    var isWalking = false
    var isPaused = true
    var pauseEndTime: CFTimeInterval = 0
    var goingRight = true
    var walkStartPos: CGFloat = 0.0
    var walkEndPos: CGFloat = 0.0
    var currentTravelDistance: CGFloat = 500.0
    var walkStartPixel: CGFloat = 0.0
    var walkEndPixel: CGFloat = 0.0

    /// Free-roam target (used by `PlacementMode.freeRoam`). nil means "pick one".
    var roamTargetX: CGFloat?
    var roamTargetY: CGFloat?
    var roamY: CGFloat = 0

    // MARK: - Placement

    /// Per-pet placement preference. Defaults to dock.
    var placement: PlacementMode = .dock

    /// True while the user is dragging the pet window. Skips per-tick placement
    /// updates so the window stays where the cursor is until mouseUp.
    var isShiftDraggingWindow = false
    /// CACurrentMediaTime() until which placement strategies should leave the
    /// pet alone after a free-drag, so the user's drop position doesn't snap
    /// back to a computed origin instantly.
    var dragCooldownUntil: CFTimeInterval = 0

    // MARK: - Throw / ballistic physics
    //
    // When the user releases a drag with enough cursor velocity, the pet
    // enters a ballistic state and flies under gravity until it settles.
    // While `isBallistic == true`, placement strategies are skipped and
    // `tickBallistic(now:)` integrates motion + edge bounces.

    /// Rolling cursor-position samples (screen coords) captured during drag,
    /// used to estimate release velocity on mouseUp.
    private var dragSamples: [(t: CFTimeInterval, p: NSPoint)] = []
    /// True while the pet is flying after a throw.
    var isBallistic: Bool = false
    private var ballisticVx: CGFloat = 0
    private var ballisticVy: CGFloat = 0
    private var ballisticLastTick: CFTimeInterval = 0
    /// Tunables — chosen for "feels good on a 16-inch laptop screen".
    private static let throwSpeedThreshold: CGFloat = 350      // pt/s release speed needed to trigger throw
    private static let ballisticAirDrag: CGFloat = 1.4         // per-second exponential decay (higher = stops sooner)
    private static let ballisticRestitution: CGFloat = 0.7     // bounce energy retained on any wall
    private static let ballisticSettleSpeed: CGFloat = 60      // |v| below this → settle wherever the pet is

    // MARK: - Onboarding

    var isOnboarding = false

    // MARK: - Popover state

    var isIdleForPopover = false
    var popoverWindow: NSWindow?
    var terminalView: TerminalView?
    var session: (any AgentSession)?
    var clickOutsideMonitor: Any?
    var escapeKeyMonitor: Any?
    var currentStreamingText = ""
    weak var controller: PetAgentsController?
    var themeOverride: PopoverTheme?
    var providerOverride: AgentProvider?
    var resolvedProvider: AgentProvider { providerOverride ?? AgentProvider.current }
    var isAgentBusy: Bool { session?.isBusy ?? false }
    var thinkingBubbleWindow: NSWindow?
    var clickAction: (() -> Void)?
    /// Window delegate that persists popover size on resize.
    private(set) lazy var popoverDelegate: PopoverWindowDelegate = PopoverWindowDelegate(slug: petSlug)

    // MARK: - Sprite animator

    private var animator: SpriteAnimator?
    /// Current high-level state. Drives which sprite frames play.
    /// Public read; private write — set via `setSpriteState(_:source:)` so the
    /// `BehaviorPlanner` can tell session-driven changes from autonomous ones.
    private(set) var spriteState: PetState = .idle {
        didSet { if oldValue != spriteState { animator?.play(state: spriteState) } }
    }
    /// CACurrentMediaTime() of the last session-callback-induced state change.
    /// `BehaviorPlanner` waits a quiet window after this before picking new states.
    private(set) var lastSessionEventTime: CFTimeInterval = 0
    /// CACurrentMediaTime() at which the current `.jumping` hop should end (0 = no hop).
    var hopEndTime: CFTimeInterval = 0
    /// Where the hop started, in window-frame coordinates. Used to interpolate the sin-curve y offset.
    var hopBaseY: CGFloat = 0
    /// True while the cursor is over the pet. Drives a continuous wave-and-bounce.
    var isHovering: Bool = false
    /// CACurrentMediaTime() at which hover began — phase reference for the sin curves.
    var hoverStartTime: CFTimeInterval = 0
    /// CACurrentMediaTime() at which the most recent edge-bump squash should end.
    var bumpEndTime: CFTimeInterval = 0
    private static let bumpDuration: CFTimeInterval = 0.25
    /// Last `notifyGreet` time, to suppress repeated triggers during one near-pass.
    var lastGreetTime: CFTimeInterval = 0

    enum SpriteStateSource {
        case session   // wired session callbacks (text/turnComplete/error/toolUse)
        case planner   // BehaviorPlanner
        case ui        // popover open/close, drag, onboarding
    }

    /// Mutate `spriteState`. Records the last session-event time so the planner backs off.
    func setSpriteState(_ state: PetState, source: SpriteStateSource) {
        if source == .session { lastSessionEventTime = CACurrentMediaTime() }
        if state == .jumping {
            hopEndTime = CACurrentMediaTime() + 0.8
            hopBaseY = window?.frame.origin.y ?? 0
        }
        spriteState = state
    }

    /// States during which the pet should hold position while the sprite
    /// keeps animating. Caller must guard with `shouldHoldForActivity`
    /// (popover open or agent busy) so a stale session-driven state can't
    /// freeze the pet forever.
    var motionHoldStates: Set<PetState> { [.waiting, .review, .waving] }

    /// Sprite for the current walking direction. Petdex packs ship separate
    /// rows for left and right runs — we pick the right row instead of
    /// flipping the sprite layer.
    var directionalRunState: PetState { goingRight ? .runRight : .runLeft }

    /// True for any "the pet is moving" state — used by tick code that
    /// previously checked `.walk` only.
    func isWalkLikeState(_ s: PetState) -> Bool {
        s == .runRight || s == .runLeft || s == .running
    }

    /// True if the pet has reason to hold position right now: the agent is
    /// busy, the popover is open, or the pet just woke up sad/asleep.
    var shouldHoldForActivity: Bool {
        isAgentBusy || isIdleForPopover
    }

    // MARK: - Init

    init(petSlug: String, petPack: PetPack? = nil) {
        self.petSlug = petSlug
        self.petPack = petPack
    }

    deinit {
        removeEventMonitors()
    }

    // MARK: - Setup

    func setup() {
        spriteLayer = CALayer()
        spriteLayer.contentsGravity = .resizeAspect
        spriteLayer.backgroundColor = NSColor.clear.cgColor
        spriteLayer.frame = CGRect(x: 0, y: 0, width: displayWidth, height: displayHeight)
        spriteLayer.magnificationFilter = .nearest // crisp pixel art
        // Belt-and-suspenders: disable every implicit animation so swapping
        // `contents` (frame change), flipping `transform` (direction change),
        // or resizing `bounds` never cross-fades the sprite. Without this,
        // CALayer's default 0.25s fade can cause the pet to briefly "go
        // invisible" when state changes happen outside our explicit
        // CATransaction blocks.
        spriteLayer.actions = [
            "contents":   NSNull(),
            "transform":  NSNull(),
            "bounds":     NSNull(),
            "position":   NSNull(),
            "frame":      NSNull(),
            "opacity":    NSNull(),
            "hidden":     NSNull(),
            "sublayers":  NSNull(),
        ]

        if let pack = petPack {
            animator = SpriteAnimator(pack: pack, layer: spriteLayer)
            animator?.play(state: .idle)
        } else if let placeholder = NSImage(named: "PlaceholderPet") {
            spriteLayer.contents = placeholder
        }

        guard let screen = NSScreen.main else { return }
        let dockTopY = screen.visibleFrame.origin.y
        let bottomPadding = displayHeight * 0.15
        let y = dockTopY - bottomPadding + yOffset

        let contentRect = CGRect(x: 0, y: y, width: displayWidth, height: displayHeight)
        window = NSWindow(
            contentRect: contentRect,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .statusBar
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.acceptsMouseMovedEvents = true

        let hostView = CharacterContentView(frame: CGRect(x: 0, y: 0, width: displayWidth, height: displayHeight))
        hostView.character = self
        hostView.wantsLayer = true
        hostView.layer?.backgroundColor = NSColor.clear.cgColor
        hostView.layer?.addSublayer(spriteLayer)

        window.contentView = hostView
        window.orderFrontRegardless()
    }

    /// Resize the pet window + layer when the user changes size prefs.
    func applyDisplaySizeFromLibrary() {
        guard let win = window else { return }
        var r = win.frame
        r.size = NSSize(width: displayWidth, height: displayHeight)
        win.setFrame(r, display: true)
        spriteLayer.frame = CGRect(x: 0, y: 0, width: displayWidth, height: displayHeight)
        updateFlip()
        updatePopoverPosition()
    }

    // MARK: - Drag session (drag-to-zone UX)

    /// Show the drop-zone overlay and (optionally) freeze auto-placement.
    func beginDragSession() {
        guard let ctrl = controller, let screen = ctrl.activeScreen else { return }
        DropZoneOverlay.shared.show(on: screen,
                                    dockX: ctrl.lastDockX,
                                    dockWidth: ctrl.lastDockWidth,
                                    dockTopY: screen.visibleFrame.minY)
        dragSamples.removeAll(keepingCapacity: true)
        dragSamples.append((CACurrentMediaTime(), NSEvent.mouseLocation))
        // Cancel any in-flight ballistic from a previous throw.
        isBallistic = false
        // Pause the autonomous mood loop while held.
        lastSessionEventTime = CACurrentMediaTime()
    }

    /// Refresh which zone is highlighted based on the dragged window center.
    /// Also drags the popover + thinking bubble along with the pet so they
    /// don't lag behind waiting for the next controller tick.
    func updateDragSession() {
        guard let win = window else { return }
        let center = NSPoint(x: win.frame.midX, y: win.frame.midY)
        DropZoneOverlay.shared.update(petCenter: center)
        updatePopoverPosition()
        updateThinkingBubble()

        // Ring-buffer the cursor samples — keep only the last ~120ms so the
        // velocity estimate reflects the *release* motion, not the full drag.
        let now = CACurrentMediaTime()
        dragSamples.append((now, NSEvent.mouseLocation))
        let cutoff = now - 0.12
        while dragSamples.count > 1, let first = dragSamples.first, first.t < cutoff {
            dragSamples.removeFirst()
        }
    }

    /// Resolve the drop zone, set placement, and hide the overlay. If the
    /// release velocity is high enough, kick off a ballistic throw instead
    /// of settling at the cursor's drop position.
    func endDragSession() {
        guard let win = window else { return }
        let (vx, vy) = estimateReleaseVelocity()
        let speed = hypot(vx, vy)

        DropZoneOverlay.shared.hide()

        if speed >= Self.throwSpeedThreshold {
            // THROW: skip the zone resolve until the pet lands.
            startBallistic(vx: vx, vy: vy)
            return
        }

        // Slow drop — treat as a deliberate placement.
        let center = NSPoint(x: win.frame.midX, y: win.frame.midY)
        let resolved = DropZoneOverlay.shared.zoneAt(center)
        if resolved != placement, let pet = PetLibrary.shared.pet(slug: petSlug) {
            pet.placement = resolved          // persists via UserDefaults
            placement = resolved
            // FreeRoam needs a fresh roam target; dock will recompute progress.
            roamTargetX = nil
            roamTargetY = nil
            // Refresh the menubar so the per-pet placement check mark moves.
            (NSApp.delegate as? AppDelegate)?.rebuildMenuBar()
        }
        handleDragRelease()
    }

    /// Compute release velocity (pt/s) from the trailing cursor samples.
    /// Uses the oldest-vs-newest sample over the captured window — averages
    /// out single-frame jitter without smearing into stale early samples.
    private func estimateReleaseVelocity() -> (CGFloat, CGFloat) {
        guard let first = dragSamples.first, let last = dragSamples.last,
              last.t > first.t else { return (0, 0) }
        let dt = CGFloat(last.t - first.t)
        return ((last.p.x - first.p.x) / dt,
                (last.p.y - first.p.y) / dt)
    }

    private func startBallistic(vx: CGFloat, vy: CGFloat) {
        isBallistic = true
        ballisticVx = vx
        ballisticVy = vy
        ballisticLastTick = CACurrentMediaTime()
        // Cancel walk/pause state so the placement strategy doesn't fight us.
        isWalking = false
        isPaused = false
        // Native flailing-mid-air sprite. (We don't synthesize a rotation —
        // sprite-only per the user's earlier "no synthetic transforms" rule.)
        setSpriteState(.jumping, source: .ui)
    }

    /// Per-tick ballistic integration. No gravity — pure inertial glide with
    /// air drag, bouncing off all four edges of the visible frame. Settles
    /// wherever the pet runs out of momentum.
    func tickBallistic(now: CFTimeInterval, context ctx: PlacementContext) {
        guard isBallistic, let win = window else { return }

        let dt = max(0.0, min(0.05, CGFloat(now - ballisticLastTick)))   // clamp for stability
        ballisticLastTick = now

        // Exponential air drag on both axes. No gravity — the throw is the
        // only force; the pet glides until friction kills it.
        let dragMul = exp(-Self.ballisticAirDrag * dt)
        ballisticVx *= dragMul
        ballisticVy *= dragMul

        var origin = win.frame.origin
        origin.x += ballisticVx * dt
        origin.y += ballisticVy * dt

        let bounds = ctx.screen.visibleFrame
        let minX = bounds.minX
        let maxX = bounds.maxX - displayWidth
        let minY = bounds.minY
        let maxY = bounds.maxY - displayHeight

        // All four walls bounce identically. No floor-vs-wall distinction —
        // the pet can stop and float anywhere, dock or no dock.
        if origin.x < minX {
            origin.x = minX
            ballisticVx = -ballisticVx * Self.ballisticRestitution
        } else if origin.x > maxX {
            origin.x = maxX
            ballisticVx = -ballisticVx * Self.ballisticRestitution
        }
        if origin.y < minY {
            origin.y = minY
            ballisticVy = -ballisticVy * Self.ballisticRestitution
        } else if origin.y > maxY {
            origin.y = maxY
            ballisticVy = -ballisticVy * Self.ballisticRestitution
        }

        // Update facing from current motion so the sprite reads correctly.
        if abs(ballisticVx) > 20 { goingRight = ballisticVx >= 0 }

        win.setFrameOrigin(origin)
        updateFlip()
        updatePopoverPosition()
        updateThinkingBubble()

        // Settle anywhere on screen once we run out of energy.
        if hypot(ballisticVx, ballisticVy) < Self.ballisticSettleSpeed {
            ballisticVx = 0
            ballisticVy = 0
            finishBallistic()
        }
    }

    private func finishBallistic() {
        isBallistic = false
        // After a throw, always switch to free-roam — the pet stops wherever
        // it ran out of momentum and starts wandering from there. (Slow
        // drops keep using the drag-to-zone resolver; this path is only
        // reached for fast releases.)
        if placement != .freeRoam, let pet = PetLibrary.shared.pet(slug: petSlug) {
            pet.placement = .freeRoam
            placement = .freeRoam
            (NSApp.delegate as? AppDelegate)?.rebuildMenuBar()
        }
        roamTargetX = nil
        roamTargetY = nil
        handleDragRelease()
    }

    /// Called after a free-drag finishes. The pet stays where dropped for a
    /// short cooldown, then placement strategies resume normal motion.
    /// For dock placement we recompute `positionProgress` from the new x so
    /// the next walk continues from the dropped location instead of jumping.
    func handleDragRelease() {
        guard let win = window else { return }
        dragCooldownUntil = CACurrentMediaTime() + 1.5

        if placement == .dock, let ctrl = controller, ctrl.lastDockWidth > displayWidth {
            let travel = ctrl.lastDockWidth - displayWidth
            let pixelOffset = win.frame.origin.x - ctrl.lastDockX - currentFlipCompensation
            positionProgress = min(max(pixelOffset / travel, 0), 1)
        } else if placement == .freeRoam {
            // Drop the in-flight roam target; planner will pick a new one.
            roamTargetX = nil
            roamTargetY = nil
        }

        isWalking = false
        isPaused = true
        pauseEndTime = CACurrentMediaTime() + 1.5
        if spriteState != .waving, spriteState != .waiting {
            setSpriteState(.idle, source: .ui)
        }
        updatePopoverPosition()
        updateThinkingBubble()
    }

    /// Keeps walk sprite frames aligned with movement along the dock (0…1).
    /// No-op: walk frames now cycle at the sprite's natural FPS (set by the
    /// pet's `pet.json`) instead of being pegged to position. Position-locked
    /// frames produced visible stutter on packs with few walk frames; native-
    /// rate playback matches what LilAgents got from HEVC video.
    func syncWalkSpriteFrames(normalized: CGFloat) { /* intentionally empty */ }

    /// Integrate `dt * walkSpeedMultiplier` (with a 2× boost while `.running`)
    /// into `walkScaledElapsed` and return the new total. Used by the dock
    /// and free-roam tick paths so changing speed mid-walk doesn't jump.
    func advanceScaledElapsed(now: CFTimeInterval) -> CFTimeInterval {
        let mult = max(0.1, walkSpeedMultiplier * (spriteState == .running ? 2.0 : 1.0))
        let dt = max(0, now - walkLastTickTime)
        walkLastTickTime = now
        walkScaledElapsed += dt * mult
        return walkScaledElapsed
    }

    /// While held, do not let dt accumulate — the next `advanceScaledElapsed`
    /// call should treat held-time as zero.
    func freezeWalkClock(at now: CFTimeInterval) { walkLastTickTime = now }

    // MARK: - Click Handling & Popover

    func handleClick() {
        if let action = clickAction { action(); return }
        if isOnboarding { openOnboardingPopover(); return }
        if isIdleForPopover { closePopover() } else { openPopover() }
    }

    private func openOnboardingPopover() {
        showingCompletion = false
        hideBubble()

        isIdleForPopover = true
        isWalking = false
        isPaused = true
        setSpriteState(.idle, source: .ui)

        if popoverWindow == nil { createPopoverWindow() }

        terminalView?.inputField.isEditable = false
        terminalView?.inputField.placeholderString = ""
        let welcome = """
        hey! i'm \(petSlug.isEmpty ? "your pet" : petSlug) — your mini pet agent.

        click me to open an AI chat. i'll wander around while you work and let you know when your agent is thinking.

        check the menu bar icon (top right) to install more pets, switch placement modes, or run prompts across all pets at once.

        click anywhere outside to dismiss, then click me again to start chatting.
        """
        terminalView?.appendStreamingText(welcome)
        terminalView?.endStreaming()

        updatePopoverPosition()
        popoverWindow?.orderFrontRegardless()

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            self?.closeOnboarding()
        }
        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.closeOnboarding(); return nil }
            return event
        }
    }

    private func closeOnboarding() {
        if let monitor = clickOutsideMonitor { NSEvent.removeMonitor(monitor); clickOutsideMonitor = nil }
        if let monitor = escapeKeyMonitor { NSEvent.removeMonitor(monitor); escapeKeyMonitor = nil }
        popoverWindow?.orderOut(nil)
        popoverWindow = nil
        terminalView = nil
        isIdleForPopover = false
        isOnboarding = false
        isPaused = true
        pauseEndTime = CACurrentMediaTime() + Double.random(in: 1.0...3.0)
        controller?.completeOnboarding()
    }

    func openPopover() {
        // Stop any in-flight throw so the pet doesn't keep bouncing behind the chat window.
        isBallistic = false
        ballisticVx = 0
        ballisticVy = 0

        isIdleForPopover = true
        isWalking = false
        isPaused = true
        // While the chat is open the pet plays `.review` (examining the
        // conversation). It used to play `.waving`, which now belongs to
        // hover.
        setSpriteState(.review, source: .ui)

        showingCompletion = false
        hideBubble()

        if session == nil {
            let newSession = resolvedProvider.createSession()
            // Restore persisted conversation history before starting.
            let saved = HistoryStore.load(key: historyKey())
            if !saved.isEmpty { newSession.history = saved }
            session = newSession
            wireSession(newSession, providerName: resolvedProvider.displayName)
            newSession.start()
        }

        if popoverWindow == nil { createPopoverWindow() }

        if let terminal = terminalView, let session = session, !session.history.isEmpty {
            terminal.replayHistory(session.history)
        }

        updatePopoverPosition()
        popoverWindow?.orderFrontRegardless()
        popoverWindow?.makeKey()

        if let terminal = terminalView {
            popoverWindow?.makeFirstResponder(terminal.inputField)
        }

        removeEventMonitors()

        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.closePopover(); return nil }
            return event
        }
    }

    func closePopover() {
        guard isIdleForPopover else { return }
        popoverWindow?.orderOut(nil)
        removeEventMonitors()
        isIdleForPopover = false
        setSpriteState(.idle, source: .ui)

        if showingCompletion {
            completionBubbleExpiry = CACurrentMediaTime() + 3.0
            showBubble(text: currentPhrase, isCompletion: true)
        } else if isAgentBusy {
            currentPhrase = ""
            lastPhraseUpdate = 0
            updateThinkingPhrase()
            showBubble(text: currentPhrase, isCompletion: false)
        }

        let delay = Double.random(in: 2.0...5.0)
        pauseEndTime = CACurrentMediaTime() + delay
    }

    private func removeEventMonitors() {
        if let monitor = clickOutsideMonitor { NSEvent.removeMonitor(monitor); clickOutsideMonitor = nil }
        if let monitor = escapeKeyMonitor { NSEvent.removeMonitor(monitor); escapeKeyMonitor = nil }
    }

    var resolvedTheme: PopoverTheme {
        (themeOverride ?? PopoverTheme.current).withCharacterColor(characterColor).withCustomFont()
    }

    func createPopoverWindow() {
        let t = resolvedTheme
        let savedSize = PetLibrary.popoverSize(for: petSlug)
        let popoverWidth = savedSize.width
        let popoverHeight = savedSize.height

        let win = KeyableWindow(
            contentRect: CGRect(x: 0, y: 0, width: popoverWidth, height: popoverHeight),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 10)
        win.collectionBehavior = [.canJoinAllSpaces, .stationary]
        win.minSize = PetLibrary.minPopoverSize
        win.maxSize = PetLibrary.maxPopoverSize
        let bgRGB = t.popoverBg.usingColorSpace(.deviceRGB) ?? t.popoverBg
        let brightness = bgRGB.redComponent * 0.299 + bgRGB.greenComponent * 0.587 + bgRGB.blueComponent * 0.114
        win.appearance = NSAppearance(named: brightness < 0.5 ? .darkAqua : .aqua)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: popoverWidth, height: popoverHeight))
        container.wantsLayer = true
        container.layer?.backgroundColor = t.popoverBg.cgColor
        container.layer?.cornerRadius = t.popoverCornerRadius
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = t.popoverBorderWidth
        container.layer?.borderColor = t.popoverBorder.cgColor
        container.autoresizingMask = [.width, .height]

        let titleBarHeight: CGFloat = 28
        let titleBar = NSView(frame: NSRect(x: 0, y: popoverHeight - titleBarHeight,
                                            width: popoverWidth, height: titleBarHeight))
        titleBar.wantsLayer = true
        titleBar.layer?.backgroundColor = t.titleBarBg.cgColor
        titleBar.autoresizingMask = [.width, .minYMargin]
        container.addSubview(titleBar)

        // Traffic-light style minimize chip (closes the popover, keeps the session running).
        let chip = MinimizeChip(frame: NSRect(x: 10, y: 7, width: 14, height: 14))
        chip.toolTip = "Minimize chat"
        chip.onClick = { [weak self] in self?.minimizeChatWindow() }
        titleBar.addSubview(chip)

        // Provider logo — uses asset catalog image, falls back to SF Symbol.
        let provider = resolvedProvider
        let iconSize: CGFloat = 16
        let iconY = (titleBarHeight - iconSize) / 2
        let iconView = NSImageView(frame: NSRect(x: 28, y: iconY, width: iconSize, height: iconSize))
        if let logo = NSImage(named: provider.logoImageName) {
            iconView.image = logo
            iconView.imageScaling = .scaleProportionallyUpOrDown
        } else if let symbol = NSImage(systemSymbolName: provider.symbolName,
                                       accessibilityDescription: provider.displayName) {
            iconView.image = symbol.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
            iconView.contentTintColor = provider.brandColor
        }
        titleBar.addSubview(iconView)

        let titleString = "\(petSlug.isEmpty ? "pet" : petSlug) · \(t.titleString(for: provider))"
        let titleLabel = NSTextField(labelWithString: titleString)
        titleLabel.font = t.titleFont
        titleLabel.textColor = t.titleText
        titleLabel.frame = NSRect(x: 50, y: 6, width: popoverWidth - 62, height: 16)
        titleLabel.autoresizingMask = [.width]
        titleBar.addSubview(titleLabel)

        let sep = NSView(frame: NSRect(x: 0, y: popoverHeight - titleBarHeight - 1,
                                       width: popoverWidth, height: 1))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = t.separatorColor.cgColor
        sep.autoresizingMask = [.width, .minYMargin]
        container.addSubview(sep)

        let terminal = TerminalView(frame: NSRect(x: 0, y: 0,
                                                  width: popoverWidth,
                                                  height: popoverHeight - titleBarHeight - 1))
        terminal.characterColor = characterColor
        terminal.themeOverride = themeOverride
        terminal.provider = provider
        terminal.autoresizingMask = [.width, .height]
        terminal.onSendMessage = { [weak self] message, attachments in
            self?.session?.send(message: message, attachments: attachments)
        }
        container.addSubview(terminal)

        // Visible resize grip in the bottom-right corner. Drag to resize.
        let gripSize: CGFloat = 16
        let grip = PopoverResizeGrip(frame: NSRect(x: popoverWidth - gripSize,
                                                   y: 0,
                                                   width: gripSize,
                                                   height: gripSize))
        grip.targetWindow = win
        grip.toolTip = "Drag to resize"
        grip.autoresizingMask = [.minXMargin]
        container.addSubview(grip)

        win.contentView = container
        win.delegate = popoverDelegate
        popoverWindow = win
        terminalView = terminal
    }

    /// Hide the popover but keep the session and window state alive.
    @objc func minimizeChatWindow() {
        closePopover()
    }

    private func historyKey() -> String {
        let slug = petSlug.isEmpty ? "unknown" : petSlug
        return "\(slug)-\(resolvedProvider.rawValue)"
    }

    private func wireSession(_ session: any AgentSession, providerName: String) {
        session.onText = { [weak self] text in
            self?.currentStreamingText += text
            self?.terminalView?.appendStreamingText(text)
            // Chat is open — pet is in `.review`. Streaming doesn't change
            // state. (Used to flip to `.waving`, which now belongs to hover.)
            self?.setSpriteState(.review, source: .session)
        }
        session.onTurnComplete = { [weak self] in
            self?.terminalView?.endStreaming()
            self?.playCompletionSound()
            self?.showCompletionBubble()
            // Pet plays `.jumping` and *stays* there until the user clicks
            // the completion bubble. The planner is gated on
            // `showingCompletion` so it won't sweep this back to .idle.
            self?.setSpriteState(.jumping, source: .session)
            self?.controller?.notifyTurnComplete(self)
            // Persist conversation history after every completed turn.
            if let self, let session = self.session {
                HistoryStore.save(key: self.historyKey(), messages: session.history)
            }
        }
        session.onError = { [weak self] text in
            self?.terminalView?.appendError(text)
            self?.setSpriteState(.failed, source: .session)
        }
        session.onToolUse = { [weak self] toolName, input in
            guard let self = self else { return }
            let summary = self.formatToolInput(input)
            self.terminalView?.appendToolUse(toolName: toolName, summary: summary)
            self.setSpriteState(.review, source: .session)
        }
        session.onToolResult = { [weak self] summary, isError in
            self?.terminalView?.appendToolResult(summary: summary, isError: isError)
        }
        session.onProcessExit = { [weak self] in
            self?.terminalView?.endStreaming()
            self?.terminalView?.appendError("\(providerName) session ended.")
            self?.setSpriteState(.idle, source: .session)
        }
    }

    private func formatToolInput(_ input: [String: Any]) -> String {
        if let cmd = input["command"] as? String { return cmd }
        if let path = input["file_path"] as? String { return path }
        if let pattern = input["pattern"] as? String { return pattern }
        return input.keys.sorted().prefix(3).joined(separator: ", ")
    }

    func updatePopoverPosition() {
        guard let popover = popoverWindow, isIdleForPopover else { return }
        // Use the screen the *pet* is on, not NSScreen.main. Otherwise the
        // popover gets clamped to the main display when the pet is on a
        // secondary monitor and ends up appearing on the wrong screen.
        guard let screen = window.screen ?? NSScreen.main else { return }

        let charFrame = window.frame
        let popoverSize = popover.frame.size
        var x = charFrame.midX - popoverSize.width / 2
        let y = charFrame.maxY - 15

        let screenFrame = screen.frame
        x = max(screenFrame.minX + 4, min(x, screenFrame.maxX - popoverSize.width - 4))
        let clampedY = min(y, screenFrame.maxY - popoverSize.height - 4)

        let newOrigin = NSPoint(x: x, y: clampedY)
        let cur = popover.frame.origin
        guard abs(newOrigin.x - cur.x) > 2 || abs(newOrigin.y - cur.y) > 2 else { return }
        popover.setFrameOrigin(newOrigin)
    }

    // MARK: - Thinking Bubble

    private static let thinkingPhrases = [
        "hmm...", "thinking...", "one sec...", "ok hold on",
        "let me check", "working on it", "almost...", "bear with me",
        "on it!", "gimme a sec", "brb", "processing...",
        "hang tight", "just a moment", "figuring it out",
        "crunching...", "reading...", "looking..."
    ]

    private static let completionPhrases = [
        "done!", "all set!", "ready!", "here you go", "got it!",
        "finished!", "ta-da!", "voila!"
    ]

    private var lastPhraseUpdate: CFTimeInterval = 0
    var currentPhrase = ""
    var completionBubbleExpiry: CFTimeInterval = 0
    var showingCompletion = false

    private static let bubbleH: CGFloat = 26

    func updateThinkingBubble() {
        let now = CACurrentMediaTime()

        if showingCompletion {
            // Persistent until the user clicks the bubble — no expiry.
            if isIdleForPopover {
                hideBubble()
            } else {
                showBubble(text: currentPhrase, isCompletion: true)
            }
            return
        }

        if isAgentBusy && !isIdleForPopover {
            setSpriteState(.waiting, source: .session)
            let oldPhrase = currentPhrase
            updateThinkingPhrase()
            if currentPhrase != oldPhrase {
                showBubble(text: currentPhrase, isCompletion: false)
            }
        } else if !showingCompletion {
            hideBubble()
        }
    }

    private func hideBubble() {
        if thinkingBubbleWindow?.isVisible ?? false { thinkingBubbleWindow?.orderOut(nil) }
    }

    func showBubble(text: String, isCompletion: Bool) {
        let t = resolvedTheme
        if thinkingBubbleWindow == nil { createThinkingBubble() }
        // Completion bubbles intercept clicks so the user can dismiss them.
        // Thinking bubbles stay click-through so the user can still click
        // the pet underneath.
        thinkingBubbleWindow?.ignoresMouseEvents = !isCompletion

        let h = Self.bubbleH
        let padding: CGFloat = 16
        let font = t.bubbleFont
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        let bubbleW = max(ceil(textSize.width) + padding * 2, 48)

        let charFrame = window.frame
        let x = charFrame.midX - bubbleW / 2
        let y = charFrame.origin.y + charFrame.height * 0.88
        thinkingBubbleWindow?.setFrame(CGRect(x: x, y: y, width: bubbleW, height: h), display: false)

        let borderColor = isCompletion ? t.bubbleCompletionBorder.cgColor : t.bubbleBorder.cgColor
        let textColor = isCompletion ? t.bubbleCompletionText : t.bubbleText

        if let container = thinkingBubbleWindow?.contentView {
            container.frame = NSRect(x: 0, y: 0, width: bubbleW, height: h)
            container.layer?.backgroundColor = t.bubbleBg.cgColor
            container.layer?.cornerRadius = t.bubbleCornerRadius
            container.layer?.borderColor = borderColor
            if let label = container.viewWithTag(100) as? NSTextField {
                label.font = font
                let lineH = ceil(textSize.height)
                let labelY = round((h - lineH) / 2) - 1
                label.frame = NSRect(x: 0, y: labelY, width: bubbleW, height: lineH + 2)
                label.stringValue = text
                label.textColor = textColor
            }
        }

        if !(thinkingBubbleWindow?.isVisible ?? false) {
            thinkingBubbleWindow?.alphaValue = 1.0
            thinkingBubbleWindow?.orderFrontRegardless()
        }
    }

    private func updateThinkingPhrase() {
        let now = CACurrentMediaTime()
        if currentPhrase.isEmpty || now - lastPhraseUpdate > Double.random(in: 3.0...5.0) {
            var next = Self.thinkingPhrases.randomElement() ?? "..."
            while next == currentPhrase && Self.thinkingPhrases.count > 1 {
                next = Self.thinkingPhrases.randomElement() ?? "..."
            }
            currentPhrase = next
            lastPhraseUpdate = now
        }
    }

    func showCompletionBubble() {
        currentPhrase = Self.completionPhrases.randomElement() ?? "done!"
        showingCompletion = true
        // Effectively "no expiry" — the bubble stays up until the user
        // clicks it (see `dismissCompletionBubble`). Kept positive so any
        // stray comparison still treats us as not-expired.
        completionBubbleExpiry = .greatestFiniteMagnitude
        lastPhraseUpdate = 0
        if !isIdleForPopover { showBubble(text: currentPhrase, isCompletion: true) }
    }

    /// Called when the user clicks the completion bubble. Hides the bubble
    /// and lets the planner sweep the pet back to `.idle` on its next tick.
    func dismissCompletionBubble() {
        guard showingCompletion else { return }
        showingCompletion = false
        completionBubbleExpiry = 0
        hideBubble()
        // Stamp the session-event time so the planner's quiet window now
        // applies from this moment, then it's free to sweep `.jumping` back
        // to `.idle` after `quietWindow` seconds.
        lastSessionEventTime = CACurrentMediaTime()
    }

    private func createThinkingBubble() {
        let t = resolvedTheme
        let w: CGFloat = 80
        let h = Self.bubbleH
        let win = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: w, height: h),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 5)
        // Click handling is managed per-show: ignoresMouseEvents flips to
        // false in showBubble(isCompletion: true) so the user can dismiss
        // the completion bubble; thinking bubbles stay click-through.
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .stationary]

        let container = ClickableBubbleView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        container.onClick = { [weak self] in self?.dismissCompletionBubble() }
        container.wantsLayer = true
        container.layer?.backgroundColor = t.bubbleBg.cgColor
        container.layer?.cornerRadius = t.bubbleCornerRadius
        container.layer?.borderWidth = 1
        container.layer?.borderColor = t.bubbleBorder.cgColor

        let font = t.bubbleFont
        let lineH = ceil(("Xg" as NSString).size(withAttributes: [.font: font]).height)
        let labelY = round((h - lineH) / 2) - 1

        let label = NSTextField(labelWithString: "")
        label.font = font
        label.textColor = t.bubbleText
        label.alignment = .center
        label.drawsBackground = false
        label.isBordered = false
        label.isEditable = false
        label.frame = NSRect(x: 0, y: labelY, width: w, height: lineH + 2)
        label.tag = 100
        container.addSubview(label)

        win.contentView = container
        thinkingBubbleWindow = win
    }

    // MARK: - Completion Sound

    static var soundsEnabled = true
    private static let completionSounds: [(name: String, ext: String)] = [
        ("ping-aa", "mp3"), ("ping-bb", "mp3"), ("ping-cc", "mp3"),
        ("ping-dd", "mp3"), ("ping-ee", "mp3"), ("ping-ff", "mp3"),
        ("ping-gg", "mp3"), ("ping-hh", "mp3"), ("ping-jj", "m4a")
    ]
    private static var lastSoundIndex: Int = -1

    func playCompletionSound() {
        guard Self.soundsEnabled else { return }
        var idx: Int
        repeat {
            idx = Int.random(in: 0..<Self.completionSounds.count)
        } while idx == Self.lastSoundIndex && Self.completionSounds.count > 1
        Self.lastSoundIndex = idx
        let s = Self.completionSounds[idx]
        if let url = Bundle.main.url(forResource: s.name, withExtension: s.ext, subdirectory: "Sounds"),
           let sound = NSSound(contentsOf: url, byReference: true) {
            sound.play()
        }
    }

    // MARK: - Walking

    func startWalk() {
        isPaused = false
        isWalking = true
        let now = CACurrentMediaTime()
        walkStartTime = now
        walkScaledElapsed = 0
        walkLastTickTime = now
        holdRequestStart = nil
        // Don't override session-driven states (.waving/.waiting/.review/etc)
        // or a planner-picked `.running` burst. Anything else becomes a
        // directional run sprite (`.runRight` or `.runLeft`) for this leg.
        let preserve: Set<PetState> = [.waving, .waiting, .review, .running]
        if !preserve.contains(spriteState) {
            setSpriteState(directionalRunState, source: .planner)
        }

        walkStartPos = positionProgress
        let referenceWidth: CGFloat = 500.0
        let walkPixels = CGFloat.random(in: walkAmountRange) * referenceWidth
        let walkAmount = currentTravelDistance > 0 ? walkPixels / currentTravelDistance : 0.3

        if placement == .dock {
            // Ping-pong along the dock: right → left → right. Direction is
            // determined by current position when at an edge, otherwise we
            // continue whatever direction we were last going.
            if positionProgress > 0.92 {
                goingRight = false
            } else if positionProgress < 0.08 {
                goingRight = true
            }
            // (else: keep the previous `goingRight`)

            if goingRight {
                walkEndPos = min(walkStartPos + walkAmount, 0.98)
                if walkEndPos <= walkStartPos + 0.001 {
                    // Already at right edge; bounce immediately.
                    goingRight = false
                    walkEndPos = max(walkStartPos - walkAmount, 0.02)
                }
            } else {
                walkEndPos = max(walkStartPos - walkAmount, 0.02)
                if walkEndPos >= walkStartPos - 0.001 {
                    goingRight = true
                    walkEndPos = min(walkStartPos + walkAmount, 0.98)
                }
            }

            // No sibling separation — pets walk through each other on the
            // dock without changing direction.
        } else if placement == .freeRoam {
            let curX = window.frame.midX
            let tx = roamTargetX ?? (curX + 1)
            goingRight = tx >= curX
            if goingRight { walkEndPos = min(walkStartPos + walkAmount, 1.0) }
            else { walkEndPos = max(walkStartPos - walkAmount, 0.0) }

            let minSeparation: CGFloat = 0.12
            if let siblings = controller?.characters {
                for sibling in siblings where sibling !== self {
                    let sibPos = sibling.positionProgress
                    if abs(walkEndPos - sibPos) < minSeparation {
                        if goingRight { walkEndPos = max(walkStartPos, sibPos - minSeparation) }
                        else { walkEndPos = min(walkStartPos, sibPos + minSeparation) }
                    }
                }
            }
        } else {
            if positionProgress > 0.85 { goingRight = false }
            else if positionProgress < 0.15 { goingRight = true }
            else { goingRight = Bool.random() }

            if goingRight { walkEndPos = min(walkStartPos + walkAmount, 1.0) }
            else { walkEndPos = max(walkStartPos - walkAmount, 0.0) }

            let minSeparation: CGFloat = 0.12
            if let siblings = controller?.characters {
                for sibling in siblings where sibling !== self {
                    let sibPos = sibling.positionProgress
                    if abs(walkEndPos - sibPos) < minSeparation {
                        if goingRight { walkEndPos = max(walkStartPos, sibPos - minSeparation) }
                        else { walkEndPos = min(walkStartPos, sibPos + minSeparation) }
                    }
                }
            }
        }

        walkStartPixel = walkStartPos * currentTravelDistance
        walkEndPixel = walkEndPos * currentTravelDistance
        updateFlip()
    }

    func enterPause() {
        isWalking = false
        isPaused = true

        let now = CACurrentMediaTime()
        // On the dock, when we arrive at either edge, throw in a flourish
        // before the next leg: a happy hop most of the time, occasionally a
        // longer "stretch and look around" idle, and rarely kick into a run
        // for the return trip (handled on the next startWalk via the planner).
        let atDockEdge = placement == .dock && (positionProgress >= 0.96 || positionProgress <= 0.04)

        if isWalkLikeState(spriteState) {
            // At a dock edge there's a 70% chance the pet plays its `.jumping`
            // sprite before turning around — a native-frame "bounce", no
            // synthetic squash transform.
            if atDockEdge, Double.random(in: 0...1) < 0.7 {
                setSpriteState(.jumping, source: .planner)
                pauseEndTime = now + Double.random(in: 1.0...1.6)
                return
            }
            setSpriteState(.idle, source: .planner)
        }

        // Shorter pauses on the dock so the pet keeps pacing.
        let delay = placement == .dock
            ? Double.random(in: 1.0...3.5)
            : Double.random(in: 5.0...12.0)
        pauseEndTime = now + delay
    }

    /// Pets ship separate `.runRight` / `.runLeft` rows in their petdex
    /// spritesheet, so direction-of-travel is handled by sprite-state
    /// selection — there is no transform mirror, rotation, squash, wiggle,
    /// or any other synthetic layer. The sprite layer stays at identity.
    /// This method is a no-op kept for source compatibility with existing
    /// call sites.
    func applySpriteTransform(now: CFTimeInterval = CACurrentMediaTime()) {
        // Intentionally empty.
    }

    /// When walking, ensure the sprite state matches the current direction.
    /// Replaces the old `updateFlip` (which did a CATransform3D mirror).
    func updateFlip() {
        guard isWalking, isWalkLikeState(spriteState) else { return }
        // Only swap between runRight / runLeft — leave .running alone since
        // packs only ship a single running row.
        if spriteState == .runRight, !goingRight {
            setSpriteState(.runLeft, source: .planner)
        } else if spriteState == .runLeft, goingRight {
            setSpriteState(.runRight, source: .planner)
        }
    }

    // MARK: - Hover wave (sprite-state cycle, no Y movement)

    func beginHover() {
        // Hover has no effect while the chat is open or during a throw.
        guard !isHovering, !isIdleForPopover, !isBallistic else { return }
        isHovering = true
        hoverStartTime = CACurrentMediaTime()
    }

    func endHover() {
        guard isHovering else { return }
        isHovering = false
        if spriteState == .waving { setSpriteState(.idle, source: .ui) }
    }

    /// Called from the controller's per-tick loop. Holds the pet at
    /// `.waving` while the cursor is over it and freezes its walk clock
    /// so it doesn't drift. Loops the `.waving` sprite frames at the FPS
    /// declared by the pack — no synthetic transforms.
    func tickHover(now: CFTimeInterval) {
        if isHovering, isIdleForPopover { endHover(); return }
        guard isHovering else { return }
        if spriteState != .waving { setSpriteState(.waving, source: .ui) }
        freezeWalkClock(at: now)
    }

    /// Returns 0 unconditionally. Hover no longer translates the window —
    /// hover reads through a sprite-state loop (`.jumping` ↔ `.idle`) plus
    /// the rotation wave layered onto the sprite transform.
    func hoverBounceOffset(now: CFTimeInterval) -> CGFloat { 0 }

    /// Trigger a brief squash/stretch — used for dock-edge bumps.
    func triggerEdgeBump() {
        bumpEndTime = CACurrentMediaTime() + Self.bumpDuration
    }

    var currentFlipCompensation: CGFloat { goingRight ? 0 : flipXOffset }

    func movementPosition(at videoTime: CFTimeInterval) -> CGFloat {
        let dIn = fullSpeedStart - accelStart
        let dLin = decelStart - fullSpeedStart
        let dOut = walkStop - decelStart
        let v = 1.0 / (dIn / 2.0 + dLin + dOut / 2.0)

        if videoTime <= accelStart { return 0.0 }
        else if videoTime <= fullSpeedStart {
            let t = videoTime - accelStart
            return CGFloat(v * t * t / (2.0 * dIn))
        } else if videoTime <= decelStart {
            let easeInDist = v * dIn / 2.0
            let t = videoTime - fullSpeedStart
            return CGFloat(easeInDist + v * t)
        } else if videoTime <= walkStop {
            let easeInDist = v * dIn / 2.0
            let linearDist = v * dLin
            let t = videoTime - decelStart
            return CGFloat(easeInDist + linearDist + v * (t - t * t / (2.0 * dOut)))
        } else { return 1.0 }
    }

    /// Vertical bounce applied while `spriteState == .jumping` (8-frame sin curve over ~0.8s).
    /// Returns 0 unconditionally — pets no longer move on the Y axis when
    /// entering `.jumping`. The "jump" reads through the sprite frames, not
    /// through window translation. Kept as a function so existing call
    /// sites compile without churn.
    func happyHopOffset(now: CFTimeInterval) -> CGFloat { 0 }

    // MARK: - Frame Update (dock placement; PlacementMode.dock uses this)

    func update(dockX: CGFloat, dockWidth: CGFloat, dockTopY: CGFloat) {
        let height = displayHeight
        let width = displayWidth
        currentTravelDistance = max(dockWidth - width, 0)
        if isIdleForPopover {
            let travelDistance = currentTravelDistance
            let x = dockX + travelDistance * positionProgress + currentFlipCompensation
            let y = dockTopY - height * 0.15 + yOffset
            window.setFrameOrigin(NSPoint(x: x, y: y))
            updatePopoverPosition()
            updateThinkingBubble()
            return
        }

        let now = CACurrentMediaTime()

        if isPaused {
            if now >= pauseEndTime {
                startWalk()
            } else {
                let x = dockX + currentTravelDistance * positionProgress + currentFlipCompensation
                let y = dockTopY - height * 0.15 + yOffset
                window.setFrameOrigin(NSPoint(x: x, y: y))
                return
            }
        }

        if isWalking {
            // Debounced hold gate: we only freeze motion when the agent has
            // been busy / popover open for ≥ 200 ms AND the sprite is in a
            // hold state. Single-tick churn from session callbacks no longer
            // stutters the walk.
            let wantsHold = shouldHoldForActivity && motionHoldStates.contains(spriteState)
            if wantsHold {
                if holdRequestStart == nil { holdRequestStart = now }
            } else {
                holdRequestStart = nil
            }
            let isHolding = holdRequestStart.map { now - $0 >= Self.holdDebounceWindow } ?? false

            if isHolding {
                freezeWalkClock(at: now)
                let x = dockX + currentTravelDistance * positionProgress + currentFlipCompensation
                let y = dockTopY - height * 0.15 + yOffset
                window.setFrameOrigin(NSPoint(x: x, y: y))
                updateThinkingBubble()
                return
            }

            let elapsed = advanceScaledElapsed(now: now)
            let videoTime = min(elapsed, videoDuration)
            let travelDistance = currentTravelDistance

            let walkNorm = elapsed >= videoDuration ? 1.0 : movementPosition(at: videoTime)
            let currentPixel = walkStartPixel + (walkEndPixel - walkStartPixel) * walkNorm

            if travelDistance > 0 {
                positionProgress = min(max(currentPixel / travelDistance, 0), 1)
            }

            if elapsed >= videoDuration {
                walkEndPos = positionProgress
                enterPause()
                return
            }

            let x = dockX + travelDistance * positionProgress + currentFlipCompensation
            let y = dockTopY - height * 0.15 + yOffset
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        updateThinkingBubble()
    }
}
