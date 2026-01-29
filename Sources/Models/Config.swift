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
    let agents: AgentsConfig?
    let commitments: CommitmentConfig?
    let api: APIConfig?
    let scheduled: ScheduledConfig?

    static func load(from path: String = "Config/config.json") -> AppConfig? {
        // Try multiple config locations in order of preference
        let configPaths = [
            // 1. Explicit path if provided
            path,
            // 2. User config directory (standard location)
            (NSString(string: "~/.config/alfred/config.json").expandingTildeInPath),
            // 3. Old location for backwards compatibility
            (NSString(string: "~/.config/exec-assistant/config.json").expandingTildeInPath),
            // 4. Original project location
            (NSString(string: "~/Documents/Claude apps/Alfred/Config/config.json").expandingTildeInPath),
            // 5. Current directory
            "Config/config.json"
        ]

        for configPath in configPaths {
            let expandedPath = (configPath as NSString).expandingTildeInPath
            if let data = try? Data(contentsOf: URL(fileURLWithPath: expandedPath)),
               let config = try? JSONDecoder().decode(AppConfig.self, from: data) {
                return config
            }
        }

        return nil
    }

    var commitmentConfig: CommitmentConfig? {
        return commitments
    }

    var userConfig: UserSettings {
        return user
    }

    var notionConfig: NotionConfig {
        return notion
    }

    var aiConfig: AIConfig {
        return ai
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
    let briefingSources: BriefingSources?

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
        case briefingSources = "briefing_sources"
    }
}

struct AIConfig: Codable {
    let anthropicApiKey: String
    let model: String
    let messageAnalysisModel: String?
    let maxThreadsToAnalyze: Int?
    let maxEmailThreadsToAnalyze: Int?
    let baseUrl: String?

    var effectiveMessageModel: String {
        messageAnalysisModel ?? "claude-haiku-4-5-20251001"
    }

    var effectiveMaxThreads: Int {
        maxThreadsToAnalyze ?? 20
    }

    var effectiveMaxEmailThreads: Int {
        maxEmailThreadsToAnalyze ?? 25
    }

    var effectiveBaseUrl: String {
        baseUrl ?? "https://api.anthropic.com/v1/messages"
    }

    enum CodingKeys: String, CodingKey {
        case anthropicApiKey = "anthropic_api_key"
        case model
        case messageAnalysisModel = "message_analysis_model"
        case maxThreadsToAnalyze = "max_threads_to_analyze"
        case maxEmailThreadsToAnalyze = "max_email_threads_to_analyze"
        case baseUrl = "base_url"
    }
}

struct MessagingConfig: Codable {
    let imessage: MessagePlatformConfig
    let whatsapp: MessagePlatformConfig
    let signal: MessagePlatformConfig
    let email: EmailPlatformConfig?

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

    struct EmailPlatformConfig: Codable {
        let enabled: Bool
        let analyzeInBriefing: Bool?
        let clientId: String
        let clientSecret: String
        let redirectUri: String
        let maxEmailsToAnalyze: Int?

        var shouldAnalyze: Bool {
            analyzeInBriefing ?? true  // Default to true for backward compatibility
        }

        var effectiveMaxEmails: Int {
            maxEmailsToAnalyze ?? 50
        }

        enum CodingKeys: String, CodingKey {
            case enabled
            case analyzeInBriefing = "analyze_in_briefing"
            case clientId = "client_id"
            case clientSecret = "client_secret"
            case redirectUri = "redirect_uri"
            case maxEmailsToAnalyze = "max_emails_to_analyze"
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

struct AgentsConfig: Codable {
    let enabled: Bool
    let autonomyLevel: String
    let capabilities: CapabilitiesConfig
    let learningMode: String
    let thresholds: ThresholdsConfig?
    let audit: AuditConfig?

    struct CapabilitiesConfig: Codable {
        let autoDraft: Bool
        let smartPriority: Bool
        let proactiveMeetingPrep: Bool
        let intelligentFollowups: Bool

        enum CodingKeys: String, CodingKey {
            case autoDraft = "auto_draft"
            case smartPriority = "smart_priority"
            case proactiveMeetingPrep = "proactive_meeting_prep"
            case intelligentFollowups = "intelligent_followups"
        }
    }

    struct ThresholdsConfig: Codable {
        let autoExecuteConfidence: Double
        let maxDailyAutoExecutions: Int

        enum CodingKeys: String, CodingKey {
            case autoExecuteConfidence = "auto_execute_confidence"
            case maxDailyAutoExecutions = "max_daily_auto_executions"
        }
    }

    struct AuditConfig: Codable {
        let retentionDays: Int
        let logAllDecisions: Bool

        enum CodingKeys: String, CodingKey {
            case retentionDays = "retention_days"
            case logAllDecisions = "log_all_decisions"
        }
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case autonomyLevel = "autonomy_level"
        case capabilities
        case learningMode = "learning_mode"
        case thresholds
        case audit
    }

    func toAgentConfig() -> AgentConfig {
        let autonomy: AutonomyLevel
        switch autonomyLevel.lowercased() {
        case "conservative":
            autonomy = .conservative
        case "moderate":
            autonomy = .moderate
        case "aggressive":
            autonomy = .aggressive
        default:
            autonomy = .moderate
        }

        let learning: AgentConfig.LearningMode
        switch learningMode.lowercased() {
        case "explicit_only":
            learning = .explicitOnly
        case "implicit_only":
            learning = .implicitOnly
        case "hybrid":
            learning = .hybrid
        default:
            learning = .hybrid
        }

        return AgentConfig(
            enabled: enabled,
            autonomyLevel: autonomy,
            capabilities: AgentConfig.AgentCapabilities(
                autoDraft: capabilities.autoDraft,
                smartPriority: capabilities.smartPriority,
                proactiveMeetingPrep: capabilities.proactiveMeetingPrep,
                intelligentFollowups: capabilities.intelligentFollowups
            ),
            learningMode: learning
        )
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
