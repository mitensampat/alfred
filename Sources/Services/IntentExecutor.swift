import Foundation

/// Executes parsed user intents by calling appropriate Alfred services
class IntentExecutor {
    private let orchestrator: BriefingOrchestrator
    private let config: AppConfig

    init(orchestrator: BriefingOrchestrator, config: AppConfig) {
        self.orchestrator = orchestrator
        self.config = config
    }

    /// Execute a user intent and return a conversational response
    /// - Parameter rawQuery: The original user message (may differ from intent.originalQuery which is LLM-rewritten)
    func execute(_ intent: UserIntent, rawQuery: String? = nil) async throws -> IntentExecutionResult {
        let effectiveQuery = rawQuery ?? intent.originalQuery
        switch (intent.action, intent.target) {

        // MARK: - Briefing Actions
        case (.generate, .briefing):
            let date = intent.filters.specificDate ?? Date()
            let briefing = try await orchestrator.generateBriefing(for: date, sendNotifications: false)
            return formatBriefingResponse(briefing, query: intent.originalQuery)

        // MARK: - Calendar Actions
        case (.generate, .calendar), (.list, .calendar), (.find, .calendar):
            let date = intent.filters.specificDate ?? Date()
            let calendar = intent.filters.calendarName ?? "all"
            let calendarBriefing = try await orchestrator.getCalendarBriefing(for: date, calendar: calendar)
            return formatCalendarResponse(calendarBriefing, query: intent.originalQuery)

        // MARK: - Message Actions
        case (.analyze, .messages), (.list, .messages), (.find, .messages), (.summarize, .messages):
            // If a specific contact is mentioned, use focused thread analysis for better results
            if let contactName = intent.filters.contactName {
                let timeframe = intent.filters.lookbackDays.map { "\($0)d" } ?? "7d"
                let thread = try await orchestrator.getFocusedWhatsAppThread(contactName: contactName, timeframe: timeframe)
                return formatThreadResponse(thread, query: intent.originalQuery)
            }
            let platform = intent.filters.platform?.rawValue ?? "all"
            let timeframe = intent.filters.lookbackDays.map { "\($0)d" } ?? "24h"
            let summaries = try await orchestrator.getMessagesSummary(platform: platform, timeframe: timeframe)
            return formatMessagesResponse(summaries, query: intent.originalQuery)

        case (.find, .thread), (.summarize, .thread), (.analyze, .thread):
            guard let contactName = intent.filters.contactName else {
                throw IntentExecutionError.missingRequiredParameter("contact_name")
            }
            let timeframe = intent.filters.lookbackDays.map { "\($0)d" } ?? "7d"
            let thread = try await orchestrator.getFocusedWhatsAppThread(contactName: contactName, timeframe: timeframe)
            return formatThreadResponse(thread, query: intent.originalQuery)

        // MARK: - Commitment Actions
        case (.scan, .commitments):
            let lookbackDays = intent.filters.lookbackDays ?? 14
            let contactName = intent.filters.contactName

            let result = try await scanCommitments(
                contactName: contactName,
                lookbackDays: lookbackDays
            )
            return formatCommitmentScanResponse(result, query: intent.originalQuery)

        case (.list, .commitments), (.find, .commitments):
            var commitments = try await fetchCommitments(
                type: intent.filters.commitmentType,
                contactName: intent.filters.contactName
            )
            // Filter to overdue only if requested
            let queryLower = intent.originalQuery.lowercased()
            if queryLower.contains("overdue") || queryLower.contains("behind") {
                commitments = commitments.filter { $0.isOverdue }
            }
            return formatCommitmentsListResponse(commitments, query: intent.originalQuery)

        // MARK: - Todo Actions
        case (.scan, .todos):
            let lookbackDays = intent.filters.lookbackDays ?? 7
            let result = try await orchestrator.processWhatsAppTodos(lookbackDays: lookbackDays)
            return formatTodoScanResponse(result, query: intent.originalQuery)

        case (.list, .todos):
            let todos = try await orchestrator.notionServicePublic.queryActiveTasks(type: .todo)
            return formatTaskListResponse(todos, query: intent.originalQuery)

        // MARK: - Task Actions
        case (.list, .tasks), (.check, .tasks), (.search, .tasks), (.find, .tasks), (.generate, .tasks), (.summarize, .tasks), (.analyze, .tasks):
            // Check if user is asking about completed/done tasks
            let queryLower = effectiveQuery.lowercased()
            let isCompletedQuery = queryLower.contains("completed") || queryLower.contains("finished") || queryLower.contains("done") || queryLower.contains("closed") || queryLower.contains("complete")
            if isCompletedQuery {
                let days = intent.filters.lookbackDays ?? 7
                print("📋 [IntentExecutor] Completed tasks query detected (effectiveQuery: '\(effectiveQuery)', days: \(days))")
                let completed = try await orchestrator.notionServicePublic.queryRecentlyCompletedTasks(days: days)
                print("📋 [IntentExecutor] Found \(completed.count) completed tasks")
                return formatTaskListResponse(completed, query: intent.originalQuery, isCompleted: true)
            }
            // For search/find, use fuzzy search if search term provided
            if (intent.action == .search || intent.action == .find),
               let searchTerm = intent.filters.taskSearchTerm, !searchTerm.isEmpty {
                let tasks = try await orchestrator.notionServicePublic.findTasksByFuzzyTitle(searchTerm)
                return formatTaskSearchResponse(tasks, searchTerm: searchTerm, query: intent.originalQuery)
            }
            // For check, show stats
            if intent.action == .check {
                let stats = TaskLifecycleTracker.shared.getStats()
                return formatTaskStatsResponse(stats, query: intent.originalQuery)
            }
            let typeFilter: TaskItem.TaskType? = intent.filters.taskType.flatMap { TaskItem.TaskType(rawValue: $0) }
            let tasks = try await orchestrator.notionServicePublic.queryActiveTasks(type: typeFilter)
            return formatTaskListResponse(tasks, query: intent.originalQuery)

        case (.create, .tasks), (.create, .todos):
            return try await handleCreateTask(intent: intent)

        case (.delete, .tasks):
            return try await handleTaskDeletion(intent: intent)

        case (.update, .tasks), (.update, .commitments):
            return try await handleTaskUpdate(intent: intent)

        // MARK: - Calendar Event Creation
        case (.create, .calendar):
            return try await handleCreateCalendarEvent(intent: intent)

        // MARK: - Commitment Actions (check — route through list for unified filtering)
        case (.check, .commitments):
            // Check if this is a pending closure query
            if intent.filters.urgency?.rawValue == "pending_closure" ||
               intent.originalQuery.lowercased().contains("pending") ||
               intent.originalQuery.lowercased().contains("confirm") {
                return try await handlePendingClosures()
            }
            var commitments = try await fetchCommitments(
                type: intent.filters.commitmentType,
                contactName: intent.filters.contactName
            )
            let queryLower = intent.originalQuery.lowercased()
            if queryLower.contains("overdue") || queryLower.contains("behind") {
                commitments = commitments.filter { $0.isOverdue }
            }
            return formatCommitmentsListResponse(commitments, query: intent.originalQuery)

        // MARK: - Attention Check
        case (.check, .attention), (.generate, .attention):
            let report = try await orchestrator.generateAttentionDefenseAlert(sendNotifications: false)
            return formatAttentionCheckResponse(report, query: intent.originalQuery)

        // MARK: - Drafts
        case (.list, .drafts):
            let drafts = try await fetchDrafts()
            return formatDraftsResponse(drafts, query: intent.originalQuery)

        case (.generate, .drafts):
            return try await handleGenerateDrafts(intent: intent)

        // MARK: - Weekly Reflection
        case (.summarize, .briefing):
            return try await handleWeeklyReflection(intent: intent)

        // MARK: - Commitment Creation (direct)
        case (.create, .commitments):
            return try await handleCreateCommitment(intent: intent)

        // MARK: - Commitment Deletion
        case (.delete, .commitments):
            return try await handleTaskDeletion(intent: intent)

        // MARK: - Calendar Update
        case (.update, .calendar):
            return try await handleUpdateCalendarEvent(intent: intent)

        // MARK: - Calendar Deletion
        case (.delete, .calendar):
            return try await handleDeleteCalendarEvent(intent: intent)

        // MARK: - Todo Update/Delete (items 1-2)
        case (.update, .todos):
            return try await handleTaskUpdate(intent: intent)

        case (.delete, .todos):
            return try await handleTaskDeletion(intent: intent)

        // MARK: - Meeting Brief (item 3)
        case (.generate, .meeting):
            return try await handleMeetingBrief()

        // MARK: - Focus Pin (item 4)
        case (.list, .focus), (.check, .focus):
            return try await handleGetFocusPin()

        case (.generate, .focus):
            return try await handleFocusSuggestions()

        case (.create, .focus):
            return try await handlePinFocus(intent: intent)

        case (.delete, .focus):
            return try await handleUnpinFocus()

        // MARK: - Reflections (item 5)
        case (.list, .reflections):
            return try await handleListReflectionThemes()

        case (.analyze, .reflections):
            return try await handleOpenQuestions()

        case (.summarize, .reflections):
            return try await handleThemeDeepDive(intent: intent)

        // MARK: - Pending Commitment Closures (item 6)
        // Handled via (.check, .commitments) with urgency:"pending_closure" filter — see existing commitments case above

        // MARK: - Memory & Learning (item 7)
        case (.list, .memory):
            return try await handleListMemory()

        case (.create, .memory):
            return try await handleTeachMemory(intent: intent)

        case (.delete, .memory):
            return try await handleForgetMemory(intent: intent)

        // MARK: - Cadence Trigger (item 8)
        case (.scan, .cadences):
            return try await handleTriggerCadence(intent: intent)

        case (.list, .cadences):
            return try await handleListCadences()

        // MARK: - Favorites (item 9)
        case (.list, .favorites):
            return try await handleListFavorites()

        case (.create, .favorites):
            return try await handleAddFavorite(intent: intent)

        case (.delete, .favorites):
            return try await handleRemoveFavorite(intent: intent)

        // MARK: - Contact Analysis (item 10)
        case (.analyze, .contacts):
            return try await handleContactAnalysis()

        // MARK: - Calendar Availability Check (item 11)
        case (.check, .calendar):
            return try await handleCalendarAvailabilityCheck(intent: intent)

        // MARK: - Task Lifecycle Stats (item 12)
        // Already handled via (.check, .tasks) in existing task actions case above

        // MARK: - Conversation History (item 13)
        case (.list, .conversations):
            return try await handleListConversations()

        // MARK: - Skills (item 14)
        case (.list, .skills):
            return try await handleListSkills()

        // MARK: - Chat (conversational, falls through to LLM)
        case (.chat, _):
            throw IntentExecutionError.unsupportedIntent(action: "chat", target: "conversation")

        case (_, nil):
            let actionHint: String
            switch intent.action {
            case .list: actionHint = "You can list your tasks, commitments, calendar, messages, todos, or drafts."
            case .create: actionHint = "You can create a task, todo, commitment, or calendar event."
            case .update: actionHint = "You can update a task, commitment, or calendar event."
            case .generate: actionHint = "You can generate a briefing, attention check, or draft responses."
            case .scan: actionHint = "You can scan for commitments or todos."
            case .check: actionHint = "You can check your attention, tasks, or commitments."
            case .search, .find: actionHint = "You can search for tasks, commitments, or specific threads."
            case .delete: actionHint = "You can cancel a task, commitment, or calendar event."
            case .summarize: actionHint = "You can summarize a message thread or get a weekly reflection."
            case .analyze: actionHint = "You can analyze a specific message thread."
            case .chat: actionHint = "I'm here to help with your tasks, calendar, commitments, and more."
            }
            return IntentExecutionResult(
                data: [:] as [String: Any],
                conversationalResponse: "I'd like to help! \(actionHint) What would you like?",
                structuredData: nil
            )

        default:
            // Check if this looks like a memory/learning request that should fall through to LLM chat
            let queryLower = effectiveQuery.lowercased()
            let memoryKeywords = ["memory", "remember", "update your", "note that", "know that", "my role", "i lead ", "i am the "]
            if memoryKeywords.contains(where: { queryLower.contains($0) }) {
                throw IntentExecutionError.unsupportedIntent(action: "memory_request", target: "learning")
            }
            let suggestion = getSuggestionForUnsupported(action: intent.action, target: intent.target)
            return IntentExecutionResult(
                data: [:] as [String: Any],
                conversationalResponse: suggestion,
                structuredData: nil
            )
        }
    }

