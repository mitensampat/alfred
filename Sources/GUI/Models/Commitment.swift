import Foundation
import CryptoKit

// MARK: - Commitment Models (GUI)

extension MessagePlatform {
    var displayName: String {
        switch self {
        case .imessage:
            return "iMessage"
        case .whatsapp:
            return "WhatsApp"
        case .signal:
            return "Signal"
        case .email:
            return "Email"
        }
    }
}

struct Commitment: Codable, Identifiable {
    let id: UUID
    let type: CommitmentType
    var status: CommitmentStatus
    let title: String
    let commitmentText: String
    let committedBy: String
    let committedTo: String
    let sourcePlatform: MessagePlatform
    let sourceThread: String
    let dueDate: Date?
    let priority: UrgencyLevel
    let originalContext: String
    let followupScheduled: Date?
    var notionId: String?
    var notionTaskId: String?
    let uniqueHash: String
    let createdAt: Date
    var lastUpdated: Date

    enum CommitmentType: String, Codable {
        case iOwe = "I Owe"
        case theyOwe = "They Owe Me"

        var displayName: String { rawValue }
        var emoji: String {
            switch self {
            case .iOwe: return "📤"
            case .theyOwe: return "📥"
            }
        }
    }

    enum CommitmentStatus: String, Codable {
        case open = "Open"
        case inProgress = "In Progress"
        case completed = "Completed"
        case cancelled = "Cancelled"

        var displayName: String { rawValue }
        var emoji: String {
            switch self {
            case .open: return "🔵"
            case .inProgress: return "🟡"
            case .completed: return "✅"
            case .cancelled: return "❌"
            }
        }
    }

    var isOverdue: Bool {
        guard let dueDate = dueDate else { return false }
        return dueDate < Date() && (status == .open || status == .inProgress)
    }

    var daysUntilDue: Int? {
        guard let dueDate = dueDate else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: dueDate).day
    }

    var formattedDueDate: String {
        guard let dueDate = dueDate else { return "No deadline" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: dueDate)
    }

    // MARK: - Initializer

    init(
        id: UUID = UUID(),
        type: CommitmentType,
        status: CommitmentStatus = .open,
        title: String,
        commitmentText: String,
        committedBy: String,
        committedTo: String,
        sourcePlatform: MessagePlatform,
        sourceThread: String,
        dueDate: Date?,
        priority: UrgencyLevel,
        originalContext: String,
        followupScheduled: Date? = nil,
        notionId: String? = nil,
        notionTaskId: String? = nil,
        createdAt: Date = Date(),
        lastUpdated: Date = Date()
    ) {
        self.id = id
        self.type = type
        self.status = status
        self.title = title
        self.commitmentText = commitmentText
        self.committedBy = committedBy
        self.committedTo = committedTo
        self.sourcePlatform = sourcePlatform
        self.sourceThread = sourceThread
        self.dueDate = dueDate
        self.priority = priority
        self.originalContext = originalContext
        self.followupScheduled = followupScheduled
        self.notionId = notionId
        self.notionTaskId = notionTaskId
        self.createdAt = createdAt
        self.lastUpdated = lastUpdated

        // Generate unique hash for deduplication
        self.uniqueHash = Self.generateHash(
            commitmentText: commitmentText,
            sourceThread: sourceThread,
            committedBy: committedBy,
            dueDate: dueDate
        )
    }

    // MARK: - Hash Generation

    static func generateHash(commitmentText: String, sourceThread: String, committedBy: String, dueDate: Date?) -> String {
        let dueDateString = dueDate?.timeIntervalSince1970.description ?? "no-date"
        let combined = "\(commitmentText)|\(sourceThread)|\(committedBy)|\(dueDateString)"

        let data = Data(combined.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}

extension UrgencyLevel {
    var emoji: String {
        switch self {
        case .critical: return "🔴"
        case .high: return "🟠"
        case .medium: return "🟡"
        case .low: return "🟢"
        }
    }
}
