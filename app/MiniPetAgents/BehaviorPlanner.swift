import AppKit
import QuartzCore

/// Owns the autonomous "mood loop" for one `WalkerCharacter`.
///
/// Session callbacks (talking/think/working/happy/sad) remain authoritative —
/// the planner only acts when no session event has fired in the last quiet
/// window AND the current sprite state is one of the planner-owned states
/// (`idle`, `walk`, `run`, `sleep`).
///
/// Behavior is shaped by the per-pet preferences resolved through `PetLibrary`:
///  - `MovementMode` (sprite-driven / stationary)
///  - `WalkSpeed` (slow / normal / fast) — applied via `walkSpeedMultiplier`
///
/// The planner does not move the window itself; placement strategies do that.
final class BehaviorPlanner {
    private weak var pet: WalkerCharacter?
    private var lastDecisionTime: CFTimeInterval = 0
    private var nextSleepCheckTime: CFTimeInterval = 0
    private var nextFlourishTime: CFTimeInterval = 0
    private var idleEnteredAt: CFTimeInterval = 0
    /// CACurrentMediaTime() until which the pet should run instead of walk.
    private var runUntil: CFTimeInterval = 0
    /// CACurrentMediaTime() at which a transient `.happy` flourish ends.
    private var flourishUntil: CFTimeInterval = 0
    /// States the planner is allowed to overwrite. Anything else is session-owned.
    private static let plannerOwned: Set<PetState> = [.idle, .walk, .run, .sleep]
    /// Ignore session-event quiet window unless the pet's last event is at least this old.
    private static let quietWindow: CFTimeInterval = 1.5

    init(pet: WalkerCharacter) {
        self.pet = pet
        let now = CACurrentMediaTime()
        idleEnteredAt = now
        nextSleepCheckTime = now + Double.random(in: 30...90)
        nextFlourishTime = now + Double.random(in: 10...25)
    }

    func tick(at now: CFTimeInterval) {
        guard let pet = pet else { return }
        // While the user is hovering, the pet's sprite state is owned by
        // tickHover (cycling .happy ↔ .idle). The planner stays out so its
        // post-quiet-window cleanup doesn't fight that cycle.
        if pet.isHovering { return }
        // Apply walk-speed multiplier every tick (cheap; keeps live menu changes responsive).
        pet.walkSpeedMultiplier = PetLibrary.resolvedWalkSpeed(for: pet.petSlug).multiplier

        // After the quiet window, sweep transient session states back to .idle so
        // the pet can resume its normal mood loop. This prevents a sticky `.sad`
        // or `.happy` from freezing motion forever.
        if (pet.spriteState == .happy || pet.spriteState == .sad),
           now - pet.lastSessionEventTime > Self.quietWindow {
            pet.setSpriteState(.idle, source: .planner)
        }

        // Don't override session-driven sprite states (talking/think/working).
        guard Self.plannerOwned.contains(pet.spriteState) else {
            idleEnteredAt = now
            return
        }
        // Quiet window: hold off briefly after a session event so the user-visible mood persists.
        if now - pet.lastSessionEventTime < Self.quietWindow { return }

        let mode = PetLibrary.resolvedMovementMode(for: pet.petSlug)

        switch mode {
        case .stationary:
            // Park forever in idle; cancel any in-flight walk.
            if pet.isWalking {
                pet.isWalking = false
                pet.isPaused = true
                pet.pauseEndTime = .greatestFiniteMagnitude
            } else {
                pet.pauseEndTime = .greatestFiniteMagnitude
            }
            if pet.spriteState != .idle { pet.setSpriteState(.idle, source: .planner) }
            return

        case .spriteDriven:
            handleSpriteDriven(pet: pet, now: now)
        }
    }

    private func handleSpriteDriven(pet: WalkerCharacter, now: CFTimeInterval) {
        // Wind down a transient flourish (.happy mid-idle dance).
        if pet.spriteState == .happy, now >= flourishUntil {
            pet.setSpriteState(.idle, source: .planner)
        }
        // End a run burst — drop back to walk.
        if pet.spriteState == .run, now >= runUntil {
            pet.setSpriteState(.walk, source: .planner)
        }

        if pet.spriteState == .sleep {
            // Wake up after 20–60s.
            if now - lastDecisionTime > Double.random(in: 20...60) {
                pet.setSpriteState(.idle, source: .planner)
                idleEnteredAt = now
                lastDecisionTime = now
                pet.pauseEndTime = now + Double.random(in: 1.5...4.0)
            }
            return
        }

        if pet.spriteState == .walk || pet.spriteState == .run {
            idleEnteredAt = now      // reset idle clock while moving

            // Mid-walk: small chance to break into a run for a few seconds.
            if pet.spriteState == .walk, runUntil < now,
               now >= nextFlourishTime, Double.random(in: 0...1) < 0.20 {
                pet.setSpriteState(.run, source: .planner)
                runUntil = now + Double.random(in: 1.5...3.0)
                nextFlourishTime = now + Double.random(in: 15...35)
            }
            return                   // walking handled by enterPause/startWalk loop
        }

        // .idle from here on. Keep nudging pauseEndTime to a finite value so
        // the pet eventually wanders again (the only way to "stop wandering"
        // is to switch to MovementMode.stationary).
        if pet.pauseEndTime == .greatestFiniteMagnitude {
            pet.pauseEndTime = now + Double.random(in: 1.0...3.0)
        }

        // Periodic flourish while idle — a quick `.happy` hop, a stretch
        // (`.sad` for a brief slow shuffle), or a nap.
        if now >= nextFlourishTime {
            nextFlourishTime = now + Double.random(in: 12...30)
            let pick = Double.random(in: 0...1)
            if pick < 0.45 {
                // Quick happy hop in place.
                pet.setSpriteState(.happy, source: .planner)
                flourishUntil = now + Double.random(in: 0.8...1.2)
                lastDecisionTime = now
                return
            } else if pick < 0.65 {
                // Energetic burst — kick off the next walk early and run.
                pet.pauseEndTime = now + 0.05
                runUntil = now + Double.random(in: 1.5...2.5)
                lastDecisionTime = now
                return
            }
            // else: fall through to maybe-sleep path below.
        }

        // Occasionally fall asleep after a long idle stretch.
        if now >= nextSleepCheckTime {
            nextSleepCheckTime = now + Double.random(in: 30...90)
            let idleDuration = now - idleEnteredAt
            if idleDuration > 25, Double.random(in: 0...1) < 0.25 {
                pet.setSpriteState(.sleep, source: .planner)
                pet.isWalking = false
                pet.isPaused = true
                pet.pauseEndTime = .greatestFiniteMagnitude
                lastDecisionTime = now
            }
        }
    }
}
