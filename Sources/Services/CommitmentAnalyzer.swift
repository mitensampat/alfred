import Foundation

class CommitmentAnalyzer {
    private let anthropicApiKey: String
    private let model: String
    private let userInfo: UserInfo

    struct UserInfo {
        let name: String
        let email: String
    }

    init(anthropicApiKey: String, model: String, userInfo: UserInfo) {
        self.anthropicApiKey = anthropicApiKey
        self.model = model
        self.userInfo = userInfo
    }

    // MARK: - Main Analysis

    /// Analyze messages for commitments using Claude API
    func analyzeMessages(
        _ messages: [Message],
        platform: MessagePlatform,
        threadName: String,
        threadId: String
    ) async throws -> CommitmentExtraction {
        // Calculate participation stats for learning
        let userMessageCount = messages.filter { $0.direction == .outgoing }.count
        let totalMessageCount = messages.count

        // Record participation for contact learning
        let uniqueSenders = Set(messages.map { $0.sender }).count
        ContactLearner.shared.recordParticipation(
            platform: platform.rawValue,
            threadId: threadId,
            threadName: threadName,
            isGroup: totalMessageCount > 2 && uniqueSenders > 2,
            userMessages: userMessageCount,
            totalMessages: totalMessageCount
        )

        // Build context for Claude
        let messageContexts = messages.map { message in
            CommitmentExtractionRequest.MessageContext(
                sender: message.sender,
                senderName: message.senderName,  // Pass the actual sender name for group chats
                content: message.content,
                timestamp: message.timestamp,
                isFromUser: message.direction == .outgoing
            )
        }

        let request = CommitmentExtractionRequest(
            messages: messageContexts,
            userInfo: CommitmentExtractionRequest.UserInfo(
                name: userInfo.name,
                email: userInfo.email
            ),
            threadName: threadName  // Pass thread name so AI knows the counterparty
        )

        // Call Claude API with platform/thread context for historical learning
        let extractedCommitments = try await extractCommitmentsWithLLM(request, platform: platform.rawValue, threadId: threadId)

        // Convert to Commitment objects
        let commitments = extractedCommitments.commitments.compactMap { extracted -> Commitment? in
            // Parse type
            guard let type = parseCommitmentType(extracted.type) else {
                print("⚠️  Skipping commitment with invalid type: \(extracted.type)")
                return nil
            }

            // Parse priority
            let priority = parsePriority(extracted.priority)

            // Parse due date
            var dueDate: Date?
            if let dueDateString = extracted.dueDate {
                let formatter = ISO8601DateFormatter()
                dueDate = formatter.date(from: dueDateString)
            }

            // Determine who committed and to whom
            let (committedBy, committedTo) = determineParties(
                type: type,
                extracted: extracted,
                userName: userInfo.name,
                threadName: threadName
            )

            // Build original context from messages
            let relevantMessages = messages.filter { message in
                message.content.localizedCaseInsensitiveContains(extracted.commitmentText.prefix(20))
            }
            let context = relevantMessages.map { "\($0.sender): \($0.content)" }.joined(separator: "\n")

            return Commitment(
                type: type,
                status: .open,
                title: extracted.title,
                commitmentText: extracted.commitmentText,
                committedBy: committedBy,
                committedTo: committedTo,
                sourcePlatform: platform,
                sourceThread: threadName,
                dueDate: dueDate,
                priority: priority,
                originalContext: context.isEmpty ? extracted.context : context
            )
        }

        let dateRange = CommitmentExtraction.SourceInfo.DateRange(
            from: messages.first?.timestamp ?? Date(),
            to: messages.last?.timestamp ?? Date()
        )

        return CommitmentExtraction(
            commitments: commitments,
            analysisDate: Date(),
            sourceInfo: CommitmentExtraction.SourceInfo(
                platform: platform,
                threadId: threadId,
                threadName: threadName,
                messagesAnalyzed: messages.count,
                dateRange: dateRange
            )
        )
    }

    // MARK: - LLM Extraction

    private func extractCommitmentsWithLLM(_ request: CommitmentExtractionRequest, platform: String, threadId: String) async throws -> CommitmentExtractionResponse {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(anthropicApiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")

        // Build prompt with historical context
        let prompt = buildExtractionPrompt(request, platform: platform, threadId: threadId)

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "messages": [
                [
                    "role": "user",
                    "content": prompt
                ]
            ]
        ]

        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CommitmentAnalyzerError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw CommitmentAnalyzerError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        // Parse Claude response
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let content = json?["content"] as? [[String: Any]],
              let firstContent = content.first,
              let text = firstContent["text"] as? String else {
            throw CommitmentAnalyzerError.invalidResponse
        }

        // Parse JSON from Claude's response
        return try parseCommitmentResponse(text)
    }

