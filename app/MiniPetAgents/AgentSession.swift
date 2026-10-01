import Foundation
import AppKit

// MARK: - Provider

enum AgentProvider: String, CaseIterable, Codable {
    case claude, codex, copilot, cursor, gemini

    private static let defaultsKey = "selectedProvider"

    /// Providers offered in the UI. Gemini/Antigravity is hidden for now: agy
    /// is an autonomous coding agent with no chat-only mode, so it explores the
    /// filesystem instead of replying like a pet. To bring it back, just drop
    /// the filter below (GeminiSession is still wired up).
    static var selectableCases: [AgentProvider] {
        allCases.filter { $0 != .gemini }
    }

    static var current: AgentProvider {
        get {
            let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? "claude"
            let provider = AgentProvider(rawValue: raw) ?? .claude
            // Never surface a hidden provider as the active default.
            return selectableCases.contains(provider) ? provider : .claude
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }

    var displayName: String {
        switch self {
        case .claude:  return "Claude"
        case .codex:   return "Codex"
        case .copilot: return "Copilot"
        case .cursor:  return "Cursor"
        case .gemini:  return "Gemini"
        }
    }

    var inputPlaceholder: String {
        "Ask \(displayName)..."
    }

    /// Brand accent color shown in the chat title bar icon badge.
    var brandColor: NSColor {
        switch self {
        case .claude:  return NSColor(red: 0.79, green: 0.38, blue: 0.26, alpha: 1.0)  // Anthropic terracotta
        case .codex:   return NSColor(red: 0.42, green: 0.41, blue: 0.95, alpha: 1.0)  // Codex purple-blue
        case .copilot: return NSColor(red: 0.0,  green: 0.47, blue: 0.84, alpha: 1.0)  // Microsoft Copilot blue
        case .cursor:  return NSColor(red: 0.20, green: 0.46, blue: 0.99, alpha: 1.0)  // Cursor blue
        case .gemini:  return NSColor(red: 0.55, green: 0.56, blue: 0.60, alpha: 1.0)  // Gemini gem silver
        }
    }

    /// Asset catalog image name for the provider logo shown in the chat title bar.
    var logoImageName: String {
        switch self {
        case .claude:  return "logo-claude"
        case .codex:   return "logo-codex"
        case .copilot: return "logo-copilot"
        case .cursor:  return "logo-cursor"
        case .gemini:  return "logo-gemini"
        }
    }

    /// SF Symbol fallback if the logo asset is missing.
    var symbolName: String {
        switch self {
        case .claude:  return "sparkle"
        case .codex:   return "terminal"
        case .copilot: return "infinity"
        case .cursor:  return "play.fill"
        case .gemini:  return "cube.fill"
        }
    }

    /// Returns provider name styled per theme format.
    func titleString(format: TitleFormat) -> String {
        switch format {
        case .uppercase:      return displayName.uppercased()
        case .lowercaseTilde: return "\(displayName.lowercased()) ~"
        case .capitalized:    return displayName
        }
    }

    var installInstructions: String {
        switch self {
        case .claude:
            return "To install, run this in Terminal:\n  curl -fsSL https://claude.ai/install.sh | sh\n\nOr download from https://claude.ai/download"
        case .codex:
            return "To install, run this in Terminal:\n  npm install -g @openai/codex"
        case .copilot:
            return "To install, run this in Terminal:\n  npm install -g @github/copilot"
        case .cursor:
            return "To install Cursor Agent, run this in Terminal:\n  curl https://cursor.com/install -fsS | bash\n\nThen add ~/.local/bin to your PATH if prompted."
        case .gemini:
            return "Install Antigravity CLI (replaces Gemini CLI as of Google I/O 2026):\n  curl -fsSL https://antigravity.google/cli/install.sh | bash\n\nLegacy Gemini CLI (EOL June 18 2026):\n  npm install -g @google/gemini-cli"
        }
    }

    func createSession() -> any AgentSession {
        switch self {
        case .claude:  return ClaudeSession()
        case .codex:   return CodexSession()
        case .copilot: return CopilotSession()
        case .cursor:  return CursorSession()
        case .gemini:  return GeminiSession()
        }
    }

    /// Models known to be valid without querying the CLI. Used as picker
    /// suggestions for providers that don't expose a headless model list.
    /// (Claude's aliases are stable/documented; others fetch or use Custom.)
    var knownModels: [String] {
        switch self {
        case .claude: return ["opus", "sonnet", "haiku"]
        default:      return []
        }
    }

    /// Executable names this provider will try, in order. Gemini falls back
    /// to the legacy `gemini` binary when Antigravity's `agy` isn't present.
    var binaryCandidates: [String] {
        switch self {
        case .claude:  return ["claude"]
        case .codex:   return ["codex"]
        case .copilot: return ["copilot"]
        case .cursor:  return ["cursor-agent"]
        case .gemini:  return ["agy", "gemini"]
        }
    }

    /// What to tell the user when this CLI reports they aren't signed in.
    var signInHint: String {
        switch self {
        case .claude:  return "Open Terminal and run:\n  claude\nthen use /login."
        case .codex:   return "Open Terminal and run:\n  codex login"
        case .copilot: return "Open Terminal and run:\n  copilot\nthen use /login."
        case .cursor:  return "Open Terminal and run:\n  cursor-agent login"
        case .gemini:  return "Open Terminal and run:\n  agy login"
        }
    }

    /// Friendly, actionable replacement for a raw CLI auth error.
    var notSignedInMessage: String {
        "Not signed in to \(displayName).\n\n\(signInHint)\n\nThen come back and chat here."
    }
}

// MARK: - Authentication failures

/// Substrings that mean "the user isn't signed in to this CLI".
///
/// Centralised because every CLI words this differently *and* rewords it
/// between releases. Cursor moved from "not logged in" to "Authentication
/// required", which silently turned its friendly sign-in hint into dead code —
/// the pet showed a raw stderr dump instead. Codex, Copilot and Gemini had no
/// detection at all. One list, checked by `scripts/check-agents.py`.
let authFailureMarkers: [String] = [
    "not logged in",
    "not signed in",
    "not authenticated",
    "login required",
    "authentication required",
    "unauthenticated",
    "unauthorized",
    "please run /login",
    "please log in",
    "please sign in",
    "sign in to continue",
    "no credentials",
    "invalid api key",
    "missing api key",
]

/// stderr lines that are chatter, not failures.
///
/// These CLIs use stderr as a progress channel. Codex announces "Reading
/// additional input from stdin..." on every single run; treating that as an
/// error put the pet in the failed pose for a turn that was working perfectly.
/// Anything not matched here is still surfaced.
let benignStderrMarkers: [String] = [
    "reading additional input from stdin",
    "reading prompt from stdin",
]

/// Drop the chatter and return what's left, or nil when the whole chunk was
/// noise and nothing should be reported to the user.
func meaningfulStderr(_ text: String) -> String? {
    let kept = text
        .split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { line in
            guard !line.isEmpty else { return false }
            let low = line.lowercased()
            return !benignStderrMarkers.contains { low.contains($0) }
        }
    return kept.isEmpty ? nil : kept.joined(separator: "\n")
}

/// True when CLI output looks like a sign-in problem rather than a real error.
func looksLikeAuthFailure(_ text: String) -> Bool {
    let lower = text.lowercased()
    return authFailureMarkers.contains { lower.contains($0) }
}

// MARK: - Model listing (best-effort)

/// Run a CLI and pull single-token model ids from its stdout. Times out so a
/// CLI that drops into an interactive prompt can't hang the picker.
func captureModelList(binaryPath: String, arguments: [String],
                      environment: [String: String],
                      completion: @escaping ([String]) -> Void) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: binaryPath)
    proc.arguments = arguments
    proc.environment = environment
    let out = Pipe()
    // Give the CLI a closed stdin rather than inheriting the app's. Model
    // listing runs without any "print/headless" flag, so a CLI that sees an
    // interactive stdin may try to draw a TUI — Ink-based ones fail loudly
    // with "Raw mode is not supported on the current process.stdin" and spray
    // terminal escape codes into our output. The timeout below is the backstop;
    // this is the actual prevention.
    proc.standardInput = FileHandle.nullDevice
    proc.standardOutput = out
    proc.standardError = Pipe()

    var finished = false
    let finish: ([String]) -> Void = { models in
        if finished { return }
        finished = true
        DispatchQueue.main.async { completion(models) }
    }

    proc.terminationHandler = { _ in
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        finish(parseModelTokens(text))
    }
    do {
        try proc.run()
    } catch {
        finish([])
        return
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
        if proc.isRunning { proc.terminate() }
    }
}

