import Foundation
import CryptoKit

class BriefingOrchestrator {
    let config: AppConfig
    private let imessageReader: iMessageReader
    private let whatsappReader: WhatsAppReader
    private let signalReader: SignalReader
    private let calendarService: MultiCalendarService
    private let aiService: ClaudeAIService
    private let researchService: ResearchService
    private let notificationService: NotificationService
    private let notionService: NotionService
    private let commitmentAnalyzer: CommitmentAnalyzer

    // Public access to NotionService for GUI features
    var notionServicePublic: NotionService { notionService }
    var commitmentAnalyzerPublic: CommitmentAnalyzer { commitmentAnalyzer }

    init(config: AppConfig) {
        self.config = config

        self.imessageReader = iMessageReader(dbPath: config.messaging.imessage.dbPath)
        self.whatsappReader = WhatsAppReader(dbPath: config.messaging.whatsapp.dbPath)
        self.signalReader = SignalReader(dbPath: config.messaging.signal.dbPath)
        self.calendarService = MultiCalendarService(configs: config.calendar.google)
        self.aiService = ClaudeAIService(config: config.ai)
        self.researchService = ResearchService(config: config, aiService: aiService)
        self.notificationService = NotificationService(config: config.notifications)
        self.notionService = NotionService(config: config.notion)
        self.commitmentAnalyzer = CommitmentAnalyzer(
            anthropicApiKey: config.ai.anthropicApiKey,
            model: config.ai.model,
            userInfo: CommitmentAnalyzer.UserInfo(
                name: config.user.name,
                email: config.user.email
            )
        )
    }

    // MARK: - Morning Briefing

    func generateMorningBriefing() async throws -> DailyBriefing {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        return try await generateBriefing(for: tomorrow, sendEmail: true)
    }

    func generateBriefing(for date: Date, sendEmail: Bool = false) async throws -> DailyBriefing {
        print("\n🚀 Generating briefing for \(date.formatted(date: .abbreviated, time: .omitted))...\n")

        // 1. Fetch messages from last 24 hours
        print("💬 Analyzing messages from last 24 hours...")
        let messagingSummary = try await fetchAndAnalyzeMessages()
        print("✓ Message analysis complete\n")

        // 2. Fetch calendar for specified date from all calendars
        let schedule = try await calendarService.fetchEventsFromAllCalendars(for: date, userSettings: config.user)
        print("")

        // 3. Generate meeting briefings for external meetings
        var meetingBriefings: [MeetingBriefing] = []
        if !schedule.externalMeetings.isEmpty {
            print("👥 Generating briefings for \(schedule.externalMeetings.count) external meeting(s)...")
            for (index, event) in schedule.externalMeetings.enumerated() {
                print("  ↳ Researching attendees for '\(event.title)' (\(index + 1)/\(schedule.externalMeetings.count))...")
                let attendeeBriefings = try await researchService.researchAttendees(event.externalAttendees)
                let briefing = try await aiService.generateMeetingBriefing(event, attendees: attendeeBriefings)
                meetingBriefings.append(briefing)
            }
            print("✓ Meeting briefings complete\n")
        }

        let calendarBriefing = CalendarBriefing(
            schedule: schedule,
            meetingBriefings: meetingBriefings,
            focusTime: schedule.freeSlots.reduce(0) { $0 + $1.duration },
            recommendations: generateScheduleRecommendations(schedule)
        )

        // 4. Query Notion for context (if configured)
        var notionNotes: [NotionNote] = []
        var notionTasks: [NotionTask] = []

        if let briefingSources = config.notion.briefingSources {
            // Query notes database
            if let notesDatabaseId = briefingSources.notesDatabaseId, notesDatabaseId != "YOUR_NOTES_DATABASE_ID" {
                print("📓 Querying Notion notes for context...")
                do {
                    let context = generateBriefingContext(messagingSummary: messagingSummary, schedule: schedule)
                    notionNotes = try await notionService.queryRelevantNotes(context: context, databaseId: notesDatabaseId)
                    print("✓ Found \(notionNotes.count) relevant note(s)\n")
                } catch {
                    print("⚠️  Failed to query notes: \(error)\n")
                }
            }

            // Query tasks database
            if let tasksDatabaseId = briefingSources.tasksDatabaseId, tasksDatabaseId != "YOUR_TASKS_DATABASE_ID" {
                print("✅ Querying Notion for active tasks...")
                do {
                    notionTasks = try await notionService.queryActiveTasks(databaseId: tasksDatabaseId)
                    print("✓ Found \(notionTasks.count) active task(s)\n")
                } catch {
                    print("⚠️  Failed to query tasks: \(error)\n")
                }
            }
        }

        // 5. Extract action items
        let actionItems = extractActionItems(from: messagingSummary, and: calendarBriefing, notionTasks: notionTasks)

        let briefing = DailyBriefing(
            date: date,
            messagingSummary: messagingSummary,
            calendarBriefing: calendarBriefing,
            actionItems: actionItems,
            notionContext: NotionContext(notes: notionNotes, tasks: notionTasks),
            generatedAt: Date()
        )

        // 5. Send notifications only if requested
        if sendEmail {
            print("📧 Sending briefing via email...")
            try await notificationService.sendBriefing(briefing)
            print("✓ Email sent successfully\n")
        }

        return briefing
    }

