import Foundation

class BriefingOrchestrator {
    let config: AppConfig
    private let imessageReader: iMessageReader
    private let whatsappReader: WhatsAppReader
    private let signalReader: SignalReader
    private let gmailReader: GmailReader?
    private let calendarService: MultiCalendarService
    private let aiService: ClaudeAIService
    private let researchService: ResearchService
    private let notificationService: NotificationService
    private let notionService: NotionService
    private var agentManager: AgentManager?

    init(config: AppConfig) {
        self.config = config

        self.imessageReader = iMessageReader(dbPath: config.messaging.imessage.dbPath)
        self.whatsappReader = WhatsAppReader(dbPath: config.messaging.whatsapp.dbPath)
        self.signalReader = SignalReader(dbPath: config.messaging.signal.dbPath)
        self.gmailReader = config.messaging.email.map { GmailReader(config: $0) }
        self.calendarService = MultiCalendarService(configs: config.calendar.google)
        self.aiService = ClaudeAIService(config: config.ai)
        self.researchService = ResearchService(config: config, aiService: aiService)
        self.notificationService = NotificationService(config: config.notifications)
        self.notionService = NotionService(config: config.notion)

        // Initialize agent manager if agents are enabled
        if let agentsConfig = config.agents, agentsConfig.enabled {
            do {
                self.agentManager = try AgentManager(config: agentsConfig.toAgentConfig(), appConfig: config)
            } catch {
                print("⚠️  Failed to initialize agent manager: \(error)")
                self.agentManager = nil
            }
        }
    }

    // MARK: - Morning Briefing

    func generateMorningBriefing() async throws -> DailyBriefing {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        return try await generateBriefing(for: tomorrow, sendNotifications: true)
    }

