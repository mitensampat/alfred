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
        case chat = "chat"              // Conversational, no structured action needed
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
        case reflections = "reflections" // Reflection themes, open questions
        case memory = "memory"          // Learned patterns, teach/forget rules
        case favorites = "favorites"    // Favorite contacts/groups
        case focus = "focus"            // Focus pin (top goal)
        case cadences = "cadences"      // Scheduled cadences
        case conversations = "conversations" // Past chat conversations
        case skills = "skills"          // Coaching skills
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

        // Task creation filters (used when action is "create" and target is "tasks"/"todos")
        let taskTitle: String?            // title for new task (distinct from taskSearchTerm which is for search)
        let taskType: String?             // "Todo", "Commitment", "Follow-up"

        // Commitment creation filters (used when action is "create" and target is "commitments")
        let commitmentDirection: String?  // "i_owe" or "they_owe"
        let commitmentCounterparty: String? // person name (e.g., "Nikhil")

        // Calendar event search/update filters
        let eventSearchTerm: String?      // fuzzy search for existing events ("3pm", "standup", "Nikhil")

        // Calendar event creation filters (used when action is "create" and target is "calendar")
        let eventTitle: String?           // "Meeting with Mona about finance"
        let eventTime: String?            // ISO8601 datetime computed from natural language
        let eventDurationMinutes: Int?    // 30 (default)
        let eventLocation: String?        // "Home", "Office", etc.
        let eventAttendees: [String]?     // ["Mona", "Nikhil"] — contact names
        let eventAttendeeEmails: [String]? // ["alice@example.com"] — extracted email addresses
        let eventDescription: String?     // topic/agenda

        // Memory/learning filters
        let teachText: String?            // rule text for "teach" action
        // Reflection filters
        let themeName: String?            // theme name for deep-dive
        // Cadence filters
        let cadenceName: String?          // cadence name to trigger

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
            case taskTitle = "task_title"
            case taskType = "task_type"
            case commitmentDirection = "commitment_direction"
            case commitmentCounterparty = "commitment_counterparty"
            case eventSearchTerm = "event_search_term"
            case eventTitle = "event_title"
            case eventTime = "event_time"
            case eventDurationMinutes = "event_duration_minutes"
            case eventLocation = "event_location"
            case eventAttendees = "event_attendees"
            case eventAttendeeEmails = "event_attendee_emails"
            case eventDescription = "event_description"
            case teachText = "teach_text"
            case themeName = "theme_name"
            case cadenceName = "cadence_name"
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

            // Task creation fields
            taskTitle = try container.decodeIfPresent(String.self, forKey: .taskTitle)
            taskType = try container.decodeIfPresent(String.self, forKey: .taskType)

            // Decode newDueDate from flexible date string
            if let dateString = try container.decodeIfPresent(String.self, forKey: .newDueDate) {
                newDueDate = IntentFilters.parseFlexibleDate(dateString)
            } else {
                newDueDate = nil
            }

            // Commitment creation fields
            commitmentDirection = try container.decodeIfPresent(String.self, forKey: .commitmentDirection)
            commitmentCounterparty = try container.decodeIfPresent(String.self, forKey: .commitmentCounterparty)

            // Calendar event search/update fields
            eventSearchTerm = try container.decodeIfPresent(String.self, forKey: .eventSearchTerm)

            // Calendar event creation fields
            eventTitle = try container.decodeIfPresent(String.self, forKey: .eventTitle)
            eventTime = try container.decodeIfPresent(String.self, forKey: .eventTime)
            eventDurationMinutes = try container.decodeIfPresent(Int.self, forKey: .eventDurationMinutes)
            eventLocation = try container.decodeIfPresent(String.self, forKey: .eventLocation)
            eventAttendees = try container.decodeIfPresent([String].self, forKey: .eventAttendees)
            eventAttendeeEmails = try container.decodeIfPresent([String].self, forKey: .eventAttendeeEmails)
            eventDescription = try container.decodeIfPresent(String.self, forKey: .eventDescription)

            // Memory/reflection/cadence fields
            teachText = try container.decodeIfPresent(String.self, forKey: .teachText)
            themeName = try container.decodeIfPresent(String.self, forKey: .themeName)
            cadenceName = try container.decodeIfPresent(String.self, forKey: .cadenceName)
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
            self.taskTitle = nil
            self.taskType = nil
            self.commitmentDirection = nil
            self.commitmentCounterparty = nil
            self.eventSearchTerm = nil
            self.eventTitle = nil
            self.eventTime = nil
            self.eventDurationMinutes = nil
            self.eventLocation = nil
            self.eventAttendees = nil
            self.eventAttendeeEmails = nil
            self.eventDescription = nil
            self.teachText = nil
            self.themeName = nil
            self.cadenceName = nil
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
            taskTitle: String? = nil,
            taskType: String? = nil,
            commitmentDirection: String? = nil,
            commitmentCounterparty: String? = nil,
            eventSearchTerm: String? = nil,
            eventTitle: String? = nil,
            eventTime: String? = nil,
            eventDurationMinutes: Int? = nil,
            eventLocation: String? = nil,
            eventAttendees: [String]? = nil,
            eventAttendeeEmails: [String]? = nil,
            eventDescription: String? = nil,
            teachText: String? = nil,
            themeName: String? = nil,
            cadenceName: String? = nil
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
            self.taskTitle = taskTitle
            self.taskType = taskType
            self.commitmentDirection = commitmentDirection
            self.commitmentCounterparty = commitmentCounterparty
            self.eventSearchTerm = eventSearchTerm
            self.eventTitle = eventTitle
            self.eventTime = eventTime
            self.eventDurationMinutes = eventDurationMinutes
            self.eventLocation = eventLocation
            self.eventAttendees = eventAttendees
            self.eventAttendeeEmails = eventAttendeeEmails
            self.eventDescription = eventDescription
            self.teachText = teachText
            self.themeName = themeName
            self.cadenceName = cadenceName
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