    // MARK: - Calendar Briefing

    func getCalendarBriefing(for date: Date, calendar: String = "all") async throws -> CalendarBriefing {
        print("📅 Fetching \(calendar) calendar for \(date.formatted(date: .long, time: .omitted))...\n")

        // Fetch calendar events from specified calendar(s)
        let schedule = try await calendarService.fetchEvents(for: date, userSettings: config.user, calendarFilter: calendar)
        print("")

        // Query Notion for context (if configured)
        var notionNotes: [NotionNote] = []
        var notionTasks: [NotionTask] = []

        if let briefingSources = config.notion.briefingSources {
            // Query notes database
            if let notesDatabaseId = briefingSources.notesDatabaseId, notesDatabaseId != "YOUR_NOTES_DATABASE_ID" {
                print("📓 Querying Notion notes for context...")
                do {
                    let context = generateCalendarContext(schedule: schedule)
                    notionNotes = try await notionService.queryRelevantNotes(context: context, databaseId: notesDatabaseId)
                    print("✓ Found \(notionNotes.count) relevant note(s)\n")
                } catch {
                    print("⚠️  Failed to query notes: \(error)\n")
                }
            }

            // Query tasks database
            if let tasksDatabaseId = briefingSources.tasksDatabaseId, tasksDatabaseId != "YOUR_TASKS_DATABASE_ID" {
                print("✅ Querying Notion for active tasks...")
                do {
                    notionTasks = try await notionService.queryActiveTasks(databaseId: tasksDatabaseId)
                    print("✓ Found \(notionTasks.count) active task(s)\n")
                } catch {
                    print("⚠️  Failed to query tasks: \(error)\n")
                }
            }
        }

        // Generate meeting briefings for external meetings
        var meetingBriefings: [MeetingBriefing] = []
        if !schedule.externalMeetings.isEmpty {
            print("👥 Generating briefings for \(schedule.externalMeetings.count) external meeting(s)...")
            for (index, event) in schedule.externalMeetings.enumerated() {
                print("  ↳ Researching attendees for '\(event.title)' (\(index + 1)/\(schedule.externalMeetings.count))...")
                let attendeeBriefings = try await researchService.researchAttendees(event.externalAttendees)

                // Include Notion context in meeting briefing
                let briefing = try await aiService.generateMeetingBriefing(
                    event,
                    attendees: attendeeBriefings,
                    notionNotes: notionNotes,
                    notionTasks: notionTasks
                )
                meetingBriefings.append(briefing)
            }
            print("✓ Meeting briefings complete\n")
        }

        let calendarBriefing = CalendarBriefing(
            schedule: schedule,
            meetingBriefings: meetingBriefings,
            focusTime: schedule.freeSlots.reduce(0) { $0 + $1.duration },
            recommendations: generateScheduleRecommendations(schedule)
        )

        print("✓ Calendar briefing ready\n")

        return calendarBriefing
    }

