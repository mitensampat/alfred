import Foundation

struct AppConfig: Codable {
    let app: AppSettings
    let user: UserSettings
    let calendar: CalendarConfig
    let notion: NotionConfig
    let ai: AIConfig
    let messaging: MessagingConfig
    let notifications: NotificationConfig
    let research: ResearchConfig
    let commitments: CommitmentsConfig?
    let api: APIConfig?
    let scheduled: ScheduledConfig?
    let cadence: CadenceConfig?

    static func load(from path: String? = nil) -> AppConfig? {
        // Try multiple config locations in order of preference
        // User's config directory takes highest priority (where they edit settings)
        var configPaths = [
            // 1. User config directory (standard location - highest priority)
            (NSString(string: "~/.config/alfred/config.json").expandingTildeInPath),
            // 2. Old location for backwards compatibility
            (NSString(string: "~/.config/exec-assistant/config.json").expandingTildeInPath),
            // 3. Original project location (fallback)
            (NSString(string: "~/Documents/Claude apps/Alfred/Config/config.json").expandingTildeInPath),
            // 4. Current directory (fallback for development)
            "Config/config.json"
        ]

        // If explicit path provided, check it first
        if let explicitPath = path {
            configPaths.insert(explicitPath, at: 0)
        }

        for configPath in configPaths {
            let expandedPath = (configPath as NSString).expandingTildeInPath
            if let data = try? Data(contentsOf: URL(fileURLWithPath: expandedPath)) {
                do {
                    let config = try JSONDecoder().decode(AppConfig.self, from: data)
                    NSLog("✅ Config loaded from: %@", expandedPath)
                    return config
                } catch {
                    NSLog("⚠️  Failed to decode config from %@: %@", expandedPath, error.localizedDescription)
                }
            }
        }

        NSLog("❌ No valid config found")
        return nil
    }
}

struct ScheduledConfig: Codable {
    let briefingEnabled: Bool
    let attentionEnabled: Bool
    let emailTo: String

    enum CodingKeys: String, CodingKey {
        case briefingEnabled = "briefing_enabled"
        case attentionEnabled = "attention_enabled"
        case emailTo = "email_to"
    }
}

struct AppSettings: Codable {
    let name: String
    let version: String
    let briefingTime: String
    let attentionAlertTime: String
    let timezone: String

    enum CodingKeys: String, CodingKey {
        case name
        case version
        case briefingTime = "briefing_time"
        case attentionAlertTime = "attention_alert_time"
        case timezone
    }
}

struct UserSettings: Codable {
    let name: String
    let email: String
    let companyDomain: String
    let companyDomains: [String]

    enum CodingKeys: String, CodingKey {
        case name
        case email
        case companyDomain = "company_domain"
        case companyDomains = "company_domains"
    }

    func isInternal(email: String) -> Bool {
        companyDomains.contains { email.hasSuffix("@\($0)") }
    }
}

struct CalendarConfig: Codable {
    let google: [GoogleCalendarConfig]

    struct GoogleCalendarConfig: Codable {
        let name: String
        let clientId: String
        let clientSecret: String
        let redirectUri: String
        let calendarId: String?

        enum CodingKeys: String, CodingKey {
            case name
            case clientId = "client_id"
            case clientSecret = "client_secret"
            case redirectUri = "redirect_uri"
            case calendarId = "calendar_id"
        }
    }
}

struct NotionConfig: Codable {
    let apiKey: String
    let databaseId: String
    let tasksDatabaseId: String?
    let reflectionsDatabaseId: String?
    let tenetsPageId: String?
    let briefingSources: BriefingSources?
    let contextDatabases: [String]?

    struct BriefingSources: Codable {
        let tasksDatabaseId: String?
        let notesDatabaseId: String?

        enum CodingKeys: String, CodingKey {
            case tasksDatabaseId = "tasks_database_id"
            case notesDatabaseId = "notes_database_id"
        }
    }

    enum CodingKeys: String, CodingKey {
        case apiKey = "api_key"
        case databaseId = "database_id"
        case tasksDatabaseId = "tasks_database_id"
        case reflectionsDatabaseId = "reflections_database_id"
        case tenetsPageId = "tenets_page_id"
        case briefingSources = "briefing_sources"
        case contextDatabases = "context_databases"
    }
}

struct AIConfig: Codable {
    let anthropicApiKey: String
    let model: String
    let messageAnalysisModel: String?
    let maxThreadsToAnalyze: Int?

    var effectiveMessageModel: String {
        messageAnalysisModel ?? "claude-haiku-4-5-20251001"
    }

