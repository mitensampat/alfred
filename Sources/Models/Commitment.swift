import Foundation
import CryptoKit

// MARK: - Commitment Models

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
    var notionId: String?  // Link to Notion page
    var notionTaskId: String?  // Link to related task
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
        // Hash is based on normalized text + date only — NOT thread or counterparty.
        // The same commitment discussed in multiple threads or attributed to different
        // people by the LLM should still be deduplicated.
        self.uniqueHash = Self.generateHash(
            commitmentText: commitmentText,
            dueDate: dueDate
        )
    }

    // MARK: - Hash Generation

    /// Generate a unique hash for deduplication.
    /// Based on normalized text + date bucket ONLY.
    /// Thread and counterparty are intentionally excluded — the same commitment
    /// discussed across multiple threads or attributed to different people
    /// by the LLM should produce the same hash.
    static func generateHash(commitmentText: String, dueDate: Date?) -> String {
        let normalizedText = normalizeForHash(commitmentText)

        // Use date bucket (same day = same bucket) instead of exact timestamp
        let dateBucket: String
        if let dueDate = dueDate {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            dateBucket = formatter.string(from: dueDate)
        } else {
            dateBucket = "no-date"
        }

        let combined = "\(normalizedText)|\(dateBucket)"

        let data = Data(combined.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Legacy hash for migration — matches the old 4-field hash used before v2.0.5
    static func generateLegacyHash(commitmentText: String, sourceThread: String, committedBy: String, dueDate: Date?) -> String {
        let normalizedText = normalizeForHash(commitmentText)
        let normalizedBy = committedBy.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedThread = sourceThread.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let dateBucket: String
        if let dueDate = dueDate {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            dateBucket = formatter.string(from: dueDate)
        } else {
            dateBucket = "no-date"
        }
        let combined = "\(normalizedText)|\(normalizedThread)|\(normalizedBy)|\(dateBucket)"
        let data = Data(combined.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Normalize text for hash comparison
    /// - Lowercase
    /// - Remove punctuation and extra whitespace
    /// - Extract key nouns/verbs (simplified approach: keep words >= 3 chars)
    /// - Sort words to handle word order variations
    static func normalizeForHash(_ text: String) -> String {
        // Common words to ignore (articles, prepositions, common verbs)
        let stopWords: Set<String> = [
            "the", "a", "an", "is", "are", "was", "were", "be", "been", "being",
            "have", "has", "had", "do", "does", "did", "will", "would", "could",
            "should", "may", "might", "must", "shall", "can", "need", "dare",
            "to", "of", "in", "for", "on", "with", "at", "by", "from", "as",
            "into", "through", "during", "before", "after", "above", "below",
            "and", "but", "or", "nor", "so", "yet", "both", "either", "neither",
            "this", "that", "these", "those", "it", "its", "i", "you", "he",
            "she", "we", "they", "me", "him", "her", "us", "them", "my", "your",
            "his", "our", "their", "please", "pls", "thanks", "thank", "hi", "hey"
        ]

        // 1. Lowercase
        var normalized = text.lowercased()

        // 2. Remove punctuation (keep only letters, numbers, spaces)
        normalized = normalized.filter { $0.isLetter || $0.isNumber || $0.isWhitespace }

        // 3. Split into words, filter stop words and short words
        let words = normalized.split(separator: " ")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 3 && !stopWords.contains($0) }

        // 4. Sort words alphabetically for order-independent matching
        let sortedWords = words.sorted()

        // 5. Take first 8 significant words (to keep hash focused on key content)
        let keyWords = Array(sortedWords.prefix(8))

        return keyWords.joined(separator: " ")
    }

    // MARK: - Helpers

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
}

// MARK: - Commitment Extraction Result

struct CommitmentExtraction: Codable {
    let commitments: [Commitment]
    let analysisDate: Date
    let sourceInfo: SourceInfo

    struct SourceInfo: Codable {
        let platform: MessagePlatform
        let threadId: String
        let threadName: String
        let messagesAnalyzed: Int
        let dateRange: DateRange

        struct DateRange: Codable {
            let from: Date
            let to: Date
        }
    }
}

// MARK: - Commitment Query Filters

struct CommitmentQueryFilter {
    let type: Commitment.CommitmentType?
    let status: Commitment.CommitmentStatus?
    let platform: MessagePlatform?
    let overdueOnly: Bool
    let dueSoon: Bool  // Due within next 7 days
    let contactName: String?

    init(
        type: Commitment.CommitmentType? = nil,
        status: Commitment.CommitmentStatus? = nil,
        platform: MessagePlatform? = nil,
        overdueOnly: Bool = false,
        dueSoon: Bool = false,
        contactName: String? = nil
    ) {
        self.type = type
        self.status = status
        self.platform = platform
        self.overdueOnly = overdueOnly
        self.dueSoon = dueSoon
        self.contactName = contactName
    }
}

// MARK: - Commitment Configuration

struct CommitmentConfig: Codable {
    let enabled: Bool
    let notionDatabaseId: String?
    let autoScanOnBriefing: Bool
    let autoScanContacts: [String]
    let defaultLookbackDays: Int
    let priorityKeywords: PriorityKeywords
    let notificationPreferences: NotificationPreferences

    enum CodingKeys: String, CodingKey {
        case enabled
        case notionDatabaseId = "notion_database_id"
        case autoScanOnBriefing = "auto_scan_on_briefing"
        case autoScanContacts = "auto_scan_contacts"
        case defaultLookbackDays = "default_lookback_days"
        case priorityKeywords = "priority_keywords"
        case notificationPreferences = "notification_preferences"
    }

    struct PriorityKeywords: Codable {
        let critical: [String]
        let high: [String]
        let medium: [String]
        let low: [String]
    }

    struct NotificationPreferences: Codable {
        let notifyOnOverdue: Bool
        let notifyBeforeDeadlineHours: Int

        enum CodingKeys: String, CodingKey {
            case notifyOnOverdue = "notify_on_overdue"
            case notifyBeforeDeadlineHours = "notify_before_deadline_hours"
        }
    }
}

// MARK: - LLM Extraction Request/Response

struct CommitmentExtractionRequest: Codable {
    let messages: [MessageContext]
    let userInfo: UserInfo
    let threadName: String  // The contact/group name (e.g., "Kunal Shah" instead of WhatsApp ID)

    struct MessageContext: Codable {
        let sender: String
        let senderName: String?  // Display name (especially important for group chats)
        let content: String
        let timestamp: Date
        let isFromUser: Bool
    }

    struct UserInfo: Codable {
        let name: String
        let email: String
    }
}

struct CommitmentExtractionResponse: Codable {
    let commitments: [ExtractedCommitment]

    struct ExtractedCommitment: Codable {
        let type: String  // "i_owe" or "they_owe"
        let title: String
        let commitmentText: String
        let committedBy: String
        let committedTo: String
        let dueDate: String?  // ISO8601 string
        let priority: String  // "critical", "high", "medium", "low"
        let context: String
        let confidence: Double  // 0.0 to 1.0
    }
}
