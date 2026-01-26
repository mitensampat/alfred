import Foundation

/// Unified TaskItem model that represents both Todos and Commitments
struct TaskItem: Codable {
    let notionId: String
    let title: String
    let type: TaskType
    var status: TaskStatus
    let description: String?
    let dueDate: Date?
    let priority: Priority?
    let assignee: String?

    // Commitment-specific fields (nil for todos)
    let commitmentDirection: CommitmentDirection?
    let committedBy: String?
    let committedTo: String?
    let originalContext: String?

    // Source metadata
    let sourcePlatform: SourcePlatform?
    let sourceThread: String?
    let sourceThreadId: String?

    // Management
    let tags: [String]?
    let followUpDate: Date?
    let uniqueHash: String?
    let notes: String?

    // Auto-generated
    let createdDate: Date
    let lastUpdated: Date

    // MARK: - Enums

    enum TaskType: String, Codable {
        case todo = "Todo"
        case commitment = "Commitment"
        case followup = "Follow-up"
    }

    enum TaskStatus: String, Codable {
        case notStarted = "Not Started"
        case inProgress = "In Progress"
        case done = "Done"
        case blocked = "Blocked"
        case cancelled = "Cancelled"
    }

    enum CommitmentDirection: String, Codable {
        case iOwe = "I Owe"
        case theyOweMe = "They Owe Me"
    }

    enum Priority: String, Codable {
        case critical = "Critical"
        case high = "High"
        case medium = "Medium"
        case low = "Low"
    }

    enum SourcePlatform: String, Codable {
        case whatsapp = "WhatsApp"
        case imessage = "iMessage"
        case email = "Email"
        case signal = "Signal"
        case manual = "Manual"
    }

    // MARK: - Computed Properties

    var isOverdue: Bool {
        guard let dueDate = dueDate else { return false }
        return dueDate < Date() && status != .done && status != .cancelled
    }

    var isCommitment: Bool {
        return type == .commitment
    }

    var isTodo: Bool {
        return type == .todo
    }

    var isFollowup: Bool {
        return type == .followup
    }

    var isActive: Bool {
        return status != .done && status != .cancelled
    }

    // MARK: - Convenience Initializers

    /// Create a TaskItem from a TodoItem
    static func fromTodoItem(_ todo: TodoItem, notionId: String = "", hash: String? = nil) -> TaskItem {
        return TaskItem(
            notionId: notionId,
            title: todo.title,
            type: .todo,
            status: .notStarted,
            description: todo.description,
            dueDate: todo.dueDate,
            priority: nil,
            assignee: nil,
            commitmentDirection: nil,
            committedBy: nil,
            committedTo: nil,
            originalContext: nil,
            sourcePlatform: .whatsapp,
            sourceThread: nil,
            sourceThreadId: nil,
            tags: nil,
            followUpDate: nil,
            uniqueHash: hash,
            notes: nil,
            createdDate: Date(),
            lastUpdated: Date()
        )
    }

    /// Create a TaskItem from a Commitment
    static func fromCommitment(_ commitment: Commitment, notionId: String = "") -> TaskItem {
        let direction: CommitmentDirection = commitment.type == .iOwe ? .iOwe : .theyOweMe
        
        let platform: SourcePlatform
        switch commitment.sourcePlatform {
        case .whatsapp: platform = .whatsapp
        case .imessage: platform = .imessage
        case .email: platform = .email
        case .signal: platform = .signal
        }

        let priority: Priority?
        switch commitment.priority {
        case .critical: priority = .critical
        case .high: priority = .high
        case .medium: priority = .medium
        case .low: priority = .low
        }

        let status: TaskStatus
        switch commitment.status {
        case .open: status = .notStarted
        case .inProgress: status = .inProgress
        case .completed: status = .done
        case .cancelled: status = .cancelled
        }

        return TaskItem(
            notionId: notionId,
            title: commitment.title,
            type: .commitment,
            status: status,
            description: commitment.commitmentText,
            dueDate: commitment.dueDate,
            priority: priority,
            assignee: nil,
            commitmentDirection: direction,
            committedBy: commitment.committedBy,
            committedTo: commitment.committedTo,
            originalContext: commitment.originalContext,
            sourcePlatform: platform,
            sourceThread: commitment.sourceThread,
            sourceThreadId: nil,  // Commitment doesn't have sourceThreadId
            tags: nil,
            followUpDate: commitment.followupScheduled,  // Note: lowercase 'u'
            uniqueHash: commitment.uniqueHash,
            notes: nil,
            createdDate: Date(),
            lastUpdated: Date()
        )
    }

