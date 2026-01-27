import Foundation

class FollowupAgent: AgentProtocol {
    let agentType: AgentType = .followup
    let autonomyLevel: AutonomyLevel
    let config: AgentConfig

    private let appConfig: AppConfig
    private let learningEngine: LearningEngine
    private let memoryService: AgentMemoryService
    private var commitmentAnalyzer: CommitmentAnalyzer?
    private var notionService: NotionService?

    init(config: AgentConfig, appConfig: AppConfig, learningEngine: LearningEngine) {
        self.config = config
        self.autonomyLevel = config.autonomyLevel
        self.appConfig = appConfig
        self.learningEngine = learningEngine
        self.memoryService = AgentMemoryService.shared

        // Initialize commitment tracking if enabled
        if let commitmentConfig = appConfig.commitmentConfig,
           commitmentConfig.enabled,
           let analysisModel = appConfig.aiConfig.messageAnalysisModel {
            self.commitmentAnalyzer = CommitmentAnalyzer(
                anthropicApiKey: appConfig.aiConfig.anthropicApiKey,
                model: analysisModel,
                userInfo: CommitmentAnalyzer.UserInfo(
                    name: appConfig.userConfig.name,
                    email: appConfig.userConfig.email
                )
            )
            self.notionService = NotionService(config: appConfig.notionConfig)
        }
    }

    // MARK: - Evaluation

    func evaluate(context: AgentContext) async throws -> [AgentDecision] {
        var decisions: [AgentDecision] = []

        // Extract commitments from messages
        if let messagingSummary = context.messagingSummary {
            let commitmentDecisions = try await extractCommitmentsFromMessages(messagingSummary, context: context)
            decisions.append(contentsOf: commitmentDecisions)
        }

        // Extract commitments from meetings
        if let calendarBriefing = context.calendarBriefing {
            let meetingDecisions = try await extractCommitmentsFromMeetings(calendarBriefing, context: context)
            decisions.append(contentsOf: meetingDecisions)
        }

        // Check for tasks nearing completion that might need follow-up
        if let notionContext = context.notionContext {
            let taskDecisions = try await analyzeTasksForFollowup(notionContext, context: context)
            decisions.append(contentsOf: taskDecisions)
        }

        return decisions
    }

    // MARK: - Commitment Extraction

    private func extractCommitmentsFromMessages(_ summary: MessagingSummary, context: AgentContext) async throws -> [AgentDecision] {
        var decisions: [AgentDecision] = []

        // Look for commitment patterns in message summaries
        let allMessages = summary.keyInteractions + summary.needsResponse + summary.criticalMessages
        for messageSummary in allMessages.prefix(10) {
            if let commitment = detectCommitment(in: messageSummary.summary) {
                if let decision = try await createFollowupDecision(
                    commitment: commitment,
                    source: "message from \(messageSummary.thread.contactName ?? "unknown")",
                    context: context
                ) {
                    decisions.append(decision)
                }
            }
        }

        return decisions
    }

    private func extractCommitmentsFromMeetings(_ briefing: CalendarBriefing, context: AgentContext) async throws -> [AgentDecision] {
        var decisions: [AgentDecision] = []

        // Check meeting briefings for commitments
        for meetingBriefing in briefing.meetingBriefings {
            // Look for action items or commitments in context/prep points
            if let contextText = meetingBriefing.context,
               let commitment = detectCommitment(in: contextText) {
                if let decision = try await createFollowupDecision(
                    commitment: commitment,
                    source: "meeting: \(meetingBriefing.event.title)",
                    context: context
                ) {
                    decisions.append(decision)
                }
            }
        }

        return decisions
    }

    private func analyzeTasksForFollowup(_ notionContext: NotionContext, context: AgentContext) async throws -> [AgentDecision] {
        var decisions: [AgentDecision] = []

        // Check for tasks that are "Done" but might need follow-up
        for task in notionContext.tasks where task.status.lowercased().contains("done") {
            // If task involves communication or deliverables, suggest follow-up
            if requiresFollowup(task: task) {
                if let decision = try await createTaskFollowupDecision(task: task, context: context) {
                    decisions.append(decision)
                }
            }
        }

        return decisions
    }