    private func generateCalendarContext(schedule: DailySchedule) -> String {
        var context = "Calendar context:\n"
        context += "- Total meetings: \(schedule.events.count)\n"
        context += "- External meetings: \(schedule.externalMeetings.map { $0.title }.joined(separator: ", "))\n"
        context += "- Focus time: \(schedule.freeSlots.reduce(0) { $0 + $1.duration } / 3600) hours\n"
        return context
    }

    // MARK: - Messages Summary

    func getMessagesSummary(platform: String, timeframe: String) async throws -> [MessageSummary] {
        let hours = parseTimeframe(timeframe)
        let since = Calendar.current.date(byAdding: .hour, value: -hours, to: Date())!

        print("💬 Fetching \(platform) messages from last \(timeframe)...\n")

        var allThreads: [MessageThread] = []

        // Fetch based on platform filter
        if platform == "all" || platform == "imessage" {
            if config.messaging.imessage.enabled {
                print("  ↳ Reading iMessage database...")
                do {
                    try imessageReader.connect()
                    let threads = try imessageReader.fetchThreads(since: since)
                    allThreads.append(contentsOf: threads)
                    imessageReader.disconnect()
                    print("  ✓ Found \(threads.count) iMessage thread(s)")
                } catch {
                    print("  ✗ Failed to fetch iMessages: \(error)")
                }
            }
        }

        if platform == "all" || platform == "whatsapp" {
            if config.messaging.whatsapp.enabled {
                print("  ↳ Reading WhatsApp database...")
                do {
                    try whatsappReader.connect()
                    let threads = try whatsappReader.fetchThreads(since: since)
                    allThreads.append(contentsOf: threads)
                    whatsappReader.disconnect()
                    print("  ✓ Found \(threads.count) WhatsApp thread(s)")
                } catch {
                    print("  ✗ Failed to fetch WhatsApp messages: \(error)")
                }
            }
        }

        if platform == "all" || platform == "signal" {
            if config.messaging.signal.enabled {
                print("  ↳ Reading Signal database...")
                do {
                    try signalReader.connect()
                    let threads = try signalReader.fetchThreads(since: since)
                    allThreads.append(contentsOf: threads)
                    signalReader.disconnect()
                    print("  ✓ Found \(threads.count) Signal thread(s)")
                } catch {
                    print("  ✗ Failed to fetch Signal messages: \(error)")
                }
            }
        }

        print("\n📊 Total threads: \(allThreads.count)\n")

        if allThreads.isEmpty {
            print("ℹ️  No messages found in the specified timeframe\n")
            return []
        }

        print("🤖 Analyzing messages with AI...")
        let summaries = try await aiService.analyzeMessages(allThreads)
        print("✓ Analysis complete\n")

        return summaries
    }

    func getFocusedWhatsAppThread(contactName: String, timeframe: String) async throws -> FocusedThreadAnalysis {
        let hours = parseTimeframe(timeframe)
        let since = Calendar.current.date(byAdding: .hour, value: -hours, to: Date())!

        print("💬 Searching for WhatsApp thread: \"\(contactName)\" (last \(timeframe))...\n")

        guard config.messaging.whatsapp.enabled else {
            throw MessageReaderError.notConnected
        }

        print("  ↳ Connecting to WhatsApp database...")
        try whatsappReader.connect()
        defer {
            whatsappReader.disconnect()
        }

        print("  ↳ Searching for contact/group: \"\(contactName)\"...")
        guard let thread = try whatsappReader.fetchThreadByName(contactName, since: since) else {
            print("  ✗ No matching WhatsApp thread found for \"\(contactName)\"")
            throw MessageReaderError.queryFailed("No WhatsApp thread found matching '\(contactName)'")
        }

        print("  ✓ Found thread with \(thread.messages.count) message(s)")
        print("  ✓ Contact: \(thread.contactName ?? "Unknown")\n")

        print("🤖 Analyzing thread with AI...")
        let analysis = try await aiService.analyzeFocusedThread(thread)
        print("✓ Analysis complete\n")

        return analysis
    }

    private func parseTimeframe(_ timeframe: String) -> Int {
        let value = Int(timeframe.dropLast()) ?? 24
        let unit = timeframe.last?.lowercased()

        switch unit {
        case "h": return value
        case "d": return value * 24
        case "w": return value * 24 * 7
        default: return 24
        }
    }

