import AppKit
import QuartzCore

/// Where on the screen a pet lives.
///
/// The drag-to-zone UX resolves a release point into one of these two zones:
/// dropping on the dock → `.dock`, anywhere else → `.freeRoam`.
enum PlacementMode: String, CaseIterable {
    case dock
    case freeRoam

    var displayName: String {
        switch self {
        case .dock:     return "Dock"
        case .freeRoam: return "Free Roam"
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
    /// Called when the AI session emits a turn-complete event. No-op for
    /// dock and free-roam (they're always visible).
    func onTurnComplete(_ pet: WalkerCharacter)
}

extension PlacementStrategy {
    func onTurnComplete(_ pet: WalkerCharacter) {}
}

enum PlacementStrategies {
    static func strategy(for mode: PlacementMode) -> PlacementStrategy {
        switch mode {
        case .dock:     return DockPlacement()
        case .freeRoam: return FreeRoamPlacement()
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
        let bounds = ctx.screen.visibleFrame.insetBy(dx: 20, dy: 20)
        pet.currentTravelDistance = max(bounds.width - pet.displayWidth, 0)

        if pet.isIdleForPopover {
            pet.updatePopoverPosition()
            pet.updateThinkingBubble()
            return
        }

        if pet.isPaused {
            if ctx.now >= pet.pauseEndTime {
                pet.roamTargetX = bounds.minX + CGFloat.random(in: 0...bounds.width)
                pet.roamTargetY = bounds.minY + CGFloat.random(in: 0...bounds.height)
                pet.startWalk()
                pet.roamY = pet.roamTargetY ?? bounds.midY
            } else {
                let charFrame = pet.window.frame
                pet.window.setFrameOrigin(NSPoint(x: charFrame.origin.x,
                                                  y: charFrame.origin.y + pet.happyHopOffset(now: ctx.now) + pet.hoverBounceOffset(now: ctx.now)))
                return
            }
        }

        if pet.isWalking {
            // Free-roam shares the dock walk's scaled-elapsed integrator so
            // velocity stays continuous when `walkSpeedMultiplier` flips.
            let wantsHold = pet.shouldHoldForActivity
                && pet.motionHoldStates.contains(pet.spriteState)
            if wantsHold {
                let frame = pet.window.frame
                pet.window.setFrameOrigin(NSPoint(x: frame.origin.x,
                                                  y: frame.origin.y + pet.happyHopOffset(now: ctx.now) + pet.hoverBounceOffset(now: ctx.now)))
                pet.updateThinkingBubble()
                return
            }
            let elapsed = pet.advanceScaledElapsed(now: ctx.now)
            let videoTime = min(elapsed, pet.videoDuration)
            let walkNorm = elapsed >= pet.videoDuration ? 1.0 : pet.movementPosition(at: videoTime)

            let startX = pet.window.frame.origin.x
            let targetX = pet.roamTargetX ?? startX
            let startY = pet.window.frame.origin.y
            let targetY = pet.roamTargetY ?? startY

            let x = startX + (targetX - startX) * walkNorm
            let y = startY + (targetY - startY) * walkNorm + pet.happyHopOffset(now: ctx.now) + pet.hoverBounceOffset(now: ctx.now)

            pet.goingRight = targetX >= startX
            pet.updateFlip()

            if elapsed >= pet.videoDuration {
                pet.enterPause()
                return
            }
            pet.window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        pet.updateThinkingBubble()
    }
}