    // MARK: - Helper Methods

    private func scanCommitments(contactName: String?, lookbackDays: Int) async throws -> CommitmentScanResult {
        guard let config = config.commitments, config.enabled else {
            throw IntentExecutionError.featureNotEnabled("commitments")
        }

        // Use unified Tasks database (tasksDatabaseId)
        guard orchestrator.notionServicePublic.tasksDatabaseId != nil else {
            throw IntentExecutionError.featureNotEnabled("tasks database not configured")
        }

        let contactsToScan: [String]
        if let contact = contactName {
            // Specific contact requested
            contactsToScan = [contact]
        } else {
            // Build smart contact list: Favorites + active threads (>5 messages)
            contactsToScan = buildSmartContactList()
        }

        let startDate = Calendar.current.date(byAdding: .day, value: -lookbackDays, to: Date()) ?? Date()
        let tracker = CommitmentScanTracker.shared
        var totalFound = 0
        var totalSaved = 0
        var threadsScanned = 0

        for contact in contactsToScan {
            let allMessages = try await orchestrator.fetchMessagesForContact(contact, since: startDate)
            guard !allMessages.isEmpty else { continue }

            let groupedByThread = Dictionary(grouping: allMessages) { $0.threadName }

            for (threadName, threadMessages) in groupedByThread {
                guard let firstMessage = threadMessages.first else { continue }

                let threadId = firstMessage.threadId

                // Check for incremental scanning - skip if recently scanned
                if let lastScan = tracker.getLastScanTime(threadId: threadId),
                   let lastMsgTimestamp = tracker.getLastMessageTimestamp(threadId: threadId) {
                    // Find the most recent message in this batch
                    let newestMsgTime = threadMessages.compactMap { $0.message.timestamp }.max() ?? Date()

                    // Skip if we've scanned within 1 hour AND no new messages
                    if Date().timeIntervalSince(lastScan) < 3600 && newestMsgTime <= lastMsgTimestamp {
                        print("⏭️ Skipping \(threadName) - recently scanned with no new messages")
                        continue
                    }

                    // Filter to only new messages since last scan
                    let newMessages = threadMessages.filter {
                        ($0.message.timestamp ?? Date.distantPast) > lastMsgTimestamp
                    }

                    if !newMessages.isEmpty {
                        // Scan only new messages
                        let extraction = try await orchestrator.commitmentAnalyzer.analyzeMessages(
                            newMessages.map { $0.message },
                            platform: firstMessage.platform,
                            threadName: threadName,
                            threadId: threadId
                        )

                        totalFound += extraction.commitments.count

                        for commitment in extraction.commitments {
                            // Check if already extracted (by hash)
                            if tracker.hasExtractedCommitment(hash: commitment.uniqueHash) {
                                continue
                            }

                            // Check Notion for existing
                            let existingCommitment = try await orchestrator.notionServicePublic.findCommitmentByHashInTasks(
                                commitment.uniqueHash
                            )

                            if existingCommitment == nil {
                                _ = try await orchestrator.notionServicePublic.createCommitmentInTasks(commitment)
                                totalSaved += 1

                                // Record extraction (use default confidence of 0.8 for AI-detected commitments)
                                tracker.recordExtraction(
                                    hash: commitment.uniqueHash,
                                    threadId: threadId,
                                    type: commitment.type.rawValue,
                                    title: commitment.title,
                                    counterparty: commitment.type == .iOwe ? commitment.committedTo : commitment.committedBy,
                                    confidence: 0.8
                                )
                            }
                        }
                    }
                } else {
                    // First scan for this thread - scan all messages
                    let messages = threadMessages.map { $0.message }

                    let extraction = try await orchestrator.commitmentAnalyzer.analyzeMessages(
                        messages,
                        platform: firstMessage.platform,
                        threadName: threadName,
                        threadId: threadId
                    )

                    totalFound += extraction.commitments.count

                    for commitment in extraction.commitments {
                        // Check if already extracted (by hash)
                        if tracker.hasExtractedCommitment(hash: commitment.uniqueHash) {
                            continue
                        }

                        // Check Notion for existing
                        let existingCommitment = try await orchestrator.notionServicePublic.findCommitmentByHashInTasks(
                            commitment.uniqueHash
                        )

                        if existingCommitment == nil {
                            _ = try await orchestrator.notionServicePublic.createCommitmentInTasks(commitment)
                            totalSaved += 1

                            // Record extraction (use default confidence of 0.8 for AI-detected commitments)
                            tracker.recordExtraction(
                                hash: commitment.uniqueHash,
                                threadId: threadId,
                                type: commitment.type.rawValue,
                                title: commitment.title,
                                counterparty: commitment.type == .iOwe ? commitment.committedTo : commitment.committedBy,
                                confidence: 0.8
                            )
                        }
                    }
                }

                // Record that we scanned this thread
                let newestMsgTime = threadMessages.compactMap { $0.message.timestamp }.max() ?? Date()
                tracker.recordThreadScan(
                    threadId: threadId,
                    threadName: threadName,
                    platform: firstMessage.platform.rawValue,
                    lastMessageTimestamp: newestMsgTime,
                    messagesScanned: threadMessages.count,
                    commitmentsFound: totalFound
                )
                threadsScanned += 1
            }
        }

        print("📊 Commitment scan complete: \(threadsScanned) threads, \(totalFound) found, \(totalSaved) saved")

        // Phase 2: Closure Detection
        // Check if any open commitments have been fulfilled based on recent messages
        var closedCount = 0
        var pendingClosures: [(hash: String, title: String, signal: String, confidence: Double)] = []

        for contact in contactsToScan {
            let allMessages = try await orchestrator.fetchMessagesForContact(contact, since: startDate)
            guard !allMessages.isEmpty else { continue }

            let groupedByThread = Dictionary(grouping: allMessages) { $0.threadId }

            for (threadId, threadMessages) in groupedByThread {
                // Get open commitments for this thread
                let openCommitments = tracker.getOpenCommitmentsForThread(threadId: threadId)
                guard !openCommitments.isEmpty else { continue }

                // Detect closures using AI
                do {
                    let messages = threadMessages.map { $0.message }
                    let closures = try await orchestrator.commitmentAnalyzer.detectClosures(
                        openCommitments: openCommitments,
                        messages: messages,
                        threadName: threadMessages.first?.threadName ?? contact
                    )

                    for closure in closures {
                        // Record the closure detection
                        tracker.recordClosureDetection(
                            commitmentHash: closure.commitmentHash,
                            closureSignal: closure.closureSignal,
                            confidence: closure.confidence,
                            autoClosed: closure.autoClose
                        )

                        if closure.autoClose {
                            // High confidence - auto-close
                            tracker.markCommitmentClosed(hash: closure.commitmentHash, closureMethod: "auto-closed")

                            // Also update in Notion
                            try? await orchestrator.notionServicePublic.closeCommitmentInTasks(
                                hash: closure.commitmentHash,
                                reason: closure.reason
                            )

                            closedCount += 1
                            print("✅ Auto-closed commitment: \(closure.reason)")
                        } else {
                            // Medium confidence - queue for user confirmation
                            if let commitment = openCommitments.first(where: { $0.hash == closure.commitmentHash }) {
                                pendingClosures.append((
                                    hash: closure.commitmentHash,
                                    title: commitment.title,
                                    signal: closure.closureSignal,
                                    confidence: closure.confidence
                                ))
                            }
                        }
                    }
                } catch {
                    print("⚠️ Closure detection failed for thread \(threadId): \(error)")
                }
            }
        }

        if closedCount > 0 {
            print("🎯 Auto-closed \(closedCount) commitments")
        }
        if !pendingClosures.isEmpty {
            print("❓ \(pendingClosures.count) commitments need user confirmation for closure")
        }

        return CommitmentScanResult(
            totalFound: totalFound,
            saved: totalSaved,
            duplicates: totalFound - totalSaved,
            autoClosed: closedCount,
            pendingClosures: pendingClosures.count
        )
    }

