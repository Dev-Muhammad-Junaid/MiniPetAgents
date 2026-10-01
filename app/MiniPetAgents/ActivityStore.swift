import Foundation

/// Every pet's turns in one place, newest first.
///
/// This is the one view the app can offer that a terminal cannot: four agents
/// working in four directories, and a single answer to "what is everyone doing
/// and what has it cost me". Per-agent spend in particular is invisible
/// anywhere else — run four CLIs in four tabs and nothing adds them up.
///
/// The store deliberately records only what the CLI actually told us. A turn
/// with no tool activity says so rather than being given an invented
/// description; the feed's whole credibility rests on never making things up.
final class ActivityStore {
    static let shared = ActivityStore()
    static let didChange = Notification.Name("ActivityStoreDidChange")

    /// Something the user can do about a failure, offered inline in the feed
    /// so they don't have to go hunting for the pet that failed.
    enum Remedy: Equatable, Codable {
        case signIn(AgentProvider)

        var title: String {
            switch self {
            case .signIn: return "Sign in"
            }
        }
    }

    struct Record: Identifiable, Equatable, Codable {
        /// `interrupted` is its own state rather than a flavour of `failed`.
        /// A turn that was still running when the app quit did not fail — we
        /// simply never found out how it ended, and saying "failed" would be a
        /// small lie that the feed cannot justify.
        enum State: String, Equatable, Codable { case live, done, failed, interrupted }

        let id: UUID
        let petSlug: String
        let provider: AgentProvider
        var state: State
        let startedAt: Date
        var endedAt: Date?

        /// Last tool the CLI reported, and its target. Kept separate so the
        /// view composes the line — the store never writes prose.
        var lastTool: String?
        var lastToolDetail: String?
        var toolCalls: Int

        /// The provider's own usage line, stored verbatim. We don't reformat
        /// or re-derive it; if a provider reports nothing, we show nothing
        /// rather than guessing at a number.
        var usageNote: String?
        var failure: String?
        var remedy: Remedy?

        var duration: TimeInterval { (endedAt ?? Date()).timeIntervalSince(startedAt) }

        /// What this turn is doing, in the CLI's own terms.
        var activity: String {
            if let tool = lastTool {
                if let detail = lastToolDetail, !detail.isEmpty { return "\(tool) · \(detail)" }
                return tool
            }
            switch state {
            case .live:        return "Thinking"
            case .done:        return toolCalls == 0 ? "Replied" : "\(toolCalls) tool calls"
            case .failed:      return failure ?? "Failed"
            case .interrupted: return "Interrupted — the app quit mid-turn"
            }
        }
    }

    /// Newest first. Capped so a long session doesn't grow without bound.
    private(set) var records: [Record] = []
    private static let cap = 200

    private init() {
        records = Self.settleStaleTurns(Self.loadFromDisk())
    }

    /// Anything still marked live on load belongs to a process that no longer
    /// exists. Settle it rather than leaving a turn spinning forever in the
    /// feed. Static and pure so it can be exercised headlessly.
    static func settleStaleTurns(_ input: [Record]) -> [Record] {
        var out = input
        for i in out.indices where out[i].state == .live {
            out[i].state = .interrupted
            out[i].endedAt = out[i].endedAt ?? out[i].startedAt
        }
        return out
    }

    /// Drop turns past the retention window.
    static func prune(_ input: [Record], now: Date = Date()) -> [Record] {
        let cutoff = now.addingTimeInterval(-retention)
        return input.filter { $0.startedAt >= cutoff }
    }

    // MARK: Writing

    func beginTurn(petSlug: String, provider: AgentProvider) -> UUID {
        let record = Record(id: UUID(), petSlug: petSlug, provider: provider,
                            state: .live, startedAt: Date(), endedAt: nil,
                            lastTool: nil, lastToolDetail: nil, toolCalls: 0,
                            usageNote: nil, failure: nil, remedy: nil)
        records.insert(record, at: 0)
        if records.count > Self.cap { records.removeLast(records.count - Self.cap) }
        announce()
        return record.id
    }

    func noteTool(_ name: String, detail: String?, for id: UUID) {
        mutate(id) {
            $0.lastTool = name
            $0.lastToolDetail = detail
            $0.toolCalls += 1
        }
    }

    func noteUsage(_ note: String, for id: UUID) {
        mutate(id) { $0.usageNote = note }
    }

    func complete(_ id: UUID) {
        mutate(id) {
            guard $0.state == .live else { return }
            $0.state = .done
            $0.endedAt = Date()
        }
    }

    /// A failed turn carries its own fix where we can identify one, so the feed
    /// is actionable rather than just a list of things that went wrong.
    func fail(_ id: UUID, message: String, provider: AgentProvider) {
        mutate(id) {
            $0.state = .failed
            $0.endedAt = Date()
            $0.failure = Self.shortFailure(message)
            $0.remedy = looksLikeAuthFailure(message) ? .signIn(provider) : nil
        }
    }

    func clear() {
        records.removeAll()
        announce()
        flush()
    }

    // MARK: Reading

    /// Turns still running, newest first — these are what the feed floats up.
    var live: [Record] { records.filter { $0.state == .live } }

    /// Totals across every agent in the window, which is the number no single
    /// terminal can show you.
    func totals(since interval: TimeInterval = 1_200) -> (turns: Int, failures: Int) {
        let cutoff = Date().addingTimeInterval(-interval)
        let recent = records.filter { $0.startedAt >= cutoff }
        return (recent.count, recent.filter { $0.state == .failed }.count)
    }

    // MARK: Internals

    private func mutate(_ id: UUID, _ change: (inout Record) -> Void) {
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[idx])
        announce()
    }

    private func announce() {
        scheduleSave()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    // MARK: Persistence

    // ~/Library/Application Support/MiniPetAgents/activity.json
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("MiniPetAgents", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("activity.json")
    }

    /// Turns older than this are dropped on save. "What did everyone do
    /// yesterday" is worth keeping; what they did last month is not, and an
    /// unbounded file would be read on every launch.
    static let retention: TimeInterval = 14 * 24 * 60 * 60

    private var saveWork: DispatchWorkItem?

    /// Coalesced: a busy turn fires noteTool several times a second and each
    /// one would otherwise rewrite the whole file.
    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveToDisk() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    /// Write now, without waiting for the coalescing window — used on quit.
    func flush() {
        saveWork?.cancel()
        saveWork = nil
        saveToDisk()
    }

    private func saveToDisk() {
        guard let data = try? JSONEncoder().encode(Self.prune(records)) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    private static func loadFromDisk() -> [Record] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Record].self, from: data)
        else { return [] }
        // Newest first is an invariant the whole feed relies on; don't trust
        // the file to have preserved it.
        return Array(decoded.sorted { $0.startedAt > $1.startedAt }.prefix(cap))
    }

    /// First line only, trimmed — a failure row has one line of space and a
    /// stack trace in the feed helps nobody.
    static func shortFailure(_ message: String) -> String {
        let line = message
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? "Failed"
        return String(line.prefix(90))
    }
}
