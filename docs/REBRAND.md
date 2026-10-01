# Rebrand brief

Working document. Covers naming, the notch command centre, identity, motion,
and how the launch gets measured.

---

## 1. What this product actually is

Today it reads as "cute desktop pets that can also chat". That undersells it and
it's the reason the name feels small. What it really is:

> **A persistent, visible roster of AI coding agents that live on your desktop
> instead of inside a terminal tab.**

Each pet is a running CLI session with its own working directory, model and
conversation. You can see at a glance which ones are thinking, which finished,
which failed — because the character's animation *is* the status indicator. That
is the actual product insight, and nothing else on the market does it.

The pet is the interface, not the gimmick.

## 2. Naming

Reference points you cited — OpenAI's **Dots**, Cursor's **Grok Bots**, OpenAI's
**Muse** — share a pattern: short, soft, concrete-but-abstract, no "AI", no
"agent", no technical compound. One or two syllables, easy to say as a verb or
possessive ("my dots", "ask Muse").

Candidates, strongest first:

| Name | Why it works | Risk |
|---|---|---|
| **Roster** | Names the real insight — a line-up of agents you can see. Natural in use: "check the roster", "add to the roster". Serious without being cold. | Slightly sporty |
| **Familiars** | A familiar is a small companion creature bound to its owner that does work on their behalf. Almost uncannily exact. Rich visual language for the identity. | Fantasy connotation; plural-only reads odd as a product name |
| **Pocketwork** | The work happens in the corner of your screen while you do something else. Warm, concrete, memorable. | Two syllables longer than the others |
| **Nook** | Where they live — the notch, the corner, the edge of the screen. Tiny, soft, inviting. Works with the notch concept as the hero. | Generic; likely contested |
| **Mote** | A mote is a tiny speck — matches the idle orb in the notch perfectly. Short, soft, slightly magical. | Obscure word for non-native speakers |

**Recommendation: Familiars**, with *Roster* as the safe alternative. Familiars
gives the identity somewhere to go — the pets genuinely are small bound
creatures doing errands for you — and it makes the notch roster feel like
summoning rather than configuration. Roster is the choice if you want the
product read as a professional tool first and a toy second.

Whatever wins, the sprite characters stay. The name should describe *the
relationship*, not the art style.

## 3. The notch command centre

This is the centrepiece of the rebrand and it reframes the whole app. Based on
the concept reference, three states:

**Resting.** A single small orb sits in the notch shelf. Almost nothing — a
presence, not a UI. Colour reflects the busiest agent: calm grey when idle, warm
when something is working, red when something failed. This is the entire UI when
you're not using it.

**Hover — the roster.** The notch expands into a wide rounded panel. Left: the
active agent, large, animated with its real sprite. Centre: that agent's live
task lane — the steps it has taken this turn, the current one highlighted.
Right: the roster, one circular avatar per pet, colour-coded by status, with the
provider's mark. Clicking an avatar switches the panel to that agent. This is
the "character selection" idea, and it is also the fix for the discoverability
problem — right now a pet's state is only legible if you happen to be looking at
it.

**Expanded — the console.** Click through and the panel grows into a full
command surface: prompt field, transcript, model and working-directory pickers,
Stop. Everything the chat popover does today, in a place that doesn't depend on
finding a 96px sprite on a cluttered desktop.

What makes it cinematic is the transition, not the layout: the notch shelf
should feel like one continuous piece of material that stretches, with the
roster avatars arriving staggered rather than together. Spring-based, ~320ms,
overshoot on expand and none on collapse.

**Why this matters beyond looks:** it decouples "where the agent lives" from
"how you talk to it". Pets can keep roaming for delight, while the notch becomes
the reliable, always-in-the-same-place control surface. That answers the real
usability complaint with desktop pets — that a UI which moves is a UI you have
to hunt for.

**Precedent to respect:** this builds on John Bai's Mac notch concept and the
Grok Bot execution by @ab_workss that you referenced. The roster-of-agents
framing is the part that is genuinely ours; the notch-as-expanding-shelf
interaction is prior art and should be credited rather than presented as
original.

**Constraint worth knowing now:** notch geometry is only available on notched
Macs. On every other display the same panel has to dock to the top edge. Design
the panel to be notch-*aware*, not notch-*dependent*, or the feature is invisible
to a large share of users.

## 4. Identity

- **Mark.** An orb with two eyes reads as a face at 16px and as a presence at
  512px, and it is the same shape as the resting notch state — so the app icon
  literally *is* the idle UI. That is the cheapest possible coherence win.
- **Palette.** One neutral base (near-black, slightly warm) plus a status set:
  calm/working/done/failed. Status colour is the only colour in the product, so
  it always means something.
- **Type.** One geometric sans for the UI, one mono for transcripts. The mono is
  doing real work — it is where the agent's output lives — so it should be the
  better-chosen of the two.
- **Terminal themes.** Ship three, not ten: a warm dark default, a true black
  for OLED, and a light. Each theme defines the status set too, so a pet's
  "working" colour is consistent with its transcript.

## 5. Motion

Current physics are already honest — real sprite frames, inertial throw, no
synthetic squash. Keep that rule. Where motion should improve:

- **Status transitions**, not idle flourishes. The moment a turn completes is the
  one the user cares about; it deserves the best animation in the product.
- **The notch stretch**, as above.
- **Roster arrival** — staggered, 40ms apart, so the line-up reads as a group
  assembling.
- **Anticipation on throw.** A few frames of wind-up before release would make
  the throw feel authored rather than physical. This is the one place a
  non-sprite transform might earn its keep, and it should be tested against the
  no-synthetic-transforms rule rather than assumed.

## 6. Launch measurement

You chose in-app onboarding A/B. The honest constraint: **the app has no
analytics at all today**, so there is nothing to measure with. A/B testing is
therefore a two-step job — instrumentation first, experiments second.

Instrumentation should be local-first and opt-in. A desktop pet that phones home
is exactly the wrong first impression for an open-source tool, and for an
audience of developers it will be the first thing they check.

Experiments worth running once that exists:

1. **First pet chosen for you vs. a picker.** Does removing the choice get more
   people to a first conversation?
2. **Where the first pet lands** — dock vs. notch roster. Directly tests whether
   the notch should be the default home.
3. **Time to first prompt.** Does a pre-filled suggested prompt beat an empty
   field?
4. **Provider pre-selection** — detect which CLIs are installed and pick, vs.
   asking.

The primary metric is the same for all four: *share of installs that complete
one agent turn on day one*. Everything else is secondary.

## 7. Sequencing

Agreed order, with the reasoning you gave — identity decisions land first
because they change what the features look like and how they get tested:

1. **Verification and edge cases.** Finish the test matrix, harden the failure
   paths. Safe ground to build on.
2. **Identity decisions.** Name, mark, palette, motion rules. Cheap to decide,
   expensive to retrofit.
3. **Notch command centre.** The structural change; everything visual depends on
   it.
4. **CLI power features.** Built into the notch surface rather than bolted onto
   the popover.
5. **Instrumentation, then the A/B experiments.**