    // MARK: - Commitment Detection

    private func detectCommitment(in text: String) -> (action: String, deadline: Date?)? {
        let lowercaseText = text.lowercased()

        // Commitment patterns
        let commitmentPatterns = [
            "i'll send",
            "i will send",
            "will share",
            "will provide",
            "will get back",
            "will follow up",
            "will review",
            "will update",
            "promised to",
            "need to send",
            "need to share"
        ]

        // Check if text contains commitment
        guard commitmentPatterns.contains(where: { lowercaseText.contains($0) }) else {
            return nil
        }

        // Extract action
        var action = text
        if text.count > 100 {
            action = String(text.prefix(100)) + "..."
        }

        // Extract deadline if mentioned
        let deadline = extractDeadline(from: text)

        return (action, deadline)
    }

    private func extractDeadline(from text: String) -> Date? {
        let lowercaseText = text.lowercased()

        // Time-based patterns
        if lowercaseText.contains("today") {
            return Calendar.current.startOfDay(for: Date())
        }

        if lowercaseText.contains("tomorrow") {
            return Calendar.current.date(byAdding: .day, value: 1, to: Date())
        }

        if lowercaseText.contains("this week") || lowercaseText.contains("end of week") {
            // Friday of current week
            let today = Date()
            let weekday = Calendar.current.component(.weekday, from: today)
            let daysUntilFriday = (6 - weekday + 7) % 7
            return Calendar.current.date(byAdding: .day, value: daysUntilFriday, to: today)
        }

        if lowercaseText.contains("next week") {
            return Calendar.current.date(byAdding: .weekOfYear, value: 1, to: Date())
        }

        // Default: 2 days from now
        return Calendar.current.date(byAdding: .day, value: 2, to: Date())
    }

    private func requiresFollowup(task: NotionTask) -> Bool {
        let followupKeywords = [
            "send", "share", "deliver", "communicate", "inform",
            "notify", "update", "report", "present"
        ]

        let lowercaseTitle = task.title.lowercased()
        return followupKeywords.contains { lowercaseTitle.contains($0) }
    }

    // MARK: - Decision Creation

    private func createFollowupDecision(
        commitment: (action: String, deadline: Date?),
        source: String,
        context: AgentContext
    ) async throws -> AgentDecision? {
        // Determine follow-up timing
        let deadline = commitment.deadline ?? Calendar.current.date(byAdding: .day, value: 2, to: Date())!
        let followupTime = Calendar.current.date(byAdding: .hour, value: -4, to: deadline)!  // 4 hours before deadline

        // Skip if followup time has passed
        guard followupTime > Date() else {
            return nil
        }

        // Determine priority based on deadline proximity
        let hoursUntilDeadline = deadline.timeIntervalSinceNow / 3600
        let priority: UrgencyLevel
        if hoursUntilDeadline <= 24 {
            priority = .critical
        } else if hoursUntilDeadline <= 72 {
            priority = .high
        } else {
            priority = .medium
        }

        // Create followup reminder
        let followup = FollowupReminder(
            originalContext: "From \(source): \(commitment.action)",
            followupAction: commitment.action,
            scheduledFor: followupTime,
            priority: priority
        )

        // Calculate confidence
        let contextString = "followup_\(source)_\(priority.rawValue)"
        let learnedConfidence = try await learningEngine.getPatternConfidence(
            for: contextString,
            agentType: .followup,
            actionType: "create_followup"
        )

        let baseConfidence = priority == .critical ? 0.8 : 0.6
        let confidence = (baseConfidence * 0.7) + (learnedConfidence * 0.3)

        let reasoning = "Detected commitment: '\(commitment.action)'. Setting follow-up reminder \(Int(hoursUntilDeadline)) hours before deadline (\(priority.rawValue) priority)."

        var risks: [String] = []
        if priority == .critical {
            risks.append("High-priority commitment with tight deadline")
        }

        return AgentDecision(
            agentType: .followup,
            action: .createFollowup(followup),
            reasoning: reasoning,
            confidence: confidence,
            context: contextString,
            risks: risks,
            alternatives: ["Skip follow-up", "Set manual reminder"],
            requiresApproval: false  // Will be determined by AgentManager
        )
    }

