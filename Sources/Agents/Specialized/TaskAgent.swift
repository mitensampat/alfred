import Foundation

class TaskAgent: AgentProtocol {
    let agentType: AgentType = .task
    let autonomyLevel: AutonomyLevel
    let config: AgentConfig

    private let appConfig: AppConfig
    private let learningEngine: LearningEngine
    private let attentionTracker: AttentionTracker
    private let aiService: ClaudeAIService
    private let memoryService: AgentMemoryService

    init(config: AgentConfig, appConfig: AppConfig, learningEngine: LearningEngine) {
        self.config = config
        self.autonomyLevel = config.autonomyLevel
        self.appConfig = appConfig
        self.learningEngine = learningEngine
        self.aiService = ClaudeAIService(config: appConfig.ai)
        self.attentionTracker = AttentionTracker(aiService: self.aiService)
        self.memoryService = AgentMemoryService.shared
    }

    // MARK: - Evaluation

    func evaluate(context: AgentContext) async throws -> [AgentDecision] {
        guard let notionContext = context.notionContext else {
            return []
        }

        var decisions: [AgentDecision] = []

        // Analyze active tasks for priority adjustments
        for task in notionContext.tasks {
            if let decision = try await evaluateTask(task, context: context) {
                decisions.append(decision)
            }
        }

        return decisions
    }

    private func evaluateTask(_ task: NotionTask, context: AgentContext) async throws -> AgentDecision? {
        // Parse current priority from status
        guard let currentPriority = parsePriority(from: task.status) else {
            return nil
        }

        // Determine if priority adjustment is needed
        let suggestedPriority = try await calculateOptimalPriority(
            task: task,
            currentPriority: currentPriority,
            context: context
        )

        // Only create decision if priority should change
        guard suggestedPriority != currentPriority else {
            return nil
        }

        // Calculate confidence
        let contextString = "task_priority_\(task.title)_\(currentPriority.rawValue)_to_\(suggestedPriority.rawValue)"
        let learnedConfidence = try await learningEngine.getPatternConfidence(
            for: contextString,
            agentType: .task,
            actionType: "adjust_task_priority"
        )

        // Base confidence from urgency factors
        let baseConfidence = calculatePriorityConfidence(
            task: task,
            newPriority: suggestedPriority,
            context: context
        )

        // Combine confidences (60% base, 40% learned)
        let confidence = (baseConfidence * 0.6) + (learnedConfidence * 0.4)

        // Create adjustment
        let adjustment = TaskAdjustment(
            taskId: task.id,
            taskTitle: task.title,
            currentPriority: currentPriority,
            newPriority: suggestedPriority,
            reason: buildReasoning(task: task, newPriority: suggestedPriority, context: context)
        )

        // Identify risks
        var risks: [String] = []
        if currentPriority == .critical {
            risks.append("Changing priority of critical task")
        }
        if suggestedPriority == .critical {
            risks.append("Elevating to critical priority")
        }

        return AgentDecision(
            agentType: .task,
            action: .adjustTaskPriority(adjustment),
            reasoning: adjustment.reason,
            confidence: confidence,
            context: contextString,
            risks: risks,
            alternatives: ["Keep current priority", "Manually review and adjust"],
            requiresApproval: false  // Will be determined by AgentManager
        )
    }

    // MARK: - Execution

    func execute(decision: AgentDecision) async throws -> ExecutionResult {
        // Execution handled by ExecutionEngine
        return .success(details: "Priority adjusted")
    }

    // MARK: - Learning

    func learn(feedback: UserFeedback) async throws {
        try await learningEngine.recordFeedback(feedback)
    }

    // MARK: - Priority Analysis

    private func calculateOptimalPriority(
        task: NotionTask,
        currentPriority: UrgencyLevel,
        context: AgentContext
    ) async throws -> UrgencyLevel {
        var urgencyScore = 0.0

        // Factor 1: Due date proximity
        if let dueDate = task.dueDate {
            let daysUntilDue = Calendar.current.dateComponents([.day], from: Date(), to: dueDate).day ?? 999
            if daysUntilDue <= 0 {
                urgencyScore += 0.4  // Overdue
            } else if daysUntilDue <= 1 {
                urgencyScore += 0.35  // Due tomorrow
            } else if daysUntilDue <= 3 {
                urgencyScore += 0.25  // Due in next 3 days
            } else if daysUntilDue <= 7 {
                urgencyScore += 0.15  // Due this week
            }
        }

        // Factor 2: Related to upcoming meetings
        if let calendarBriefing = context.calendarBriefing {
            let taskKeywords = extractKeywords(from: task.title)
            for meeting in calendarBriefing.schedule.externalMeetings {
                let meetingKeywords = extractKeywords(from: meeting.title)
                if hasOverlap(taskKeywords, meetingKeywords) {
                    let hoursUntilMeeting = meeting.startTime.timeIntervalSinceNow / 3600
                    if hoursUntilMeeting <= 24 {
                        urgencyScore += 0.3  // Meeting in next 24 hours
                    } else if hoursUntilMeeting <= 72 {
                        urgencyScore += 0.2  // Meeting in next 3 days
                    }
                }
            }
        }

        // Factor 3: Blocking other work (keywords like "blocker", "dependency")
        if task.title.lowercased().contains("blocker") || task.title.lowercased().contains("dependency") {
            urgencyScore += 0.2
        }

        // Factor 4: Critical keywords in title
        let criticalKeywords = ["urgent", "critical", "asap", "immediate", "emergency"]
        if criticalKeywords.contains(where: { task.title.lowercased().contains($0) }) {
            urgencyScore += 0.25
        }

        // Map urgency score to priority level
        if urgencyScore >= 0.7 {
            return .critical
        } else if urgencyScore >= 0.4 {
            return .high
        } else if urgencyScore >= 0.2 {
            return .medium
        } else {
            return .low
        }
    }

