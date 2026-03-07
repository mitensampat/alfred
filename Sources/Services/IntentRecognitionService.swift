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

        // Try decoding with detailed error logging + retry with cleanup
        do {
            let intentResponse = try JSONDecoder().decode(IntentRecognitionResponse.self, from: data)
            return intentResponse
        } catch {
            print("⚠️ JSON decode error (attempt 1): \(error)")
            print("⚠️ Extracted JSON was: \(jsonString.prefix(800))")

            // Retry with cleaned JSON (fix trailing commas, comments, control chars)
            let cleanedString = cleanJSON(jsonString)
            if cleanedString != jsonString, let cleanedData = cleanedString.data(using: .utf8) {
                do {
                    let intentResponse = try JSONDecoder().decode(IntentRecognitionResponse.self, from: cleanedData)
                    print("✅ JSON decode succeeded after cleanup")
                    return intentResponse
                } catch {
                    print("⚠️ JSON decode error (attempt 2 after cleanup): \(error)")
                }
            }

            throw NSError(domain: "IntentRecognition", code: 2,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to decode JSON after cleanup. Error: \(error.localizedDescription). Extracted: \(jsonString.prefix(500))"])
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

    /// Attempt to clean common JSON issues that Claude sometimes produces
    private func cleanJSON(_ json: String) -> String {
        var cleaned = json
        // Fix "value" or "value" pattern → keep only the first alternative
        cleaned = cleaned.replacingOccurrences(
            of: "(\"[^\"]*\")\\s+or\\s+\"[^\"]*\"",
            with: "$1",
            options: .regularExpression
        )
        // Remove single-line comments (// ...)
        cleaned = cleaned.replacingOccurrences(of: "//[^\n]*", with: "", options: .regularExpression)
        // Remove trailing commas before } or ]
        cleaned = cleaned.replacingOccurrences(of: ",\\s*([}\\]])", with: "$1", options: .regularExpression)
        // Remove control chars (keep newline/tab)
        cleaned = String(cleaned.unicodeScalars.filter {
            $0.value >= 32 || $0.value == 10 || $0.value == 9
        }.map { Character($0) })
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
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
              "note_to_add": null,
              "task_title": null,
              "task_type": null
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
        - "messages from X" -> action:"find", target:"thread", filters.contact_name:"X"
        - "messages" or "my messages" (no specific person/group) -> action:"list", target:"messages"
        - specific_date format: "YYYY-MM-DD" string
        - date_range format: {"start":"YYYY-MM-DD","end":"YYYY-MM-DD"}
        - Use null for unused filter fields

        THREAD / GROUP ANALYSIS RULES:
        - "how's my energy on [group/contact]" -> action:"analyze", target:"thread", filters.contact_name:"[group/contact]", filters.platform:"whatsapp"
        - "summarize the CRED- Kunal Directs group" -> action:"summarize", target:"thread", filters.contact_name:"CRED- Kunal Directs"
        - "what's happening on [group name] on whatsapp" -> action:"analyze", target:"thread", filters.contact_name:"[group name]", filters.platform:"whatsapp"
        - "show me [group name] thread" -> action:"find", target:"thread", filters.contact_name:"[group name]"
        - "how's conversation with [person]" -> action:"analyze", target:"thread", filters.contact_name:"[person]"
        - When user mentions a specific person or group name with words like "energy", "vibe", "conversation", "thread", "discussion", "chat" -> use target:"thread" with contact_name set to the person/group name
        - contact_name should preserve the EXACT group/contact name as written (including dashes, spaces, special chars)
        - If platform is mentioned (whatsapp, imessage), set filters.platform accordingly; otherwise leave null

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

        CALENDAR EVENT CREATION RULES:
        - "block 4PM tomorrow with Mona for 30 minutes at Home, topic is finance" -> action:"create", target:"calendar"
        - "schedule a meeting with Nikhil at 2PM on Friday for 1 hour" -> action:"create", target:"calendar"
        - "set up a call with Kunal tomorrow morning" -> action:"create", target:"calendar"
        - event_title: null (leave blank — the app auto-generates the title from attendees + topic)
        - event_time: MUST be an ISO8601 datetime string (e.g. "2026-02-28T16:00:00+05:30"). Compute the ACTUAL date from relative terms like "tomorrow", "Friday", "next Monday". Use the user's timezone (Asia/Kolkata, +05:30).
        - event_duration_minutes: integer, default 30 if not specified. "1 hour" = 60, "45 min" = 45
        - event_location: extract if mentioned ("at Home", "at Office", "at Starbucks"), null if not specified
        - event_attendees: list of person names mentioned (["Mona"], ["Nikhil", "Kunal"]), null if no one mentioned
        - event_description: topic or agenda if mentioned, null otherwise

        TASK CREATION RULES:
        - "create a task to review the deck" -> action:"create", target:"tasks", filters.task_title:"Review the deck"
        - "add a todo: call dentist" -> action:"create", target:"todos", filters.task_title:"Call dentist"
        - "new task: budget review, high priority, due Friday" -> action:"create", target:"tasks", filters.task_title:"Budget review", filters.new_priority:"High", filters.new_due_date:"YYYY-MM-DD"
        - task_title: the title for the new task. Required for create actions.
        - task_type: "Todo" (default), "Commitment", "Follow-up"
        - For create + todos, task_type is automatically "Todo"
        - new_priority, new_due_date, note_to_add also apply to creation (reuse same fields)

        TASK LISTING / SEARCH RULES:
        - "show my tasks" -> action:"list", target:"tasks"
        - "what's on my plate" -> action:"list", target:"tasks"
        - "show my todos" -> action:"list", target:"todos"
        - "find the RCA task" -> action:"search", target:"tasks", filters.task_search_term:"RCA"
        - "search for budget review" -> action:"search", target:"tasks", filters.task_search_term:"budget review"

        TASK DELETION RULES:
        - "cancel the dentist task" -> action:"delete", target:"tasks", filters.task_search_term:"dentist"
        - "remove the budget review" -> action:"delete", target:"tasks", filters.task_search_term:"budget review"
        - Deletion is soft: tasks are marked as "Cancelled", not permanently removed

        COMMITMENT CHECK RULES:
        - "do I have overdue commitments?" -> action:"check", target:"commitments"
        - "what commitments am I behind on?" -> action:"check", target:"commitments"
        - "mark the commitment with Nikhil as done" -> action:"update", target:"commitments", filters.task_search_term:"Nikhil", filters.new_status:"Done"

        DRAFT GENERATION RULES:
        - "draft a reply to Mona" -> action:"generate", target:"drafts", filters.contact_name:"Mona"
        - "generate drafts for my messages" -> action:"generate", target:"drafts"

        TASK STATS / WEEKLY REFLECTION RULES:
        - "how are my tasks doing?" -> action:"check", target:"tasks"
        - "task stats" -> action:"check", target:"tasks"
        - "weekly reflection" -> action:"summarize", target:"briefing"
        - "how was my week?" -> action:"summarize", target:"briefing"

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
