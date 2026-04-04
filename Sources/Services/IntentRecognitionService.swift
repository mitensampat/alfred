import Foundation

/// Service for recognizing user intent from natural language queries
class IntentRecognitionService {
    private let claudeService: ClaudeAIService
    private let conversationContext: ConversationContext
    private let userTimezone: String

    init(config: AppConfig, conversationContext: ConversationContext? = nil) {
        self.claudeService = ClaudeAIService(config: config.ai)
        self.conversationContext = conversationContext ?? ConversationContext.shared
        self.userTimezone = config.app.timezone.isEmpty ? TimeZone.current.identifier : config.app.timezone
    }

    /// Parse a natural language query into a structured intent (with conversation context)
    func recognizeIntent(_ query: String, sessionId: String = "default") async throws -> IntentRecognitionResponse {
        // Get recent conversation context
        let recentTurns = conversationContext.getRecentContext(for: sessionId, limit: 3)
        let session = conversationContext.getSession(for: sessionId)

        let userPrompt = buildIntentRecognitionPrompt(query: query, conversationTurns: recentTurns, session: session)
        let systemPrompt = getSystemPrompt()

        // Use separate system + user messages for better JSON output
        // Use Haiku for fast, cost-effective intent recognition
        let response = try await claudeService.generateText(
            prompt: userPrompt,
            system: systemPrompt,
            maxTokens: 1024,
            useModel: "claude-haiku-4-5-20251001"
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
        - event_time: MUST be an ISO8601 datetime string (e.g. "2026-02-28T16:00:00\(timezoneOffsetString())"). Compute the ACTUAL date from relative terms like "tomorrow", "Friday", "next Monday". Use the user's timezone (\(userTimezone)).
        - event_duration_minutes: integer, default 30 if not specified. "1 hour" = 60, "45 min" = 45
        - event_location: extract if mentioned ("at Home", "at Office", "at Starbucks"), null if not specified
        - event_attendees: list of person names mentioned (["Mona"], ["Nikhil", "Kunal"]), null if no one mentioned
        - event_description: topic or agenda if mentioned, null otherwise
        - event_attendee_emails: if the user includes email addresses in their message (e.g. "alice@example.com"), extract them into this list. These are DISTINCT from event_attendees (names). Example: "block 3pm with Mona alice@example.com" -> event_attendees: ["Mona"], event_attendee_emails: ["alice@example.com"]. If the message contains ONLY an email (no name), still extract the email and use the local-part as the attendee name. Example: "meeting with nikhil@example.com at 2pm" -> event_attendees: ["nikhil"], event_attendee_emails: ["nikhil@example.com"]

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

        COMMITMENT RULES:
        - commitment_type: "i_owe" when user asks about things THEY owe to others, "they_owe" when asking about things OTHERS owe them, "all" or null for everything
        - "show me commitments I owe" -> action:"list", target:"commitments", filters.commitment_type:"i_owe"
        - "show me commitments others owe me" -> action:"list", target:"commitments", filters.commitment_type:"they_owe"
        - "show me overdue commitments" -> action:"list", target:"commitments", filters.urgency:"overdue"
        - "show me commitments with Mona" -> action:"list", target:"commitments", filters.contact_name:"Mona"
        - "how are my commitments looking?" -> action:"list", target:"commitments"
        - "do I have overdue commitments?" -> action:"list", target:"commitments", filters.urgency:"overdue"
        - "what commitments am I behind on?" -> action:"list", target:"commitments", filters.urgency:"overdue"
        - "mark the commitment with Nikhil as done" -> action:"update", target:"commitments", filters.task_search_term:"Nikhil", filters.new_status:"Done"

        COMMITMENT CREATION RULES:
        - "I owe Nikhil a deck review by Friday" -> action:"create", target:"commitments", filters.task_title:"Deck review", filters.commitment_direction:"i_owe", filters.commitment_counterparty:"Nikhil", filters.new_due_date:"YYYY-MM-DD"
        - "Mona owes me the Q3 numbers" -> action:"create", target:"commitments", filters.task_title:"Q3 numbers", filters.commitment_direction:"they_owe", filters.commitment_counterparty:"Mona"
        - "I need to send Kunal the report by Monday" -> action:"create", target:"commitments", filters.task_title:"Send the report", filters.commitment_direction:"i_owe", filters.commitment_counterparty:"Kunal", filters.new_due_date:"YYYY-MM-DD"
        - commitment_direction: "i_owe" when the user owes someone, "they_owe" when someone owes the user
        - commitment_counterparty: the OTHER person's name (who the commitment is with)

        COMMITMENT DELETION RULES:
        - "cancel my commitment to review the budget" -> action:"delete", target:"commitments", filters.task_search_term:"budget review"
        - "remove the commitment with Mona about Q3" -> action:"delete", target:"commitments", filters.task_search_term:"Mona Q3"
        - Deletion is soft: commitments are marked as "Cancelled", not permanently removed

        CALENDAR UPDATE RULES:
        - "move my 3pm to 4pm" -> action:"update", target:"calendar", filters.event_search_term:"3pm", filters.event_time:"<new ISO8601 datetime for 4pm today>"
        - "reschedule the meeting with Nikhil to tomorrow" -> action:"update", target:"calendar", filters.event_search_term:"Nikhil", filters.event_time:"<tomorrow ISO8601>"
        - "change my standup location to Conference Room" -> action:"update", target:"calendar", filters.event_search_term:"standup", filters.event_location:"Conference Room"
        - "push back the 2pm by 30 minutes" -> action:"update", target:"calendar", filters.event_search_term:"2pm", filters.event_time:"<ISO8601 for 2:30pm>"
        - event_search_term: keywords to fuzzy-match an existing event (time like "3pm", title words, attendee names)
        - event_time: the NEW time for the event (ISO8601 with timezone), only if time is being changed
        - event_location: the NEW location, only if location is being changed

        CALENDAR DELETE RULES:
        - "cancel my 3pm meeting" -> action:"delete", target:"calendar", filters.event_search_term:"3pm"
        - "remove the sync with product" -> action:"delete", target:"calendar", filters.event_search_term:"product sync"
        - "delete the standup" -> action:"delete", target:"calendar", filters.event_search_term:"standup"

        DRAFT GENERATION RULES:
        - "draft a reply to Mona" -> action:"generate", target:"drafts", filters.contact_name:"Mona"
        - "generate drafts for my messages" -> action:"generate", target:"drafts"

        TODO UPDATE / DELETE RULES:
        - "mark that todo as done" -> action:"update", target:"todos", filters.task_search_term:"<resolve from context>", filters.new_status:"Done"
        - "complete the dentist todo" -> action:"update", target:"todos", filters.task_search_term:"dentist", filters.new_status:"Done"
        - "cancel the groceries todo" -> action:"delete", target:"todos", filters.task_search_term:"groceries"
        - Todo update/delete follows the same rules as task update/delete — use task_search_term, new_status, new_priority, new_due_date

        MEETING BRIEF RULES:
        - "brief me on my next meeting" -> action:"generate", target:"meeting"
        - "what's my next meeting about?" -> action:"generate", target:"meeting"
        - "prep me for the 3pm" -> action:"generate", target:"meeting"
        - "meeting brief" -> action:"generate", target:"meeting"
        - "what should I know before my next call?" -> action:"generate", target:"meeting"

        FOCUS PIN RULES:
        - "what's my top goal?" -> action:"list", target:"focus"
        - "what's my focus?" -> action:"list", target:"focus"
        - "show focus suggestions" -> action:"generate", target:"focus"
        - "suggest a focus for today" -> action:"generate", target:"focus"
        - "pin the RCA task as my focus" -> action:"create", target:"focus", filters.task_search_term:"RCA"
        - "set my top goal to the budget review" -> action:"create", target:"focus", filters.task_search_term:"budget review"
        - "I'm done with my focus" -> action:"delete", target:"focus"
        - "unpin my focus" -> action:"delete", target:"focus"
        - "clear my top goal" -> action:"delete", target:"focus"

        REFLECTIONS RULES:
        - "what themes have I been thinking about?" -> action:"list", target:"reflections"
        - "show my reflection themes" -> action:"list", target:"reflections"
        - "what are my open questions?" -> action:"analyze", target:"reflections"
        - "what questions am I wrestling with?" -> action:"analyze", target:"reflections"
        - "deep dive on Revenue Strategy" -> action:"summarize", target:"reflections", filters.theme_name:"Revenue Strategy"
        - "tell me more about the Leadership theme" -> action:"summarize", target:"reflections", filters.theme_name:"Leadership"
        - theme_name: the exact theme name for deep-dive queries

        PENDING COMMITMENT CLOSURES RULES:
        - "any commitments to confirm?" -> action:"check", target:"commitments", filters.urgency:"pending_closure"
        - "pending closures" -> action:"check", target:"commitments", filters.urgency:"pending_closure"
        - "confirm the commitment with Nikhil" -> action:"update", target:"commitments", filters.task_search_term:"Nikhil", filters.new_status:"Done"
        - When urgency is "pending_closure", this specifically queries auto-detected closure suggestions

        MEMORY & LEARNING RULES:
        - "what patterns have you learned about me?" -> action:"list", target:"memory"
        - "show learned patterns" -> action:"list", target:"memory"
        - "what do you know about me?" -> action:"list", target:"memory"
        - "teach: always CC finance on budget emails" -> action:"create", target:"memory", filters.teach_text:"Always CC finance on budget emails"
        - "remember that I prefer morning meetings" -> action:"create", target:"memory", filters.teach_text:"Prefers morning meetings"
        - "forget the pattern about morning meetings" -> action:"delete", target:"memory", filters.task_search_term:"morning meetings"
        - teach_text: the rule text to teach Alfred (extract from user's message, clean up to a clear rule statement)
        - IMPORTANT: "stop reminding me about X", "don't surface X", "mute X", "ignore X group", "I've muted X", "stop flagging X" are ALL memory/teach intents. Route to action:"create", target:"memory" with teach_text capturing the preference. Examples:
          - "I muted the MARS group, stop reminding me" -> action:"create", target:"memory", filters.teach_text:"Do not surface or remind about the MARS WhatsApp group"
          - "stop flagging messages from the family group" -> action:"create", target:"memory", filters.teach_text:"Do not flag or surface messages from the family group"
          - "don't remind me about overdue tasks from last quarter" -> action:"create", target:"memory", filters.teach_text:"Do not remind about overdue tasks from last quarter"
        - NEVER route behavioral preferences like "stop doing X" or "don't remind me about Y" to target:"preferences". Those are memory rules.

        CADENCE TRIGGER RULES:
        - "run attention check now" -> action:"scan", target:"cadences", filters.cadence_name:"attention"
        - "trigger the todo scan" -> action:"scan", target:"cadences", filters.cadence_name:"todo"
        - "refresh my briefing" -> action:"scan", target:"cadences", filters.cadence_name:"briefing"
        - "run commitment scan" -> action:"scan", target:"cadences", filters.cadence_name:"commitment"
        - "show cadence status" -> action:"list", target:"cadences"
        - "what cadences are running?" -> action:"list", target:"cadences"
        - cadence_name: keyword to match against cadence names (e.g. "attention", "todo", "briefing", "commitment", "reflection", "pattern")

        FAVORITES RULES:
        - "who are my favorites?" -> action:"list", target:"favorites"
        - "show my favorite contacts" -> action:"list", target:"favorites"
        - "add Vinay to my favorites" -> action:"create", target:"favorites", filters.contact_name:"Vinay"
        - "add Acme Leadership group to favorites" -> action:"create", target:"favorites", filters.contact_name:"Acme Leadership"
        - "remove Vinay from favorites" -> action:"delete", target:"favorites", filters.contact_name:"Vinay"

        CONTACT ANALYSIS RULES:
        - "who have I been talking to most?" -> action:"analyze", target:"contacts"
        - "show my contact participation" -> action:"analyze", target:"contacts"
        - "who am I spending the most time messaging?" -> action:"analyze", target:"contacts"

        CALENDAR AVAILABILITY RULES:
        - "am I free next Friday at 4pm?" -> action:"check", target:"calendar", filters.event_time:"<ISO8601 datetime for next Friday 4pm>"
        - "do I have anything at 2pm tomorrow?" -> action:"check", target:"calendar", filters.event_time:"<ISO8601 datetime for tomorrow 2pm>"
        - "what's open on Monday afternoon?" -> action:"check", target:"calendar", filters.specific_date:"<YYYY-MM-DD for Monday>"
        - "is my calendar clear tomorrow morning?" -> action:"check", target:"calendar", filters.specific_date:"<YYYY-MM-DD for tomorrow>"
        - "am I free at 11am on Wednesday" -> action:"check", target:"calendar", filters.event_time:"<ISO8601 datetime for NEXT Wednesday 11am>"
        - For availability checks: use action:"check" with target:"calendar". Set event_time for specific time queries, specific_date for general day queries.
        - CRITICAL: Use the Today date and day-of-week provided below to compute the ACTUAL calendar date. "Wednesday" means the NEXT upcoming Wednesday from today. "next Friday" means the Friday of NEXT week. Always output a real ISO8601 datetime, never a placeholder.

        CONVERSATION HISTORY RULES:
        - "show my recent conversations" -> action:"list", target:"conversations"
        - "what did we talk about yesterday?" -> action:"list", target:"conversations"

        SKILLS RULES:
        - "what coaching skills are active?" -> action:"list", target:"skills"
        - "show my skills" -> action:"list", target:"skills"
        - "describe my coaching skills" -> action:"list", target:"skills"

        TASK STATS / WEEKLY REFLECTION RULES:
        - "how are my tasks doing?" -> action:"check", target:"tasks"
        - "task stats" -> action:"check", target:"tasks"
        - "weekly reflection" -> action:"summarize", target:"briefing"
        - "how was my week?" -> action:"summarize", target:"briefing"

        CONVERSATIONAL / ACKNOWLEDGMENT RULES:
        - "thanks for the feedback" / "got it" / "I agree" / "sounds good" -> action:"chat", target:null, confidence:0.9
        - "I will do better in the future" / "that's a good point" -> action:"chat", target:null, confidence:0.9
        - "yes" / "no" / "okay" / "sure" -> resolve from conversation context if possible; if context has a pending action, complete it. Otherwise action:"chat"
        - If a message is PRIMARILY conversational but mentions a task by name AND contains a clear command (e.g. "mark it as done"), extract the command as the intent — do NOT use action:"chat"
        - If a message is conversational with NO embedded command, use action:"chat" with confidence:0.9
        - Do NOT ask for clarification on purely conversational messages

        Output the JSON object now. Nothing else.
        """
    }

    private func timezoneOffsetString() -> String {
        let tz = TimeZone(identifier: userTimezone) ?? TimeZone.current
        let seconds = tz.secondsFromGMT()
        let hours = abs(seconds) / 3600
        let minutes = (abs(seconds) % 3600) / 60
        let sign = seconds >= 0 ? "+" : "-"
        return String(format: "%@%02d:%02d", sign, hours, minutes)
    }

    private func buildIntentRecognitionPrompt(query: String, conversationTurns: [ConversationTurn], session: ConversationSession) -> String {
        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let today = dateFormatter.string(from: now)

        let dayOfWeekFmt = DateFormatter()
        dayOfWeekFmt.dateFormat = "EEEE"
        let dayOfWeek = dayOfWeekFmt.string(from: now)

        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"
        let currentTime = timeFmt.string(from: now)

        var prompt = "Query: \"\(query)\"\nToday: \(today) (\(dayOfWeek)), current time: \(currentTime), timezone: \(userTimezone)"

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
