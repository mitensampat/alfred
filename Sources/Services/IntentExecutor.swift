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
    func execute(_ intent: UserIntent) async throws -> IntentExecutionResult {
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
            let commitments = try await fetchCommitments(
                type: intent.filters.commitmentType,
                contactName: intent.filters.contactName
            )
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
        case (.list, .tasks):
            let typeFilter: TaskItem.TaskType? = intent.filters.taskType.flatMap { TaskItem.TaskType(rawValue: $0) }
            let tasks = try await orchestrator.notionServicePublic.queryActiveTasks(type: typeFilter)
            return formatTaskListResponse(tasks, query: intent.originalQuery)

        case (.search, .tasks), (.find, .tasks):
            guard let searchTerm = intent.filters.taskSearchTerm, !searchTerm.isEmpty else {
                return IntentExecutionResult(
                    data: [:] as [String: Any],
                    conversationalResponse: "What task are you looking for? Give me a name or keyword.",
                    structuredData: nil
                )
            }
            let tasks = try await orchestrator.notionServicePublic.findTasksByFuzzyTitle(searchTerm)
            return formatTaskSearchResponse(tasks, searchTerm: searchTerm, query: intent.originalQuery)

        case (.create, .tasks), (.create, .todos):
            return try await handleCreateTask(intent: intent)

        case (.delete, .tasks):
            return try await handleTaskDeletion(intent: intent)

        case (.update, .tasks), (.update, .commitments):
            return try await handleTaskUpdate(intent: intent)

        case (.check, .tasks):
            let stats = TaskLifecycleTracker.shared.getStats()
            return formatTaskStatsResponse(stats, query: intent.originalQuery)

        // MARK: - Calendar Event Creation
        case (.create, .calendar):
            return try await handleCreateCalendarEvent(intent: intent)

        // MARK: - Commitment Actions (check overdue)
        case (.check, .commitments):
            let overdue = try await orchestrator.notionServicePublic.queryOverdueCommitmentsFromTasks()
            return formatOverdueCommitmentsResponse(overdue, query: intent.originalQuery)

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

        case (_, nil):
            let actionHint: String
            switch intent.action {
            case .list: actionHint = "You can list your tasks, commitments, calendar, messages, todos, or drafts."
            case .create: actionHint = "You can create a task, todo, or calendar event."
            case .update: actionHint = "You can update a task or commitment."
            case .generate: actionHint = "You can generate a briefing, attention check, or draft responses."
            case .scan: actionHint = "You can scan for commitments or todos."
            case .check: actionHint = "You can check your attention, tasks, or commitments."
            case .search, .find: actionHint = "You can search for tasks, commitments, or specific threads."
            case .delete: actionHint = "You can cancel a task."
            case .summarize: actionHint = "You can summarize a message thread or get a weekly reflection."
            case .analyze: actionHint = "You can analyze a specific message thread."
            }
            return IntentExecutionResult(
                data: [:] as [String: Any],
                conversationalResponse: "I'd like to help! \(actionHint) What would you like?",
                structuredData: nil
            )

        default:
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
        // TODO: Implement conversational formatting
        return IntentExecutionResult(data: briefing, conversationalResponse: "Here's your briefing", structuredData: nil)
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

    private func formatTaskListResponse(_ tasks: [TaskItem], query: String) -> IntentExecutionResult {
        if tasks.isEmpty {
            return IntentExecutionResult(
                data: tasks,
                conversationalResponse: "You have no active tasks right now.",
                structuredData: nil
            )
        }

        var response = "You have \(tasks.count) active task\(tasks.count == 1 ? "" : "s"):\n\n"

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
            return "I can help with your favorites. Try 'show my favorite contacts'."
        case .preferences:
            return "Settings changes should be made through the Alfred web UI."
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

        // Create the event
        let createdEvent = try await calendarService.createEvent(
            title: title,
            startTime: startTime,
            endTime: endTime,
            location: filters.eventLocation,
            description: filters.eventDescription
        )

        // Format times for display
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "h:mm a"
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "EEE, MMM d"

        let timeRange = "\(timeFmt.string(from: startTime)) – \(timeFmt.string(from: endTime))"
        let dateStr = dateFmt.string(from: startTime)

        var summary = "Created '\(title)' on \(dateStr), \(timeRange)"
        if let loc = filters.eventLocation { summary += " at \(loc)" }
        summary += "."
        summary += "\n\nShare this link so others can add it to their calendar:\n\(createdEvent.shareableLink)"

        return IntentExecutionResult(
            data: createdEvent,
            conversationalResponse: summary,
            structuredData: [
                "type": "calendar_create",
                "title": title,
                "date": dateStr,
                "timeRange": timeRange,
                "location": filters.eventLocation ?? "",
                "shareableLink": createdEvent.shareableLink,
                "htmlLink": createdEvent.htmlLink,
                "success": true
            ]
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
