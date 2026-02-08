import Foundation

/// Tracks FTUE (First Time User Experience) setup status
class SetupStatusService {
    static let shared = SetupStatusService()

    private let configPath: String
    private let progressPath: String

    struct SetupStatus: Codable {
        var isComplete: Bool
        var completedSteps: [String]
        var missingRequirements: [String]
        var currentStep: Int
    }

    struct SetupProgress: Codable {
        var completedSteps: [String]
        var currentStep: Int
        var stepData: [String: StepData]
        var startedAt: Date
        var lastUpdated: Date

        struct StepData: Codable {
            var completed: Bool
            var data: [String: String]
        }
    }

    private init() {
        let configDir = (NSString(string: "~/.config/alfred").expandingTildeInPath)
        self.configPath = configDir + "/config.json"
        self.progressPath = configDir + "/ftue-progress.json"

        // Ensure config directory exists
        try? FileManager.default.createDirectory(
            atPath: configDir,
            withIntermediateDirectories: true
        )
    }

    /// Check if this is first run (no config exists or setup not completed)
    func isFirstRun() -> Bool {
        // Check if config file exists
        guard FileManager.default.fileExists(atPath: configPath) else {
            return true
        }

        // Check if config has minimum required fields
        guard let config = AppConfig.load() else {
            return true
        }

        // Check for required setup completion marker
        let status = getStatus()
        return !status.isComplete
    }

    /// Get comprehensive setup status
    func getStatus() -> SetupStatus {
        var completedSteps: [String] = []
        var missingRequirements: [String] = []

        // Load existing config
        let config = AppConfig.load()

        // Check Claude API Key
        if let apiKey = config?.ai.anthropicApiKey, !apiKey.isEmpty, apiKey != "YOUR_API_KEY" {
            completedSteps.append("apiKeys")
        } else {
            missingRequirements.append("Claude API Key")
        }

        // Check Notion configuration
        if let notionKey = config?.notion.apiKey, !notionKey.isEmpty, notionKey != "YOUR_NOTION_API_KEY" {
            if let dbId = config?.notion.databaseId, !dbId.isEmpty {
                completedSteps.append("notion")
            } else {
                missingRequirements.append("Notion Database")
            }
        } else {
            missingRequirements.append("Notion API Key")
        }

        // Check Google OAuth (look for tokens file)
        let tokensPath = (NSString(string: "~/.alfred/google_tokens.json").expandingTildeInPath)
        if FileManager.default.fileExists(atPath: tokensPath) {
            completedSteps.append("googleOauth")
        } else {
            missingRequirements.append("Google OAuth")
        }

        // Check User Profile
        if let name = config?.user.name, !name.isEmpty, name != "YOUR_NAME",
           let email = config?.user.email, !email.isEmpty, email != "your@email.com" {
            completedSteps.append("profile")
        } else {
            missingRequirements.append("User Profile")
        }

        // Check Messaging (at least one enabled)
        if config?.messaging.imessage.enabled == true || config?.messaging.whatsapp.enabled == true {
            completedSteps.append("messaging")
        }

        // Permissions are hard to verify programmatically, so we check for a marker
        let permissionsMarker = (NSString(string: "~/.alfred/permissions_acknowledged").expandingTildeInPath)
        if FileManager.default.fileExists(atPath: permissionsMarker) {
            completedSteps.append("permissions")
        }

        // Load progress file to get current step
        let progress = loadProgress()

        // Setup is complete if we have all required items
        let requiredSteps = ["apiKeys", "notion", "profile"]
        let hasAllRequired = requiredSteps.allSatisfy { completedSteps.contains($0) }

        // Also check for explicit completion marker
        let completionMarker = (NSString(string: "~/.alfred/setup_complete").expandingTildeInPath)
        let hasCompletionMarker = FileManager.default.fileExists(atPath: completionMarker)

        return SetupStatus(
            isComplete: hasAllRequired && hasCompletionMarker,
            completedSteps: completedSteps,
            missingRequirements: missingRequirements,
            currentStep: progress?.currentStep ?? 0
        )
    }

    /// Mark a step as complete
    func markStepComplete(_ step: String, data: [String: String] = [:]) {
        var progress = loadProgress() ?? SetupProgress(
            completedSteps: [],
            currentStep: 0,
            stepData: [:],
            startedAt: Date(),
            lastUpdated: Date()
        )

        if !progress.completedSteps.contains(step) {
            progress.completedSteps.append(step)
        }

        progress.stepData[step] = SetupProgress.StepData(completed: true, data: data)
        progress.lastUpdated = Date()

        saveProgress(progress)
    }

    /// Update current step
    func setCurrentStep(_ step: Int) {
        var progress = loadProgress() ?? SetupProgress(
            completedSteps: [],
            currentStep: 0,
            stepData: [:],
            startedAt: Date(),
            lastUpdated: Date()
        )

        progress.currentStep = step
        progress.lastUpdated = Date()

        saveProgress(progress)
    }

