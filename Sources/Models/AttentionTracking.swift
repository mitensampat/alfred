import Foundation

// MARK: - Attention Tracking Models

/// Tracks how time and attention are allocated across different activities
struct AttentionReport: Codable {
    let period: TimePeriod
    let calendar: CalendarAttention
    let messaging: MessagingAttention
    let overall: OverallAttention
    let recommendations: [AttentionRecommendation]
    let generatedAt: Date

    struct TimePeriod: Codable {
        let start: Date
        let end: Date
        let type: PeriodType

        enum PeriodType: String, Codable {
            case past
            case future
            case current
        }

        var description: String {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            return "\(formatter.string(from: start)) to \(formatter.string(from: end))"
        }
    }

    struct CalendarAttention: Codable {
        let totalMeetingTime: TimeInterval  // in seconds
        let meetingCount: Int
        let breakdown: [MeetingCategory: CategoryStats]
        let topTimeConsumers: [MeetingPattern]
        let utilizationScore: Double  // 0-100
        let wastedTimeEstimate: TimeInterval

        struct CategoryStats: Codable {
            let category: MeetingCategory
            var timeSpent: TimeInterval
            var meetingCount: Int
            var percentage: Double
            var averageMeetingDuration: TimeInterval
        }

        struct MeetingPattern: Codable {
            let pattern: String  // e.g., "Weekly sync with Team X"
            let occurrences: Int
            let totalTime: TimeInterval
            let averageAttendees: Int
            let isExternal: Bool
        }
    }

    struct MessagingAttention: Codable {
        let totalThreads: Int
        let responsesGiven: Int
        let averageResponseTime: TimeInterval?
        let breakdown: [MessageCategory: CategoryStats]
        let topTimeConsumers: [ThreadPattern]
        let utilizationScore: Double  // 0-100

        struct CategoryStats: Codable {
            let category: MessageCategory
            var threadCount: Int
            var messageCount: Int
            var percentage: Double
            var needsResponseCount: Int
        }

        struct ThreadPattern: Codable {
            let contact: String
            let messageCount: Int
            let platform: String
            let isGroup: Bool
            let averageMessagesPerDay: Double
        }
    }

    struct OverallAttention: Codable {
        let focusScore: Double  // 0-100: how well attention aligns with priorities
        let balanceScore: Double  // 0-100: how balanced time allocation is
        let efficiencyScore: Double  // 0-100: how efficiently time is used
        let alignmentWithGoals: Double  // 0-100: alignment with user's stated priorities
        let summary: String
    }

    struct AttentionRecommendation: Codable {
        let type: RecommendationType
        let priority: Priority
        let title: String
        let description: String
        let impact: Impact
        let actionable: Bool
        let suggestedAction: String?

        enum RecommendationType: String, Codable {
            case reduceMeetings
            case delegateResponsibility
            case blockFocusTime
            case reduceMessageLoad
            case rebalanceAttention
            case setMeetingLimit
            case improveResponseTime
        }

        enum Priority: String, Codable {
            case critical
            case high
            case medium
            case low
        }

        struct Impact: Codable {
            let timeRecovered: TimeInterval?
            let focusImprovement: Double?  // 0-100
            let description: String
        }
    }
}

/// Categories for meetings based on their value and importance
enum MeetingCategory: String, Codable, CaseIterable {
    case strategic = "Strategic"  // High-value, long-term impact
    case tactical = "Tactical"  // Important for execution
    case collaborative = "Collaborative"  // Team coordination
    case informational = "Informational"  // Status updates, FYIs
    case ceremonial = "Ceremonial"  // Could be async
    case waste = "Potential Waste"  // Low value
    case uncategorized = "Uncategorized"

    var priority: Int {
        switch self {
        case .strategic: return 1
        case .tactical: return 2
        case .collaborative: return 3
        case .informational: return 4
        case .ceremonial: return 5
        case .waste: return 6
        case .uncategorized: return 7
        }
    }
}

/// Categories for messages based on their importance
enum MessageCategory: String, Codable, CaseIterable {
    case urgent = "Urgent"
    case important = "Important"
    case routine = "Routine"
    case social = "Social"
    case noise = "Noise"
    case uncategorized = "Uncategorized"
}

