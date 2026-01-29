import Foundation

/// Represents an item extracted from message analysis that may be added to Notion Tasks
/// Used for interactive confirmation prompts before saving
struct ExtractedItem: Codable, Identifiable {
    let id: UUID
    let type: ItemType
    let title: String
    let description: String?
    let priority: ItemPriority
    let source: ItemSource
    let dueDate: Date?

    // For commitments
    let commitmentDirection: CommitmentDirection?
    let committedBy: String?
    let committedTo: String?

    // For tracking
    let originalContext: String?
    let uniqueHash: String

    init(
        id: UUID = UUID(),
        type: ItemType,
        title: String,
        description: String? = nil,
        priority: ItemPriority = .medium,
        source: ItemSource,
        dueDate: Date? = nil,
        commitmentDirection: CommitmentDirection? = nil,
        committedBy: String? = nil,
        committedTo: String? = nil,
        originalContext: String? = nil,
        uniqueHash: String? = nil
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.description = description
        self.priority = priority
        self.source = source
        self.dueDate = dueDate
        self.commitmentDirection = commitmentDirection
        self.committedBy = committedBy
        self.committedTo = committedTo
        self.originalContext = originalContext
        self.uniqueHash = uniqueHash ?? Self.generateHash(title: title, context: originalContext ?? "", type: type)
    }

    // MARK: - Types

    enum ItemType: String, Codable {
        case commitment = "Commitment"
        case todo = "Todo"
        case followup = "Follow-up"

        var emoji: String {
            switch self {
            case .commitment: return "🤝"
            case .todo: return "✅"
            case .followup: return "🔄"
            }
        }
    }

    enum ItemPriority: String, Codable {
        case critical = "Critical"
        case high = "High"
        case medium = "Medium"
        case low = "Low"

        var emoji: String {
            switch self {
            case .critical: return "🔴"
            case .high: return "🟠"
            case .medium: return "🟡"
            case .low: return "🟢"
            }
        }
    }

    enum CommitmentDirection: String, Codable {
        case iOwe = "I Owe"
        case theyOweMe = "They Owe Me"

        var emoji: String {
            switch self {
            case .iOwe: return "📤"
            case .theyOweMe: return "📥"
            }
        }
    }

    struct ItemSource: Codable {
        let platform: SourcePlatform
        let contact: String
        let threadName: String?
        let threadId: String?

        enum SourcePlatform: String, Codable {
            case whatsapp = "WhatsApp"
            case imessage = "iMessage"
            case email = "Email"
            case signal = "Signal"
            case manual = "Manual"
        }

        var displayName: String {
            if let thread = threadName {
                return "\(platform.rawValue): \(thread)"
            }
            return "\(platform.rawValue): \(contact)"
        }
    }

    // MARK: - Helpers

    static func generateHash(title: String, context: String, type: ItemType) -> String {
        let input = "\(title)|\(context)|\(type.rawValue)"
        return String(input.hashValue)
    }

    /// Format for display in CLI
    func formattedForDisplay(index: Int) -> String {
        var lines: [String] = []

        // For commitments, use arrow format: "→ John: Send Q4 deck" or "← Sarah: Review proposal"
        if let direction = commitmentDirection {
            let arrow = direction == .iOwe ? "→" : "←"
            let counterparty = direction == .iOwe ? (committedTo ?? "them") : (committedBy ?? "them")
            lines.append("\(index). \(type.emoji) \(priority.emoji) \(arrow) \(counterparty): \(title)")
        } else {
            lines.append("\(index). \(type.emoji) \(priority.emoji) \(title)")
        }

        if let desc = description, !desc.isEmpty {
            let truncated = desc.count > 80 ? String(desc.prefix(77)) + "..." : desc
            lines.append("   \(truncated)")
        }

        if let due = dueDate {
            lines.append("   Due: \(due.formatted(date: .abbreviated, time: .omitted))")
        }

        lines.append("   Source: \(source.displayName)")

        return lines.joined(separator: "\n")
    }

    // MARK: - Conversion to TaskItem

