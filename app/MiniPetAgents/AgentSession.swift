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

    func start()
    func send(message: String)
    func send(message: String, attachments: [ChatAttachment])
    /// Cancel the in-flight turn (if any) without discarding the conversation.
    /// One-shot providers keep their resume id; the persistent Claude session
    /// restarts its process (its in-CLI context resets).
    func interrupt()
    func terminate()
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