    // MARK: - Attention Defense Alert (3pm)

    func generateAttentionDefenseAlert(sendEmail: Bool = true) async throws -> AttentionDefenseReport {
        print("Generating attention defense alert...")

        // 1. Get current action items
        let today = Date()
        let schedule = try await calendarService.fetchEventsFromAllCalendars(for: today, userSettings: config.user)

        // For demo purposes, we'll use placeholder action items
        // In a real app, these would be persisted and tracked
        let actionItems = loadStoredActionItems()

        // 2. Use AI to analyze what can be pushed off
        let report = try await aiService.generateAttentionDefenseReport(
            actionItems: actionItems,
            schedule: schedule,
            currentTime: Date()
        )

        // 3. Send alert only if requested
        if sendEmail {
            try await notificationService.sendAttentionDefenseReport(report)
        }

        return report
    }

    // MARK: - Private Helpers

    private func fetchAndAnalyzeMessages() async throws -> MessagingSummary {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!

        var allThreads: [MessageThread] = []

        // Fetch from all enabled platforms
        if config.messaging.imessage.enabled {
            do {
                try imessageReader.connect()
                let threads = try imessageReader.fetchThreads(since: yesterday)
                allThreads.append(contentsOf: threads)
                imessageReader.disconnect()
            } catch {
                print("Warning: Failed to fetch iMessages: \(error)")
            }
        }

        if config.messaging.whatsapp.enabled {
            do {
                try whatsappReader.connect()
                let threads = try whatsappReader.fetchThreads(since: yesterday)
                allThreads.append(contentsOf: threads)
                whatsappReader.disconnect()
            } catch {
                print("Warning: Failed to fetch WhatsApp messages: \(error)")
            }
        }

        if config.messaging.signal.enabled {
            do {
                try signalReader.connect()
                let threads = try signalReader.fetchThreads(since: yesterday)
                allThreads.append(contentsOf: threads)
                signalReader.disconnect()
            } catch {
                print("Warning: Failed to fetch Signal messages: \(error)")
            }
        }

        // Smart filtering: prioritize threads for analysis
        let filteredThreads = prioritizeThreads(allThreads, maxCount: config.ai.effectiveMaxThreads)
        print("  📊 Filtered to top \(filteredThreads.count) threads for analysis (from \(allThreads.count) total)")

        // Analyze threads with AI
        let summaries = try await aiService.analyzeMessages(filteredThreads)

        // Categorize summaries
        let keyInteractions = summaries.filter { $0.urgency >= .medium }.prefix(10)
        let needsResponse = summaries.filter { $0.thread.needsResponse }
        let criticalMessages = summaries.filter { $0.urgency == .critical }

        let stats = MessagingSummary.MessagingStats(
            totalMessages: allThreads.flatMap { $0.messages }.count,
            unreadMessages: allThreads.reduce(0) { $0 + $1.unreadCount },
            threadsNeedingResponse: needsResponse.count,
            byPlatform: Dictionary(grouping: allThreads, by: { $0.platform })
                .mapValues { $0.flatMap { $0.messages }.count }
        )

        return MessagingSummary(
            keyInteractions: Array(keyInteractions),
            needsResponse: Array(needsResponse),
            criticalMessages: Array(criticalMessages),
            stats: stats
        )
    }

    private func prioritizeThreads(_ threads: [MessageThread], maxCount: Int) -> [MessageThread] {
        // Score threads based on multiple factors
        let scoredThreads = threads.map { thread -> (thread: MessageThread, score: Double) in
            var score: Double = 0

            // Factor 1: Recency (most recent message)
            let hoursSinceLastMessage = Date().timeIntervalSince(thread.lastMessageDate) / 3600
            score += max(0, 100 - hoursSinceLastMessage) // Up to 100 points for very recent

            // Factor 2: Message volume in thread
            score += Double(min(thread.messages.count, 10)) * 5 // Up to 50 points

            // Factor 3: Is it a 1:1 conversation? (higher priority)
            let isOneOnOne = thread.contactName != nil && !thread.contactIdentifier.contains(",") && !thread.contactIdentifier.contains("group")
            if isOneOnOne {
                score += 50
            }

            // Factor 4: Unread count
            score += Double(min(thread.unreadCount, 5)) * 10 // Up to 50 points

            // Factor 5: Penalize very old threads
            if hoursSinceLastMessage > 24 {
                score *= 0.5 // Cut score in half for messages over 24h old
            }

            return (thread: thread, score: score)
        }

        // Sort by score and take top N
        return scoredThreads
            .sorted { $0.score > $1.score }
            .prefix(maxCount)
            .map { $0.thread }
    }

