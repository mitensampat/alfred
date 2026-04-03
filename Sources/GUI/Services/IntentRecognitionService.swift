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
        let tz = TimeZone.current
        let seconds = tz.secondsFromGMT()
        let hours = seconds / 3600
        let minutes = abs(seconds / 60 % 60)
        let offsetStr = String(format: "%+03d:%02d", hours, minutes)

        return """
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
              "task_type": null,
              "event_title": null,
              "event_time": null,
              "event_duration_minutes": null,
              "event_location": null,
              "event_attendees": null,
              "event_attendee_emails": null,
              "event_description": null,
              "event_search_term": null,
              "commitment_direction": null,
              "commitment_counterparty": null,
              "teach_text": null,
              "theme_name": null,
              "cadence_name": null
            },
            "confidence": 0.95,
            "original_query": "<the user query>"
          },
          "clarification_needed": false,
          "clarification_question": null,
          "suggested_follow_ups": ["suggestion 1", "suggestion 2"]
        }

        ACTION must be one of: generate, scan, analyze, find, summarize, check, list, update, create, delete, search, chat
        TARGET must be one of: briefing, calendar, messages, commitments, todos, drafts, attention, thread, meeting, tasks, contacts, preferences, reflections, memory, favorites, focus, cadences, conversations, skills

        CRITICAL RULES:
        - "action", "target", "filters", "confidence", "original_query" are ALL REQUIRED inside "intent"
        - "filters" is an object with the keys shown above. Put contact_name, lookback_days etc INSIDE filters, never at the intent level.
        - "show my commitments with X" -> action:"list", target:"commitments", filters.contact_name:"X"
        - "scan commitments" -> action:"scan", target:"commitments"
        - "what's on my calendar" -> action:"list", target:"calendar"
        - "morning briefing" -> action:"generate", target:"briefing"
        - "what should I focus on" -> action:"check", target:"attention"
        - "messages from X" -> action:"find", target:"thread", filters.contact_name:"X"
        - specific_date format: "YYYY-MM-DD" string
        - date_range format: {"start":"YYYY-MM-DD","end":"YYYY-MM-DD"}
        - Use null for unused filter fields
        - event_time: MUST be an ISO8601 datetime string with timezone offset \(offsetStr). Compute the ACTUAL date from relative terms.

        TASK UPDATE RULES:
        - "mark the RCA task as done" -> action:"update", target:"tasks", filters.task_search_term:"RCA", filters.new_status:"Done"
        - "move the dentist appointment to Friday" -> action:"update", target:"tasks", filters.task_search_term:"dentist", filters.new_due_date:"YYYY-MM-DD"
        - new_status valid values: "Done", "In Progress", "Not Started", "Blocked", "Cancelled"
        - new_priority valid values: "Critical", "High", "Medium", "Low"
        - task_search_term: extract the MOST specific identifying keywords from the user's message

        TODO UPDATE / DELETE RULES:
        - "mark that todo as done" -> action:"update", target:"todos", filters.task_search_term:"<resolve from context>", filters.new_status:"Done"
        - "cancel the groceries todo" -> action:"delete", target:"todos", filters.task_search_term:"groceries"

        MEETING BRIEF RULES:
        - "brief me on my next meeting" -> action:"generate", target:"meeting"
        - "what's my next meeting about?" -> action:"generate", target:"meeting"

        FOCUS PIN RULES:
        - "what's my top goal?" -> action:"list", target:"focus"
        - "suggest a focus for today" -> action:"generate", target:"focus"
        - "pin the RCA task as my focus" -> action:"create", target:"focus", filters.task_search_term:"RCA"
        - "I'm done with my focus" -> action:"delete", target:"focus"

        REFLECTIONS RULES:
        - "what themes have I been thinking about?" -> action:"list", target:"reflections"
        - "what are my open questions?" -> action:"analyze", target:"reflections"
        - "deep dive on Revenue Strategy" -> action:"summarize", target:"reflections", filters.theme_name:"Revenue Strategy"

        MEMORY & LEARNING RULES:
        - "what patterns have you learned about me?" -> action:"list", target:"memory"
        - "teach: always CC finance on budget emails" -> action:"create", target:"memory", filters.teach_text:"Always CC finance on budget emails"
        - "forget the pattern about morning meetings" -> action:"delete", target:"memory", filters.task_search_term:"morning meetings"

        CADENCE TRIGGER RULES:
        - "run attention check now" -> action:"scan", target:"cadences", filters.cadence_name:"attention"
        - "show cadence status" -> action:"list", target:"cadences"

        FAVORITES RULES:
        - "who are my favorites?" -> action:"list", target:"favorites"
        - "add Vinay to my favorites" -> action:"create", target:"favorites", filters.contact_name:"Vinay"
        - "remove Vinay from favorites" -> action:"delete", target:"favorites", filters.contact_name:"Vinay"

        CALENDAR AVAILABILITY RULES:
        - "am I free next Friday at 4pm?" -> action:"check", target:"calendar", filters.event_time:"<ISO8601 datetime>"
        - "is my calendar clear tomorrow?" -> action:"check", target:"calendar", filters.specific_date:"<YYYY-MM-DD>"

        CONVERSATION HISTORY RULES:
        - "show my recent conversations" -> action:"list", target:"conversations"

        SKILLS RULES:
        - "what coaching skills are active?" -> action:"list", target:"skills"

        CONTACT ANALYSIS RULES:
        - "who have I been talking to most?" -> action:"analyze", target:"contacts"

        CONVERSATIONAL / ACKNOWLEDGMENT RULES:
        - "thanks" / "got it" / "sounds good" -> action:"chat", target:null, confidence:0.9
        - If a message contains a clear command, extract it — do NOT use action:"chat"
        - Do NOT ask for clarification on purely conversational messages

        Output the JSON object now. Nothing else.
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
