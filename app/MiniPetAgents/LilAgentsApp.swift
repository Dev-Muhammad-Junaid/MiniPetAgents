import SwiftUI
import AppKit
import Sparkle

@main
struct MiniPetAgentsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: PetAgentsController?
    var statusItem: NSStatusItem?
    let updaterController = SPUStandardUpdaterController(startingUpdater: true,
                                                         updaterDelegate: nil,
                                                         userDriverDelegate: nil)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        PetLibrary.clearLegacyPinnedOrigins()
        controller = PetAgentsController()
        PetGalleryWindowController.shared.controller = controller
        BroadcastComposerController.shared.controller = controller
        controller?.start()
        setupMenuBar()

        NotificationCenter.default.addObserver(forName: PetLibrary.didChange,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.rebuildMenuBar()
        }

        NotificationCenter.default.addObserver(forName: PetLibrary.layoutPreferencesDidChange,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.rebuildMenuBar()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.characters.forEach { $0.session?.terminate() }
    }

    // MARK: - Menu Bar

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(named: "MenuBarIcon") ?? NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Mini Pet Agents")
        }
        rebuildMenuBar()
    }

    func rebuildMenuBar() {
        let menu = NSMenu()

        // Per-pet section
        let pets = PetLibrary.shared.pets
        if pets.isEmpty {
            let empty = NSMenuItem(title: "No pets installed", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            let header = NSMenuItem(title: "Pets", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for (i, pet) in pets.enumerated() {
                let isSpawned = controller?.characters.contains(where: { $0.petSlug == pet.slug }) ?? false
                let petItem = NSMenuItem(title: pet.slug,
                                         action: #selector(togglePetSpawn(_:)),
                                         keyEquivalent: i < 9 ? "\(i+1)" : "")
                petItem.state = isSpawned ? .on : .off
                petItem.representedObject = pet.slug
                petItem.target = self

                // Submenu: placement, provider, edge (for edgeSlide), open chat
                let sub = NSMenu()
                let placementHeader = NSMenuItem(title: "Placement", action: nil, keyEquivalent: "")
                placementHeader.isEnabled = false
                sub.addItem(placementHeader)
                for mode in PlacementMode.allCases {
                    let mi = NSMenuItem(title: "  \(mode.displayName)",
                                        action: #selector(setPlacement(_:)),
                                        keyEquivalent: "")
                    mi.state = pet.placement == mode ? .on : .off
                    mi.representedObject = ["slug": pet.slug, "placement": mode.rawValue]
                    mi.target = self
                    sub.addItem(mi)
                }
                sub.addItem(NSMenuItem.separator())
                let providerHeader = NSMenuItem(title: "Provider", action: nil, keyEquivalent: "")
                providerHeader.isEnabled = false
                sub.addItem(providerHeader)
                let defaultProvider = NSMenuItem(title: "  Default (\(AgentProvider.current.displayName))",
                                                 action: #selector(setProvider(_:)),
                                                 keyEquivalent: "")
                defaultProvider.state = pet.providerOverride == nil ? .on : .off
                defaultProvider.representedObject = ["slug": pet.slug, "provider": ""]
                defaultProvider.target = self
                sub.addItem(defaultProvider)
                for provider in AgentProvider.allCases {
                    let mi = NSMenuItem(title: "  \(provider.displayName)",
                                        action: #selector(setProvider(_:)),
                                        keyEquivalent: "")
                    mi.state = pet.providerOverride == provider ? .on : .off
                    mi.representedObject = ["slug": pet.slug, "provider": provider.rawValue]
                    mi.target = self
                    sub.addItem(mi)
                }
                sub.addItem(NSMenuItem.separator())
                let chatItem = NSMenuItem(title: "Open Chat",
                                          action: #selector(openChat(_:)),
                                          keyEquivalent: "")
                chatItem.representedObject = pet.slug
                chatItem.target = self
                sub.addItem(chatItem)

                sub.addItem(NSMenuItem.separator())
                let sizeHeader = NSMenuItem(title: "Size on screen", action: nil, keyEquivalent: "")
                sizeHeader.isEnabled = false
                sub.addItem(sizeHeader)
                let useAppDefaultSize = NSMenuItem(title: "  Match app default",
                                                   action: #selector(setPetMenuSize(_:)),
                                                   keyEquivalent: "")
                useAppDefaultSize.state = PetLibrary.hasPerPetDisplayHeightOverride(slug: pet.slug) ? .off : .on
                useAppDefaultSize.representedObject = ["slug": pet.slug, "height": "default"]
                useAppDefaultSize.target = self
                sub.addItem(useAppDefaultSize)
                for h in PetLibrary.displayHeightPresets {
                    let mi = NSMenuItem(title: "  \(Int(h)) pt tall",
                                        action: #selector(setPetMenuSize(_:)),
                                        keyEquivalent: "")
                    if let stored = PetLibrary.storedPerPetDisplayHeight(slug: pet.slug) {
                        mi.state = abs(stored - h) < 0.5 ? .on : .off
                    } else {
                        mi.state = .off
                    }
                    mi.representedObject = ["slug": pet.slug, "height": "\(Int(h))"]
                    mi.target = self
                    sub.addItem(mi)
                }

                sub.addItem(NSMenuItem.separator())
                addAnimationAndMovementMenu(into: sub, slug: pet.slug, placement: pet.placement)

                petItem.submenu = sub
                menu.addItem(petItem)
            }
        }

        menu.addItem(NSMenuItem.separator())

        let galleryItem = NSMenuItem(title: "Pet Gallery…",
                                     action: #selector(showGallery),
                                     keyEquivalent: "g")
        galleryItem.target = self
        menu.addItem(galleryItem)

        let broadcastItem = NSMenuItem(title: "Ask all pets…",
                                       action: #selector(showBroadcast),
                                       keyEquivalent: "b")
        broadcastItem.target = self
        menu.addItem(broadcastItem)

        menu.addItem(NSMenuItem.separator())

        let soundItem = NSMenuItem(title: "Sounds", action: #selector(toggleSounds(_:)), keyEquivalent: "")
        soundItem.state = WalkerCharacter.soundsEnabled ? .on : .off
        soundItem.target = self
        menu.addItem(soundItem)

        // App-default Animation & Movement (per-pet menus inherit from these).
        let animRoot = NSMenuItem(title: "App default animation & movement", action: nil, keyEquivalent: "")
        let animMenu = NSMenu()
        addAnimationAndMovementMenu(into: animMenu, slug: nil, placement: nil)
        animRoot.submenu = animMenu
        menu.addItem(animRoot)

        let appSizeRoot = NSMenuItem(title: "App default pet size", action: nil, keyEquivalent: "")
        let appSizeMenu = NSMenu()
        let globalH = PetLibrary.resolvedGlobalDefaultDisplayHeight()
        for h in PetLibrary.displayHeightPresets {
            let mi = NSMenuItem(title: "\(Int(h)) pt",
                                action: #selector(setGlobalDefaultPetSize(_:)),
                                keyEquivalent: "")
            mi.representedObject = Double(h)
            mi.state = abs(globalH - h) < 0.5 ? .on : .off
            mi.target = self
            appSizeMenu.addItem(mi)
        }
        appSizeRoot.submenu = appSizeMenu
        menu.addItem(appSizeRoot)

        // Default provider submenu
        let providerItem = NSMenuItem(title: "Default Provider", action: nil, keyEquivalent: "")
        let providerMenu = NSMenu()
        for (i, provider) in AgentProvider.allCases.enumerated() {
            let item = NSMenuItem(title: provider.displayName,
                                  action: #selector(switchDefaultProvider(_:)),
                                  keyEquivalent: "")
            item.tag = i
            item.state = provider == AgentProvider.current ? .on : .off
            item.target = self
            providerMenu.addItem(item)
        }
        providerItem.submenu = providerMenu
        menu.addItem(providerItem)

        // Theme submenu
        let themeItem = NSMenuItem(title: "Style", action: nil, keyEquivalent: "")
        let themeMenu = NSMenu()
        for (i, theme) in PopoverTheme.allThemes.enumerated() {
            let item = NSMenuItem(title: theme.name,
                                  action: #selector(switchTheme(_:)),
                                  keyEquivalent: "")
            item.tag = i
            item.state = theme.name == PopoverTheme.current.name ? .on : .off
            item.target = self
            themeMenu.addItem(item)
        }
        themeItem.submenu = themeMenu
        menu.addItem(themeItem)

        // Display submenu
        let displayItem = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
        let displayMenu = NSMenu()
        let autoItem = NSMenuItem(title: "Auto (Main Display)",
                                  action: #selector(switchDisplay(_:)),
                                  keyEquivalent: "")
        autoItem.tag = -1
        autoItem.state = .on
        autoItem.target = self
        displayMenu.addItem(autoItem)
        displayMenu.addItem(NSMenuItem.separator())
        for (i, screen) in NSScreen.screens.enumerated() {
            let item = NSMenuItem(title: screen.localizedName,
                                  action: #selector(switchDisplay(_:)),
                                  keyEquivalent: "")
            item.tag = i
            item.state = .off
            item.target = self
            displayMenu.addItem(item)
        }
        displayItem.submenu = displayMenu
        menu.addItem(displayItem)

        menu.addItem(NSMenuItem.separator())

        let updateItem = NSMenuItem(title: "Check for Updates…",
                                    action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                                    keyEquivalent: "")
        updateItem.target = updaterController
        menu.addItem(updateItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    // MARK: - Per-pet actions

    @objc func togglePetSpawn(_ sender: NSMenuItem) {
        guard let slug = sender.representedObject as? String else { return }
        guard let pet = PetLibrary.shared.pet(slug: slug) else { return }
        if controller?.characters.contains(where: { $0.petSlug == slug }) == true {
            pet.isSpawned = false
            controller?.despawn(slug: slug)
        } else {
            pet.isSpawned = true
            controller?.spawn(pet: pet)
        }
        rebuildMenuBar()
    }

    @objc func setPlacement(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let slug = info["slug"],
              let raw = info["placement"],
              let mode = PlacementMode(rawValue: raw),
              let pet = PetLibrary.shared.pet(slug: slug) else { return }
        pet.placement = mode
        controller?.refreshPet(slug: slug)
        rebuildMenuBar()
    }

    @objc func setProvider(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let slug = info["slug"],
              let pet = PetLibrary.shared.pet(slug: slug) else { return }
        let raw = info["provider"] ?? ""
        pet.providerOverride = raw.isEmpty ? nil : AgentProvider(rawValue: raw)
        // Drop existing session so it rebuilds with the new provider on next chat.
        if let char = controller?.characters.first(where: { $0.petSlug == slug }) {
            char.providerOverride = pet.providerOverride
            char.session?.terminate()
            char.session = nil
            char.popoverWindow?.orderOut(nil)
            char.popoverWindow = nil
            char.terminalView = nil
        }
        rebuildMenuBar()
    }

    @objc func setPetMenuSize(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let slug = info["slug"],
              let raw = info["height"] else { return }
        if raw == "default" {
            PetLibrary.clearPerPetDisplayHeight(slug: slug)
        } else if let v = Double(raw) {
            PetLibrary.setDisplayHeight(CGFloat(v), for: slug)
        }
        controller?.applyLayoutPreferences()
        rebuildMenuBar()
    }

    @objc func setGlobalDefaultPetSize(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        PetLibrary.setDisplayHeight(CGFloat(v), for: nil)
        controller?.applyLayoutPreferences()
        rebuildMenuBar()
    }

    @objc func openChat(_ sender: NSMenuItem) {
        guard let slug = sender.representedObject as? String else { return }
        controller?.openChat(slug: slug)
    }

    @objc func showGallery() {
        PetGalleryWindowController.shared.show()
    }

    @objc func showBroadcast() {
        BroadcastComposerController.shared.show()
    }

    // MARK: - Global actions

    @objc func switchTheme(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard idx < PopoverTheme.allThemes.count else { return }
        PopoverTheme.current = PopoverTheme.allThemes[idx]

        if let themeMenu = sender.menu {
            for item in themeMenu.items {
                item.state = item.tag == idx ? .on : .off
            }
        }
        controller?.characters.forEach { char in
            let wasOpen = char.isIdleForPopover
            if wasOpen { char.popoverWindow?.orderOut(nil) }
            char.popoverWindow = nil
            char.terminalView = nil
            char.thinkingBubbleWindow = nil
            if wasOpen {
                char.createPopoverWindow()
                if let session = char.session, !session.history.isEmpty {
                    char.terminalView?.replayHistory(session.history)
                }
                char.updatePopoverPosition()
                char.popoverWindow?.orderFrontRegardless()
                char.popoverWindow?.makeKey()
                if let terminal = char.terminalView {
                    char.popoverWindow?.makeFirstResponder(terminal.inputField)
                }
            }
        }
    }

    @objc func switchDefaultProvider(_ sender: NSMenuItem) {
        let idx = sender.tag
        let allProviders = AgentProvider.allCases
        guard idx < allProviders.count else { return }
        AgentProvider.current = allProviders[idx]
        if let providerMenu = sender.menu {
            for item in providerMenu.items {
                item.state = item.tag == idx ? .on : .off
            }
        }
        // Clear sessions for pets with no override so they pick up the new default.
        controller?.characters.forEach { char in
            guard char.providerOverride == nil else { return }
            char.session?.terminate()
            char.session = nil
            if char.isIdleForPopover { char.closePopover() }
            char.popoverWindow?.orderOut(nil)
            char.popoverWindow = nil
            char.terminalView = nil
            char.thinkingBubbleWindow?.orderOut(nil)
            char.thinkingBubbleWindow = nil
        }
    }

    @objc func switchDisplay(_ sender: NSMenuItem) {
        let idx = sender.tag
        controller?.pinnedScreenIndex = idx
        if let displayMenu = sender.menu {
            for item in displayMenu.items {
                item.state = item.tag == idx ? .on : .off
            }
        }
    }

    @objc func toggleSounds(_ sender: NSMenuItem) {
        WalkerCharacter.soundsEnabled.toggle()
        sender.state = WalkerCharacter.soundsEnabled ? .on : .off
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Animation & movement submenu

    /// Builds the "Animation & movement" submenu. When `slug == nil`, the menu
    /// edits the app-wide defaults; otherwise it edits per-pet overrides.
    /// `placement` determines whether the Free-Roam region picker is enabled.
    private func addAnimationAndMovementMenu(into parent: NSMenu, slug: String?, placement: PlacementMode?) {
        let header = NSMenuItem(title: "Animation & movement", action: nil, keyEquivalent: "")
        header.isEnabled = false
        parent.addItem(header)

        // Movement mode
        let modeRoot = NSMenuItem(title: "  Movement", action: nil, keyEquivalent: "")
        let modeMenu = NSMenu()
        let currentMode = slug.map { PetLibrary.resolvedMovementMode(for: $0) } ?? PetLibrary.resolvedMovementMode(for: "")
        for mode in MovementMode.allCases {
            let mi = NSMenuItem(title: mode.displayName, action: #selector(setMovementMode(_:)), keyEquivalent: "")
            mi.state = mode == currentMode ? .on : .off
            mi.representedObject = ["slug": slug ?? "", "value": mode.rawValue]
            mi.target = self
            modeMenu.addItem(mi)
        }
        modeRoot.submenu = modeMenu
        parent.addItem(modeRoot)

        // Walk speed
        let speedRoot = NSMenuItem(title: "  Walk speed", action: nil, keyEquivalent: "")
        let speedMenu = NSMenu()
        let currentSpeed = slug.map { PetLibrary.resolvedWalkSpeed(for: $0) } ?? PetLibrary.resolvedWalkSpeed(for: "")
        for s in WalkSpeed.allCases {
            let mi = NSMenuItem(title: s.displayName, action: #selector(setWalkSpeed(_:)), keyEquivalent: "")
            mi.state = s == currentSpeed ? .on : .off
            mi.representedObject = ["slug": slug ?? "", "value": s.rawValue]
            mi.target = self
            speedMenu.addItem(mi)
        }
        speedRoot.submenu = speedMenu
        parent.addItem(speedRoot)

        // Idle wander toggle
        let wanderItem = NSMenuItem(title: "  Idle wander",
                                    action: #selector(toggleIdleWander(_:)),
                                    keyEquivalent: "")
        let wanderOn = slug.map { PetLibrary.resolvedIdleWander(for: $0) } ?? PetLibrary.resolvedIdleWander(for: "")
        wanderItem.state = wanderOn ? .on : .off
        wanderItem.representedObject = slug ?? ""
        wanderItem.target = self
        parent.addItem(wanderItem)

        // Pause-while-talking toggle
        let pauseItem = NSMenuItem(title: "  Pause while talking",
                                   action: #selector(togglePauseWhileTalking(_:)),
                                   keyEquivalent: "")
        let pauseOn = slug.map { PetLibrary.resolvedPauseWhileTalking(for: $0) } ?? PetLibrary.resolvedPauseWhileTalking(for: "")
        pauseItem.state = pauseOn ? .on : .off
        pauseItem.representedObject = slug ?? ""
        pauseItem.target = self
        parent.addItem(pauseItem)

        // Free-roam region picker (only meaningful in freeRoam placement)
        let regionRoot = NSMenuItem(title: "  Free-roam region", action: nil, keyEquivalent: "")
        let regionMenu = NSMenu()
        let currentRegion = slug.map { PetLibrary.resolvedRoamRegion(for: $0) } ?? PetLibrary.resolvedRoamRegion(for: "")
        for r in RoamRegion.allCases {
            let mi = NSMenuItem(title: r.displayName, action: #selector(setRoamRegion(_:)), keyEquivalent: "")
            mi.state = r == currentRegion ? .on : .off
            mi.representedObject = ["slug": slug ?? "", "value": r.rawValue]
            mi.target = self
            regionMenu.addItem(mi)
        }
        regionRoot.submenu = regionMenu
        // Disable the parent for per-pet menus when placement isn't freeRoam — still shows current value.
        if let p = placement, p != .freeRoam { regionRoot.isEnabled = false }
        parent.addItem(regionRoot)

        // "Use app default" reset (per-pet menus only)
        if slug != nil {
            let reset = NSMenuItem(title: "  Reset to app defaults",
                                   action: #selector(resetAnimationOverrides(_:)),
                                   keyEquivalent: "")
            reset.representedObject = slug
            reset.target = self
            parent.addItem(reset)
        }
    }

    private func slugFromInfo(_ sender: NSMenuItem) -> String? {
        if let info = sender.representedObject as? [String: String] {
            let s = info["slug"] ?? ""
            return s.isEmpty ? nil : s
        }
        if let s = sender.representedObject as? String, !s.isEmpty { return s }
        return nil
    }

    @objc func setMovementMode(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let raw = info["value"], let mode = MovementMode(rawValue: raw) else { return }
        let slug = (info["slug"] ?? "").isEmpty ? nil : info["slug"]
        PetLibrary.setMovementMode(mode, for: slug)
        rebuildMenuBar()
    }

    @objc func setWalkSpeed(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let raw = info["value"], let speed = WalkSpeed(rawValue: raw) else { return }
        let slug = (info["slug"] ?? "").isEmpty ? nil : info["slug"]
        PetLibrary.setWalkSpeed(speed, for: slug)
        rebuildMenuBar()
    }

    @objc func toggleIdleWander(_ sender: NSMenuItem) {
        let slug = slugFromInfo(sender)
        let current = slug.map { PetLibrary.resolvedIdleWander(for: $0) } ?? PetLibrary.resolvedIdleWander(for: "")
        PetLibrary.setIdleWander(!current, for: slug)
        rebuildMenuBar()
    }

    @objc func togglePauseWhileTalking(_ sender: NSMenuItem) {
        let slug = slugFromInfo(sender)
        let current = slug.map { PetLibrary.resolvedPauseWhileTalking(for: $0) } ?? PetLibrary.resolvedPauseWhileTalking(for: "")
        PetLibrary.setPauseWhileTalking(!current, for: slug)
        rebuildMenuBar()
    }

    @objc func setRoamRegion(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let raw = info["value"], let region = RoamRegion(rawValue: raw) else { return }
        let slug = (info["slug"] ?? "").isEmpty ? nil : info["slug"]
        PetLibrary.setRoamRegion(region, for: slug)
        rebuildMenuBar()
    }

    @objc func resetAnimationOverrides(_ sender: NSMenuItem) {
        guard let slug = sender.representedObject as? String else { return }
        PetLibrary.setMovementMode(nil, for: slug)
        PetLibrary.setWalkSpeed(nil, for: slug)
        PetLibrary.setIdleWander(nil, for: slug)
        PetLibrary.setPauseWhileTalking(nil, for: slug)
        PetLibrary.setRoamRegion(nil, for: slug)
        rebuildMenuBar()
    }
}
