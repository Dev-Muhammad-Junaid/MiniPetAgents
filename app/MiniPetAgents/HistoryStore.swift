import Foundation

enum HistoryStore {
    private static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("MiniPetAgents/history", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func load(key: String) -> [AgentMessage] {
        let url = dir.appendingPathComponent(sanitize(key) + ".json")
        guard let data = try? Data(contentsOf: url),
              let messages = try? JSONDecoder().decode([AgentMessage].self, from: data)
        else { return [] }
        return messages
    }

    static func save(key: String, messages: [AgentMessage]) {
        let url = dir.appendingPathComponent(sanitize(key) + ".json")
        guard let data = try? JSONEncoder().encode(messages) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func clear(key: String) {
        let url = dir.appendingPathComponent(sanitize(key) + ".json")
        try? FileManager.default.removeItem(at: url)
    }

    private static func sanitize(_ key: String) -> String {
        key.replacingOccurrences(of: "[^a-zA-Z0-9._-]", with: "_", options: .regularExpression)
    }
}
