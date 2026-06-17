import Foundation

class GeminiSession: AgentSession {
    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var lineBuffer = ""
    private(set) var isRunning = false
    private(set) var isBusy = false
    private static var binaryPath: String?

    /// Conversation id recovered from agy's on-disk store
    /// (~/.gemini/antigravity-cli/brain/<id>). Print mode doesn't emit the id
    /// yet (upstream issue #7), so we diff the brain directory before/after the
    /// first turn to learn it, then resume that exact conversation with
    /// `--conversation <id>`. Keeps each pet's thread separate instead of
    /// `--continue`'s global most-recent (which would cross-talk).
    private var conversationId: String?
    private var pendingBrainSnapshot: Set<String>?

    private static let brainDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".gemini/antigravity-cli/brain", isDirectory: true)

    var onText: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onToolUse: ((String, [String: Any]) -> Void)?
    var onToolResult: ((String, Bool) -> Void)?
    var onSessionReady: (() -> Void)?
    var onTurnComplete: (() -> Void)?
    var onProcessExit: (() -> Void)?
    var onUsage: ((String) -> Void)?

    var history: [AgentMessage] = []
    var workingDirectory: URL?
    var model: String?

    // MARK: - Lifecycle

    func start() {
        if Self.binaryPath != nil {
            isRunning = true
            onSessionReady?()
            return
        }

        // Antigravity CLI (agy) replaces Gemini CLI as of Google I/O 2026.
        // Try agy first; fall back to the legacy gemini binary for users
        // who haven't migrated yet (Gemini CLI EOL: June 18 2026).
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let agyFallbacks = [
            "\(home)/.local/bin/agy",
            "\(home)/.antigravity/bin/agy",
            "/usr/local/bin/agy",
            "/opt/homebrew/bin/agy"
        ]

        ShellEnvironment.findBinary(name: "agy", fallbackPaths: agyFallbacks) { [weak self] path in
            guard let self = self else { return }

            if let binaryPath = path {
                Self.binaryPath = binaryPath
                self.isRunning = true
                self.onSessionReady?()
                return
            }

            // agy not found — try legacy gemini binary
            ShellEnvironment.findBinary(name: "gemini", fallbackPaths: []) { [weak self] legacyPath in
                guard let self = self else { return }
                guard let binaryPath = legacyPath else {
                    let msg = "Gemini / Antigravity CLI not found.\n\n\(AgentProvider.gemini.installInstructions)"
                    self.onError?(msg)
                    self.history.append(AgentMessage(role: .error, text: msg))
                    return
                }
                Self.binaryPath = binaryPath
                self.isRunning = true
                self.onSessionReady?()
            }
        }
    }

    func send(message: String) {
        guard isRunning, let binaryPath = Self.binaryPath else { return }
        guard !isBusy else {
            onError?("Gemini is still working on the previous message — please wait.")
            return
        }
        isBusy = true
        history.append(AgentMessage(role: .user, text: message))
        lineBuffer = ""

        // First turn: snapshot existing conversation ids so we can identify the
        // new folder agy creates and resume by id on later turns.
        pendingBrainSnapshot = conversationId == nil ? Self.conversationIds() : nil

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        // Antigravity CLI non-interactive mode. Unlike the other providers, agy
        // is a fully autonomous agent: --dangerously-skip-permissions makes it
        // auto-run an exploration loop (git, dotfiles, web search) on ANY prompt
        // instead of just answering, so we deliberately omit it and let plain
        // `agy -p` reply conversationally. IMPORTANT: -p/--print takes the prompt
        // as its *value*, so it must come last, immediately before the message —
        // any flag placed after -p gets swallowed as the prompt text.
        // --conversation <id> resumes this pet's own thread once its id is known.
        var args: [String] = []
        if let conversationId = conversationId {
            args += ["--conversation", conversationId]
        }
        if let model = model { args += ["--model", model] }
        args += ["-p", message]
        proc.arguments = args
        proc.currentDirectoryURL = workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser
        proc.environment = ShellEnvironment.processEnvironment()

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.process = nil
                let tail = self.lineBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !tail.isEmpty {
                    self.history.append(AgentMessage(role: .assistant, text: tail))
                    self.onText?(tail)
                    self.lineBuffer = ""
                }
                // Recover this pet's conversation id from agy's brain dir so the
                // next turn can resume it (print mode doesn't emit it directly).
                if self.conversationId == nil, let snapshot = self.pendingBrainSnapshot {
                    self.conversationId = Self.newConversationId(excluding: snapshot)
                }
                self.pendingBrainSnapshot = nil
                if self.isBusy {
                    self.isBusy = false
                    self.onTurnComplete?()
                }
                self.onProcessExit?()
            }
        }

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.lineBuffer += text
                while let nl = self.lineBuffer.range(of: "\n") {
                    let line = String(self.lineBuffer[self.lineBuffer.startIndex..<nl.lowerBound])
                    self.lineBuffer = String(self.lineBuffer[nl.upperBound...])
                    self.parseLine(line)
                }
            }
        }

        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self?.onError?(text)
            }
        }

        do {
            try proc.run()
            process = proc
            outputPipe = outPipe
            errorPipe = errPipe
        } catch {
            isBusy = false
            let msg = "Failed to launch Gemini CLI: \(error.localizedDescription)"
            onError?(msg)
            history.append(AgentMessage(role: .error, text: msg))
        }
    }

    func interrupt() {
        guard isBusy, let proc = process else { return }
        // Detach handlers so the kill doesn't fire onTurnComplete; the captured
        // conversationId is kept so the next message resumes this conversation.
        proc.terminationHandler = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        proc.terminate()
        process = nil
        lineBuffer = ""
        pendingBrainSnapshot = nil
        isBusy = false
    }

    func terminate() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        isRunning = false
        isBusy = false
        conversationId = nil
        pendingBrainSnapshot = nil
    }

    // MARK: - Conversation id recovery

    /// Folder names under agy's brain dir = existing conversation ids.
    private static func conversationIds() -> Set<String> {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
                at: brainDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]) else { return [] }
        return Set(entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map { $0.lastPathComponent })
    }

    /// The newest conversation folder that didn't exist before this turn. If
    /// several appeared (concurrent Gemini pets firing their first turn at
    /// once), pick the most recently created — best effort, since print mode
    /// gives us nothing to correlate a folder to a specific process.
    private static func newConversationId(excluding prior: Set<String>) -> String? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
                at: brainDir,
                includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]) else { return nil }
        return entries
            .filter {
                ((try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true)
                && !prior.contains($0.lastPathComponent)
            }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                return a > b
            }
            .first?
            .lastPathComponent
    }

    // MARK: - Output parsing

    private func parseLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Try NDJSON first (Gemini CLI may emit structured output).
        if let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let type = json["type"] as? String ?? ""
            switch type {
            case "text", "message", "assistant":
                let text = json["text"] as? String
                             ?? json["content"] as? String
                             ?? json["message"] as? String
                             ?? ""
                if !text.isEmpty {
                    history.append(AgentMessage(role: .assistant, text: text))
                    onText?(text)
                }
            case "tool_use":
                let toolName = json["name"] as? String ?? "Tool"
                let input = json["input"] as? [String: Any] ?? [:]
                let summary = input["command"] as? String
                              ?? input["file_path"] as? String
                              ?? input.keys.sorted().prefix(3).joined(separator: ", ")
                history.append(AgentMessage(role: .toolUse, text: "\(toolName): \(summary)"))
                onToolUse?(toolName, input)
            case "tool_result":
                let output = json["output"] as? String ?? json["result"] as? String ?? ""
                let isError = json["is_error"] as? Bool ?? false
                let summary = String(output.prefix(80))
                history.append(AgentMessage(role: .toolResult, text: isError ? "ERROR: \(summary)" : summary))
                onToolResult?(output, isError)
            case "done", "complete", "result":
                isBusy = false
                if let result = json["result"] as? String ?? json["text"] as? String, !result.isEmpty {
                    history.append(AgentMessage(role: .assistant, text: result))
                }
                onTurnComplete?()
            case "error":
                let msg = json["message"] as? String ?? json["error"] as? String ?? trimmed
                onError?(msg)
                history.append(AgentMessage(role: .error, text: msg))
            default:
                history.append(AgentMessage(role: .assistant, text: trimmed))
                onText?(trimmed)
            }
            return
        }

        // Plain-text line — stream directly.
        history.append(AgentMessage(role: .assistant, text: trimmed))
        onText?(trimmed)
    }
}
