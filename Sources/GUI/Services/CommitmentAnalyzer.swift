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

    private func buildExtractionPrompt(_ request: CommitmentExtractionRequest, platform: String, threadId: String) -> String {
        // Collect unique participant names from group chats (for non-user messages with sender names)
        let otherParticipants = Set(request.messages.compactMap { message -> String? in
            guard !message.isFromUser else { return nil }
            return message.senderName ?? message.sender
        })
        let isGroupChat = otherParticipants.count > 1

        // Build messages with actual sender names (not just thread name)
        let messagesText = request.messages.map { message in
            let sender: String
            if message.isFromUser {
                sender = request.userInfo.name
            } else {
                // Use sender name if available (important for groups), otherwise fall back to sender ID
                sender = message.senderName ?? message.sender
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

        // For HotReloadManager, provide appropriate counterparty info
        let counterpartyInfo = isGroupChat
            ? "GROUP: \(request.threadName) (Participants: \(otherParticipants.sorted().joined(separator: ", ")))"
            : request.threadName

        // Try to use external prompt from HotReloadManager (hot-reloadable)
        let externalPrompt = HotReloadManager.shared.getCommitmentExtractionPrompt(
            userName: userName,
            counterpartyName: counterpartyInfo,
            participationLevel: "\(participationLevel)\nUser was directly mentioned by others: \(userMentioned ? "Yes" : "No")",
            participationGuidance: participationGuidance,
            correctionContext: correctionContext.isEmpty ? "" : "## LEARNING FROM PAST CORRECTIONS\nThe user has previously rejected or corrected these items. Avoid extracting similar items:\n\(correctionContext)",
            historicalContext: historicalContext,
            messagesText: messagesText
        )

        // If external prompt exists and was loaded, use it
        if HotReloadManager.shared.getPrompt("commitment-extraction") != nil {
            return externalPrompt
        }

        // Fallback to inline prompt (keeps working if external file is missing)
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
        - title: A brief 3-8 word description
        - commitmentText: The exact phrase containing the commitment
        - committedBy: Name of person making the commitment
        - committedTo: Name of person receiving the commitment
        - dueDate: ISO8601 date if mentioned (e.g., "tomorrow", "Friday", "next week")
        - priority: "critical", "high", "medium", or "low" based on urgency indicators
        - context: Surrounding context from the message
        - confidence: 0.0 to 1.0 score of how confident you are this is a real commitment

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
        threadName: String
    ) -> (committedBy: String, committedTo: String) {
        // A counterparty is "junk" if empty, "Unknown", the user themselves, or a raw ID.
        // When junk, fall back to the thread name — already the canonical WhatsApp/Contacts
        // name (ZPARTNERNAME). Only ever fills blanks; never overrides a real name, so this
        // cannot create a mis-attribution.
        func resolved(_ raw: String) -> String {
            if isJunkParty(raw, userName: userName) {
                return isJunkParty(threadName, userName: userName) ? "Unknown" : threadName
            }
            return raw
        }
        switch type {
        case .iOwe:
            return (userName, resolved(extracted.committedTo))
        case .theyOwe:
            return (resolved(extracted.committedBy), userName)
        }
    }

    private func isJunkParty(_ name: String, userName: String) -> Bool {
        let s = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s == "Unknown" || s == "Group" { return true }
        if s.lowercased() == userName.lowercased() { return true }
        return isRawId(s)
    }

    private func isRawId(_ name: String) -> Bool {
        // Base64 IDs (e.g. CM2E5M0GIABIAZABAPABAg==)
        if name.hasSuffix("==") || name.hasSuffix("=") { return true }
        // Phone / numeric IDs
        if name.allSatisfy({ $0.isNumber || $0 == "+" || $0 == "-" || $0 == " " }) && name.count > 5 { return true }
        // JID-style IDs (no spaces, contains @)
        if name.contains("@") && !name.contains(" ") { return true }
        return false
    }
}

// MARK: - Supporting Models

struct CommitmentExtraction {
    let commitments: [Commitment]
    let analysisDate: Date
    let sourceInfo: SourceInfo

    struct SourceInfo {
        let platform: MessagePlatform
        let threadId: String
        let threadName: String
        let messagesAnalyzed: Int
        let dateRange: DateRange

        struct DateRange {
            let from: Date
            let to: Date
        }
    }
}

struct CommitmentExtractionRequest: Codable {
    let messages: [MessageContext]
    let userInfo: UserInfo
    let threadName: String

    struct MessageContext: Codable {
        let sender: String
        let senderName: String?  // Display name (especially important for group chats)
        let content: String
        let timestamp: Date
        let isFromUser: Bool
    }

    struct UserInfo: Codable {
        let name: String
        let email: String
    }
}

struct CommitmentExtractionResponse: Codable {
    let commitments: [ExtractedCommitment]

    struct ExtractedCommitment: Codable {
        let type: String
        let title: String
        let commitmentText: String
        let committedBy: String
        let committedTo: String
        let dueDate: String?
        let priority: String
        let context: String
        let confidence: Double
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
