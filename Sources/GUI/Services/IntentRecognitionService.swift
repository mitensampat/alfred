import Foundation

/// Service for recognizing user intent from natural language queries
class IntentRecognitionService {
    private let claudeService: ClaudeAIService
    private let conversationContext: ConversationContext

    init(config: AppConfig) {
        self.claudeService = ClaudeAIService(config: config.ai)
        self.conversationContext = ConversationContext()
    }

    /// Parse a natural language query into a structured intent (with conversation context)
    func recognizeIntent(_ query: String, sessionId: String = "default") async throws -> IntentRecognitionResponse {
        // Get recent conversation context
        let recentTurns = conversationContext.getRecentContext(for: sessionId, limit: 3)
        let session = conversationContext.getSession(for: sessionId)

        let prompt = buildIntentRecognitionPrompt(query: query, conversationTurns: recentTurns, session: session)

        // Use ClaudeAIService's generateText method
        let combinedPrompt = """
        \(getSystemPrompt())

        \(prompt)
        """

        let response = try await claudeService.generateText(prompt: combinedPrompt)

        // Extract JSON from response (Claude may wrap it in text)
        guard let jsonString = extractJSON(from: response) else {
            print("ERROR: Could not extract JSON from Claude response:")
            print(response)
            throw IntentRecognitionError.failedToParse
        }

        // Parse Claude's JSON response
        guard let data = jsonString.data(using: String.Encoding.utf8) else {
            NSLog("ERROR: Could not convert JSON string to data")
            NSLog("JSON string: %@", jsonString)
            throw IntentRecognitionError.failedToParse
        }

        do {
            let decoder = JSONDecoder()
            // Custom date decoding to handle both full ISO8601 and date-only formats
            decoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                let dateString = try container.decode(String.self)

                // Try full ISO8601 first
                let iso8601Formatter = ISO8601DateFormatter()
                if let date = iso8601Formatter.date(from: dateString) {
                    return date
                }

                // Try date-only format (YYYY-MM-DD)
                let dateOnlyFormatter = ISO8601DateFormatter()
                dateOnlyFormatter.formatOptions = [.withFullDate]
                if let date = dateOnlyFormatter.date(from: dateString) {
                    return date
                }

                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode date from: \(dateString)")
            }
            // Don't use convertFromSnakeCase - the models have explicit CodingKeys
            let intentResponse = try decoder.decode(IntentRecognitionResponse.self, from: data)
            return intentResponse
        } catch {
            NSLog("ERROR: JSON decoding failed: %@", error.localizedDescription)
            NSLog("JSON string: %@", jsonString)
            if let decodingError = error as? DecodingError {
                switch decodingError {
                case .keyNotFound(let key, let context):
                    NSLog("Key '%@' not found: %@", key.stringValue, context.debugDescription)
                    NSLog("Coding path: %@", context.codingPath.map { $0.stringValue }.joined(separator: " -> "))
                case .typeMismatch(let type, let context):
                    NSLog("Type mismatch for type %@: %@", String(describing: type), context.debugDescription)
                    NSLog("Coding path: %@", context.codingPath.map { $0.stringValue }.joined(separator: " -> "))
                case .valueNotFound(let type, let context):
                    NSLog("Value of type %@ not found: %@", String(describing: type), context.debugDescription)
                    NSLog("Coding path: %@", context.codingPath.map { $0.stringValue }.joined(separator: " -> "))
                case .dataCorrupted(let context):
                    NSLog("Data corrupted: %@", context.debugDescription)
                    NSLog("Coding path: %@", context.codingPath.map { $0.stringValue }.joined(separator: " -> "))
                @unknown default:
                    NSLog("Unknown decoding error: %@", String(describing: decodingError))
                }
            }
            throw IntentRecognitionError.failedToParse
        }
    }

    /// Store turn result in conversation context
    func recordTurn(sessionId: String, query: String, intent: UserIntent, result: IntentExecutionResult?) {
        conversationContext.addTurn(sessionId: sessionId, query: query, intent: intent, result: result)
    }

    /// Clear a specific conversation session
    func clearSession(_ sessionId: String) {
        conversationContext.clearSession(sessionId)
    }

    /// Clear all conversation sessions
    func clearAllSessions() {
        conversationContext.clearAllSessions()
    }

    // MARK: - JSON Extraction

    private func extractJSON(from text: String) -> String? {
        // Try to find JSON between curly braces
        if let range = text.range(of: "\\{[\\s\\S]*\\}", options: .regularExpression) {
            return String(text[range])
        }
        // If no match, maybe the whole response is JSON
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
            return text
        }
        return nil
    }

    // MARK: - Prompt Building

    private func getSystemPrompt() -> String {
        """
        You are an intent recognition system for Alfred, an executive assistant app.

        Your job is to parse natural language queries and extract:
        1. The action the user wants (generate, scan, analyze, find, summarize, check, list)
        2. The target entity (briefing, calendar, messages, commitments, todos, drafts, attention)
        3. Any filters or parameters (contact names, date ranges, platforms, etc.)

        Available actions:
        - generate: Create a briefing, report, or draft
        - scan: Scan for commitments or todos in messages
        - analyze: Deep analysis of messages or calendar patterns
        - find: Find specific items matching criteria
        - summarize: Summarize a thread, meeting, or time period
        - check: Run attention check or check for overdue items
        - list: List existing items (commitments, drafts, etc.)
        - update: Update task or commitment status
        - create: Create new task or commitment
        - delete: Delete or cancel an item
        - search: Search across all data

        Available targets:
        - briefing: Daily briefing with priorities and recommendations
        - calendar: Calendar events and meeting briefings
        - messages: Message threads and summaries
        - commitments: Tracked commitments (I owe / they owe)
        - todos: Todo items extracted from messages
        - drafts: Draft messages generated by Alfred
        - attention: Attention defense report (what to prioritize)
        - thread: Specific message conversation
        - meeting: Specific calendar event
        - tasks: Unified tasks (todos + commitments)
        - contacts: People and contacts
        - preferences: User preferences and settings

        Date parsing rules:
        - "last two weeks" = lookback_days: 14
        - "next week" = lookforward_days: 7
        - "today" = specific_date: [today's date]
        - "this month" = date_range from start to end of current month

        Platform detection:
        - "WhatsApp", "on WhatsApp" → platform: "whatsapp"
        - "iMessage", "text messages" → platform: "imessage"
        - If not specified → platform: null (means all)

        You must respond with valid JSON in this exact format:
        {
          "intent": {
            "action": "scan",
            "target": "commitments",
            "filters": {
              "contact_name": "Mona Gandhi",
              "lookback_days": 14,
              "platform": "whatsapp"
            },
            "confidence": 0.95,
            "original_query": "find my commitments to Mona Gandhi over the last two weeks"
          },
          "clarification_needed": false,
          "clarification_question": null,
          "suggested_follow_ups": [
            "Show me overdue commitments",
            "Scan for new commitments from this week"
          ]
        }

        Confidence scoring guidelines:
        - confidence >= 0.9: Very clear intent, all parameters specified
        - confidence 0.7-0.9: Clear action but some ambiguity in parameters
        - confidence < 0.7: Ambiguous intent, needs clarification

        If confidence < 0.7 OR the query is genuinely ambiguous, set clarification_needed: true and provide a specific clarification_question.

        Be generous with interpreting user intent - err on the side of action rather than asking for clarification, unless truly ambiguous.
        """
    }

    private func buildIntentRecognitionPrompt(query: String, conversationTurns: [ConversationTurn], session: ConversationSession) -> String {
        let today = ISO8601DateFormatter().string(from: Date())

        var prompt = """
        Parse this user query into a structured intent:

        Query: "\(query)"

        Today's date: \(today)
        """

        // Add conversation context if available
        if !conversationTurns.isEmpty {
            let contextString = ContextBuilder.buildContextString(from: conversationTurns)
            prompt += "\n\n\(contextString)"
        }

        // Add entity hints
        let entityHints = ContextBuilder.buildEntityHints(from: session)
        if !entityHints.isEmpty {
            prompt += "\n\(entityHints)"
        }

        prompt += """


        IMPORTANT: Use conversation context to resolve references like:
        - "that", "them", "those" → refer to entities from recent turns
        - "yesterday", "last week" → use actual dates based on today
        - Pronouns like "he", "she", "they" → refer to recent contacts

        Respond with JSON only, no additional text.
        """

        return prompt
    }
}

// MARK: - Errors

enum IntentRecognitionError: Error, LocalizedError {
    case failedToParse
    case ambiguousIntent
    case unsupportedAction

    var errorDescription: String? {
        switch self {
        case .failedToParse:
            return "Failed to parse intent from Claude response"
        case .ambiguousIntent:
            return "Query is too ambiguous to interpret"
        case .unsupportedAction:
            return "Requested action is not supported"
        }
    }
}