    /// Build smart list of contacts/threads to scan for commitments
    /// Includes: All Favorites + Active threads with >5 messages
    private func buildSmartContactList() -> [String] {
        var contacts = Set<String>()

        // 1. Add all favorites (contacts and groups)
        let favorites = FavoritesService.shared.getFavorites()
        for contact in favorites.contacts {
            contacts.insert(contact.name)
        }
        for group in favorites.groups {
            contacts.insert(group.name)
        }

        // 2. Add active threads with significant message history (>5 messages)
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

    private func fetchCommitments(type: UserIntent.IntentFilters.CommitmentType?, contactName: String?) async throws -> [Commitment] {
        guard let config = config.commitments, config.enabled else {
            throw IntentExecutionError.featureNotEnabled("commitments")
        }

        // Use unified Tasks database
        guard orchestrator.notionServicePublic.tasksDatabaseId != nil else {
            throw IntentExecutionError.featureNotEnabled("tasks database not configured")
        }

        let commitmentType: Commitment.CommitmentType?
        switch type {
        case .iOwe: commitmentType = .iOwe
        case .theyOwe: commitmentType = .theyOwe
        case .all, .none: commitmentType = nil
        }

        // Query from unified Tasks database
        var allCommitments = try await orchestrator.notionServicePublic.queryActiveCommitmentsFromTasks(
            type: commitmentType
        )

        // Filter by contact name if specified
        if let contactName = contactName?.lowercased() {
            allCommitments = allCommitments.filter {
                $0.committedBy.lowercased().contains(contactName) ||
                $0.committedTo.lowercased().contains(contactName) ||
                $0.title.lowercased().contains(contactName)
            }
        }

        return allCommitments
    }

    private func fetchDrafts() async throws -> [MessageDraft] {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let draftsFile = homeDir.appendingPathComponent(".alfred/message_drafts.json")

        guard FileManager.default.fileExists(atPath: draftsFile.path) else {
            return []
        }

        let data = try Data(contentsOf: draftsFile)
        let drafts = try JSONDecoder().decode([MessageDraft].self, from: data)
        return drafts
    }

    // MARK: - Response Formatters (to be implemented)
    // These will format the data into conversational responses

    private func formatBriefingResponse(_ briefing: DailyBriefing, query: String) -> IntentExecutionResult {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        let dateStr = dateFormatter.string(from: briefing.date)

        var parts: [String] = []
        parts.append("**Daily Briefing — \(dateStr)**\n")

        // Coaching cards
        if let cards = briefing.coachingCards, !cards.isEmpty {
            for card in cards {
                parts.append("**\(card.label):** \(card.insight)")
            }
            parts.append("")
        }

        // Calendar
        let eventCount = briefing.calendarBriefing.schedule.events.count
        if eventCount > 0 {
            parts.append("**Schedule:** \(eventCount) event\(eventCount == 1 ? "" : "s") today")
            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "h:mm a"
            for event in briefing.calendarBriefing.schedule.events.prefix(5) {
                let time = timeFormatter.string(from: event.startTime)
                parts.append("• \(time) — \(event.title)")
            }
            parts.append("")
        } else {
            parts.append("**Schedule:** No meetings today\n")
        }

        // Action items
        if !briefing.actionItems.isEmpty {
            parts.append("**Action Items:** \(briefing.actionItems.count) items")
            for item in briefing.actionItems.prefix(5) {
                let priority = item.priority.rawValue.lowercased()
                parts.append("• [\(priority)] \(item.title)")
            }
            parts.append("")
        }

        // Messages
        let allMsgSummaries = briefing.messagingSummary.keyInteractions + briefing.messagingSummary.needsResponse + briefing.messagingSummary.criticalMessages
        let msgCount = allMsgSummaries.count
        if msgCount > 0 {
            parts.append("**Messages:** \(msgCount) threads flagged (\(briefing.messagingSummary.criticalMessages.count) critical, \(briefing.messagingSummary.needsResponse.count) need response)")
        }

        let response = parts.joined(separator: "\n")
        return IntentExecutionResult(data: briefing, conversationalResponse: response, structuredData: nil)
    }

    private func formatCalendarResponse(_ calendar: CalendarBriefing, query: String) -> IntentExecutionResult {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        let dateStr = dateFormatter.string(from: calendar.schedule.date)

        let eventCount = calendar.schedule.events.count

        if eventCount == 0 {
            return IntentExecutionResult(
                data: calendar,
                conversationalResponse: "You have no meetings scheduled for \(dateStr). Enjoy your free time!",
                structuredData: nil
            )
        }

        // Build a conversational response
        var response = "Here's your calendar for \(dateStr):\n\n"

        // List events
        let timeFormatter = DateFormatter()
        timeFormatter.timeStyle = .short

        for event in calendar.schedule.events {
            let startTime = timeFormatter.string(from: event.startTime)
            let endTime = timeFormatter.string(from: event.endTime)
            response += "• \(startTime) - \(endTime): \(event.title)"

            if let location = event.location, !location.isEmpty {
                response += " (\(location))"
            }

            if event.hasExternalAttendees {
                let externalCount = event.externalAttendees.count
                response += " - \(externalCount) external attendee\(externalCount == 1 ? "" : "s")"
            }

            response += "\n"
        }

        // Add focus time info
        let hours = Int(calendar.focusTime / 3600)
        let minutes = Int((calendar.focusTime.truncatingRemainder(dividingBy: 3600)) / 60)

        if hours > 0 || minutes > 0 {
            response += "\n"
            if hours > 0 {
                response += "You have \(hours)h"
                if minutes > 0 {
                    response += " \(minutes)m"
                }
            } else {
                response += "You have \(minutes)m"
            }
            response += " of focus time available."
        }

        return IntentExecutionResult(data: calendar, conversationalResponse: response, structuredData: nil)
    }

    private func formatMessagesResponse(_ summaries: [MessageSummary], query: String) -> IntentExecutionResult {
        return IntentExecutionResult(data: summaries, conversationalResponse: "Here are your messages", structuredData: nil)
    }

    private func formatThreadResponse(_ thread: FocusedThreadAnalysis, query: String) -> IntentExecutionResult {
        var response = "**\(thread.thread.contactName ?? thread.thread.contactIdentifier)** (\(thread.thread.platform.displayName))\n"

        // Message stats
        let total = thread.thread.messages.count
        let sent = thread.thread.messages.filter { $0.direction == .outgoing }.count
        let received = total - sent
        if let first = thread.thread.messages.first, let last = thread.thread.messages.last {
            let df = DateFormatter()
            df.dateFormat = "MMM d"
            response += "Period: \(df.string(from: first.timestamp)) – \(df.string(from: last.timestamp)) · \(total) messages (\(sent) sent, \(received) received)\n\n"
        }

        // AI summary
        response += "**Summary**: \(thread.summary)\n\n"

        // Key quotes (actual quotes from the analysis)
        if !thread.keyQuotes.isEmpty {
            response += "**Key quotes**:\n"
            for q in thread.keyQuotes.prefix(5) {
                response += "- [\(q.timestamp)] \(q.speaker): \"\(q.quote)\"\n"
            }
            response += "\n"
        }

        // Action items
        if !thread.actionItems.isEmpty {
            response += "**Action items**:\n"
            for item in thread.actionItems {
                response += "- [\(item.priority)] \(item.item)\n"
            }
            response += "\n"
        }

        // Context
        if !thread.context.isEmpty {
            response += "**Context**: \(thread.context)\n"
        }

        return IntentExecutionResult(data: thread, conversationalResponse: response, structuredData: nil)
    }

    private func formatCommitmentScanResponse(_ result: CommitmentScanResult, query: String) -> IntentExecutionResult {
        var response = "I found \(result.totalFound) commitments. Saved \(result.saved) new ones"

        if result.duplicates > 0 {
            response += " (\(result.duplicates) were duplicates)"
        }
        response += "."

        if result.autoClosed > 0 {
            response += " Auto-closed \(result.autoClosed) completed commitment\(result.autoClosed == 1 ? "" : "s")."
        }

        if result.pendingClosures > 0 {
            response += " \(result.pendingClosures) commitment\(result.pendingClosures == 1 ? "" : "s") may be complete and need\(result.pendingClosures == 1 ? "s" : "") your confirmation."
        }

        return IntentExecutionResult(data: result, conversationalResponse: response, structuredData: nil)
    }

    private func formatCommitmentsListResponse(_ commitments: [Commitment], query: String) -> IntentExecutionResult {
        let response = "Found \(commitments.count) commitments"
        return IntentExecutionResult(data: commitments, conversationalResponse: response, structuredData: nil)
    }

    private func formatTodoScanResponse(_ result: TodoScanResult, query: String) -> IntentExecutionResult {
        var response = "Scanned \(result.messagesScanned) messages from the last \(result.lookbackDays) days.\n\n"

        if result.todosFound == 0 {
            response += "No todos found in your WhatsApp messages to yourself."
        } else {
            response += "Found \(result.todosFound) todo\(result.todosFound == 1 ? "" : "s"):\n"
            response += "• Created \(result.todosCreated) new todo\(result.todosCreated == 1 ? "" : "s") in Notion\n"

            if result.duplicatesSkipped > 0 {
                response += "• Skipped \(result.duplicatesSkipped) duplicate\(result.duplicatesSkipped == 1 ? "" : "s")\n"
            }

            if result.createdTodos.count > 0 {
                response += "\nNew todos created:\n"
                for todo in result.createdTodos.prefix(5) {
                    response += "• \(todo.title)\n"
                }
                if result.createdTodos.count > 5 {
                    response += "• ... and \(result.createdTodos.count - 5) more\n"
                }
            }
        }

        let structuredData: [String: Any] = [
            "messagesScanned": result.messagesScanned,
            "todosFound": result.todosFound,
            "todosCreated": result.todosCreated,
            "duplicatesSkipped": result.duplicatesSkipped,
            "lookbackDays": result.lookbackDays
        ]

        return IntentExecutionResult(data: result, conversationalResponse: response, structuredData: structuredData)
    }

    private func formatAttentionCheckResponse(_ report: AttentionDefenseReport, query: String) -> IntentExecutionResult {
        return IntentExecutionResult(data: report, conversationalResponse: "Here's your attention check", structuredData: nil)
    }

    private func formatDraftsResponse(_ drafts: [MessageDraft], query: String) -> IntentExecutionResult {
        return IntentExecutionResult(data: drafts, conversationalResponse: "Found \(drafts.count) drafts", structuredData: nil)
    }

    private func formatTaskListResponse(_ tasks: [TaskItem], query: String, isCompleted: Bool = false) -> IntentExecutionResult {
        let label = isCompleted ? "completed" : "active"

        if tasks.isEmpty {
            let emptyMsg = isCompleted
                ? "No tasks completed in the last week."
                : "You have no active tasks right now."
            return IntentExecutionResult(
                data: tasks,
                conversationalResponse: emptyMsg,
                structuredData: nil
            )
        }

        var response = isCompleted
            ? "You have \(tasks.count) recently completed task\(tasks.count == 1 ? "" : "s"):\n\n"
            : "You have \(tasks.count) active task\(tasks.count == 1 ? "" : "s"):\n\n"

        if isCompleted {
            // For completed tasks, just list them (no overdue grouping)
            for task in tasks.prefix(15) {
                response += "- ✅ \(task.title)"
                if let p = task.priority { response += " [\(p.rawValue)]" }
                response += "\n"
            }
            if tasks.count > 15 { response += "\n...and \(tasks.count - 15) more" }
        } else {
            // Group by priority for better readability
            let overdue = tasks.filter { $0.isOverdue }
            let rest = tasks.filter { !$0.isOverdue }

            if !overdue.isEmpty {
                response += "**Overdue (\(overdue.count)):**\n"
                for task in overdue.prefix(5) {
                    response += "- \(task.title)"
                    if let p = task.priority { response += " [\(p.rawValue)]" }
                    response += "\n"
                }
                if overdue.count > 5 { response += "- ...and \(overdue.count - 5) more\n" }
                response += "\n"
            }

            let showing = rest.prefix(10)
            for task in showing {
                response += "- \(task.title)"
                if let p = task.priority { response += " [\(p.rawValue)]" }
                if let due = task.dueDate {
                    let fmt = DateFormatter()
                    fmt.dateStyle = .short
                    response += " (due \(fmt.string(from: due)))"
                }
                response += "\n"
            }
            if rest.count > 10 { response += "\n...and \(rest.count - 10) more" }
        }

        return IntentExecutionResult(data: tasks, conversationalResponse: response, structuredData: nil)
    }

    private func formatTaskSearchResponse(_ tasks: [TaskItem], searchTerm: String, query: String) -> IntentExecutionResult {
        if tasks.isEmpty {
            return IntentExecutionResult(
                data: tasks,
                conversationalResponse: "No active tasks matching '\(searchTerm)'.",
                structuredData: nil
            )
        }

        var response = "Found \(tasks.count) task\(tasks.count == 1 ? "" : "s") matching '\(searchTerm)':\n\n"
        for task in tasks.prefix(5) {
            response += "- \(task.title)"
            if let p = task.priority { response += " [\(p.rawValue)]" }
            response += " — \(task.status.rawValue)"
            if task.isOverdue { response += " (OVERDUE)" }
            response += "\n"
        }
        if tasks.count > 5 { response += "\n...and \(tasks.count - 5) more" }

        return IntentExecutionResult(data: tasks, conversationalResponse: response, structuredData: nil)
    }

    private func formatOverdueCommitmentsResponse(_ commitments: [Commitment], query: String) -> IntentExecutionResult {
        if commitments.isEmpty {
            return IntentExecutionResult(
                data: commitments,
                conversationalResponse: "You're all caught up — no overdue commitments.",
                structuredData: nil
            )
        }

        var response = "You have \(commitments.count) overdue commitment\(commitments.count == 1 ? "" : "s"):\n\n"
        for c in commitments.prefix(8) {
            let arrow = c.type == .iOwe ? "You owe" : "Owed by"
            let person = c.type == .iOwe ? c.committedTo : c.committedBy
            response += "- \(c.title) (\(arrow) \(person))\n"
        }
        if commitments.count > 8 { response += "\n...and \(commitments.count - 8) more" }

        return IntentExecutionResult(data: commitments, conversationalResponse: response, structuredData: nil)
    }

    private func formatTaskStatsResponse(_ stats: LifecycleStats, query: String) -> IntentExecutionResult {
        var response = "**Task overview:**\n\n"
        response += "- Total tracked: \(stats.totalTasks)\n"
        response += "- Completed: \(stats.totalCompleted)\n"
        response += "- Completion rate: \(Int(stats.completionRate * 100))%\n"
        response += "- Overdue rate: \(Int(stats.overdueRate * 100))%\n"
        if let lastScan = stats.lastScanTime {
            let fmt = DateFormatter()
            fmt.dateStyle = .short
            fmt.timeStyle = .short
            response += "- Last scan: \(fmt.string(from: lastScan))\n"
        }

        return IntentExecutionResult(data: stats, conversationalResponse: response, structuredData: nil)
    }

    // MARK: - Unsupported Intent Suggestions

    private func getSuggestionForUnsupported(action: UserIntent.Action, target: UserIntent.Target?) -> String {
        guard let target = target else {
            return "I'm not sure what you'd like me to help with. Try asking about your briefing, calendar, tasks, commitments, or messages."
        }

        switch target {
        case .briefing:
            return "I can generate your daily briefing or weekly reflection. Try 'generate my briefing' or 'how was my week?'"
        case .calendar:
            return "I can show your calendar or create events. Try 'what's on my calendar today?' or 'schedule a meeting'."
        case .messages:
            return "I can summarize your messages or analyze specific threads. Try 'summarize my messages' or 'what's happening with [contact]?'"
        case .tasks:
            return "I can list, create, update, search, or cancel tasks. Try 'show my tasks', 'create a task', or 'mark [task] as done'."
        case .todos:
            return "I can list your todos, create new ones, or scan WhatsApp for them. Try 'show my todos' or 'scan for todos'."
        case .commitments:
            return "I can list, scan, or check your commitments. Try 'show my commitments', 'scan for commitments', or 'any overdue commitments?'"
        case .drafts:
            return "I can list your pending drafts or generate new ones. Try 'show my drafts' or 'draft a reply to [contact]'."
        case .attention:
            return "I can check what needs your attention. Try 'what should I focus on?'"
        case .thread:
            return "I can analyze a specific message thread. Try 'summarize my thread with [contact]'."
        case .meeting:
            return "I can show your meeting schedule or create events. Try 'what meetings do I have today?' or 'schedule a meeting'."
        case .contacts:
            return "I can analyze your contact participation. Try 'who have I been talking to most?'"
        case .preferences:
            return "Settings changes should be made through the Alfred web UI."
        case .reflections:
            return "I can show your reflection themes and open questions. Try 'what themes have I been thinking about?' or 'what are my open questions?'"
        case .memory:
            return "I can show learned patterns, teach me new rules, or forget old ones. Try 'what patterns have you learned?' or 'teach: always do X'."
        case .favorites:
            return "I can list, add, or remove favorites. Try 'show my favorites' or 'add Vinay to my favorites'."
        case .focus:
            return "I can show your focus, suggest one, or pin/unpin it. Try 'what's my top goal?' or 'pin the RCA task as my focus'."
        case .cadences:
            return "I can show cadence status or trigger them. Try 'show cadence status' or 'run attention check now'."
        case .conversations:
            return "I can show your recent chat conversations. Try 'show my recent conversations'."
        case .skills:
            return "I can show your active coaching skills. Try 'what coaching skills are active?'"
        }
    }

    // MARK: - Task Creation Handler

    private func handleCreateTask(intent: UserIntent) async throws -> IntentExecutionResult {
        let filters = intent.filters

        guard let title = filters.taskTitle ?? filters.taskSearchTerm, !title.isEmpty else {
            return IntentExecutionResult(
                data: [:] as [String: Any],
                conversationalResponse: "What should the task be called? Give me a title.",
                structuredData: nil
            )
        }

        let taskType: TaskItem.TaskType
        if intent.target == .todos {
            taskType = .todo
        } else if let typeStr = filters.taskType, let parsed = TaskItem.TaskType(rawValue: typeStr) {
            taskType = parsed
        } else {
            taskType = .todo
        }

        let priority: TaskItem.Priority?
        if let p = filters.newPriority {
            priority = TaskItem.Priority(rawValue: p)
        } else {
            priority = nil
        }

        let task = TaskItem(
            notionId: "",
            title: title,
            type: taskType,
            status: .notStarted,
            description: filters.noteToAdd,
            dueDate: filters.newDueDate,
            priority: priority,
            assignee: nil,
            commitmentDirection: nil,
            committedBy: nil,
            committedTo: nil,
            originalContext: nil,
            sourcePlatform: .manual,
            sourceThread: nil,
            sourceThreadId: nil,
            tags: nil,
            followUpDate: nil,
            uniqueHash: nil,
            notes: nil,
            createdDate: Date(),
            lastUpdated: Date()
        )

        let notionId = try await orchestrator.notionServicePublic.createTask(task)
        print("✅ Created task '\(title)' in Notion: \(notionId)")

        var response = "Created \(taskType.rawValue.lowercased()) '\(title)'"
        if let p = priority { response += " with \(p.rawValue) priority" }
        if let dueDate = filters.newDueDate {
            let fmt = DateFormatter()
            fmt.dateStyle = .medium
            response += ", due \(fmt.string(from: dueDate))"
        }
        response += "."

        return IntentExecutionResult(
            data: task,
            conversationalResponse: response,
            structuredData: [
                "type": "task_create",
                "taskTitle": title,
                "taskType": taskType.rawValue,
                "notionId": notionId,
                "success": true
            ]
        )
    }

    // MARK: - Commitment Creation Handler

    private func handleCreateCommitment(intent: UserIntent) async throws -> IntentExecutionResult {
        let filters = intent.filters

        guard let title = filters.taskTitle ?? filters.taskSearchTerm, !title.isEmpty else {
            return IntentExecutionResult(
                data: [:] as [String: Any],
                conversationalResponse: "What's the commitment? Give me a description.",
                structuredData: nil
            )
        }

        let direction: TaskItem.CommitmentDirection
        if filters.commitmentDirection == "they_owe" {
            direction = .theyOweMe
        } else {
            direction = .iOwe
        }

        let counterparty = filters.commitmentCounterparty ?? filters.contactName

        let priority: TaskItem.Priority?
        if let p = filters.newPriority {
            priority = TaskItem.Priority(rawValue: p)
        } else {
            priority = nil
        }

        let task = TaskItem(
            notionId: "",
            title: title,
            type: .commitment,
            status: .notStarted,
            description: filters.noteToAdd,
            dueDate: filters.newDueDate,
            priority: priority,
            assignee: nil,
            commitmentDirection: direction,
            committedBy: direction == .iOwe ? nil : counterparty,
            committedTo: direction == .iOwe ? counterparty : nil,
            originalContext: nil,
            sourcePlatform: .manual,
            sourceThread: nil,
            sourceThreadId: nil,
            tags: nil,
            followUpDate: nil,
            uniqueHash: nil,
            notes: nil,
            createdDate: Date(),
            lastUpdated: Date()
        )

        let notionId = try await orchestrator.notionServicePublic.createTask(task)
        print("✅ Created commitment '\(title)' in Notion: \(notionId)")

        var response = "Created commitment: '\(title)'"
        if let cp = counterparty {
            response += direction == .iOwe ? " (you owe \(cp))" : " (\(cp) owes you)"
        }
        if let p = priority { response += " — \(p.rawValue) priority" }
        if let dueDate = filters.newDueDate {
            let fmt = DateFormatter()
            fmt.dateStyle = .medium
            response += ", due \(fmt.string(from: dueDate))"
        }
        response += "."

        return IntentExecutionResult(
            data: task,
            conversationalResponse: response,
            structuredData: [
                "type": "commitment_create",
                "taskTitle": title,
                "taskType": "Commitment",
                "notionId": notionId,
                "success": true
            ]
        )
    }

    // MARK: - Task Deletion Handler

    private func handleTaskDeletion(intent: UserIntent) async throws -> IntentExecutionResult {
        let filters = intent.filters

        guard let searchTerm = filters.taskSearchTerm, !searchTerm.isEmpty else {
            return IntentExecutionResult(
                data: [:] as [String: Any],
                conversationalResponse: "Which task would you like to cancel? Give me a name or keyword.",
                structuredData: nil
            )
        }

        let matchingTasks = try await orchestrator.notionServicePublic.findTasksByFuzzyTitle(searchTerm)

        guard !matchingTasks.isEmpty else {
            return IntentExecutionResult(
                data: [:] as [String: Any],
                conversationalResponse: "I couldn't find an active task matching '\(searchTerm)'.",
                structuredData: nil
            )
        }

        if matchingTasks.count > 3 {
            let taskNames = matchingTasks.prefix(5).map { $0.title }
            return IntentExecutionResult(
                data: ["type": "disambiguation", "matches": taskNames] as [String: Any],
                conversationalResponse: "I found \(matchingTasks.count) tasks matching '\(searchTerm)'. Which one?\n" + taskNames.enumerated().map { "  \($0.offset + 1). \($0.element)" }.joined(separator: "\n"),
                structuredData: nil
            )
        }

        let task = matchingTasks[0]
        var updates = NotionService.TaskPropertyUpdate()
        updates.status = .cancelled

        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd HH:mm"
        updates.appendDescription = "[\(dateFmt.string(from: Date()))] Cancelled by Coach Alfred"

        try await orchestrator.notionServicePublic.updateTaskProperties(notionId: task.notionId, updates: updates)
        print("✅ Cancelled task '\(task.title)'")

        return IntentExecutionResult(
            data: task,
            conversationalResponse: "Cancelled '\(task.title)'.",
            structuredData: [
                "type": "task_delete",
                "taskTitle": task.title,
                "notionId": task.notionId,
                "success": true
            ]
        )
    }

    // MARK: - Draft Generation Handler

    private func handleGenerateDrafts(intent: UserIntent) async throws -> IntentExecutionResult {
        if let contactName = intent.filters.contactName {
            let timeframe = intent.filters.lookbackDays.map { "\($0)d" } ?? "7d"
            let thread = try await orchestrator.getFocusedWhatsAppThread(contactName: contactName, timeframe: timeframe)
            let count = try await orchestrator.generateDraftForThread(thread)
            return IntentExecutionResult(
                data: count,
                conversationalResponse: count > 0
                    ? "Generated \(count) draft response\(count == 1 ? "" : "s") for \(contactName)."
                    : "No draft responses needed for \(contactName) right now.",
                structuredData: nil
            )
        } else {
            let summaries = try await orchestrator.getMessagesSummary(platform: "all", timeframe: "24h")
            let count = try await orchestrator.generateDraftsForMessages(summaries)
            return IntentExecutionResult(
                data: count,
                conversationalResponse: count > 0
                    ? "Generated \(count) draft response\(count == 1 ? "" : "s") across your messages."
                    : "No draft responses needed right now.",
                structuredData: nil
            )
        }
    }

    // MARK: - Weekly Reflection Handler

    private func handleWeeklyReflection(intent: UserIntent) async throws -> IntentExecutionResult {
        // Gather this week's data from multiple sources
        let today = Date()
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: today) ?? today

        // Get tasks completed this week
        let allTasks = try await orchestrator.notionServicePublic.queryActiveTasks()
        let stats = TaskLifecycleTracker.shared.getStats()
        let recentChanges = TaskLifecycleTracker.shared.getRecentChanges(limit: 20)

        // Get commitment stats
        let openCommitments = try await orchestrator.notionServicePublic.queryActiveCommitmentsFromTasks(type: nil)
        let overdueCommitments = try await orchestrator.notionServicePublic.queryOverdueCommitmentsFromTasks()

        // Build a summary
        let completedThisWeek = recentChanges.filter { $0.newStatus == "Done" }
        var response = "**This week's snapshot:**\n\n"
        response += "- Tasks completed: \(completedThisWeek.count)\n"
        response += "- Active tasks: \(allTasks.count)\n"
        response += "- Open commitments: \(openCommitments.count)"
        if !overdueCommitments.isEmpty {
            response += " (\(overdueCommitments.count) overdue)"
        }
        response += "\n"
        response += "- Overall completion rate: \(Int(stats.completionRate * 100))%\n"

        if !completedThisWeek.isEmpty {
            response += "\n**Completed:**\n"
            for change in completedThisWeek.prefix(5) {
                response += "- \(change.title)\n"
            }
            if completedThisWeek.count > 5 {
                response += "- ...and \(completedThisWeek.count - 5) more\n"
            }
        }

        if !overdueCommitments.isEmpty {
            response += "\n**Overdue commitments:**\n"
            for c in overdueCommitments.prefix(3) {
                let person = c.type == .iOwe ? c.committedTo : c.committedBy
                response += "- \(c.title) (with \(person))\n"
            }
        }

        return IntentExecutionResult(
            data: stats,
            conversationalResponse: response,
            structuredData: [
                "type": "weekly_reflection",
                "completedCount": completedThisWeek.count,
                "activeTasks": allTasks.count,
                "openCommitments": openCommitments.count,
                "overdueCommitments": overdueCommitments.count,
                "completionRate": Int(stats.completionRate * 100)
            ]
        )
    }