    /// Check if a string looks like a raw WhatsApp/platform ID rather than a human name
    private func isRawId(_ name: String) -> Bool {
        // Base64-encoded IDs (e.g. CM2E5M0GIABIAZABAPABAg==)
        if name.hasSuffix("==") || name.hasSuffix("=") { return true }
        // Phone numbers or numeric IDs
        if name.allSatisfy({ $0.isNumber || $0 == "+" || $0 == "-" || $0 == " " }) && name.count > 5 { return true }
        // Email-style IDs
        if name.contains("@") && !name.contains(" ") { return true }
        return false
    }

    private func buildExtractionPrompt(_ request: CommitmentExtractionRequest, platform: String, threadId: String) -> String {
        // Collect unique participant names from group chats (for non-user messages with sender names)
        // Filter out raw IDs — only include actual human-readable names
        let otherParticipants = Set(request.messages.compactMap { message -> String? in
            guard !message.isFromUser else { return nil }
            let name = message.senderName ?? message.sender
            // Skip raw platform IDs — they're not usable as counterparty names
            if isRawId(name) { return nil }
            return name
        })
        let isGroupChat = otherParticipants.count > 1

        // Build messages with actual sender names (not just thread name)
        let messagesText = request.messages.map { message in
            let sender: String
            if message.isFromUser {
                sender = request.userInfo.name
            } else {
                // Use sender name if available (important for groups)
                // If only a raw ID is available, use "Unknown participant" to avoid polluting commitment data
                let rawName = message.senderName ?? message.sender
                sender = isRawId(rawName) ? "Unknown participant" : rawName
            }
            let timestamp = ISO8601DateFormatter().string(from: message.timestamp)
            return "[\(timestamp)] \(sender): \(message.content)"
        }.joined(separator: "\n")

        // Calculate user participation stats
        let totalMessages = request.messages.count
        let userMessages = request.messages.filter { $0.isFromUser }
        let userMessageCount = userMessages.count
        let participationPercent = totalMessages > 0 ? Int((Double(userMessageCount) / Double(totalMessages)) * 100) : 0

        // Check if user was mentioned by name in others' messages
        let userName = request.userInfo.name
        let userFirstName = userName.split(separator: " ").first.map(String.init) ?? userName
        let userMentioned = request.messages.filter { !$0.isFromUser }.contains { msg in
            msg.content.localizedCaseInsensitiveContains(userName) ||
            msg.content.localizedCaseInsensitiveContains(userFirstName)
        }

        // Determine participation level
        let participationLevel: String
        let participationGuidance: String

        if userMessageCount == 0 {
            participationLevel = "PASSIVE OBSERVER (0 messages)"
            participationGuidance = """
            CRITICAL: The user sent NO messages in this conversation. They are a PASSIVE OBSERVER only.
            - Do NOT extract any "i_owe" commitments - the user made no promises since they didn't speak
            - Only extract "they_owe" if someone explicitly promised something TO the user BY NAME
            - Commitments between OTHER people in this group should be IGNORED entirely
            - If no one directly addressed the user by name, return an empty commitments array
            """
        } else if participationPercent < 20 {
            participationLevel = "MINIMAL PARTICIPANT (\(userMessageCount) of \(totalMessages) messages, \(participationPercent)%)"
            participationGuidance = """
            The user had minimal participation in this conversation.
            - Only extract "i_owe" from the user's actual messages
            - Only extract "they_owe" if explicitly directed at the user
            - Be very conservative - don't attribute group commitments to this user
            """
        } else {
            participationLevel = "ACTIVE PARTICIPANT (\(userMessageCount) of \(totalMessages) messages, \(participationPercent)%)"
            participationGuidance = """
            The user actively participated in this conversation.
            - Extract "i_owe" from the user's messages where they made commitments
            - Extract "they_owe" where others made commitments to the user
            """
        }

        // Get correction context from past user feedback
        let correctionContext = CorrectionTracker.shared.getCorrectionsForPrompt(itemType: "Commitment", limit: 5)

        // Get historical thread context from contact learning
        let historicalContext = ContactLearner.shared.getPromptContext(platform: platform, threadId: threadId)

        var prompt = """
        You are analyzing a conversation to extract commitments. A commitment is a promise or agreement to do something.

        ## USER PARTICIPATION ANALYSIS
        User name: \(userName)
        Participation level: \(participationLevel)
        User was directly mentioned by others: \(userMentioned ? "Yes" : "No")

        \(participationGuidance)
        """

        // Add historical thread context if available
        if !historicalContext.isEmpty {
            prompt += "\n\n\(historicalContext)"
        }

        // Add workflow patterns learned from user behavior
        let workflowContext = WorkflowLearningService.shared.getPatternContextForAI()
        if !workflowContext.isEmpty {
            prompt += "\n\n\(workflowContext)"
        }

        prompt += """


        ## COMMITMENT TYPES

        1. **I Owe** (commitments made BY the user \(userName)):
           - ONLY from messages actually sent by \(userName)
           - Look for: "I'll send", "I will share", "Let me get back", "I'll have it ready"

        2. **They Owe Me** (commitments made TO the user by others):
           - Must be explicitly directed at \(userName)
           - The other person must commit to delivering something TO the user
           - Commitments between other people (not involving \(userName)) should be IGNORED

        For each valid commitment found, extract:
        - type: "i_owe" or "they_owe"
        - title: A brief 3-8 word description using ONLY words that appear in the actual messages. Do NOT invent names, products, or topics that aren't explicitly mentioned in the conversation text above. If the message is vague (e.g. "I'll give it that skill"), use the vague language — do NOT guess what "it" refers to.
        - commitmentText: The exact phrase containing the commitment (copy verbatim from the message)
        - committedBy: Name of person making the commitment. MUST be a real human name from the conversation. If you only have a raw ID (e.g. base64 string, phone number), use "Unknown".
        - committedTo: Name of person receiving the commitment. Same rule — real names only, "Unknown" if unresolvable.
        - dueDate: ISO8601 date if mentioned (e.g., "tomorrow", "Friday", "next week")
        - priority: "critical", "high", "medium", or "low" based on urgency indicators
        - context: Surrounding context from the message
        - confidence: 0.0 to 1.0 score of how confident you are this is a real commitment. Lower confidence (0.6-0.7) when the commitment is vague or the subject is unclear. Higher confidence (0.8+) only when the commitment is specific and unambiguous.

        Only extract commitments with confidence >= 0.6.
        """

        // Add learning from past corrections if available
        if !correctionContext.isEmpty {
            prompt += """

        ## LEARNING FROM PAST CORRECTIONS
        The user has previously rejected or corrected these items. Avoid extracting similar items:
        \(correctionContext)
        """
        }

        // Build counterparty info section depending on whether it's a group
        let counterpartySection: String
        let exampleCommittedTo: String
        if isGroupChat {
            let participantsList = otherParticipants.sorted().joined(separator: ", ")
            counterpartySection = """
        ## PARTICIPANTS (GROUP CHAT)
        This is a GROUP chat named: "\(request.threadName)"
        Participants (besides \(userName)): \(participantsList)

        CRITICAL for group chats:
        - Use the ACTUAL PERSON'S NAME for committedBy/committedTo fields (e.g., "Alex", "John")
        - Do NOT use the group name as the person (e.g., NOT "Team - Alex Directs")
        - Each message already shows WHO said it - use that person's name
        - If someone says "I'll send the deck", committedBy = that person's name
        """
            exampleCommittedTo = otherParticipants.first ?? request.threadName
        } else {
            counterpartySection = """
        ## COUNTERPARTY
        The other person in this conversation is: \(request.threadName)
        Use "\(request.threadName)" (not raw IDs) for committedBy/committedTo fields.
        """
            exampleCommittedTo = request.threadName
        }

        prompt += """

        \(counterpartySection)

        Conversation:
        \(messagesText)

        Return ONLY valid JSON in this exact format:
        {
          "commitments": [
            {
              "type": "i_owe",
              "title": "Send Q4 metrics deck",
              "commitmentText": "I'll send you the Q4 metrics by EOW",
              "committedBy": "\(request.userInfo.name)",
              "committedTo": "\(exampleCommittedTo)",
              "dueDate": "2026-01-24T23:59:59Z",
              "priority": "high",
              "context": "Discussion about quarterly review",
              "confidence": 0.9
            }
          ]
        }

        If the user is a passive observer with no valid commitments involving them, return: {"commitments": []}
        """
        return prompt
    }

