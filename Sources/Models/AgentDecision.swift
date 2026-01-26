import Foundation

// MARK: - Agent Decision Models

struct AgentDecision: Codable, Identifiable {
    let id: UUID
    let agentType: AgentType
    let action: AgentAction
    let reasoning: String
    let confidence: Double  // 0.0 to 1.0
    let context: String
    let risks: [String]
    let alternatives: [String]
    let requiresApproval: Bool
    let timestamp: Date

    init(
        id: UUID = UUID(),
        agentType: AgentType,
        action: AgentAction,
        reasoning: String,
        confidence: Double,
        context: String,
        risks: [String] = [],
        alternatives: [String] = [],
        requiresApproval: Bool,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.agentType = agentType
        self.action = action
        self.reasoning = reasoning
        self.confidence = confidence
        self.context = context
        self.risks = risks
        self.alternatives = alternatives
        self.requiresApproval = requiresApproval
        self.timestamp = timestamp
    }
}

enum AgentType: String, Codable, CaseIterable {
    case communication
    case task
    case calendar
    case followup

    var displayName: String {
        switch self {
        case .communication: return "Communication"
        case .task: return "Task"
        case .calendar: return "Calendar"
        case .followup: return "Follow-up"
        }
    }

    var icon: String {
        switch self {
        case .communication: return "message.fill"
        case .task: return "checklist"
        case .calendar: return "calendar"
        case .followup: return "bell.fill"
        }
    }
}

enum AgentAction: Codable {
    case draftResponse(MessageDraft)
    case adjustTaskPriority(TaskAdjustment)
    case scheduleMeetingPrep(MeetingPrepTask)
    case createFollowup(FollowupReminder)
    case noAction(reason: String)

    var description: String {
        switch self {
        case .draftResponse(let draft):
            return "Draft response to \(draft.recipient)"
        case .adjustTaskPriority(let adj):
            return "Change task priority: \(adj.currentPriority.rawValue) → \(adj.newPriority.rawValue)"
        case .scheduleMeetingPrep(let prep):
            return "Schedule prep for: \(prep.meetingTitle)"
        case .createFollowup(let followup):
            return "Create follow-up: \(followup.followupAction)"
        case .noAction(let reason):
            return "No action: \(reason)"
        }
    }
}

// MARK: - Action Details

struct MessageDraft: Codable {
    let recipient: String
    let platform: MessagePlatform
    let content: String
    let tone: MessageTone
    let suggestedSendTime: Date?

    enum MessageTone: String, Codable {
        case professional
        case casual
        case friendly
        case formal
    }
}

struct TaskAdjustment: Codable {
    let taskId: String
    let taskTitle: String
    let currentPriority: UrgencyLevel
    let newPriority: UrgencyLevel
    let reason: String
}

struct MeetingPrepTask: Codable {
    let meetingId: String
    let meetingTitle: String
    let prepActions: [String]
    let scheduledFor: Date
    let estimatedDuration: TimeInterval
}

struct FollowupReminder: Codable {
    let originalContext: String
    let followupAction: String
    let scheduledFor: Date
    let priority: UrgencyLevel
}

// MARK: - Execution Result

enum ExecutionResult: Codable {
    case success(details: String)
    case failure(error: String)
    case skipped

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

// MARK: - Agent Context

struct AgentContext: Codable {
    let briefing: DailyBriefing?
    let messagingSummary: MessagingSummary?
    let calendarBriefing: CalendarBriefing?
    let notionContext: NotionContext?
    let timestamp: Date

    init(
        briefing: DailyBriefing? = nil,
        messagingSummary: MessagingSummary? = nil,
        calendarBriefing: CalendarBriefing? = nil,
        notionContext: NotionContext? = nil,
        timestamp: Date = Date()
    ) {
        self.briefing = briefing
        self.messagingSummary = messagingSummary
        self.calendarBriefing = calendarBriefing
        self.notionContext = notionContext
        self.timestamp = timestamp
    }
}

// MARK: - User Feedback

struct UserFeedback: Codable, Identifiable {
    let id: UUID
    let decisionId: UUID
    let feedbackType: FeedbackType
    let wasApproved: Bool
    let wasSuccessful: Bool
    let userComment: String?
    let context: String
    let timestamp: Date

    enum FeedbackType: String, Codable {
        case explicit  // User clicked thumbs up/down
        case implicit  // Tracked from approval/rejection
    }

    init(
        id: UUID = UUID(),
        decisionId: UUID,
        feedbackType: FeedbackType,
        wasApproved: Bool,
        wasSuccessful: Bool,
        userComment: String? = nil,
        context: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.decisionId = decisionId
        self.feedbackType = feedbackType
        self.wasApproved = wasApproved
        self.wasSuccessful = wasSuccessful
        self.userComment = userComment
        self.context = context
        self.timestamp = timestamp
    }
}

// MARK: - Decision Modifications

struct DecisionModifications: Codable {
    let modifiedReasoning: String?
    let modifiedAction: AgentAction?
    let userNotes: String?
}

// MARK: - Audit Entry

struct AuditEntry: Codable, Identifiable {
    let id: UUID
    let decision: AgentDecision
    let executionResult: ExecutionResult?
    let feedback: UserFeedback?
    let timestamp: Date

    init(
        id: UUID = UUID(),
        decision: AgentDecision,
        executionResult: ExecutionResult? = nil,
        feedback: UserFeedback? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.decision = decision
        self.executionResult = executionResult
        self.feedback = feedback
        self.timestamp = timestamp
    }
}