    private func generateScheduleRecommendations(_ schedule: DailySchedule) -> [String] {
        var recommendations: [String] = []

        let totalHours = schedule.totalMeetingTime / 3600
        if totalHours > 6 {
            recommendations.append("Heavy meeting day (\(Int(totalHours))h) - consider time-boxing discussions")
        }

        if schedule.freeSlots.isEmpty {
            recommendations.append("No focus time available - consider declining non-essential meetings")
        } else {
            let longestSlot = schedule.freeSlots.max(by: { $0.duration < $1.duration })
            if let slot = longestSlot, slot.duration >= 7200 {
                recommendations.append("Deep work opportunity: \(Int(slot.duration/3600))h free block at \(slot.start.formatted(.dateTime.hour().minute()))")
            }
        }

        if schedule.externalMeetings.count > 3 {
            recommendations.append("Multiple external meetings - review briefings before each")
        }

        return recommendations
    }

    private func generateBriefingContext(messagingSummary: MessagingSummary, schedule: DailySchedule) -> String {
        var context = "Briefing context:\n"
        context += "- Meetings today: \(schedule.events.count)\n"
        context += "- Critical messages: \(messagingSummary.criticalMessages.count)\n"
        context += "- External meetings: \(schedule.externalMeetings.map { $0.title }.joined(separator: ", "))\n"
        return context
    }

    private func extractActionItems(from messaging: MessagingSummary, and calendar: CalendarBriefing, notionTasks: [NotionTask] = []) -> [ActionItem] {
        var items: [ActionItem] = []

        // Extract from critical messages
        for summary in messaging.criticalMessages {
            for (index, actionText) in summary.actionItems.enumerated() {
                let item = ActionItem(
                    id: "\(summary.thread.contactIdentifier)_action_\(index)",
                    title: "Respond to \(summary.thread.contactName ?? "Unknown")",
                    description: actionText,
                    source: .message,
                    priority: summary.urgency,
                    dueDate: Calendar.current.date(byAdding: .hour, value: 24, to: Date()),
                    estimatedDuration: 600,
                    category: .respond
                )
                items.append(item)
            }
        }

        // Extract from messages needing response
        for summary in messaging.needsResponse.prefix(5) {
            let item = ActionItem(
                id: "\(summary.thread.contactIdentifier)_response",
                title: "Reply to \(summary.thread.contactName ?? "Unknown")",
                description: summary.summary,
                source: .message,
                priority: summary.urgency,
                dueDate: Calendar.current.date(byAdding: .hour, value: 12, to: Date()),
                estimatedDuration: 300,
                category: .respond
            )
            items.append(item)
        }

        // Extract from meetings
        for briefing in calendar.meetingBriefings {
            let item = ActionItem(
                id: "\(briefing.event.id)_prep",
                title: "Prepare for: \(briefing.event.title)",
                description: briefing.preparation,
                source: .meeting,
                priority: .high,
                dueDate: Calendar.current.date(byAdding: .minute, value: -30, to: briefing.event.startTime),
                estimatedDuration: 900,
                category: .prepare
            )
            items.append(item)
        }

        return items.sorted { $0.priority > $1.priority }
    }

    private func loadStoredActionItems() -> [ActionItem] {
        // In a real implementation, load from persistent storage
        // For now, return empty array
        return []
    }

    // MARK: - Notion Integration