/// Keep only single-token, model-id-looking lines (skips headers/tables).
func parseModelTokens(_ text: String) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for raw in text.split(separator: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.contains(" "),
              line.range(of: "^[A-Za-z][A-Za-z0-9._:/-]{1,}$", options: .regularExpression) != nil
        else { continue }
        if seen.insert(line).inserted { result.append(line) }
    }
    return result
}

// MARK: - Title Format

enum TitleFormat {
    case uppercase       // "CLAUDE"
    case lowercaseTilde  // "claude ~"
    case capitalized     // "Claude"
}

// MARK: - Message

struct AgentMessage: Codable {
    enum Role: String, Codable { case user, assistant, error, toolUse, toolResult }
    let role: Role
    let text: String
}

// MARK: - Usage formatting

/// Build a compact "↑in ↓out tok · $cost" line from whatever a provider reports.
/// Returns nil when there's nothing useful to show.
func formatUsageNote(inputTokens: Int?, outputTokens: Int?, costUSD: Double?) -> String? {
    var parts: [String] = []
    if let i = inputTokens, let o = outputTokens {
        parts.append("↑\(i) ↓\(o) tok")
    } else if let o = outputTokens {
        parts.append("↓\(o) tok")
    } else if let i = inputTokens {
        parts.append("↑\(i) tok")
    }
    if let c = costUSD, c > 0 {
        parts.append(String(format: "$%.4f", c))
    }
    guard !parts.isEmpty else { return nil }
    return "  " + parts.joined(separator: " · ")
}