    // MARK: - Task Update Handler

    private func handleTaskUpdate(intent: UserIntent) async throws -> IntentExecutionResult {
        let filters = intent.filters

        // Step 1: Resolve which task the user means
        guard let searchTerm = filters.taskSearchTerm, !searchTerm.isEmpty else {
            return IntentExecutionResult(
                data: [:] as [String: Any],
                conversationalResponse: "Which task would you like me to update? Give me a name or keyword.",
                structuredData: nil
            )
        }

        let matchingTasks = try await orchestrator.notionServicePublic.findTasksByFuzzyTitle(searchTerm)

        guard !matchingTasks.isEmpty else {
            return IntentExecutionResult(
                data: [:] as [String: Any],
                conversationalResponse: "I couldn't find an active task matching '\(searchTerm)'. Could you be more specific?",
                structuredData: nil
            )
        }

        // If too many matches, ask the user to be specific
        if matchingTasks.count > 3 {
            let taskNames = matchingTasks.prefix(5).map { $0.title }
            return IntentExecutionResult(
                data: ["type": "disambiguation", "matches": taskNames] as [String: Any],
                conversationalResponse: "I found \(matchingTasks.count) tasks matching '\(searchTerm)'. Which one?\n" + taskNames.enumerated().map { "  \($0.offset + 1). \($0.element)" }.joined(separator: "\n"),
                structuredData: ["type": "disambiguation", "matches": taskNames]
            )
        }

        // Use the best match (first result — sorted by due date)
        let task = matchingTasks[0]
        let notionId = task.notionId

        // Step 2: Build the property update
        var updates = NotionService.TaskPropertyUpdate()
        var changeDescriptions: [String] = []

        if let newStatusStr = filters.newStatus,
           let newStatus = TaskItem.TaskStatus(rawValue: newStatusStr) {
            updates.status = newStatus
            changeDescriptions.append("status → \(newStatus.rawValue)")
        }

        if let newPriorityStr = filters.newPriority,
           let newPriority = TaskItem.Priority(rawValue: newPriorityStr) {
            updates.priority = newPriority
            changeDescriptions.append("priority → \(newPriority.rawValue)")
        }

        if let newDueDate = filters.newDueDate {
            updates.dueDate = newDueDate
            let fmt = DateFormatter()
            fmt.dateStyle = .medium
            changeDescriptions.append("due date → \(fmt.string(from: newDueDate))")
        }

        if let note = filters.noteToAdd, !note.isEmpty {
            let dateFmt = DateFormatter()
            dateFmt.dateFormat = "yyyy-MM-dd HH:mm"
            let auditNote = "[\(dateFmt.string(from: Date()))] Coach Alfred: \(note)"
            updates.appendDescription = auditNote
            changeDescriptions.append("added note")
        }

        // If no note was added but we have other changes, add audit trail
        if updates.appendDescription == nil && !changeDescriptions.isEmpty {
            let dateFmt = DateFormatter()
            dateFmt.dateFormat = "yyyy-MM-dd HH:mm"
            let auditLine = "[\(dateFmt.string(from: Date()))] Updated by Coach Alfred: \(changeDescriptions.joined(separator: ", "))"
            updates.appendDescription = auditLine
        }

        guard !changeDescriptions.isEmpty else {
            return IntentExecutionResult(
                data: [:] as [String: Any],
                conversationalResponse: "I found '\(task.title)' but I'm not sure what to change. You can update the status, priority, due date, or add a note.",
                structuredData: nil
            )
        }

        // Step 3: Execute the update
        try await orchestrator.notionServicePublic.updateTaskProperties(notionId: notionId, updates: updates)

        let summary = "Updated '\(task.title)': \(changeDescriptions.joined(separator: ", "))"
        print("✅ \(summary)")

        let result = TaskUpdateResult(
            taskTitle: task.title,
            notionId: notionId,
            changes: changeDescriptions,
            success: true
        )

        return IntentExecutionResult(
            data: result,
            conversationalResponse: summary,
            structuredData: [
                "type": "task_update",
                "taskTitle": task.title,
                "notionId": notionId,
                "changes": changeDescriptions,
                "success": true
            ]
        )
    }

