import Foundation

class CommunicationAgent: AgentProtocol {
    let agentType: AgentType = .communication
    let autonomyLevel: AutonomyLevel
    let config: AgentConfig

    private let appConfig: AppConfig
    private let learningEngine: LearningEngine
    private let aiService: ClaudeAIService
    private var training: CommunicationTraining?

    init(config: AgentConfig, appConfig: AppConfig, learningEngine: LearningEngine) {
        self.config = config
        self.autonomyLevel = config.autonomyLevel
        self.appConfig = appConfig
        self.learningEngine = learningEngine
        self.aiService = ClaudeAIService(config: appConfig.ai)

        // Load training examples
        self.training = CommunicationTrainingLoader.load()
        if self.training != nil {
            print("✓ Loaded communication training with \(self.training!.trainingExamples.count) examples")
        }
    }

    // MARK: - Evaluation

    func evaluate(context: AgentContext) async throws -> [AgentDecision] {
        guard let messagingSummary = context.messagingSummary else {
            return []
        }

        var decisions: [AgentDecision] = []

        // Find high-priority messages needing responses
        let highPriorityMessages = messagingSummary.needsResponse
            .prefix(5)  // Limit to top 5

        for messageSummary in highPriorityMessages {
            // Analyze message to determine if we should draft a response
            if let decision = try await evaluateMessage(messageSummary, context: context) {
                decisions.append(decision)
            }
        }

        return decisions
    }

    private func evaluateMessage(_ messageSummary: MessageSummary, context: AgentContext) async throws -> AgentDecision? {
        let thread = messageSummary.thread

        // Skip if no clear contact
        guard let contactName = thread.contactName else {
            return nil
        }

        // Analyze message content and urgency
        let urgency = messageSummary.urgency
        let summary = messageSummary.summary

        // Check if this is a simple acknowledgment or requires complex response
        let isSimpleAcknowledgment = detectSimpleAcknowledgment(summary: summary)
        let requiresComplexResponse = detectComplexResponse(summary: summary)

        // Get confidence from learning engine
        let contextString = "communication_response_to_\(contactName)_urgency_\(urgency.rawValue)"
        let learnedConfidence = try await learningEngine.getPatternConfidence(
            for: contextString,
            agentType: .communication,
            actionType: "draft_response"
        )

        // Base confidence calculation
        var baseConfidence = 0.5

        if isSimpleAcknowledgment {
            baseConfidence = 0.8  // High confidence for simple acknowledgments
        } else if requiresComplexResponse {
            baseConfidence = 0.3  // Low confidence for complex responses
        } else {
            baseConfidence = 0.6  // Medium confidence for standard responses
        }

        // Combine with learned confidence (70% base, 30% learned)
        let confidence = (baseConfidence * 0.7) + (learnedConfidence * 0.3)

        // Determine tone based on relationship
        let tone: MessageDraft.MessageTone = determineTone(for: thread.platform)

        // Draft response content
        let draftContent = try await generateDraftContent(
            summary: summary,
            tone: tone,
            context: context
        )

        // Create message draft
        let draft = MessageDraft(
            recipient: contactName,
            platform: thread.platform,
            content: draftContent,
            tone: tone,
            suggestedSendTime: nil
        )

        // Identify risks
        var risks: [String] = []
        if urgency == .critical {
            risks.append("Critical urgency - response timing matters")
        }
        if requiresComplexResponse {
            risks.append("Complex topic may require personalized response")
        }

        // Create decision
        return AgentDecision(
            agentType: .communication,
            action: .draftResponse(draft),
            reasoning: "Thread from \(contactName) needs response. \(isSimpleAcknowledgment ? "Simple acknowledgment detected." : "Standard response pattern.") Confidence based on similar past interactions.",
            confidence: confidence,
            context: contextString,
            risks: risks,
            alternatives: ["Wait for more context", "Send manual response"],
            requiresApproval: false  // Will be determined by AgentManager
        )
    }

    // MARK: - Execution

    func execute(decision: AgentDecision) async throws -> ExecutionResult {
        // Execution handled by ExecutionEngine
        return .success(details: "Draft prepared")
    }

    // MARK: - Learning

    func learn(feedback: UserFeedback) async throws {
        // Learning handled by LearningEngine
        try await learningEngine.recordFeedback(feedback)
    }

    // MARK: - Analysis Helpers