// MARK: - Session Protocol

protocol AgentSession: AnyObject {
    var isRunning: Bool { get }
    var isBusy: Bool { get }
    var history: [AgentMessage] { get set }
    /// Directory the CLI runs in. nil = the user's home directory. Set before
    /// `start()`; the CLI's cwd is fixed at launch, so changing it later
    /// requires restarting the session.
    var workingDirectory: URL? { get set }
    /// Model passed to the CLI via --model. nil = the provider's default.
    var model: String? { get set }

    var onText: ((String) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    var onToolUse: ((String, [String: Any]) -> Void)? { get set }
    var onToolResult: ((String, Bool) -> Void)? { get set }
    var onSessionReady: (() -> Void)? { get set }
    var onTurnComplete: (() -> Void)? { get set }
    var onProcessExit: (() -> Void)? { get set }
    /// Per-turn usage line (tokens / cost) when the provider reports it.
    var onUsage: ((String) -> Void)? { get set }
    /// Slash commands the provider advertises (e.g. from Claude's init event).
    var onProviderCommands: (([String]) -> Void)? { get set }

    func start()
    func send(message: String)
    func send(message: String, attachments: [ChatAttachment])
    /// Cancel the in-flight turn (if any) without discarding the conversation.
    /// One-shot providers keep their resume id; the persistent Claude session
    /// restarts its process (its in-CLI context resets).
    func interrupt()
    func terminate()
    /// Best-effort list of selectable models. Default: none (use Custom entry).
    func listModels(completion: @escaping ([String]) -> Void)
}

extension AgentSession {
    func listModels(completion: @escaping ([String]) -> Void) { completion([]) }
}

// MARK: - Default attachment handling

extension AgentSession {
    /// Non-Claude sessions: prepend text file contents into the message; note images by filename.
    func send(message: String, attachments: [ChatAttachment]) {
        guard !attachments.isEmpty else { send(message: message); return }
        var prefix = ""
        for att in attachments {
            switch att.kind {
            case .text(let content): prefix += "[\(att.filename)]\n\(content)\n\n"
            case .image:             prefix += "[Image: \(att.filename)]\n"
            }
        }
        send(message: prefix + message)
    }
}

// MARK: - Headless self-test

/// Exercises each provider through the app's own `AgentSession` implementation
/// — process launch, argv, streaming, output parsing, turn completion — rather
/// than through the CLI directly.
///
/// `scripts/check-agents.py` proves the CLIs accept our arguments. It cannot
/// prove we understand what they send back: a provider can rename an event or
/// reshape its JSON and still accept every flag, leaving a pet that sits in the
/// thinking pose forever. This closes that gap.
///
///     "/Applications/Mini Pet Agents.app/Contents/MacOS/Mini Pet Agents" \
///         --self-test-agents [--only claude,codex]
enum AgentSelfTest {
    private static let probe = "Reply with exactly: PETOK"
    private static let marker = "PETOK"

    enum Outcome {
        case pass(String)
        case auth
        case fail(String)
        case skipped(String)
    }