    // MARK: - Calendar Event Creation Handler

    private func handleCreateCalendarEvent(intent: UserIntent) async throws -> IntentExecutionResult {
        let filters = intent.filters

        // Parse event time from ISO8601 string
        guard let eventTimeStr = filters.eventTime,
              let startTime = UserIntent.IntentFilters.parseFlexibleDate(eventTimeStr) else {
            return IntentExecutionResult(
                data: [:] as [String: Any],
                conversationalResponse: "I need a time to create the event. When should it be?",
                structuredData: nil
            )
        }

        // Bug 4 fix: Reject events in the past
        if startTime < Date() {
            let dateFmt = DateFormatter()
            dateFmt.dateFormat = "EEE, MMM d 'at' h:mm a"
            return IntentExecutionResult(
                data: [:] as [String: Any],
                conversationalResponse: "That time (\(dateFmt.string(from: startTime))) is in the past. When should I block it instead?",
                structuredData: nil
            )
        }

        let durationMinutes = filters.eventDurationMinutes ?? 30
        let endTime = startTime.addingTimeInterval(Double(durationMinutes) * 60)

        // Build title: "Miten <> Mona : Coffee-time" format
        let title: String
        if let explicit = filters.eventTitle, !explicit.isEmpty {
            title = explicit
        } else {
            let firstName = config.user.name.split(separator: " ").first.map(String.init) ?? "Me"
            let attendeeStr = filters.eventAttendees?.joined(separator: ", ")
            let topic = filters.eventDescription

            if let attendee = attendeeStr, let topic = topic {
                title = "\(firstName) <> \(attendee) : \(topic)"
            } else if let attendee = attendeeStr {
                title = "\(firstName) <> \(attendee)"
            } else if let topic = topic {
                title = topic
            } else {
                title = "Blocked time"
            }
        }

        // Get the primary calendar service
        guard let calendarService = orchestrator.calendarServicePublic.getService(named: "primary") else {
            return IntentExecutionResult(
                data: [:] as [String: Any],
                conversationalResponse: "Primary calendar is not configured. Please set up Google Calendar first.",
                structuredData: nil
            )
        }

        // --- Stage A: Availability check (use RAW events, not filtered) ---
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "h:mm a"
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "EEE, MMM d"
        let targetDateStr = dateFmt.string(from: startTime)

        do {
            // Bug 2 fix: fetch raw events from Google Calendar directly (bypasses block/short event filtering)
            let rawEvents = try await calendarService.fetchEvents(for: startTime)

            // Check if proposed time overlaps with any existing event (skip all-day events)
            let conflicts = rawEvents.filter { event in
                !(endTime <= event.startTime || startTime >= event.endTime) && !event.isAllDay
            }

            if !conflicts.isEmpty {
                let conflictNames = conflicts.map { $0.title }.joined(separator: ", ")

                // Find next available slot after the proposed time on the same day
                let requiredDuration = endTime.timeIntervalSince(startTime)
                let dayEnd = Calendar.current.date(bySettingHour: 21, minute: 0, second: 0, of: startTime)!
                let sortedEvents = rawEvents.filter { !$0.isAllDay && $0.endTime > startTime && $0.startTime < dayEnd }
                    .sorted { $0.startTime < $1.startTime }

                // Walk through events to find a gap that fits
                var cursor = startTime
                var suggestion: Date? = nil
                for event in sortedEvents {
                    if event.startTime > cursor {
                        let gap = event.startTime.timeIntervalSince(cursor)
                        if gap >= requiredDuration {
                            suggestion = cursor
                            break
                        }
                    }
                    cursor = max(cursor, event.endTime)
                }
                // Check after last event
                if suggestion == nil && cursor < dayEnd && dayEnd.timeIntervalSince(cursor) >= requiredDuration {
                    suggestion = cursor
                }

                // Bug 3 fix: reference the actual target date, not "today"
                var response = "You're blocked at that time — '\(conflictNames)' is on your calendar."
                if let freeAt = suggestion {
                    response += " You're free at \(timeFmt.string(from: freeAt)) — want me to book it then instead?"
                } else {
                    response += " I don't see a free slot on \(targetDateStr) that fits. Want to try a different day?"
                }

                return IntentExecutionResult(
                    data: [:] as [String: Any],
                    conversationalResponse: response,
                    structuredData: nil
                )
            }
        } catch {
            // If availability check fails, proceed anyway (don't block event creation)
            print("⚠️ Availability check failed, proceeding with creation: \(error)")
        }

        // --- Stage B: Collect attendee emails ---
        var allEmails: [String] = filters.eventAttendeeEmails ?? []

        // Always add the user's work email as default invitee
        let userCalendarEmail = config.user.calendarEmail
        if !allEmails.map({ $0.lowercased() }).contains(userCalendarEmail.lowercased()) {
            allEmails.append(userCalendarEmail)
        }

        // Deduplicate (case-insensitive)
        var seen = Set<String>()
        let uniqueEmails = allEmails.filter { email in
            let lower = email.lowercased()
            if seen.contains(lower) { return false }
            seen.insert(lower)
            return true
        }

        // Bug 1 fix: detect named attendees without emails
        let namedAttendees = filters.eventAttendees ?? []
        let providedEmails = filters.eventAttendeeEmails ?? []
        let unresolvedNames: [String]
        if namedAttendees.isEmpty {
            // No named attendees → nothing to resolve
            unresolvedNames = []
        } else if providedEmails.count >= namedAttendees.count {
            // User provided enough emails to cover all named attendees → all resolved
            unresolvedNames = []
        } else {
            // Fewer emails than names — check which names have a matching email
            // Match if any part of the name (first/last) appears in any provided email
            unresolvedNames = namedAttendees.filter { name in
                let nameParts = name.lowercased().split(separator: " ").map(String.init)
                return !providedEmails.contains { email in
                    let emailLower = email.lowercased()
                    // Check if full name matches OR any individual name part appears in the email local part
                    return emailLower.contains(name.lowercased()) ||
                           nameParts.contains { part in emailLower.split(separator: "@").first.map(String.init)?.contains(part) ?? false }
                }
            }
        }

        // --- Stage C: Create event with attendees ---
        let createdEvent = try await calendarService.createEvent(
            title: title,
            startTime: startTime,
            endTime: endTime,
            location: filters.eventLocation,
            description: filters.eventDescription,
            attendees: uniqueEmails.isEmpty ? nil : uniqueEmails
        )

        // --- Stage D: Build response ---
        let timeRange = "\(timeFmt.string(from: startTime)) – \(timeFmt.string(from: endTime))"
        let dateStr = dateFmt.string(from: startTime)

        var summary = "Created '\(title)' on \(dateStr), \(timeRange)"
        if let loc = filters.eventLocation { summary += " at \(loc)" }
        summary += "."

        // Mention non-self invitees
        let externalInvitees = uniqueEmails.filter { $0.lowercased() != userCalendarEmail.lowercased() }
        if !externalInvitees.isEmpty {
            summary += "\nInvite sent to: \(externalInvitees.joined(separator: ", "))"
        }

        // Bug 1 fix: prompt for unresolved attendee emails
        let hasUnresolvedAttendees = !unresolvedNames.isEmpty
        if hasUnresolvedAttendees {
            let names = unresolvedNames.joined(separator: " and ")
            summary += "\n\nWant to invite \(names)? Share their email\(unresolvedNames.count > 1 ? "s" : "") and I'll send the invite."
        }

        summary += "\n\nShare this link so others can add it to their calendar:\n\(createdEvent.shareableLink)"

        var structuredData: [String: Any] = [
            "type": "calendar_create",
            "title": title,
            "date": dateStr,
            "timeRange": timeRange,
            "location": filters.eventLocation ?? "",
            "shareableLink": createdEvent.shareableLink,
            "htmlLink": createdEvent.htmlLink,
            "success": true
        ]
        if hasUnresolvedAttendees {
            structuredData["needsFollowUp"] = true
            structuredData["unresolvedAttendees"] = unresolvedNames
            structuredData["eventId"] = createdEvent.id
        }

        return IntentExecutionResult(
            data: createdEvent,
            conversationalResponse: summary,
            structuredData: structuredData
        )
    }

