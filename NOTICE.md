# Third-party notices

Mini Pet Agents builds on the work below. Each upstream license is reproduced
in full as required.

---

## LilAgents

The app's architecture — the menubar shell, the per-frame character tick loop,
the dock-geometry math, and the AI CLI session layer (`AgentSession.swift`,
`ClaudeSession.swift`, `CodexSession.swift`, `CopilotSession.swift`) — is
derived from LilAgents by Ryan Stephen. Portions of the session layer are used
substantially unchanged.

```
MIT License

Copyright (c) 2026 Ryan Stephen

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## petdex

Pet sprite packs are authored and distributed by the [petdex](https://petdex.dev)
community (<https://github.com/crafter-station/petdex>). Mini Pet Agents does
**not** bundle or redistribute any sprite art — packs are fetched at runtime by
the user into `~/.codex/pets/` and remain the property of their respective
authors, under whatever terms each author published them.

The canonical animation table in `PetPack.swift` (row order, per-state frame
counts, and durations) follows the petdex sprite-sheet specification.

---

## Sparkle

Auto-update support uses [Sparkle](https://sparkle-project.org), distributed
under the MIT license with additional BSD-licensed components. See
<https://github.com/sparkle-project/Sparkle/blob/2.x/LICENSE> for the full text.