    private func detectSimpleAcknowledgment(summary: String) -> Bool {
        let acknowledgmentKeywords = [
            "thanks", "thank you", "got it", "noted", "sounds good",
            "perfect", "great", "awesome", "okay", "ok", "sure",
            "will do", "understood"
        ]

        let lowercaseSummary = summary.lowercased()
        return acknowledgmentKeywords.contains { lowercaseSummary.contains($0) }
    }

    private func detectComplexResponse(summary: String) -> Bool {
        let complexKeywords = [
            "decision", "proposal", "strategy", "plan", "budget",
            "negotiation", "contract", "legal", "review", "feedback on"
        ]

        let lowercaseSummary = summary.lowercased()
        return complexKeywords.contains { lowercaseSummary.contains($0) }
    }

    private func determineTone(for platform: MessagePlatform) -> MessageDraft.MessageTone {
        // Determine tone based on platform
        if platform == .email {
            return .professional
        } else if platform == .imessage {
            return .friendly
        } else {
            return .casual
        }
    }

    private func generateDraftContent(
        summary: String,
        tone: MessageDraft.MessageTone,
        context: AgentContext
    ) async throws -> String {
        // Use AI-powered generation with training examples
        return try await generateAIDraft(summary: summary, tone: tone, context: context)
    }

    private func generateAIDraft(
        summary: String,
        tone: MessageDraft.MessageTone,
        context: AgentContext
    ) async throws -> String {
        // Build context-aware prompt with training examples
        var prompt = """
        You are drafting a message reply on behalf of the user. Generate ONLY the message text, nothing else.

        """

        // Add user profile if training available
        if let training = training {
            prompt += """
            USER'S COMMUNICATION STYLE:
            \(training.userProfile.communicationStyle)
            Response length: \(training.userProfile.typicalResponseLength)
            Uses emojis: \(training.userProfile.usesEmojis ? "Yes" : "No")

            """

            // Find similar training examples
            let similarExamples = CommunicationTrainingLoader.findSimilarExamples(
                for: summary,
                in: training,
                limit: 3
            )

            if !similarExamples.isEmpty {
                prompt += """
                EXAMPLE RESPONSES (for reference):

                """
                for example in similarExamples {
                    prompt += """
                    When they said: "\(example.incomingMessage)"
                    User replied: "\(example.yourTypicalResponse)"

                    """
                }
            }

            // Add personalization rules
            prompt += """
            USER'S PREFERENCES:
            Never use these phrases: \(training.personalizationRules.neverUse.joined(separator: ", "))
            Preferred phrases: \(training.personalizationRules.preferredPhrases.joined(separator: ", "))

            """
        }

        // Add message context
        prompt += """
        CURRENT MESSAGE:
        Summary: \(summary)
        Required tone: \(tone.rawValue)

        """

        // Add calendar context if available
        if let calendarBriefing = context.calendarBriefing, !calendarBriefing.schedule.events.isEmpty {
            let upcomingEvents = calendarBriefing.schedule.events.prefix(2).map { $0.title }.joined(separator: ", ")
            prompt += """
            User's upcoming schedule: \(upcomingEvents)

            """
        }

        // Add task context if available
        if let briefing = context.briefing,
           let notionContext = briefing.notionContext,
           !notionContext.tasks.isEmpty {
            let tasks = notionContext.tasks.prefix(2).map { $0.title }.joined(separator: ", ")
            prompt += """
            User's active tasks: \(tasks)

            """
        }

        prompt += """
        INSTRUCTIONS:
        1. Write in the user's style (see examples above)
        2. Keep it concise (\(training?.userProfile.typicalResponseLength ?? "1-2 sentences"))
        3. Match the \(tone.rawValue) tone
        4. Use user's preferred phrases when appropriate
        5. Do NOT use phrases from the "never use" list
        6. Be specific and actionable
        7. Output ONLY the message text, no explanations

        Draft reply:
        """

        // Generate response with AI
        do {
            let response = try await aiService.generateText(prompt: prompt, maxTokens: 150)
            return response.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        } catch {
            print("⚠️  AI generation failed, using fallback: \(error)")
            // Fallback to simple response if AI fails
            return generateFallbackResponse(tone: tone)
        }
    }

    private func generateFallbackResponse(tone: MessageDraft.MessageTone) -> String {
        // Simple fallback if AI fails
        switch tone {
        case .professional:
            return "Thank you for your message. I'll review and respond shortly."
        case .friendly:
            return "Thanks for the message! I'll get back to you soon."
        case .casual:
            return "Got it, thanks!"
        case .formal:
            return "Thank you for bringing this to my attention."
        }
    }
}