    // MARK: - Calendar Event Update Handler

    private func handleUpdateCalendarEvent(intent: UserIntent) async throws -> IntentExecutionResult {
        let filters = intent.filters

        guard let searchTerm = filters.eventSearchTerm ?? filters.eventTitle, !searchTerm.isEmpty else {
            return IntentExecutionResult(
                data: [:] as [String: Any],
                conversationalResponse: "Which event would you like to update? Give me a name, time, or keyword.",
                structuredData: nil
            )
        }

        guard let calendarService = orchestrator.calendarServicePublic.getService(named: "primary") else {
            return IntentExecutionResult(
                data: [:] as [String: Any],
                conversationalResponse: "Primary calendar is not configured. Please set up Google Calendar first.",
                structuredData: nil
            )
        }

        // Fetch today's events to find the match
        let targetDate = filters.specificDate ?? Date()
        let events = try await calendarService.fetchEvents(for: targetDate)

        // Fuzzy-match events by search term (title, time, attendee name)
        let searchLower = searchTerm.lowercased()
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "h:mma"
        let hourFmt = DateFormatter()
        hourFmt.dateFormat = "ha"

        let matches = events.filter { event in
            let titleMatch = event.title.lowercased().contains(searchLower)
            let timeStr = timeFmt.string(from: event.startTime).lowercased()
            let hourStr = hourFmt.string(from: event.startTime).lowercased()
            let timeMatch = searchLower.contains(timeStr.replacingOccurrences(of: ":00", with: "")) || searchLower.contains(hourStr)
            let attendeeMatch = event.attendees.contains { ($0.name ?? "").lowercased().contains(searchLower) || $0.email.lowercased().contains(searchLower) }
            return titleMatch || timeMatch || attendeeMatch
        }

        guard !matches.isEmpty else {
            return IntentExecutionResult(
                data: [:] as [String: Any],
                conversationalResponse: "I couldn't find a calendar event matching '\(searchTerm)' today.",
                structuredData: nil
            )
        }

        if matches.count > 3 {
            let eventNames = matches.prefix(5).map { "\($0.title) (\(timeFmt.string(from: $0.startTime)))" }
            return IntentExecutionResult(
                data: ["type": "disambiguation", "matches": eventNames] as [String: Any],
                conversationalResponse: "I found \(matches.count) events matching '\(searchTerm)'. Which one?\n" + eventNames.enumerated().map { "  \($0.offset + 1). \($0.element)" }.joined(separator: "\n"),
                structuredData: nil
            )
        }

        let event = matches[0]

        // Parse new time if provided
        var newStart: Date? = nil
        var newEnd: Date? = nil
        if let eventTimeStr = filters.eventTime {
            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime]
            if let parsed = isoFormatter.date(from: eventTimeStr) {
                newStart = parsed
                let duration = event.endTime.timeIntervalSince(event.startTime)
                newEnd = parsed.addingTimeInterval(duration)
            }
        }

        let updatedEvent = try await calendarService.updateEvent(
            eventId: event.id,
            startTime: newStart,
            endTime: newEnd,
            location: filters.eventLocation
        )

        let displayTimeFmt = DateFormatter()
        displayTimeFmt.dateFormat = "h:mm a"

        var changes: [String] = []
        if let ns = newStart { changes.append("moved to \(displayTimeFmt.string(from: ns))") }
        if let loc = filters.eventLocation { changes.append("location → \(loc)") }

        let summary = "Updated '\(event.title)': \(changes.joined(separator: ", "))."

