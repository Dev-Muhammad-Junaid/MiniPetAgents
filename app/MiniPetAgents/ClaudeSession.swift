import Foundation

class ClaudeSession: AgentSession {
    private var process: Process?
    private var inputPipe: Pipe?
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
    var onUsage: ((String) -> Void)?
    var onProviderCommands: (([String]) -> Void)?

    var history: [AgentMessage] = []   // satisfies { get set } protocol requirement
    var workingDirectory: URL?
    var model: String?

    // MARK: - Process Lifecycle

    func start() {
        if let cached = Self.binaryPath {
            launchProcess(binaryPath: cached)
            return
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        ShellEnvironment.findBinary(name: "claude", fallbackPaths: [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/bin/claude",
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude"
        ]) { [weak self] path in
            guard let self = self else { return }
            guard let binaryPath = path else {
                let msg = "Claude CLI not found.\n\n\(AgentProvider.claude.installInstructions)"
                self.onError?(msg)
                self.history.append(AgentMessage(role: .error, text: msg))
                return
            }
            Self.binaryPath = binaryPath
            self.launchProcess(binaryPath: binaryPath)
        }
    }

    private func launchProcess(binaryPath: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        var args = [
            "-p",
            "--output-format", "stream-json",
            "--input-format", "stream-json",
            "--verbose",
            "--dangerously-skip-permissions"
        ]
        if let model = model { args += ["--model", model] }
        proc.arguments = args
        proc.currentDirectoryURL = workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser
        proc.environment = ShellEnvironment.processEnvironment()

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.isRunning = false
                self?.isBusy = false
                self?.onProcessExit?()
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
                    let lower = text.lowercased()
                    if lower.contains("not logged in") || lower.contains("please run /login") || lower.contains("unauthenticated") {
                        let msg = "Not logged in to Claude.\n\nOpen Terminal and run:\n  claude\n\nComplete the login prompt, then come back and chat here."
                        self?.onError?(msg)
                    } else {
                        self?.onError?(text)
                    }
                }
            }
        }

        do {
            try proc.run()
            process = proc
            inputPipe = inPipe
            outputPipe = outPipe
            errorPipe = errPipe
            isRunning = true
        } catch {
            let msg = "Failed to launch Claude CLI.\n\n\(AgentProvider.claude.installInstructions)\n\nError: \(error.localizedDescription)"
            onError?(msg)
            history.append(AgentMessage(role: .error, text: msg))
        }
    }

    func send(message: String) {
        send(message: message, attachments: [])
    }

    func send(message: String, attachments: [ChatAttachment]) {
        guard isRunning, let pipe = inputPipe else { return }
        isBusy = true
        history.append(AgentMessage(role: .user, text: message))

        // Build content: plain string for text-only, content-block array when attachments present.
        let content: Any
        if attachments.isEmpty {
            content = message
        } else {
            var blocks: [[String: Any]] = []
            for att in attachments {
                switch att.kind {
                case .image(_, let png, let mediaType):
                    blocks.append([
                        "type": "image",
                        "source": ["type": "base64", "media_type": mediaType,
                                   "data": png.base64EncodedString()]
                    ])
                case .text(let fileContent):
                    blocks.append(["type": "text", "text": "[\(att.filename)]\n\(fileContent)"])
                }
            }
            blocks.append(["type": "text", "text": message])
            content = blocks
        }

        let payload: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": content]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let jsonStr = String(data: data, encoding: .utf8),
              let lineData = (jsonStr + "\n").data(using: .utf8) else { return }
        // Writing to a dead process raises an ObjC exception; guard + try.
        guard process?.isRunning == true else {
            isBusy = false
            onError?("Claude process is not running. Start a new chat to reconnect.")
            return
        }
        do {
            try pipe.fileHandleForWriting.write(contentsOf: lineData)
        } catch {
            isBusy = false
            onError?("Failed to send message: \(error.localizedDescription)")
        }
    }

    func interrupt() {
        guard isBusy else { return }
        // stream-json input mode has no per-turn cancel, so restart the process.
        // The in-CLI context resets; the transcript is preserved by the caller.
        if let proc = process {
            proc.terminationHandler = nil
            outputPipe?.fileHandleForReading.readabilityHandler = nil
            errorPipe?.fileHandleForReading.readabilityHandler = nil
            proc.terminate()
        }
        process = nil
        inputPipe = nil
        lineBuffer = ""
        isBusy = false
        isRunning = false
        if let path = Self.binaryPath {
            launchProcess(binaryPath: path)   // fresh pipes; keeps workingDirectory
        }
    }

    func terminate() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        inputPipe = nil
        isRunning = false
        isBusy = false
    }

    // MARK: - NDJSON Parsing

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
        case "system":
            let subtype = json["subtype"] as? String ?? ""
            if subtype == "init" {
                onSessionReady?()
                // The init handshake lists every available slash command
                // (built-in + custom + skills) for this version/session.
                if let cmds = json["slash_commands"] as? [String], !cmds.isEmpty {
                    onProviderCommands?(cmds)
                }
            }

        case "assistant":
            if let message = json["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                for block in content {
                    let blockType = block["type"] as? String ?? ""
                    if blockType == "text", let text = block["text"] as? String {
                        onText?(text)
                    } else if blockType == "tool_use" {
                        let toolName = block["name"] as? String ?? "Tool"
                        let input = block["input"] as? [String: Any] ?? [:]
                        let summary = formatToolSummary(toolName: toolName, input: input)
                        history.append(AgentMessage(role: .toolUse, text: "\(toolName): \(summary)"))
                        onToolUse?(toolName, input)
                    }
                }
            }

        case "user":
            if let message = json["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                for block in content {
                    if block["type"] as? String == "tool_result" {
                        let isError = block["is_error"] as? Bool ?? false
                        var summary = ""
                        if let resultInfo = json["tool_use_result"] as? [String: Any] {
                            if let text = resultInfo["type"] as? String, text == "text" {
                                if let file = resultInfo["file"] as? [String: Any],
                                   let path = file["filePath"] as? String {
                                    let lines = file["totalLines"] as? Int ?? 0
                                    summary = "\(path) (\(lines) lines)"
                                }
                            }
                        } else if let resultStr = json["tool_use_result"] as? String {
                            summary = String(resultStr.prefix(80))
                        }
                        if summary.isEmpty {
                            if let contentStr = block["content"] as? String {
                                summary = String(contentStr.prefix(80))
                            }
                        }
                        history.append(AgentMessage(role: .toolResult, text: isError ? "ERROR: \(summary)" : summary))
                        onToolResult?(summary, isError)
                    }
                }
            }

        case "result":
            isBusy = false
            if let result = json["result"] as? String, !result.isEmpty {
                let lower = result.lowercased()
                if lower.contains("not logged in") || lower.contains("please run /login") || lower.contains("unauthenticated") {
                    let msg = "Not logged in to Claude.\n\nOpen Terminal and run:\n  claude\n\nComplete the login prompt, then come back and chat here."
                    history.append(AgentMessage(role: .error, text: msg))
                    onError?(msg)
                } else {
                    history.append(AgentMessage(role: .assistant, text: result))
                }
            }
            let usage = json["usage"] as? [String: Any]
            if let note = formatUsageNote(inputTokens: usage?["input_tokens"] as? Int,
                                          outputTokens: usage?["output_tokens"] as? Int,
                                          costUSD: json["total_cost_usd"] as? Double) {
                onUsage?(note)
            }
            onTurnComplete?()

        default:
            break
        }
    }

    private func formatToolSummary(toolName: String, input: [String: Any]) -> String {
        switch toolName {
        case "Bash":
            return input["command"] as? String ?? ""
        case "Read":
            return input["file_path"] as? String ?? ""
        case "Edit", "Write":
            return input["file_path"] as? String ?? ""
        case "Glob":
            return input["pattern"] as? String ?? ""
        case "Grep":
            return input["pattern"] as? String ?? ""
        default:
            if let desc = input["description"] as? String { return desc }
            return input.keys.sorted().prefix(3).joined(separator: ", ")
        }
    }
}