    var effectiveMaxThreads: Int {
        maxThreadsToAnalyze ?? 20
    }

    enum CodingKeys: String, CodingKey {
        case anthropicApiKey = "anthropic_api_key"
        case model
        case messageAnalysisModel = "message_analysis_model"
        case maxThreadsToAnalyze = "max_threads_to_analyze"
    }
}

struct MessagingConfig: Codable {
    let imessage: MessagePlatformConfig
    let whatsapp: MessagePlatformConfig
    let signal: MessagePlatformConfig

    struct MessagePlatformConfig: Codable {
        let enabled: Bool
        let dbPath: String

        enum CodingKeys: String, CodingKey {
            case enabled
            case dbPath = "db_path"
        }

        var expandedPath: String {
            (dbPath as NSString).expandingTildeInPath
        }
    }
}

struct NotificationConfig: Codable {
    let email: EmailConfig
    let push: PushConfig
    let slack: SlackConfig

    struct EmailConfig: Codable {
        let enabled: Bool
        let smtpHost: String
        let smtpPort: Int
        let smtpUsername: String
        let smtpPassword: String

        enum CodingKeys: String, CodingKey {
            case enabled
            case smtpHost = "smtp_host"
            case smtpPort = "smtp_port"
            case smtpUsername = "smtp_username"
            case smtpPassword = "smtp_password"
        }
    }

    struct PushConfig: Codable {
        let enabled: Bool
    }

    struct SlackConfig: Codable {
        let enabled: Bool
        let webhookUrl: String
        let botToken: String

        enum CodingKeys: String, CodingKey {
            case enabled
            case webhookUrl = "webhook_url"
            case botToken = "bot_token"
        }
    }
}

struct ResearchConfig: Codable {
    let linkedin: LinkedInConfig
    let search: SearchConfig

    struct LinkedInConfig: Codable {
        let enabled: Bool
        let accessToken: String

        enum CodingKeys: String, CodingKey {
            case enabled
            case accessToken = "access_token"
        }
    }

    struct SearchConfig: Codable {
        let enabled: Bool
    }
}

struct CommitmentsConfig: Codable {
    let enabled: Bool
    let notionDatabaseId: String?
    let autoScanOnBriefing: Bool
    let autoScanContacts: [String]
    let defaultLookbackDays: Int

    enum CodingKeys: String, CodingKey {
        case enabled
        case notionDatabaseId = "notion_database_id"
        case autoScanOnBriefing = "auto_scan_on_briefing"
        case autoScanContacts = "auto_scan_contacts"
        case defaultLookbackDays = "default_lookback_days"
    }
}

struct CadenceConfig: Codable {
    let todoScanEnabled: Bool?           // default true
    let todoScanIntervalHours: Int?      // default 3
    let commitmentScanEnabled: Bool?     // default true
    let commitmentScanTime: String?      // default "17:00"
    let patternLearnEnabled: Bool?       // default true
    let patternLearnDay: String?         // default "thursday"
    let patternLearnTime: String?        // default "18:00"
    let groupAnalysisEnabled: Bool?      // default true
    let groupAnalysisDay: String?        // default "monday"
    let groupAnalysisTime: String?       // default "09:00"
    var autoSummaryGroups: [String]?     // user-approved groups for daily auto-summary
    let autoSummaryTime: String?         // default "18:00"
    let weeklyReviewEnabled: Bool?       // default true
    let weeklyReviewDay: String?         // default "friday"
    let weeklyReviewTime: String?        // default "17:00"

    enum CodingKeys: String, CodingKey {
        case todoScanEnabled = "todo_scan_enabled"
        case todoScanIntervalHours = "todo_scan_interval_hours"
        case commitmentScanEnabled = "commitment_scan_enabled"
        case commitmentScanTime = "commitment_scan_time"
        case patternLearnEnabled = "pattern_learn_enabled"
        case patternLearnDay = "pattern_learn_day"
        case patternLearnTime = "pattern_learn_time"
        case groupAnalysisEnabled = "group_analysis_enabled"
        case groupAnalysisDay = "group_analysis_day"
        case groupAnalysisTime = "group_analysis_time"
        case autoSummaryGroups = "auto_summary_groups"
        case autoSummaryTime = "auto_summary_time"
        case weeklyReviewEnabled = "weekly_review_enabled"
        case weeklyReviewDay = "weekly_review_day"
        case weeklyReviewTime = "weekly_review_time"
    }
}

struct APIConfig: Codable {
    let enabled: Bool
    let port: Int
    let passcode: String

    enum CodingKeys: String, CodingKey {
        case enabled
        case port
        case passcode
    }
}