    private func createTaskFollowupDecision(task: NotionTask, context: AgentContext) async throws -> AgentDecision? {
        // Create follow-up for completed task that needs post-completion action
        let followupTime = Calendar.current.date(byAdding: .day, value: 1, to: Date())!

        let followup = FollowupReminder(
            originalContext: "Completed task: \(task.title)",
            followupAction: "Follow up on: \(task.title)",
            scheduledFor: followupTime,
            priority: .medium
        )

        let contextString = "followup_completed_task_\(task.id)"
        let learnedConfidence = try await learningEngine.getPatternConfidence(
            for: contextString,
            agentType: .followup,
            actionType: "create_followup"
        )

        let baseConfidence = 0.5
        let confidence = (baseConfidence * 0.7) + (learnedConfidence * 0.3)

        let reasoning = "Task '\(task.title)' completed. Creating follow-up reminder to ensure deliverables were received/acknowledged."

        return AgentDecision(
            agentType: .followup,
            action: .createFollowup(followup),
            reasoning: reasoning,
            confidence: confidence,
            context: contextString,
            risks: [],
            alternatives: ["Skip follow-up", "Manual verification"],
            requiresApproval: false  // Will be determined by AgentManager
        )
    }

    // MARK: - Commitment Persistence

    /// Save commitment to Notion database (using unified Tasks database)
    func saveCommitmentToNotion(_ commitment: Commitment) async throws -> String? {
        guard let notionService = notionService,
              appConfig.commitmentConfig?.enabled == true,
              notionService.tasksDatabaseId != nil else {
            print("⚠️  Tasks database not configured")
            return nil
        }

        // Check for duplicates in unified Tasks database
        if let existingId = try await notionService.findCommitmentByHashInTasks(commitment.uniqueHash) {
            print("ℹ️  Commitment already exists (hash: \(commitment.uniqueHash.prefix(8))...)")
            return existingId
        }

        // Create new commitment in unified Tasks database
        let notionId = try await notionService.createCommitmentInTasks(commitment)
        print("✅ Saved commitment to Notion Tasks: \(notionId)")
        return notionId
    }

    /// Check Notion for overdue commitments and create reminders (using unified Tasks database)
    func syncOverdueCommitments() async throws -> [AgentDecision] {
        guard let notionService = notionService,
              appConfig.commitmentConfig?.enabled == true,
              notionService.tasksDatabaseId != nil else {
            return []
        }

        // Query overdue commitments from unified Tasks database
        let overdueCommitments = try await notionService.queryOverdueCommitmentsFromTasks()
        var decisions: [AgentDecision] = []

        for commitment in overdueCommitments where commitment.type == .iOwe {
            // Create urgent follow-up for overdue "I Owe" commitments
            let followup = FollowupReminder(
                originalContext: "Overdue commitment: \(commitment.title)",
                followupAction: commitment.commitmentText,
                scheduledFor: Date(),  // Now
                priority: .critical
            )

            let decision = AgentDecision(
                agentType: .followup,
                action: .createFollowup(followup),
                reasoning: "Commitment '\(commitment.title)' is overdue. Creating urgent reminder.",
                confidence: 0.95,
                context: "overdue_commitment_\(commitment.uniqueHash)",
                risks: ["Overdue commitment may impact relationships"],
                alternatives: ["Mark as cancelled", "Extend deadline"],
                requiresApproval: false
            )

            decisions.append(decision)
        }

        return decisions
    }

    // MARK: - Execution

    func execute(decision: AgentDecision) async throws -> ExecutionResult {
        // Execution handled by ExecutionEngine
        return .success(details: "Follow-up created")
    }

    // MARK: - Learning

    func learn(feedback: UserFeedback) async throws {
        try await learningEngine.recordFeedback(feedback)
    }
}
