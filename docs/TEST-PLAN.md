# Test plan

Everything the app does, and how to prove each part still works.

Three levels, cheapest first:

| Level | Command | Covers |
|---|---|---|
| CLI contract | `./scripts/check-agents.py` | the arguments we pass are still accepted |
| Session layer | `"…/Mini Pet Agents" --self-test-agents` | a real turn through the app's own session classes |
| Feature logic | `"…/Mini Pet Agents" --self-test-features` | sprite packs, hit geometry, preferences, error matchers, damaged packs (131 checks) |
| Edge cases | `"…/Mini Pet Agents" --self-test-edges` | killed CLI, busy guard, stale working dir, cleanup (10 checks) |
| Manual | this document | anything that needs a window, a sprite in motion or a pointer |

All four are automated and gate a release (`RELEASING.md` step 0).
The manual cases below are the ones no script can reach — if you only have ten
minutes, run the **smoke** set.

Legend: **[A]** automated · **[M]** manual · **[S]** in the smoke set.

---

## 1. Providers and chat

| ID | Case | Expected |
|---|---|---|
| P-01 **[A]** | Each CLI accepts our argv on every invocation path | `check-agents.py` all green |
| P-02 **[A]** | One real turn per provider through the session layer | `--self-test-agents` all green |
| P-03 **[M][S]** | Click a pet, send "hi" | Reply streams into the chat; pet jumps at the end |
| P-04 **[M]** | Switch a pet's provider, send again | New provider answers; prior history still shown |
| P-05 **[M]** | Two pets, two different providers, same prompt | Both answer independently, no cross-talk |
| P-06 **[M]** | Send a follow-up ("what did I just ask?") | Context retained — this is the resume path that the Codex `--sandbox` bug broke |
| P-07 **[M]** | Press Stop mid-reply | Turn ends, pet leaves the thinking pose, chat stays usable |
| P-08 **[M]** | New Chat | History clears; next reply has no memory of the old thread |
| P-09 **[M]** | Restart Agent | Process respawns; pet returns to idle |
| P-10 **[M]** | Pick a model from the picker | Model applies; usage/cost line reflects it |
| P-11 **[M]** | Set a working directory, ask "what files are here?" | Answer reflects that directory, not home |
| P-12 **[M]** | Ask all pets… (broadcast) | Every spawned pet answers its own copy |
| P-13 **[M]** | Attach a file, ask about it | Content reaches the agent |
| P-14 **[M]** | Provider slash commands | Palette lists what the CLI advertised at init |

## 2. Pets and the gallery

| ID | Case | Expected |
|---|---|---|
| G-01 **[M][S]** | Install a pet from the gallery | Downloads, appears in the list, preview renders |
| G-02 **[M]** | Toggle Spawn on / off | Pet appears / disappears immediately |
| G-03 **[M]** | Quit and relaunch | Spawned pets come back where they were |
| G-04 **[M]** | Delete a pet | Confirmation, then gone from disk and list |
| G-05 **[M]** | Change size (per-pet and app default) | Sprite rescales, stays crisp (nearest-neighbour); prefs round-trip covered by **[A]** |
| G-06 **[M]** | Install a second pet of the same slug | No duplicate row, no double spawn |

## 3. Placement and movement

| ID | Case | Expected |
|---|---|---|
| M-01 **[M][S]** | Dock placement, watch 60s | Paces, turns at both ends, no freeze between legs |
| M-02 **[A]** | Every frame of every state is non-blank | `--self-test-features` names the offending frame indices |
| M-03 **[M]** | Free roam | Wanders the whole visible frame, stays inside it |
| M-04 **[M]** | Left / right stack | Sits against that edge, multiple pets stack without overlap |
| M-05 **[M]** | Drag a pet slowly, drop on the dock | Drop-zone overlay highlights; pet re-homes to dock |
| M-06 **[M]** | Walk speed slow / normal / fast | Visibly different traversal time, no velocity jump on change |
| M-07 **[M]** | Stationary mode | Never moves; sprite still animates on agent activity |
| M-08 **[M]** | Two pets meet on the dock | They pass through each other, no bouncing off |
| M-09 **[M]** | Second display / display picker | Pet moves to the chosen screen and stays |