    func processWhatsAppTodos(lookbackDays: Int = 7) async throws -> TodoScanResult {
        print("\n📝 Processing WhatsApp messages for todos...\n")

        // Fetch WhatsApp messages from specified lookback period
        let since = Calendar.current.date(byAdding: .day, value: -lookbackDays, to: Date())!
        print("  ↳ Scanning last \(lookbackDays) days...\n")

        guard config.messaging.whatsapp.enabled else {
            print("  ⚠️  WhatsApp is not enabled in config")
            return TodoScanResult(messagesScanned: 0, todosFound: 0, todosCreated: 0, duplicatesSkipped: 0, notTodos: 0, createdTodos: [], lookbackDays: lookbackDays)
        }

        print("  ↳ Reading WhatsApp database...")
        try whatsappReader.connect()
        let threads = try whatsappReader.fetchThreads(since: since)
        whatsappReader.disconnect()

        // Filter for messages to yourself (self)
        print("  ↳ All thread names found:")
        for thread in threads {
            print("    • \(thread.contactName ?? "Unknown")")
        }

        let selfThreads = threads.filter { thread in
            isSelfThread(thread, userFullName: config.user.name)
        }

        print("  ✓ Found \(selfThreads.count) thread(s) with yourself (using name: \(config.user.name))\n")

        if selfThreads.isEmpty {
            print("  ℹ️  No messages to yourself found")
            return TodoScanResult(messagesScanned: 0, todosFound: 0, todosCreated: 0, duplicatesSkipped: 0, notTodos: 0, createdTodos: [], lookbackDays: lookbackDays)
        }

        // Fetch existing todos from Notion for duplication check
        print("  ↳ Checking existing todos in Notion...")
        let existingTitles = (try? await notionService.searchExistingTodos(title: "")) ?? []
        print("  ✓ Found \(existingTitles.count) existing todo(s)\n")

        // Extract todos from outgoing messages
        var createdTodos: [TodoItem] = []
        var allFoundTodos: [TodoItem] = []
        var processedCount = 0
        var skippedDuplicates = 0
        var notTodoCount = 0

        for thread in selfThreads {
            let outgoingMessages = thread.messages.filter { $0.direction == .outgoing }

            for message in outgoingMessages {
                processedCount += 1
                print("  ↳ Analyzing message \(processedCount): \"\(String(message.content.prefix(50)))\(message.content.count > 50 ? "..." : "")\"")

                if let todo = try await aiService.extractTodoFromMessage(message) {
                    print("    ✓ Detected todo: \(todo.title)")
                    allFoundTodos.append(todo)

                    // Check for duplicates
                    let isDuplicate = existingTitles.contains { existingTitle in
                        existingTitle.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ==
                        todo.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                    }

                    if isDuplicate {
                        print("    ⚠️  Skipping duplicate todo\n")
                        skippedDuplicates += 1
                        continue
                    }

                    // Create in Notion using unified Tasks database
                    do {
                        // Generate hash for duplicate detection
                        let hash = Self.generateTaskHash(
                            title: todo.title,
                            description: todo.description ?? "",
                            platform: "WhatsApp",
                            threadId: thread.contactIdentifier
                        )

                        // Check if task already exists by hash
                        if let existingId = try await notionService.findTaskByHash(hash) {
                            print("    ⚠️  Skipping duplicate (found by hash: \(existingId))\n")
                            skippedDuplicates += 1
                            continue
                        }

                        // Convert TodoItem to TaskItem
                        let taskItem = TaskItem.fromTodoItem(todo, hash: hash)

                        // Create task in Notion
                        let pageId = try await notionService.createTask(taskItem)
                        print("    ✓ Created in Notion (ID: \(pageId))\n")
                        createdTodos.append(todo)
                    } catch {
                        print("    ✗ Failed to create in Notion: \(error)\n")
                    }
                } else {
                    print("    • Not a todo\n")
                    notTodoCount += 1
                }
            }
        }

        print("✓ Processed \(processedCount) message(s), created \(createdTodos.count) todo(s), skipped \(skippedDuplicates) duplicate(s)\n")

        return TodoScanResult(
            messagesScanned: processedCount,
            todosFound: allFoundTodos.count,
            todosCreated: createdTodos.count,
            duplicatesSkipped: skippedDuplicates,
            notTodos: notTodoCount,
            createdTodos: createdTodos,
            lookbackDays: lookbackDays
        )
    }

