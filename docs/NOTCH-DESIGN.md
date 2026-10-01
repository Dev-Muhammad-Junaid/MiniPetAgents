# Notch command centre — design language

Derived by stepping through the reference clip frame by frame (John Bai's Mac
notch concept, executed for Grok Bot by @ab_workss). This records what the
reference actually does, so decisions later are grounded rather than recalled.

## The one trick everything rests on

The panel is the **same black as the physical notch**, and it bleeds off the top
of the screen. You cannot see where hardware stops and software starts — the
shelf reads as the Mac growing, not as a window appearing. Every other choice
serves that illusion:

- Near-black ground (#000–#0A0A0A), never a grey panel, never a blur.
- No border, no drop shadow, no window chrome at the top edge.
- Bottom corners curve outward (~24–28px) so the shelf looks moulded.
- The only light in the composition is the character's own glow.

Lose the colour match and it becomes just another floating window.

## Three states

**Resting.** A wide black shelf. Left: the active agent's orb on a slightly
lighter well, with a soft blue bloom and a small circular status badge at its
top-left. Right: the roster as a condensed 2×2 cluster of tiny coloured faces.
Between them, empty black. That is the entire UI at rest.

**Expanded.** The shelf becomes a panel that *replaces the menu bar* — its own
chrome row with pill icon buttons on the left and system glyphs (cloud, globe,
battery, "100%") on the right. Below, two cards:

- *Active agent* — a large orb with its glow, and beside it a vertical task
  list. Past and future steps are muted grey with line icons; **the current
  step is white, semibold and larger**, with a terminal glyph in a rounded
  square. One bright thing at a time; everything else recedes.
- *Roster* — a 2×2 grid of capsule chips. Each chip: a saturated circular face,
  a label in the same hue, a 1px border of that hue at low alpha, and a fill
  that is a very dark tint of the hue rather than grey. Labels truncate.

**Notification / progress.** One wide card with the status colour rising from
the bottom edge as a **soft ambient bloom**, not a solid fill. A quiet title and
a right-aligned percentage, and a thin progress track whose **thumb is the
agent's own face**. The roster restacks into a narrow vertical column. Green
bloom for working, red for failure.

## What translates directly to this app

| Reference | Ours |
|---|---|
| Agent orb | the pet's actual sprite, already animated per state |
| Task list, current step bright | the turn's tool-use steps |
| Roster chips, one hue each | spawned pets, hue by provider or status |
| Ambient bloom | our existing `waiting` / `jumping` / `failed` states |
| Face as progress thumb | the pet literally walking the bar |

The mapping is unusually clean because the app already models agent activity as
character state. The notch is a second renderer for data we have.

## Rules worth writing down

1. Colour identifies an agent or a status. Chrome stays monochrome.
2. Exactly one element is bright at a time.
3. Status is never colour alone — an icon and a word travel with it.
4. Capsules and ~24px rounded rectangles. Nothing sharp.
5. The character is the only light source.

## Motion

Springs, not durations — see Apple's *Designing Fluid Interfaces* (WWDC18).
Animate from the current on-screen value, inherit velocity, stay interruptible.

- Shelf stretch: spring, slight overshoot opening, none closing.
- Roster: staggered ~40ms, so the line-up assembles.
- Status bloom: cross-fade the colour, never slide the panel.
- Hover intent: ~120ms before expanding, or it flickers as the pointer crosses.

## Constraint to design around from day one

Notch geometry only exists on notched Macs. On every other display the panel
docks to the top edge instead. Design it notch-*aware*, not notch-*dependent*,
or the feature is invisible to a large share of users — and the black-match
trick has no hardware to match, so that variant needs its own treatment.
