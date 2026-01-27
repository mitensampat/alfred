import Foundation

/// Main service interface for the GUI app to interact with Alfred's core functionality
@MainActor
class AlfredService: ObservableObject {
    var orchestrator: BriefingOrchestrator? // Made public for HTTP server access
    private var config: AppConfig?

    @Published var isInitialized = false
    @Published var error: String?

    init() {
        Task {
            await initialize()
        }
    }

    func initialize() async {
        // Try to load config
        guard let loadedConfig = AppConfig.load() else {
            self.error = "Failed to load config. Please ensure config file exists at ~/.config/alfred/config.json"
            print("❌ Failed to load config")
            return
        }

        print("✅ Config loaded successfully")
        self.config = loadedConfig
        self.orchestrator = BriefingOrchestrator(config: loadedConfig)
        self.isInitialized = true
        self.error = nil
        print("✅ AlfredService initialized, isInitialized=true")
    }

    // MARK: - Messages

    func fetchMessagesSummary(platform: String = "all", timeframe: String = "24h") async throws -> [MessageSummary] {
        guard let orchestrator = orchestrator else {
            throw ServiceError.notInitialized
        }
        return try await orchestrator.getMessagesSummary(platform: platform, timeframe: timeframe)
    }

    func fetchFocusedThread(contactName: String, timeframe: String = "7d") async throws -> FocusedThreadAnalysis {
        guard let orchestrator = orchestrator else {
            throw ServiceError.notInitialized
        }
        return try await orchestrator.getFocusedWhatsAppThread(contactName: contactName, timeframe: timeframe)
    }

    // MARK: - Calendar

    func fetchCalendarBriefing(for date: Date = Date(), calendar: String = "all") async throws -> CalendarBriefing {
        guard let orchestrator = orchestrator else {
            throw ServiceError.notInitialized
        }
        return try await orchestrator.getCalendarBriefing(for: date, calendar: calendar)
    }

    // MARK: - Briefing

    func generateDailyBriefing(for date: Date = Date()) async throws -> DailyBriefing {
        guard let orchestrator = orchestrator else {
            throw ServiceError.notInitialized
        }
        return try await orchestrator.generateBriefing(for: date, sendEmail: false)
    }

    // MARK: - Attention Check

    func generateAttentionCheck() async throws -> AttentionDefenseReport {
        guard let orchestrator = orchestrator else {
            throw ServiceError.notInitialized
        }
        return try await orchestrator.generateAttentionDefenseAlert(sendEmail: false)
    }

    // MARK: - Notion Todos

    func scanWhatsAppForTodos() async throws -> [TodoItem] {
        guard let orchestrator = orchestrator else {
            throw ServiceError.notInitialized
        }
        let result = try await orchestrator.processWhatsAppTodos()
        return result.createdTodos
    }

    // MARK: - Recommended Actions

    func extractRecommendedActions(from analysis: FocusedThreadAnalysis) -> [RecommendedAction] {
        guard let orchestrator = orchestrator else { return [] }
        return orchestrator.extractRecommendedActions(from: analysis)
    }

    func extractRecommendedActions(from summaries: [MessageSummary]) -> [RecommendedAction] {
        guard let orchestrator = orchestrator else { return [] }
        return orchestrator.extractRecommendedActions(from: summaries)
    }

    func addRecommendedActionsToNotion(_ actions: [RecommendedAction]) async throws -> [String] {
        guard let orchestrator = orchestrator else {
            throw ServiceError.notInitialized
        }
        return try await orchestrator.addRecommendedActionsToNotion(actions)
    }

    // MARK: - Commitments

    func fetchCommitments(type: Commitment.CommitmentType? = nil) async throws -> [Commitment] {
        guard let orchestrator = orchestrator else {
            throw ServiceError.notInitialized
        }
        guard let config = orchestrator.config.commitments, config.enabled else {
            throw ServiceError.commitmentsNotEnabled
        }

        // Use unified Tasks database
        guard orchestrator.notionServicePublic.tasksDatabaseId != nil else {
            throw ServiceError.notionDatabaseNotConfigured
        }

        return try await orchestrator.notionServicePublic.queryActiveCommitmentsFromTasks(type: type)
    }