    func toTaskItem() -> TaskItem {
        let taskType: TaskItem.TaskType
        switch type {
        case .commitment: taskType = .commitment
        case .todo: taskType = .todo
        case .followup: taskType = .followup
        }

        let taskPriority: TaskItem.Priority?
        switch priority {
        case .critical: taskPriority = .critical
        case .high: taskPriority = .high
        case .medium: taskPriority = .medium
        case .low: taskPriority = .low
        }

        let direction: TaskItem.CommitmentDirection?
        if let dir = commitmentDirection {
            direction = dir == .iOwe ? .iOwe : .theyOweMe
        } else {
            direction = nil
        }

        let platform: TaskItem.SourcePlatform
        switch source.platform {
        case .whatsapp: platform = .whatsapp
        case .imessage: platform = .imessage
        case .email: platform = .email
        case .signal: platform = .signal
        case .manual: platform = .manual
        }

        return TaskItem(
            notionId: "",
            title: title,
            type: taskType,
            status: .notStarted,
            description: description,
            dueDate: dueDate,
            priority: taskPriority,
            assignee: nil,
            commitmentDirection: direction,
            committedBy: committedBy,
            committedTo: committedTo,
            originalContext: originalContext,
            sourcePlatform: platform,
            sourceThread: source.threadName,
            sourceThreadId: source.threadId,
            tags: nil,
            followUpDate: type == .followup ? dueDate : nil,
            uniqueHash: uniqueHash,
            notes: nil,
            createdDate: Date(),
            lastUpdated: Date()
        )
    }

    // MARK: - Factory Methods

    /// Create from a Commitment
    static func fromCommitment(_ commitment: Commitment) -> ExtractedItem {
        let direction: CommitmentDirection = commitment.type == .iOwe ? .iOwe : .theyOweMe

        let platform: ItemSource.SourcePlatform
        switch commitment.sourcePlatform {
        case .whatsapp: platform = .whatsapp
        case .imessage: platform = .imessage
        case .email: platform = .email
        case .signal: platform = .signal
        }

        let priority: ItemPriority
        switch commitment.priority {
        case .critical: priority = .critical
        case .high: priority = .high
        case .medium: priority = .medium
        case .low: priority = .low
        }

        return ExtractedItem(
            type: .commitment,
            title: commitment.title,
            description: commitment.commitmentText,
            priority: priority,
            source: ItemSource(
                platform: platform,
                contact: commitment.type == .iOwe ? commitment.committedTo : commitment.committedBy,
                threadName: commitment.sourceThread,
                threadId: nil
            ),
            dueDate: commitment.dueDate,
            commitmentDirection: direction,
            committedBy: commitment.committedBy,
            committedTo: commitment.committedTo,
            originalContext: commitment.originalContext,
            uniqueHash: commitment.uniqueHash
        )
    }

    /// Create from a TodoItem
    static func fromTodoItem(_ todo: TodoItem, platform: ItemSource.SourcePlatform, contact: String, threadName: String?) -> ExtractedItem {
        let hash = "\(todo.title)|\(todo.description ?? "")|\(platform.rawValue)|\(threadName ?? "")"

        return ExtractedItem(
            type: .todo,
            title: todo.title,
            description: todo.description,
            priority: .medium,
            source: ItemSource(
                platform: platform,
                contact: contact,
                threadName: threadName,
                threadId: nil
            ),
            dueDate: todo.dueDate,
            uniqueHash: String(hash.hashValue)
        )
    }

    /// Create from a FollowupReminder
    static func fromFollowup(_ followup: FollowupReminder, platform: ItemSource.SourcePlatform, contact: String) -> ExtractedItem {
        let priority: ItemPriority
        switch followup.priority {
        case .critical: priority = .critical
        case .high: priority = .high
        case .medium: priority = .medium
        case .low: priority = .low
        }

        let hash = "\(followup.followupAction)|\(followup.originalContext)|\(followup.scheduledFor.timeIntervalSince1970)"

        return ExtractedItem(
            type: .followup,
            title: followup.followupAction,
            description: followup.originalContext,
            priority: priority,
            source: ItemSource(
                platform: platform,
                contact: contact,
                threadName: nil,
                threadId: nil
            ),
            dueDate: followup.scheduledFor,
            originalContext: followup.originalContext,
            uniqueHash: String(hash.hashValue)
        )
    }
}

// MARK: - Batch Extraction Result

/// Result of extracting items from messages with interactive approval support
struct ExtractionResult {
    let items: [ExtractedItem]
    let sourceInfo: SourceInfo

    struct SourceInfo {
        let contact: String
        let platform: String
        let messagesAnalyzed: Int
        let dateRange: (start: Date, end: Date)
    }

    var commitments: [ExtractedItem] {
        items.filter { $0.type == .commitment }
    }

    var todos: [ExtractedItem] {
        items.filter { $0.type == .todo }
    }

    var followups: [ExtractedItem] {
        items.filter { $0.type == .followup }
    }

    var hasItems: Bool {
        !items.isEmpty
    }

    var summary: String {
        var parts: [String] = []
        if !commitments.isEmpty {
            parts.append("\(commitments.count) commitment(s)")
        }
        if !todos.isEmpty {
            parts.append("\(todos.count) todo(s)")
        }
        if !followups.isEmpty {
            parts.append("\(followups.count) follow-up(s)")
        }
        return parts.isEmpty ? "No items found" : parts.joined(separator: ", ")
    }
}
