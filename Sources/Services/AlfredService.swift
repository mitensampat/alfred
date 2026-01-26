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

    func initialize(config: AppConfig, orchestrator: BriefingOrchestrator) async {
        self.config = config
        self.orchestrator = orchestrator
        self.isInitialized = true
        self.error = nil
        print("✅ AlfredService initialized with provided config and orchestrator")
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
        return try await orchestrator.generateBriefing(for: date, sendNotifications: false)
    }

    // MARK: - Attention Check

    func generateAttentionCheck() async throws -> AttentionDefenseReport {
        guard let orchestrator = orchestrator else {
            throw ServiceError.notInitialized
        }
        return try await orchestrator.generateAttentionDefenseAlert(sendNotifications: false)
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

        // Query Tasks database for commitments
        let tasks = try await orchestrator.notionServicePublic.queryActiveTasks(type: .commitment)

        // Filter by commitment direction if specified
        var filteredTasks = tasks
        if let type = type {
            let direction: TaskItem.CommitmentDirection = type == .iOwe ? .iOwe : .theyOweMe
            filteredTasks = tasks.filter { $0.commitmentDirection == direction }
        }

        // Convert TaskItems to Commitments
        return filteredTasks.compactMap { $0.toCommitment() }
    }

    func fetchOverdueCommitments() async throws -> [Commitment] {
        guard let orchestrator = orchestrator else {
            throw ServiceError.notInitialized
        }
        guard let config = orchestrator.config.commitments, config.enabled else {
            throw ServiceError.commitmentsNotEnabled
        }

        // Query Tasks database for commitments
        let tasks = try await orchestrator.notionServicePublic.queryActiveTasks(type: .commitment)

        // Filter for overdue commitments and convert to Commitment type
        return tasks.filter { $0.isOverdue }.compactMap { $0.toCommitment() }
    }

    func scanCommitments(contactName: String?, lookbackDays: Int) async throws -> CommitmentScanResult {
        guard let orchestrator = orchestrator else {
            throw ServiceError.notInitialized
        }
        guard let config = orchestrator.config.commitments, config.enabled else {
            throw ServiceError.commitmentsNotEnabled
        }
        guard let databaseId = config.notionDatabaseId else {
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

                let extraction = try await orchestrator.commitmentAnalyzer.analyzeMessages(
                    messages,
                    platform: firstMessage.platform,
                    threadName: threadName,
                    threadId: firstMessage.threadId
                )

                totalFound += extraction.commitments.count

                for commitment in extraction.commitments {
                    let existingCommitment = try await orchestrator.notionServicePublic.findCommitmentByHash(
                        commitment.uniqueHash,
                        databaseId: databaseId
                    )

                    if existingCommitment == nil {
                        _ = try await orchestrator.notionServicePublic.createCommitment(
                            commitment,
                            databaseId: databaseId
                        )
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

    // MARK: - Additional API Methods

    /// Scan messages for commitments with a specific contact
    func scanMessagesForCommitments(contact: String, timeframe: String) async throws -> [Commitment] {
        guard let orchestrator = orchestrator else {
            throw ServiceError.notInitialized
        }
        guard let config = orchestrator.config.commitments, config.enabled else {
            throw ServiceError.commitmentsNotEnabled
        }

        // Parse timeframe (e.g., "7d" -> 7 days)
        let lookbackDays: Int
        if timeframe.hasSuffix("d") {
            lookbackDays = Int(timeframe.dropLast()) ?? 7
        } else {
            lookbackDays = 7 // default
        }

        let startDate = Calendar.current.date(byAdding: .day, value: -lookbackDays, to: Date()) ?? Date()

        // Fetch messages for this contact
        let allMessages = try await orchestrator.fetchMessagesForContact(contact, since: startDate)

        guard !allMessages.isEmpty else {
            // No messages found, return existing commitments instead
            let existingCommitments = try await fetchCommitments()
            return existingCommitments.filter { commitment in
                commitment.committedBy.lowercased().contains(contact.lowercased()) ||
                commitment.committedTo.lowercased().contains(contact.lowercased())
            }
        }

        // Group by thread and analyze for commitments
        let groupedByThread = Dictionary(grouping: allMessages) { $0.threadName }
        var foundCommitments: [Commitment] = []

        for (threadName, threadMessages) in groupedByThread {
            guard let firstMessage = threadMessages.first else { continue }
            let messages = threadMessages.map { $0.message }

            // Extract commitments using AI
            let extraction = try await orchestrator.commitmentAnalyzer.analyzeMessages(
                messages,
                platform: firstMessage.platform,
                threadName: threadName,
                threadId: firstMessage.threadId
            )

            // For each found commitment, check if it already exists in Tasks database
            for commitment in extraction.commitments {
                let existingPageId = try await orchestrator.notionServicePublic.findTaskByHash(
                    commitment.uniqueHash
                )

                if existingPageId == nil {
                    // New commitment - save to Tasks database
                    // createCommitment converts to TaskItem and saves to Tasks database
                    _ = try await orchestrator.notionServicePublic.createCommitment(
                        commitment,
                        databaseId: ""  // Not used anymore, kept for compatibility
                    )
                }

                // Add to results (whether new or existing)
                foundCommitments.append(commitment)
            }
        }

        return foundCommitments
    }

    /// Get message summary for a specific contact
    func getMessagesSummaryForContact(contact: String, platform: String, timeframe: String) async throws -> (summary: String, keyPoints: [String], needsResponse: Bool, messageCount: Int) {
        guard let orchestrator = orchestrator else {
            throw ServiceError.notInitialized
        }

        // Only WhatsApp is currently supported for focused thread analysis
        guard platform.lowercased() == "whatsapp" else {
            return (
                summary: "Platform '\(platform)' is not yet supported for message summaries. Currently only WhatsApp is available.",
                keyPoints: ["WhatsApp is the only supported platform at this time"],
                needsResponse: false,
                messageCount: 0
            )
        }

        // Use the existing getFocusedWhatsAppThread method
        let analysis = try await orchestrator.getFocusedWhatsAppThread(contactName: contact, timeframe: timeframe)

        // Extract key points from action items
        let keyPoints = analysis.actionItems.map { actionItem in
            "[\(actionItem.priority)] \(actionItem.item)"
        }

        return (
            summary: analysis.summary,
            keyPoints: keyPoints,
            needsResponse: !analysis.actionItems.isEmpty,
            messageCount: analysis.thread.messages.count
        )
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
