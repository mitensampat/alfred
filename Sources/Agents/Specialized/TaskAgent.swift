import Foundation

class TaskAgent: AgentProtocol {
    let agentType: AgentType = .task
    let autonomyLevel: AutonomyLevel
    let config: AgentConfig

    private let appConfig: AppConfig
    private let learningEngine: LearningEngine

    init(config: AgentConfig, appConfig: AppConfig, learningEngine: LearningEngine) {
        self.config = config
        self.autonomyLevel = config.autonomyLevel
        self.appConfig = appConfig
        self.learningEngine = learningEngine
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
}
