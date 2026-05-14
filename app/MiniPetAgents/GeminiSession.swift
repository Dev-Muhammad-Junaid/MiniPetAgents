import Foundation

class GeminiSession: AgentSession {
    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
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

        ShellEnvironment.findBinary(name: "gemini", fallbackPaths: []) { [weak self] path in
            guard let self = self else { return }
            guard let binaryPath = path else {
                let msg = "Gemini CLI not found.\n\n\(AgentProvider.gemini.installInstructions)"
                self.onError?(msg)
                self.history.append(AgentMessage(role: .error, text: msg))
                return
            }
            Self.binaryPath = binaryPath
            self.isRunning = true
            self.onSessionReady?()
        }
    }

    func send(message: String) {
        guard isRunning, let binaryPath = Self.binaryPath else { return }
        isBusy = true
        history.append(AgentMessage(role: .user, text: message))
        lineBuffer = ""

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        // Gemini CLI non-interactive mode: gemini -p "<prompt>"
        proc.arguments = ["-p", message]
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
