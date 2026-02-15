import Foundation

/// Main service interface for the GUI app to interact with Alfred's core functionality
/// Note: Removed @MainActor to allow HTTP handlers to access this from background threads
/// The orchestrator handles its own thread safety
class AlfredService: ObservableObject {
    var orchestrator: BriefingOrchestrator? // Made public for HTTP server access
    private var config: AppConfig?

    // These @Published properties are only used by GUI, which runs on MainActor anyway
    @Published var isInitialized = false
    @Published var error: String?

    init() {
        // Don't auto-initialize - let caller decide when to initialize
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

    /// Progress callback type for streaming briefing generation
    typealias BriefingProgressCallback = (_ step: String, _ message: String, _ progress: Int) -> Void

    /// Generate briefing with progress callbacks for streaming UI
    func generateDailyBriefingWithProgress(
        for date: Date = Date(),
        onProgress: @escaping BriefingProgressCallback
    ) async throws -> DailyBriefing {
        guard let orchestrator = orchestrator else {
            throw ServiceError.notInitialized
        }

        // Step 1: Messages - pre-check that we can access messages
        onProgress("messages", "Scanning your messages...", 10)
        let messageSummaries = try await orchestrator.getMessagesSummary(platform: "all", timeframe: "24h")
        let threadCount = messageSummaries.count
        onProgress("messages", "Found \(threadCount) conversations...", 20)

        // Step 2: Calendar - pre-check that we can access calendar
        onProgress("calendar", "Loading your calendar...", 30)
        let calendarBriefing = try await orchestrator.getCalendarBriefing(for: date, calendar: "all")
        let eventCount = calendarBriefing.schedule.events.count
        onProgress("calendar", "Found \(eventCount) events...", 40)

        // Step 3: Notion
        onProgress("notion", "Checking Notion for context...", 50)

        // Step 4: Analysis - this is where the heavy AI work happens
        onProgress("analysis", "AI is analyzing your day...", 60)

        // Step 5: Generate full briefing (this compiles everything and does final analysis)
        // The orchestrator will re-fetch some data but it should be fast due to caching
        let briefing = try await orchestrator.generateBriefing(for: date, sendNotifications: false)

        // Step 6: Complete
        onProgress("complete", "Briefing ready!", 100)

        return briefing
    }

    // MARK: - Attention Check

    func generateAttentionCheck() async throws -> AttentionDefenseReport {
        guard let orchestrator = orchestrator else {
            throw ServiceError.notInitialized
        }
        return try await orchestrator.generateAttentionDefenseAlert(sendNotifications: false)
    }

    /// Streaming version of attention check with progress callbacks
    /// Progress callback: (step: String, message: String, progress: Int) -> Void
    func generateAttentionCheckWithProgress(
        onProgress: @escaping (String, String, Int) -> Void
    ) async throws -> AttentionDefenseReport {
        guard let orchestrator = orchestrator else {
            throw ServiceError.notInitialized
        }
        return try await orchestrator.generateAttentionDefenseAlertWithProgress(
            sendNotifications: false,
            onProgress: onProgress
        )
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

    func scanCommitments(contactName: String?, lookbackDays: Int, scanMode: String = "favorites") async throws -> CommitmentScanResult {
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

        switch scanMode {
        case "contact":
            // Scan specific contact (requires contactName)
            if let contact = contactName {
                contactsToScan = [contact]
            } else {
                throw ServiceError.missingParameter("contactName required for 'contact' scan mode")
            }

        case "full":
            // Scan all active threads (slow but comprehensive)
            contactsToScan = buildSmartContactList(appConfig: orchestrator.config)
            print("📊 Full scan mode: scanning \(contactsToScan.count) contacts/threads")

        case "favorites":
            fallthrough
        default:
            // Scan only favorites (fast)
            let favorites = FavoritesService.shared.getFavorites()
            let favoriteContactNames = favorites.contacts.map { $0.name }
            let favoriteGroupNames = favorites.groups.map { $0.name }
            contactsToScan = favoriteContactNames + favoriteGroupNames
            print("⭐ Favorites scan mode: scanning \(contactsToScan.count) favorites")
        }

        let fullLookbackDate = Calendar.current.date(byAdding: .day, value: -lookbackDays, to: Date()) ?? Date()
        let tracker = CommitmentScanTracker.shared

        var totalFound = 0
        var totalSaved = 0
        var totalSkippedNewMessages = 0

        for contact in contactsToScan {
            let allMessages = try await orchestrator.fetchMessagesForContact(contact, since: fullLookbackDate)

            guard !allMessages.isEmpty else { continue }

            let groupedByThread = Dictionary(grouping: allMessages) { $0.threadName }

            for (threadName, threadMessages) in groupedByThread {
                guard let firstMessage = threadMessages.first else { continue }
                let threadId = firstMessage.threadId

                // INCREMENTAL SCAN: Only analyze messages newer than the last scan
                let lastMsgTimestamp = tracker.getLastMessageTimestamp(threadId: threadId)
                let newMessages: [Message]

                if let lastTimestamp = lastMsgTimestamp {
                    // Filter to only messages AFTER the last scanned message
                    let filtered = threadMessages.filter { $0.message.timestamp > lastTimestamp }
                    if filtered.isEmpty {
                        totalSkippedNewMessages += threadMessages.count
                        print("⏭️  Skipping \(threadName) - no new messages since last scan")
                        continue
                    }
                    newMessages = filtered.map { $0.message }
                    print("📬 \(threadName): \(newMessages.count) new messages (of \(threadMessages.count) total)")
                } else {
                    // Never scanned before - analyze all messages
                    newMessages = threadMessages.map { $0.message }
                    print("🆕 \(threadName): first scan - \(newMessages.count) messages")
                }

                let extraction = try await orchestrator.commitmentAnalyzer.analyzeMessages(
                    newMessages,
                    platform: firstMessage.platform,
                    threadName: threadName,
                    threadId: threadId
                )

                totalFound += extraction.commitments.count

                for commitment in extraction.commitments {
                    // Check 1: Local tracker (fast, catches same-session duplicates)
                    if tracker.hasExtractedCommitment(hash: commitment.uniqueHash) {
                        print("⏭️  Skipping duplicate (local tracker): \(commitment.title)")
                        continue
                    }

                    // Check 2: Notion database (catches completed/done items too - no status filter)
                    let existingCommitment = try await orchestrator.notionServicePublic.findCommitmentByHashInTasks(
                        commitment.uniqueHash
                    )

                    if existingCommitment != nil {
                        // Record in local tracker so we skip faster next time
                        tracker.recordExtraction(
                            hash: commitment.uniqueHash,
                            threadId: threadId,
                            type: commitment.type.rawValue,
                            title: commitment.title,
                            counterparty: commitment.type == .iOwe ? commitment.committedTo : commitment.committedBy,
                            confidence: 0.8
                        )
                        print("⏭️  Skipping duplicate (exists in Notion): \(commitment.title)")
                        continue
                    }

                    _ = try await orchestrator.notionServicePublic.createCommitmentInTasks(commitment)
                    totalSaved += 1

                    // Record extraction to tracker
                    tracker.recordExtraction(
                        hash: commitment.uniqueHash,
                        threadId: threadId,
                        type: commitment.type.rawValue,
                        title: commitment.title,
                        counterparty: commitment.type == .iOwe ? commitment.committedTo : commitment.committedBy,
                        confidence: 0.8
                    )

                    // Record commitment creation for workflow learning
                    let counterparty = commitment.type == .iOwe ? commitment.committedTo : commitment.committedBy
                    WorkflowLearningService.shared.recordCommitmentCreated(
                        hash: commitment.uniqueHash,
                        counterparty: counterparty,
                        commitmentType: commitment.type.rawValue,
                        priority: commitment.priority.rawValue
                    )
                }

                // Record thread scan with the newest message timestamp from ALL messages (not just new)
                let allMsgs = threadMessages.map { $0.message }
                let newestMsgTime = allMsgs.compactMap { $0.timestamp }.max() ?? Date()
                tracker.recordThreadScan(
                    threadId: threadId,
                    threadName: threadName,
                    platform: firstMessage.platform.rawValue,
                    lastMessageTimestamp: newestMsgTime,
                    messagesScanned: newMessages.count,
                    commitmentsFound: extraction.commitments.count
                )
            }
        }

        if totalSkippedNewMessages > 0 {
            print("📊 Scan summary: \(totalFound) found, \(totalSaved) new, skipped \(totalSkippedNewMessages) already-scanned messages")
        }

        return CommitmentScanResult(
            totalFound: totalFound,
            saved: totalSaved,
            duplicates: totalFound - totalSaved
        )
    }

    func closeCommitmentByHash(hash: String, reason: String) async throws {
        guard let orchestrator = orchestrator else {
            throw ServiceError.notInitialized
        }
        try await orchestrator.notionServicePublic.closeCommitmentInTasks(hash: hash, reason: reason)
    }

    /// Build smart list of contacts/threads to scan for commitments
    /// Includes: All Favorites + Active threads with >5 messages
    private func buildSmartContactList(appConfig: AppConfig) -> [String] {
        var contacts = Set<String>()

        // 1. Add all favorites (contacts and groups)
        let favorites = FavoritesService.shared.getFavorites()
        for contact in favorites.contacts {
            contacts.insert(contact.name)
        }
        for group in favorites.groups {
            contacts.insert(group.name)
        }

        // 2. Add config autoScanContacts if available
        if let commitmentsConfig = appConfig.commitments {
            for contact in commitmentsConfig.autoScanContacts {
                contacts.insert(contact)
            }
        }

        // 3. Add active threads with significant message history (>5 messages)
        let allThreads = ContactLearner.shared.getAllThreads()
        let minMessageThreshold = 5

        for thread in allThreads {
            // Sum total messages from participation history
            let totalMessages = thread.participationHistory.reduce(0) { $0 + $1.totalMessages }

            // Include if has enough messages and user participates
            if totalMessages >= minMessageThreshold && thread.avgParticipation > 0 {
                contacts.insert(thread.threadName)
            }
        }

        print("🎯 Smart contact list: \(contacts.count) contacts/groups to scan")
        print("   - Favorites: \(favorites.contacts.count) contacts, \(favorites.groups.count) groups")
        print("   - Active threads added: \(contacts.count - favorites.contacts.count - favorites.groups.count)")

        return Array(contacts)
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
    func getMessagesSummaryForContact(contact: String, platform: String, timeframe: String) async throws -> (summary: String, keyPoints: [String], needsResponse: Bool, messageCount: Int, actionItems: [FocusedThreadAnalysis.FocusedActionItem]) {
        guard let orchestrator = orchestrator else {
            throw ServiceError.notInitialized
        }

        // Only WhatsApp is currently supported for focused thread analysis
        guard platform.lowercased() == "whatsapp" else {
            return (
                summary: "Platform '\(platform)' is not yet supported for message summaries. Currently only WhatsApp is available.",
                keyPoints: ["WhatsApp is the only supported platform at this time"],
                needsResponse: false,
                messageCount: 0,
                actionItems: []
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
            messageCount: analysis.thread.messages.count,
            actionItems: analysis.actionItems
        )
    }

    // MARK: - Agent Digest

    func generateAgentDigest() async throws -> AgentDigest {
        guard let orchestrator = orchestrator else {
            throw ServiceError.notInitialized
        }
        return try await orchestrator.generateAgentDigest()
    }

    // MARK: - Interactive Task Extraction (for GUI approval flow)

    /// Extract commitments from messages for review (without auto-saving)
    func extractCommitmentsForReview(contactName: String?, lookbackDays: Int) async throws -> [ExtractedItem] {
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
            // Merge favorites with autoScanContacts (favorites take priority)
            let favorites = FavoritesService.shared.getFavorites()
            let favoriteContactNames = favorites.contacts.map { $0.name }
            let favoriteGroupNames = favorites.groups.map { $0.name }
            let allFavoriteNames = favoriteContactNames + favoriteGroupNames
            // Combine favorites with config, deduplicating
            let combined = allFavoriteNames + config.autoScanContacts
            contactsToScan = Array(Set(combined))
        }

        let fullLookbackDate = Calendar.current.date(byAdding: .day, value: -lookbackDays, to: Date()) ?? Date()
        let tracker = CommitmentScanTracker.shared
        var extractedItems: [ExtractedItem] = []

        for contact in contactsToScan {
            let allMessages = try await orchestrator.fetchMessagesForContact(contact, since: fullLookbackDate)
            guard !allMessages.isEmpty else { continue }

            let groupedByThread = Dictionary(grouping: allMessages) { $0.threadName }

            for (threadName, threadMessages) in groupedByThread {
                guard let firstMessage = threadMessages.first else { continue }
                let threadId = firstMessage.threadId

                // INCREMENTAL SCAN: Only analyze messages newer than the last scan
                let lastMsgTimestamp = tracker.getLastMessageTimestamp(threadId: threadId)
                let newMessages: [Message]

                if let lastTimestamp = lastMsgTimestamp {
                    let filtered = threadMessages.filter { $0.message.timestamp > lastTimestamp }
                    if filtered.isEmpty {
                        print("⏭️  Skipping \(threadName) - no new messages since last scan")
                        continue
                    }
                    newMessages = filtered.map { $0.message }
                    print("📬 \(threadName): \(newMessages.count) new messages (of \(threadMessages.count) total)")
                } else {
                    newMessages = threadMessages.map { $0.message }
                    print("🆕 \(threadName): first scan - \(newMessages.count) messages")
                }

                let extraction = try await orchestrator.commitmentAnalyzer.analyzeMessages(
                    newMessages,
                    platform: firstMessage.platform,
                    threadName: threadName,
                    threadId: threadId
                )

                for commitment in extraction.commitments {
                    // Check 1: Local tracker (fast)
                    if tracker.hasExtractedCommitment(hash: commitment.uniqueHash) {
                        continue
                    }

                    // Check 2: Notion database (includes Done/Cancelled)
                    let existing = try? await orchestrator.notionServicePublic.findCommitmentByHashInTasks(
                        commitment.uniqueHash
                    )

                    if existing != nil {
                        // Sync to local tracker for faster future skips
                        tracker.recordExtraction(
                            hash: commitment.uniqueHash,
                            threadId: threadId,
                            type: commitment.type.rawValue,
                            title: commitment.title,
                            counterparty: commitment.type == .iOwe ? commitment.committedTo : commitment.committedBy,
                            confidence: 0.8
                        )
                        continue
                    }

                    // Convert to ExtractedItem for review
                    let item = ExtractedItem.fromCommitment(commitment)
                    extractedItems.append(item)
                }

                // Record the scan so next time we only look at new messages
                let allMsgs = threadMessages.map { $0.message }
                let newestMsgTime = allMsgs.compactMap { $0.timestamp }.max() ?? Date()
                tracker.recordThreadScan(
                    threadId: threadId,
                    threadName: threadName,
                    platform: firstMessage.platform.rawValue,
                    lastMessageTimestamp: newestMsgTime,
                    messagesScanned: newMessages.count,
                    commitmentsFound: extraction.commitments.count
                )
            }
        }

        return extractedItems
    }

    /// Extract todos from WhatsApp self-messages for review (without auto-saving)
    func extractTodosForReview(lookbackDays: Int = 7) async throws -> [ExtractedItem] {
        guard let orchestrator = orchestrator else {
            throw ServiceError.notInitialized
        }
        return try await orchestrator.extractWhatsAppTodosForReview(lookbackDays: lookbackDays)
    }

    /// Analyze a specific contact thread and extract all actionable items for review
    func extractItemsFromThread(contactName: String, timeframe: String) async throws -> [ExtractedItem] {
        guard let orchestrator = orchestrator else {
            throw ServiceError.notInitialized
        }

        var extractedItems: [ExtractedItem] = []

        // Parse timeframe to hours
        let lookbackHours: Int
        if timeframe.hasSuffix("h") {
            lookbackHours = Int(timeframe.dropLast()) ?? 24
        } else if timeframe.hasSuffix("d") {
            lookbackHours = (Int(timeframe.dropLast()) ?? 1) * 24
        } else {
            lookbackHours = 24
        }

        let since = Calendar.current.date(byAdding: .hour, value: -lookbackHours, to: Date()) ?? Date()

        // Get focused thread analysis for recommended actions
        let analysis = try await orchestrator.getFocusedWhatsAppThread(contactName: contactName, timeframe: timeframe)

        // Extract recommended actions as ExtractedItems
        let recommendedActions = orchestrator.extractRecommendedActions(from: analysis)
        for action in recommendedActions {
            let priority: ExtractedItem.ItemPriority = action.priority == .critical ? .critical : .high
            let item = ExtractedItem(
                type: .todo,
                title: action.title,
                description: action.description,
                priority: priority,
                source: ExtractedItem.ItemSource(
                    platform: .whatsapp,
                    contact: contactName,
                    threadName: analysis.thread.contactName,
                    threadId: analysis.thread.contactIdentifier
                ),
                dueDate: action.dueDate,
                originalContext: action.context
            )
            extractedItems.append(item)
        }

        // Also scan for commitments
        let messages = try await orchestrator.fetchMessagesForContact(contactName, since: since)

        if !messages.isEmpty {
            let groupedByThread = Dictionary(grouping: messages) { $0.threadName }

            for (threadName, threadMessages) in groupedByThread {
                guard let firstMessage = threadMessages.first else { continue }
                let messageObjects = threadMessages.map { $0.message }

                let extraction = try await orchestrator.commitmentAnalyzer.analyzeMessages(
                    messageObjects,
                    platform: firstMessage.platform,
                    threadName: threadName,
                    threadId: firstMessage.threadId
                )

                for commitment in extraction.commitments {
                    // Check if already exists in unified Tasks database
                    let existing = try? await orchestrator.notionServicePublic.findCommitmentByHashInTasks(
                        commitment.uniqueHash
                    )
                    if existing != nil { continue }

                    let item = ExtractedItem.fromCommitment(commitment)
                    extractedItems.append(item)
                }
            }
        }

        return extractedItems
    }

    /// Save approved extracted items to Notion
    func saveApprovedItems(_ items: [ExtractedItem]) async throws -> (saved: Int, failed: Int) {
        guard let orchestrator = orchestrator else {
            throw ServiceError.notInitialized
        }
        return try await orchestrator.saveExtractedItems(items)
    }

    /// Save a single extracted item by its unique hash
    func saveItemByHash(_ hash: String, from items: [ExtractedItem]) async throws -> Bool {
        guard let item = items.first(where: { $0.uniqueHash == hash }) else {
            return false
        }

        let (saved, _) = try await saveApprovedItems([item])
        return saved > 0
    }
}

// MARK: - Helper Structs

enum ServiceError: Error, LocalizedError {
    case notInitialized
    case configMissing
    case commitmentsNotEnabled
    case notionDatabaseNotConfigured
    case notImplemented(String)
    case missingParameter(String)

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
        case .missingParameter(let param):
            return "Missing required parameter: \(param)"
        }
    }
}
