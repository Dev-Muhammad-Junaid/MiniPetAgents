import AppKit
import QuartzCore

/// Where on the screen a pet lives. Each mode has its own positioning logic
/// implemented by a `PlacementStrategy`.
enum PlacementMode: String, CaseIterable {
    case dock
    case freeRoam
    case notch
    case edgeSlide

    var displayName: String {
        switch self {
        case .dock:      return "Dock"
        case .freeRoam:  return "Free Roam"
        case .notch:     return "Notch"
        case .edgeSlide: return "Edge Slide"
        }
    }
}

/// Geometry context fed into every per-tick placement update. Computed once
/// per controller tick so all pets share consistent screen state.
struct PlacementContext {
    let screen: NSScreen
    let dockX: CGFloat
    let dockWidth: CGFloat
    let dockTopY: CGFloat
    let hasDock: Bool
    let now: CFTimeInterval
}

/// Each placement mode implements a strategy. The strategy is stateless —
/// the per-pet state (walk progress, roam target) lives on `WalkerCharacter`.
protocol PlacementStrategy {
    func update(_ pet: WalkerCharacter, context: PlacementContext)
    /// Called when the AI session emits a turn-complete event. Used by
    /// notch/edgeSlide modes to briefly reveal the pet.
    func onTurnComplete(_ pet: WalkerCharacter)
}

extension PlacementStrategy {
    func onTurnComplete(_ pet: WalkerCharacter) {}
}

// MARK: - Resolver

enum PlacementStrategies {
    static func strategy(for mode: PlacementMode) -> PlacementStrategy {
        switch mode {
        case .dock:      return DockPlacement()
        case .freeRoam:  return FreeRoamPlacement()
        case .notch:     return NotchPlacement()
        case .edgeSlide: return EdgeSlidePlacement()
        }
    }
}

// MARK: - Dock (default — original LilAgents behavior)

struct DockPlacement: PlacementStrategy {
    func update(_ pet: WalkerCharacter, context ctx: PlacementContext) {
        pet.update(dockX: ctx.dockX, dockWidth: ctx.dockWidth, dockTopY: ctx.dockTopY)
    }
}

// MARK: - Free Roam

struct FreeRoamPlacement: PlacementStrategy {
    func update(_ pet: WalkerCharacter, context ctx: PlacementContext) {
        let region = PetLibrary.resolvedRoamRegion(for: pet.petSlug)
        let bounds = region.bounds(within: ctx.screen.visibleFrame).insetBy(dx: 20, dy: 20)
        pet.currentTravelDistance = max(bounds.width - pet.displayWidth, 0)

        if pet.isIdleForPopover {
            // Hold position; popover follow logic remains valid.
            pet.updatePopoverPosition()
            pet.updateThinkingBubble()
            return
        }

        // Hold position only while there's a real activity reason (agent busy / popover open).
        let pauseTalk = PetLibrary.resolvedPauseWhileTalking(for: pet.petSlug)
        if pet.isWalking, pet.shouldHoldForActivity,
           pet.motionHoldStates(pauseWhileTalking: pauseTalk).contains(pet.spriteState) {
            // Advance walkStartTime so elapsed stays put; pet appears to wait in place.
            pet.walkStartTime += 1.0 / 60.0
            let frame = pet.window.frame
            pet.window.setFrameOrigin(NSPoint(x: frame.origin.x, y: frame.origin.y + pet.happyHopOffset(now: ctx.now)))
            pet.updateThinkingBubble()
            return
        }

        if pet.isPaused {
            if ctx.now >= pet.pauseEndTime {
                // Pick a new roam target before starting a fresh walk.
                pet.roamTargetX = bounds.minX + CGFloat.random(in: 0...bounds.width)
                pet.roamTargetY = bounds.minY + CGFloat.random(in: 0...bounds.height)
                pet.startWalk()
                pet.roamY = pet.roamTargetY ?? bounds.midY
            } else {
                let charFrame = pet.window.frame
                pet.window.setFrameOrigin(NSPoint(x: charFrame.origin.x,
                                                  y: charFrame.origin.y + pet.happyHopOffset(now: ctx.now)))
                return
            }
        }

        if pet.isWalking {
            let mult = max(0.1, pet.walkSpeedMultiplier * (pet.spriteState == .run ? 2.0 : 1.0))
            let elapsed = (ctx.now - pet.walkStartTime) * mult
            let videoTime = min(elapsed, pet.videoDuration)
            let walkNorm = elapsed >= pet.videoDuration ? 1.0 : pet.movementPosition(at: videoTime)

            let startX = pet.window.frame.origin.x
            let targetX = pet.roamTargetX ?? startX
            let startY = pet.window.frame.origin.y
            let targetY = pet.roamTargetY ?? startY

            let x = startX + (targetX - startX) * walkNorm
            let y = startY + (targetY - startY) * walkNorm + pet.happyHopOffset(now: ctx.now)

            // Keep flip in sync with horizontal direction.
            pet.goingRight = targetX >= startX
            pet.updateFlip()
            pet.syncWalkSpriteFrames(normalized: walkNorm)

            if elapsed >= pet.videoDuration {
                pet.enterPause()
                return
            }
            pet.window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        pet.updateThinkingBubble()
    }
}

// MARK: - Notch

struct NotchPlacement: PlacementStrategy {
    func update(_ pet: WalkerCharacter, context ctx: PlacementContext) {
        let screen = ctx.screen
        let frame = screen.frame
        // The menubar inset gives us the height to tuck under.
        let topInset: CGFloat = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : 24
        let notchY = frame.maxY - topInset

        // Park the pet just above the menubar, centered under the notch when
        // present, otherwise centered on the screen top.
        let revealOffset: CGFloat = pet.isIdleForPopover ? pet.displayHeight * 0.7 : pet.displayHeight * 0.15
        let x = frame.midX - pet.displayWidth / 2
        let y = notchY - pet.displayHeight + revealOffset

        pet.window.setFrameOrigin(NSPoint(x: x, y: y))
        pet.updatePopoverPosition()
        pet.updateThinkingBubble()
    }