    func fetchOverdueCommitments() async throws -> [Commitment] {
        guard let orchestrator = orchestrator else {
            throw ServiceError.notInitialized
        }
        guard let config = orchestrator.config.commitments, config.enabled else {
            throw ServiceError.commitmentsNotEnabled
        }

        // Use unified Tasks database
        guard orchestrator.notionServicePublic.tasksDatabaseId != nil else {
            throw ServiceError.notionDatabaseNotConfigured
        }

        return try await orchestrator.notionServicePublic.queryOverdueCommitmentsFromTasks()
    }

    func scanCommitments(contactName: String?, lookbackDays: Int) async throws -> CommitmentScanResult {
        guard let orchestrator = orchestrator else {
            throw ServiceError.notInitialized
        }
        guard let config = orchestrator.config.commitments, config.enabled else {
            throw ServiceError.commitmentsNotEnabled
        }

        // Use unified Tasks database
        guard orchestrator.notionServicePublic.tasksDatabaseId != nil else {
            throw ServiceError.notionDatabaseNotConfigured
        }

        let contactsToScan: [String]
        if let contact = contactName {
            contactsToScan = [contact]
        } else {
            contactsToScan = config.autoScanContacts
        }

        let startDate = Calendar.current.date(byAdding: .day, value: -lookbackDays, to: Date()) ?? Date()

        var totalFound = 0
        var totalSaved = 0

        for contact in contactsToScan {
            let allMessages = try await orchestrator.fetchMessagesForContact(contact, since: startDate)

            guard !allMessages.isEmpty else { continue }

            let groupedByThread = Dictionary(grouping: allMessages) { $0.threadName }

            for (threadName, threadMessages) in groupedByThread {
                guard let firstMessage = threadMessages.first else { continue }
                let messages = threadMessages.map { $0.message }

                let extraction = try await orchestrator.commitmentAnalyzerPublic.analyzeMessages(
                    messages,
                    platform: firstMessage.platform,
                    threadName: threadName,
                    threadId: firstMessage.threadId
                )

                totalFound += extraction.commitments.count

                for commitment in extraction.commitments {
                    // Use unified Tasks database
                    let existingCommitment = try await orchestrator.notionServicePublic.findCommitmentByHashInTasks(
                        commitment.uniqueHash
                    )

                    if existingCommitment == nil {
                        _ = try await orchestrator.notionServicePublic.createCommitmentInTasks(commitment)
                        totalSaved += 1
                    }
                }
            }
        }

        return CommitmentScanResult(
            totalFound: totalFound,
            saved: totalSaved,
            duplicates: totalFound - totalSaved
        )
    }

    // MARK: - Drafts

    func fetchDrafts() async throws -> [MessageDraft] {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let draftsFile = homeDir.appendingPathComponent(".alfred/message_drafts.json")

        guard FileManager.default.fileExists(atPath: draftsFile.path) else {
            return []
        }

        let data = try Data(contentsOf: draftsFile)
        let drafts = try JSONDecoder().decode([MessageDraft].self, from: data)
        return drafts
    }

    func clearDrafts() async throws {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let draftsFile = homeDir.appendingPathComponent(".alfred/message_drafts.json")

        try "[]".write(to: draftsFile, atomically: true, encoding: .utf8)
    }

    func deleteDraft(at index: Int) async throws {
        var drafts = try await fetchDrafts()
        guard index < drafts.count else { return }
        drafts.remove(at: index)

        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let draftsFile = homeDir.appendingPathComponent(".alfred/message_drafts.json")
        let data = try JSONEncoder().encode(drafts)
        try data.write(to: draftsFile)
    }
}

// MARK: - Helper Structs

enum ServiceError: Error, LocalizedError {
    case notInitialized
    case configMissing
    case commitmentsNotEnabled
    case notionDatabaseNotConfigured
    case notImplemented(String)

    var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "Service not initialized. Please check your configuration."
        case .configMissing:
            return "Configuration file not found."
        case .commitmentsNotEnabled:
            return "Commitments feature is not enabled in config."
        case .notionDatabaseNotConfigured:
            return "Notion database ID not configured for commitments."
        case .notImplemented(let message):
            return message
        }
    }
}