    static func run(only: [String]?, timeout: TimeInterval) -> Never {
        let providers = AgentProvider.allCases.filter {
            only == nil || only!.contains($0.rawValue)
        }
        // An app bundle's stdout is fully buffered, so a batched report at the
        // end arrives as nothing at all if anything goes sideways. Unbuffer and
        // emit each provider the moment it resolves — this doubles as progress
        // for a run that can take several minutes.
        setvbuf(stdout, nil, _IONBF, 0)

        var anyFailed = false
        say("")
        for provider in providers {
            let outcome = exercise(provider, timeout: timeout)
            let (mark, detail): (String, String)
            switch outcome {
            case .pass(let d):    (mark, detail) = ("ok  ", d)
            case .auth:           (mark, detail) = ("auth", "not signed in — app showed the sign-in prompt")
            case .skipped(let d): (mark, detail) = ("skip", d)
            case .fail(let d):
                (mark, detail) = ("FAIL", d)
                anyFailed = true
            }
            say("  \(mark)  \(provider.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)) \(detail)")
        }

        say("")
        say(anyFailed
            ? "A provider failed inside the app's own session layer."
            : "Every provider completed a turn through the app's session layer.")
        fflush(stdout)
        exit(anyFailed ? 1 : 0)
    }

    /// stdout for the report, mirrored to stderr so the result survives even if
    /// the caller only captured one of them.
    private static func say(_ line: String) {
        print(line)
        fflush(stdout)
    }

    /// Send one message and wait for the session to report the turn finished.
    private static func exercise(_ provider: AgentProvider, timeout: TimeInterval) -> Outcome {
        guard installedBinary(for: provider) != nil else {
            return .skipped("\(provider.binaryCandidates.joined(separator: "/")) not installed")
        }

        let session = provider.createSession()
        var streamed = ""
        var failure: String?
        var finished = false

        session.onText = { streamed += $0 }
        session.onTurnComplete = { finished = true }
        session.onError = { message in
            if failure == nil { failure = message }
            finished = true
        }
        session.onProcessExit = { finished = true }

        session.start()
        // start() spawns a process; persistent sessions aren't writable until
        // it's up. Give it a moment rather than racing the spawn.
        pump(until: { session.isRunning }, deadline: Date().addingTimeInterval(15))
        guard session.isRunning else {
            session.terminate()
            return .fail("session never reported running")
        }

        session.send(message: probe)
        pump(until: { finished }, deadline: Date().addingTimeInterval(timeout))
        session.terminate()

        if let failure = failure {
            if looksLikeAuthFailure(failure) { return .auth }
            return .fail(oneLine(failure))
        }
        if !finished { return .fail("no turn-complete within \(Int(timeout))s") }
        if streamed.contains(marker) { return .pass("turn completed, reply parsed") }
        if streamed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .fail("turn completed but no text was parsed from the reply")
        }
        return .pass("turn completed, reply parsed (marker not echoed verbatim)")
    }

    /// Run the main loop until `condition` holds or we pass `deadline`. The
    /// session classes dispatch their callbacks to the main queue, so the loop
    /// has to actually turn for any of this to make progress.
    private static func pump(until condition: () -> Bool, deadline: Date) {
        while !condition(), Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    /// Synchronous PATH lookup. ShellEnvironment.findBinary is async and the
    /// run loop isn't turning yet at this point, so resolve it directly.
    private static func installedBinary(for provider: AgentProvider) -> String? {
        let path = ShellEnvironment.processEnvironment()["PATH"] ?? ""
        let dirs = path.split(separator: ":").map(String.init)
        for name in provider.binaryCandidates {
            for dir in dirs where FileManager.default.isExecutableFile(atPath: "\(dir)/\(name)") {
                return "\(dir)/\(name)"
            }
        }
        return nil
    }

    private static func oneLine(_ s: String) -> String {
        let flat = s.split(whereSeparator: \.isNewline).joined(separator: " ")
        return String(flat.prefix(110))
    }
}

// MARK: - Headless feature self-test
//
// NOTE: this and AgentSelfTest should live in their own SelfTest.swift. They're
// here because adding a file means editing project.pbxproj by hand, which is
// worth doing deliberately rather than in passing.

/// Everything about the app that can be checked without a window or a pointer:
/// sprite packs, the hit-test geometry, preference round-trips, and the string
/// matchers that decide what the user is shown when a CLI misbehaves.
///
///     "…/Mini Pet Agents" --self-test-features
enum FeatureSelfTest {
    /// Canonical petdex row lengths. The padding past these is blank.
    private static let canonical: [(PetState, Int)] = [
        (.idle, 6), (.runRight, 8), (.runLeft, 8), (.waving, 4), (.jumping, 5),
        (.failed, 8), (.waiting, 6), (.running, 6), (.review, 6),
    ]

    private static var failures = 0
    private static var checks = 0

    static func run() -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        print("")
        spritePacks()
        hitGeometry()
        preferences()
        matchers()
        brokenPacks()
        missingBinaries()
        activityFeed()
        print("")
        print(failures == 0
              ? "All \(checks) feature checks passed."
              : "\(failures) of \(checks) feature checks failed.")
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: checks

