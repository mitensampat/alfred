import Foundation

enum MessagePlatform: String, Codable {
    case imessage
    case whatsapp
    case signal
    case email
}

enum MessageDirection: String, Codable {
    case incoming
    case outgoing
}

struct Message: Codable, Identifiable {
    let id: String
    let platform: MessagePlatform
    let sender: String
    let senderName: String?
    let recipient: String
    let content: String
    let timestamp: Date
    let direction: MessageDirection
    let chatId: String
    let isRead: Bool
    let hasAttachment: Bool

    var needsResponse: Bool {
        direction == .incoming && !isRead
    }
}

struct MessageThread: Codable {
    let contactIdentifier: String
    let contactName: String?
    let platform: MessagePlatform
    let messages: [Message]
    let unreadCount: Int
    let lastMessageDate: Date

    var needsResponse: Bool {
        unreadCount > 0 || messages.filter { $0.direction == .incoming }.contains {
            Calendar.current.isDateInToday($0.timestamp)
        }
    }
}

struct MessageSummary: Codable {
    let thread: MessageThread
    let summary: String
    let urgency: UrgencyLevel
    let suggestedResponse: String?
    let actionItems: [String]
    let sentiment: String
}

enum UrgencyLevel: String, Codable, Comparable {
    case critical
    case high
    case medium
    case low

    static func < (lhs: UrgencyLevel, rhs: UrgencyLevel) -> Bool {
        let order: [UrgencyLevel] = [.low, .medium, .high, .critical]
        guard let lhsIndex = order.firstIndex(of: lhs),
              let rhsIndex = order.firstIndex(of: rhs) else {
            return false
        }
        return lhsIndex < rhsIndex
    }
}
