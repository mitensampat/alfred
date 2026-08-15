import Foundation

// MARK: - Cadence Action Type

/// Every tool Alfred can run as a scheduled cadence
enum CadenceActionType: String, Codable, CaseIterable {
    case morningBriefing = "morning_briefing"
    case attentionCheck = "attention_check"
    case todoScan = "todo_scan"
    case commitmentScan = "commitment_scan"
    case patternLearning = "pattern_learning"
    case groupAnalysis = "group_analysis"
    case autoSummary = "auto_summary"
    case weeklyReview = "weekly_review"
    case messageSummary = "message_summary"
    case playbookSync = "playbook_sync"
    case coachingSync = "coaching_sync"
    case taskLifecycleScan = "task_lifecycle_scan"
    case reflectionIngestion = "reflection_ingestion"
    case themeConvergence = "theme_convergence"
    case notionSync = "notion_sync"
}

// MARK: - Cadence Schedule

/// When a cadence runs
enum CadenceSchedule: Codable, Equatable {
    case daily(time: String)                                      // "HH:mm"
    case weekly(day: String, time: String)                        // ("monday", "17:00")
    case interval(hours: Int, activeStart: Int, activeEnd: Int)   // every N hours within window

    // Manual Codable with "type" discriminator
    enum CodingKeys: String, CodingKey {
        case type, time, day, hours, activeStart = "active_start", activeEnd = "active_end"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "daily":
            let time = try container.decode(String.self, forKey: .time)
            self = .daily(time: time)
        case "weekly":
            let day = try container.decode(String.self, forKey: .day)
            let time = try container.decode(String.self, forKey: .time)
            self = .weekly(day: day, time: time)
        case "interval":
            let hours = try container.decode(Int.self, forKey: .hours)
            let activeStart = try container.decodeIfPresent(Int.self, forKey: .activeStart) ?? 0
            let activeEnd = try container.decodeIfPresent(Int.self, forKey: .activeEnd) ?? 23
            self = .interval(hours: hours, activeStart: activeStart, activeEnd: activeEnd)
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: [CodingKeys.type], debugDescription: "Unknown schedule type: \(type)"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .daily(let time):
            try container.encode("daily", forKey: .type)
            try container.encode(time, forKey: .time)
        case .weekly(let day, let time):
            try container.encode("weekly", forKey: .type)
            try container.encode(day, forKey: .day)
            try container.encode(time, forKey: .time)
        case .interval(let hours, let activeStart, let activeEnd):
            try container.encode("interval", forKey: .type)
            try container.encode(hours, forKey: .hours)
            try container.encode(activeStart, forKey: .activeStart)
            try container.encode(activeEnd, forKey: .activeEnd)
        }
    }

    /// Human-readable schedule description
    var displayText: String {
        switch self {
        case .daily(let time):
            return "Daily @ \(time)"
        case .weekly(let day, let time):
            return "\(day.capitalized) @ \(time)"
        case .interval(let hours, let activeStart, let activeEnd):
            if activeStart == 0 && activeEnd == 23 {
                return "Every \(hours)h"
            }
            return "Every \(hours)h (\(activeStart):00-\(activeEnd):00)"
        }
    }
}

// MARK: - JSON Value (typed params)