/// User's attention preferences and priorities
struct AttentionPreferences: Codable {
    let version: String
    let lastUpdated: Date

    // User's stated priorities
    let priorities: [Priority]

    // Meeting preferences
    let meetingPreferences: MeetingPreferences

    // Messaging preferences
    let messagingPreferences: MessagingPreferences

    // Time allocation goals
    let timeAllocation: TimeAllocationGoals

    // Query defaults for attention reports
    let queryDefaults: QueryDefaults?

    struct Priority: Codable {
        let id: String
        let description: String
        let weight: Double  // 0-1.0
        let keywords: [String]
        let timeAllocation: Double  // Percentage of time (0-100)

        enum CodingKeys: String, CodingKey {
            case id
            case description
            case weight
            case keywords
            case timeAllocation = "time_allocation"
        }
    }

    struct MeetingPreferences: Codable {
        // Patterns to prioritize
        let highValue: [String]  // Keywords or patterns for valuable meetings
        let lowValue: [String]  // Keywords for meetings to minimize

        // Meeting limits
        let maxMeetingsPerDay: Int?
        let maxMeetingsPerWeek: Int?
        let maxHoursPerDay: Double?
        let maxHoursPerWeek: Double?

        // Categorization feedback
        let categoryOverrides: [String: MeetingCategory]  // Meeting title/pattern -> category

        // Focus time
        let minimumFocusBlockHours: Double  // Minimum contiguous focus time desired
        let preferredFocusTimeSlots: [String]  // e.g., ["9am-12pm", "2pm-5pm"]

        enum CodingKeys: String, CodingKey {
            case highValue = "high_value"
            case lowValue = "low_value"
            case maxMeetingsPerDay = "max_meetings_per_day"
            case maxMeetingsPerWeek = "max_meetings_per_week"
            case maxHoursPerDay = "max_hours_per_day"
            case maxHoursPerWeek = "max_hours_per_week"
            case categoryOverrides = "category_overrides"
            case minimumFocusBlockHours = "minimum_focus_block_hours"
            case preferredFocusTimeSlots = "preferred_focus_time_slots"
        }
    }

    struct MessagingPreferences: Codable {
        // Response priorities
        let highPriorityContacts: [String]
        let lowPriorityContacts: [String]

        // Response time goals
        let targetResponseTimeUrgent: TimeInterval  // seconds
        let targetResponseTimeImportant: TimeInterval
        let targetResponseTimeRoutine: TimeInterval

        // Noise reduction
        let autoDeclinePatterns: [String]  // Message patterns to deprioritize

        enum CodingKeys: String, CodingKey {
            case highPriorityContacts = "high_priority_contacts"
            case lowPriorityContacts = "low_priority_contacts"
            case targetResponseTimeUrgent = "target_response_time_urgent"
            case targetResponseTimeImportant = "target_response_time_important"
            case targetResponseTimeRoutine = "target_response_time_routine"
            case autoDeclinePatterns = "auto_decline_patterns"
        }
    }

    struct TimeAllocationGoals: Codable {
        let period: String  // e.g., "weekly", "monthly"
        let goals: [AllocationGoal]

        struct AllocationGoal: Codable {
            let category: String  // e.g., "Strategic work", "Team collaboration"
            let targetPercentage: Double  // 0-100
            let currentPercentage: Double?  // Actual, if calculated
            let variance: Double?  // Difference from target

            enum CodingKeys: String, CodingKey {
                case category
                case targetPercentage = "target_percentage"
                case currentPercentage = "current_percentage"
                case variance
            }
        }
    }

    struct QueryDefaults: Codable {
        let defaultLookbackDays: Int  // Default days to look back for historical reports
        let defaultLookforwardDays: Int  // Default days to look forward for planning
        let weekStartDay: String  // e.g., "monday", "sunday"

        enum CodingKeys: String, CodingKey {
            case defaultLookbackDays = "default_lookback_days"
            case defaultLookforwardDays = "default_lookforward_days"
            case weekStartDay = "week_start_day"
        }
    }

