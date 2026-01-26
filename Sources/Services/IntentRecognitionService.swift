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

        let response = try await claudeService.generateText(prompt: combinedPrompt, maxTokens: 2048)

        // Extract JSON from response (handle markdown code blocks)
        let jsonString = extractJSON(from: response)

        // Parse Claude's JSON response
        guard let data = jsonString.data(using: String.Encoding.utf8) else {
            // Create a detailed error with the response
            throw NSError(domain: "IntentRecognition", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to parse intent. Response: \(response.prefix(500))"])
        }

        guard let intentResponse = try? JSONDecoder().decode(IntentRecognitionResponse.self, from: data) else {
            // Create a detailed error with the extracted JSON
            throw NSError(domain: "IntentRecognition", code: 2,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to decode JSON. Extracted: \(jsonString.prefix(500))"])
        }

        return intentResponse
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

    // MARK: - Prompt Building

    private func extractJSON(from response: String) -> String {
        // Try to extract JSON from markdown code blocks
        if let jsonMatch = response.range(of: "```json\\s*([\\s\\S]*?)```", options: .regularExpression) {
            let jsonBlock = String(response[jsonMatch])
            // Remove the ```json and ``` markers
            return jsonBlock
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Try to extract JSON from plain code blocks
        if let codeMatch = response.range(of: "```\\s*([\\s\\S]*?)```", options: .regularExpression) {
            let codeBlock = String(response[codeMatch])
            return codeBlock
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // If no code block, try to find JSON object directly
        if let startBrace = response.firstIndex(of: "{"),
           let endBrace = response.lastIndex(of: "}") {
            return String(response[startBrace...endBrace])
        }

        // Return as-is if no patterns match
        return response.trimmingCharacters(in: .whitespacesAndNewlines)
    }

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

        IMPORTANT: You must respond with ONLY valid, complete JSON. Do not truncate the response. Ensure all JSON arrays and objects are properly closed.

        Response format:
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
            "Show overdue commitments",
            "What meetings do I have this week?"
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
