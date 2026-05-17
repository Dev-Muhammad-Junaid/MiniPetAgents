import AppKit
import QuartzCore

/// Where on the screen a pet lives.
///
/// The drag-to-zone UX resolves a release point into one of these two zones:
/// dropping on the dock → `.dock`, anywhere else → `.freeRoam`.
enum PlacementMode: String, CaseIterable {
    case dock
    case freeRoam
    case leftStack
    case rightStack

    var displayName: String {
        switch self {
        case .dock:       return "Dock"
        case .freeRoam:   return "Free Roam"
        case .leftStack:  return "Left Stack"
        case .rightStack: return "Right Stack"
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
        case .dock:       return DockPlacement()
        case .freeRoam:   return FreeRoamPlacement()
        case .leftStack:  return StackPlacement(edge: .left)
        case .rightStack: return StackPlacement(edge: .right)
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
                                                  y: charFrame.origin.y))
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
                                                  y: frame.origin.y))
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
            let y = startY + (targetY - startY) * walkNorm

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

// MARK: - Stack (vertical column on left or right screen edge)

struct StackPlacement: PlacementStrategy {
    enum Edge { case left, right }
    let edge: Edge

    private let margin:  CGFloat = 8
    private let spacing: CGFloat = 10
    /// Fraction of remaining distance covered each tick (60 Hz). 0.18 ≈ 0.23 s to travel.
    private let lerpFactor: CGFloat = 0.18
    /// Below this threshold the pet is considered "arrived" and snaps exactly.
    private let snapThreshold: CGFloat = 1.0

    func update(_ pet: WalkerCharacter, context ctx: PlacementContext) {
        let screen = ctx.screen
        let size   = pet.displayHeight

        let x: CGFloat = edge == .left
            ? screen.frame.minX + margin
            : screen.frame.maxX - size - margin

        // Target Y: stack upward from the bottom of the visible frame.
        let yBase   = screen.visibleFrame.minY + margin
        let targetY = yBase + CGFloat(pet.stackIndex) * (size + spacing)

        // --- Smooth repositioning ---
        if pet.stackCurrentY < -9000 {
            // First placement after spawning or mode-switch: snap immediately.
            pet.stackCurrentY = targetY
        } else {
            let diff = targetY - pet.stackCurrentY
            if abs(diff) > snapThreshold {
                // Lerp toward target and animate the walk sprite.
                pet.stackCurrentY += diff * lerpFactor
                if !pet.isIdleForPopover {
                    // Face the direction of motion and play the run cycle.
                    let runState: PetState = diff > 0 ? .runRight : .runLeft
                    pet.setSpriteState(runState, source: .ui)
                }
            } else {
                // Close enough — snap and return to idle.
                pet.stackCurrentY = targetY
                if !pet.isIdleForPopover {
                    pet.setSpriteState(.idle, source: .ui)
                }
            }
        }

        // Keep the pet stationary in X; suppress autonomous wandering.
        pet.isWalking = false
        if !pet.isIdleForPopover {
            pet.isPaused     = true
            pet.pauseEndTime = ctx.now + 9999
        }

        pet.window.setFrameOrigin(NSPoint(x: x, y: pet.stackCurrentY))

        if pet.isIdleForPopover { pet.updatePopoverPosition() }
        pet.updateThinkingBubble()
    }
}
