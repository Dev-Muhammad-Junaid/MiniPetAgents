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
    /// CACurrentMediaTime() at which the current `.happy` hop should end (0 = no hop).
    var hopEndTime: CFTimeInterval = 0
    /// Where the hop started, in window-frame coordinates. Used to interpolate the sin-curve y offset.
    var hopBaseY: CGFloat = 0

    enum SpriteStateSource {
        case session   // wired session callbacks (text/turnComplete/error/toolUse)
        case planner   // BehaviorPlanner
        case ui        // popover open/close, drag, onboarding
    }

    /// Mutate `spriteState`. Records the last session-event time so the planner backs off.
    func setSpriteState(_ state: PetState, source: SpriteStateSource) {
        if source == .session { lastSessionEventTime = CACurrentMediaTime() }
        if state == .happy {
            hopEndTime = CACurrentMediaTime() + 0.8
            hopBaseY = window?.frame.origin.y ?? 0
        }
        spriteState = state
    }

    /// States during which the pet should hold position (sprite still animates).
    /// `pauseWhileTalking == false` removes `.talking` from this set.
    /// Caller is expected to only consult this when `isAgentBusy || isIdleForPopover`
    /// is true — otherwise a sticky session-driven state (e.g. `.sad`) would
    /// freeze the pet forever.
    func motionHoldStates(pauseWhileTalking: Bool) -> Set<PetState> {
        var s: Set<PetState> = [.sleep, .think, .working]
        if pauseWhileTalking { s.insert(.talking) }
        return s
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

    // MARK: - Setup

    func setup() {
        spriteLayer = CALayer()
        spriteLayer.contentsGravity = .resizeAspect
        spriteLayer.backgroundColor = NSColor.clear.cgColor
        spriteLayer.frame = CGRect(x: 0, y: 0, width: displayWidth, height: displayHeight)
        spriteLayer.magnificationFilter = .nearest // crisp pixel art

        if let pack = petPack {
            animator = SpriteAnimator(pack: pack, layer: spriteLayer)
            animator?.play(state: .idle)
        } else if let placeholder = NSImage(named: "PlaceholderPet") {
            spriteLayer.contents = placeholder
        }

        let screen = NSScreen.main!
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
        if spriteState != .talking, spriteState != .think {
            setSpriteState(.idle, source: .ui)
        }
        updatePopoverPosition()
        updateThinkingBubble()
    }

    /// Keeps walk sprite frames aligned with movement along the dock (0…1).
    /// Only fires when the sprite is actually in `.walk` or `.run` — otherwise
    /// the frame index would override whatever animation a session callback
    /// (e.g. `.talking`) is currently playing.
    func syncWalkSpriteFrames(normalized: CGFloat) {
        guard isWalking, spriteState == .walk || spriteState == .run else { return }
        animator?.syncWalkProgress(normalized)
    }

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
        if let siblings = controller?.characters {
            for sibling in siblings where sibling !== self && sibling.isIdleForPopover {
                sibling.closePopover()
            }
        }

        isIdleForPopover = true
        isWalking = false
        isPaused = true
        setSpriteState(.talking, source: .ui)

        showingCompletion = false
        hideBubble()

        if session == nil {
            let newSession = resolvedProvider.createSession()
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

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, let popover = self.popoverWindow else { return }
            let popoverFrame = popover.frame
            let charFrame = self.window.frame
            if !popoverFrame.contains(NSEvent.mouseLocation) && !charFrame.contains(NSEvent.mouseLocation) {
                self.closePopover()
            }
        }

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

        let titleString = "\(petSlug.isEmpty ? "pet" : petSlug) · \(t.titleString)"
        let titleLabel = NSTextField(labelWithString: titleString)
        titleLabel.font = t.titleFont
        titleLabel.textColor = t.titleText
        titleLabel.frame = NSRect(x: 32, y: 6, width: popoverWidth - 44, height: 16)
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
        terminal.autoresizingMask = [.width, .height]
        terminal.onSendMessage = { [weak self] message in
            self?.session?.send(message: message)
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

    private func wireSession(_ session: any AgentSession, providerName: String) {
        session.onText = { [weak self] text in
            self?.currentStreamingText += text
            self?.terminalView?.appendStreamingText(text)
            self?.setSpriteState(.talking, source: .session)
        }
        session.onTurnComplete = { [weak self] in
            self?.terminalView?.endStreaming()
            self?.playCompletionSound()
            self?.showCompletionBubble()
            self?.setSpriteState(.happy, source: .session)
            // Notify placement strategies (e.g. notch/edgeSlide) so they can
            // briefly reveal the pet on completion.
            self?.controller?.notifyTurnComplete(self)
        }
        session.onError = { [weak self] text in
            self?.terminalView?.appendError(text)
            self?.setSpriteState(.sad, source: .session)
        }
        session.onToolUse = { [weak self] toolName, input in
            guard let self = self else { return }
            let summary = self.formatToolInput(input)
            self.terminalView?.appendToolUse(toolName: toolName, summary: summary)
            self.setSpriteState(.working, source: .session)
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
        guard let screen = NSScreen.main else { return }

        let charFrame = window.frame
        let popoverSize = popover.frame.size
        var x = charFrame.midX - popoverSize.width / 2
        let y = charFrame.maxY - 15

        let screenFrame = screen.frame
        x = max(screenFrame.minX + 4, min(x, screenFrame.maxX - popoverSize.width - 4))
        let clampedY = min(y, screenFrame.maxY - popoverSize.height - 4)

        popover.setFrameOrigin(NSPoint(x: x, y: clampedY))
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
            if now >= completionBubbleExpiry {
                showingCompletion = false
                hideBubble()
                return
            }
            if isIdleForPopover {
                completionBubbleExpiry += 1.0 / 60.0
                hideBubble()
            } else {
                showBubble(text: currentPhrase, isCompletion: true)
            }
            return
        }

        if isAgentBusy && !isIdleForPopover {
            setSpriteState(.think, source: .session)
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
        completionBubbleExpiry = CACurrentMediaTime() + 3.0
        lastPhraseUpdate = 0
        if !isIdleForPopover { showBubble(text: currentPhrase, isCompletion: true) }
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
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .stationary]

        let container = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
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
        walkStartTime = CACurrentMediaTime()
        // Don't override session-driven states (.talking/.think/.working/etc) or
        // a planner-picked `.run` burst. Anything else (idle, happy, sad, sleep)
        // becomes `.walk` for this leg.
        let preserve: Set<PetState> = [.talking, .think, .working, .run]
        if !preserve.contains(spriteState) {
            setSpriteState(.walk, source: .planner)
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

            let minSeparation: CGFloat = 0.12
            if let siblings = controller?.characters {
                for sibling in siblings where sibling !== self {
                    let sibPos = sibling.positionProgress
                    if abs(walkEndPos - sibPos) < minSeparation {
                        if goingRight {
                            walkEndPos = max(walkStartPos, sibPos - minSeparation)
                        } else {
                            walkEndPos = min(walkStartPos, sibPos + minSeparation)
                        }
                    }
                }
            }
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

        if spriteState == .walk || spriteState == .run {
            if atDockEdge, Double.random(in: 0...1) < 0.7 {
                // Happy hop at the bounce point.
                setSpriteState(.happy, source: .planner)
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

    func updateFlip() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if goingRight {
            spriteLayer.transform = CATransform3DIdentity
        } else {
            spriteLayer.transform = CATransform3DMakeScale(-1, 1, 1)
        }
        spriteLayer.frame = CGRect(x: 0, y: 0, width: displayWidth, height: displayHeight)
        CATransaction.commit()
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

    /// Vertical bounce applied while `spriteState == .happy` (8-frame sin curve over ~0.8s).
    func happyHopOffset(now: CFTimeInterval) -> CGFloat {
        guard spriteState == .happy, hopEndTime > now else { return 0 }
        let total: CFTimeInterval = 0.8
        let remaining = hopEndTime - now
        let t = max(0, min(1, 1 - remaining / total))   // 0…1 over the hop
        let amp: CGFloat = displayHeight * 0.08
        return amp * CGFloat(sin(t * .pi))
    }

    // MARK: - Frame Update (dock placement; PlacementMode.dock uses this)

    func update(dockX: CGFloat, dockWidth: CGFloat, dockTopY: CGFloat) {
        currentTravelDistance = max(dockWidth - displayWidth, 0)
        if isIdleForPopover {
            let travelDistance = currentTravelDistance
            let x = dockX + travelDistance * positionProgress + currentFlipCompensation
            let bottomPadding = displayHeight * 0.15
            let y = dockTopY - bottomPadding + yOffset
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
                let travelDistance = max(dockWidth - displayWidth, 0)
                let x = dockX + travelDistance * positionProgress + currentFlipCompensation
                let bottomPadding = displayHeight * 0.15
                let y = dockTopY - bottomPadding + yOffset
                window.setFrameOrigin(NSPoint(x: x, y: y))
                return
            }
        }

        if isWalking {
            // Hold motion only when there's a real reason to (agent busy / popover open)
            // AND the sprite state asks for a hold. Otherwise stale `.sad`/`.think` after
            // a long-finished session would freeze the pet permanently.
            let pauseWhileTalking = PetLibrary.resolvedPauseWhileTalking(for: petSlug)
            if shouldHoldForActivity, motionHoldStates(pauseWhileTalking: pauseWhileTalking).contains(spriteState) {
                walkStartTime += 1.0 / 60.0
                let travelDistance = currentTravelDistance
                let x = dockX + travelDistance * positionProgress + currentFlipCompensation
                let bottomPadding = displayHeight * 0.15
                let y = dockTopY - bottomPadding + yOffset + happyHopOffset(now: now)
                window.setFrameOrigin(NSPoint(x: x, y: y))
                updateThinkingBubble()
                return
            }

            let mult = max(0.1, walkSpeedMultiplier * (spriteState == .run ? 2.0 : 1.0))
            let elapsed = (now - walkStartTime) * mult
            let videoTime = min(elapsed, videoDuration)
            let travelDistance = currentTravelDistance

            let walkNorm = elapsed >= videoDuration ? 1.0 : movementPosition(at: videoTime)
            let currentPixel = walkStartPixel + (walkEndPixel - walkStartPixel) * walkNorm

            if travelDistance > 0 {
                positionProgress = min(max(currentPixel / travelDistance, 0), 1)
            }

            syncWalkSpriteFrames(normalized: walkNorm)

            if elapsed >= videoDuration {
                walkEndPos = positionProgress
                enterPause()
                return
            }

            let x = dockX + travelDistance * positionProgress + currentFlipCompensation
            let bottomPadding = displayHeight * 0.15
            let y = dockTopY - bottomPadding + yOffset + happyHopOffset(now: now)
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        updateThinkingBubble()
    }
}