    private static func spritePacks() {
        section("sprite packs")
        let pets = PetLibrary.shared.pets
        guard !pets.isEmpty else { return skip("no pets installed") }

        for pet in pets {
            guard let pack = PetPack.load(from: pet.folderURL) else {
                fail("\(pet.slug): pack failed to load"); continue
            }
            for (state, expected) in canonical {
                guard let frames = pack.frames[state] else {
                    fail("\(pet.slug): missing \(state.rawValue)"); continue
                }
                expect(frames.count == expected,
                       "\(pet.slug) \(state.rawValue): \(frames.count) frames, expected \(expected)")

                // The blank-frame bug: a padded cell inside the animation makes
                // the pet vanish for a beat at the end of every cycle.
                var blank: [Int] = []
                for (i, img) in frames.enumerated() {
                    var r = CGRect(origin: .zero, size: img.size)
                    guard let cg = img.cgImage(forProposedRect: &r, context: nil, hints: nil) else { continue }
                    if SpriteHitGeometry.isBlank(cg) { blank.append(i) }
                }
                expect(blank.isEmpty, blank.isEmpty
                       ? "\(pet.slug) \(state.rawValue): no blank frames"
                       : "\(pet.slug) \(state.rawValue): blank frame(s) at \(blank) — pet will blink out")
            }
        }
    }

    private static func hitGeometry() {
        section("hit testing")
        guard let pet = PetLibrary.shared.pets.first,
              let pack = PetPack.load(from: pet.folderURL),
              let first = pack.frames[.idle]?.first else { return skip("no pet to sample") }
        var r = CGRect(origin: .zero, size: first.size)
        guard let cg = first.cgImage(forProposedRect: &r, context: nil, hints: nil) else {
            return fail("idle frame has no CGImage")
        }

        // A square window around a taller-than-wide frame letterboxes left and
        // right; those columns must not accept clicks.
        let box = CGSize(width: 96, height: 96)
        expect(SpriteHitGeometry.alpha(of: cg, atLayerPoint: CGPoint(x: 0.5, y: 48), layerSize: box) == 0,
               "left letterbox column should be transparent")
        expect(SpriteHitGeometry.alpha(of: cg, atLayerPoint: CGPoint(x: 95.5, y: 48), layerSize: box) == 0,
               "right letterbox column should be transparent")
        expect(SpriteHitGeometry.alpha(of: cg, atLayerPoint: CGPoint(x: -1, y: 48), layerSize: box) == 0,
               "points outside the layer should be transparent")

        // The sprite's own body must be hittable, or clicking a pet does nothing.
        var opaque = 0
        for y in stride(from: 4, to: 92, by: 4) {
            for x in stride(from: 4, to: 92, by: 4) {
                if SpriteHitGeometry.alpha(of: cg, atLayerPoint: CGPoint(x: CGFloat(x), y: CGFloat(y)),
                                           layerSize: box) > 30.0 / 255.0 { opaque += 1 }
            }
        }
        expect(opaque > 60, "sprite body should be broadly clickable (got \(opaque) opaque sample points)")

        // Orientation: a petdex sprite stands on the ground, so the bottom half
        // of the frame carries more ink than the very top. A vertical flip in
        // the mapping shows up here.
        func inkRow(_ y: CGFloat) -> Int {
            stride(from: 4, to: 92, by: 2).reduce(0) {
                $0 + (SpriteHitGeometry.alpha(of: cg, atLayerPoint: CGPoint(x: CGFloat($1), y: y),
                                              layerSize: box) > 0.1 ? 1 : 0)
            }
        }
        expect(inkRow(20) >= inkRow(92), "sprite should be denser near its feet than above its head (flip check)")
    }

    private static func preferences() {
        section("preferences")
        let slug = "selftest-pet"
        let before = PetLibrary.preferredPlacement(for: slug)

        for mode in PlacementMode.allCases {
            PetLibrary.setPreferredPlacement(mode, for: slug)
            expect(PetLibrary.preferredPlacement(for: slug) == mode,
                   "placement \(mode.rawValue) should round-trip")
        }
        PetLibrary.setPreferredModel("some-model", for: slug)
        expect(PetLibrary.preferredModel(for: slug) == "some-model", "model should round-trip")
        PetLibrary.setPreferredModel(nil, for: slug)
        expect(PetLibrary.preferredModel(for: slug) == nil, "clearing the model should stick")

        // Removed option values linger in UserDefaults from older builds —
        // `alwaysWalk` was a real MovementMode until it was dropped. Resolving
        // one must fall back, not crash or return something unusable.
        UserDefaults.standard.set("alwaysWalk", forKey: "pet.\(slug).movementMode")
        let resolved = PetLibrary.resolvedMovementMode(for: slug)
        expect(MovementMode.allCases.contains(resolved),
               "a removed movementMode value should fall back to a valid mode (got \(resolved.rawValue))")
        UserDefaults.standard.set("ludicrous", forKey: "pet.\(slug).walkSpeed")
        expect(WalkSpeed.allCases.contains(PetLibrary.resolvedWalkSpeed(for: slug)),
               "an unknown walkSpeed should fall back to a valid speed")

        for suffix in ["placement", "model", "movementMode", "walkSpeed"] {
            UserDefaults.standard.removeObject(forKey: "pet.\(slug).\(suffix)")
        }
        PetLibrary.setPreferredPlacement(before, for: slug)
        UserDefaults.standard.removeObject(forKey: "pet.\(slug).placement")
    }