    private func parseCommitmentResponse(_ text: String) throws -> CommitmentExtractionResponse {
        // Try to extract JSON from the response
        var jsonText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove markdown code blocks if present
        if jsonText.hasPrefix("```json") {
            jsonText = jsonText.replacingOccurrences(of: "```json", with: "")
            jsonText = jsonText.replacingOccurrences(of: "```", with: "")
            jsonText = jsonText.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if jsonText.hasPrefix("```") {
            jsonText = String(jsonText.dropFirst(3))
            if let end = jsonText.range(of: "```") {
                jsonText = String(jsonText[..<end.lowerBound])
            }
            jsonText = jsonText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Extract just the JSON object — Claude sometimes appends explanatory text after the JSON
        if let start = jsonText.firstIndex(of: "{") {
            var depth = 0
            var endIndex = jsonText.endIndex
            for i in jsonText.indices[start...] {
                if jsonText[i] == "{" { depth += 1 }
                else if jsonText[i] == "}" { depth -= 1 }
                if depth == 0 {
                    endIndex = jsonText.index(after: i)
                    break
                }
            }
            jsonText = String(jsonText[start..<endIndex])
        }

        guard let data = jsonText.data(using: .utf8) else {
            throw CommitmentAnalyzerError.invalidJSON
        }

        let decoder = JSONDecoder()
        return try decoder.decode(CommitmentExtractionResponse.self, from: data)
    }

    // MARK: - Helpers

    private func parseCommitmentType(_ typeString: String) -> Commitment.CommitmentType? {
        switch typeString.lowercased() {
        case "i_owe", "i owe", "user":
            return .iOwe
        case "they_owe", "they owe", "they_owe_me", "other":
            return .theyOwe
        default:
            return nil
        }
    }

    private func parsePriority(_ priorityString: String) -> UrgencyLevel {
        switch priorityString.lowercased() {
        case "critical", "urgent":
            return .critical
        case "high", "important":
            return .high
        case "low":
            return .low
        default:
            return .medium
        }
    }

    private func determineParties(
        type: Commitment.CommitmentType,
        extracted: CommitmentExtractionResponse.ExtractedCommitment,
        userName: String,
        threadName: String = ""
    ) -> (committedBy: String, committedTo: String) {
        switch type {
        case .iOwe:
            // User committed to someone — counterparty is committedTo
            var to = extracted.committedTo.isEmpty ? "Unknown" : extracted.committedTo
            // Guard: if AI returned the user's own name as the counterparty, use thread name instead
            if to.lowercased() == userName.lowercased() {
                to = threadName.isEmpty ? "Unknown" : threadName
            }
            // Guard: if AI returned a raw ID instead of a name, use thread name
            if isRawId(to) {
                to = threadName.isEmpty ? "Unknown" : threadName
            }
            return (userName, to)
        case .theyOwe:
            // Someone committed to user — counterparty is committedBy
            var by = extracted.committedBy.isEmpty ? "Unknown" : extracted.committedBy
            // Guard: if AI returned the user's own name as the counterparty, use thread name instead
            if by.lowercased() == userName.lowercased() {
                by = threadName.isEmpty ? "Unknown" : threadName
            }
            // Guard: if AI returned a raw ID instead of a name, use thread name
            if isRawId(by) {
                by = threadName.isEmpty ? "Unknown" : threadName
            }
            return (by, userName)
        }
    }

    // MARK: - Pattern-Based Detection (Fallback)

    /// Simple pattern-based detection if LLM is unavailable
    func analyzeMessagesWithPatterns(
        _ messages: [Message],
        platform: MessagePlatform,
        threadName: String,
        threadId: String
    ) -> CommitmentExtraction {
        var commitments: [Commitment] = []

        let iOwePatterns = [
            "i'll send", "i will send", "will share", "i'll share",
            "let me get back", "i'll get back", "i'll have it ready",
            "i promise to", "i need to send you", "i should share"
        ]

        let theyOwePatterns = [
            "will send you", "i'll send it to you", "you'll receive",
            "can you send", "could you share", "please send me",
            "you mentioned you'd", "waiting for your"
        ]

        for message in messages {
            let lowercased = message.content.lowercased()

            // Check "I Owe" patterns
            for pattern in iOwePatterns {
                if lowercased.contains(pattern) && message.direction == .outgoing {
                    let commitment = Commitment(
                        type: .iOwe,
                        status: .open,
                        title: extractTitle(from: message.content),
                        commitmentText: message.content,
                        committedBy: userInfo.name,
                        committedTo: threadName,
                        sourcePlatform: platform,
                        sourceThread: threadName,
                        dueDate: extractDeadline(from: message.content),
                        priority: inferPriority(from: message.content),
                        originalContext: message.content
                    )
                    commitments.append(commitment)
                    break
                }
            }

            // Check "They Owe" patterns
            for pattern in theyOwePatterns {
                if lowercased.contains(pattern) && message.direction == .incoming {
                    let commitment = Commitment(
                        type: .theyOwe,
                        status: .open,
                        title: extractTitle(from: message.content),
                        commitmentText: message.content,
                        committedBy: message.sender,
                        committedTo: userInfo.name,
                        sourcePlatform: platform,
                        sourceThread: threadName,
                        dueDate: extractDeadline(from: message.content),
                        priority: inferPriority(from: message.content),
                        originalContext: message.content
                    )
                    commitments.append(commitment)
                    break
                }
            }
        }

        let dateRange = CommitmentExtraction.SourceInfo.DateRange(
            from: messages.first?.timestamp ?? Date(),
            to: messages.last?.timestamp ?? Date()
        )

        return CommitmentExtraction(
            commitments: commitments,
            analysisDate: Date(),
            sourceInfo: CommitmentExtraction.SourceInfo(
                platform: platform,
                threadId: threadId,
                threadName: threadName,
                messagesAnalyzed: messages.count,
                dateRange: dateRange
            )
        )
    }

    private func extractTitle(from text: String) -> String {
        // Simple title extraction - take first 50 chars
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(50))
    }

    private func extractDeadline(from text: String) -> Date? {
        let lowercased = text.lowercased()

        if lowercased.contains("today") {
            return Calendar.current.startOfDay(for: Date())
        }

        if lowercased.contains("tomorrow") {
            return Calendar.current.date(byAdding: .day, value: 1, to: Date())
        }

        if lowercased.contains("this week") || lowercased.contains("eow") {
            let today = Date()
            let weekday = Calendar.current.component(.weekday, from: today)
            let daysUntilFriday = (6 - weekday + 7) % 7
            return Calendar.current.date(byAdding: .day, value: daysUntilFriday, to: today)
        }

        if lowercased.contains("next week") {
            return Calendar.current.date(byAdding: .weekOfYear, value: 1, to: Date())
        }

        // Default: 3 days from now
        return Calendar.current.date(byAdding: .day, value: 3, to: Date())
    }

    private func inferPriority(from text: String) -> UrgencyLevel {
        let lowercased = text.lowercased()

        let criticalKeywords = ["urgent", "asap", "critical", "immediately", "right away"]
        let highKeywords = ["important", "soon", "this week", "by friday", "need to"]
        let lowKeywords = ["sometime", "eventually", "no rush", "when you can"]

        if criticalKeywords.contains(where: { lowercased.contains($0) }) {
            return .critical
        }

        if highKeywords.contains(where: { lowercased.contains($0) }) {
            return .high
        }

        if lowKeywords.contains(where: { lowercased.contains($0) }) {
            return .low
        }

        return .medium
    }

    // MARK: - Closure Detection

    /// Analyze messages for commitment closure signals
    /// Returns detected closures with confidence scores for auto-closing
    func detectClosures(
        openCommitments: [(hash: String, title: String, type: String, counterparty: String)],
        messages: [Message],
        threadName: String
    ) async throws -> [ClosureDetection] {
        guard !openCommitments.isEmpty && !messages.isEmpty else {
            return []
        }

        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(anthropicApiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")

        let prompt = buildClosureDetectionPrompt(
            openCommitments: openCommitments,
            messages: messages,
            threadName: threadName
        )

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
            "messages": [
                [
                    "role": "user",
                    "content": prompt
                ]
            ]
        ]

        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CommitmentAnalyzerError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw CommitmentAnalyzerError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        // Parse Claude response
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let content = json?["content"] as? [[String: Any]],
              let firstContent = content.first,
              let text = firstContent["text"] as? String else {
            throw CommitmentAnalyzerError.invalidResponse
        }

        return try parseClosureResponse(text)
    }

    private func buildClosureDetectionPrompt(
        openCommitments: [(hash: String, title: String, type: String, counterparty: String)],
        messages: [Message],
        threadName: String
    ) -> String {
        let commitmentsText = openCommitments.enumerated().map { index, commitment in
            """
            [\(index + 1)] Hash: \(commitment.hash)
                Title: \(commitment.title)
                Type: \(commitment.type)
                Counterparty: \(commitment.counterparty)
            """
        }.joined(separator: "\n")

        let messagesText = messages.suffix(50).map { message in
            let sender = message.direction == .outgoing ? userInfo.name : message.senderName ?? message.sender
            let timestamp = ISO8601DateFormatter().string(from: message.timestamp ?? Date())
            return "[\(timestamp)] \(sender): \(message.content)"
        }.joined(separator: "\n")

        // Include learned patterns from user feedback to improve accuracy
        let workflowContext = WorkflowLearningService.shared.getPatternContextForAI()
        let learningSection = workflowContext.isEmpty ? "" : """

        ## LEARNED PATTERNS (from your previous feedback)
        \(workflowContext)
        """

        return """
        You are analyzing recent messages to detect if any open commitments have been fulfilled or closed.

        ## OPEN COMMITMENTS
        These are commitments that are currently marked as open/pending:
        \(commitmentsText)

        ## RECENT MESSAGES
        Thread: \(threadName)
        \(messagesText)
        \(learningSection)

        ## CLOSURE SIGNALS TO LOOK FOR

        1. **Direct Completion Acknowledgment** (highest confidence):
           - "Done", "Sent", "Here's the...", "I've shared..."
           - The committer explicitly stating they fulfilled it

        2. **Recipient Acknowledgment** (high confidence):
           - "Thanks!", "Got it", "Received", "Perfect"
           - The person who was owed acknowledging receipt

        3. **Context Completion** (medium confidence):
           - Discussion moving past the topic
           - References to the item being complete
           - Follow-up questions about delivered item

        4. **Time-Based Staleness** (low confidence):
           - No mention in >14 days
           - Topic seems abandoned

        ## OUTPUT FORMAT
        Return JSON with closures detected:
        {
          "closures": [
            {
              "commitmentHash": "hash_value",
              "closureSignal": "Recipient said 'Thanks, got the deck!'",
              "confidence": 0.95,
              "autoClose": true,
              "reason": "Direct acknowledgment from recipient"
            }
          ]
        }

        Guidelines:
        - confidence >= 0.85: Set autoClose = true (safe to auto-close)
        - confidence 0.6-0.84: Set autoClose = false (suggest to user)
        - confidence < 0.6: Do not include in results

        If no closures detected, return: {"closures": []}
        """
    }

    private func parseClosureResponse(_ text: String) throws -> [ClosureDetection] {
        var jsonText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove markdown code blocks if present
        if jsonText.hasPrefix("```json") {
            jsonText = jsonText.replacingOccurrences(of: "```json", with: "")
            jsonText = jsonText.replacingOccurrences(of: "```", with: "")
            jsonText = jsonText.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if jsonText.hasPrefix("```") {
            jsonText = String(jsonText.dropFirst(3))
            if let end = jsonText.range(of: "```") {
                jsonText = String(jsonText[..<end.lowerBound])
            }
            jsonText = jsonText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Extract just the JSON object — Claude sometimes appends explanatory text after the JSON
        if let start = jsonText.firstIndex(of: "{") {
            var depth = 0
            var endIndex = jsonText.endIndex
            for i in jsonText.indices[start...] {
                if jsonText[i] == "{" { depth += 1 }
                else if jsonText[i] == "}" { depth -= 1 }
                if depth == 0 {
                    endIndex = jsonText.index(after: i)
                    break
                }
            }
            jsonText = String(jsonText[start..<endIndex])
        }

        guard let data = jsonText.data(using: .utf8) else {
            throw CommitmentAnalyzerError.invalidJSON
        }

        let response = try JSONDecoder().decode(ClosureDetectionResponse.self, from: data)
        return response.closures
    }
}

// MARK: - Closure Detection Models

struct ClosureDetection: Codable {
    let commitmentHash: String
    let closureSignal: String
    let confidence: Double
    let autoClose: Bool
    let reason: String
}

struct ClosureDetectionResponse: Codable {
    let closures: [ClosureDetection]
}

// MARK: - Errors

enum CommitmentAnalyzerError: Error, LocalizedError {
    case invalidResponse
    case apiError(statusCode: Int, message: String)
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from API"
        case .apiError(let statusCode, let message):
            return "API error (\(statusCode)): \(message)"
        case .invalidJSON:
            return "Failed to parse commitment JSON"
        }
    }
}