/// Lightweight typed value for cadence parameters
enum JSONValue: Codable, Equatable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case stringArray([String])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let v = try? container.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? container.decode(Int.self) {
            self = .int(v)
        } else if let v = try? container.decode(String.self) {
            self = .string(v)
        } else if let v = try? container.decode([String].self) {
            self = .stringArray(v)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .stringArray(let v): try container.encode(v)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    var intValue: Int? {
        if case .int(let v) = self { return v }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    var stringArrayValue: [String]? {
        if case .stringArray(let v) = self { return v }
        return nil
    }

    /// Convert to Any for JSON serialization
    var anyValue: Any {
        switch self {
        case .string(let v): return v
        case .int(let v): return v
        case .bool(let v): return v
        case .stringArray(let v): return v
        case .null: return NSNull()
        }
    }
}

// MARK: - Cadence

/// A scheduled automation that runs an Alfred tool on a schedule
struct Cadence: Codable, Identifiable {
    let id: String
    var name: String
    var icon: String
    var actionType: CadenceActionType
    var params: [String: JSONValue]
    var schedule: CadenceSchedule
    var enabled: Bool
    var isBuiltIn: Bool
    var createdAt: Date
    var lastRunDate: String?               // "yyyy-MM-dd" for daily/weekly dedup (scheduled runs only)
    var lastRunTimestamp: String?           // ISO8601 for display (scheduled runs only)
    var lastManualRunTimestamp: String?     // ISO8601 for display (manual API runs — does NOT suppress scheduler)
    var failureCooldownUntil: Date?        // Don't retry until this time
    var lastRunSummary: String?            // Summary output from last run
    var lastRunStatus: String?             // "success" or "failure"
    var catchUpWindowHours: Int
    var weeklyCatchUpDays: Int             // How many days after the scheduled day to still catch up (default 2)
    var notifyOnSuccess: Bool
    var emailOnSuccess: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, icon
        case actionType = "action_type"
        case params, schedule, enabled
        case isBuiltIn = "is_built_in"
        case createdAt = "created_at"
        case lastRunDate = "last_run_date"
        case lastRunTimestamp = "last_run_timestamp"
        case lastManualRunTimestamp = "last_manual_run_timestamp"
        case failureCooldownUntil = "failure_cooldown_until"
        case lastRunSummary = "last_run_summary"
        case lastRunStatus = "last_run_status"
        case catchUpWindowHours = "catch_up_window_hours"
        case weeklyCatchUpDays = "weekly_catch_up_days"
        case notifyOnSuccess = "notify_on_success"
        case emailOnSuccess = "email_on_success"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        icon = try container.decode(String.self, forKey: .icon)
        actionType = try container.decode(CadenceActionType.self, forKey: .actionType)
        params = try container.decode([String: JSONValue].self, forKey: .params)
        schedule = try container.decode(CadenceSchedule.self, forKey: .schedule)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        isBuiltIn = try container.decode(Bool.self, forKey: .isBuiltIn)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastRunDate = try container.decodeIfPresent(String.self, forKey: .lastRunDate)
        lastRunTimestamp = try container.decodeIfPresent(String.self, forKey: .lastRunTimestamp)
        lastManualRunTimestamp = try container.decodeIfPresent(String.self, forKey: .lastManualRunTimestamp)
        failureCooldownUntil = try container.decodeIfPresent(Date.self, forKey: .failureCooldownUntil)
        lastRunSummary = try container.decodeIfPresent(String.self, forKey: .lastRunSummary)
        lastRunStatus = try container.decodeIfPresent(String.self, forKey: .lastRunStatus)
        catchUpWindowHours = try container.decodeIfPresent(Int.self, forKey: .catchUpWindowHours) ?? 3
        weeklyCatchUpDays = try container.decodeIfPresent(Int.self, forKey: .weeklyCatchUpDays) ?? 2
        notifyOnSuccess = try container.decode(Bool.self, forKey: .notifyOnSuccess)
        emailOnSuccess = try container.decode(Bool.self, forKey: .emailOnSuccess)
    }

    init(id: String, name: String, icon: String, actionType: CadenceActionType,
         params: [String: JSONValue] = [:], schedule: CadenceSchedule,
         enabled: Bool = true, isBuiltIn: Bool = false,
         createdAt: Date = Date(), lastRunDate: String? = nil,
         lastRunTimestamp: String? = nil, lastManualRunTimestamp: String? = nil,
         failureCooldownUntil: Date? = nil,
         lastRunSummary: String? = nil, lastRunStatus: String? = nil,
         catchUpWindowHours: Int = 3, weeklyCatchUpDays: Int = 2,
         notifyOnSuccess: Bool = true,
         emailOnSuccess: Bool = false) {
        self.id = id
        self.name = name
        self.icon = icon
        self.actionType = actionType
        self.params = params
        self.schedule = schedule
        self.enabled = enabled
        self.isBuiltIn = isBuiltIn
        self.createdAt = createdAt
        self.lastRunDate = lastRunDate
        self.lastRunTimestamp = lastRunTimestamp
        self.lastManualRunTimestamp = lastManualRunTimestamp
        self.failureCooldownUntil = failureCooldownUntil
        self.lastRunSummary = lastRunSummary
        self.lastRunStatus = lastRunStatus
        self.catchUpWindowHours = catchUpWindowHours
        self.weeklyCatchUpDays = weeklyCatchUpDays
        self.notifyOnSuccess = notifyOnSuccess
        self.emailOnSuccess = emailOnSuccess
    }

    /// Serialize to [String: Any] for JSON API responses
    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "id": id,
            "name": name,
            "icon": icon,
            "action_type": actionType.rawValue,
            "params": params.mapValues { $0.anyValue },
            "enabled": enabled,
            "is_built_in": isBuiltIn,
            "created_at": ISO8601DateFormatter().string(from: createdAt),
            "catch_up_window_hours": catchUpWindowHours,
            "notify_on_success": notifyOnSuccess,
            "email_on_success": emailOnSuccess
        ]

        // Schedule
        switch schedule {
        case .daily(let time):
            dict["schedule"] = ["type": "daily", "time": time]
        case .weekly(let day, let time):
            dict["schedule"] = ["type": "weekly", "day": day, "time": time]
        case .interval(let hours, let activeStart, let activeEnd):
            dict["schedule"] = ["type": "interval", "hours": hours, "active_start": activeStart, "active_end": activeEnd] as [String: Any]
        }

        dict["schedule_display"] = schedule.displayText
        dict["last_run_date"] = lastRunDate ?? NSNull()
        dict["last_run_timestamp"] = lastRunTimestamp ?? NSNull()
        dict["last_manual_run_timestamp"] = lastManualRunTimestamp ?? NSNull()
        dict["last_run_summary"] = lastRunSummary ?? NSNull()
        dict["last_run_status"] = lastRunStatus ?? NSNull()
        dict["failure_cooldown_until"] = failureCooldownUntil.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull()
        dict["weekly_catch_up_days"] = weeklyCatchUpDays

        return dict
    }
}