    func saveBriefingToNotion(_ briefing: DailyBriefing) async throws -> String {
        print("\n📓 Saving briefing to Notion...")
        let url = try await notionService.saveBriefing(briefing)
        print("✓ Briefing saved to Notion\n")
        return url
    }

    // MARK: - Recommended Actions from Analysis

    /// Extract critical action items from focused thread analysis
    func extractRecommendedActions(from analysis: FocusedThreadAnalysis) -> [RecommendedAction] {
        // Only extract critical/high priority items
        return analysis.actionItems.filter { item in
            item.priority.lowercased() == "high" || item.priority.lowercased() == "critical"
        }.map { item in
            let priority: ActionPriority = item.priority.lowercased() == "critical" ? .critical : .high
            let dueDate = parseDueDate(from: item.deadline)

            return RecommendedAction(
                title: item.item,
                description: "From thread with \(analysis.thread.contactName ?? "Unknown")",
                priority: priority,
                source: .focusedAnalysis(contact: analysis.thread.contactName ?? "Unknown"),
                dueDate: dueDate,
                context: "Action identified from message analysis"
            )
        }
    }

    /// Extract critical action items from message summaries
    func extractRecommendedActions(from summaries: [MessageSummary]) -> [RecommendedAction] {
        var actions: [RecommendedAction] = []

        for summary in summaries {
            // Only extract from critical/high urgency messages
            guard summary.urgency == .critical || summary.urgency == .high else { continue }

            // Only take first 2 most critical action items per thread
            for actionItem in summary.actionItems.prefix(2) {
                let priority: ActionPriority = summary.urgency == .critical ? .critical : .high

                actions.append(RecommendedAction(
                    title: actionItem,
                    description: summary.summary,
                    priority: priority,
                    source: .messageThread(contact: summary.thread.contactName ?? "Unknown", platform: summary.thread.platform),
                    dueDate: nil,
                    context: "From \(summary.thread.platform.rawValue) conversation"
                ))
            }
        }

        return actions
    }

    /// Add recommended actions to Notion
    func addRecommendedActionsToNotion(_ actions: [RecommendedAction]) async throws -> [String] {
        var createdIds: [String] = []

        for action in actions {
            do {
                let description = action.description + "\n\nSource: " + action.source.displayName

                // Create unique hash for deduplication
                let combined = "\(action.title)|\(description)"
                let hash = SHA256.hash(data: Data(combined.utf8))
                    .compactMap { String(format: "%02x", $0) }
                    .joined()

                // Check if task already exists by hash
                if let _ = try await notionService.findTaskByHash(hash) {
                    print("  ⚠️  Skipping duplicate: \(action.title)")
                    continue
                }

                // Create TaskItem from recommended action
                let taskItem = TaskItem(
                    notionId: "",
                    title: action.title,
                    type: .todo,
                    status: .notStarted,
                    description: description,
                    dueDate: action.dueDate,
                    priority: action.priority == .critical ? .critical : (action.priority == .high ? .high : .medium),
                    assignee: config.user.name,
                    commitmentDirection: nil,
                    committedBy: nil,
                    committedTo: nil,
                    originalContext: nil,
                    sourcePlatform: nil,
                    sourceThread: action.source.displayName,
                    sourceThreadId: nil,
                    tags: nil,
                    followUpDate: nil,
                    uniqueHash: hash,
                    notes: nil,
                    createdDate: Date(),
                    lastUpdated: Date()
                )

                let pageId = try await notionService.createTask(taskItem)
                createdIds.append(pageId)
                print("  ✓ Added: \(action.title)")
            } catch {
                print("  ✗ Failed to add '\(action.title)': \(error)")
            }
        }

        return createdIds
    }

    private func parseDueDate(from deadline: String?) -> Date? {
        guard let deadline = deadline?.lowercased() else { return nil }

        let calendar = Calendar.current
        let now = Date()

        if deadline.contains("today") {
            return calendar.date(bySettingHour: 23, minute: 59, second: 0, of: now)
        } else if deadline.contains("tomorrow") {
            return calendar.date(byAdding: .day, value: 1, to: now)
        } else if deadline.contains("week") {
            return calendar.date(byAdding: .day, value: 7, to: now)
        }

        return nil
    }