    private func calculatePriorityConfidence(
        task: NotionTask,
        newPriority: UrgencyLevel,
        context: AgentContext
    ) -> Double {
        var confidence = 0.5

        // High confidence if task is overdue and being elevated
        if let dueDate = task.dueDate, dueDate < Date(), newPriority == .critical {
            confidence = 0.9
        }

        // High confidence if related to imminent meeting
        if let calendarBriefing = context.calendarBriefing {
            for meeting in calendarBriefing.schedule.externalMeetings {
                if meeting.startTime.timeIntervalSinceNow <= 24 * 3600 {
                    let taskKeywords = extractKeywords(from: task.title)
                    let meetingKeywords = extractKeywords(from: meeting.title)
                    if hasOverlap(taskKeywords, meetingKeywords) {
                        confidence = max(confidence, 0.85)
                    }
                }
            }
        }

        // Medium confidence for routine priority adjustments
        if newPriority.rawValue == "high" || newPriority.rawValue == "medium" {
            confidence = max(confidence, 0.6)
        }

        return confidence
    }

    private func buildReasoning(
        task: NotionTask,
        newPriority: UrgencyLevel,
        context: AgentContext
    ) -> String {
        var reasons: [String] = []

        // Due date reasoning
        if let dueDate = task.dueDate {
            let daysUntilDue = Calendar.current.dateComponents([.day], from: Date(), to: dueDate).day ?? 999
            if daysUntilDue <= 0 {
                reasons.append("Task is overdue")
            } else if daysUntilDue <= 1 {
                reasons.append("Due tomorrow")
            } else if daysUntilDue <= 3 {
                reasons.append("Due in next 3 days")
            }
        }

        // Meeting relationship
        if let calendarBriefing = context.calendarBriefing {
            for meeting in calendarBriefing.schedule.externalMeetings {
                let taskKeywords = extractKeywords(from: task.title)
                let meetingKeywords = extractKeywords(from: meeting.title)
                if hasOverlap(taskKeywords, meetingKeywords) {
                    reasons.append("Related to upcoming meeting: \(meeting.title)")
                    break
                }
            }
        }

        // Blocker detection
        if task.title.lowercased().contains("blocker") {
            reasons.append("Marked as blocker")
        }

        if reasons.isEmpty {
            return "Priority adjustment based on current workload and deadlines"
        }

        return reasons.joined(separator: ". ")
    }

    // MARK: - Helpers

    private func parsePriority(from status: String) -> UrgencyLevel? {
        let status = status.lowercased()
        if status.contains("critical") || status.contains("urgent") {
            return .critical
        } else if status.contains("high") {
            return .high
        } else if status.contains("medium") || status.contains("normal") {
            return .medium
        } else if status.contains("low") {
            return .low
        }
        return .medium  // Default
    }

