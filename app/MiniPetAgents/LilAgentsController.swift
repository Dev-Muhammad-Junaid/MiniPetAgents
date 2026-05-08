import AppKit

/// Drives the per-frame tick for every spawned pet, owns the dock-geometry
/// math (kept verbatim from LilAgents), and dispatches placement work to
/// each pet's `PlacementStrategy`.
final class PetAgentsController {
    var characters: [WalkerCharacter] = []
    /// One per spawned character. Owns the autonomous mood loop.
    private var planners: [String: BehaviorPlanner] = [:]
    /// 60Hz tick driving placement updates. Timer is more reliable than
    /// CVDisplayLink across power states and external displays.
    private var tickTimer: Timer?
    /// Last computed dock geometry, exposed for `WalkerCharacter.handleDragRelease`
    /// so a drop on the dock can resume walking from the dropped x.
    var lastDockX: CGFloat = 0
    var lastDockWidth: CGFloat = 0
    var debugWindow: NSWindow?
    var pinnedScreenIndex: Int = -1
    private static let onboardingKey = "hasCompletedOnboarding"
    private var shiftFlagsLocalMonitor: Any?

    func start() {
        // Re-spawn pets that were toggled "spawned" in a previous launch.
        for pet in PetLibrary.shared.pets where pet.isSpawned {
            spawn(pet: pet)
        }

        startDisplayLink()
        setupDebugLine()

        NotificationCenter.default.addObserver(forName: PetLibrary.layoutPreferencesDidChange,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.applyLayoutPreferences()
        }

        if !UserDefaults.standard.bool(forKey: Self.onboardingKey) {
            triggerOnboarding()
        }

        NotificationCenter.default.addObserver(forName: PetLibrary.didChange,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.handleLibraryChanged()
        }

        shiftFlagsLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.refreshRepositionCursorsAfterFlagsChanged()
            return event
        }
    }

    // MARK: - Spawning

    func spawn(pet: InstalledPet) {
        if characters.contains(where: { $0.petSlug == pet.slug }) { return }
        let pack = pet.loadPack()
        let char = WalkerCharacter(petSlug: pet.slug, petPack: pack)
        char.controller = self
        char.placement = pet.placement
        char.providerOverride = pet.providerOverride
        // Spread spawn positions so multiple pets don't overlap on day one.
        char.positionProgress = CGFloat.random(in: 0.15...0.85)
        char.pauseEndTime = CACurrentMediaTime() + Double.random(in: 0.5...3.5)
        char.setup()
        characters.append(char)
        planners[char.petSlug] = BehaviorPlanner(pet: char)
    }

    func despawn(slug: String) {
        guard let idx = characters.firstIndex(where: { $0.petSlug == slug }) else { return }
        let char = characters[idx]
        char.session?.terminate()
        char.popoverWindow?.orderOut(nil)
        char.thinkingBubbleWindow?.orderOut(nil)
        char.window?.orderOut(nil)
        characters.remove(at: idx)
        planners.removeValue(forKey: slug)
        // Free the decoded sprite sheet — next spawn will reload from disk
        // (now PNG-cached after first decode).
        PetLibrary.shared.pet(slug: slug)?.releasePack()
    }

    func refreshPet(slug: String) {
        guard let pet = PetLibrary.shared.pet(slug: slug),
              let char = characters.first(where: { $0.petSlug == slug }) else { return }
        char.placement = pet.placement
        char.providerOverride = pet.providerOverride
        char.applyDisplaySizeFromLibrary()
    }

    /// Re-apply size after prefs change.
    func applyLayoutPreferences() {
        for char in characters {
            char.applyDisplaySizeFromLibrary()
        }
    }

    func openChat(slug: String) {
        guard let char = characters.first(where: { $0.petSlug == slug }) else { return }
        char.openPopover()
    }

    /// Send a single prompt to every spawned pet (broadcast).
    func broadcast(message: String) {
        for char in characters {
            if char.session == nil {
                let session = char.resolvedProvider.createSession()
                char.session = session
                char.session?.start()
                // Wire is normally done on first openPopover; do it here too.
                if let s = char.session {
                    char.terminalView?.replayHistory(s.history)
                }
            }
            char.session?.send(message: message)
        }
    }

    func notifyTurnComplete(_ char: WalkerCharacter?) {
        guard let char = char else { return }
        let strat = PlacementStrategies.strategy(for: char.placement)
        strat.onTurnComplete(char)
    }

    private func handleLibraryChanged() {
        // Sync spawned set with library: despawn pets that were removed,
        // and ensure persisted spawns survive new pet installs.
        let validSlugs = Set(PetLibrary.shared.pets.map { $0.slug })
        for char in characters where !validSlugs.contains(char.petSlug) {
            despawn(slug: char.petSlug)
        }
    }

    // MARK: - Onboarding

    private func triggerOnboarding() {
        // If no pets installed yet, prompt the gallery instead of a "hi" bubble.
        if characters.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                PetGalleryWindowController.shared.show()
            }
            return
        }
        guard let first = characters.first else { return }
        first.isOnboarding = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            first.currentPhrase = "hi!"
            first.showingCompletion = true
            first.completionBubbleExpiry = CACurrentMediaTime() + 600
            first.showBubble(text: "hi!", isCompletion: true)
            first.playCompletionSound()
        }
    }

    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.onboardingKey)
        characters.forEach { $0.isOnboarding = false }
    }

    // MARK: - Debug

    private func setupDebugLine() {
        let win = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 2),
                           styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = NSColor.red
        win.hasShadow = false
        win.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 10)
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .stationary]
        win.orderOut(nil)
        debugWindow = win
    }

    private func updateDebugLine(dockX: CGFloat, dockWidth: CGFloat, dockTopY: CGFloat) {
        guard let win = debugWindow, win.isVisible else { return }
        win.setFrame(CGRect(x: dockX, y: dockTopY, width: dockWidth, height: 2), display: true)
    }

    // MARK: - Dock Geometry (kept verbatim from LilAgents)

    private func getDockIconArea(screenWidth: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let dockDefaults = UserDefaults(suiteName: "com.apple.dock")
        let tileSize = CGFloat(dockDefaults?.double(forKey: "tilesize") ?? 48)
        let slotWidth = tileSize * 1.25

        let persistentApps = dockDefaults?.array(forKey: "persistent-apps")?.count ?? 0
        let persistentOthers = dockDefaults?.array(forKey: "persistent-others")?.count ?? 0
        let showRecents = dockDefaults?.bool(forKey: "show-recents") ?? true
        let recentApps = showRecents ? (dockDefaults?.array(forKey: "recent-apps")?.count ?? 0) : 0
        let totalIcons = persistentApps + persistentOthers + recentApps

        var dividers = 0
        if persistentApps > 0 && (persistentOthers > 0 || recentApps > 0) { dividers += 1 }
        if persistentOthers > 0 && recentApps > 0 { dividers += 1 }
        if showRecents && recentApps > 0 { dividers += 1 }

        let dividerWidth: CGFloat = 12.0
        var dockWidth = slotWidth * CGFloat(totalIcons) + CGFloat(dividers) * dividerWidth
        dockWidth *= 1.1
        let dockX = (screenWidth - dockWidth) / 2.0
        return (dockX, dockWidth)
    }

    // MARK: - Display Link / Tick

    private func startDisplayLink() {
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        tickTimer = t
    }

    var activeScreen: NSScreen? {
        if pinnedScreenIndex >= 0, pinnedScreenIndex < NSScreen.screens.count {
            return NSScreen.screens[pinnedScreenIndex]
        }
        return NSScreen.main
    }

    private func screenHasDock(_ screen: NSScreen) -> Bool {
        return screen.visibleFrame.origin.y > screen.frame.origin.y
    }

    func tick() {
        guard let screen = activeScreen else { return }

        let screenWidth = screen.frame.width
        let dockX: CGFloat
        let dockWidth: CGFloat
        let dockTopY: CGFloat

        if screenHasDock(screen) {
            (dockX, dockWidth) = getDockIconArea(screenWidth: screenWidth)
            dockTopY = screen.visibleFrame.origin.y
        } else {
            let margin: CGFloat = 40.0
            dockX = screen.frame.origin.x + margin
            dockWidth = screenWidth - margin * 2
            dockTopY = screen.frame.origin.y
        }

        updateDebugLine(dockX: dockX, dockWidth: dockWidth, dockTopY: dockTopY)
        lastDockX = dockX
        lastDockWidth = dockWidth

        let now = CACurrentMediaTime()
        let context = PlacementContext(
            screen: screen,
            dockX: dockX,
            dockWidth: dockWidth,
            dockTopY: dockTopY,
            hasDock: screenHasDock(screen),
            now: now
        )

        let activeChars = characters.filter { $0.window?.isVisible ?? false }

        // Tick the autonomous behavior planner for each pet. This sets sprite
        // state (idle/walk/sleep) and walkSpeedMultiplier per per-pet prefs;
        // placement strategies below execute the actual motion.
        for char in activeChars { planners[char.petSlug]?.tick(at: now) }

        for char in activeChars {
            // While the user is mid-drag, or in the post-drop cooldown, do not
            // overwrite the window origin from a placement strategy.
            if char.isShiftDraggingWindow || char.dragCooldownUntil > now {
                char.updateThinkingBubble()
                char.updatePopoverPosition()
                continue
            }
            // Hover takes over: freeze motion, cycle sprite state. Skip the
            // placement strategy so the pet doesn't slide while waving.
            if char.isHovering {
                char.tickHover(now: now)
                char.updateThinkingBubble()
                continue
            }
            let strat = PlacementStrategies.strategy(for: char.placement)
            strat.update(char, context: context)
        }

        // Per-tick refresh of the sprite transform (flip + hover wave + bump
        // squash). Doing this once at the end of the tick — rather than at
        // every state change — means hover/bump animations are continuous
        // and we don't need each placement strategy to remember to call it.
        for char in activeChars { char.applySpriteTransform(now: now) }

        // (Pets pass through each other on the dock — no greet-on-collision,
        //  no sibling separation.)

        let sorted = activeChars.sorted { $0.positionProgress < $1.positionProgress }
        for (i, char) in sorted.enumerated() {
            char.window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + i)
        }
    }

    /// So pet windows show open/closed hand when Shift is pressed/released without moving the mouse.
    private func refreshRepositionCursorsAfterFlagsChanged() {
        for char in characters {
            guard let win = char.window, win.isVisible else { continue }
            guard win.frame.contains(NSEvent.mouseLocation) else { continue }
            (win.contentView as? CharacterContentView)?.refreshRepositionCursor()
        }
    }

    deinit {
        tickTimer?.invalidate()
        if let shiftFlagsLocalMonitor {
            NSEvent.removeMonitor(shiftFlagsLocalMonitor)
        }
    }
}