// MARK: - Tool Catalog

/// Parameter type for tool configuration UI
enum ToolParamType: String {
    case string
    case int
    case stringArray = "string_array"
    case select
}

/// Defines a parameter that a tool accepts
struct ToolParamDefinition {
    let key: String
    let label: String
    let type: ToolParamType
    let required: Bool
    let defaultValue: JSONValue?
    let options: [String]?   // for .select type

    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "key": key,
            "label": label,
            "type": type.rawValue,
            "required": required
        ]
        if let dv = defaultValue { dict["default_value"] = dv.anyValue }
        if let opts = options { dict["options"] = opts }
        return dict
    }
}

/// Tool category for grouping in the UI
enum ToolCategory: String, CaseIterable {
    case communication = "Communication"
    case analysis = "Analysis"
    case sync = "Sync"
    case review = "Review"
}

/// A tool entry in the catalog (static metadata for UI)
struct ToolCatalogEntry {
    let actionType: CadenceActionType
    let label: String
    let icon: String
    let description: String
    let category: ToolCategory
    let params: [ToolParamDefinition]
    let defaultSchedule: CadenceSchedule

    func toDictionary() -> [String: Any] {
        var scheduleDict: [String: Any] = [:]
        switch defaultSchedule {
        case .daily(let time):
            scheduleDict = ["type": "daily", "time": time]
        case .weekly(let day, let time):
            scheduleDict = ["type": "weekly", "day": day, "time": time]
        case .interval(let hours, let activeStart, let activeEnd):
            scheduleDict = ["type": "interval", "hours": hours, "active_start": activeStart, "active_end": activeEnd]
        }

        return [
            "action_type": actionType.rawValue,
            "label": label,
            "icon": icon,
            "description": description,
            "category": category.rawValue,
            "params": params.map { $0.toDictionary() },
            "default_schedule": scheduleDict
        ]
    }
}

// MARK: - Static Tool Catalog