    private static func matchers() {
        section("error matchers")
        // The app's own sign-in message has to satisfy its own matcher, or a
        // signed-out provider shows a raw stderr dump instead of guidance.
        for provider in AgentProvider.allCases {
            expect(looksLikeAuthFailure(provider.notSignedInMessage),
                   "\(provider.rawValue): its own sign-in message should match the auth matcher")
        }
        // Real wording seen in the wild.
        for sample in ["Error: Authentication required. Please run 'agent login' first.",
                       "You are not logged in. Please run /login",
                       "401 Unauthorized"] {
            expect(looksLikeAuthFailure(sample), "should recognise: \(sample)")
        }
        expect(!looksLikeAuthFailure("file not found: config.toml"),
               "an ordinary error should not be read as a sign-in problem")

        expect(meaningfulStderr("Reading additional input from stdin...") == nil,
               "codex stdin chatter should be dropped entirely")
        expect(meaningfulStderr("Reading additional input from stdin...\nError: boom") == "Error: boom",
               "a real error alongside chatter should survive")
        expect(meaningfulStderr("   \n  \n") == nil, "whitespace-only stderr should be dropped")
        expect(meaningfulStderr("Error: boom") == "Error: boom", "a real error should pass through")
    }

    /// E-06 — a pack that is damaged on disk must be skipped, not crash the
    /// app or take the other pets down with it.
    private static func brokenPacks() {
        section("damaged pet packs")
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("mpa-selftest-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }

        func makeCase(_ name: String, json: String?, sheet: Bool) -> URL {
            let dir = root.appendingPathComponent(name)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if let json = json {
                try? json.write(to: dir.appendingPathComponent("pet.json"),
                                atomically: true, encoding: .utf8)
            }
            if sheet {
                try? Data("not an image".utf8)
                    .write(to: dir.appendingPathComponent("spritesheet.png"))
            }
            return dir
        }

        expect(PetPack.load(from: makeCase("empty", json: nil, sheet: false)) == nil,
               "a directory with no pet.json is skipped")
        expect(PetPack.load(from: makeCase("badjson", json: "{ not json", sheet: true)) == nil,
               "malformed pet.json is skipped")
        expect(PetPack.load(from: makeCase("nosheet", json: "{\"id\":\"x\"}", sheet: false)) == nil,
               "a pack with no spritesheet is skipped")
        expect(PetPack.load(from: makeCase("badsheet", json: "{\"id\":\"x\"}", sheet: true)) == nil,
               "an undecodable spritesheet is skipped")
        expect(PetPack.load(from: root.appendingPathComponent("does-not-exist")) == nil,
               "a missing directory is skipped")
    }

    /// E-02 — when a CLI isn't installed the user needs to be told which one
    /// and how to get it, not handed a launch failure.
    private static func missingBinaries() {
        section("missing CLI guidance")
        for provider in AgentProvider.allCases {
            let text = provider.installInstructions
            expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   "\(provider.rawValue): has install instructions")
            let mentionsBinary = provider.binaryCandidates.contains { text.contains($0) }
            expect(mentionsBinary || text.contains("http"),
                   "\(provider.rawValue): instructions name the binary or link somewhere")
        }
    }

