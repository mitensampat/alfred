import Foundation

/// Service for recognizing user intent from natural language queries
class IntentRecognitionService {
    private let claudeService: ClaudeAIService
    private let conversationContext: ConversationContext

    init(config: AppConfig, conversationContext: ConversationContext? = nil) {
        self.claudeService = ClaudeAIService(config: config.ai)
        self.conversationContext = conversationContext ?? ConversationContext.shared
    }

    /// Parse a natural language query into a structured intent (with conversation context)
    func recognizeIntent(_ query: String, sessionId: String = "default") async throws -> IntentRecognitionResponse {
        // Get recent conversation context
        let recentTurns = conversationContext.getRecentContext(for: sessionId, limit: 3)
        let session = conversationContext.getSession(for: sessionId)

        let userPrompt = buildIntentRecognitionPrompt(query: query, conversationTurns: recentTurns, session: session)
        let systemPrompt = getSystemPrompt()

        // Use separate system + user messages for better JSON output
        let response = try await claudeService.generateText(
            prompt: userPrompt,
            system: systemPrompt,
            maxTokens: 1024
        )

        // Extract JSON from response (handle markdown code blocks)
        let jsonString = extractJSON(from: response)

        // Parse Claude's JSON response
        guard let data = jsonString.data(using: String.Encoding.utf8) else {
            throw NSError(domain: "IntentRecognition", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to parse intent. Response: \(response.prefix(500))"])
        }

        // Try decoding with detailed error logging
        do {
            let intentResponse = try JSONDecoder().decode(IntentRecognitionResponse.self, from: data)
            return intentResponse
        } catch {
            print("⚠️ JSON decode error details: \(error)")
            print("⚠️ Extracted JSON was: \(jsonString.prefix(800))")
            throw NSError(domain: "IntentRecognition", code: 2,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to decode JSON. Error: \(error.localizedDescription). Extracted: \(jsonString.prefix(500))"])
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

    // MARK: - Prompt Building

    private func extractJSON(from response: String) -> String {
        // Try to extract JSON from markdown code blocks
        if let jsonMatch = response.range(of: "```json\\s*([\\s\\S]*?)```", options: .regularExpression) {
            let jsonBlock = String(response[jsonMatch])
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
        You are a JSON intent parser. You MUST output ONLY valid JSON matching the exact schema below. No text before or after the JSON. No markdown code fences.

        REQUIRED OUTPUT SCHEMA:
        {
          "intent": {
            "action": "<ACTION>",
            "target": "<TARGET>",
            "filters": {
              "contact_name": null,
              "date_range": null,
              "specific_date": null,
              "date_description": null,
              "platform": null,
              "commitment_type": null,
              "urgency": null,
              "lookback_days": null,
              "lookforward_days": null,
              "calendar_name": null,
              "task_search_term": null,
              "new_status": null,
              "new_priority": null,
              "new_due_date": null,
              "note_to_add": null
            },
            "confidence": 0.95,
            "original_query": "<the user query>"
          },
          "clarification_needed": false,
          "clarification_question": null,
          "suggested_follow_ups": ["suggestion 1", "suggestion 2"]
        }

        ACTION must be one of: generate, scan, analyze, find, summarize, check, list, update, create, delete, search
        TARGET must be one of: briefing, calendar, messages, commitments, todos, drafts, attention, thread, meeting, tasks, contacts, preferences

        CRITICAL RULES:
        - "action", "target", "filters", "confidence", "original_query" are ALL REQUIRED inside "intent"
        - "filters" is an object with the keys shown above. Put contact_name, lookback_days etc INSIDE filters, never at the intent level.
        - "show my commitments with X" -> action:"list", target:"commitments", filters.contact_name:"X"
        - "scan commitments" -> action:"scan", target:"commitments"
        - "what's on my calendar" -> action:"list", target:"calendar"
        - "morning briefing" -> action:"generate", target:"briefing"
        - "what should I focus on" -> action:"check", target:"attention"
        - "messages from X" -> action:"find", target:"messages", filters.contact_name:"X"
        - specific_date format: "YYYY-MM-DD" string
        - date_range format: {"start":"YYYY-MM-DD","end":"YYYY-MM-DD"}
        - Use null for unused filter fields

        TASK UPDATE RULES:
        - "mark the RCA task as done" -> action:"update", target:"tasks", filters.task_search_term:"RCA", filters.new_status:"Done"
        - "set priority on Jira migration to high" -> action:"update", target:"tasks", filters.task_search_term:"Jira migration", filters.new_priority:"High"
        - "move the dentist appointment to Friday" -> action:"update", target:"tasks", filters.task_search_term:"dentist", filters.new_due_date:"YYYY-MM-DD" (compute actual Friday date)
        - "add a note to the budget review: waiting on finance" -> action:"update", target:"tasks", filters.task_search_term:"budget review", filters.note_to_add:"Waiting on finance"
        - "complete the follow-up with Sarah" -> action:"update", target:"tasks", filters.task_search_term:"Sarah", filters.new_status:"Done"
        - "my top goal is done" or "mark that task done" -> resolve from conversation context, put task keywords in task_search_term, filters.new_status:"Done"
        - new_status valid values: "Done", "In Progress", "Not Started", "Blocked", "Cancelled"
        - new_priority valid values: "Critical", "High", "Medium", "Low"
        - new_due_date format: "YYYY-MM-DD" — compute the actual calendar date from natural language like "Monday", "next Friday", "end of week"
        - task_search_term: extract the MOST specific identifying keywords from the user's message (task title words, person name, topic). Use conversation context to resolve "that task", "it", "my top goal".
        - Multiple updates in one request are supported: "mark the RCA as high priority and due Monday" -> set both new_priority and new_due_date

        Output the JSON object now. Nothing else.
        """
    }

    private func buildIntentRecognitionPrompt(query: String, conversationTurns: [ConversationTurn], session: ConversationSession) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let today = dateFormatter.string(from: Date())

        var prompt = "Query: \"\(query)\"\nToday: \(today)"

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
