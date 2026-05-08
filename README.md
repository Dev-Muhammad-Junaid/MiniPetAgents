# Mini Pet Agents

Tiny petdex-powered AI companions for macOS. Pick from 870+ animated pets at [petdex.crafter.run](https://petdex.crafter.run/), spawn as many as you want on your screen, and chat with each via Claude Code, Codex, or Copilot CLIs.

This project forks the architecture of `lilagentsdoc` (LilAgents) and replaces its bundled HEVC video characters with sprite-based [petdex](https://petdex.crafter.run/) packs. It adds dynamic pet loading, four placement modes (dock / free roam / notch / edge slide), and a multi-pet broadcast composer.

## Layout

```
MiniPetAgents/
  app/                          # Xcode project — open this in Xcode
    MiniPetAgents.xcodeproj/
    MiniPetAgents/              # Swift sources + resources
  lilagentsdoc/                 # Reference fork (read-only, do not modify)
```

## Requirements

- macOS Sonoma (14.0+)
- Xcode 15+
- Node 18+ on the user's machine for `npx petdex install …`
- At least one supported AI CLI:
  - [Claude Code](https://claude.ai/download)
  - [OpenAI Codex](https://github.com/openai/codex) — `npm install -g @openai/codex`
  - [GitHub Copilot CLI](https://github.com/github/copilot-cli) — `brew install copilot-cli`

## First run

1. Open `app/MiniPetAgents.xcodeproj` in Xcode.
2. Set a development team in target signing.
3. Build & run.
4. The menubar icon appears (paw print). Click it → "Pet Gallery…" → install your first pet (e.g. `noir-webling`).
5. Toggle "Spawn" on a row to drop the pet onto your screen. **Click** the pet (no modifiers) to chat. **Hold Shift and drag** to move it anywhere and pin that position (pauses auto placement until you clear the pin in the menubar pet submenu).

## Feature map

| Area | File | Notes |
|---|---|---|
| Menubar / app entry | [`app/MiniPetAgents/LilAgentsApp.swift`](app/MiniPetAgents/LilAgentsApp.swift) | Per-pet submenus (placement, provider, **size**, **clear pin**), **app default pet size**, theme, displays, broadcast, gallery |
| Tick loop & dock geometry | [`app/MiniPetAgents/LilAgentsController.swift`](app/MiniPetAgents/LilAgentsController.swift) | Owns spawn/despawn; delegates positioning to placement strategies |
| On-screen pet | [`app/MiniPetAgents/WalkerCharacter.swift`](app/MiniPetAgents/WalkerCharacter.swift) | Sprite-driven; dock **always LTR**; walk frames **sync** to movement; **idle/sleep/happy** hold first frame (no blink loops); drag to **pin** position |
| Sprite renderer | [`app/MiniPetAgents/PetPack.swift`](app/MiniPetAgents/PetPack.swift) | Decodes `pet.json` + spritesheet; `SpriteAnimator` with static-hold calm states + walk progress sync |
| Library + watcher | [`app/MiniPetAgents/PetLibrary.swift`](app/MiniPetAgents/PetLibrary.swift) | Scans `~/.codex/pets/`; **display height** + **pinned screen origin** prefs |
| Installer | [`app/MiniPetAgents/PetInstaller.swift`](app/MiniPetAgents/PetInstaller.swift) | Wraps `npx petdex install/list` |
| Gallery UI | [`app/MiniPetAgents/PetGalleryWindow.swift`](app/MiniPetAgents/PetGalleryWindow.swift) | SwiftUI; install, spawn, placement, provider, **size** picker, open chat |
| Hit testing / drag | [`app/MiniPetAgents/CharacterContentView.swift`](app/MiniPetAgents/CharacterContentView.swift) | Alpha-aware hit test; **Shift+drag** to reposition and **pin** (no drag-distance heuristics) |
| Placement modes | [`app/MiniPetAgents/PlacementMode.swift`](app/MiniPetAgents/PlacementMode.swift) | dock / freeRoam / notch / edgeSlide strategies |
| Broadcast | [`app/MiniPetAgents/BroadcastComposer.swift`](app/MiniPetAgents/BroadcastComposer.swift) | Fan a single prompt to every spawned pet |
| AI CLI sessions | `Claude/Codex/CopilotSession.swift`, `AgentSession.swift` | Verbatim from LilAgents |

## Per-pet preferences

Stored in `UserDefaults` under keys:

- `pet.<slug>.spawned` — bool, on-screen state at launch
- `pet.<slug>.placement` — one of `dock`, `freeRoam`, `notch`, `edgeSlide`
- `pet.<slug>.provider` — optional override of `claude`/`codex`/`copilot`
- `pet.<slug>.edge` — for `edgeSlide` mode: `left`/`right`/`top`/`bottom`
- `app.defaultPetDisplayHeight` — global default window height (pt)
- `pet.<slug>.displayHeight` — optional per-pet height override
- `pet.<slug>.pinnedScreenOrigin` — `NSStringFromPoint` when the user dragged to pin; clears to resume auto placement

## Pet pack format

The decoder accepts a few shapes for `pet.json` to be tolerant of community variation; see `PetMetadata.decode`. Supported animations map onto `PetState`:

```
idle, walk, run, sleep, think, happy, sad, working, talking
```

Spritesheet is row-major; default grid 8×9. `idle` / `sleep` / `happy` show a **single static frame** in-app to avoid distracting blink cycles in full multi-frame sheets. `walk` frame index follows **movement progress**. Other states use timed frame advance as defined in `pet.json`.

## Use cases

- "Walk a tiny detective above my dock and ask it coding questions" → install `noir-webling`, leave placement on Dock.
- "Park one under the notch and slide out when Claude finishes" → set placement to Notch; on `onTurnComplete` the strategy briefly slides the pet down.
- "Compare Claude vs Codex on the same prompt" → spawn two pets, set per-pet provider override, use Broadcast composer.
- "Pet on my second display only" → set Display submenu to that screen.

## Out of scope (v1)

- Direct REST APIs (OpenAI/Anthropic/Gemini) — CLI subprocess only.
- Submitting/creating pets in-app — defer to `npx petdex submit`.
- iCloud / cross-device preference sync.

## Auto-updates

Sparkle is wired up but the appcast feed URL in [`app/MiniPetAgents/Info.plist`](app/MiniPetAgents/Info.plist) is a placeholder. Replace `SUFeedURL` and add a `SUPublicEDKey` once you publish a feed.

## License

This project depends on the LilAgents source layout (MIT). See `lilagentsdoc/LICENSE` in the reference fork.