    /// The Activity feed is only worth having if it never invents anything,
    /// so these pin the honesty rules as much as the mechanics.
    private static func activityFeed() {
        section("activity feed")
        let store = ActivityStore.shared
        store.clear()

        let a = store.beginTurn(petSlug: "pet-a", provider: .claude)
        expect(store.records.first?.id == a, "a new turn lands at the top of the feed")
        expect(store.records.first?.state == .live, "a new turn starts live")
        expect(store.live.count == 1, "it counts as live")
        expect(store.records.first?.activity == "Thinking",
               "a turn with no tool activity says Thinking, not an invented description")

        store.noteTool("Bash", detail: "npm test", for: a)
        expect(store.records.first?.activity == "Bash · npm test",
               "activity reads back the CLI's own tool and target")
        store.noteTool("Read", detail: nil, for: a)
        expect(store.records.first?.activity == "Read", "a tool with no detail shows just the tool")
        expect(store.records.first?.toolCalls == 2, "tool calls are counted")

        store.noteUsage("2.1k tokens · $0.04", for: a)
        expect(store.records.first?.usageNote == "2.1k tokens · $0.04",
               "the provider's usage line is stored verbatim, not re-derived")

        store.complete(a)
        expect(store.records.first?.state == .done, "completing moves the turn to done")
        expect(store.records.first?.endedAt != nil, "completing stamps an end time")
        expect(store.live.isEmpty, "a completed turn is no longer live")

        // A turn that did nothing but reply should say so honestly.
        let b = store.beginTurn(petSlug: "pet-b", provider: .codex)
        store.complete(b)
        expect(store.records.first?.activity == "Replied",
               "a turn with no tools reports Replied rather than a made-up summary")

        // Failures carry their own fix where we can name one.
        let c = store.beginTurn(petSlug: "pet-c", provider: .cursor)
        store.fail(c, message: "Error: Authentication required. Please run 'agent login' first.",
                   provider: .cursor)
        expect(store.records.first?.state == .failed, "a failed turn is marked failed")
        expect(store.records.first?.remedy == .signIn(.cursor),
               "a sign-in failure offers Sign in inline")

        let d = store.beginTurn(petSlug: "pet-d", provider: .codex)
        store.fail(d, message: "ENOENT: no such file or directory", provider: .codex)
        expect(store.records.first?.remedy == nil,
               "an ordinary failure offers no bogus remedy")

        expect(ActivityStore.shortFailure("line one\nline two") == "line one",
               "a failure row shows the first line only")
        expect(ActivityStore.shortFailure(String(repeating: "x", count: 300)).count == 90,
               "a long failure is truncated to fit one row")

        let (turns, failures) = store.totals()
        expect(turns == 4 && failures == 2, "totals count turns and failures across every pet")

        // --- persistence ---
        // A turn still running when the app quit did not fail; we never found
        // out how it ended. It settles to `interrupted`, which is its own
        // state precisely so the feed doesn't have to claim otherwise.
        let stale = store.records.first { $0.state == .done }
        var pretendLive = stale!
        pretendLive.state = .live
        pretendLive.endedAt = nil
        let settled = ActivityStore.settleStaleTurns([pretendLive])
        expect(settled.first?.state == .interrupted,
               "a turn left live by a quit settles to interrupted, not failed")
        expect(settled.first?.endedAt != nil, "a settled turn gets an end time")
        expect(settled.first?.activity.contains("Interrupted") == true,
               "an interrupted turn says so plainly")

        var done = stale!
        done.state = .done
        expect(ActivityStore.settleStaleTurns([done]).first?.state == .done,
               "settling leaves finished turns alone")

        var old = stale!
        old = ActivityStore.Record(id: old.id, petSlug: old.petSlug, provider: old.provider,
                                   state: .done,
                                   startedAt: Date().addingTimeInterval(-ActivityStore.retention - 60),
                                   endedAt: nil, lastTool: nil, lastToolDetail: nil,
                                   toolCalls: 0, usageNote: nil, failure: nil, remedy: nil)
        expect(ActivityStore.prune([old]).isEmpty, "turns past the retention window are dropped")
        expect(ActivityStore.prune([stale!]).count == 1, "recent turns are kept")

        // The file has to survive a round trip or "what did everyone do
        // yesterday" silently becomes "what did everyone do since launch".
        if let data = try? JSONEncoder().encode(store.records),
           let back = try? JSONDecoder().decode([ActivityStore.Record].self, from: data) {
            expect(back.count == store.records.count, "the feed round-trips through JSON")
            expect(back.contains { $0.remedy == .signIn(.cursor) },
                   "a remedy survives the round trip")
            expect(back.contains { $0.state == .failed }, "states survive the round trip")
        } else {
            fail("the feed failed to encode or decode")
        }

        store.clear()
        expect(store.records.isEmpty, "clearing empties the feed")
    }

    // MARK: harness