    func onTurnComplete(_ pet: WalkerCharacter) {
        // Slide down by ~half the pet height for ~1.5s, then back up.
        guard let screen = NSScreen.main else { return }
        let frame = screen.frame
        let topInset: CGFloat = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : 24
        let baseY = frame.maxY - topInset - pet.displayHeight + (pet.displayHeight * 0.15)
        let revealY = frame.maxY - topInset - pet.displayHeight + (pet.displayHeight * 0.85)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            pet.window.animator().setFrameOrigin(NSPoint(x: pet.window.frame.origin.x, y: revealY))
        }, completionHandler: {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.3
                    pet.window.animator().setFrameOrigin(NSPoint(x: pet.window.frame.origin.x, y: baseY))
                })
            }
        })
    }
}

// MARK: - Edge Slide

struct EdgeSlidePlacement: PlacementStrategy {
    /// Per-pet edge persisted via UserDefaults.
    private static func edgeKey(_ slug: String) -> String { "pet.\(slug).edge" }
    static func edge(for slug: String) -> Edge {
        let raw = UserDefaults.standard.string(forKey: edgeKey(slug)) ?? Edge.right.rawValue
        return Edge(rawValue: raw) ?? .right
    }
    static func setEdge(_ edge: Edge, for slug: String) {
        UserDefaults.standard.set(edge.rawValue, forKey: edgeKey(slug))
    }

    enum Edge: String, CaseIterable {
        case left, right, top, bottom
    }

    func update(_ pet: WalkerCharacter, context ctx: PlacementContext) {
        // When the popover is open we hold a "revealed" position; otherwise
        // park the pet just off-screen on its chosen edge.
        let edge = Self.edge(for: pet.petSlug)
        let frame = ctx.screen.frame

        let parkedX: CGFloat
        let parkedY: CGFloat
        let revealedX: CGFloat
        let revealedY: CGFloat

        switch edge {
        case .left:
            parkedX   = frame.minX - pet.displayWidth * 0.85
            revealedX = frame.minX - pet.displayWidth * 0.05
            parkedY   = frame.midY - pet.displayHeight / 2
            revealedY = parkedY
        case .right:
            parkedX   = frame.maxX - pet.displayWidth * 0.15
            revealedX = frame.maxX - pet.displayWidth * 0.95
            parkedY   = frame.midY - pet.displayHeight / 2
            revealedY = parkedY
        case .top:
            parkedX   = frame.midX - pet.displayWidth / 2
            revealedX = parkedX
            parkedY   = frame.maxY - pet.displayHeight * 0.15
            revealedY = frame.maxY - pet.displayHeight * 0.95
        case .bottom:
            parkedX   = frame.midX - pet.displayWidth / 2
            revealedX = parkedX
            parkedY   = frame.minY - pet.displayHeight * 0.85
            revealedY = frame.minY - pet.displayHeight * 0.05
        }

        let revealed = pet.isIdleForPopover || pet.isAgentBusy
        let x = revealed ? revealedX : parkedX
        let y = revealed ? revealedY : parkedY
        pet.window.setFrameOrigin(NSPoint(x: x, y: y))
        pet.updatePopoverPosition()
        pet.updateThinkingBubble()
    }

    func onTurnComplete(_ pet: WalkerCharacter) {
        // Slide in for ~2s as a "look at me" reveal even when no popover.
        let edge = Self.edge(for: pet.petSlug)
        guard let screen = NSScreen.main else { return }
        let frame = screen.frame

        let revealedOrigin: NSPoint
        let parkedOrigin: NSPoint
        switch edge {
        case .left:
            revealedOrigin = NSPoint(x: frame.minX - pet.displayWidth * 0.05,
                                     y: frame.midY - pet.displayHeight / 2)
            parkedOrigin   = NSPoint(x: frame.minX - pet.displayWidth * 0.85,
                                     y: frame.midY - pet.displayHeight / 2)
        case .right:
            revealedOrigin = NSPoint(x: frame.maxX - pet.displayWidth * 0.95,
                                     y: frame.midY - pet.displayHeight / 2)
            parkedOrigin   = NSPoint(x: frame.maxX - pet.displayWidth * 0.15,
                                     y: frame.midY - pet.displayHeight / 2)
        case .top:
            revealedOrigin = NSPoint(x: frame.midX - pet.displayWidth / 2,
                                     y: frame.maxY - pet.displayHeight * 0.95)
            parkedOrigin   = NSPoint(x: frame.midX - pet.displayWidth / 2,
                                     y: frame.maxY - pet.displayHeight * 0.15)
        case .bottom:
            revealedOrigin = NSPoint(x: frame.midX - pet.displayWidth / 2,
                                     y: frame.minY - pet.displayHeight * 0.05)
            parkedOrigin   = NSPoint(x: frame.midX - pet.displayWidth / 2,
                                     y: frame.minY - pet.displayHeight * 0.85)
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.4
            pet.window.animator().setFrameOrigin(revealedOrigin)
        }, completionHandler: {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.5
                    pet.window.animator().setFrameOrigin(parkedOrigin)
                })
            }
        })
    }
}