    private func extractKeywords(from text: String) -> Set<String> {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 3 }  // Only words longer than 3 characters
        return Set(words)
    }

    private func hasOverlap(_ set1: Set<String>, _ set2: Set<String>) -> Bool {
        return !set1.intersection(set2).isEmpty
    }

    // MARK: - Attention Analysis

    /// Analyze attention allocation and generate report
    func analyzeAttention(
        query: AttentionQuery,
        events: [CalendarEvent],
        messages: [MessageSummary]
    ) async throws -> AttentionReport {
        return try await attentionTracker.generateAttentionReport(
            query: query,
            events: events,
            messages: messages
        )
    }

    /// Generate attention plan for future period
    func planAttention(
        request: AttentionPlanRequest,
        currentEvents: [CalendarEvent]
    ) async throws -> AttentionPlan {
        return try await attentionTracker.generateAttentionPlan(
            request: request,
            currentEvents: currentEvents
        )
    }

    /// Proactively ask user about meeting priorities
    func collectMeetingPriorities(events: [CalendarEvent]) async throws -> [String: MeetingCategory] {
        var categorizations: [String: MeetingCategory] = [:]

        // Group similar meetings
        let patterns = groupMeetingsByPattern(events)

        // Ask about the top patterns (limit to avoid overwhelming user)
        for (pattern, meetings) in patterns.prefix(5) {
            let category = try await askUserAboutMeeting(pattern: pattern, sampleMeeting: meetings[0])
            categorizations[pattern] = category

            // Apply to all similar meetings
            for meeting in meetings {
                categorizations[meeting.title] = category
            }
        }

        return categorizations
    }

    private func groupMeetingsByPattern(_ events: [CalendarEvent]) -> [String: [CalendarEvent]] {
        var patterns: [String: [CalendarEvent]] = [:]

        for event in events {
            let pattern = extractPattern(from: event.title)
            if patterns[pattern] != nil {
                patterns[pattern]?.append(event)
            } else {
                patterns[pattern] = [event]
            }
        }

        // Sort by frequency (most common first)
        return patterns.sorted { $0.value.count > $1.value.count }
            .reduce(into: [:]) { $0[$1.key] = $1.value }
    }

    private func extractPattern(from title: String) -> String {
        let lower = title.lowercased()

        // Common patterns
        if lower.contains("1:1") || lower.contains("1-1") {
            return "1:1 meetings"
        }
        if lower.contains("weekly") {
            return "Weekly sync meetings"
        }
        if lower.contains("standup") || lower.contains("stand-up") {
            return "Team standups"
        }
        if lower.contains("sync") {
            return "Sync meetings"
        }
        if lower.contains("review") {
            return "Review meetings"
        }
        if lower.contains("planning") {
            return "Planning meetings"
        }

        // Return simplified title (first 3 words)
        let words = title.components(separatedBy: " ").prefix(3)
        return words.joined(separator: " ")
    }

    private func askUserAboutMeeting(pattern: String, sampleMeeting: CalendarEvent) async throws -> MeetingCategory {
        // Get memory context for task prioritization rules
        let memoryContext = memoryService.getMemoryForPrompt(agentType: .task, context: nil)

        // Use AI to suggest category based on meeting details and user preferences
        var prompt = ""
        if !memoryContext.isEmpty {
            prompt += memoryContext + "\n"
        }

        prompt += """
        Analyze this meeting pattern and suggest how valuable it is:

        Pattern: \(pattern)
        Example meeting: \(sampleMeeting.title)
        Duration: \(Int(sampleMeeting.duration / 60)) minutes
        Attendees: \(sampleMeeting.attendees.count)
        Is external: \(sampleMeeting.hasExternalAttendees)

        Categories:
        1. Strategic - High-value, long-term impact
        2. Tactical - Important for execution
        3. Collaborative - Team coordination
        4. Informational - Status updates, FYIs
        5. Ceremonial - Could be async
        6. Waste - Low value

        Consider the user's taught rules and learned patterns when categorizing.
        Respond with just the category number and name (e.g., "3. Collaborative")
        """

        let response = try await aiService.generateText(prompt: prompt, maxTokens: 50)
        let cleaned = response.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).lowercased()

        // Parse AI response
        if cleaned.contains("strategic") { return .strategic }
        if cleaned.contains("tactical") { return .tactical }
        if cleaned.contains("collaborative") { return .collaborative }
        if cleaned.contains("informational") { return .informational }
        if cleaned.contains("ceremonial") { return .ceremonial }
        if cleaned.contains("waste") { return .waste }

        return .uncategorized
    }

    /// Generate AI-powered recommendations for attention optimization
    func generateAttentionRecommendations(
        report: AttentionReport
    ) async throws -> [AttentionReport.AttentionRecommendation] {
        let prompt = """
        Analyze this attention report and provide 3-5 specific, actionable recommendations:

        CALENDAR:
        - Total meeting time: \(Int(report.calendar.totalMeetingTime / 3600)) hours
        - Meeting count: \(report.calendar.meetingCount)
        - Utilization score: \(Int(report.calendar.utilizationScore))%
        - Estimated waste: \(Int(report.calendar.wastedTimeEstimate / 3600)) hours

        MESSAGING:
        - Total threads: \(report.messaging.totalThreads)
        - Responses given: \(report.messaging.responsesGiven)
        - Utilization score: \(Int(report.messaging.utilizationScore))%

        OVERALL:
        - Focus score: \(Int(report.overall.focusScore))%
        - Efficiency score: \(Int(report.overall.efficiencyScore))%
        - Goal alignment: \(Int(report.overall.alignmentWithGoals))%

        Provide recommendations in this format:
        1. [Type]: [Title] - [Description] - [Impact]

        Types: reduceMeetings, delegateResponsibility, blockFocusTime, reduceMessageLoad, rebalanceAttention
        """

        let response = try await aiService.generateText(prompt: prompt, maxTokens: 500)

        // Parse AI response into recommendations
        // For now, return existing recommendations + AI suggestions as description
        var recommendations = report.recommendations

        recommendations.append(AttentionReport.AttentionRecommendation(
            type: .rebalanceAttention,
            priority: .medium,
            title: "AI-Generated Insights",
            description: response,
            impact: AttentionReport.AttentionRecommendation.Impact(
                timeRecovered: nil,
                focusImprovement: nil,
                description: "AI analysis of attention patterns"
            ),
            actionable: true,
            suggestedAction: "Review AI recommendations below"
        ))

        return recommendations
    }
}
