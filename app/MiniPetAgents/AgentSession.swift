import Foundation
import AppKit

// MARK: - Provider

enum AgentProvider: String, CaseIterable {
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