extension CadenceActionType {
    /// The complete catalog of available tools
    static var catalog: [ToolCatalogEntry] {
        [
            ToolCatalogEntry(
                actionType: .morningBriefing,
                label: "Morning Briefing",
                icon: "☀️",
                description: "Generate and email the daily briefing (calendar, messages, commitments)",
                category: .review,
                params: [],
                defaultSchedule: .daily(time: "08:15")
            ),
            ToolCatalogEntry(
                actionType: .attentionCheck,
                label: "Attention Check",
                icon: "🎯",
                description: "Generate attention defense alert — what needs focus today",
                category: .review,
                params: [],
                defaultSchedule: .daily(time: "15:00")
            ),
            ToolCatalogEntry(
                actionType: .todoScan,
                label: "Todo Scan",
                icon: "📝",
                description: "Scan WhatsApp messages for action items and save to Notion",
                category: .communication,
                params: [
                    ToolParamDefinition(key: "lookback_days", label: "Lookback Days", type: .int, required: false, defaultValue: .int(7), options: nil)
                ],
                defaultSchedule: .interval(hours: 3, activeStart: 9, activeEnd: 21)
            ),
            ToolCatalogEntry(
                actionType: .commitmentScan,
                label: "Commitment Scan",
                icon: "🤝",
                description: "Scan messages from all contacts for commitments and save to Notion",
                category: .communication,
                params: [
                    ToolParamDefinition(key: "scan_mode", label: "Scan Mode", type: .select, required: false, defaultValue: .string("all"), options: ["all", "favorites"])
                ],
                defaultSchedule: .daily(time: "17:00")
            ),
            ToolCatalogEntry(
                actionType: .patternLearning,
                label: "Pattern Learning",
                icon: "🧠",
                description: "Recompute workflow patterns from feedback, generate digest, sync to Notion",
                category: .analysis,
                params: [],
                defaultSchedule: .weekly(day: "thursday", time: "18:00")
            ),
            ToolCatalogEntry(
                actionType: .groupAnalysis,
                label: "Group Analysis",
                icon: "📊",
                description: "Analyze busy WhatsApp groups and suggest new ones for auto-summary",
                category: .analysis,
                params: [],
                defaultSchedule: .weekly(day: "sunday", time: "09:00")
            ),
            ToolCatalogEntry(
                actionType: .autoSummary,
                label: "Auto Summary",
                icon: "📨",
                description: "Generate and email daily summary for approved WhatsApp groups",
                category: .communication,
                params: [
                    ToolParamDefinition(key: "groups", label: "Groups", type: .stringArray, required: true, defaultValue: nil, options: nil)
                ],
                defaultSchedule: .daily(time: "18:00")
            ),
            ToolCatalogEntry(
                actionType: .weeklyReview,
                label: "Weekly Review",
                icon: "📋",
                description: "Comprehensive weekly reflection — wins, accountability, patterns, next week",
                category: .review,
                params: [],
                defaultSchedule: .weekly(day: "sunday", time: "08:00")
            ),
            ToolCatalogEntry(
                actionType: .messageSummary,
                label: "Message Summary",
                icon: "💬",
                description: "Summarize messages for a specific contact or group and email the results",
                category: .communication,
                params: [
                    ToolParamDefinition(key: "contact", label: "Contact/Group Name", type: .string, required: true, defaultValue: nil, options: nil),
                    ToolParamDefinition(key: "platform", label: "Platform", type: .select, required: false, defaultValue: .string("whatsapp"), options: ["whatsapp", "imessage"]),
                    ToolParamDefinition(key: "timeframe", label: "Timeframe", type: .select, required: false, defaultValue: .string("24h"), options: ["24h", "7d", "30d"])
                ],
                defaultSchedule: .daily(time: "18:00")
            ),
            ToolCatalogEntry(
                actionType: .playbookSync,
                label: "Playbook Sync",
                icon: "📖",
                description: "Sync workflow patterns and rules to the Notion playbook page",
                category: .sync,
                params: [],
                defaultSchedule: .weekly(day: "thursday", time: "18:30")
            ),
            ToolCatalogEntry(
                actionType: .coachingSync,
                label: "Coaching Sync",
                icon: "🪞",
                description: "Sync coaching context and tenets to Notion",
                category: .sync,
                params: [],
                defaultSchedule: .weekly(day: "thursday", time: "18:30")
            ),
            ToolCatalogEntry(
                actionType: .taskLifecycleScan,
                label: "Task Lifecycle Scan",
                icon: "🔄",
                description: "Scan Notion for task state changes and update lifecycle tracking",
                category: .sync,
                params: [],
                defaultSchedule: .daily(time: "09:00")
            ),
            ToolCatalogEntry(
                actionType: .reflectionIngestion,
                label: "Reflection Ingestion",
                icon: "🧠",
                description: "Ingest browsing history, Notion notes, YouTube transcripts, and imports to build reflection context",
                category: .analysis,
                params: [],
                defaultSchedule: .daily(time: "22:00")
            )
        ]
    }
}

// MARK: - Cadence Error

enum CadenceError: Error, LocalizedError {
    case serviceUnavailable(String)
    case missingParameter(String)
    case executionFailed(String)
    case notFound(String)
    case cannotDeleteBuiltIn

    var errorDescription: String? {
        switch self {
        case .serviceUnavailable(let svc): return "Service unavailable: \(svc)"
        case .missingParameter(let param): return "Missing required parameter: \(param)"
        case .executionFailed(let msg): return "Execution failed: \(msg)"
        case .notFound(let id): return "Cadence not found: \(id)"
        case .cannotDeleteBuiltIn: return "Cannot delete built-in cadences"
        }
    }
}