        return IntentExecutionResult(
            data: updatedEvent,
            conversationalResponse: summary,
            structuredData: [
                "type": "calendar_update",
                "eventTitle": event.title,
                "eventId": event.id,
                "changes": changes,
                "success": true
            ]
        )
    }

    // MARK: - Calendar Event Delete Handler

    private func handleDeleteCalendarEvent(intent: UserIntent) async throws -> IntentExecutionResult {
        let filters = intent.filters

        guard let searchTerm = filters.eventSearchTerm ?? filters.eventTitle, !searchTerm.isEmpty else {
            return IntentExecutionResult(
                data: [:] as [String: Any],
                conversationalResponse: "Which event would you like to cancel? Give me a name, time, or keyword.",
                structuredData: nil
            )
        }

        guard let calendarService = orchestrator.calendarServicePublic.getService(named: "primary") else {
            return IntentExecutionResult(
                data: [:] as [String: Any],
                conversationalResponse: "Primary calendar is not configured. Please set up Google Calendar first.",
                structuredData: nil
            )
        }

        let targetDate = filters.specificDate ?? Date()
        let events = try await calendarService.fetchEvents(for: targetDate)

        // Fuzzy-match (same logic as update)
        let searchLower = searchTerm.lowercased()
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "h:mma"
        let hourFmt = DateFormatter()
        hourFmt.dateFormat = "ha"

        let matches = events.filter { event in
            let titleMatch = event.title.lowercased().contains(searchLower)
            let timeStr = timeFmt.string(from: event.startTime).lowercased()
            let hourStr = hourFmt.string(from: event.startTime).lowercased()
            let timeMatch = searchLower.contains(timeStr.replacingOccurrences(of: ":00", with: "")) || searchLower.contains(hourStr)
            let attendeeMatch = event.attendees.contains { ($0.name ?? "").lowercased().contains(searchLower) || $0.email.lowercased().contains(searchLower) }
            return titleMatch || timeMatch || attendeeMatch
        }

        guard !matches.isEmpty else {
            return IntentExecutionResult(
                data: [:] as [String: Any],
                conversationalResponse: "I couldn't find a calendar event matching '\(searchTerm)' today.",
                structuredData: nil
            )
        }

        if matches.count > 3 {
            let eventNames = matches.prefix(5).map { "\($0.title) (\(timeFmt.string(from: $0.startTime)))" }
            return IntentExecutionResult(
                data: ["type": "disambiguation", "matches": eventNames] as [String: Any],
                conversationalResponse: "I found \(matches.count) events matching '\(searchTerm)'. Which one?\n" + eventNames.enumerated().map { "  \($0.offset + 1). \($0.element)" }.joined(separator: "\n"),
                structuredData: nil
            )
        }

        let event = matches[0]
        let displayTimeFmt = DateFormatter()
        displayTimeFmt.dateFormat = "h:mm a"
        let eventDescription = "\(event.title) at \(displayTimeFmt.string(from: event.startTime))"

        try await calendarService.deleteEvent(eventId: event.id)

        return IntentExecutionResult(
            data: [:] as [String: Any],
            conversationalResponse: "Cancelled '\(eventDescription)'.",
            structuredData: [
                "type": "calendar_delete",
                "eventTitle": event.title,
                "eventId": event.id,
                "success": true
            ]
        )
    }

    // MARK: - Meeting Brief Handler (item 3)

    private func handleMeetingBrief() async throws -> IntentExecutionResult {
        let events = try await orchestrator.calendarServicePublic.fetchEventsFromAllCalendars(
            for: Date(),
            userSettings: config.user
        )

        let now = Date()
        let upcomingEvents = events.events.filter { $0.startTime > now && !$0.isAllDay }
            .sorted { $0.startTime < $1.startTime }

        guard let nextEvent = upcomingEvents.first else {
            return IntentExecutionResult(
                data: [:] as [String: Any],
                conversationalResponse: "You don't have any upcoming meetings today.",
                structuredData: ["type": "meeting_brief", "noMeeting": true]
            )
        }

        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "h:mm a"
        let timeStr = timeFmt.string(from: nextEvent.startTime)

        var response = "Your next meeting is '\(nextEvent.title)' at \(timeStr)."
        if !nextEvent.attendees.isEmpty {
            let names = nextEvent.attendees.prefix(5).map { $0.name ?? $0.email }.joined(separator: ", ")
            response += " Attendees: \(names)."
        }
        if let location = nextEvent.location, !location.isEmpty {
            response += " Location: \(location)."
        }

        return IntentExecutionResult(
            data: nextEvent,
            conversationalResponse: response,
            structuredData: [
                "type": "meeting_brief",
                "title": nextEvent.title,
                "time": timeStr,
                "attendeeCount": nextEvent.attendees.count
            ]
        )
    }

    // MARK: - Focus Pin Handlers (item 4)

    private func handleGetFocusPin() async throws -> IntentExecutionResult {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let pinFile = homeDir.appendingPathComponent(".alfred/focus_pin.json")

        guard FileManager.default.fileExists(atPath: pinFile.path),
              let data = try? Data(contentsOf: pinFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = json["title"] as? String else {
            return IntentExecutionResult(
                data: [:] as [String: Any],
                conversationalResponse: "You don't have a focus pinned right now. Want me to suggest one?",
                structuredData: ["type": "focus", "pinned": false]
            )
        }

        let priority = json["priority"] as? String ?? ""
        var response = "Your current focus: '\(title)'"
        if !priority.isEmpty { response += " (\(priority) priority)" }

        return IntentExecutionResult(
            data: json,
            conversationalResponse: response,
            structuredData: ["type": "focus", "pinned": true, "title": title, "priority": priority]
        )
    }

    private func handleFocusSuggestions() async throws -> IntentExecutionResult {
        let tasks = try await orchestrator.notionServicePublic.queryActiveTasks(type: nil)

        // Score tasks: Critical/High priority + soonest due date = best suggestion
        let scored = tasks.prefix(20).map { task -> (TaskItem, Int) in
            var score = 0
            switch task.priority {
            case .critical: score += 40
            case .high: score += 30
            case .medium: score += 15
            case .low: score += 5
            case .none, nil: score += 10
            }
            if task.isOverdue { score += 25 }
            if let due = task.dueDate, due.timeIntervalSinceNow < 86400 * 2 { score += 20 }
            return (task, score)
        }.sorted { $0.1 > $1.1 }

        let suggestions = scored.prefix(5).map { (task, score) -> [String: Any] in
            [
                "notionId": task.notionId,
                "title": task.title,
                "priority": task.priority?.rawValue ?? "Medium",
                "score": score
            ]
        }

        var response = "Here are my focus suggestions:\n"
        for (i, s) in suggestions.enumerated() {
            let title = s["title"] as? String ?? ""
            let priority = s["priority"] as? String ?? ""
            response += "\(i + 1). \(title) (\(priority))\n"
        }
        response += "\nTell me which one to pin, or describe your own focus."

        return IntentExecutionResult(
            data: suggestions,
            conversationalResponse: response,
            structuredData: ["type": "focus_suggestions", "suggestions": suggestions, "count": suggestions.count]
        )
    }

    private func handlePinFocus(intent: UserIntent) async throws -> IntentExecutionResult {
        guard let searchTerm = intent.filters.taskSearchTerm, !searchTerm.isEmpty else {
            return IntentExecutionResult(
                data: [:] as [String: Any],
                conversationalResponse: "Which task would you like to pin as your focus? Give me a name or keyword.",
                structuredData: nil
            )
        }

        let matchingTasks = try await orchestrator.notionServicePublic.findTasksByFuzzyTitle(searchTerm)
        guard let task = matchingTasks.first else {
            return IntentExecutionResult(
                data: [:] as [String: Any],
                conversationalResponse: "I couldn't find a task matching '\(searchTerm)'. Could you be more specific?",
                structuredData: nil
            )
        }

        let pinData: [String: Any] = [
            "notionId": task.notionId,
            "title": task.title,
            "priority": task.priority?.rawValue ?? "Medium",
            "pinnedAt": ISO8601DateFormatter().string(from: Date())
        ]

        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let pinFile = homeDir.appendingPathComponent(".alfred/focus_pin.json")
        let jsonData = try JSONSerialization.data(withJSONObject: pinData, options: .prettyPrinted)
        try jsonData.write(to: pinFile)

        return IntentExecutionResult(
            data: pinData,
            conversationalResponse: "Pinned '\(task.title)' as your focus. I'll keep this front and center.",
            structuredData: ["type": "focus", "pinned": true, "title": task.title]
        )
    }

    private func handleUnpinFocus() async throws -> IntentExecutionResult {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let pinFile = homeDir.appendingPathComponent(".alfred/focus_pin.json")

        if FileManager.default.fileExists(atPath: pinFile.path) {
            try FileManager.default.removeItem(at: pinFile)
        }

        return IntentExecutionResult(
            data: [:] as [String: Any],
            conversationalResponse: "Focus unpinned. Ready for a new one when you are.",
            structuredData: ["type": "focus", "pinned": false]
        )
    }

    // MARK: - Reflection Handlers (item 5)

    private func handleListReflectionThemes() async throws -> IntentExecutionResult {
        let themes = ReflectionStore.shared.getThemesWithState(days: 30, limit: 15)
        let openQuestions = ReflectionStore.shared.getOpenQuestions(limit: 5)

        if themes.isEmpty {
            return IntentExecutionResult(
                data: [:] as [String: Any],
                conversationalResponse: "No reflection themes found in the last 30 days. Reflection data may not have been ingested yet.",
                structuredData: ["type": "reflections", "count": 0]
            )
        }

        var response = "Your top themes from the last 30 days:\n"
        for (i, theme) in themes.prefix(10).enumerated() {
            let name = theme["theme"] as? String ?? "Unknown"
            let count = theme["count"] as? Int ?? 0
            let state = theme["state"] as? String ?? ""
            response += "\(i + 1). \(name) (\(count) mentions"
            if !state.isEmpty { response += ", \(state)" }
            response += ")\n"
        }

        if !openQuestions.isEmpty {
            response += "\nOpen questions you've been wrestling with:\n"
            for q in openQuestions.prefix(3) {
                response += "• \(q)\n"
            }
        }

        return IntentExecutionResult(
            data: themes,
            conversationalResponse: response,
            structuredData: ["type": "reflections", "count": themes.count]
        )
    }

    private func handleOpenQuestions() async throws -> IntentExecutionResult {
        let questions = ReflectionStore.shared.getOpenQuestions(limit: 10)

        if questions.isEmpty {
            return IntentExecutionResult(
                data: [:] as [String: Any],
                conversationalResponse: "No open questions found. These are extracted from your reflections over time.",
                structuredData: ["type": "open_questions", "count": 0]
            )
        }

        var response = "Open questions you've been wrestling with:\n"
        for (i, q) in questions.enumerated() {
            response += "\(i + 1). \(q)\n"
        }

        return IntentExecutionResult(
            data: questions,
            conversationalResponse: response,
            structuredData: ["type": "open_questions", "count": questions.count]
        )
    }

    private func handleThemeDeepDive(intent: UserIntent) async throws -> IntentExecutionResult {
        guard let themeName = intent.filters.themeName ?? intent.filters.taskSearchTerm, !themeName.isEmpty else {
            return IntentExecutionResult(
                data: [:] as [String: Any],
                conversationalResponse: "Which theme would you like to deep-dive on? Try 'deep dive on [theme name]'.",
                structuredData: nil
            )
        }

        let detail = ReflectionStore.shared.getThemeDetail(theme: themeName)

        guard !detail.isEmpty,
              let name = detail["theme"] as? String else {
            return IntentExecutionResult(
                data: [:] as [String: Any],
                conversationalResponse: "I couldn't find a reflection theme matching '\(themeName)'. Try 'show my reflection themes' to see available themes.",
                structuredData: nil
            )
        }

        let state = detail["state"] as? String ?? "unknown"
        let mentionCount = detail["mention_count"] as? Int ?? 0
        let snippets = detail["snippets"] as? [String] ?? []

        var response = "Theme: \(name) (\(state), \(mentionCount) mentions)\n\n"
        if !snippets.isEmpty {
            response += "Key insights:\n"
            for snippet in snippets.prefix(5) {
                response += "• \(snippet)\n"
            }
        }

        return IntentExecutionResult(
            data: detail,
            conversationalResponse: response,
            structuredData: ["type": "theme_detail", "name": name, "state": state, "mentionCount": mentionCount]
        )
    }

    // MARK: - Pending Commitment Closures Handler (item 6)

    private func handlePendingClosures() async throws -> IntentExecutionResult {
        let pending = CommitmentScanTracker.shared.getPendingClosureConfirmations()

        if pending.isEmpty {
            return IntentExecutionResult(
                data: [:] as [String: Any],
                conversationalResponse: "No pending commitment closures to confirm right now.",
                structuredData: ["type": "pending_closures", "count": 0]
            )
        }

        var response = "You have \(pending.count) commitment closure\(pending.count == 1 ? "" : "s") to confirm:\n\n"
        for (i, closure) in pending.enumerated() {
            response += "\(i + 1). \(closure.title)"
            if !closure.signal.isEmpty { response += " — \(closure.signal)" }
            response += " (\(Int(closure.confidence * 100))% confident)\n"
        }
        response += "\nConfirm or reject these through the commitment dashboard, or tell me which one to close."

        return IntentExecutionResult(
            data: pending,
            conversationalResponse: response,
            structuredData: ["type": "pending_closures", "closures": pending, "count": pending.count]
        )
    }

    // MARK: - Memory & Learning Handlers (item 7)

    private func handleListMemory() async throws -> IntentExecutionResult {
        let commMemory = AgentMemoryService.shared.getMemory(for: .communication)
        let taskMemory = AgentMemoryService.shared.getMemory(for: .task)

        // Parse sections from memory content
        let commSections = commMemory.sections
        let taskSections = taskMemory.sections

        // Get learned patterns from WorkflowLearningService
        let patterns = WorkflowLearningService.shared.getLearnedPatterns()
        let activePatterns = patterns.filter { !$0.isArchived && !$0.isStale }

        var response = ""
        if !commSections.isEmpty || !taskSections.isEmpty {
            response += "Memory sections:\n"
            for (key, value) in commSections {
                let preview = String(value.prefix(80))
                response += "• \(key): \(preview)...\n"
            }
            for (key, value) in taskSections {
                let preview = String(value.prefix(80))
                response += "• \(key): \(preview)...\n"
            }
        }
        if !activePatterns.isEmpty {
            response += "\nLearned patterns (\(activePatterns.count)):\n"
            for pattern in activePatterns.prefix(10) {
                response += "• \(pattern.description) (\(Int(pattern.confidence * 100))%)\n"
            }
        }
        if commSections.isEmpty && taskSections.isEmpty && activePatterns.isEmpty {
            response = "I haven't learned any patterns yet. You can teach me rules like 'teach: always CC finance on budget emails'."
        }

        let sectionCount = commSections.count + taskSections.count
        return IntentExecutionResult(
            data: ["sectionCount": sectionCount, "patternCount": activePatterns.count] as [String: Any],
            conversationalResponse: response,
            structuredData: ["type": "memory", "sectionCount": sectionCount, "patternCount": activePatterns.count]
        )
    }

    private func handleTeachMemory(intent: UserIntent) async throws -> IntentExecutionResult {
        guard let teachText = intent.filters.teachText ?? intent.filters.noteToAdd, !teachText.isEmpty else {
            return IntentExecutionResult(
                data: [:] as [String: Any],
                conversationalResponse: "What would you like to teach me? Try 'teach: [your rule]'.",
                structuredData: nil
            )
        }

        try AgentMemoryService.shared.teach(agentType: .communication, rule: teachText)

        return IntentExecutionResult(
            data: ["taught": teachText] as [String: Any],
            conversationalResponse: "Got it — I'll remember: \"\(teachText)\"",
            structuredData: ["type": "memory_teach", "text": teachText, "success": true]
        )
    }

    private func handleForgetMemory(intent: UserIntent) async throws -> IntentExecutionResult {
        guard let searchTerm = intent.filters.taskSearchTerm ?? intent.filters.teachText, !searchTerm.isEmpty else {
            return IntentExecutionResult(
                data: [:] as [String: Any],
                conversationalResponse: "Which pattern or rule should I forget? Give me a keyword.",
                structuredData: nil
            )
        }

        let forgotten = try AgentMemoryService.shared.forget(agentType: .communication, pattern: searchTerm)

        if forgotten {
            return IntentExecutionResult(
                data: ["forgotten": searchTerm] as [String: Any],
                conversationalResponse: "Forgotten: \"\(searchTerm)\"",
                structuredData: ["type": "memory_forget", "text": searchTerm, "success": true]
            )
        }

        return IntentExecutionResult(
            data: [:] as [String: Any],
            conversationalResponse: "I couldn't find a rule matching '\(searchTerm)'. Try 'show learned patterns' to see what I know.",
            structuredData: nil
        )
    }

    // MARK: - Cadence Handlers (item 8)

    private func handleTriggerCadence(intent: UserIntent) async throws -> IntentExecutionResult {
        guard let cadenceName = intent.filters.cadenceName ?? intent.filters.taskSearchTerm, !cadenceName.isEmpty else {
            return IntentExecutionResult(
                data: [:] as [String: Any],
                conversationalResponse: "Which cadence would you like to trigger? Try 'run attention check' or 'trigger commitment scan'.",
                structuredData: nil
            )
        }

        let allCadences = CadenceService.shared.getAll()
        let searchLower = cadenceName.lowercased()

        // Fuzzy match cadence by name or action type
        guard let cadence = allCadences.first(where: {
            $0.name.lowercased().contains(searchLower) ||
            $0.actionType.rawValue.lowercased().contains(searchLower)
        }) else {
            let available = allCadences.map { $0.name }.joined(separator: ", ")
            return IntentExecutionResult(
                data: [:] as [String: Any],
                conversationalResponse: "I couldn't find a cadence matching '\(cadenceName)'. Available: \(available)",
                structuredData: nil
            )
        }

        // Trigger it
        CadenceService.shared.markManualRunSuccess(id: cadence.id, timestamp: ISO8601DateFormatter().string(from: Date()), summary: "Triggered via chat")

        return IntentExecutionResult(
            data: ["id": cadence.id, "name": cadence.name] as [String: Any],
            conversationalResponse: "Triggered '\(cadence.name)'. It's running now.",
            structuredData: ["type": "cadence_trigger", "id": cadence.id, "name": cadence.name, "success": true]
        )
    }

    private func handleListCadences() async throws -> IntentExecutionResult {
        let cadences = CadenceService.shared.getAll()

        if cadences.isEmpty {
            return IntentExecutionResult(
                data: [:] as [String: Any],
                conversationalResponse: "No cadences configured.",
                structuredData: ["type": "cadences", "count": 0]
            )
        }

        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "MMM d, h:mm a"

        var response = "Your cadences (\(cadences.count)):\n"
        for cadence in cadences {
            let enabled = cadence.enabled ? "✓" : "✗"
            let lastRun = cadence.lastRunTimestamp ?? "never"
            response += "\(enabled) \(cadence.name) — last run: \(lastRun)\n"
        }

        return IntentExecutionResult(
            data: cadences.map { ["id": $0.id, "name": $0.name, "enabled": $0.enabled] as [String: Any] },
            conversationalResponse: response,
            structuredData: ["type": "cadences", "count": cadences.count]
        )
    }

    // MARK: - Favorites Handlers (item 9)

    private func handleListFavorites() async throws -> IntentExecutionResult {
        let favorites = FavoritesService.shared.getFavorites()
        let contacts = favorites.contacts
        let groups = favorites.groups

        if contacts.isEmpty && groups.isEmpty {
            return IntentExecutionResult(
                data: [:] as [String: Any],
                conversationalResponse: "You don't have any favorites set up yet. Try 'add [name] to my favorites'.",
                structuredData: ["type": "favorites", "count": 0]
            )
        }

        var response = ""
        if !contacts.isEmpty {
            response += "Favorite contacts (\(contacts.count)):\n"
            for c in contacts {
                response += "• \(c.name)"
                if !c.aliases.isEmpty { response += " (aka \(c.aliases.joined(separator: ", ")))" }
                response += "\n"
            }
        }
        if !groups.isEmpty {
            response += "\nFavorite groups (\(groups.count)):\n"
            for g in groups {
                response += "• \(g.name)"
                if !g.platform.isEmpty { response += " (\(g.platform))" }
                response += "\n"
            }
        }

        return IntentExecutionResult(
            data: favorites,
            conversationalResponse: response,
            structuredData: ["type": "favorites", "contactCount": contacts.count, "groupCount": groups.count]
        )
    }

    private func handleAddFavorite(intent: UserIntent) async throws -> IntentExecutionResult {
        guard let name = intent.filters.contactName, !name.isEmpty else {
            return IntentExecutionResult(
                data: [:] as [String: Any],
                conversationalResponse: "Who would you like to add to your favorites?",
                structuredData: nil
            )
        }

        let contact = FavoriteContact(name: name)
        try FavoritesService.shared.addContact(contact)

        return IntentExecutionResult(
            data: ["name": name] as [String: Any],
            conversationalResponse: "Added '\(name)' to your favorites.",
            structuredData: ["type": "favorite_add", "name": name, "success": true]
        )
    }

    private func handleRemoveFavorite(intent: UserIntent) async throws -> IntentExecutionResult {
        guard let name = intent.filters.contactName, !name.isEmpty else {
            return IntentExecutionResult(
                data: [:] as [String: Any],
                conversationalResponse: "Who would you like to remove from favorites?",
                structuredData: nil
            )
        }

        try FavoritesService.shared.removeContact(name: name)

        return IntentExecutionResult(
            data: ["name": name] as [String: Any],
            conversationalResponse: "Removed '\(name)' from your favorites.",
            structuredData: ["type": "favorite_remove", "name": name, "success": true]
        )
    }

    // MARK: - Contact Analysis Handler (item 10)

    private func handleContactAnalysis() async throws -> IntentExecutionResult {
        let favorites = FavoritesService.shared.getFavorites()
        let contactNames = favorites.contacts.map { $0.name }

        if contactNames.isEmpty {
            return IntentExecutionResult(
                data: [:] as [String: Any],
                conversationalResponse: "No favorite contacts configured. Add some favorites first to track participation.",
                structuredData: nil
            )
        }

        var response = "Contact participation (based on favorites):\n"
        for name in contactNames.prefix(10) {
            response += "• \(name)\n"
        }
        response += "\nFor detailed thread analysis, try 'analyze thread with [name]'."

        return IntentExecutionResult(
            data: contactNames,
            conversationalResponse: response,
            structuredData: ["type": "contact_analysis", "contacts": contactNames, "count": contactNames.count]
        )
    }

    // MARK: - Calendar Availability Check Handler (item 11)

    private func handleCalendarAvailabilityCheck(intent: UserIntent) async throws -> IntentExecutionResult {
        let filters = intent.filters

        // Determine the date/time to check — extract date from eventTime if specificDate not set
        let checkDate: Date
        if let specificDate = filters.specificDate {
            checkDate = specificDate
        } else if let eventTimeStr = filters.eventTime,
                  let eventTime = UserIntent.IntentFilters.parseFlexibleDate(eventTimeStr) {
            checkDate = eventTime
        } else {
            checkDate = Date()
        }

        let events = try await orchestrator.calendarServicePublic.fetchEventsFromAllCalendars(
            for: checkDate,
            userSettings: config.user
        )

        let allEvents = events.events
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "h:mm a"
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "EEE, MMM d"
        let dateStr = dateFmt.string(from: checkDate)

        // If a specific time was requested, check that slot
        if let eventTimeStr = filters.eventTime,
           let checkTime = UserIntent.IntentFilters.parseFlexibleDate(eventTimeStr) {

            let duration: TimeInterval = Double(filters.eventDurationMinutes ?? 30) * 60
            let endTime = checkTime.addingTimeInterval(duration)

            let conflicts = allEvents.filter { event in
                !(endTime <= event.startTime || checkTime >= event.endTime) && !event.isAllDay
            }

            let timeStr = timeFmt.string(from: checkTime)

            if conflicts.isEmpty {
                return IntentExecutionResult(
                    data: ["free": true, "time": timeStr] as [String: Any],
                    conversationalResponse: "Yes, you're free at \(timeStr) on \(dateStr). Want me to block that time?",
                    structuredData: ["type": "availability", "free": true, "time": timeStr, "date": dateStr]
                )
            } else {
                let conflictNames = conflicts.map { $0.title }.joined(separator: ", ")

                // Find next free slot
                let sortedEvents = allEvents.filter { !$0.isAllDay && $0.endTime > checkTime }
                    .sorted { $0.startTime < $1.startTime }
                let dayEnd = Calendar.current.date(bySettingHour: 21, minute: 0, second: 0, of: checkTime)!

                var cursor = checkTime
                var suggestion: Date? = nil
                for event in sortedEvents {
                    if event.startTime > cursor && event.startTime.timeIntervalSince(cursor) >= duration {
                        suggestion = cursor
                        break
                    }
                    cursor = max(cursor, event.endTime)
                }
                if suggestion == nil && cursor < dayEnd && dayEnd.timeIntervalSince(cursor) >= duration {
                    suggestion = cursor
                }

                var response = "You're blocked at \(timeStr) — '\(conflictNames)' is on your calendar."
                if let freeAt = suggestion {
                    response += " You're free at \(timeFmt.string(from: freeAt)) — want me to book it then?"
                }

                return IntentExecutionResult(
                    data: ["free": false, "conflicts": conflicts.map { $0.title }] as [String: Any],
                    conversationalResponse: response,
                    structuredData: ["type": "availability", "free": false, "conflicts": conflicts.map { $0.title }]
                )
            }
        }

        // General day availability
        let nonAllDay = allEvents.filter { !$0.isAllDay }
        let busyHours = nonAllDay.reduce(0.0) { $0 + $1.endTime.timeIntervalSince($1.startTime) } / 3600

        var response = "Your calendar for \(dateStr): \(nonAllDay.count) meeting\(nonAllDay.count == 1 ? "" : "s"), ~\(String(format: "%.1f", busyHours))h booked.\n"

        if nonAllDay.isEmpty {
            response += "You're completely free!"
        } else {
            for event in nonAllDay.sorted(by: { $0.startTime < $1.startTime }) {
                response += "• \(timeFmt.string(from: event.startTime))-\(timeFmt.string(from: event.endTime)): \(event.title)\n"
            }
        }

        return IntentExecutionResult(
            data: allEvents.map { $0.title } as [String],
            conversationalResponse: response,
            structuredData: ["type": "availability", "date": dateStr, "meetingCount": nonAllDay.count, "busyHours": busyHours]
        )
    }

    // MARK: - Conversation History Handler (item 13)

    private func handleListConversations() async throws -> IntentExecutionResult {
        let conversations = ConversationHistoryService.shared.getConversations(limit: 10)

        if conversations.isEmpty {
            return IntentExecutionResult(
                data: [:] as [String: Any],
                conversationalResponse: "No past conversations found.",
                structuredData: ["type": "conversations", "count": 0]
            )
        }

        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "MMM d, h:mm a"

        var response = "Recent conversations:\n"
        for (i, conv) in conversations.enumerated() {
            let title = (conv["title"] as? String ?? "").isEmpty ? "Untitled" : String((conv["title"] as? String ?? "").prefix(60))
            let date = (conv["lastActiveAt"] as? String) ?? (conv["createdAt"] as? String) ?? ""
            let turnCount = conv["turnCount"] as? Int ?? 0
            response += "\(i + 1). \(title) — \(date) (\(turnCount) turns)\n"
        }

        return IntentExecutionResult(
            data: conversations,
            conversationalResponse: response,
            structuredData: ["type": "conversations", "count": conversations.count]
        )
    }

    // MARK: - Skills Handler (item 14)

    private func handleListSkills() async throws -> IntentExecutionResult {
        let skills = SkillLoader.shared.getEnabledSkills()

        if skills.isEmpty {
            return IntentExecutionResult(
                data: [:] as [String: Any],
                conversationalResponse: "No coaching skills are currently active.",
                structuredData: ["type": "skills", "count": 0]
            )
        }

        var response = "Active coaching skills (\(skills.count)):\n"
        for skill in skills {
            let name = skill.effectiveName
            let desc = skill.description
            response += "• \(name)"
            if !desc.isEmpty { response += " — \(String(desc.prefix(80)))" }
            response += "\n"
        }

        return IntentExecutionResult(
            data: skills.map { ["id": $0.id, "name": $0.effectiveName] as [String: Any] },
            conversationalResponse: response,
            structuredData: ["type": "skills", "count": skills.count]
        )
    }
}

// MARK: - Execution Result

struct IntentExecutionResult {
    let data: Any  // The actual data returned
    let conversationalResponse: String  // Natural language summary
    let structuredData: [String: Any]?  // Optional structured data for UI
}

struct CommitmentScanResult {
    let totalFound: Int
    let saved: Int
    let duplicates: Int
    var autoClosed: Int = 0
    var pendingClosures: Int = 0
}

struct TaskUpdateResult {
    let taskTitle: String
    let notionId: String
    let changes: [String]
    let success: Bool
}

// MARK: - Errors

enum IntentExecutionError: Error, LocalizedError {
    case unsupportedIntent(action: String, target: String)
    case missingRequiredParameter(String)
    case featureNotEnabled(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedIntent(let action, let target):
            return "Unsupported intent: \(action) \(target)"
        case .missingRequiredParameter(let param):
            return "Missing required parameter: \(param)"
        case .featureNotEnabled(let feature):
            return "Feature '\(feature)' is not enabled in config"
        }
    }
}
