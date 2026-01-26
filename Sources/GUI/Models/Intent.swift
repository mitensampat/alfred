import Foundation

// MARK: - User Intent Models

/// Represents a parsed user intent with extracted parameters
struct UserIntent: Codable {
    let action: Action
    let target: Target
    let filters: IntentFilters
    let confidence: Double  // 0-1.0
    let originalQuery: String

    enum CodingKeys: String, CodingKey {
        case action
        case target
        case filters
        case confidence
        case originalQuery = "original_query"
    }

    enum Action: String, Codable {
        case generate = "generate"      // Generate briefing, report, draft
        case scan = "scan"              // Scan for commitments, todos
        case analyze = "analyze"        // Analyze messages, calendar
        case find = "find"              // Find specific items
        case summarize = "summarize"    // Summarize threads, meetings
        case check = "check"            // Attention check, overdue items
        case list = "list"              // List commitments, drafts
    }

    enum Target: String, Codable {
        case briefing = "briefing"
        case calendar = "calendar"
        case messages = "messages"
        case commitments = "commitments"
        case todos = "todos"
        case drafts = "drafts"
        case attention = "attention"
        case thread = "thread"          // Specific message thread
        case meeting = "meeting"        // Specific meeting
    }

    struct IntentFilters: Codable {
        // Contact/person filters
        let contactName: String?

        // Time filters
        let dateRange: DateRange?
        let specificDate: Date?

        // Platform filters
        let platform: MessagePlatform?

        // Commitment filters
        let commitmentType: CommitmentType?

        // Priority/urgency filters
        let urgency: UrgencyLevel?

        // Lookback/lookforward
        let lookbackDays: Int?
        let lookforwardDays: Int?

        // Calendar filters
        let calendarName: String?

        enum CodingKeys: String, CodingKey {
            case contactName = "contact_name"
            case dateRange = "date_range"
            case specificDate = "specific_date"
            case platform
            case commitmentType = "commitment_type"
            case urgency
            case lookbackDays = "lookback_days"
            case lookforwardDays = "lookforward_days"
            case calendarName = "calendar_name"
        }

        struct DateRange: Codable {
            let start: Date
            let end: Date
        }

        enum CommitmentType: String, Codable {
            case iOwe = "i_owe"
            case theyOwe = "they_owe"
            case all = "all"
        }
    }
}

// MARK: - Intent Recognition Response

/// Response from Claude API for intent recognition
struct IntentRecognitionResponse: Codable {
    let intent: UserIntent
    let clarificationNeeded: Bool
    let clarificationQuestion: String?
    let suggestedFollowUps: [String]?

    enum CodingKeys: String, CodingKey {
        case intent
        case clarificationNeeded = "clarification_needed"
        case clarificationQuestion = "clarification_question"
        case suggestedFollowUps = "suggested_follow_ups"
    }
}
