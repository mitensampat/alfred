import Foundation

// MARK: - Conversation Context Management

/// Manages conversation context for multi-turn intent recognition and general chat
class ConversationContext {
    /// Shared singleton — all request handlers use the same context store
    static let shared = ConversationContext()

    private var sessions: [String: ConversationSession] = [:]
    private let maxSessionAge: TimeInterval = 7200 // 2 hours

    /// Get or create a conversation session
    func getSession(for sessionId: String) -> ConversationSession {
        // Clean up old sessions
        cleanupExpiredSessions()

        if let session = sessions[sessionId] {
            return session
        }

        let newSession = ConversationSession(id: sessionId)
        sessions[sessionId] = newSession
        return newSession
    }

    /// Add a turn to the conversation (intent-matched)
    func addTurn(sessionId: String, query: String, intent: UserIntent, result: IntentExecutionResult?) {
        let session = getSession(for: sessionId)
        session.addTurn(query: query, intent: intent, result: result)
    }

    /// Add a general chat turn (no intent match — free-form Q&A)
    func addChatTurn(sessionId: String, userMessage: String, assistantResponse: String) {
        let session = getSession(for: sessionId)
        session.addChatTurn(userMessage: userMessage, assistantResponse: assistantResponse)
    }

    /// Get the full conversation as Claude API messages array (user/assistant pairs)
    func getMessagesArray(for sessionId: String, limit: Int = 20) -> [[String: String]] {
        guard let session = sessions[sessionId] else { return [] }
        return session.buildMessagesArray(limit: limit)
    }

    /// Get recent context for a session
    func getRecentContext(for sessionId: String, limit: Int = 3) -> [ConversationTurn] {
        guard let session = sessions[sessionId] else { return [] }
        return session.getRecentTurns(limit: limit)
    }

    /// Restore a session from persisted conversation history
    /// Re-injects turns into in-memory context so Claude has full history on resume
    func restoreSession(id: String, from records: [ConversationTurnRecord]) {
        // Clear any stale session with this ID
        sessions.removeValue(forKey: id)

        let session = ConversationSession(id: id)

        // Walk records pairwise: user message + assistant response
        var i = 0
        while i < records.count {
            let record = records[i]
            if record.role == "user" {
                // Look for the next assistant response
                let userMessage = record.content
                var assistantResponse = ""
                if i + 1 < records.count && records[i + 1].role == "assistant" {
                    assistantResponse = records[i + 1].content
                    i += 2
                } else {
                    i += 1
                }
                if !assistantResponse.isEmpty {
                    session.addChatTurn(userMessage: userMessage, assistantResponse: assistantResponse)
                }
            } else {
                // Orphan assistant message — skip
                i += 1
            }
        }

        sessions[id] = session
        print("🔄 [Context] Restored session \(id) with \(session.turns.count) turns")
    }

    /// Clear a specific session
    func clearSession(_ sessionId: String) {
        sessions.removeValue(forKey: sessionId)
    }

    /// Clear all sessions
    func clearAllSessions() {
        sessions.removeAll()
    }

    private func cleanupExpiredSessions() {
        let now = Date()
        sessions = sessions.filter { _, session in
            now.timeIntervalSince(session.lastActivity) < maxSessionAge
        }
    }
}

// MARK: - Conversation Session

/// A single conversation session with history
class ConversationSession: Codable {
    let id: String
    private(set) var turns: [ConversationTurn]
    private(set) var lastActivity: Date
    private(set) var entities: [String: EntityReference]
    private let maxTurns = 50

    init(id: String) {
        self.id = id
        self.turns = []
        self.lastActivity = Date()
        self.entities = [:]
    }

    func addTurn(query: String, intent: UserIntent, result: IntentExecutionResult?) {
        let turn = ConversationTurn(query: query, intent: intent, result: result)
        turns.append(turn)
        lastActivity = Date()

        // Extract and store entity references
        updateEntities(from: intent, result: result)

        // Keep only recent turns
        if turns.count > maxTurns {
            turns.removeFirst()
        }
    }

    /// Add a general chat turn (no structured intent)
    func addChatTurn(userMessage: String, assistantResponse: String) {
        let turn = ConversationTurn(chatQuery: userMessage, chatResponse: assistantResponse)
        turns.append(turn)
        lastActivity = Date()

        // Keep only recent turns
        if turns.count > maxTurns {
            turns.removeFirst()
        }
    }

    func getRecentTurns(limit: Int) -> [ConversationTurn] {
        Array(turns.suffix(limit))
    }

    func getEntity(key: String) -> EntityReference? {
        entities[key]
    }

    /// Build a Claude API messages array from conversation history
    /// Returns alternating user/assistant messages for multi-turn chat
    func buildMessagesArray(limit: Int) -> [[String: String]] {
        let recentTurns = Array(turns.suffix(limit))
        var messages: [[String: String]] = []

        for turn in recentTurns {
            // User message
            messages.append(["role": "user", "content": turn.query])

            // Assistant response (from result summary or chat response)
            if let response = turn.resultSummary, !response.isEmpty {
                messages.append(["role": "assistant", "content": response])
            }
        }

        return messages
    }