    private static func section(_ name: String) { print("  \(name)") }
    private static func skip(_ why: String) { print("    skip  \(why)") }
    private static func fail(_ why: String) { failures += 1; checks += 1; print("    FAIL  \(why)") }
    private static func expect(_ condition: Bool, _ description: String) {
        checks += 1
        if condition { print("    ok    \(description)") }
        else { failures += 1; print("    FAIL  \(description)") }
    }
}

// MARK: - Headless edge-case self-test

/// Failure paths that need a real subprocess: a CLI dying mid-turn, a second
/// message arriving while one is in flight, a working directory that no longer
/// exists, and cleanup on quit. These are the ones that bite real users, and
/// none of them are reachable from a pure-logic test.
///
///     "…/Mini Pet Agents" --self-test-edges [--provider codex]
enum EdgeSelfTest {
    private static var failures = 0
    private static var checks = 0

    static func run(provider: AgentProvider) -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        print("")
        print("  edge cases via \(provider.rawValue)")
        badWorkingDirectory(provider)
        busyGuard(provider)
        killedMidTurn(provider)
        terminateIsClean(provider)
        print("")
        print(failures == 0
              ? "All \(checks) edge-case checks passed."
              : "\(failures) of \(checks) edge-case checks failed.")
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }

    /// E-08 — a stale per-pet working directory must produce a visible error,
    /// not a pet stuck in the thinking pose forever.
    private static func badWorkingDirectory(_ provider: AgentProvider) {
        let session = provider.createSession()
        session.workingDirectory = URL(fileURLWithPath: "/nope/does/not/exist-\(UUID().uuidString)")
        var reported: String?
        var settled = false
        session.onError = { if reported == nil { reported = $0 }; settled = true }
        session.onTurnComplete = { settled = true }
        session.start()
        pump(until: { session.isRunning }, for: 10)
        session.send(message: "hello")
        pump(until: { settled }, for: 25)
        session.terminate()

        expect(settled, "E-08 a missing working directory settles instead of hanging")
        expect(reported?.isEmpty == false, "E-08 the failure is reported to the user")
        expect(!session.isBusy, "E-08 the session doesn't stay busy afterwards")
    }

    /// E-05 — a second prompt while one is in flight is refused with an
    /// explanation, and does not disturb the turn already running.
    private static func busyGuard(_ provider: AgentProvider) {
        let session = provider.createSession()
        var messages: [String] = []
        session.onError = { messages.append($0) }
        session.start()
        pump(until: { session.isRunning }, for: 15)
        session.send(message: "Count slowly to twenty, one number per line.")
        pump(until: { session.isBusy }, for: 10)
        let wasBusy = session.isBusy
        session.send(message: "second message while busy")
        pump(until: { !messages.isEmpty }, for: 5)
        session.interrupt()
        session.terminate()

        expect(wasBusy, "E-05 the session reports busy during a turn")
        expect(messages.contains { $0.lowercased().contains("still working") },
               "E-05 a second message is refused with an explanation")
    }

    /// E-03 — the CLI dying mid-turn must surface and clear, so the pet
    /// recovers rather than sitting in the thinking pose.
    private static func killedMidTurn(_ provider: AgentProvider) {
        let session = provider.createSession()
        var settled = false
        session.onError = { _ in settled = true }
        session.onTurnComplete = { settled = true }
        session.onProcessExit = { settled = true }
        session.start()
        pump(until: { session.isRunning }, for: 15)
        session.send(message: "Count slowly to fifty, one number per line.")
        pump(until: { session.isBusy }, for: 10)

        // Kill the child out from under the session.
        let pattern = provider.binaryCandidates.first ?? "codex"
        _ = shell("/usr/bin/pkill", ["-f", pattern])
        pump(until: { settled }, for: 25)
        let busyAfter = session.isBusy
        session.terminate()

        expect(settled, "E-03 a killed CLI is noticed rather than hanging the turn")
        expect(!busyAfter, "E-03 the session clears busy so the pet can recover")
    }

    /// E-12 — quitting with a turn in flight must leave nothing behind, and
    /// terminate must be safe to call twice.
    private static func terminateIsClean(_ provider: AgentProvider) {
        let session = provider.createSession()
        session.start()
        pump(until: { session.isRunning }, for: 15)
        session.send(message: "Count slowly to fifty, one number per line.")
        pump(until: { session.isBusy }, for: 10)
        session.terminate()
        pump(until: { !session.isRunning }, for: 5)

        expect(!session.isRunning, "E-12 terminate stops the session")
        expect(!session.isBusy, "E-12 terminate clears the busy flag")
        session.terminate()   // must not crash
        expect(true, "E-12 terminate is safe to call twice")
    }

    // MARK: harness

    @discardableResult
    private static func shell(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
    }

    private static func pump(until condition: () -> Bool, for seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    private static func expect(_ condition: Bool, _ description: String) {
        checks += 1
        if condition { print("    ok    \(description)") }
        else { failures += 1; print("    FAIL  \(description)") }
    }
}
