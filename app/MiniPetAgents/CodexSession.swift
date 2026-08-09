import Foundation

class CodexSession: AgentSession {
    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var lineBuffer = ""
    private(set) var isRunning = false
    private(set) var isBusy = false
    /// Thread id captured from `thread.started`; resuming by explicit id keeps
    /// each pet's conversation separate (resume --last would cross-talk when
    /// multiple Codex pets run at once).
    private var threadId: String?
    private static var binaryPath: String?

    var onText: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onToolUse: ((String, [String: Any]) -> Void)?
    var onToolResult: ((String, Bool) -> Void)?
    var onSessionReady: (() -> Void)?
    var onTurnComplete: (() -> Void)?
    var onProcessExit: (() -> Void)?
    var onUsage: ((String) -> Void)?
    var onProviderCommands: (([String]) -> Void)?

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

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        ShellEnvironment.findBinary(name: "codex", fallbackPaths: [
            "\(home)/.local/bin/codex",
            "\(home)/.npm-global/bin/codex",
            "/usr/local/bin/codex",
            "/opt/homebrew/bin/codex"
        ]) { [weak self] path in
            guard let self = self else { return }
            guard let binaryPath = path else {
                let msg = "Codex CLI not found.\n\n\(AgentProvider.codex.installInstructions)"
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
        guard !isBusy else {
            onError?("Codex is still working on the previous message — please wait.")
            return
        }
        isBusy = true
        history.append(AgentMessage(role: .user, text: message))
        lineBuffer = ""

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)

        // `--full-auto` is deprecated in current Codex; workspace-write is the
        // replacement (auto-run with write access to the working dir). exec is
        // already non-interactive, so no approval flag.
        //
        // Set it via `-c sandbox_mode=` rather than the `--sandbox` flag:
        // `codex exec` accepts `--sandbox`, but `codex exec resume` does NOT
        // and hard-fails with "unexpected argument '--sandbox' found". The
        // `-c` config override is accepted by both, so one form covers the
        // first turn and every follow-up.
        var args: [String]
        if let threadId = threadId {
            args = ["exec", "resume", threadId, "--json", "--skip-git-repo-check"]
        } else {
            args = ["exec", "--json", "--skip-git-repo-check"]
        }
        args += ["-c", "sandbox_mode=\"workspace-write\""]
        if let model = model { args += ["--model", model] }
        args.append(message)
        proc.arguments = args

        proc.currentDirectoryURL = workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser
        proc.environment = ShellEnvironment.processEnvironment(extraPaths: [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".npm-global/bin").path
        ])

        let outPipe = Pipe()
        let errPipe = Pipe()
        // Never let the CLI inherit the app's stdin. An inherited terminal
        // makes Node-based CLIs think they're interactive and try to render a
        // TUI, which blows up with "Raw mode is not supported on the current
        // process.stdin". We only ever want headless output here.
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.process = nil
                // Flush remaining buffer
                if !self.lineBuffer.isEmpty {
                    self.parseLine(self.lineBuffer)
                    self.lineBuffer = ""
                }
                if self.isBusy {
                    self.isBusy = false
                    self.onTurnComplete?()
                }
            }
        }

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let text = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async {
                    self?.processOutput(text)
                }
            }
        }

        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let text = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async {
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
            let msg = "Failed to launch Codex CLI: \(error.localizedDescription)"
            onError?(msg)
            history.append(AgentMessage(role: .error, text: msg))
        }
    }

    func interrupt() {
        guard isBusy, let proc = process else { return }
        // Detach handlers so the kill doesn't fire onTurnComplete; the captured
        // threadId is kept so the next message resumes this conversation.
        proc.terminationHandler = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        proc.terminate()
        process = nil
        lineBuffer = ""
        isBusy = false
    }

    func terminate() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        isRunning = false
        isBusy = false
        threadId = nil
    }

    // MARK: - JSONL Parsing

    private func processOutput(_ text: String) {
        lineBuffer += text
        while let newlineRange = lineBuffer.range(of: "\n") {
            let line = String(lineBuffer[lineBuffer.startIndex..<newlineRange.lowerBound])
            lineBuffer = String(lineBuffer[newlineRange.upperBound...])
            if !line.isEmpty {
                parseLine(line)
            }
        }
    }

    private func parseLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let type = json["type"] as? String ?? ""

        switch type {
        case "thread.started":
            if let tid = json["thread_id"] as? String, !tid.isEmpty {
                threadId = tid
            }

        case "item.started":
            if let item = json["item"] as? [String: Any] {
                let itemType = item["type"] as? String ?? ""
                if itemType == "command_execution" {
                    let command = item["command"] as? String ?? ""
                    history.append(AgentMessage(role: .toolUse, text: "Bash: \(command)"))
                    onToolUse?("Bash", ["command": command])
                }
            }

        case "item.completed":
            if let item = json["item"] as? [String: Any] {
                let itemType = item["type"] as? String ?? ""
                switch itemType {
                case "agent_message":
                    let text = item["text"] as? String ?? ""
                    if !text.isEmpty {
                        history.append(AgentMessage(role: .assistant, text: text))
                        onText?(text)
                    }
                case "command_execution":
                    let status = item["status"] as? String ?? ""
                    let command = item["command"] as? String ?? ""
                    let isError = status == "failed"
                    let summary = command.isEmpty ? status : String(command.prefix(80))
                    history.append(AgentMessage(role: .toolResult, text: isError ? "ERROR: \(summary)" : summary))
                    onToolResult?(summary, isError)
                case "file_change":
                    let path = item["file"] as? String ?? item["path"] as? String ?? "file"
                    history.append(AgentMessage(role: .toolUse, text: "FileChange: \(path)"))
                    onToolUse?("FileChange", ["file_path": path])
                    history.append(AgentMessage(role: .toolResult, text: path))
                    onToolResult?(path, false)
                default:
                    break
                }
            }

        case "turn.completed":
            isBusy = false
            if let usage = json["usage"] as? [String: Any],
               let note = formatUsageNote(inputTokens: usage["input_tokens"] as? Int,
                                          outputTokens: usage["output_tokens"] as? Int,
                                          costUSD: nil) {
                onUsage?(note)
            }
            onTurnComplete?()

        case "turn.failed":
            isBusy = false
            let msg = (json["error"] as? [String: Any])?["message"] as? String
                ?? json["message"] as? String
                ?? "Turn failed"
            onError?(msg)
            history.append(AgentMessage(role: .error, text: msg))
            onTurnComplete?()

        case "error":
            let msg = json["message"] as? String ?? json["error"] as? String ?? "Unknown error"
            onError?(msg)
            history.append(AgentMessage(role: .error, text: msg))

        default:
            break
        }
    }
}
