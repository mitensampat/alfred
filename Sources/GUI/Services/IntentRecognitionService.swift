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
        - chat: Conversational messages with no structured action needed

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
              "platform": "whatsapp",
              "task_search_term": null,
              "new_status": null,
              "new_priority": null,
              "new_due_date": null,
              "note_to_add": null
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

        TASK UPDATE RULES:
        - "mark the RCA task as done" -> action:"update", target:"tasks", filters.task_search_term:"RCA", filters.new_status:"Done"
        - "set priority on Jira migration to high" -> action:"update", target:"tasks", filters.task_search_term:"Jira migration", filters.new_priority:"High"
        - "move the dentist appointment to Friday" -> action:"update", target:"tasks", filters.task_search_term:"dentist", filters.new_due_date:"YYYY-MM-DD" (compute actual Friday date)
        - "add a note to the budget review: waiting on finance" -> action:"update", target:"tasks", filters.task_search_term:"budget review", filters.note_to_add:"Waiting on finance"
        - "complete the follow-up with Sarah" -> action:"update", target:"tasks", filters.task_search_term:"Sarah", filters.new_status:"Done"
        - "my top goal is done" or "mark that task done" -> resolve from conversation context, put task keywords in task_search_term, filters.new_status:"Done"
        - new_status valid values: "Done", "In Progress", "Not Started", "Blocked", "Cancelled"
        - new_priority valid values: "Critical", "High", "Medium", "Low"
        - new_due_date format: "YYYY-MM-DD" — compute the actual calendar date from natural language
        - task_search_term: extract the MOST specific identifying keywords from the user's message
        - Multiple updates in one request are supported: "mark the RCA as high priority and due Monday" -> set both new_priority and new_due_date

        Confidence scoring guidelines:
        - confidence >= 0.9: Very clear intent, all parameters specified
        - confidence 0.7-0.9: Clear action but some ambiguity in parameters
        - confidence < 0.7: Ambiguous intent, needs clarification

        If confidence < 0.7 OR the query is genuinely ambiguous, set clarification_needed: true and provide a specific clarification_question.

        Be generous with interpreting user intent - err on the side of action rather than asking for clarification, unless truly ambiguous.

        CONVERSATIONAL / ACKNOWLEDGMENT RULES:
        - "thanks for the feedback" / "got it" / "I agree" / "sounds good" -> action:"chat", target:null, confidence:0.9
        - "I will do better in the future" / "that's a good point" -> action:"chat", target:null, confidence:0.9
        - If a message is PRIMARILY conversational but mentions a task by name AND contains a clear command (e.g. "mark it as done"), extract the command as the intent — do NOT use action:"chat"
        - If a message is conversational with NO embedded command, use action:"chat" with confidence:0.9
        - Do NOT ask for clarification on purely conversational messages
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
