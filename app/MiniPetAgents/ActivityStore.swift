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
    enum Remedy: Equatable {
        case signIn(AgentProvider)

        var title: String {
            switch self {
            case .signIn: return "Sign in"
            }
        }
    }

    struct Record: Identifiable, Equatable {
        enum State: Equatable { case live, done, failed }

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
            case .live:   return "Thinking"
            case .done:   return toolCalls == 0 ? "Replied" : "\(toolCalls) tool calls"
            case .failed: return failure ?? "Failed"
            }
        }
    }

    /// Newest first. Capped so a long session doesn't grow without bound.
    private(set) var records: [Record] = []
    private static let cap = 200

    private init() {}

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
        NotificationCenter.default.post(name: Self.didChange, object: nil)
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
