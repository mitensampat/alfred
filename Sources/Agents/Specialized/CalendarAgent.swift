import Foundation

class CalendarAgent: AgentProtocol {
    let agentType: AgentType = .calendar
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
        guard let calendarBriefing = context.calendarBriefing else {
            return []
        }

        var decisions: [AgentDecision] = []

        // Analyze external meetings for prep needs
        for meeting in calendarBriefing.schedule.externalMeetings {
            if let decision = try await evaluateMeeting(meeting, context: context) {
                decisions.append(decision)
            }
        }

        return decisions
    }

    private func evaluateMeeting(_ meeting: CalendarEvent, context: AgentContext) async throws -> AgentDecision? {
        // Check if meeting needs prep
        let hoursUntilMeeting = meeting.startTime.timeIntervalSinceNow / 3600

        // Skip if meeting is too far out (>48 hours) or already started
        guard hoursUntilMeeting > 0 && hoursUntilMeeting <= 48 else {
            return nil
        }

        // Determine optimal prep time
        let prepLeadTime = determinePrepLeadTime(for: meeting, hoursUntil: hoursUntilMeeting)

        // Skip if prep time hasn't arrived yet
        guard prepLeadTime >= hoursUntilMeeting else {
            return nil
        }

        // Build prep actions
        let prepActions = buildPrepActions(for: meeting, context: context)

        // Calculate prep duration
        let estimatedDuration = estimatePrepDuration(for: meeting)

        // Create prep task
        let prepTask = MeetingPrepTask(
            meetingId: meeting.id,
            meetingTitle: meeting.title,
            prepActions: prepActions,
            scheduledFor: Date(timeIntervalSinceNow: 3600),  // 1 hour from now
            estimatedDuration: estimatedDuration
        )

        // Calculate confidence
        let contextString = "calendar_prep_\(meeting.title)_\(Int(hoursUntilMeeting))h"
        let learnedConfidence = try await learningEngine.getPatternConfidence(
            for: contextString,
            agentType: .calendar,
            actionType: "schedule_meeting_prep"
        )

        // Base confidence from meeting importance
        let baseConfidence = calculatePrepConfidence(for: meeting, hoursUntil: hoursUntilMeeting)

        // Combine confidences
        let confidence = (baseConfidence * 0.6) + (learnedConfidence * 0.4)

        // Identify risks
        var risks: [String] = []
        if meeting.externalAttendees.count > 5 {
            risks.append("Large meeting - may need extensive prep")
        }
        if hoursUntilMeeting < 3 {
            risks.append("Meeting is soon - limited prep time")
        }

        let reasoning = buildPrepReasoning(meeting: meeting, hoursUntil: hoursUntilMeeting, prepActions: prepActions)

        return AgentDecision(
            agentType: .calendar,
            action: .scheduleMeetingPrep(prepTask),
            reasoning: reasoning,
            confidence: confidence,
            context: contextString,
            risks: risks,
            alternatives: ["Skip prep", "Manually schedule prep time"],
            requiresApproval: false  // Will be determined by AgentManager
        )
    }

    // MARK: - Execution

    func execute(decision: AgentDecision) async throws -> ExecutionResult {
        // Execution handled by ExecutionEngine
        return .success(details: "Prep scheduled")
    }

    // MARK: - Learning

    func learn(feedback: UserFeedback) async throws {
        try await learningEngine.recordFeedback(feedback)
    }

    // MARK: - Prep Analysis

    private func determinePrepLeadTime(for meeting: CalendarEvent, hoursUntil: Double) -> Double {
        // Determine how far in advance to schedule prep based on meeting importance

        let attendeeCount = meeting.externalAttendees.count

        if attendeeCount >= 5 {
            return 24  // Large meetings need 24h lead time
        } else if attendeeCount >= 3 {
            return 12  // Medium meetings need 12h lead time
        } else {
            return 4   // Small meetings need 4h lead time
        }
    }

    private func buildPrepActions(for meeting: CalendarEvent, context: AgentContext) -> [String] {
        var actions: [String] = []

        // Review meeting description
        if meeting.description != nil && !meeting.description!.isEmpty {
            actions.append("Review meeting agenda and description")
        }

        // Research attendees
        if !meeting.externalAttendees.isEmpty {
            actions.append("Review attendee backgrounds (\(meeting.externalAttendees.count) external attendees)")
        }

        // Check related Notion notes
        if let notionContext = context.notionContext {
            let meetingKeywords = extractKeywords(from: meeting.title)
            let relatedNotes = notionContext.notes.filter { note in
                let noteKeywords = extractKeywords(from: note.title)
                return !meetingKeywords.intersection(noteKeywords).isEmpty
            }

            if !relatedNotes.isEmpty {
                actions.append("Review \(relatedNotes.count) related Notion note(s)")
            }
        }

        // Check related tasks
        if let notionContext = context.notionContext {
            let meetingKeywords = extractKeywords(from: meeting.title)
            let relatedTasks = notionContext.tasks.filter { task in
                let taskKeywords = extractKeywords(from: task.title)
                return !meetingKeywords.intersection(taskKeywords).isEmpty
            }

            if !relatedTasks.isEmpty {
                actions.append("Review status of \(relatedTasks.count) related task(s)")
            }
        }

        // Default action if nothing specific
        if actions.isEmpty {
            actions.append("Review meeting purpose and desired outcomes")
        }

        return actions
    }

    private func estimatePrepDuration(for meeting: CalendarEvent) -> TimeInterval {
        let attendeeCount = meeting.externalAttendees.count

        if attendeeCount >= 5 {
            return 30 * 60  // 30 minutes for large meetings
        } else if attendeeCount >= 3 {
            return 20 * 60  // 20 minutes for medium meetings
        } else {
            return 10 * 60  // 10 minutes for small meetings
        }
    }

    private func calculatePrepConfidence(for meeting: CalendarEvent, hoursUntil: Double) -> Double {
        var confidence = 0.5

        // Higher confidence for external meetings with many attendees
        let attendeeCount = meeting.externalAttendees.count
        if attendeeCount >= 5 {
            confidence = 0.8
        } else if attendeeCount >= 3 {
            confidence = 0.7
        } else if attendeeCount >= 1 {
            confidence = 0.6
        }

        // Adjust based on timing
        if hoursUntil < 6 {
            confidence += 0.1  // More urgent = higher confidence
        }

        return min(confidence, 0.9)
    }

    private func buildPrepReasoning(meeting: CalendarEvent, hoursUntil: Double, prepActions: [String]) -> String {
        var reasoning = "Meeting '\(meeting.title)' is in \(Int(hoursUntil)) hours with \(meeting.externalAttendees.count) external attendee(s). "

        if prepActions.count == 1 {
            reasoning += "Suggested prep: \(prepActions[0])."
        } else {
            reasoning += "Suggested prep includes \(prepActions.count) actions."
        }

        return reasoning
    }

    // MARK: - Helpers

    private func extractKeywords(from text: String) -> Set<String> {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 3 }
        return Set(words)
    }
}
