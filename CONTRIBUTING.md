# Contributing

Thanks for taking a look. This is a small AppKit app — no build system beyond
Xcode, no test suite, no CI yet.

## Getting set up

```bash
git clone https://github.com/Dev-Muhammad-Junaid/MiniPetAgents.git
cd MiniPetAgents
open app/MiniPetAgents.xcodeproj
```

No development team is committed, so it builds signed-to-run-locally. Don't
commit your team ID back — if Xcode adds `DEVELOPMENT_TEAM` to
`project.pbxproj`, drop that line before pushing.

You'll want at least one pet installed (**Pet Gallery…** in the menubar) and at
least one AI CLI on your `PATH` to exercise anything meaningful.

## Verifying a change

There are no tests, so changes get checked by running the app:

```bash
cd app && xcodebuild -scheme MiniPetAgents -configuration Debug build
```

If you touched anything under `*Session.swift`, also run the provider contract
check — it validates the arguments the app passes against each installed CLI's
actual help output:

```bash
./scripts/check-agents.py           # free
./scripts/check-agents.py --live    # one real prompt per provider
```

It reads the flags straight out of the Swift source, so adding a flag without
updating the test's expectations fails the drift guard rather than silently
going uncovered.

Then run the app and drive the specific thing you touched. Movement and
animation work is easy to get subtly wrong in ways a build can't catch — a pet that
freezes for a beat between walk legs, or blinks out at the end of an animation
cycle, still compiles perfectly. Watch the actual pet for a minute.

## Things worth knowing

**Sprite frames are authoritative.** The app only plays frames the pack's
artist drew. No synthetic rotation, squash, or vertical bounce — direction of
travel swaps between the `run-right` and `run-left` rows rather than mirroring
a transform. If a behaviour seems to need a new visual, it probably needs a
different existing sprite row instead.

**Frame counts per row are not uniform.** They are 6/8/8/4/5/8/6/6/6, and the
trailing cells of shorter rows are blank. Iterating a full 8 columns makes pets
vanish mid-animation.

**Planner and placement are separate.** `BehaviorPlanner` decides what state a
pet should be in; the `PlacementStrategy` decides where on screen that plays
out. Keep motion decisions out of the strategies and screen geometry out of the
planner.

**Implicit CALayer animation is the enemy.** Sprite layers set
`actions = NSNull()` for animatable keys. Without that, every frame change
cross-fades over 0.25s and the pet looks like it's underwater.

**Tuning values are constants, not magic numbers buried in expressions.** Throw
physics, walk timing, and hold windows all live as named `static let`s near the
top of their type. Put new ones there too.

## Pull requests

- One concern per PR.
- Say what you did and how you checked it — "spawned two pets, threw one at the
  left edge, confirmed it bounced and resumed wandering" is exactly right.
- Match surrounding style. Comments explain constraints, not narration.
- Screen recordings help enormously for anything visual;
  `./scripts/make-demo-gif.sh` turns a `.mov` into an attachable GIF.

## Reporting bugs

Include your macOS version, which CLI provider the pet was set to, and the pet
slug. For visual bugs a short recording is worth more than any description.
