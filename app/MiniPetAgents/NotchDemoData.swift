import AppKit

/// Seeded content for the notch, so the whole surface can be experienced
/// without waiting for four agents to actually be mid-turn.
///
/// Two rules this deliberately follows:
///
/// 1. It never touches `ActivityStore`. Demo rows are built here and handed
///    straight to the view, so nothing fabricated can reach the persisted
///    history on disk and be mistaken for a real record later.
/// 2. The pets are the user's own installed packs, drawn from their real
///    sprite sheets. Only the agent activity is invented, and the panel says
///    so while demo mode is on.
enum NotchDemoData {

    private static let key = "app.notchDemoMode"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Status hues, in the same vocabulary the live shelf uses.
    private static let calm   = NSColor(srgbRed: 0.81, green: 0.89, blue: 0.96, alpha: 1)
    private static let good   = NSColor(srgbRed: 0.18, green: 0.84, blue: 0.66, alpha: 1)
    private static let wait   = NSColor(srgbRed: 1.00, green: 0.70, blue: 0.14, alpha: 1)
    private static let review = NSColor(srgbRed: 0.61, green: 0.42, blue: 1.00, alpha: 1)
    private static let bad    = NSColor(srgbRed: 1.00, green: 0.23, blue: 0.36, alpha: 1)

    /// One roster entry per installed pet, cycling through the status colours
    /// so every state is visible at once.
    /// One roster entry per installed pet, each playing a *different* sprite
    /// state, so the shelf shows the whole animation vocabulary at once rather
    /// than five copies of the same idle pose.
    static func entries() -> [NotchShelfView.Entry] {
        let script: [(PetState, NSColor, Bool, AgentProvider)] = [
            (.running,  calm,   true,  .claude),   // the active one, hard at work
            (.runRight, good,   true,  .codex),
            (.waving,   wait,   false, .cursor),
            (.review,   review, false, .copilot),
            (.failed,   bad,    false, .claude),
        ]
        var out: [NotchShelfView.Entry] = []
        for (i, pet) in PetLibrary.shared.pets.prefix(5).enumerated() {
            guard let pack = pet.loadPack() else { continue }
            let (state, tint, busy, provider) = script[i % script.count]
            let frames = pack.frames[state] ?? pack.frames[.idle] ?? []
            guard !frames.isEmpty else { continue }
            out.append(NotchShelfView.Entry(slug: pet.slug,
                                            provider: provider,
                                            frames: frames,
                                            fps: pack.metadata.animations[state]?.fps ?? 8,
                                            tint: tint,
                                            isBusy: busy))
        }
        return out
    }

    /// A feed covering every row state the real one can produce: two turns in
    /// flight, two finished, one failed with its remedy, one interrupted.
    static func rows() -> [NotchShelfView.ActivityRow] {
        let names = PetLibrary.shared.pets.map { $0.slug }
        func name(_ i: Int) -> String { i < names.count ? names[i] : "pet \(i + 1)" }
        let packs = entries()
        func image(_ i: Int) -> NSImage? { i < packs.count ? packs[i].image : nil }
        func frames(_ i: Int) -> [NSImage] { i < packs.count ? packs[i].frames : [] }
        func fps(_ i: Int) -> Double { i < packs.count ? packs[i].fps : 8 }

        func row(_ i: Int, _ provider: AgentProvider, _ activity: String,
                 _ state: ActivityStore.Record.State, _ trailing: String,
                 _ tint: NSColor, remedy: String? = nil, live: Bool = false)
        -> NotchShelfView.ActivityRow {
            NotchShelfView.ActivityRow(
                name: name(i), provider: provider.displayName,
                providerKind: provider, slug: name(i),
                activity: activity, state: state, trailing: trailing,
                remedy: remedy, tint: tint, image: image(i),
                frames: live ? frames(i) : [], fps: fps(i))
        }

        return [
            row(0, .claude,  "Spelunking · running the test suite", .live, "14s · 2.1k", calm, live: true),
            row(1, .codex,   "Percolating · reading the diff",      .live, "9s · 840",   good, live: true),
            row(2, .cursor,  "Bash · npm run build",                .done, "1m 12s · 8.4k · $0.11", good),
            row(3, .copilot, "Not signed in to Copilot",            .failed, "—",        bad, remedy: "Sign in"),
            row(4, .claude,  "Replied",                             .done, "3m 04s · 22k · $0.28", good),
            row(0, .codex,   "Interrupted — the app quit mid-turn", .interrupted, "41s", NSColor(white: 0.55, alpha: 1)),
        ]
    }

    /// A short seeded conversation so Chat can be seen working.
    static func chat() -> [NotchShelfView.ChatLine] {
        [
            .init(isUser: true,  text: "run the test suite and tell me what broke"),
            .init(isUser: false, text: "Running it now — 169 checks. Two failed, both in the sprite pack loader."),
            .init(isUser: true,  text: "what's the common cause?"),
            .init(isUser: false, text: "Both read a frame index past the end of a row. The padding cells again."),
        ]
    }

    static let summary = "demo data · 6 turns · 33k · $0.39"
    static let word = "Spelunking"
    static let caption = "running the test suite · 14s · 2.1k"
}
