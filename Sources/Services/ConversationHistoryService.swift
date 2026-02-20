import Foundation

// MARK: - Conversation History Models

struct ConversationRecord: Codable {
    let id: String
    var title: String
    var summary: String
    let createdAt: Date
    var lastActiveAt: Date
    var turnCount: Int
    var turns: [ConversationTurnRecord]
    var isClosed: Bool
}

struct ConversationTurnRecord: Codable {
    let role: String      // "user" or "assistant"
    let content: String   // truncated at 2000 chars
    let timestamp: Date
}

// MARK: - Conversation History Service

/// Persists coaching conversations to ~/.alfred/conversations.json
/// Enables "Past Conversations" in the Chat tab — users can see and resume previous chats
class ConversationHistoryService {

    static let shared = ConversationHistoryService()

    private let filePath: String
    private let fileLock = NSLock()
    private let fileManager = FileManager.default

    private let maxConversations = 30
    private let maxTurnsPerConversation = 20
    private let maxContentLength = 2000

    private var conversations: [ConversationRecord] = []

    init() {
        let homeDir = NSHomeDirectory()
        self.filePath = "\(homeDir)/.alfred/conversations.json"
        loadFromDisk()
    }

    // MARK: - Read Operations

    /// Get recent conversations (sorted by lastActiveAt desc), excluding turns for lightweight listing
    func getConversations(limit: Int = 20) -> [[String: Any]] {
        fileLock.lock()
        defer { fileLock.unlock() }

        let sorted = conversations
            .sorted { $0.lastActiveAt > $1.lastActiveAt }
            .prefix(limit)

        return sorted.map { conv in
            [
                "id": conv.id,
                "title": conv.title,
                "summary": conv.summary,
                "createdAt": ISO8601DateFormatter().string(from: conv.createdAt),
                "lastActiveAt": ISO8601DateFormatter().string(from: conv.lastActiveAt),
                "turnCount": conv.turnCount,
                "isClosed": conv.isClosed
            ] as [String: Any]
        }
    }

    /// Get a single conversation with full turns (for resume rendering)
    func getConversation(id: String) -> ConversationRecord? {
        fileLock.lock()
        defer { fileLock.unlock() }
        return conversations.first { $0.id == id }
    }

    // MARK: - Write Operations

    /// Add a turn to a conversation. Creates the record if it doesn't exist.
    func addTurn(sessionId: String, role: String, content: String) {
        fileLock.lock()
        defer { fileLock.unlock() }

        let truncatedContent = String(content.prefix(maxContentLength))
        let turn = ConversationTurnRecord(
            role: role,
            content: truncatedContent,
            timestamp: Date()
        )

        if let index = conversations.firstIndex(where: { $0.id == sessionId }) {
            conversations[index].turns.append(turn)
            conversations[index].lastActiveAt = Date()
            conversations[index].turnCount = conversations[index].turns.count

            // Cap turns
            if conversations[index].turns.count > maxTurnsPerConversation {
                let excess = conversations[index].turns.count - maxTurnsPerConversation
                conversations[index].turns.removeFirst(excess)
            }
        } else {
            // Create new conversation record
            let firstUserContent = role == "user" ? truncatedContent : "New conversation"
            let title = String(firstUserContent.prefix(50))

            let record = ConversationRecord(
                id: sessionId,
                title: title,
                summary: "",
                createdAt: Date(),
                lastActiveAt: Date(),
                turnCount: 1,
                turns: [turn],
                isClosed: false
            )
            conversations.append(record)

            // Evict oldest if over limit
            evictIfNeeded()
        }

        saveToDisk()
    }

