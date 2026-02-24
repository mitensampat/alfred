import Foundation

class ClaudeAIService {
    private let apiKey: String
    private let model: String
    private let messageModel: String
    private let baseURL: String

    init(config: AIConfig) {
        self.apiKey = config.anthropicApiKey
        self.model = config.model
        self.messageModel = config.effectiveMessageModel
        self.baseURL = config.effectiveBaseUrl
    }

    func analyzeMessages(_ threads: [MessageThread], favoriteNames: [String] = []) async throws -> [MessageSummary] {
        print("  ⚡ Using \(messageModel) for fast message analysis")
        var summaries: [MessageSummary] = []

        // Process threads in parallel batches for speed
        let batchSize = 5
        for batchStart in stride(from: 0, to: threads.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, threads.count)
            let batch = Array(threads[batchStart..<batchEnd])

            // Analyze batch in parallel
            let batchSummaries = try await withThrowingTaskGroup(of: MessageSummary.self) { group in
                for thread in batch {
                    group.addTask {
                        try await self.analyzeThread(thread, useModel: self.messageModel, favoriteNames: favoriteNames)
                    }
                }

                var results: [MessageSummary] = []
                for try await summary in group {
                    results.append(summary)
                }
                return results
            }

            summaries.append(contentsOf: batchSummaries)
            print("  ✓ Analyzed batch \(batchStart/batchSize + 1) (\(batchSummaries.count) threads)")
        }