## 4. Throw physics

| ID | Case | Expected |
|---|---|---|
| T-01 **[M][S]** | Fling a pet hard at a side wall | Glides, bounces, loses energy, settles |
| T-02 **[M]** | Fling at the top and bottom edges | Bounces off both — all four walls behave the same |
| T-03 **[M]** | After it settles | Switches to free roam and wanders from where it stopped |
| T-04 **[M]** | Release slowly (under the threshold) | No throw — ordinary drag-to-zone placement |
| T-05 **[M]** | Fling toward the dock | Zone-aware guard: docks rather than going ballistic |

## 5. Pointer and hover

| ID | Case | Expected |
|---|---|---|
| H-01 **[M][S]** | Hover a pet | Waving loop, held while the cursor is over it, no vertical hop |
| H-02 **[M][S]** | Click the sprite body | Chat opens |
| H-03 **[A]** | Letterbox columns reject clicks, sprite body accepts them, no vertical flip | `--self-test-features` hit-geometry section |
| H-04 **[M]** | Hover while chat is open | No waving; chat state wins |
| H-05 **[M]** | Click the completion bubble | Bubble dismisses, pet resumes its mood loop |

## 6. Chat window

| ID | Case | Expected |
|---|---|---|
| W-01 **[M]** | Resize the chat, close, reopen | Size persisted per pet |
| W-02 **[M]** | Minimize chip | Collapses; pet keeps working |
| W-03 **[M]** | Reopen a pet with history | Prior conversation replays |
| W-04 **[M]** | Switch theme | Applies to open and future chat windows |
| W-05 **[M]** | Very long reply | Scrolls, no layout break |

## 7. Edge cases

Most of these are automated now. The four that are not need hardware or network
events a script can't stage: E-04 (network drop), E-07 (pet folder deleted while
running), E-09 (dock auto-hide), E-10 (display unplugged), E-11 (sleep/wake).

| ID | Case | Expected |
|---|---|---|
| E-01 **[A]** | Provider CLI not signed in | Friendly sign-in prompt naming the exact command — not a raw stderr dump. Each provider's own message is asserted against the matcher |
| E-02 **[A]** | Provider CLI not installed | Every provider has instructions naming its binary or a link |
| E-03 **[A]** | Kill the CLI mid-reply | Noticed rather than hanging; busy clears so the pet recovers |
| E-04 **[M]** | Network drop mid-turn | Error surfaces; Restart Agent recovers |
| E-05 **[A]** | Send a second message while one is in flight | Refused with an explanation; first turn unaffected |
| E-06 **[A]** | Damaged pack — bad JSON, no sheet, undecodable sheet, missing dir | Each is skipped, nothing crashes |
| E-07 **[M]** | Delete a spawned pet's folder while running | Despawns cleanly |
| E-08 **[A]** | Working directory that no longer exists | Settles with a reported error instead of hanging |
| E-09 **[M]** | Dock hidden / auto-hide | Pets fall back to the screen bottom |
| E-10 **[M]** | Display unplugged while a pet is on it | Pet relocates to a remaining screen |
| E-11 **[M]** | Laptop sleep / wake | Pets still animate; sessions still usable |
| E-12 **[A]** | Quit with a turn in flight | Session stops, busy clears, terminate is idempotent. *Orphan check itself stays manual:* `pgrep -fl codex` after quitting |

## Smoke set

The ten-minute pass before tagging a release. Run both scripts, then:
P-03, G-01, M-01, T-01, H-01, H-02. (M-02 and H-03 are automated now.)

## Not covered

No unit tests and no UI automation. The app is `LSUIElement`, so it is invisible
to macOS UI-automation tooling unless accessibility access is granted, and the
sprite behaviour it would need to assert on is visual. Everything mechanical
that *can* be automated is in the three suites; what remains is motion and
pointer behaviour, which needs eyes.