    /// Create a TaskItem from a FollowupReminder
    static func fromFollowup(_ followup: FollowupReminder, notionId: String = "", hash: String? = nil) -> TaskItem {
        let priority: Priority
        switch followup.priority {
        case .critical: priority = .critical
        case .high: priority = .high
        case .medium: priority = .medium
        case .low: priority = .low
        }

        return TaskItem(
            notionId: notionId,
            title: followup.followupAction,
            type: .followup,
            status: .notStarted,
            description: followup.originalContext,
            dueDate: followup.scheduledFor,
            priority: priority,
            assignee: nil,
            commitmentDirection: nil,
            committedBy: nil,
            committedTo: nil,
            originalContext: followup.originalContext,
            sourcePlatform: .manual,
            sourceThread: nil,
            sourceThreadId: nil,
            tags: ["follow-up"],
            followUpDate: followup.scheduledFor,
            uniqueHash: hash,
            notes: nil,
            createdDate: Date(),
            lastUpdated: Date()
        )
    }

    /// Convert TaskItem to FollowupReminder (if applicable)
    func toFollowupReminder() -> FollowupReminder? {
        guard type == .followup else { return nil }

        let urgencyLevel: UrgencyLevel
        switch priority {
        case .critical: urgencyLevel = .critical
        case .high: urgencyLevel = .high
        case .medium: urgencyLevel = .medium
        case .low: urgencyLevel = .low
        case .none: urgencyLevel = .medium
        }

        return FollowupReminder(
            originalContext: originalContext ?? description ?? "",
            followupAction: title,
            scheduledFor: dueDate ?? Date(),
            priority: urgencyLevel
        )
    }

    /// Convert TaskItem back to Commitment (for backwards compatibility)
    func toCommitment() -> Commitment? {
        guard type == .commitment else { return nil }
        guard let direction = commitmentDirection else { return nil }
        guard let committedBy = committedBy else { return nil }
        guard let committedTo = committedTo else { return nil }

        let commitmentType: Commitment.CommitmentType = direction == .iOwe ? .iOwe : .theyOwe

        let commitmentStatus: Commitment.CommitmentStatus
        switch status {
        case .notStarted: commitmentStatus = .open
        case .inProgress: commitmentStatus = .inProgress
        case .done: commitmentStatus = .completed
        case .cancelled: commitmentStatus = .cancelled
        case .blocked: commitmentStatus = .open
        }

        let platform: MessagePlatform
        switch sourcePlatform {
        case .whatsapp: platform = .whatsapp
        case .imessage: platform = .imessage
        case .email: platform = .email
        case .signal: platform = .signal
        case .manual, .none: platform = .whatsapp  // Default fallback
        }

        let urgencyLevel: UrgencyLevel
        switch priority {
        case .critical: urgencyLevel = .critical
        case .high: urgencyLevel = .high
        case .medium: urgencyLevel = .medium
        case .low: urgencyLevel = .low
        case .none: urgencyLevel = .medium  // Default fallback
        }

        return Commitment(
            type: commitmentType,
            status: commitmentStatus,
            title: title,
            commitmentText: description ?? title,
            committedBy: committedBy,
            committedTo: committedTo,
            sourcePlatform: platform,
            sourceThread: sourceThread ?? "",
            dueDate: dueDate,
            priority: urgencyLevel,
            originalContext: originalContext ?? "",
            followupScheduled: followUpDate,
            notionId: notionId,
            createdAt: createdDate,
            lastUpdated: lastUpdated
        )
    }
}