        return summaries.sorted { $0.urgency > $1.urgency }
    }

    func analyzeFocusedThread(_ thread: MessageThread) async throws -> FocusedThreadAnalysis {
        let messagesText = thread.messages.map { msg in
            "[\(msg.timestamp.formatted())] \(msg.direction == .incoming ? thread.contactName ?? "Unknown" : "You"): \(msg.content)"
        }.joined(separator: "\n")

        // Calculate user participation
        let totalMessages = thread.messages.count
        let userMessages = thread.messages.filter { $0.direction == .outgoing }
        let userMessageCount = userMessages.count
        let participationPercent = totalMessages > 0 ? Int((Double(userMessageCount) / Double(totalMessages)) * 100) : 0

        // Record participation for contact learning
        let uniqueSenders = Set(thread.messages.map { $0.sender }).count
        ContactLearner.shared.recordParticipation(
            platform: thread.platform.rawValue,
            threadId: thread.contactIdentifier,
            threadName: thread.contactName ?? thread.contactIdentifier,
            isGroup: totalMessages > 2 && uniqueSenders > 2,
            userMessages: userMessageCount,
            totalMessages: totalMessages
        )

        // Get historical context from contact learning
        let historicalContext = ContactLearner.shared.getPromptContext(
            platform: thread.platform.rawValue,
            threadId: thread.contactIdentifier
        )

        // Build participation context for the prompt
        let participationContext: String
        let actionItemGuidance: String

        if userMessageCount == 0 {
            participationContext = """
            ## USER PARTICIPATION: PASSIVE OBSERVER
            The user (Miten/You) sent 0 messages in this conversation. They are ONLY OBSERVING.
            """
            actionItemGuidance = """
            CRITICAL RULE FOR ACTION ITEMS:
            - Since the user sent NO messages, they are a PASSIVE OBSERVER in this conversation
            - Do NOT extract action items - the user was not addressed or involved
            - Conversations between OTHER people in a group do NOT create action items for the observer
            - Return an EMPTY actionItems array: []
            - Only summarize what was discussed between the other participants
            """
        } else if participationPercent < 20 {
            participationContext = """
            ## USER PARTICIPATION: MINIMAL (\(userMessageCount) of \(totalMessages) messages, \(participationPercent)%)
            The user had minimal participation in this conversation.
            """
            actionItemGuidance = """
            ACTION ITEM GUIDANCE:
            - Only extract action items that the user explicitly committed to in their \(userMessageCount) message(s)
            - Only extract action items that were explicitly assigned TO the user by name
            - Do NOT infer action items from conversations between other people
            - Be very conservative - if unclear whether it's for the user, don't include it
            """
        } else {
            participationContext = """
            ## USER PARTICIPATION: ACTIVE (\(userMessageCount) of \(totalMessages) messages, \(participationPercent)%)
            The user actively participated in this conversation.
            """
            actionItemGuidance = """
            ACTION ITEM GUIDANCE:
            - Extract action items the user committed to or were assigned to them
            - Focus on what the OTHER person asked, requested, or expects from the user
            """
        }

        var prompt = """
        Analyze this entire WhatsApp message thread and provide a detailed analysis.

        IMPORTANT: In this thread, "You" refers to the user (Miten), and "\(thread.contactName ?? "Unknown")" is the other person/group.

        \(participationContext)

        \(actionItemGuidance)
        """

        // Add historical context if available
        if !historicalContext.isEmpty {
            prompt += "\n\n\(historicalContext)"
        }

        prompt += """


        Provide:
        1. A comprehensive summary (3-5 sentences) - be clear about who said what
        2. Action items for MITEN (the user marked as "You") - ONLY if they participated and were asked to do something
        3. Key quotes or messages from the OTHER PERSON that are most important (include exact quotes with timestamps)
        4. Overall context and what this conversation is about
        5. Any deadlines, commitments, or time-sensitive information

        Message thread:
        \(messagesText)

        Respond in JSON format:
        {
            "summary": "comprehensive summary of the conversation",
            "actionItems": [
                {"item": "action description", "priority": "high|medium|low", "deadline": "optional deadline if mentioned"}
            ],
            "keyQuotes": [
                {"timestamp": "timestamp", "speaker": "name", "quote": "exact quote"}
            ],
            "context": "overall context of the conversation",
            "timeSensitive": ["any deadlines or time-sensitive info"]
        }

        If the user is a passive observer with no action items, return: "actionItems": []
        """

        let response = try await sendRequest(prompt: prompt)
        let analysis = try parseFocusedThreadAnalysis(response)

        return FocusedThreadAnalysis(
            thread: thread,
            summary: analysis.summary,
            actionItems: analysis.actionItems.map { FocusedThreadAnalysis.FocusedActionItem(item: $0.item, priority: $0.priority, deadline: $0.deadline) },
            keyQuotes: analysis.keyQuotes.map { FocusedThreadAnalysis.KeyQuote(timestamp: $0.timestamp, speaker: $0.speaker, quote: $0.quote) },
            context: analysis.context,
            timeSensitive: analysis.timeSensitive
        )
    }

    private func analyzeThread(_ thread: MessageThread, useModel: String? = nil, favoriteNames: [String] = []) async throws -> MessageSummary {
        let recentMessages = Array(thread.messages.prefix(20))
        let messagesText = recentMessages.map { msg in
            "[\(msg.timestamp.formatted())] \(msg.direction == .incoming ? thread.contactName ?? "Unknown" : "You"): \(msg.content)"
        }.joined(separator: "\n")

        // Calculate user participation
        let totalMessages = recentMessages.count
        let userMessages = recentMessages.filter { $0.direction == .outgoing }
        let userMessageCount = userMessages.count
        let participationPercent = totalMessages > 0 ? Int((Double(userMessageCount) / Double(totalMessages)) * 100) : 0

        // Record participation for contact learning
        let uniqueSenders = Set(recentMessages.map { $0.sender }).count
        ContactLearner.shared.recordParticipation(
            platform: thread.platform.rawValue,
            threadId: thread.contactIdentifier,
            threadName: thread.contactName ?? thread.contactIdentifier,
            isGroup: totalMessages > 2 && uniqueSenders > 2,
            userMessages: userMessageCount,
            totalMessages: totalMessages
        )

        // Get historical context from contact learning
        let historicalContext = ContactLearner.shared.getPromptContext(
            platform: thread.platform.rawValue,
            threadId: thread.contactIdentifier
        )

        // Check if this thread is from a priority contact/group
        let threadName = thread.contactName ?? ""
        let isFavorite = favoriteNames.contains { favName in
            threadName.localizedCaseInsensitiveContains(favName) || favName.localizedCaseInsensitiveContains(threadName)
        }

        let participationContext: String
        if userMessageCount == 0 {
            participationContext = """
            USER PARTICIPATION: PASSIVE OBSERVER (0 messages sent)
            - Only list action items that were explicitly assigned to the user by name
            - Do NOT infer action items from conversations between other people
            - If no one directly addressed the user, actionItems should be empty
            """
        } else if participationPercent < 20 {
            participationContext = """
            USER PARTICIPATION: MINIMAL (\(userMessageCount) of \(totalMessages) messages, \(participationPercent)%)
            - Only list action items from the user's own messages or explicitly assigned to them
            - Be conservative about inferring action items
            """
        } else {
            participationContext = """
            USER PARTICIPATION: ACTIVE (\(userMessageCount) of \(totalMessages) messages, \(participationPercent)%)
            - List action items the user committed to or were assigned to them
            """
        }

        let priorityContext = isFavorite ? """

        PRIORITY CONTACT: This is a priority contact/group for the user. Weight urgency assessment accordingly - messages from priority contacts warrant faster response times and higher attention.
        """ : ""

        var prompt = """
        Analyze this message thread and provide:
        1. A concise summary (2-3 sentences max)
        2. Urgency level (critical/high/medium/low)
        3. Key action items FOR THE USER (not action items between other people)
        4. Sentiment (positive/neutral/negative/urgent)
        5. Whether it needs a response and suggested response if applicable

        \(participationContext)\(priorityContext)
        """

        // Add historical context if available
        if !historicalContext.isEmpty {
            prompt += "\n\n\(historicalContext)"
        }

        prompt += """


        Message thread:
        \(messagesText)

        Respond in JSON format:
        {
            "summary": "brief summary",
            "urgency": "critical|high|medium|low",
            "actionItems": ["item1", "item2"],
            "sentiment": "sentiment analysis",
            "needsResponse": true|false,
            "suggestedResponse": "optional suggested response"
        }
        """

        let response = try await sendRequest(prompt: prompt, useModel: useModel)
        let analysis = try parseMessageAnalysis(response)

        return MessageSummary(
            thread: thread,
            summary: analysis.summary,
            urgency: analysis.urgency,
            suggestedResponse: analysis.suggestedResponse,
            actionItems: analysis.actionItems,
            sentiment: analysis.sentiment
        )
    }

    func generateMeetingBriefing(
        _ event: CalendarEvent,
        attendees: [AttendeeBriefing],
        notionNotes: [NotionNote] = [],
        notionTasks: [NotionTask] = []
    ) async throws -> MeetingBriefing {
        let attendeesInfo = attendees.map { briefing in
            """
            - \(briefing.attendee.name ?? briefing.attendee.email)
              Bio: \(briefing.bio)
              Recent Activity: \(briefing.recentActivity.joined(separator: ", "))
              \(briefing.companyInfo.map { "Company: \($0.name) - \($0.description ?? "")" } ?? "")
              \(briefing.notes ?? "")
            """
        }.joined(separator: "\n\n")

        // Build Notion context section — include full note content for richer briefings
        var notionContext = ""
        if !notionNotes.isEmpty {
            notionContext += "\n\nRelevant Notion Notes:\n"
            for note in notionNotes.prefix(5) {
                notionContext += "\n### \(note.title)\n"
                if !note.content.isEmpty {
                    notionContext += String(note.content.prefix(800)) + "\n"
                }
            }
        }
        if !notionTasks.isEmpty {
            notionContext += "\n\nActive Tasks:\n"
            notionContext += notionTasks.prefix(5).map { "- \($0.title) (\($0.status))" }.joined(separator: "\n")
        }

        let prompt = """
        Create a 45-60 second executive briefing for this meeting:

        Meeting: \(event.title)
        Time: \(event.startTime.formatted()) - \(event.endTime.formatted())
        Duration: \(Int(event.duration / 60)) minutes
        \(event.location.map { "Location: \($0)" } ?? "")

        Attendees:
        \(attendeesInfo)

        Meeting Description:
        \(event.description ?? "No description provided")
        \(notionContext)

        Provide:
        1. Context: What is this meeting about and why it matters (2-3 sentences). Use the Notion notes content to provide specific, contextual preparation. Reference specific details from notes — names, decisions, action items mentioned.
        2. Key preparation points: What should I review or prepare before this meeting. Reference specific content from Notion notes and active tasks.
        3. Suggested topics: 3-4 topics that should be discussed, informed by the notes and task context.
        4. Quick takes on each attendee: Most relevant facts I should remember

        Format as JSON:
        {
            "context": "brief context",
            "preparation": "preparation notes",
            "suggestedTopics": ["topic1", "topic2", "topic3"],
            "attendeeInsights": {"email": "key insight"}
        }
        """

        let response = try await sendRequest(prompt: prompt)
        let briefingData = try parseBriefingData(response)

        return MeetingBriefing(
            event: event,
            attendeeBriefings: attendees,
            preparation: briefingData.preparation,
            suggestedTopics: briefingData.suggestedTopics,
            context: briefingData.context
        )
    }

    func generateAttentionDefenseReport(
        actionItems: [ActionItem],
        todaySchedule: DailySchedule,
        tomorrowSchedule: DailySchedule,
        currentTime: Date,
        favoriteNames: [String] = []
    ) async throws -> AttentionDefenseReport {
        let calendar = Calendar.current
        let endOfDay = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: currentTime)!
        let timeRemaining = max(0, endOfDay.timeIntervalSince(currentTime))

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let todayStr = dateFormatter.string(from: currentTime)
        let tomorrowDate = calendar.date(byAdding: .day, value: 1, to: currentTime)!
        let tomorrowStr = dateFormatter.string(from: tomorrowDate)

        // Today's remaining meetings
        let remainingMeetings = todaySchedule.events.filter { $0.startTime > currentTime }
        let todayMeetingsText = remainingMeetings.isEmpty ? "No more meetings today." : remainingMeetings.map { event in
            let isExternal = todaySchedule.externalMeetings.contains { $0.title == event.title }
            let extFlag = isExternal ? " [EXTERNAL]" : ""
            return "- \(event.startTime.formatted(.dateTime.hour().minute()))-\(event.endTime.formatted(.dateTime.hour().minute())): \(event.title) (\(Int(event.duration/60))min)\(extFlag)"
        }.joined(separator: "\n")

        // Tomorrow's full schedule
        let tomorrowMeetingCount = tomorrowSchedule.events.count
        let tomorrowMeetingHours = tomorrowSchedule.totalMeetingTime / 3600.0
        let tomorrowFreeTime = tomorrowSchedule.freeSlots.reduce(0.0) { $0 + $1.duration } / 3600.0
        let tomorrowEarlyMeeting = tomorrowSchedule.events.first.map { event in
            "First meeting: \(event.startTime.formatted(.dateTime.hour().minute())) - \(event.title)"
        } ?? "No meetings scheduled"

        let tomorrowMeetingsText = tomorrowSchedule.events.isEmpty ? "No meetings tomorrow." : tomorrowSchedule.events.map { event in
            let isExternal = tomorrowSchedule.externalMeetings.contains { $0.title == event.title }
            let extFlag = isExternal ? " [EXTERNAL]" : ""
            return "- \(event.startTime.formatted(.dateTime.hour().minute()))-\(event.endTime.formatted(.dateTime.hour().minute())): \(event.title) (\(Int(event.duration/60))min)\(extFlag)"
        }.joined(separator: "\n")

        // Action items with rich context - mark items from priority contacts
        let itemsText = actionItems.isEmpty ? "No open tasks found." : actionItems.map { item in
            var line = "- [\(item.id)] [\(item.priority.rawValue.uppercased())] \(item.title)"
            if item.description != item.title {
                line += ": \(item.description)"
            }
            line += " (Category: \(item.category.rawValue), Source: \(item.source.rawValue))"
            // Check if this item is from a priority contact
            let isPriority = favoriteNames.contains { favName in
                item.title.localizedCaseInsensitiveContains(favName) || item.description.localizedCaseInsensitiveContains(favName)
            }
            if isPriority {
                line += " [PRIORITY CONTACT]"
            }
            if let dueDate = item.dueDate {
                let dueDateStr = dateFormatter.string(from: dueDate)
                let isOverdue = dueDate < currentTime
                line += " | Due: \(dueDateStr)\(isOverdue ? " [OVERDUE]" : "")"
            }
            return line
        }.joined(separator: "\n")

        // Priority contacts context
        let priorityContext = favoriteNames.isEmpty ? "" : """

        === PRIORITY CONTACTS ===
        The following are priority contacts/groups. Tasks involving them should be weighted higher in urgency:
        \(favoriteNames.joined(separator: ", "))
        """

        let prompt = """
        You are the executive assistant for a busy professional. It's currently \(currentTime.formatted()) on \(todayStr).
        Workday ends at 18:00. Time remaining today: \(Int(timeRemaining/3600))h \(Int((timeRemaining.truncatingRemainder(dividingBy: 3600))/60))m
        \(priorityContext)

        === TODAY'S REMAINING MEETINGS ===
        \(todayMeetingsText)

        === TOMORROW'S SCHEDULE (\(tomorrowStr)) ===
        \(tomorrowMeetingsText)
        Summary: \(tomorrowMeetingCount) meetings, ~\(String(format: "%.1f", tomorrowMeetingHours))h in meetings, ~\(String(format: "%.1f", tomorrowFreeTime))h free time
        \(tomorrowEarlyMeeting)

        === OPEN TASKS & COMMITMENTS ===
        \(itemsText)

        === YOUR ANALYSIS ===
        Consider:
        1. What MUST be done today? (overdue items, critical priority, time-sensitive responses, items due today, items from priority contacts)
        2. What can safely be pushed to tomorrow or later? Give clear reasoning for each.
        3. Does tomorrow's schedule allow space for pushed items, or is it already packed?
        4. Are there any preparation tasks needed for tomorrow's meetings?
        5. Strategic recommendations: what's the highest-leverage use of remaining time today?

        Format as JSON:
        {
            "mustDoToday": ["task_id1", "task_id2"],
            "canPushOff": [
                {"taskId": "id", "reason": "why it can wait", "suggestedDate": "\(tomorrowStr)", "impact": "low|medium|high"}
            ],
            "recommendations": ["recommendation1", "recommendation2"]
        }

        IMPORTANT: Use the exact task IDs from the brackets (e.g. [abc123]) in mustDoToday and canPushOff.taskId fields.
        Every task should appear in either mustDoToday or canPushOff — don't skip any.
        Keep recommendations actionable and specific (max 3 recommendations).
        Keep reasons brief (under 15 words each).
        """

        // Use higher max_tokens for attention check since response includes all tasks
        let response = try await sendRequest(prompt: prompt, maxTokens: 8192)
        let analysis = try parseAttentionDefenseAnalysis(response, actionItems: actionItems)

        return analysis
    }

    // MARK: - Streaming

    /// Stream text from Claude API, calling onChunk for each text delta
    func streamText(
        prompt: String,
        system: String? = nil,
        maxTokens: Int = 4096,
        useModel: String? = nil,
        onChunk: @escaping (String) -> Void
    ) async throws {
        let url = URL(string: baseURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 120

        var body: [String: Any] = [
            "model": useModel ?? model,
            "max_tokens": maxTokens,
            "stream": true,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]

        if let system = system {
            body["system"] = system
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIError.requestFailed
        }

        if httpResponse.statusCode != 200 {
            // Read the error body
            var errorData = Data()
            for try await byte in bytes {
                errorData.append(byte)
            }
            if let errorBody = String(data: errorData, encoding: .utf8) {
                print("ERROR: HTTP \(httpResponse.statusCode): \(errorBody)")
            }
            throw AIError.requestFailed
        }

        // Parse SSE stream from Anthropic
        // IMPORTANT: Use a Data buffer for proper UTF-8 multi-byte character handling.
        // Individual bytes cannot be converted to Characters — multi-byte UTF-8 chars
        // like em-dash (—, 3 bytes: 0xE2 0x80 0x94) would produce garbage.
        var rawBuffer = Data()
        for try await byte in bytes {
            rawBuffer.append(byte)

            // Only process when we have a newline (complete SSE line)
            guard byte == UInt8(ascii: "\n") else { continue }

            // Try to decode the accumulated buffer as UTF-8
            guard let bufferString = String(data: rawBuffer, encoding: .utf8) else {
                // Incomplete UTF-8 at the boundary — keep accumulating
                continue
            }

            // Split into lines and process each complete line
            let lines = bufferString.components(separatedBy: "\n")
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

                // SSE data lines start with "data: "
                guard trimmed.hasPrefix("data: ") else { continue }
                let jsonStr = String(trimmed.dropFirst(6))

                // [DONE] marker or empty
                if jsonStr == "[DONE]" || jsonStr.isEmpty { continue }

                // Parse the event JSON
                guard let jsonData = jsonStr.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                      let eventType = event["type"] as? String else {
                    continue
                }

                // Extract text delta from content_block_delta events
                if eventType == "content_block_delta",
                   let delta = event["delta"] as? [String: Any],
                   let text = delta["text"] as? String {
                    onChunk(text)
                }
            }

            // Clear the buffer after processing
            rawBuffer = Data()
        }
    }

    /// Stream multi-turn chat from Claude API with full conversation history
    /// messages: array of ["role": "user"/"assistant", "content": "..."] dicts
    func streamChat(
        messages: [[String: String]],
        system: String? = nil,
        maxTokens: Int = 2048,
        onChunk: @escaping (String) -> Void
    ) async throws {
        guard !messages.isEmpty else { return }

        let url = URL(string: baseURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 120

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": true,
            "messages": messages
        ]

        if let system = system {
            body["system"] = system
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIError.requestFailed
        }

        if httpResponse.statusCode != 200 {
            var errorData = Data()
            for try await byte in bytes {
                errorData.append(byte)
            }
            if let errorBody = String(data: errorData, encoding: .utf8) {
                print("ERROR: HTTP \(httpResponse.statusCode): \(errorBody)")
            }
            throw AIError.requestFailed
        }

        // Parse SSE stream — same logic as streamText
        var rawBuffer = Data()
        for try await byte in bytes {
            rawBuffer.append(byte)
            guard byte == UInt8(ascii: "\n") else { continue }
            guard let bufferString = String(data: rawBuffer, encoding: .utf8) else { continue }

            let lines = bufferString.components(separatedBy: "\n")
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("data: ") else { continue }
                let jsonStr = String(trimmed.dropFirst(6))
                if jsonStr == "[DONE]" || jsonStr.isEmpty { continue }

                guard let jsonData = jsonStr.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                      let eventType = event["type"] as? String else { continue }

                if eventType == "content_block_delta",
                   let delta = event["delta"] as? [String: Any],
                   let text = delta["text"] as? String {
                    onChunk(text)
                }
            }
            rawBuffer = Data()
        }
    }

    // MARK: - Private Helpers

    /// Generate text from a prompt (public method for agents)
    func generateText(prompt: String, maxTokens: Int = 4096, useModel: String? = nil) async throws -> String {
        return try await sendRequest(prompt: prompt, maxTokens: maxTokens, useModel: useModel)
    }

    /// Generate text with separate system prompt (better for structured output like JSON)
    func generateText(prompt: String, system: String, maxTokens: Int = 4096, useModel: String? = nil) async throws -> String {
        return try await sendRequest(prompt: prompt, system: system, maxTokens: maxTokens, useModel: useModel)
    }

    private func sendRequest(prompt: String, system: String? = nil, maxTokens: Int = 4096, useModel: String? = nil) async throws -> String {
        let url = URL(string: baseURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 120 // 2 minutes for AI calls (default 60s is too short)

        var body: [String: Any] = [
            "model": useModel ?? model,
            "max_tokens": maxTokens,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]

        if let system = system {
            body["system"] = system
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            print("ERROR: Invalid HTTP response")
            throw AIError.requestFailed
        }

        if httpResponse.statusCode != 200 {
            print("ERROR: HTTP \(httpResponse.statusCode)")
            if let errorBody = String(data: data, encoding: .utf8) {
                print("Response body:", errorBody)
            }
            throw AIError.requestFailed
        }

        let apiResponse = try JSONDecoder().decode(ClaudeResponse.self, from: data)

        // Log if response was cut off
        if let stopReason = apiResponse.stopReason, stopReason == "max_tokens" {
            print("⚠️  WARNING: Response hit max_tokens limit and was truncated")
        }

        return apiResponse.content.first?.text ?? ""
    }

    private func parseMessageAnalysis(_ response: String) throws -> MessageAnalysis {
        guard let jsonString = extractJSON(from: response) else {
            print("ERROR: Could not extract JSON from response:")
            print(response)
            throw AIError.parsingFailed
        }

        guard let jsonData = jsonString.data(using: .utf8) else {
            print("ERROR: Could not convert JSON string to data")
            throw AIError.parsingFailed
        }

        do {
            let analysis = try JSONDecoder().decode(MessageAnalysis.self, from: jsonData)
            return analysis
        } catch {
            print("ERROR: JSON decoding failed:")
            print("Extracted JSON:", jsonString)
            print("Decode error:", error)
            throw AIError.parsingFailed
        }
    }

    private func parseFocusedThreadAnalysis(_ response: String) throws -> FocusedThreadAnalysisData {
        guard let jsonString = extractJSON(from: response) else {
            print("ERROR: Could not extract JSON from response:")
            print(response)
            throw AIError.parsingFailed
        }

        guard let jsonData = jsonString.data(using: .utf8) else {
            print("ERROR: Could not convert JSON string to data")
            throw AIError.parsingFailed
        }

        do {
            let analysis = try JSONDecoder().decode(FocusedThreadAnalysisData.self, from: jsonData)
            return analysis
        } catch {
            print("ERROR: JSON decoding failed:")
            print("Extracted JSON:", jsonString)
            print("Decode error:", error)
            throw AIError.parsingFailed
        }
    }

    private func parseBriefingData(_ response: String) throws -> BriefingData {
        guard let jsonData = extractJSON(from: response)?.data(using: .utf8),
              let data = try? JSONDecoder().decode(BriefingData.self, from: jsonData) else {
            throw AIError.parsingFailed
        }
        return data
    }

    private func parseAttentionDefenseAnalysis(_ response: String, actionItems: [ActionItem]) throws -> AttentionDefenseReport {
        guard let jsonData = extractJSON(from: response)?.data(using: .utf8),
              let analysis = try? JSONDecoder().decode(AttentionDefenseAnalysis.self, from: jsonData) else {
            throw AIError.parsingFailed
        }

        let itemsById = Dictionary(uniqueKeysWithValues: actionItems.map { ($0.id, $0) })

        let mustDoToday = analysis.mustDoToday.compactMap { itemsById[$0] }
        let canPushOff = analysis.canPushOff.compactMap { suggestion -> PushOffSuggestion? in
            guard let item = itemsById[suggestion.taskId] else { return nil }
            let dateFormatter = ISO8601DateFormatter()
            let newDate = dateFormatter.date(from: suggestion.suggestedDate) ?? Date().addingTimeInterval(86400)
            return PushOffSuggestion(
                item: item,
                reason: suggestion.reason,
                suggestedNewDate: newDate,
                impact: PushOffSuggestion.ImpactLevel(rawValue: suggestion.impact) ?? .low
            )
        }

        let upcomingDeadlines = actionItems.filter { item in
            guard let dueDate = item.dueDate else { return false }
            return dueDate.timeIntervalSinceNow < 3600 * 3
        }

        return AttentionDefenseReport(
            currentTime: Date(),
            upcomingDeadlines: upcomingDeadlines,
            criticalTasks: mustDoToday,
            canPushOff: canPushOff,
            mustDoToday: mustDoToday,
            timeAvailable: 0,
            recommendations: analysis.recommendations
        )
    }

    // MARK: - Todo Detection

    func extractTodoFromMessage(_ message: Message) async throws -> TodoItem? {
        // Only process messages from yourself (Miten Sampat)
        guard message.direction == .outgoing,
              !message.content.isEmpty else {
            return nil
        }

        let content = message.content
        let prompt = """
        Analyze this message I sent to myself to see if it contains a todo item or action item.

        Message: "\(content)"

        If this is a todo/action item, extract:
        1. Title (concise summary)
        2. Description (optional details)
        3. Due date (if mentioned, otherwise null)

        Return JSON format:
        {
          "is_todo": true/false,
          "title": "...",
          "description": "...",
          "due_date": "YYYY-MM-DD" or null
        }

        Examples of todo items:
        - "Remember to call John tomorrow"
        - "Need to review Q4 metrics by Friday"
        - "Follow up with Sarah about the proposal"
        - "Buy milk"

        Not todo items:
        - Regular conversations
        - Questions
        - Status updates without action
        """

        let response = try await sendRequest(prompt: prompt)

        guard let jsonData = extractJSON(from: response)?.data(using: .utf8),
              let todoData = try? JSONDecoder().decode(TodoDetection.self, from: jsonData),
              todoData.isTodo else {
            return nil
        }

        var dueDate: Date?
        if let dueDateString = todoData.dueDate {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            dueDate = formatter.date(from: dueDateString)
        }

        return TodoItem(
            title: todoData.title,
            description: todoData.description,
            dueDate: dueDate,
            sourceMessage: message
        )
    }

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
}