    // MARK: - Message Fetching for Commitments

    func fetchMessagesForContact(_ contactName: String, since: Date) async throws -> [(message: Message, platform: MessagePlatform, threadName: String, threadId: String)] {
        var allMessages: [(Message, MessagePlatform, String, String)] = []

        // iMessage
        if config.messaging.imessage.enabled {
            do {
                try imessageReader.connect()
                let threads = try imessageReader.fetchThreads(since: since)
                imessageReader.disconnect()

                let matchingThreads = threads.filter { thread in
                    (thread.contactName ?? thread.contactIdentifier).localizedCaseInsensitiveContains(contactName)
                }

                for thread in matchingThreads {
                    for message in thread.messages {
                        let threadName = thread.contactName ?? thread.contactIdentifier
                        allMessages.append((message, .imessage, threadName, thread.contactIdentifier))
                    }
                }
            } catch {
                print("  ✗ Failed to fetch iMessages: \(error)")
            }
        }

        // WhatsApp
        if config.messaging.whatsapp.enabled {
            do {
                try whatsappReader.connect()
                let threads = try whatsappReader.fetchThreads(since: since)
                whatsappReader.disconnect()

                let matchingThreads = threads.filter { thread in
                    (thread.contactName ?? thread.contactIdentifier).localizedCaseInsensitiveContains(contactName)
                }

                for thread in matchingThreads {
                    for message in thread.messages {
                        let threadName = thread.contactName ?? thread.contactIdentifier
                        allMessages.append((message, .whatsapp, threadName, thread.contactIdentifier))
                    }
                }
            } catch {
                print("  ✗ Failed to fetch WhatsApp messages: \(error)")
            }
        }

        // Signal
        if config.messaging.signal.enabled {
            do {
                try signalReader.connect()
                let threads = try signalReader.fetchThreads(since: since)
                signalReader.disconnect()

                let matchingThreads = threads.filter { thread in
                    (thread.contactName ?? thread.contactIdentifier).localizedCaseInsensitiveContains(contactName)
                }

                for thread in matchingThreads {
                    for message in thread.messages {
                        let threadName = thread.contactName ?? thread.contactIdentifier
                        allMessages.append((message, .signal, threadName, thread.contactIdentifier))
                    }
                }
            } catch {
                print("  ✗ Failed to fetch Signal messages: \(error)")
            }
        }

        return allMessages
    }

    /// Helper function to check if a thread is a self-thread (messages to yourself)
    /// Handles all common name variations and formats
    private func isSelfThread(_ thread: MessageThread, userFullName: String) -> Bool {
        guard let contactName = thread.contactName else { return false }

        // Normalize the contact name: lowercase and remove "(You)" suffix
        let normalizedContact = contactName
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "(you)", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Parse user's full name into components
        let nameComponents = userFullName
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }

        guard nameComponents.count >= 2 else {
            // Fallback: if config name is not properly formatted, just check if it contains the full name
            return normalizedContact.contains(userFullName.lowercased())
        }

        let firstName = nameComponents.first!.lowercased()
        let lastName = nameComponents.last!.lowercased()

        // Generate all possible name combinations
        let possibleVariations = [
            "\(firstName) \(lastName)",      // "miten sampat"
            "\(lastName) \(firstName)",      // "sampat miten"
            "\(firstName)\(lastName)",       // "mitensampat"
            "\(lastName)\(firstName)",       // "sampatmiten"
            "\(firstName)_\(lastName)",      // "miten_sampat"
            "\(lastName)_\(firstName)",      // "sampat_miten"
            "\(firstName).\(lastName)",      // "miten.sampat"
            "\(lastName).\(firstName)"       // "sampat.miten"
        ]

        // Check if contact name matches any variation
        for variation in possibleVariations {
            if normalizedContact.contains(variation) {
                return true
            }
        }

        return false
    }

    /// Generate unique hash for task deduplication
    private static func generateTaskHash(title: String, description: String, platform: String, threadId: String) -> String {
        let combined = "\(title)|\(description)|\(platform)|\(threadId)"
        let data = Data(combined.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}
