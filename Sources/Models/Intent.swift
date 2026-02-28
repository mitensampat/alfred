import Foundation

// MARK: - User Intent Models

/// Represents a parsed user intent with extracted parameters
struct UserIntent: Codable {
    let action: Action
    let target: Target?  // Optional to handle ambiguous queries
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

    /// Custom decoder that handles Claude's sometimes-imperfect JSON:
    /// - Missing confidence defaults to 0.9
    /// - Missing original_query defaults to empty string
    /// - Missing filters defaults to empty filters
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.action = try container.decode(Action.self, forKey: .action)
        self.target = try container.decodeIfPresent(Target.self, forKey: .target)
        self.filters = (try? container.decode(IntentFilters.self, forKey: .filters)) ?? IntentFilters()
        self.confidence = (try? container.decode(Double.self, forKey: .confidence)) ?? 0.9
        self.originalQuery = (try? container.decode(String.self, forKey: .originalQuery)) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(action, forKey: .action)
        try container.encodeIfPresent(target, forKey: .target)
        try container.encode(filters, forKey: .filters)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(originalQuery, forKey: .originalQuery)
    }

    /// Manual init for programmatic construction
    init(action: Action, target: Target?, filters: IntentFilters, confidence: Double, originalQuery: String) {
        self.action = action
        self.target = target
        self.filters = filters
        self.confidence = confidence
        self.originalQuery = originalQuery
    }

    enum Action: String, Codable {
        case generate = "generate"      // Generate briefing, report, draft
        case scan = "scan"              // Scan for commitments, todos
        case analyze = "analyze"        // Analyze messages, calendar
        case find = "find"              // Find specific items
        case summarize = "summarize"    // Summarize threads, meetings
        case check = "check"            // Attention check, overdue items
        case list = "list"              // List commitments, drafts
        case update = "update"          // Update task, commitment status
        case create = "create"          // Create new task, commitment
        case delete = "delete"          // Delete/cancel item
        case search = "search"          // Search across all data
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
        case tasks = "tasks"            // Unified tasks (todos + commitments)
        case contacts = "contacts"      // People/contacts
        case preferences = "preferences" // User preferences/settings
    }

    struct IntentFilters: Codable {
        // Contact/person filters
        let contactName: String?

        // Time filters
        let dateRange: DateRange?
        let specificDate: Date?
        let dateDescription: String?  // Human-readable date context (e.g., "Monday", "next week")

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

        // Task update filters (used when action is "update" and target is "tasks")
        let taskSearchTerm: String?    // fuzzy task name keywords ("RCA", "dentist appointment")
        let newStatus: String?         // "Done", "In Progress", "Not Started", "Blocked", "Cancelled"
        let newPriority: String?       // "Critical", "High", "Medium", "Low"
        let newDueDate: Date?          // new due date for the task
        let noteToAdd: String?         // text to append to Description

        // Calendar event creation filters (used when action is "create" and target is "calendar")
        let eventTitle: String?           // "Meeting with Mona about finance"
        let eventTime: String?            // ISO8601 datetime computed from natural language
        let eventDurationMinutes: Int?    // 30 (default)
        let eventLocation: String?        // "Home", "Office", etc.
        let eventAttendees: [String]?     // ["Mona", "Nikhil"] — contact names
        let eventDescription: String?     // topic/agenda

        enum CodingKeys: String, CodingKey {
            case contactName = "contact_name"
            case dateRange = "date_range"
            case specificDate = "specific_date"
            case dateDescription = "date_description"
            case platform
            case commitmentType = "commitment_type"
            case urgency
            case lookbackDays = "lookback_days"
            case lookforwardDays = "lookforward_days"
            case calendarName = "calendar_name"
            case taskSearchTerm = "task_search_term"
            case newStatus = "new_status"
            case newPriority = "new_priority"
            case newDueDate = "new_due_date"
            case noteToAdd = "note_to_add"
            case eventTitle = "event_title"
            case eventTime = "event_time"
            case eventDurationMinutes = "event_duration_minutes"
            case eventLocation = "event_location"
            case eventAttendees = "event_attendees"
            case eventDescription = "event_description"
        }

        struct DateRange: Codable {
            let start: Date
            let end: Date

            init(start: Date, end: Date) {
                self.start = start
                self.end = end
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.start = try DateRange.decodeFlexibleDate(from: container, key: .start)
                self.end = try DateRange.decodeFlexibleDate(from: container, key: .end)
            }

            private enum CodingKeys: String, CodingKey {
                case start, end
            }

            private static func decodeFlexibleDate(from container: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) throws -> Date {
                let dateString = try container.decode(String.self, forKey: key)
                return IntentFilters.parseFlexibleDate(dateString) ?? Date()
            }
        }

        enum CommitmentType: String, Codable {
            case iOwe = "i_owe"
            case theyOwe = "they_owe"
            case all = "all"
        }

        /// Custom decoder that handles Claude's flexible JSON output:
        /// - Date strings in various formats (ISO8601, date-only, etc.)
        /// - Null values for optional enum fields
        /// - Missing keys gracefully defaulting to nil
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)

            contactName = try container.decodeIfPresent(String.self, forKey: .contactName)
            dateDescription = try container.decodeIfPresent(String.self, forKey: .dateDescription)
            lookbackDays = try container.decodeIfPresent(Int.self, forKey: .lookbackDays)
            lookforwardDays = try container.decodeIfPresent(Int.self, forKey: .lookforwardDays)
            calendarName = try container.decodeIfPresent(String.self, forKey: .calendarName)

            // Decode specificDate from flexible date string
            if let dateString = try container.decodeIfPresent(String.self, forKey: .specificDate) {
                specificDate = IntentFilters.parseFlexibleDate(dateString)
            } else {
                specificDate = nil
            }

            // Decode dateRange with flexible date parsing
            dateRange = try container.decodeIfPresent(DateRange.self, forKey: .dateRange)

            // Decode optional enums safely (Claude may send null or invalid values)
            platform = try? container.decodeIfPresent(MessagePlatform.self, forKey: .platform)
            commitmentType = try? container.decodeIfPresent(CommitmentType.self, forKey: .commitmentType)
            urgency = try? container.decodeIfPresent(UrgencyLevel.self, forKey: .urgency)

            // Task update fields
            taskSearchTerm = try container.decodeIfPresent(String.self, forKey: .taskSearchTerm)
            newStatus = try container.decodeIfPresent(String.self, forKey: .newStatus)
            newPriority = try container.decodeIfPresent(String.self, forKey: .newPriority)
            noteToAdd = try container.decodeIfPresent(String.self, forKey: .noteToAdd)

            // Decode newDueDate from flexible date string
            if let dateString = try container.decodeIfPresent(String.self, forKey: .newDueDate) {
                newDueDate = IntentFilters.parseFlexibleDate(dateString)
            } else {
                newDueDate = nil
            }

            // Calendar event creation fields
            eventTitle = try container.decodeIfPresent(String.self, forKey: .eventTitle)
            eventTime = try container.decodeIfPresent(String.self, forKey: .eventTime)
            eventDurationMinutes = try container.decodeIfPresent(Int.self, forKey: .eventDurationMinutes)
            eventLocation = try container.decodeIfPresent(String.self, forKey: .eventLocation)
            eventAttendees = try container.decodeIfPresent([String].self, forKey: .eventAttendees)
            eventDescription = try container.decodeIfPresent(String.self, forKey: .eventDescription)
        }

        /// Parse date strings in multiple formats that Claude might produce
        static func parseFlexibleDate(_ string: String) -> Date? {
            // Try ISO8601 with time first
            let iso8601Full = ISO8601DateFormatter()
            iso8601Full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso8601Full.date(from: string) { return d }

            let iso8601 = ISO8601DateFormatter()
            iso8601.formatOptions = [.withInternetDateTime]
            if let d = iso8601.date(from: string) { return d }

            // Try date-only format (YYYY-MM-DD)
            let dateOnly = DateFormatter()
            dateOnly.dateFormat = "yyyy-MM-dd"
            dateOnly.timeZone = TimeZone.current
            if let d = dateOnly.date(from: string) { return d }

            // Try natural date formats
            let natural = DateFormatter()
            natural.dateFormat = "MMMM d, yyyy"
            if let d = natural.date(from: string) { return d }

            natural.dateFormat = "MMM d, yyyy"
            if let d = natural.date(from: string) { return d }

            return nil
        }

        /// Default empty init (all nil)
        init() {
            self.contactName = nil
            self.dateRange = nil
            self.specificDate = nil
            self.dateDescription = nil
            self.platform = nil
            self.commitmentType = nil
            self.urgency = nil
            self.lookbackDays = nil
            self.lookforwardDays = nil
            self.calendarName = nil
            self.taskSearchTerm = nil
            self.newStatus = nil
            self.newPriority = nil
            self.newDueDate = nil
            self.noteToAdd = nil
            self.eventTitle = nil
            self.eventTime = nil
            self.eventDurationMinutes = nil
            self.eventLocation = nil
            self.eventAttendees = nil
            self.eventDescription = nil
        }

        // Manual init for programmatic construction
        init(
            contactName: String? = nil,
            dateRange: DateRange? = nil,
            specificDate: Date? = nil,
            dateDescription: String? = nil,
            platform: MessagePlatform? = nil,
            commitmentType: CommitmentType? = nil,
            urgency: UrgencyLevel? = nil,
            lookbackDays: Int? = nil,
            lookforwardDays: Int? = nil,
            calendarName: String? = nil,
            taskSearchTerm: String? = nil,
            newStatus: String? = nil,
            newPriority: String? = nil,
            newDueDate: Date? = nil,
            noteToAdd: String? = nil,
            eventTitle: String? = nil,
            eventTime: String? = nil,
            eventDurationMinutes: Int? = nil,
            eventLocation: String? = nil,
            eventAttendees: [String]? = nil,
            eventDescription: String? = nil
        ) {
            self.contactName = contactName
            self.dateRange = dateRange
            self.specificDate = specificDate
            self.dateDescription = dateDescription
            self.platform = platform
            self.commitmentType = commitmentType
            self.urgency = urgency
            self.lookbackDays = lookbackDays
            self.lookforwardDays = lookforwardDays
            self.calendarName = calendarName
            self.taskSearchTerm = taskSearchTerm
            self.newStatus = newStatus
            self.newPriority = newPriority
            self.newDueDate = newDueDate
            self.noteToAdd = noteToAdd
            self.eventTitle = eventTitle
            self.eventTime = eventTime
            self.eventDurationMinutes = eventDurationMinutes
            self.eventLocation = eventLocation
            self.eventAttendees = eventAttendees
            self.eventDescription = eventDescription
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

    /// Custom decoder: clarification fields default to false/nil if missing
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.intent = try container.decode(UserIntent.self, forKey: .intent)
        self.clarificationNeeded = (try? container.decode(Bool.self, forKey: .clarificationNeeded)) ?? false
        self.clarificationQuestion = try? container.decodeIfPresent(String.self, forKey: .clarificationQuestion)
        self.suggestedFollowUps = try? container.decodeIfPresent([String].self, forKey: .suggestedFollowUps)
    }
}