    /// Mark setup as complete
    func completeSetup() {
        let completionMarker = (NSString(string: "~/.alfred/setup_complete").expandingTildeInPath)
        FileManager.default.createFile(atPath: completionMarker, contents: Data(), attributes: nil)

        // Clean up progress file
        try? FileManager.default.removeItem(atPath: progressPath)

        print("FTUE setup completed")
    }

    /// Mark permissions as acknowledged
    func acknowledgePermissions() {
        let permissionsMarker = (NSString(string: "~/.alfred/permissions_acknowledged").expandingTildeInPath)
        FileManager.default.createFile(atPath: permissionsMarker, contents: Data(), attributes: nil)
    }

    /// Save step data to config
    func saveStepToConfig(step: String, data: [String: Any]) throws {
        // Load existing config or create minimal one
        var configDict = loadConfigDict() ?? createMinimalConfig()

        switch step {
        case "apiKeys":
            if var ai = configDict["ai"] as? [String: Any] {
                if let claudeKey = data["claudeApiKey"] as? String {
                    ai["anthropic_api_key"] = claudeKey
                }
                configDict["ai"] = ai
            }

        case "notion":
            if var notion = configDict["notion"] as? [String: Any] {
                if let notionKey = data["notionApiKey"] as? String {
                    notion["api_key"] = notionKey
                }
                if let dbId = data["tasksDatabaseId"] as? String {
                    notion["database_id"] = dbId
                    notion["tasks_database_id"] = dbId
                }
                if let commitmentDbId = data["commitmentsDatabaseId"] as? String {
                    if var sources = notion["briefing_sources"] as? [String: Any] {
                        sources["commitments_database_id"] = commitmentDbId
                        notion["briefing_sources"] = sources
                    }
                }
                configDict["notion"] = notion
            }

        case "profile":
            if var user = configDict["user"] as? [String: Any] {
                if let name = data["name"] as? String {
                    user["name"] = name
                }
                if let email = data["email"] as? String {
                    user["email"] = email
                }
                configDict["user"] = user
            }

            if var app = configDict["app"] as? [String: Any] {
                if let workStart = data["workStartHour"] as? String,
                   let workEnd = data["workEndHour"] as? String {
                    // Store work hours in app settings
                    app["work_start_hour"] = workStart
                    app["work_end_hour"] = workEnd
                }
                configDict["app"] = app
            }

        case "messaging":
            if var messaging = configDict["messaging"] as? [String: Any] {
                if var imessage = messaging["imessage"] as? [String: Any] {
                    imessage["enabled"] = (data["enableIMessage"] as? String) == "true"
                    messaging["imessage"] = imessage
                }
                if var whatsapp = messaging["whatsapp"] as? [String: Any] {
                    whatsapp["enabled"] = (data["enableWhatsApp"] as? String) == "true"
                    messaging["whatsapp"] = whatsapp
                }
                configDict["messaging"] = messaging
            }

        default:
            break
        }

        // Write updated config
        let jsonData = try JSONSerialization.data(withJSONObject: configDict, options: [.prettyPrinted, .sortedKeys])
        try jsonData.write(to: URL(fileURLWithPath: configPath))

        print("Saved step '\(step)' to config")
    }

    // MARK: - Private Helpers

    private func loadProgress() -> SetupProgress? {
        guard let data = FileManager.default.contents(atPath: progressPath) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SetupProgress.self, from: data)
    }

    private func saveProgress(_ progress: SetupProgress) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted

        if let data = try? encoder.encode(progress) {
            try? data.write(to: URL(fileURLWithPath: progressPath))
        }
    }

    private func loadConfigDict() -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: configPath),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return dict
    }

    private func createMinimalConfig() -> [String: Any] {
        // Create a minimal config structure that can be filled in during FTUE
        return [
            "app": [
                "name": "Alfred",
                "version": "1.0.0",
                "briefing_time": "08:00",
                "attention_alert_time": "17:00",
                "timezone": TimeZone.current.identifier
            ],
            "user": [
                "name": "",
                "email": "",
                "company_domain": "",
                "company_domains": []
            ],
            "calendar": [
                "google": []
            ],
            "notion": [
                "api_key": "",
                "database_id": "",
                "tasks_database_id": ""
            ],
            "ai": [
                "anthropic_api_key": "",
                "model": "claude-sonnet-4-20250514",
                "message_analysis_model": "claude-haiku-4-5-20251001"
            ],
            "messaging": [
                "imessage": [
                    "enabled": true,
                    "db_path": "~/Library/Messages/chat.db"
                ],
                "whatsapp": [
                    "enabled": false,
                    "db_path": ""
                ],
                "signal": [
                    "enabled": false,
                    "db_path": ""
                ]
            ],
            "notifications": [
                "email": [
                    "enabled": false,
                    "smtp_host": "",
                    "smtp_port": 587,
                    "smtp_username": "",
                    "smtp_password": ""
                ],
                "push": [
                    "enabled": true
                ],
                "slack": [
                    "enabled": false,
                    "webhook_url": "",
                    "bot_token": ""
                ]
            ],
            "research": [
                "linkedin": [
                    "enabled": false,
                    "access_token": ""
                ],
                "search": [
                    "enabled": true
                ]
            ]
        ]
    }
}
