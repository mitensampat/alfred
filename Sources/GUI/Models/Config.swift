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