    enum CodingKeys: String, CodingKey {
        case version
        case lastUpdated = "last_updated"
        case priorities
        case meetingPreferences = "meeting_preferences"
        case messagingPreferences = "messaging_preferences"
        case timeAllocation = "time_allocation"
        case queryDefaults = "query_defaults"
    }
}

/// Request for future attention planning
struct AttentionPlanRequest: Codable {
    let period: TimePeriod
    let priorities: [String]  // What user wants to focus on
    let constraints: [Constraint]
    let goals: [Goal]

    struct TimePeriod: Codable {
        let start: Date
        let end: Date
        let description: String  // e.g., "next 2 weeks", "Q1 2026"
    }

    struct Constraint: Codable {
        let type: ConstraintType
        let description: String
        let value: Double?

        enum ConstraintType: String, Codable {
            case maxMeetingHours
            case maxMeetingsPerDay
            case requiredFocusTime
            case noMeetingDays
            case blockTimeSlots
        }
    }

    struct Goal: Codable {
        let description: String
        let category: String
        let targetHours: Double?
        let priority: Int  // 1-5
    }
}

/// Response to attention planning request
struct AttentionPlan: Codable {
    let request: AttentionPlanRequest
    let currentCommitments: [Commitment]
    let recommendations: [PlanRecommendation]
    let projectedAttention: AttentionReport.OverallAttention
    let conflicts: [Conflict]

    struct Commitment: Codable {
        let title: String
        let date: Date
        let duration: TimeInterval
        let category: MeetingCategory
        let canReschedule: Bool
        let priority: Int
    }

    struct PlanRecommendation: Codable {
        let action: ActionType
        let title: String
        let description: String
        let impact: String
        let effort: String

        enum ActionType: String, Codable {
            case declineMeeting
            case rescheduleMeeting
            case blockFocusTime
            case delegateTask
            case reduceMeetingFrequency
            case consolidateMeetings
        }
    }

    struct Conflict: Codable {
        let description: String
        let severity: Severity
        let affectedGoal: String
        let suggestedResolution: String

        enum Severity: String, Codable {
            case critical
            case high
            case medium
            case low
        }
    }
}

// MARK: - Attention Tracker Query

/// Query parameters for attention analysis
struct AttentionQuery: Codable {
    let scope: Scope
    let period: Period
    let includeCalendar: Bool
    let includeMessaging: Bool
    let compareWithGoals: Bool

    enum Scope: String, Codable {
        case calendar = "calendar"
        case messaging = "messaging"
        case both = "both"
    }

    struct Period: Codable {
        let start: Date
        let end: Date
        let type: PeriodType

        enum PeriodType: String, Codable {
            case day
            case week
            case month
            case quarter
            case custom
        }

        static func today() -> Period {
            let now = Date()
            let calendar = Calendar.current
            let start = calendar.startOfDay(for: now)
            let end = calendar.date(byAdding: .day, value: 1, to: start)!
            return Period(start: start, end: end, type: .day)
        }

        static func thisWeek() -> Period {
            let now = Date()
            let calendar = Calendar.current
            let start = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
            let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start)!
            return Period(start: start, end: end, type: .week)
        }

        static func lastWeek() -> Period {
            let now = Date()
            let calendar = Calendar.current
            let thisWeekStart = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
            let start = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeekStart)!
            let end = thisWeekStart
            return Period(start: start, end: end, type: .week)
        }

        static func nextWeek() -> Period {
            let now = Date()
            let calendar = Calendar.current
            let thisWeekStart = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
            let start = calendar.date(byAdding: .weekOfYear, value: 1, to: thisWeekStart)!
            let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start)!
            return Period(start: start, end: end, type: .week)
        }

        // Custom lookback period in days
        static func lastNDays(_ days: Int) -> Period {
            let now = Date()
            let calendar = Calendar.current
            let end = calendar.startOfDay(for: now)
            let start = calendar.date(byAdding: .day, value: -days, to: end)!
            return Period(start: start, end: end, type: .custom)
        }

        // Custom lookforward period in days
        static func nextNDays(_ days: Int) -> Period {
            let now = Date()
            let calendar = Calendar.current
            let start = calendar.startOfDay(for: now)
            let end = calendar.date(byAdding: .day, value: days, to: start)!
            return Period(start: start, end: end, type: .custom)
        }
    }
}