    private func updateEntities(from intent: UserIntent, result: IntentExecutionResult?) {
        // Store contact names
        if let contactName = intent.filters.contactName {
            entities["last_contact"] = EntityReference(
                type: "contact",
                value: contactName,
                timestamp: Date()
            )
        }

        // Store dates
        if let date = intent.filters.specificDate {
            entities["last_date"] = EntityReference(
                type: "date",
                value: date,
                timestamp: Date()
            )
        }

        // Store platforms
        if let platform = intent.filters.platform {
            entities["last_platform"] = EntityReference(
                type: "platform",
                value: platform.rawValue,
                timestamp: Date()
            )
        }

        // Store result references
        if let result = result {
            entities["last_result_type"] = EntityReference(
                type: "result",
                value: String(describing: type(of: result.data)),
                timestamp: Date()
            )
        }
    }
}

// MARK: - Conversation Turn

/// A single turn in a conversation
struct ConversationTurn: Codable {
    let query: String
    let intent: UserIntent?
    let timestamp: Date
    let resultSummary: String?

    /// Init for intent-matched turns
    init(query: String, intent: UserIntent, result: IntentExecutionResult?) {
        self.query = query
        self.intent = intent
        self.timestamp = Date()
        self.resultSummary = result?.conversationalResponse
    }

    /// Init for general chat turns (no structured intent)
    init(chatQuery: String, chatResponse: String) {
        self.query = chatQuery
        self.intent = nil
        self.timestamp = Date()
        self.resultSummary = chatResponse
    }
}

// MARK: - Entity Reference

/// A reference to an entity mentioned in conversation
struct EntityReference: Codable {
    let type: String           // "contact", "date", "platform", etc.
    let value: Any
    let timestamp: Date

    enum CodingKeys: String, CodingKey {
        case type, valueString, valueDate, timestamp
    }

    init(type: String, value: Any, timestamp: Date) {
        self.type = type
        self.value = value
        self.timestamp = timestamp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        timestamp = try container.decode(Date.self, forKey: .timestamp)

        // Try different value types
        if let stringValue = try? container.decode(String.self, forKey: .valueString) {
            value = stringValue
        } else if let dateValue = try? container.decode(Date.self, forKey: .valueDate) {
            value = dateValue
        } else {
            value = ""
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(timestamp, forKey: .timestamp)

        if let stringValue = value as? String {
            try container.encode(stringValue, forKey: .valueString)
        } else if let dateValue = value as? Date {
            try container.encode(dateValue, forKey: .valueDate)
        }
    }
}

// MARK: - Context Builder

/// Builds context strings for intent recognition prompts
struct ContextBuilder {
    static func buildContextString(from turns: [ConversationTurn]) -> String {
        guard !turns.isEmpty else { return "" }

        var context = "\n\nRecent conversation context:\n"

        for (index, turn) in turns.enumerated() {
            let timeAgo = formatTimeAgo(turn.timestamp)
            context += "\n\(index + 1). User: \"\(turn.query)\""

            if let intent = turn.intent {
                let targetStr = intent.target?.rawValue ?? "unknown"
                context += "\n   Intent: \(intent.action.rawValue) → \(targetStr)"

                if let contactName = intent.filters.contactName {
                    context += " (contact: \(contactName))"
                }
            } else {
                context += "\n   (general chat)"
            }

            if let summary = turn.resultSummary {
                let truncated = String(summary.prefix(200))
                context += "\n   Result: \(truncated)\(summary.count > 200 ? "..." : "")"
            }

            context += " (\(timeAgo))"
        }

        context += "\n\nUse this context to resolve references like 'that meeting', 'them', 'yesterday', etc."

        return context
    }

    static func buildEntityHints(from session: ConversationSession) -> String {
        let entities = [
            ("last_contact", "Recent contact"),
            ("last_date", "Recent date"),
            ("last_platform", "Recent platform")
        ]

        var hints: [String] = []

        for (key, label) in entities {
            if let entity = session.getEntity(key: key) {
                if let stringValue = entity.value as? String {
                    hints.append("\(label): \(stringValue)")
                } else if let dateValue = entity.value as? Date {
                    let formatter = DateFormatter()
                    formatter.dateStyle = .medium
                    hints.append("\(label): \(formatter.string(from: dateValue))")
                }
            }
        }

        guard !hints.isEmpty else { return "" }

        return "\n\nEntity context:\n" + hints.joined(separator: "\n")
    }

    private static func formatTimeAgo(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)

        if seconds < 60 {
            return "just now"
        } else if seconds < 3600 {
            return "\(Int(seconds / 60))m ago"
        } else if seconds < 86400 {
            return "\(Int(seconds / 3600))h ago"
        } else {
            return "\(Int(seconds / 86400))d ago"
        }
    }
}
