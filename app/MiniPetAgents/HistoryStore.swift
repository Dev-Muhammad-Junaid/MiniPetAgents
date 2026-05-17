import Foundation

// MARK: - Session metadata

struct ChatSession {
    let id: String          // ISO8601 timestamp used as filename stem
    let date: Date
    let preview: String     // first user message, truncated
    let messageCount: Int
}

// MARK: - Store

enum HistoryStore {

    // ~/Library/Application Support/MiniPetAgents/history/<key>/<sessionId>.json
    private static func dir(for key: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("MiniPetAgents/history/\(sanitize(key))",
                                              isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Session IDs

    static func newSessionId() -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate,
                             .withColonSeparatorInTime]
        return fmt.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
    }

    // MARK: Load / save

    static func load(key: String, sessionId: String) -> [AgentMessage] {
        let url = dir(for: key).appendingPathComponent(sessionId + ".json")
        guard let data = try? Data(contentsOf: url),
              let msgs = try? JSONDecoder().decode([AgentMessage].self, from: data)
        else { return [] }
        return msgs
    }

    /// Loads the most-recently modified session, for backward-compat on first launch.
    static func loadLatest(key: String) -> (id: String, messages: [AgentMessage])? {
        guard let latest = listSessions(key: key).first else { return nil }
        let msgs = load(key: key, sessionId: latest.id)
        return (latest.id, msgs)
    }

    static func save(key: String, sessionId: String, messages: [AgentMessage]) {
        let url = dir(for: key).appendingPathComponent(sessionId + ".json")
        guard let data = try? JSONEncoder().encode(messages) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func delete(key: String, sessionId: String) {
        let url = dir(for: key).appendingPathComponent(sessionId + ".json")
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: List sessions (newest first)

    static func listSessions(key: String) -> [ChatSession] {
        let d = dir(for: key)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: d, includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles)
        else { return [] }

        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> ChatSession? in
                let id = url.deletingPathExtension().lastPathComponent
                let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                let date = attrs?.contentModificationDate ?? Date.distantPast
                guard let data = try? Data(contentsOf: url),
                      let msgs = try? JSONDecoder().decode([AgentMessage].self, from: data)
                else { return nil }
                let preview = msgs.first(where: { $0.role == .user })?.text
                    .prefix(60).description ?? "Empty session"
                return ChatSession(id: id, date: date, preview: preview,
                                   messageCount: msgs.count)
            }
            .sorted { $0.date > $1.date }
    }

    // MARK: Helpers

    private static func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: "[^a-zA-Z0-9._-]", with: "_", options: .regularExpression)
    }
}
