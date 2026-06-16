import Foundation

class CursorSession: AgentSession {
    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var lineBuffer = ""
    private(set) var isRunning = false
    private(set) var isBusy = false
    /// Chat id captured from the first turn's `session_id`; used with
    /// `--resume` so follow-up messages keep conversation context.
    private var chatId: String?
    private static var binaryPath: String?

    var onText: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onToolUse: ((String, [String: Any]) -> Void)?
    var onToolResult: ((String, Bool) -> Void)?
    var onSessionReady: (() -> Void)?
    var onTurnComplete: (() -> Void)?
    var onProcessExit: (() -> Void)?

    var history: [AgentMessage] = []
    var workingDirectory: URL?

    // MARK: - Lifecycle

    func start() {
        if Self.binaryPath != nil {
            isRunning = true
            onSessionReady?()
            return
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Cursor CLI installs as `cursor-agent` (and `agent` on newer builds)
        // at ~/.local/bin, via: curl https://cursor.com/install -fsS | bash
        ShellEnvironment.findBinary(name: "cursor-agent", fallbackPaths: [
            "\(home)/.local/bin/cursor-agent",
            "\(home)/.local/bin/agent"
        ]) { [weak self] path in
            guard let self = self else { return }

            if let binaryPath = path {
                Self.binaryPath = binaryPath
                self.isRunning = true
                self.onSessionReady?()
                return
            }

            ShellEnvironment.findBinary(name: "agent", fallbackPaths: [
                "\(home)/.local/bin/agent"
            ]) { [weak self] fallbackPath in
                guard let self = self else { return }
                guard let binaryPath = fallbackPath else {
                    let msg = "Cursor Agent not found.\n\n\(AgentProvider.cursor.installInstructions)"
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
            onError?("Cursor is still working on the previous message — please wait.")
            return
        }
        isBusy = true
        history.append(AgentMessage(role: .user, text: message))
        lineBuffer = ""

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        // Non-interactive print mode with structured NDJSON output.
        // `--resume <chatId>` keeps context across turns; `--force` allows
        // file edits without an interactive approval prompt.
        var args = ["-p", "--output-format", "stream-json", "--force"]
        if let chatId = chatId {
            args += ["--resume", chatId]
        }
        args.append(message)
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
                // Flush any remaining buffered output.
                let tail = self.lineBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !tail.isEmpty {
                    self.parseLine(tail)
                    self.lineBuffer = ""
                }
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
                let lower = text.lowercased()
                if lower.contains("not logged in") || lower.contains("unauthorized") || lower.contains("login required") {
                    self?.onError?("Not logged in to Cursor.\n\nOpen Terminal and run:\n  cursor-agent login\n\nThen come back and chat here.")
                } else {
                    self?.onError?(text)
                }
            }
        }

        do {
            try proc.run()
            process = proc
            outputPipe = outPipe
            errorPipe = errPipe
        } catch {
            isBusy = false
            let msg = "Failed to launch Cursor Agent: \(error.localizedDescription)"
            onError?(msg)
            history.append(AgentMessage(role: .error, text: msg))
        }
    }

    func terminate() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        isRunning = false
        isBusy = false
        chatId = nil
    }

    // MARK: - Output parsing (cursor-agent stream-json)

    private func parseLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Plain-text line — stream directly.
            history.append(AgentMessage(role: .assistant, text: trimmed))
            onText?(trimmed)
            return
        }

        // Every event carries the chat id; capture it for --resume.
        if let sid = json["session_id"] as? String, !sid.isEmpty {
            chatId = sid
        }

        let type = json["type"] as? String ?? ""
        switch type {
        case "system":
            if json["subtype"] as? String == "init" { onSessionReady?() }

        case "assistant":
            // Claude-compatible shape: message.content is an array of blocks.
            if let message = json["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                for block in content {
                    if block["type"] as? String == "text", let text = block["text"] as? String, !text.isEmpty {
                        history.append(AgentMessage(role: .assistant, text: text))
                        onText?(text)
                    }
                }
            }

        case "user":
            break // echo of our own prompt

        case "tool_call":
            let subtype = json["subtype"] as? String ?? ""
            guard let toolCall = json["tool_call"] as? [String: Any],
                  let (name, payload) = toolCall.first(where: { $0.value is [String: Any] })
                    .map({ ($0.key, $0.value as? [String: Any] ?? [:]) }) else { break }
            let toolName = prettyToolName(name)
            if subtype == "started" {
                let args = payload["args"] as? [String: Any] ?? [:]
                let summary = args["command"] as? String
                    ?? args["path"] as? String
                    ?? args["pattern"] as? String
                    ?? args["globPattern"] as? String
                    ?? args.keys.sorted().prefix(3).joined(separator: ", ")
                history.append(AgentMessage(role: .toolUse, text: "\(toolName): \(summary)"))
                onToolUse?(toolName, args)
            } else if subtype == "completed" {
                let result = payload["result"] as? [String: Any] ?? [:]
                let isError = result["success"] == nil && !result.isEmpty
                let summary = isError ? "\(toolName) failed" : toolName
                history.append(AgentMessage(role: .toolResult, text: isError ? "ERROR: \(summary)" : summary))
                onToolResult?(summary, isError)
            }

        case "result":
            isBusy = false
            if let resultText = json["result"] as? String, !resultText.isEmpty,
               history.last?.text != resultText {
                history.append(AgentMessage(role: .assistant, text: resultText))
            }
            onTurnComplete?()

        case "error":
            let msg = json["message"] as? String ?? json["error"] as? String ?? trimmed
            onError?(msg)
            history.append(AgentMessage(role: .error, text: msg))

        default:
            break // ignore unknown structured events instead of dumping raw JSON
        }
    }

    private func prettyToolName(_ key: String) -> String {
        // "shellToolCall" -> "Shell", "readToolCall" -> "Read", etc.
        var name = key
        if name.hasSuffix("ToolCall") { name = String(name.dropLast("ToolCall".count)) }
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}
