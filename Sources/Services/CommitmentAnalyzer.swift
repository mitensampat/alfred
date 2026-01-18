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
        // Build context for Claude
        let messageContexts = messages.map { message in
            CommitmentExtractionRequest.MessageContext(
                sender: message.sender,
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
            )
        )

        // Call Claude API
        let extractedCommitments = try await extractCommitmentsWithLLM(request)

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
                userName: userInfo.name
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

    private func extractCommitmentsWithLLM(_ request: CommitmentExtractionRequest) async throws -> CommitmentExtractionResponse {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(anthropicApiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")

        // Build prompt
        let prompt = buildExtractionPrompt(request)

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

    private func buildExtractionPrompt(_ request: CommitmentExtractionRequest) -> String {
        let messagesText = request.messages.map { message in
            let sender = message.isFromUser ? request.userInfo.name : message.sender
            let timestamp = ISO8601DateFormatter().string(from: message.timestamp)
            return "[\(timestamp)] \(sender): \(message.content)"
        }.joined(separator: "\n")

        return """
        You are analyzing a conversation to extract commitments. A commitment is a promise or agreement to do something.

        There are TWO types of commitments to identify:

        1. **I Owe** (commitments made BY the user):
           - Look for phrases like: "I'll send", "I will share", "Let me get back", "I'll have it ready", "I promise to", "I need to send you"
           - The user's name is: \(request.userInfo.name)

        2. **They Owe Me** (commitments made TO the user by others):
           - Look for phrases like: "[Name] will send", "You'll share", "Can you get back", "Please send", "Could you share by", "You mentioned you'd"
           - Look for requests where someone commits to delivering something to the user

        For each commitment found, extract:
        - type: "i_owe" or "they_owe"
        - title: A brief 3-8 word description
        - commitmentText: The exact phrase containing the commitment
        - committedBy: Name of person making the commitment
        - committedTo: Name of person receiving the commitment
        - dueDate: ISO8601 date if mentioned (e.g., "tomorrow", "Friday", "next week")
        - priority: "critical", "high", "medium", or "low" based on urgency indicators
        - context: Surrounding context from the message
        - confidence: 0.0 to 1.0 score of how confident you are this is a real commitment

        Only extract commitments with confidence >= 0.6.

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
              "committedTo": "John Smith",
              "dueDate": "2026-01-24T23:59:59Z",
              "priority": "high",
              "context": "Discussion about quarterly review",
              "confidence": 0.9
            }
          ]
        }
        """
    }

    private func parseCommitmentResponse(_ text: String) throws -> CommitmentExtractionResponse {
        // Try to extract JSON from the response
        var jsonText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove markdown code blocks if present
        if jsonText.hasPrefix("```json") {
            jsonText = jsonText.replacingOccurrences(of: "```json", with: "")
            jsonText = jsonText.replacingOccurrences(of: "```", with: "")
            jsonText = jsonText.trimmingCharacters(in: .whitespacesAndNewlines)
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
        userName: String
    ) -> (committedBy: String, committedTo: String) {
        switch type {
        case .iOwe:
            // User committed to someone
            let to = extracted.committedTo.isEmpty ? "Unknown" : extracted.committedTo
            return (userName, to)
        case .theyOwe:
            // Someone committed to user
            let by = extracted.committedBy.isEmpty ? "Unknown" : extracted.committedBy
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