// MARK: - Supporting Types

private struct ClaudeResponse: Codable {
    let content: [Content]
    let stopReason: String?

    enum CodingKeys: String, CodingKey {
        case content
        case stopReason = "stop_reason"
    }

    struct Content: Codable {
        let text: String
    }
}

private struct MessageAnalysis: Codable {
    let summary: String
    let urgency: UrgencyLevel
    let actionItems: [String]
    let sentiment: String
    let needsResponse: Bool
    let suggestedResponse: String?
}

private struct BriefingData: Codable {
    let context: String
    let preparation: String
    let suggestedTopics: [String]
}

private struct AttentionDefenseAnalysis: Codable {
    let mustDoToday: [String]
    let canPushOff: [PushOffItem]
    let recommendations: [String]

    struct PushOffItem: Codable {
        let taskId: String
        let reason: String
        let suggestedDate: String
        let impact: String
    }
}

private struct TodoDetection: Codable {
    let isTodo: Bool
    let title: String
    let description: String?
    let dueDate: String?

    enum CodingKeys: String, CodingKey {
        case isTodo = "is_todo"
        case title
        case description
        case dueDate = "due_date"
    }
}

private struct FocusedThreadAnalysisData: Codable {
    let summary: String
    let actionItems: [ActionItemData]
    let keyQuotes: [KeyQuoteData]
    let context: String
    let timeSensitive: [String]

    struct ActionItemData: Codable {
        let item: String
        let priority: String
        let deadline: String?
    }

    struct KeyQuoteData: Codable {
        let timestamp: String
        let speaker: String
        let quote: String
    }
}

struct TodoItem {
    let title: String
    let description: String?
    let dueDate: Date?
    let sourceMessage: Message
}

struct TodoScanResult {
    let messagesScanned: Int
    let todosFound: Int
    let todosCreated: Int
    let duplicatesSkipped: Int
    let notTodos: Int
    let createdTodos: [TodoItem]
    let lookbackDays: Int
}

struct FocusedThreadAnalysis {
    let thread: MessageThread
    let summary: String
    let actionItems: [FocusedActionItem]
    let keyQuotes: [KeyQuote]
    let context: String
    let timeSensitive: [String]

    struct FocusedActionItem {
        let item: String
        let priority: String
        let deadline: String?
    }

    struct KeyQuote {
        let timestamp: String
        let speaker: String
        let quote: String
    }
}

enum AIError: Error, LocalizedError {
    case requestFailed
    case parsingFailed
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .requestFailed:
            return "AI API request failed"
        case .parsingFailed:
            return "Failed to parse AI response"
        case .invalidResponse:
            return "Invalid response from AI"
        }
    }
}
