import Foundation

class CursorSession: AgentSession {
    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var inputPipe: Pipe?
    private var lineBuffer = ""
    private(set) var isRunning = false
    private(set) var isBusy = false
    private static var binaryPath: String?

    var onText: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onToolUse: ((String, [String: Any]) -> Void)?
    var onToolResult: ((String, Bool) -> Void)?
    var onSessionReady: (() -> Void)?
    var onTurnComplete: (() -> Void)?
    var onProcessExit: (() -> Void)?

    var history: [AgentMessage] = []

    // MARK: - Lifecycle

    func start() {
        if Self.binaryPath != nil {
            isRunning = true
            onSessionReady?()
            return
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Cursor Agent installs as `agent` (primary) and `cursor-agent` (legacy)
        // at ~/.local/bin, via: curl https://cursor.com/install -fsS | bash
        ShellEnvironment.findBinary(name: "agent", fallbackPaths: [
            "\(home)/.local/bin/agent",
            "\(home)/.local/bin/cursor-agent"
        ]) { [weak self] path in
            guard let self = self else { return }

            if let binaryPath = path {
                Self.binaryPath = binaryPath
                self.isRunning = true
                self.onSessionReady?()
                return
            }

            // agent not found — try cursor-agent explicitly
            ShellEnvironment.findBinary(name: "cursor-agent", fallbackPaths: [
                "\(home)/.local/bin/cursor-agent"
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
        isBusy = true
        history.append(AgentMessage(role: .user, text: message))
        lineBuffer = ""

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        // Cursor Agent runs as a one-shot command — pass the prompt as a
        // positional argument. The agent writes its response to stdout and
        // exits when done.
        proc.arguments = [message]
        proc.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
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
                    self.history.append(AgentMessage(role: .assistant, text: tail))
                    self.onText?(tail)
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
                // Parse NDJSON line by line; fall back to plain text per line.
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
    }

    // MARK: - Output parsing

    private func parseLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Try structured JSON first (in case agent emits JSON lines).
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
                // Unknown JSON — surface raw line as text so nothing is silently lost.
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
