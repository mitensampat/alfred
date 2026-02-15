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

    /// Generate a unique hash for deduplication
    /// Uses normalized text to handle AI extraction variations
    static func generateHash(commitmentText: String, sourceThread: String, committedBy: String, dueDate: Date?) -> String {
        // Normalize commitment text to handle AI extraction variations
        let normalizedText = normalizeForHash(commitmentText)

        // Normalize committed by (lowercase, trim)
        let normalizedBy = committedBy.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Normalize thread (lowercase, trim)
        let normalizedThread = sourceThread.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Use date bucket (same day = same bucket) instead of exact timestamp
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
    private static func normalizeForHash(_ text: String) -> String {
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
