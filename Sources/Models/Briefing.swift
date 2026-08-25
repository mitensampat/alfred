import Foundation

struct CoachingCardData: Codable {
    let type: String        // "leverage", "relationship", "avoidance"
    let label: String       // "Leverage", "Relationship", "Avoidance"
    let insight: String     // The coaching text (1-2 sentences)
}

struct DailyBriefing: Codable {
    let date: Date
    let messagingSummary: MessagingSummary
    let calendarBriefing: CalendarBriefing
    let actionItems: [ActionItem]
    let notionContext: NotionContext?
    let agentDecisions: [AgentDecision]?
    let agentInsights: AgentInsights?
    let coachingCards: [CoachingCardData]?
    let generatedAt: Date
}

// MARK: - Agent Insights

struct AgentInsights: Codable {
    let recentLearnings: [AgentLearning]
    let proactiveNotices: [ProactiveNotice]
    let commitmentReminders: [CommitmentReminder]
    let crossAgentSuggestions: [CrossAgentSuggestion]

    var isEmpty: Bool {
        recentLearnings.isEmpty && proactiveNotices.isEmpty &&
        commitmentReminders.isEmpty && crossAgentSuggestions.isEmpty
    }
}

struct AgentLearning: Codable {
    let agentType: AgentType
    let description: String
    let learnedAt: Date
    let confidence: Double
}

struct ProactiveNotice: Codable {
    let agentType: AgentType
    let title: String
    let message: String
    let priority: UrgencyLevel
    let suggestedAction: String?
    let relatedContext: String?
}

struct CommitmentReminder: Codable {
    let commitment: String
    let committedTo: String?
    let dueDate: Date?
    let daysOverdue: Int?
    let source: String
    let suggestedAction: String
}

struct CrossAgentSuggestion: Codable {
    let title: String
    let description: String
    let involvedAgents: [AgentType]
    let confidence: Double
}

struct NotionContext: Codable {
    let notes: [NotionNote]
    let tasks: [NotionTask]
}

struct NotionNote: Codable {
    let id: String
    let title: String
    let content: String
    let lastEdited: Date
}

/// The result of one incremental "pages edited since X" pull for a single database.
///
/// Carries enough for the caller to decide whether it is safe to advance that database's sync
/// watermark: a pull that lost pages must not be recorded as a clean pull.
struct NotionEditedPageBatch {
    /// Readable pages, ascending by `lastEdited`.
    let notes: [NotionNote]
    /// Pages Notion listed but whose content could not be read.
    let failedPageIds: [String]
    /// `lastEdited` of the earliest failed page — the point a watermark must not advance past.
    let firstFailureAt: Date?
    /// True when the request cap was hit and more edited pages remain unseen.
    let truncated: Bool

    var isClean: Bool { failedPageIds.isEmpty && !truncated }
}

struct NotionTask: Codable {
    let id: String
    let title: String
    let status: String
    let dueDate: Date?
}

struct MessagingSummary: Codable {
    let keyInteractions: [MessageSummary]
    let needsResponse: [MessageSummary]
    let criticalMessages: [MessageSummary]
    let stats: MessagingStats
    let warnings: [String]?

    struct MessagingStats: Codable {
        let totalMessages: Int
        let unreadMessages: Int
        let threadsNeedingResponse: Int
        let byPlatform: [MessagePlatform: Int]
    }
}

struct CalendarBriefing: Codable {
    let schedule: DailySchedule
    let meetingBriefings: [MeetingBriefing]
    let focusTime: TimeInterval
    let recommendations: [String]
}

struct ActionItem: Codable, Identifiable {
    let id: String
    let title: String
    let description: String
    let source: ActionSource
    let priority: UrgencyLevel
    let dueDate: Date?
    let estimatedDuration: TimeInterval?
    let category: ActionCategory
    let counterparty: String?  // Who this task is related to (for commitments, messages)

    enum ActionSource: String, Codable {
        case message
        case meeting
        case calendar
        case system
    }

    enum ActionCategory: String, Codable {
        case respond
        case prepare
        case follow_up
        case decision
        case task
    }

    // Convenience init with default counterparty = nil for backward compatibility
    init(id: String, title: String, description: String, source: ActionSource, priority: UrgencyLevel, dueDate: Date?, estimatedDuration: TimeInterval?, category: ActionCategory, counterparty: String? = nil) {
        self.id = id
        self.title = title
        self.description = description
        self.source = source
        self.priority = priority
        self.dueDate = dueDate
        self.estimatedDuration = estimatedDuration
        self.category = category
        self.counterparty = counterparty
    }
}

struct AttentionDefenseReport: Codable {
    let currentTime: Date
    let upcomingDeadlines: [ActionItem]
    let criticalTasks: [ActionItem]
    let canPushOff: [PushOffSuggestion]
    let mustDoToday: [ActionItem]
    let timeAvailable: TimeInterval
    let recommendations: [String]
}

struct PushOffSuggestion: Codable {
    let item: ActionItem
    let reason: String
    let suggestedNewDate: Date
    let impact: ImpactLevel

    enum ImpactLevel: String, Codable {
        case none
        case low
        case medium
        case high
    }
}

// MARK: - Daily Agent Digest

struct AgentDigest: Codable {
    let date: Date
    let summary: DigestSummary
    let agentActivity: [AgentActivitySummary]
    let newLearnings: [AgentLearning]
    let decisionsRequiringReview: [AgentDecision]
    let upcomingFollowups: [FollowupDigestItem]
    let commitmentStatus: CommitmentStatusSummary
    let recommendations: [String]
    let generatedAt: Date
}

struct DigestSummary: Codable {
    let totalDecisions: Int
    let decisionsExecuted: Int
    let decisionsPending: Int
    let newLearningsCount: Int
    let followupsCreated: Int
    let commitmentsClosed: Int
}

struct AgentActivitySummary: Codable {
    let agentType: AgentType
    let decisionsCount: Int
    let successRate: Double
    let topAction: String?
    let keyInsight: String?
}

struct FollowupDigestItem: Codable {
    let title: String
    let scheduledFor: Date
    let context: String
    let priority: UrgencyLevel
    let isOverdue: Bool
}

struct CommitmentStatusSummary: Codable {
    let activeIOwe: Int
    let activeTheyOwe: Int
    let completedToday: Int
    let overdueCount: Int
    let upcomingThisWeek: Int
}
