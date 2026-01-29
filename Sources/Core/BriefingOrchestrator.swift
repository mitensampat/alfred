import Foundation
import CryptoKit

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

    // Public accessors for commitments feature
    let commitmentAnalyzer: CommitmentAnalyzer
    var notionServicePublic: NotionService { notionService }

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

        // Initialize commitment analyzer
        self.commitmentAnalyzer = CommitmentAnalyzer(
            anthropicApiKey: config.ai.anthropicApiKey,
            model: config.ai.model,
            userInfo: CommitmentAnalyzer.UserInfo(
                name: config.user.name,
                email: config.user.email
            )
        )

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

    func generateBriefing(for date: Date, sendNotifications: Bool = false, toAddress: String? = nil) async throws -> DailyBriefing {
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

            // Query tasks database - check top-level first, then briefing_sources
            let tasksDbId = config.notion.tasksDatabaseId ?? briefingSources.tasksDatabaseId
            if let tasksDatabaseId = tasksDbId, tasksDatabaseId != "YOUR_TASKS_DATABASE_ID" {
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

        // 7. Gather agent insights (proactive notices, recent learnings, commitment reminders)
        var agentInsights: AgentInsights? = nil
        if agentManager != nil {
            print("🧠 Gathering agent insights...")
            agentInsights = try await gatherAgentInsights(
                messagingSummary: messagingSummary,
                calendarBriefing: calendarBriefing,
                notionTasks: notionTasks
            )
            if let insights = agentInsights, !insights.isEmpty {
                print("✓ Agent insights: \(insights.recentLearnings.count) learnings, \(insights.proactiveNotices.count) notices, \(insights.commitmentReminders.count) reminders\n")
            } else {
                print("ℹ️  No significant agent insights\n")
            }
        }

        let briefing = DailyBriefing(
            date: date,
            messagingSummary: messagingSummary,
            calendarBriefing: calendarBriefing,
            actionItems: actionItems,
            notionContext: NotionContext(notes: notionNotes, tasks: notionTasks),
            agentDecisions: agentDecisions,
            agentInsights: agentInsights,
            generatedAt: Date()
        )

        // 7. Send notifications only if requested
        if sendNotifications {
            print("📬 Sending briefing notifications...")
            try await notificationService.sendBriefing(briefing, toAddress: toAddress)
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

            // Query tasks database - check top-level first, then briefing_sources
            let tasksDbId = config.notion.tasksDatabaseId ?? briefingSources.tasksDatabaseId
            if let tasksDatabaseId = tasksDbId, tasksDatabaseId != "YOUR_TASKS_DATABASE_ID" {
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

        // Include all meeting titles for keyword extraction
        context += "- Meeting titles: \(schedule.events.map { $0.title }.joined(separator: ", "))\n"

        // Include attendee names and emails (important for finding related notes)
        var attendeeNames: [String] = []
        var attendeeEmails: [String] = []
        for event in schedule.events {
            for attendee in event.attendees {
                if let name = attendee.name, !name.isEmpty {
                    attendeeNames.append(name)
                }
                attendeeEmails.append(attendee.email)
            }
        }
        if !attendeeNames.isEmpty {
            context += "- Attendee names: \(Array(Set(attendeeNames)).joined(separator: ", "))\n"
        }
        if !attendeeEmails.isEmpty {
            context += "- Attendee emails: \(Array(Set(attendeeEmails)).joined(separator: ", "))\n"
        }

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
                let description = action.description + "\n\nSource: " + action.source.displayName

                // Generate hash for duplicate detection
                let hash = Self.generateTaskHash(
                    title: action.title,
                    description: description,
                    platform: "Alfred",
                    threadId: "recommended-actions"
                )

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

    func generateAttentionDefenseAlert(sendNotifications: Bool = true, toAddress: String? = nil) async throws -> AttentionDefenseReport {
        print("Generating attention defense alert...")

        let today = Date()
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!

        // 1. Fetch calendar for today and tomorrow
        let todaySchedule = try await calendarService.fetchEventsFromAllCalendars(for: today, userSettings: config.user)
        let tomorrowSchedule = try await calendarService.fetchEventsFromAllCalendars(for: tomorrow, userSettings: config.user)

        // 2. Fetch active tasks from Notion
        var actionItems: [ActionItem] = []
        do {
            let tasks = try await notionService.queryActiveTasks(type: nil)
            let capped = Array(tasks.prefix(50))
            actionItems = capped.map { convertTaskItemToActionItem($0) }
            print("Loaded \(actionItems.count) active tasks from Notion")
        } catch {
            print("Warning: Failed to fetch Notion tasks: \(error). Continuing with empty task list.")
        }

        // 3. Use AI to analyze what can be pushed off
        let report = try await aiService.generateAttentionDefenseReport(
            actionItems: actionItems,
            todaySchedule: todaySchedule,
            tomorrowSchedule: tomorrowSchedule,
            currentTime: Date()
        )

        // 4. Send alert only if requested
        if sendNotifications {
            try await notificationService.sendAttentionDefenseReport(report, toAddress: toAddress)
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

        // Include meeting titles for keyword extraction
        context += "- Meeting titles: \(schedule.events.map { $0.title }.joined(separator: ", "))\n"

        // Include attendee names and emails (important for finding related notes)
        var attendeeNames: [String] = []
        var attendeeEmails: [String] = []
        for event in schedule.events {
            for attendee in event.attendees {
                if let name = attendee.name, !name.isEmpty {
                    attendeeNames.append(name)
                }
                attendeeEmails.append(attendee.email)
            }
        }
        if !attendeeNames.isEmpty {
            context += "- Attendee names: \(Array(Set(attendeeNames)).joined(separator: ", "))\n"
        }
        if !attendeeEmails.isEmpty {
            context += "- Attendee emails: \(Array(Set(attendeeEmails)).joined(separator: ", "))\n"
        }

        // Include message contact names
        var messageContacts: [String] = []
        for summary in messagingSummary.keyInteractions {
            if let name = summary.thread.contactName {
                messageContacts.append(name)
            }
        }
        for summary in messagingSummary.criticalMessages {
            if let name = summary.thread.contactName {
                messageContacts.append(name)
            }
        }
        if !messageContacts.isEmpty {
            context += "- Message contacts: \(Array(Set(messageContacts)).joined(separator: ", "))\n"
        }

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

    private func convertTaskItemToActionItem(_ task: TaskItem) -> ActionItem {
        let priority: UrgencyLevel
        switch task.priority {
        case .critical: priority = .critical
        case .high: priority = .high
        case .medium: priority = .medium
        case .low: priority = .low
        case .none: priority = .medium
        }

        let source: ActionItem.ActionSource
        switch task.sourcePlatform {
        case .whatsapp, .imessage, .signal, .email: source = .message
        case .manual, .none: source = .system
        }

        let category: ActionItem.ActionCategory
        switch task.type {
        case .todo: category = .task
        case .commitment: category = .respond
        case .followup: category = .follow_up
        }

        let description: String
        if let desc = task.description, !desc.isEmpty {
            description = desc
        } else {
            description = task.title
        }

        return ActionItem(
            id: task.notionId.isEmpty ? UUID().uuidString : task.notionId,
            title: task.title,
            description: description,
            source: source,
            priority: priority,
            dueDate: task.dueDate,
            estimatedDuration: nil,
            category: category
        )
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

    // MARK: - Interactive Todo Extraction (without auto-save)

    /// Extracts todos from WhatsApp messages without automatically saving them
    /// Returns ExtractedItems for interactive review
    func extractWhatsAppTodosForReview(lookbackDays: Int = 7) async throws -> [ExtractedItem] {
        print("\n📝 Extracting todos from WhatsApp messages...\n")

        let since = Calendar.current.date(byAdding: .day, value: -lookbackDays, to: Date())!
        print("  ↳ Scanning last \(lookbackDays) days...\n")

        guard config.messaging.whatsapp.enabled else {
            print("  ⚠️  WhatsApp is not enabled in config")
            return []
        }

        print("  ↳ Reading WhatsApp database...")
        try whatsappReader.connect()
        let threads = try whatsappReader.fetchThreads(since: since)
        whatsappReader.disconnect()

        // Filter for messages to yourself
        let selfThreads = threads.filter { thread in
            isSelfThread(thread, userFullName: config.user.name)
        }

        print("  ✓ Found \(selfThreads.count) thread(s) with yourself\n")

        if selfThreads.isEmpty {
            return []
        }

        // Fetch existing todos for duplicate check
        print("  ↳ Checking existing todos in Notion...")
        let existingTitles = (try? await notionService.searchExistingTodos(title: "")) ?? []

        var extractedItems: [ExtractedItem] = []
        var processedCount = 0

        for thread in selfThreads {
            let outgoingMessages = thread.messages.filter { $0.direction == .outgoing }

            for message in outgoingMessages {
                processedCount += 1
                print("  ↳ Analyzing message \(processedCount)...")

                if let todo = try await aiService.extractTodoFromMessage(message) {
                    // Generate hash for duplicate check
                    let hash = Self.generateTaskHash(
                        title: todo.title,
                        description: todo.description ?? "",
                        platform: "WhatsApp",
                        threadId: thread.contactIdentifier
                    )

                    // Check for duplicates by title
                    let isDuplicateByTitle = existingTitles.contains { existingTitle in
                        existingTitle.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ==
                        todo.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                    }

                    // Check by hash if not already a duplicate
                    var isDuplicateByHash = false
                    if !isDuplicateByTitle {
                        if let _ = try? await notionService.findTaskByHash(hash) {
                            isDuplicateByHash = true
                        }
                    }

                    if isDuplicateByTitle || isDuplicateByHash {
                        print("    ⊘ Already exists: \(todo.title)")
                        continue
                    }

                    print("    ✓ Found todo: \(todo.title)")

                    // Convert to ExtractedItem
                    let item = ExtractedItem(
                        type: .todo,
                        title: todo.title,
                        description: todo.description,
                        priority: .medium,
                        source: ExtractedItem.ItemSource(
                            platform: .whatsapp,
                            contact: config.user.name,
                            threadName: thread.contactName,
                            threadId: thread.contactIdentifier
                        ),
                        dueDate: todo.dueDate,
                        uniqueHash: hash
                    )
                    extractedItems.append(item)
                } else {
                    print("    • Not a todo")
                }
            }
        }

        print("\n✓ Found \(extractedItems.count) new todo(s) for review\n")
        return extractedItems
    }

    /// Save extracted items to Notion Tasks database
    func saveExtractedItems(_ items: [ExtractedItem]) async throws -> (saved: Int, failed: Int) {
        var savedCount = 0
        var failedCount = 0
        var duplicateCount = 0

        for item in items {
            do {
                let taskItem = item.toTaskItem()
                _ = try await notionService.createTask(taskItem)
                savedCount += 1
                print("  ✓ Saved: \(item.title)")
            } catch let error as NotionService.TaskCreationError {
                switch error {
                case .duplicate:
                    duplicateCount += 1
                    print("  ⏭ Skipped (duplicate): \(item.title)")
                }
            } catch {
                print("  ✗ Failed to save: \(item.title) - \(error)")
                failedCount += 1
            }
        }

        // Report duplicates as part of failed count (they weren't newly saved)
        if duplicateCount > 0 {
            print("  ℹ️ \(duplicateCount) duplicate(s) skipped")
        }

        return (savedCount, failedCount + duplicateCount)
    }

    // MARK: - Public Helpers for Attention System

    /// Fetch calendar events for a date range (public accessor)
    func fetchCalendarEvents(from start: Date, to end: Date) async throws -> [CalendarEvent] {
        // Fetch events day by day and combine
        var allEvents: [CalendarEvent] = []
        var currentDate = start

        while currentDate <= end {
            let schedule = try await calendarService.fetchEventsFromAllCalendars(for: currentDate, userSettings: config.user)
            allEvents.append(contentsOf: schedule.events)
            currentDate = Calendar.current.date(byAdding: .day, value: 1, to: currentDate) ?? end
        }

        return allEvents
    }

    /// Access the agent manager (public accessor)
    var publicAgentManager: AgentManager? {
        return agentManager
    }

    // MARK: - Commitments Support

    /// Fetch messages for a specific contact from all platforms
    func fetchMessagesForContact(_ contactName: String, since: Date) async throws -> [(message: Message, platform: MessagePlatform, threadName: String, threadId: String)] {
        var allMessages: [(Message, MessagePlatform, String, String)] = []

        // iMessage
        if config.messaging.imessage.enabled {
            do {
                try imessageReader.connect()
                let threads = try imessageReader.fetchThreads(since: since)
                imessageReader.disconnect()

                let matchingThreads = threads.filter { thread in
                    thread.threadName.localizedCaseInsensitiveContains(contactName)
                }

                for thread in matchingThreads {
                    for message in thread.messages {
                        allMessages.append((message, .imessage, thread.threadName, thread.threadId))
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
                    thread.threadName.localizedCaseInsensitiveContains(contactName)
                }

                for thread in matchingThreads {
                    for message in thread.messages {
                        allMessages.append((message, .whatsapp, thread.threadName, thread.threadId))
                    }
                }
            } catch {
                print("  ✗ Failed to fetch WhatsApp messages: \(error)")
            }
        }

        return allMessages
    }

    /// Helper function to check if a thread is a self-thread (messages to yourself)
    /// Handles all common name variations and formats
    private func isSelfThread(_ thread: MessageThread, userFullName: String) -> Bool {
        guard let contactName = thread.contactName else { return false }

        // Strip Unicode control/formatting characters (LTR mark, RTL mark, etc.) then normalize
        let strippedContact = contactName.unicodeScalars
            .filter { !($0.properties.isDefaultIgnorableCodePoint || CharacterSet.controlCharacters.contains($0)) }
            .map { Character($0) }
            .map { String($0) }
            .joined()
        let normalizedContact = strippedContact
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "(you)", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // WhatsApp labels self-chat as "You" (often with invisible Unicode chars)
        if normalizedContact == "you" {
            return true
        }

        // Parse user's full name into components
        let nameComponents = userFullName
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }

        guard nameComponents.count >= 2 else {
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

    // MARK: - Agent Insights

    /// Gather proactive insights from all agents for the briefing
    private func gatherAgentInsights(
        messagingSummary: MessagingSummary,
        calendarBriefing: CalendarBriefing,
        notionTasks: [NotionTask]
    ) async throws -> AgentInsights {
        let memoryService = AgentMemoryService.shared

        // 1. Gather recent learnings from all agents (last 24 hours)
        var recentLearnings: [AgentLearning] = []
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!

        let allAgentTypes: [AgentType] = [.communication, .task, .calendar, .followup]
        for agentType in allAgentTypes {
            let memory = memoryService.getMemory(for: agentType)

            // Parse recent learnings from memory
            if let learnedSection = extractSection(from: memory.content, named: "Learned Patterns") {
                let learnings = parseRecentLearnings(learnedSection, agentType: agentType, since: yesterday)
                recentLearnings.append(contentsOf: learnings)
            }
        }

        // 2. Generate proactive notices based on context
        var proactiveNotices: [ProactiveNotice] = []

        // Communication agent notices
        if messagingSummary.stats.threadsNeedingResponse > 5 {
            proactiveNotices.append(ProactiveNotice(
                agentType: .communication,
                title: "High message backlog",
                message: "You have \(messagingSummary.stats.threadsNeedingResponse) threads awaiting response. Consider batch-responding to clear your inbox.",
                priority: .medium,
                suggestedAction: "Review messages summary and prioritize responses",
                relatedContext: nil
            ))
        }

        // Check for VIP contacts needing response
        let vipPatterns = extractVIPPatterns(from: memoryService.getMemory(for: .communication).content)
        for summary in messagingSummary.needsResponse {
            if let contactName = summary.thread.contactName,
               vipPatterns.contains(where: { contactName.lowercased().contains($0.lowercased()) }) {
                proactiveNotices.append(ProactiveNotice(
                    agentType: .communication,
                    title: "VIP contact waiting",
                    message: "\(contactName) is in your VIP list and has an unanswered message.",
                    priority: .high,
                    suggestedAction: "Prioritize responding to \(contactName)",
                    relatedContext: summary.summary
                ))
            }
        }

        // Calendar agent notices
        let meetingHours = calendarBriefing.schedule.totalMeetingTime / 3600
        if meetingHours > 6 {
            proactiveNotices.append(ProactiveNotice(
                agentType: .calendar,
                title: "Heavy meeting day",
                message: "You have \(Int(meetingHours)) hours of meetings. Based on your patterns, this impacts your deep work capacity.",
                priority: .medium,
                suggestedAction: "Block time for essential tasks between meetings",
                relatedContext: nil
            ))
        }

        // Task agent notices
        let overdueTasks = notionTasks.filter { task in
            if let dueDate = task.dueDate, dueDate < Date() {
                return task.status.lowercased() != "done" && task.status.lowercased() != "completed"
            }
            return false
        }
        if !overdueTasks.isEmpty {
            proactiveNotices.append(ProactiveNotice(
                agentType: .task,
                title: "\(overdueTasks.count) overdue task(s)",
                message: "Tasks need attention: \(overdueTasks.prefix(3).map { $0.title }.joined(separator: ", "))\(overdueTasks.count > 3 ? "..." : "")",
                priority: .high,
                suggestedAction: "Review and reschedule or complete overdue tasks",
                relatedContext: nil
            ))
        }

        // 3. Check for commitment reminders (from unified Tasks database)
        var commitmentReminders: [CommitmentReminder] = []

        if config.commitments?.enabled == true, notionService.tasksDatabaseId != nil {
            do {
                // Query overdue commitments from unified Tasks database
                let overdueCommitments = try await notionService.queryOverdueCommitmentsFromTasks()

                for commitment in overdueCommitments.prefix(5) {
                    let daysOverdue: Int?
                    if let dueDate = commitment.dueDate {
                        daysOverdue = Calendar.current.dateComponents([.day], from: dueDate, to: Date()).day
                    } else {
                        daysOverdue = nil
                    }

                    commitmentReminders.append(CommitmentReminder(
                        commitment: commitment.title,
                        committedTo: commitment.committedTo,
                        dueDate: commitment.dueDate,
                        daysOverdue: daysOverdue,
                        source: commitment.sourcePlatform.rawValue,
                        suggestedAction: commitment.type == .iOwe ? "Complete and deliver" : "Follow up with \(commitment.committedBy)"
                    ))
                }

                // Also check for upcoming commitments (due within 24 hours)
                let upcomingCommitments = try await notionService.queryUpcomingCommitmentsFromTasks(withinHours: 24)
                for commitment in upcomingCommitments.prefix(3) {
                    commitmentReminders.append(CommitmentReminder(
                        commitment: commitment.title,
                        committedTo: commitment.committedTo,
                        dueDate: commitment.dueDate,
                        daysOverdue: nil,
                        source: commitment.sourcePlatform.rawValue,
                        suggestedAction: "Due soon - prioritize today"
                    ))
                }
            } catch {
                // Silently ignore commitment query errors
            }
        }

        // 4. Cross-agent suggestions
        var crossAgentSuggestions: [CrossAgentSuggestion] = []

        // Communication + Calendar: External meeting with pending response
        for briefing in calendarBriefing.meetingBriefings {
            for attendee in briefing.event.externalAttendees {
                let attendeeName = attendee.name ?? attendee.email.components(separatedBy: "@").first ?? attendee.email
                if messagingSummary.needsResponse.contains(where: {
                    $0.thread.contactName?.lowercased().contains(attendeeName.lowercased()) ?? false
                }) {
                    crossAgentSuggestions.append(CrossAgentSuggestion(
                        title: "Reply before meeting",
                        description: "You have a pending message from \(attendeeName) and a meeting with them today. Consider responding before the meeting.",
                        involvedAgents: [.communication, .calendar],
                        confidence: 0.85
                    ))
                }
            }
        }

        // Task + Followup: Completed tasks that might need follow-up
        let completedTasks = notionTasks.filter {
            $0.status.lowercased() == "done" || $0.status.lowercased() == "completed"
        }
        let communicationTasks = completedTasks.filter { task in
            let keywords = ["send", "share", "deliver", "email", "message", "notify"]
            return keywords.contains { task.title.lowercased().contains($0) }
        }
        if !communicationTasks.isEmpty {
            crossAgentSuggestions.append(CrossAgentSuggestion(
                title: "Follow up on deliverables",
                description: "You completed \(communicationTasks.count) task(s) involving communication. Consider following up to confirm receipt.",
                involvedAgents: [.task, .followup],
                confidence: 0.7
            ))
        }

        return AgentInsights(
            recentLearnings: recentLearnings,
            proactiveNotices: proactiveNotices,
            commitmentReminders: commitmentReminders,
            crossAgentSuggestions: crossAgentSuggestions
        )
    }

    /// Extract a section from markdown memory content
    private func extractSection(from markdown: String, named sectionName: String) -> String? {
        let pattern = "## \(sectionName)\n([\\s\\S]*?)(?=\n## |$)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: markdown, options: [], range: NSRange(markdown.startIndex..., in: markdown)),
              let range = Range(match.range(at: 1), in: markdown) else {
            return nil
        }
        return String(markdown[range])
    }

    /// Parse recent learnings from a memory section
    private func parseRecentLearnings(_ section: String, agentType: AgentType, since: Date) -> [AgentLearning] {
        var learnings: [AgentLearning] = []
        let lines = section.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }

        let dateFormatter = ISO8601DateFormatter()

        for line in lines.prefix(5) {
            // Try to extract date from line (format: "- [date] learning text")
            if let bracketStart = line.firstIndex(of: "["),
               let bracketEnd = line.firstIndex(of: "]"),
               bracketStart < bracketEnd {
                let dateStr = String(line[line.index(after: bracketStart)..<bracketEnd])
                if let learnedDate = dateFormatter.date(from: dateStr), learnedDate >= since {
                    let text = String(line[line.index(after: bracketEnd)...]).trimmingCharacters(in: .whitespaces)
                    learnings.append(AgentLearning(
                        agentType: agentType,
                        description: text,
                        learnedAt: learnedDate,
                        confidence: 0.7
                    ))
                }
            } else {
                // No date, assume it's recent
                let text = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty {
                    learnings.append(AgentLearning(
                        agentType: agentType,
                        description: text,
                        learnedAt: Date(),
                        confidence: 0.6
                    ))
                }
            }
        }

        return learnings
    }

    /// Extract VIP contact patterns from communication agent memory
    private func extractVIPPatterns(from memory: String) -> [String] {
        var vips: [String] = []

        // Look for VIP mentions in rules or patterns
        let lines = memory.components(separatedBy: "\n")
        for line in lines {
            let lowercased = line.lowercased()
            if lowercased.contains("vip") || lowercased.contains("priority") || lowercased.contains("important contact") {
                // Extract name from the line
                let words = line.components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { $0.count > 2 && $0.first?.isUppercase == true }
                vips.append(contentsOf: words)
            }
        }

        return vips
    }

    // MARK: - Agent Digest Generation

    /// Generate a daily agent digest for end-of-day email
    func generateAgentDigest() async throws -> AgentDigest {
        let memoryService = AgentMemoryService.shared
        let decisionLog = DecisionLog.shared

        // 1. Get today's decisions from the decision log
        let todaysDecisions = try decisionLog.getDecisionsForToday()
        let executedCount = todaysDecisions.filter {
            if case .success = decisionLog.getExecutionResult(for: $0.id) { return true }
            return false
        }.count
        let pendingReview = todaysDecisions.filter { $0.requiresApproval &&
            decisionLog.getExecutionResult(for: $0.id) == nil }

        // 2. Gather new learnings from today
        let today = Calendar.current.startOfDay(for: Date())
        var newLearnings: [AgentLearning] = []
        for agentType in [AgentType.communication, .task, .calendar, .followup] {
            let learnings = parseRecentLearnings(memoryService.getMemory(for: agentType).content,
                                                  agentType: agentType,
                                                  since: today)
            newLearnings.append(contentsOf: learnings)
        }

        // 3. Build agent activity summaries
        var agentActivity: [AgentActivitySummary] = []
        for agentType in [AgentType.communication, .task, .calendar, .followup] {
            let agentDecisions = todaysDecisions.filter { $0.agentType == agentType }
            let successCount = agentDecisions.filter {
                if case .success = decisionLog.getExecutionResult(for: $0.id) { return true }
                return false
            }.count
            let successRate = agentDecisions.isEmpty ? 0.0 : Double(successCount) / Double(agentDecisions.count)

            // Find most common action type
            var actionCounts: [String: Int] = [:]
            for decision in agentDecisions {
                let actionKey = decision.action.description.components(separatedBy: ":").first ?? "Unknown"
                actionCounts[actionKey, default: 0] += 1
            }
            let topAction = actionCounts.max(by: { $0.value < $1.value })?.key

            // Get key insight from memory
            let memory = memoryService.getMemory(for: agentType)
            let keyInsight = extractSection(from: memory.content, named: "Active Rules")?
                .components(separatedBy: "\n")
                .first { $0.hasPrefix("- ") }?
                .dropFirst(2)
                .prefix(60)
                .description

            agentActivity.append(AgentActivitySummary(
                agentType: agentType,
                decisionsCount: agentDecisions.count,
                successRate: successRate,
                topAction: topAction,
                keyInsight: keyInsight.map { String($0) }
            ))
        }

        // 4. Get follow-ups due soon
        var upcomingFollowups: [FollowupDigestItem] = []
        if notionService.tasksDatabaseId != nil {
            let followups = try await notionService.queryActiveTasks(type: .followup)
            let now = Date()
            let threeDaysFromNow = Calendar.current.date(byAdding: .day, value: 3, to: now)!

            upcomingFollowups = followups
                .filter { ($0.dueDate ?? .distantFuture) <= threeDaysFromNow }
                .map { task in
                    FollowupDigestItem(
                        title: task.title,
                        scheduledFor: task.dueDate ?? now,
                        context: task.originalContext ?? task.description ?? "",
                        priority: UrgencyLevel(rawValue: task.priority?.rawValue.lowercased() ?? "medium") ?? .medium,
                        isOverdue: task.isOverdue
                    )
                }
                .sorted { $0.scheduledFor < $1.scheduledFor }
        }

        // 5. Get commitment status
        var commitmentStatus = CommitmentStatusSummary(
            activeIOwe: 0,
            activeTheyOwe: 0,
            completedToday: 0,
            overdueCount: 0,
            upcomingThisWeek: 0
        )

        if notionService.tasksDatabaseId != nil {
            let commitments = try await notionService.queryActiveTasks(type: .commitment)

            let now = Date()
            let weekFromNow = Calendar.current.date(byAdding: .day, value: 7, to: now)!

            commitmentStatus = CommitmentStatusSummary(
                activeIOwe: commitments.filter { $0.commitmentDirection == .iOwe }.count,
                activeTheyOwe: commitments.filter { $0.commitmentDirection == .theyOweMe }.count,
                completedToday: 0, // Would need to query completed items
                overdueCount: commitments.filter { $0.isOverdue }.count,
                upcomingThisWeek: commitments.filter {
                    guard let due = $0.dueDate else { return false }
                    return due >= now && due <= weekFromNow
                }.count
            )
        }

        // 6. Generate recommendations
        var recommendations: [String] = []

        if commitmentStatus.overdueCount > 0 {
            recommendations.append("You have \(commitmentStatus.overdueCount) overdue commitments that need attention")
        }

        if !upcomingFollowups.isEmpty {
            let overdueFollowups = upcomingFollowups.filter { $0.isOverdue }.count
            if overdueFollowups > 0 {
                recommendations.append("\(overdueFollowups) follow-ups are overdue - consider addressing them tomorrow")
            }
        }

        let lowSuccessAgents = agentActivity.filter { $0.successRate < 0.5 && $0.decisionsCount > 0 }
        for agent in lowSuccessAgents {
            recommendations.append("Consider reviewing \(agent.agentType.displayName) agent rules - success rate was \(Int(agent.successRate * 100))%")
        }

        if newLearnings.count > 5 {
            recommendations.append("Agents learned \(newLearnings.count) new patterns today - review in 'alfred agents memory'")
        }

        // Build summary
        let followupsCreated = todaysDecisions.filter {
            if case .createFollowup = $0.action { return true }
            return false
        }.count

        let summary = DigestSummary(
            totalDecisions: todaysDecisions.count,
            decisionsExecuted: executedCount,
            decisionsPending: pendingReview.count,
            newLearningsCount: newLearnings.count,
            followupsCreated: followupsCreated,
            commitmentsClosed: commitmentStatus.completedToday
        )

        return AgentDigest(
            date: Date(),
            summary: summary,
            agentActivity: agentActivity,
            newLearnings: newLearnings,
            decisionsRequiringReview: pendingReview,
            upcomingFollowups: upcomingFollowups,
            commitmentStatus: commitmentStatus,
            recommendations: recommendations,
            generatedAt: Date()
        )
    }
}