    func generateBriefing(for date: Date, sendNotifications: Bool = false) async throws -> DailyBriefing {
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

        // 6. Let agents evaluate the context and make decisions
        var agentDecisions: [AgentDecision]? = nil
        if let agentManager = agentManager {
            print("🤖 Agents evaluating context...")
            let context = AgentContext(
                briefing: nil,  // Will be set after creation
                messagingSummary: messagingSummary,
                calendarBriefing: calendarBriefing,
                notionContext: NotionContext(notes: notionNotes, tasks: notionTasks)
            )

            do {
                let allDecisions = try await agentManager.evaluateContext(context)
                // Filter for decisions that require approval (others were auto-executed)
                agentDecisions = allDecisions.filter { $0.requiresApproval }
                print("✓ Agents generated \(allDecisions.count) decision(s) (\(allDecisions.filter { !$0.requiresApproval }.count) auto-executed, \(agentDecisions?.count ?? 0) pending approval)\n")
            } catch {
                print("⚠️  Agent evaluation failed: \(error)\n")
            }
        }

        let briefing = DailyBriefing(
            date: date,
            messagingSummary: messagingSummary,
            calendarBriefing: calendarBriefing,
            actionItems: actionItems,
            notionContext: NotionContext(notes: notionNotes, tasks: notionTasks),
            agentDecisions: agentDecisions,
            generatedAt: Date()
        )

        // 7. Send notifications only if requested
        if sendNotifications {
            print("📬 Sending briefing notifications...")
            try await notificationService.sendBriefing(briefing)
            print("✓ Notifications sent successfully\n")
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

    func generateDraftsForMessages(_ summaries: [MessageSummary]) async throws -> Int {
        guard let agentManager = agentManager else {
            print("⚠️  Agents not enabled - skipping draft creation\n")
            return 0
        }

        print("🤖 Agents analyzing messages for draft responses...")

        // Filter messages needing response (by checking thread.needsResponse)
        let needsResponse = summaries.filter { $0.thread.needsResponse }

        // Create messaging stats
        let stats = MessagingSummary.MessagingStats(
            totalMessages: summaries.reduce(0) { $0 + $1.thread.messages.count },
            unreadMessages: summaries.reduce(0) { $0 + $1.thread.unreadCount },
            threadsNeedingResponse: needsResponse.count,
            byPlatform: Dictionary(grouping: summaries, by: { $0.thread.platform }).mapValues { $0.count }
        )

        // Create a minimal context for the communication agent
        let context = AgentContext(
            messagingSummary: MessagingSummary(
                keyInteractions: needsResponse,
                needsResponse: needsResponse,
                criticalMessages: summaries.filter { $0.urgency == .critical },
                stats: stats
            )
        )

        do {
            let decisions = try await agentManager.evaluateContext(context)
            let draftDecisions = decisions.filter { if case .draftResponse = $0.action { return true }; return false }

            if draftDecisions.isEmpty {
                print("ℹ️  No draft responses needed\n")
            } else {
                print("✓ Created \(draftDecisions.count) draft response(s)\n")
            }

            return draftDecisions.count
        } catch {
            print("⚠️  Failed to generate drafts: \(error)\n")
            return 0
        }
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

    func generateDraftForThread(_ analysis: FocusedThreadAnalysis) async throws -> Int {
        guard let agentManager = agentManager else {
            print("⚠️  Agents not enabled - skipping draft creation\n")
            return 0
        }

        print("🤖 Agents analyzing thread for draft response...")

        // Parse urgency from action items
        let urgency: UrgencyLevel
        if analysis.actionItems.contains(where: { $0.priority.lowercased() == "critical" }) {
            urgency = .critical
        } else if analysis.actionItems.contains(where: { $0.priority.lowercased() == "high" }) {
            urgency = .high
        } else if !analysis.actionItems.isEmpty {
            urgency = .medium
        } else {
            urgency = .low
        }

        // Create a message summary from the thread analysis
        let summary = MessageSummary(
            thread: analysis.thread,
            summary: analysis.summary,
            urgency: urgency,
            suggestedResponse: nil,
            actionItems: analysis.actionItems.map { $0.item },
            sentiment: "neutral"  // FocusedThreadAnalysis doesn't have sentiment
        )

        // Create messaging stats
        let stats = MessagingSummary.MessagingStats(
            totalMessages: analysis.thread.messages.count,
            unreadMessages: analysis.thread.unreadCount,
            threadsNeedingResponse: 1,
            byPlatform: [analysis.thread.platform: 1]
        )

        // Create context with single thread
        let context = AgentContext(
            messagingSummary: MessagingSummary(
                keyInteractions: [summary],
                needsResponse: [summary],
                criticalMessages: urgency == .critical ? [summary] : [],
                stats: stats
            )
        )

        do {
            let decisions = try await agentManager.evaluateContext(context)
            let draftDecisions = decisions.filter { if case .draftResponse = $0.action { return true }; return false }

            if draftDecisions.isEmpty {
                print("ℹ️  No draft response needed\n")
            } else {
                print("✓ Created draft response\n")
            }

            return draftDecisions.count
        } catch {
            print("⚠️  Failed to generate draft: \(error)\n")
            return 0
        }
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
                let pageId = try await notionService.createTodo(
                    title: action.title,
                    description: action.description + "\n\nSource: " + action.source.displayName,
                    dueDate: action.dueDate,
                    assignee: config.user.name
                )
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

    func generateAttentionDefenseAlert(sendNotifications: Bool = true) async throws -> AttentionDefenseReport {
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
        if sendNotifications {
            try await notificationService.sendAttentionDefenseReport(report)
        }

        return report
    }

    // MARK: - Private Helpers

    private func fetchAndAnalyzeMessages() async throws -> MessagingSummary {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let twoDaysAgo = Calendar.current.date(byAdding: .hour, value: -48, to: Date())!

        var messagingThreads: [MessageThread] = []
        var emailThreads: [MessageThread] = []

        // Fetch from all enabled messaging platforms
        if config.messaging.imessage.enabled {
            do {
                try imessageReader.connect()
                let threads = try imessageReader.fetchThreads(since: yesterday)
                messagingThreads.append(contentsOf: threads)
                imessageReader.disconnect()
            } catch {
                print("Warning: Failed to fetch iMessages: \(error)")
            }
        }

        if config.messaging.whatsapp.enabled {
            do {
                try whatsappReader.connect()
                let threads = try whatsappReader.fetchThreads(since: yesterday)
                messagingThreads.append(contentsOf: threads)
                whatsappReader.disconnect()
            } catch {
                print("Warning: Failed to fetch WhatsApp messages: \(error)")
            }
        }

        if config.messaging.signal.enabled {
            do {
                try signalReader.connect()
                let threads = try signalReader.fetchThreads(since: yesterday)
                messagingThreads.append(contentsOf: threads)
                signalReader.disconnect()
            } catch {
                print("Warning: Failed to fetch Signal messages: \(error)")
            }
        }

        // Fetch from email (48 hour lookback) - only if user wants email analysis in briefing
        if let gmailReader = gmailReader,
           let emailConfig = config.messaging.email,
           emailConfig.enabled && emailConfig.shouldAnalyze {
            do {
                let threads = try await gmailReader.fetchThreads(since: twoDaysAgo)
                emailThreads.append(contentsOf: threads)
            } catch {
                print("Warning: Failed to fetch emails: \(error)")
            }
        }

        // Smart filtering: separate quotas for messaging vs email
        let filteredMessagingThreads = prioritizeThreads(messagingThreads, maxCount: config.ai.effectiveMaxThreads)
        let filteredEmailThreads = prioritizeEmailThreads(emailThreads, maxCount: config.ai.effectiveMaxEmailThreads)

        print("  📊 Filtered to top \(filteredMessagingThreads.count) messaging threads (from \(messagingThreads.count) total)")
        print("  📧 Filtered to top \(filteredEmailThreads.count) email threads (from \(emailThreads.count) total)")

        // Combine for analysis
        let allFilteredThreads = filteredMessagingThreads + filteredEmailThreads
        let allThreads = messagingThreads + emailThreads

        // Analyze threads with AI
        let summaries = try await aiService.analyzeMessages(allFilteredThreads)

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

    private func prioritizeEmailThreads(_ threads: [MessageThread], maxCount: Int) -> [MessageThread] {
        // Keywords that indicate critical emails (HR, resignations, departures)
        let criticalKeywords = [
            "resignation", "last working day", "exit", "leaving", "farewell",
            "offboarding", "transition", "notice period", "final day",
            "last day", "departed", "resignation letter", "stepping down"
        ]

        // Score threads based on multiple factors
        let scoredThreads = threads.map { thread -> (thread: MessageThread, score: Double) in
            var score: Double = 0

            // Factor 1: Recency (most recent message)
            let hoursSinceLastMessage = Date().timeIntervalSince(thread.lastMessageDate) / 3600
            score += max(0, 100 - hoursSinceLastMessage) // Up to 100 points for very recent

            // Factor 2: Message volume in thread
            score += Double(min(thread.messages.count, 3)) * 10 // Up to 30 points

            // Factor 3: Check for critical keywords (MASSIVE boost)
            let allContent = thread.messages.map { $0.content.lowercased() }.joined(separator: " ")
            let hasSubject = thread.contactName?.lowercased() ?? ""
            let searchableText = allContent + " " + hasSubject

            for keyword in criticalKeywords {
                if searchableText.contains(keyword) {
                    score += 10000 // Guaranteed to be at top
                    break
                }
            }

            // Factor 4: Not from bots or automated services
            let sender = thread.contactName?.lowercased() ?? ""
            if sender.contains("noreply") || sender.contains("[bot]") || sender.contains("notification") {
                score *= 0.1 // Heavily penalize automated emails
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

    func processWhatsAppTodos() async throws -> [TodoItem] {
        print("\n📝 Processing WhatsApp messages for todos...\n")

        // Fetch WhatsApp messages from last 24 hours where I'm the sender
        let since = Calendar.current.date(byAdding: .hour, value: -24, to: Date())!

        guard config.messaging.whatsapp.enabled else {
            print("  ⚠️  WhatsApp is not enabled in config")
            return []
        }

        print("  ↳ Reading WhatsApp database...")
        try whatsappReader.connect()
        let threads = try whatsappReader.fetchThreads(since: since)
        whatsappReader.disconnect()

        // Filter for messages to yourself (self)
        let selfThreads = threads.filter { thread in
            let name = thread.contactName?.lowercased() ?? ""
            return name.contains("miten sampat") || name.contains("sampat miten")
        }

        print("  ✓ Found \(selfThreads.count) thread(s) with yourself\n")

        if selfThreads.isEmpty {
            print("  ℹ️  No messages to yourself found")
            return []
        }

        // Fetch existing todos from Notion for duplication check
        print("  ↳ Checking existing todos in Notion...")
        let existingTitles = (try? await notionService.searchExistingTodos(title: "")) ?? []
        print("  ✓ Found \(existingTitles.count) existing todo(s)\n")

        // Extract todos from outgoing messages
        var createdTodos: [TodoItem] = []
        var processedCount = 0
        var skippedDuplicates = 0

        for thread in selfThreads {
            let outgoingMessages = thread.messages.filter { $0.direction == .outgoing }

            for message in outgoingMessages {
                processedCount += 1
                print("  ↳ Analyzing message \(processedCount): \"\(String(message.content.prefix(50)))\(message.content.count > 50 ? "..." : "")\"")

                if let todo = try await aiService.extractTodoFromMessage(message) {
                    print("    ✓ Detected todo: \(todo.title)")

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

                    // Create in Notion with assignee and tomorrow as due date
                    do {
                        let pageId = try await notionService.createTodo(
                            title: todo.title,
                            description: todo.description,
                            dueDate: nil,  // Will default to tomorrow in NotionService
                            assignee: "Miten Sampat"
                        )
                        print("    ✓ Created in Notion (ID: \(pageId))\n")
                        createdTodos.append(todo)
                    } catch {
                        print("    ✗ Failed to create in Notion: \(error)\n")
                    }
                } else {
                    print("    • Not a todo\n")
                }
            }
        }

        print("✓ Processed \(processedCount) message(s), created \(createdTodos.count) todo(s), skipped \(skippedDuplicates) duplicate(s)\n")
        return createdTodos
    }

    func saveBriefingToNotion(_ briefing: DailyBriefing) async throws -> String {
        print("\n📓 Saving briefing to Notion...")
        let url = try await notionService.saveBriefing(briefing)
        print("✓ Briefing saved to Notion\n")
        return url
    }
}