    /// Close a conversation and generate title + summary via Claude
    func closeConversation(id: String, aiConfig: Any?) async {
        fileLock.lock()
        guard let index = conversations.firstIndex(where: { $0.id == id }) else {
            fileLock.unlock()
            return
        }

        // Already closed? Skip
        if conversations[index].isClosed {
            fileLock.unlock()
            return
        }

        let conv = conversations[index]
        conversations[index].isClosed = true
        fileLock.unlock()

        // Only generate title/summary if there were at least 2 turns (1 exchange)
        guard conv.turns.count >= 2 else {
            saveToDiskSafe()
            return
        }

        // Build conversation text for Claude
        let turnsText = conv.turns.prefix(10).map { turn in
            let role = turn.role == "user" ? "User" : "Coach"
            let content = String(turn.content.prefix(500))
            return "\(role): \(content)"
        }.joined(separator: "\n")

        let prompt = """
        Given this coaching conversation, generate a title and summary.

        \(turnsText)

        Return ONLY valid JSON (no markdown fences):
        {"title": "3-5 word topic title", "summary": "1 sentence summary of what was discussed"}
        """

        // Use Claude Haiku for fast, cheap generation
        do {
            if let config = aiConfig as? AIConfig {
                let claudeService = ClaudeAIService(config: config)
                let response = try await claudeService.generateText(
                    prompt: prompt,
                    system: "You generate concise titles and summaries for coaching conversations. Return only JSON.",
                    maxTokens: 150,
                    useModel: "claude-haiku-4-5-20251001"
                )

                // Strip markdown code fences if present
                var cleanResponse = response.trimmingCharacters(in: .whitespacesAndNewlines)
                if cleanResponse.hasPrefix("```") {
                    // Remove opening fence (```json or ```)
                    if let firstNewline = cleanResponse.firstIndex(of: "\n") {
                        cleanResponse = String(cleanResponse[cleanResponse.index(after: firstNewline)...])
                    }
                    // Remove closing fence
                    if cleanResponse.hasSuffix("```") {
                        cleanResponse = String(cleanResponse.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }

                // Parse JSON response
                if let jsonData = cleanResponse.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                    let title = json["title"] as? String ?? conv.title
                    let summary = json["summary"] as? String ?? ""

                    fileLock.lock()
                    if let idx = conversations.firstIndex(where: { $0.id == id }) {
                        conversations[idx].title = title
                        conversations[idx].summary = summary
                    }
                    fileLock.unlock()

                    print("📝 [Conversations] Closed '\(title)' — \(conv.turnCount) turns")
                } else {
                    print("⚠️ [Conversations] Failed to parse Haiku JSON response")
                }
            } else {
                print("⚠️ [Conversations] No AI config available for title generation (type: \(String(describing: type(of: aiConfig))))")
            }
        } catch {
            print("⚠️ [Conversations] Title generation failed for \(id): \(error)")
        }

        saveToDiskSafe()
    }

    /// Delete a conversation permanently
    func deleteConversation(id: String) -> Bool {
        fileLock.lock()
        defer { fileLock.unlock() }

        if let index = conversations.firstIndex(where: { $0.id == id }) {
            conversations.remove(at: index)
            saveToDisk()
            return true
        }
        return false
    }

    // MARK: - Restore (for ConversationContext re-injection)

    /// Get turns for a conversation (used by restore endpoint to re-inject into ConversationContext)
    func getTurns(for id: String) -> [ConversationTurnRecord] {
        fileLock.lock()
        defer { fileLock.unlock() }
        return conversations.first { $0.id == id }?.turns ?? []
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        fileLock.lock()
        defer { fileLock.unlock() }

        guard fileManager.fileExists(atPath: filePath),
              let data = fileManager.contents(atPath: filePath) else {
            conversations = []
            return
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            conversations = try decoder.decode([ConversationRecord].self, from: data)
            print("📂 [Conversations] Loaded \(conversations.count) conversations from disk")
        } catch {
            print("⚠️ [Conversations] Failed to load conversations.json: \(error)")
            conversations = []
        }
    }

    /// Save to disk (must be called within fileLock)
    private func saveToDisk() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(conversations)

            // Ensure directory exists
            let dir = (filePath as NSString).deletingLastPathComponent
            if !fileManager.fileExists(atPath: dir) {
                try fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }

            try data.write(to: URL(fileURLWithPath: filePath))
        } catch {
            print("⚠️ [Conversations] Failed to save conversations.json: \(error)")
        }
    }

    /// Thread-safe save (acquires lock)
    private func saveToDiskSafe() {
        fileLock.lock()
        defer { fileLock.unlock() }
        saveToDisk()
    }

    private func evictIfNeeded() {
        // Must be called within fileLock
        guard conversations.count > maxConversations else { return }

        // Sort by lastActiveAt, remove oldest
        conversations.sort { $0.lastActiveAt > $1.lastActiveAt }
        conversations = Array(conversations.prefix(maxConversations))
    }
}
