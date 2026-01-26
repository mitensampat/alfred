import Foundation
import UserNotifications

// Main entry point - using Task with explicit exit
Task {
    await AlfredApp.main()
    Foundation.exit(0)
}

// Keep the process alive until Task completes
RunLoop.main.run()

struct AlfredApp {
    static func main() async {
        print("Alfred Starting...")

        // Load configuration
        guard let config = AppConfig.load(from: "Config/config.json") else {
            print("Error: Failed to load configuration")
            print("Please copy Config/config.example.json to Config/config.json and fill in your credentials")
            return
        }

        // Initialize orchestrator
        let orchestrator = BriefingOrchestrator(config: config)

        // Setup scheduler
        let scheduler = Scheduler(config: config, orchestrator: orchestrator)

        // Parse command line arguments
        let arguments = CommandLine.arguments

        // Check for --notify flag (sends to all enabled notification channels: email, Slack, push)
        let shouldSendNotifications = arguments.contains("--notify")
        let filteredArgs = arguments.filter { $0 != "--notify" }

        if shouldSendNotifications {
            print("🔔 Notifications enabled - will send to configured channels\n")
        }

        if filteredArgs.count > 1 {
            switch filteredArgs[1] {
            case "briefing":
                let date = filteredArgs.count > 2 ? parseDate(filteredArgs[2]) : nil
                await runBriefing(orchestrator, for: date, sendNotifications: shouldSendNotifications)
            case "messages":
                let platform = filteredArgs.count > 2 ? filteredArgs[2] : "all"

                // Check if this is a focused thread query (whatsapp + contact name)
                // Format: alfred messages whatsapp "Name" [timeframe]
                // vs: alfred messages whatsapp 24h (general)
                if platform.lowercased() == "whatsapp" && filteredArgs.count > 3 {
                    let thirdArg = filteredArgs[3]
                    // Check if third arg is a timeframe pattern (e.g., 1h, 24h, 7d) or a contact name
                    let timeframePattern = try? NSRegularExpression(pattern: "^\\d+[hdw]$", options: .caseInsensitive)
                    let isTimeframe = timeframePattern?.firstMatch(in: thirdArg, range: NSRange(thirdArg.startIndex..., in: thirdArg)) != nil

                    if isTimeframe {
                        // General query: alfred messages whatsapp 24h
                        await runMessagesSummary(orchestrator, platform: platform, timeframe: thirdArg)
                    } else {
                        // Focused query: alfred messages whatsapp "Name" [timeframe]
                        let contactName = thirdArg
                        let timeframe = filteredArgs.count > 4 ? filteredArgs[4] : "24h"
                        await runFocusedWhatsAppThread(orchestrator, contactName: contactName, timeframe: timeframe)
                    }
                } else {
                    let timeframe = filteredArgs.count > 3 ? filteredArgs[3] : "24h"
                    await runMessagesSummary(orchestrator, platform: platform, timeframe: timeframe)
                }
            case "calendar":
                let firstArg = filteredArgs.count > 2 ? filteredArgs[2] : nil
                let secondArg = filteredArgs.count > 3 ? filteredArgs[3] : nil

                // Determine if first arg is calendar name or date
                let calendarNames = ["primary", "work", "all"]
                let (calendarFilter, dateArg): (String, String?) = {
                    if let first = firstArg, calendarNames.contains(first.lowercased()) {
                        return (first.lowercased(), secondArg)
                    } else {
                        return ("all", firstArg)
                    }
                }()

                let date = dateArg.flatMap { parseDate($0) }
                await runCalendar(orchestrator, for: date, calendar: calendarFilter)
            case "attention":
                // Sub-commands for attention system
                if filteredArgs.count > 2 {
                    let subcommand = filteredArgs[2]
                    switch subcommand {
                    case "init":
                        await runAttentionInit()
                    case "report":
                        let scope = filteredArgs.count > 3 ? filteredArgs[3] : "both"
                        let period = filteredArgs.count > 4 ? filteredArgs[4] : "week"
                        await runAttentionReport(orchestrator, scope: scope, period: period)
                    case "calendar":
                        let period = filteredArgs.count > 3 ? filteredArgs[3] : "week"
                        await runAttentionReport(orchestrator, scope: "calendar", period: period)
                    case "messaging":
                        let period = filteredArgs.count > 3 ? filteredArgs[3] : "week"
                        await runAttentionReport(orchestrator, scope: "messaging", period: period)
                    case "plan":
                        let days = filteredArgs.count > 3 ? Int(filteredArgs[3]) ?? 7 : 7
                        await runAttentionPlan(orchestrator, days: days)
                    case "priorities":
                        await runCollectPriorities(orchestrator)
                    case "config":
                        await runAttentionConfig()
                    default:
                        print("Unknown attention subcommand: \(subcommand)")
                        printAttentionUsage()
                    }
                } else {
                    // Default: run attention defense
                    await runAttentionDefense(orchestrator, sendNotifications: shouldSendNotifications)
                }
            case "commitments":
                if filteredArgs.count > 2 {
                    let subcommand = filteredArgs[2]
                    switch subcommand {
                    case "init":
                        await runCommitmentsInit(orchestrator)
                    case "scan":
                        await runCommitmentsScan(orchestrator, args: Array(filteredArgs.dropFirst(3)))
                    case "list":
                        await runCommitmentsList(orchestrator, args: Array(filteredArgs.dropFirst(3)))
                    case "overdue":
                        await runCommitmentsOverdue(orchestrator)
                    default:
                        printCommitmentsUsage()
                    }
                } else {
                    printCommitmentsUsage()
                }
            case "schedule":
                print("Starting scheduled mode...")
                await scheduler.start()
            case "auth":
                await runGoogleAuth(config)
            case "auth-gmail":
                await runGmailAuth(config)
            case "notion-todos":
                await runNotionTodos(orchestrator)
            case "test-notion":
                await testNotion(orchestrator)
            case "drafts":
                await runShowDrafts()
            case "clear-drafts":
                await runClearDrafts()
            case "agents":
                await runAgentsCommand(filteredArgs)
            case "teach":
                await runTeachCommand(filteredArgs)
            case "digest":
                await runAgentDigest(orchestrator)
            case "server":
                await runServer(config, orchestrator)
            default:
                printUsage()
            }
        } else {
            printUsage()
        }
    }

    static func requestNotificationPermissions() async {
        let center = UNUserNotificationCenter.current()
        do {
            try await center.requestAuthorization(options: [.alert, .sound, .badge])
            print("Notification permissions granted")
        } catch {
            print("Failed to get notification permissions: \(error)")
        }
    }

    static func parseDate(_ dateString: String) -> Date? {
        // Try formats: "tomorrow", "2026-01-15", "+2" (days from now)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]

        if dateString.lowercased() == "tomorrow" {
            return Calendar.current.date(byAdding: .day, value: 1, to: Date())
        } else if dateString.lowercased() == "today" {
            return Date()
        } else if dateString.hasPrefix("+") {
            let days = Int(dateString.dropFirst()) ?? 0
            return Calendar.current.date(byAdding: .day, value: days, to: Date())
        } else if let date = formatter.date(from: dateString) {
            return date
        }
        return nil
    }

    static func runBriefing(_ orchestrator: BriefingOrchestrator, for date: Date?, sendNotifications: Bool) async {
        let targetDate = date ?? Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        print("\nGenerating briefing for \(targetDate.formatted(date: .long, time: .omitted))...\n")
        do {
            let briefing = try await orchestrator.generateBriefing(for: targetDate, sendNotifications: sendNotifications)
            print("\n=== DAILY BRIEFING ===\n")
            printBriefing(briefing)
            if sendNotifications {
                var channels: [String] = []
                if orchestrator.config.notifications.email.enabled {
                    channels.append("email")
                }
                if orchestrator.config.notifications.slack.enabled {
                    channels.append("Slack")
                }
                if orchestrator.config.notifications.push.enabled {
                    channels.append("push")
                }
                print("\n✓ Briefing sent via \(channels.joined(separator: ", "))")
            }
        } catch {
            print("Error generating briefing: \(error)")
        }
    }

    static func runMessagesSummary(_ orchestrator: BriefingOrchestrator, platform: String, timeframe: String) async {
        do {
            let summary = try await orchestrator.getMessagesSummary(platform: platform, timeframe: timeframe)
            print("=== MESSAGES SUMMARY ===\n")
            printMessagesSummary(summary)

            // Generate drafts for messages needing responses
            let draftCount = try await orchestrator.generateDraftsForMessages(summary)
            if draftCount > 0 {
                print("💡 Tip: Run 'alfred drafts' to review and send the \(draftCount) draft(s)\n")
            }

            // Extract recommended actions
            let recommendedActions = orchestrator.extractRecommendedActions(from: summary)

            if !recommendedActions.isEmpty {
                print("\n" + String(repeating: "=", count: 60))
                print("\n💡 RECOMMENDED ACTIONS FOR NOTION")
                print(String(repeating: "-", count: 60))
                print("\nI found \(recommendedActions.count) critical action item(s) from your messages:\n")

                for (index, action) in recommendedActions.enumerated() {
                    print("\(index + 1). \(action.priority.emoji) \(action.title)")
                    print("   Source: \(action.source.displayName)")
                    print("   \(action.description)")
                    print("")
                }

                print("Would you like to add these to your Notion todo list? (yes/no): ", terminator: "")

                if let response = readLine()?.lowercased(), response == "yes" || response == "y" {
                    print("\n📓 Adding actions to Notion...")
                    let createdIds = try await orchestrator.addRecommendedActionsToNotion(recommendedActions)
                    print("\n✓ Successfully added \(createdIds.count) action item(s) to Notion\n")
                } else {
                    print("\n⏭️  Skipped adding actions to Notion\n")
                }
            }
        } catch {
            print("Error fetching messages: \(error)")
        }
    }

    static func runFocusedWhatsAppThread(_ orchestrator: BriefingOrchestrator, contactName: String, timeframe: String) async {
        do {
            let analysis = try await orchestrator.getFocusedWhatsAppThread(contactName: contactName, timeframe: timeframe)
            print("=== WHATSAPP THREAD ANALYSIS ===\n")
            printFocusedThreadAnalysis(analysis)

            // Generate draft response for this thread
            let draftCount = try await orchestrator.generateDraftForThread(analysis)
            if draftCount > 0 {
                print("💡 Tip: Run 'alfred drafts' to review and send the draft\n")
            }

            // Extract recommended actions
            let recommendedActions = orchestrator.extractRecommendedActions(from: analysis)

            if !recommendedActions.isEmpty {
                print("\n" + String(repeating: "=", count: 60))
                print("\n💡 RECOMMENDED ACTIONS FOR NOTION")
                print(String(repeating: "-", count: 60))
                print("\nI found \(recommendedActions.count) critical action item(s) from this conversation:\n")

                for (index, action) in recommendedActions.enumerated() {
                    print("\(index + 1). \(action.priority.emoji) \(action.title)")
                    print("   \(action.description)")
                    if let dueDate = action.dueDate {
                        print("   Due: \(dueDate.formatted(date: .abbreviated, time: .omitted))")
                    }
                    print("")
                }

                print("Would you like to add these to your Notion todo list? (yes/no): ", terminator: "")

                if let response = readLine()?.lowercased(), response == "yes" || response == "y" {
                    print("\n📓 Adding actions to Notion...")
                    let createdIds = try await orchestrator.addRecommendedActionsToNotion(recommendedActions)
                    print("\n✓ Successfully added \(createdIds.count) action item(s) to Notion\n")
                } else {
                    print("\n⏭️  Skipped adding actions to Notion\n")
                }
            }
        } catch {
            print("Error analyzing WhatsApp thread: \(error)")
        }
    }

    static func runCalendar(_ orchestrator: BriefingOrchestrator, for date: Date?, calendar: String) async {
        let targetDate = date ?? Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        do {
            let calendarBriefing = try await orchestrator.getCalendarBriefing(for: targetDate, calendar: calendar)
            print("=== CALENDAR BRIEFING ===\n")
            printCalendarBriefing(calendarBriefing)
        } catch {
            print("Error fetching calendar: \(error)")
        }
    }

    static func runAttentionDefense(_ orchestrator: BriefingOrchestrator, sendNotifications: Bool) async {
        print("\nGenerating attention defense report...\n")
        do {
            let report = try await orchestrator.generateAttentionDefenseAlert(sendNotifications: sendNotifications)
            print("\n=== ATTENTION DEFENSE REPORT ===\n")
            printAttentionReport(report)
            if sendNotifications {
                var channels: [String] = []
                if orchestrator.config.notifications.email.enabled {
                    channels.append("email")
                }
                if orchestrator.config.notifications.slack.enabled {
                    channels.append("Slack")
                }
                if orchestrator.config.notifications.push.enabled {
                    channels.append("push")
                }
                print("\n✓ Report sent via \(channels.joined(separator: ", "))")
            }
        } catch {
            print("Error generating report: \(error)")
        }
    }

    // MARK: - Enhanced Attention Commands

    static func runAttentionInit() async {
        print("\n=== INITIALIZE ATTENTION PREFERENCES ===\n")
        print("Creating attention preferences configuration...")

        let templatePath = "Config/attention_preferences.json"
        let template = """
{
  "version": "1.0",
  "last_updated": "\(ISO8601DateFormatter().string(from: Date()))",
  "priorities": [
    {
      "id": "deep_work",
      "description": "Deep focused work on strategic projects",
      "weight": 0.4,
      "keywords": ["strategic", "planning", "development"],
      "time_allocation": 40.0
    },
    {
      "id": "collaboration",
      "description": "Team collaboration and coordination",
      "weight": 0.3,
      "keywords": ["team", "sync", "meeting"],
      "time_allocation": 30.0
    },
    {
      "id": "communication",
      "description": "Responding to messages and emails",
      "weight": 0.2,
      "keywords": ["response", "reply", "message"],
      "time_allocation": 20.0
    },
    {
      "id": "administrative",
      "description": "Administrative tasks and overhead",
      "weight": 0.1,
      "keywords": ["admin", "overhead"],
      "time_allocation": 10.0
    }
  ],
  "meeting_preferences": {
    "high_value": ["strategic", "planning", "1:1", "customer"],
    "low_value": ["status update", "fyi", "optional"],
    "max_meetings_per_day": 5,
    "max_meetings_per_week": 20,
    "max_hours_per_day": 6.0,
    "max_hours_per_week": 25.0,
    "category_overrides": {},
    "minimum_focus_block_hours": 2.0,
    "preferred_focus_time_slots": ["9am-12pm", "2pm-5pm"]
  },
  "messaging_preferences": {
    "high_priority_contacts": [],
    "low_priority_contacts": [],
    "target_response_time_urgent": 3600,
    "target_response_time_important": 14400,
    "target_response_time_routine": 86400,
    "auto_decline_patterns": []
  },
  "time_allocation": {
    "period": "weekly",
    "goals": [
      {
        "category": "Strategic",
        "target_percentage": 40.0,
        "current_percentage": null,
        "variance": null
      },
      {
        "category": "Collaborative",
        "target_percentage": 30.0,
        "current_percentage": null,
        "variance": null
      },
      {
        "category": "Tactical",
        "target_percentage": 20.0,
        "current_percentage": null,
        "variance": null
      },
      {
        "category": "Informational",
        "target_percentage": 10.0,
        "current_percentage": null,
        "variance": null
      }
    ]
  },
  "query_defaults": {
    "default_lookback_days": 7,
    "default_lookforward_days": 14,
    "week_start_day": "monday"
  }
}
"""

        do {
            // Try to write to the Alfred project Config directory first
            let preferredPath = (NSString(string: "~/Documents/Claude apps/Alfred/Config/attention_preferences.json").expandingTildeInPath)
            let fileURL = URL(fileURLWithPath: preferredPath)

            // Create Config directory if it doesn't exist
            let configDir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)

            try template.write(to: fileURL, atomically: true, encoding: .utf8)
            print("✓ Created attention preferences at: \(preferredPath)")
            print("\n📝 Edit this file to customize your attention preferences")
            print("💡 Run 'alfred attention report' to see your attention metrics")
        } catch {
            print("⚠️  Failed to create preferences file: \(error)")
        }
    }

    static func runAttentionReport(_ orchestrator: BriefingOrchestrator, scope: String, period: String) async {
        print("\n=== ATTENTION REPORT ===\n")
        print("Scope: \(scope)")
        print("Period: \(period)\n")

        do {
            // Parse period
            let query = parseAttentionQuery(scope: scope, period: period)

            // Process calendar and messaging completely separately
            if query.includeCalendar && !query.includeMessaging {
                // Calendar only - fast path
                print("📅 Analyzing calendar attention...\n")
                try await runCalendarOnlyReport(orchestrator, query: query)
            } else if query.includeMessaging && !query.includeCalendar {
                // Messaging only - streaming processing for large volumes
                print("💬 Analyzing messaging attention...\n")
                try await runMessagingOnlyReport(orchestrator, query: query)
            } else {
                // Both - process separately then combine
                print("📊 Analyzing both calendar and messaging...\n")
                try await runCombinedReport(orchestrator, query: query)
            }

        } catch {
            print("Error generating attention report: \(error)")
        }
    }

    static func runCalendarOnlyReport(_ orchestrator: BriefingOrchestrator, query: AttentionQuery) async throws {
        let events = try await orchestrator.fetchCalendarEvents(
            from: query.period.start,
            to: query.period.end
        )

        print("✓ Found \(events.count) calendar event(s)\n")

        guard let agentManager = orchestrator.publicAgentManager,
              let taskAgent = agentManager.getTaskAgent() else {
            print("⚠️  Agents not enabled")
            return
        }

        let report = try await taskAgent.analyzeAttention(
            query: query,
            events: events,
            messages: []
        )

        printDetailedAttentionReport(report)
    }

    static func runMessagingOnlyReport(_ orchestrator: BriefingOrchestrator, query: AttentionQuery) async throws {
        // Fetch messages with limit to avoid memory issues
        print("📱 Fetching messages (this may take a moment for large volumes)...\n")

        let messages = try await orchestrator.getMessagesSummary(
            platform: "all",
            timeframe: calculateTimeframe(from: query.period.start, to: query.period.end)
        )

        print("✓ Found \(messages.count) message thread(s)\n")

        guard let agentManager = orchestrator.publicAgentManager,
              let taskAgent = agentManager.getTaskAgent() else {
            print("⚠️  Agents not enabled")
            return
        }

        let report = try await taskAgent.analyzeAttention(
            query: query,
            events: [],
            messages: messages
        )

        printDetailedAttentionReport(report)
    }

    static func runCombinedReport(_ orchestrator: BriefingOrchestrator, query: AttentionQuery) async throws {
        // Process calendar first (fast)
        print("📅 Step 1/2: Analyzing calendar...")
        let events = try await orchestrator.fetchCalendarEvents(
            from: query.period.start,
            to: query.period.end
        )
        print("✓ Found \(events.count) calendar event(s)\n")

        // Process messages second (slower)
        print("💬 Step 2/2: Analyzing messages...")
        let messages = try await orchestrator.getMessagesSummary(
            platform: "all",
            timeframe: calculateTimeframe(from: query.period.start, to: query.period.end)
        )
        print("✓ Found \(messages.count) message thread(s)\n")

        guard let agentManager = orchestrator.publicAgentManager,
              let taskAgent = agentManager.getTaskAgent() else {
            print("⚠️  Agents not enabled")
            return
        }

        print("🔄 Generating combined report...\n")

        let report = try await taskAgent.analyzeAttention(
            query: query,
            events: events,
            messages: messages
        )

        printDetailedAttentionReport(report)
    }

    static func runAttentionPlan(_ orchestrator: BriefingOrchestrator, days: Int) async {
        print("\n=== ATTENTION PLANNING ===\n")
        print("Planning for next \(days) days\n")

        do {
            // Get upcoming events
            let start = Date()
            let end = Calendar.current.date(byAdding: .day, value: days, to: start)!

            let events = try await orchestrator.fetchCalendarEvents(from: start, to: end)

            // Create planning request (simplified - would prompt user for details)
            let request = AttentionPlanRequest(
                period: AttentionPlanRequest.TimePeriod(
                    start: start,
                    end: end,
                    description: "next \(days) days"
                ),
                priorities: ["Focus on strategic work", "Limit meetings"],
                constraints: [
                    AttentionPlanRequest.Constraint(
                        type: .maxMeetingHours,
                        description: "Maximum 6 hours of meetings per day",
                        value: 6.0
                    ),
                    AttentionPlanRequest.Constraint(
                        type: .requiredFocusTime,
                        description: "At least 2 hours of focus time per day",
                        value: 2.0
                    )
                ],
                goals: [
                    AttentionPlanRequest.Goal(
                        description: "Deep work on strategic projects",
                        category: "Strategic",
                        targetHours: Double(days) * 3,
                        priority: 1
                    )
                ]
            )

            // Generate plan using TaskAgent
            guard let agentManager = orchestrator.publicAgentManager,
                  let taskAgent = agentManager.getTaskAgent() else {
                print("⚠️  Agents not enabled")
                return
            }

            let plan = try await taskAgent.planAttention(request: request, currentEvents: events)

            // Print plan
            printAttentionPlan(plan)

        } catch {
            print("Error generating attention plan: \(error)")
        }
    }

    static func runCollectPriorities(_ orchestrator: BriefingOrchestrator) async {
        print("\n=== COLLECT MEETING PRIORITIES ===\n")
        print("Analyzing your meetings to understand priorities...\n")

        do {
            // Get last 30 days of meetings
            let end = Date()
            let start = Calendar.current.date(byAdding: .day, value: -30, to: end)!

            let events = try await orchestrator.fetchCalendarEvents(from: start, to: end)

            guard let agentManager = orchestrator.publicAgentManager,
                  let taskAgent = agentManager.getTaskAgent() else {
                print("⚠️  Agents not enabled")
                return
            }

            print("Found \(events.count) meetings in last 30 days")
            print("Analyzing patterns...\n")

            let categorizations = try await taskAgent.collectMeetingPriorities(events: events)

            print("\n=== MEETING CATEGORIZATIONS ===\n")
            for (pattern, category) in categorizations.sorted(by: { $0.key < $1.key }) {
                print("📌 \(pattern)")
                print("   Category: \(category.rawValue)\n")
            }

            print("\n💡 These categorizations will be saved to your attention preferences")
            print("💡 Run 'alfred attention report' to see updated metrics")

        } catch {
            print("Error collecting priorities: \(error)")
        }
    }

    static func runAttentionConfig() async {
        print("\n=== ATTENTION CONFIGURATION ===\n")

        // Find the config file
        let paths = [
            (NSString(string: "~/Documents/Claude apps/Alfred/Config/attention_preferences.json").expandingTildeInPath),
            (NSString(string: "~/.config/alfred/attention_preferences.json").expandingTildeInPath)
        ]

        var configPath: String?
        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                configPath = path
                break
            }
        }

        guard let path = configPath else {
            print("⚠️  No attention preferences file found")
            print("💡 Run 'alfred attention init' to create one")
            return
        }

        print("📍 Config file: \(path)")
        print("")

        // Load current config
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            print("⚠️  Failed to read preferences file")
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let currentPrefs = try? decoder.decode(AttentionPreferences.self, from: data) else {
            print("⚠️  Failed to parse current preferences")
            return
        }

        // Interactive menu
        print("What would you like to configure?\n")
        print("1. Query defaults (lookback/lookforward windows)")
        print("2. Meeting preferences (meeting limits)")
        print("3. Time allocation goals")
        print("4. View current configuration")
        print("5. Exit")
        print("")

        print("Enter choice (1-5): ", terminator: "")
        guard let choice = readLine()?.trimmingCharacters(in: .whitespaces) else { return }

        switch choice {
        case "1":
            await configureQueryDefaults(path: path, current: currentPrefs)
        case "2":
            await configureMeetingPreferences(path: path, current: currentPrefs)
        case "3":
            await configureTimeAllocation(path: path, current: currentPrefs)
        case "4":
            printCurrentConfiguration(currentPrefs)
        case "5":
            print("👋 Exiting")
        default:
            print("Invalid choice")
        }
    }

    static func configureQueryDefaults(path: String, current: AttentionPreferences) async {
        print("\n=== QUERY DEFAULTS ===\n")

        let currentDefaults = current.queryDefaults
        let currentLookback = currentDefaults?.defaultLookbackDays ?? 7
        let currentLookforward = currentDefaults?.defaultLookforwardDays ?? 14
        let currentWeekStart = currentDefaults?.weekStartDay ?? "monday"

        print("Current settings:")
        print("  Lookback days: \(currentLookback)")
        print("  Lookforward days: \(currentLookforward)")
        print("  Week start: \(currentWeekStart)")
        print("")

        print("Enter new lookback days [\(currentLookback)]: ", terminator: "")
        let lookbackInput = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
        let newLookback = Int(lookbackInput) ?? currentLookback

        print("Enter new lookforward days [\(currentLookforward)]: ", terminator: "")
        let lookforwardInput = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
        let newLookforward = Int(lookforwardInput) ?? currentLookforward

        print("Enter week start day (monday/sunday) [\(currentWeekStart)]: ", terminator: "")
        let weekStartInput = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        let newWeekStart = weekStartInput.isEmpty ? currentWeekStart : weekStartInput

        // Update the config
        do {
            var data = try Data(contentsOf: URL(fileURLWithPath: path))
            var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

            json["query_defaults"] = [
                "default_lookback_days": newLookback,
                "default_lookforward_days": newLookforward,
                "week_start_day": newWeekStart
            ]
            json["last_updated"] = ISO8601DateFormatter().string(from: Date())

            let newData = try JSONSerialization.data(withJSONObject: json, options: .prettyPrinted)
            try newData.write(to: URL(fileURLWithPath: path))

            print("\n✓ Configuration updated successfully!")
            print("\n📝 New settings:")
            print("  Lookback days: \(newLookback)")
            print("  Lookforward days: \(newLookforward)")
            print("  Week start: \(newWeekStart)")
        } catch {
            print("⚠️  Failed to update configuration: \(error)")
        }
    }

    static func configureMeetingPreferences(path: String, current: AttentionPreferences) async {
        print("\n=== MEETING PREFERENCES ===\n")

        let prefs = current.meetingPreferences

        print("Current settings:")
        print("  Max meetings per day: \(prefs.maxMeetingsPerDay ?? 0)")
        print("  Max meetings per week: \(prefs.maxMeetingsPerWeek ?? 0)")
        print("  Max hours per day: \(prefs.maxHoursPerDay ?? 0.0)")
        print("  Max hours per week: \(prefs.maxHoursPerWeek ?? 0.0)")
        print("  Minimum focus block: \(prefs.minimumFocusBlockHours) hours")
        print("")

        print("Enter new max meetings per day [\(prefs.maxMeetingsPerDay ?? 0)]: ", terminator: "")
        let maxDayInput = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
        let newMaxDay = Int(maxDayInput) ?? (prefs.maxMeetingsPerDay ?? 0)

        print("Enter new max hours per day [\(prefs.maxHoursPerDay ?? 0.0)]: ", terminator: "")
        let maxHoursInput = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
        let newMaxHours = Double(maxHoursInput) ?? (prefs.maxHoursPerDay ?? 0.0)

        print("Enter minimum focus block hours [\(prefs.minimumFocusBlockHours)]: ", terminator: "")
        let focusInput = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
        let newFocus = Double(focusInput) ?? prefs.minimumFocusBlockHours

        // Update the config
        do {
            var data = try Data(contentsOf: URL(fileURLWithPath: path))
            var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            var meetingPrefs = json["meeting_preferences"] as! [String: Any]

            meetingPrefs["max_meetings_per_day"] = newMaxDay
            meetingPrefs["max_hours_per_day"] = newMaxHours
            meetingPrefs["minimum_focus_block_hours"] = newFocus

            json["meeting_preferences"] = meetingPrefs
            json["last_updated"] = ISO8601DateFormatter().string(from: Date())

            let newData = try JSONSerialization.data(withJSONObject: json, options: .prettyPrinted)
            try newData.write(to: URL(fileURLWithPath: path))

            print("\n✓ Configuration updated successfully!")
        } catch {
            print("⚠️  Failed to update configuration: \(error)")
        }
    }

    static func configureTimeAllocation(path: String, current: AttentionPreferences) async {
        print("\n=== TIME ALLOCATION GOALS ===\n")

        print("Current allocation targets:")
        for goal in current.timeAllocation.goals {
            print("  \(goal.category): \(goal.targetPercentage)%")
        }
        print("")

        print("Enter category to update (or 'done'): ", terminator: "")
        guard let category = readLine()?.trimmingCharacters(in: .whitespaces), category.lowercased() != "done" else {
            return
        }

        print("Enter new target percentage for \(category): ", terminator: "")
        guard let percentInput = readLine()?.trimmingCharacters(in: .whitespaces),
              let newPercent = Double(percentInput) else {
            print("Invalid percentage")
            return
        }

        // Update the config
        do {
            var data = try Data(contentsOf: URL(fileURLWithPath: path))
            var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            var timeAlloc = json["time_allocation"] as! [String: Any]
            var goals = timeAlloc["goals"] as! [[String: Any]]

            for (index, goal) in goals.enumerated() {
                if let cat = goal["category"] as? String, cat.lowercased() == category.lowercased() {
                    goals[index]["target_percentage"] = newPercent
                    break
                }
            }

            timeAlloc["goals"] = goals
            json["time_allocation"] = timeAlloc
            json["last_updated"] = ISO8601DateFormatter().string(from: Date())

            let newData = try JSONSerialization.data(withJSONObject: json, options: .prettyPrinted)
            try newData.write(to: URL(fileURLWithPath: path))

            print("\n✓ Configuration updated successfully!")
            print("💡 Run this command again to update more categories")
        } catch {
            print("⚠️  Failed to update configuration: \(error)")
        }
    }

    static func printCurrentConfiguration(_ prefs: AttentionPreferences) {
        print("\n=== CURRENT CONFIGURATION ===\n")

        print("📅 Query Defaults:")
        if let defaults = prefs.queryDefaults {
            print("  Lookback days: \(defaults.defaultLookbackDays)")
            print("  Lookforward days: \(defaults.defaultLookforwardDays)")
            print("  Week start: \(defaults.weekStartDay)")
        } else {
            print("  Not configured")
        }

        print("\n📊 Meeting Preferences:")
        let mp = prefs.meetingPreferences
        print("  Max meetings/day: \(mp.maxMeetingsPerDay ?? 0)")
        print("  Max meetings/week: \(mp.maxMeetingsPerWeek ?? 0)")
        print("  Max hours/day: \(mp.maxHoursPerDay ?? 0.0)")
        print("  Max hours/week: \(mp.maxHoursPerWeek ?? 0.0)")
        print("  Min focus block: \(mp.minimumFocusBlockHours)h")

        print("\n🎯 Time Allocation Goals:")
        for goal in prefs.timeAllocation.goals {
            print("  \(goal.category): \(goal.targetPercentage)%")
        }

        print("\n📍 File location:")
        let paths = [
            (NSString(string: "~/Documents/Claude apps/Alfred/Config/attention_preferences.json").expandingTildeInPath),
            (NSString(string: "~/.config/alfred/attention_preferences.json").expandingTildeInPath)
        ]
        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                print("  \(path)")
                break
            }
        }

        print("\n💡 Edit the file directly for advanced configuration")
        print("💡 Run 'alfred attention config' to use interactive mode")
    }

    // MARK: - Attention Helper Functions

    static func parseAttentionQuery(scope: String, period: String) -> AttentionQuery {
        let queryPeriod: AttentionQuery.Period

        // Check if period is a number (e.g., "7", "30", "-14")
        if let days = Int(period) {
            if days > 0 {
                // Positive number = look forward
                queryPeriod = .nextNDays(days)
            } else if days < 0 {
                // Negative number = look back
                queryPeriod = .lastNDays(abs(days))
            } else {
                queryPeriod = .today()
            }
        } else {
            // Named periods
            switch period.lowercased() {
            case "today":
                queryPeriod = .today()
            case "week", "thisweek":
                queryPeriod = .thisWeek()
            case "lastweek":
                queryPeriod = .lastWeek()
            case "nextweek":
                queryPeriod = .nextWeek()
            default:
                queryPeriod = .thisWeek()
            }
        }

        let includeCalendar = scope == "calendar" || scope == "both"
        let includeMessaging = scope == "messaging" || scope == "both"

        return AttentionQuery(
            scope: scope == "calendar" ? .calendar : (scope == "messaging" ? .messaging : .both),
            period: queryPeriod,
            includeCalendar: includeCalendar,
            includeMessaging: includeMessaging,
            compareWithGoals: true
        )
    }

    static func calculateTimeframe(from start: Date, to end: Date) -> String {
        let hours = Int(end.timeIntervalSince(start) / 3600)
        if hours < 24 {
            return "\(hours)h"
        }
        let days = hours / 24
        return "\(days)d"
    }

    static func printDetailedAttentionReport(_ report: AttentionReport) {
        print("Period: \(report.period.description)")
        print("Type: \(report.period.type.rawValue)\n")

        // Calendar metrics
        if report.calendar.meetingCount > 0 {
            print("=== CALENDAR ATTENTION ===\n")
            print("Total Meeting Time: \(formatDuration(report.calendar.totalMeetingTime))")
            print("Meeting Count: \(report.calendar.meetingCount)")
            print("Utilization Score: \(Int(report.calendar.utilizationScore))%")
            print("Estimated Waste: \(formatDuration(report.calendar.wastedTimeEstimate))\n")

            print("Breakdown by Category:")
            for (category, stats) in report.calendar.breakdown.sorted(by: { $0.key.priority < $1.key.priority }) {
                print("  \(category.rawValue): \(formatDuration(stats.timeSpent)) (\(Int(stats.percentage))%)")
            }

            print("\nTop Time Consumers:")
            for (index, pattern) in report.calendar.topTimeConsumers.prefix(5).enumerated() {
                print("  \(index + 1). \(pattern.pattern)")
                print("     \(pattern.occurrences) meetings, \(formatDuration(pattern.totalTime)) total")
            }
            print()
        }

        // Messaging metrics
        if report.messaging.totalThreads > 0 {
            print("=== MESSAGING ATTENTION ===\n")
            print("Total Threads: \(report.messaging.totalThreads)")
            print("Responses Given: \(report.messaging.responsesGiven)")
            print("Utilization Score: \(Int(report.messaging.utilizationScore))%\n")

            print("Breakdown by Category:")
            for (category, stats) in report.messaging.breakdown.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                print("  \(category.rawValue): \(stats.threadCount) threads (\(Int(stats.percentage))%)")
            }

            print("\nTop Thread Consumers:")
            for (index, thread) in report.messaging.topTimeConsumers.prefix(5).enumerated() {
                print("  \(index + 1). \(thread.contact)")
                print("     \(thread.messageCount) messages, \(String(format: "%.1f", thread.averageMessagesPerDay)) msg/day")
            }
            print()
        }

        // Overall scores
        print("=== OVERALL ATTENTION ===\n")
        print("Focus Score: \(Int(report.overall.focusScore))%")
        print("Balance Score: \(Int(report.overall.balanceScore))%")
        print("Efficiency Score: \(Int(report.overall.efficiencyScore))%")
        print("Goal Alignment: \(Int(report.overall.alignmentWithGoals))%\n")

        // Recommendations
        if !report.recommendations.isEmpty {
            print("=== RECOMMENDATIONS ===\n")
            for (index, rec) in report.recommendations.enumerated() {
                print("\(index + 1). [\(rec.priority.rawValue.uppercased())] \(rec.title)")
                print("   \(rec.description)")
                if let action = rec.suggestedAction {
                    print("   → \(action)")
                }
                print()
            }
        }
    }

    static func printAttentionPlan(_ plan: AttentionPlan) {
        print("Planning Period: \(plan.request.period.description)\n")

        print("=== CURRENT COMMITMENTS ===\n")
        print("Total commitments: \(plan.currentCommitments.count)")
        let totalHours = plan.currentCommitments.reduce(0.0) { $0 + $1.duration } / 3600
        print("Total hours: \(String(format: "%.1f", totalHours))h\n")

        // Group by category
        let byCategory = Dictionary(grouping: plan.currentCommitments, by: { $0.category })
        for category in MeetingCategory.allCases {
            if let commitments = byCategory[category], !commitments.isEmpty {
                let hours = commitments.reduce(0.0) { $0 + $1.duration } / 3600
                print("\(category.rawValue): \(commitments.count) meetings, \(String(format: "%.1f", hours))h")
            }
        }

        print("\n=== RECOMMENDATIONS ===\n")
        for (index, rec) in plan.recommendations.enumerated() {
            print("\(index + 1). \(rec.title)")
            print("   Action: \(rec.action.rawValue)")
            print("   \(rec.description)")
            print("   Impact: \(rec.impact)")
            print("   Effort: \(rec.effort)\n")
        }

        if !plan.conflicts.isEmpty {
            print("=== CONFLICTS ===\n")
            for conflict in plan.conflicts {
                print("⚠️  [\(conflict.severity.rawValue.uppercased())] \(conflict.description)")
                print("   Affected: \(conflict.affectedGoal)")
                print("   Resolution: \(conflict.suggestedResolution)\n")
            }
        }

        print("=== PROJECTED ATTENTION ===\n")
        print("Focus Score: \(Int(plan.projectedAttention.focusScore))%")
        print("Efficiency Score: \(Int(plan.projectedAttention.efficiencyScore))%")
        print("Goal Alignment: \(Int(plan.projectedAttention.alignmentWithGoals))%")
        print("\n\(plan.projectedAttention.summary)")
    }

    static func printAttentionUsage() {
        print("""

        Usage: alfred attention [subcommand] [options]

        Subcommands:
          (none)              Run attention defense (default)
          init                Create attention preferences configuration
          report [scope] [period]  Generate detailed attention report
          calendar [period]   Analyze calendar attention only
          messaging [period]  Analyze messaging attention only
          plan [days]         Plan attention for next N days (default: 7)
          priorities          Collect and categorize meeting priorities

        Scope (for report):
          both                Both calendar and messaging (default)
          calendar            Calendar only
          messaging           Messaging only

        Period:
          today               Today only
          week                This week (default)
          lastweek            Last week
          nextweek            Next week

        Examples:
          alfred attention                      # Run attention defense
          alfred attention init                 # Initialize preferences
          alfred attention report               # Full report for this week
          alfred attention calendar lastweek    # Calendar report for last week
          alfred attention messaging today      # Messaging report for today
          alfred attention plan 14              # Plan next 2 weeks
          alfred attention priorities           # Learn meeting priorities

        """)
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    static func runGoogleAuth(_ config: AppConfig) async {
        print("\nGoogle Calendar Accounts Available:")
        for (index, account) in config.calendar.google.enumerated() {
            print("  \(index + 1). \(account.name)")
        }
        print("\nEnter the number of the account to authenticate (or 'all' for all accounts):")
        
        guard let input = readLine() else { return }
        
        let accounts: [CalendarConfig.GoogleCalendarConfig]
        if input.lowercased() == "all" {
            accounts = config.calendar.google
        } else if let index = Int(input), index > 0, index <= config.calendar.google.count {
            accounts = [config.calendar.google[index - 1]]
        } else {
            print("Invalid selection")
            return
        }
        
        for account in accounts {
            print("\n\nStarting authentication for '\(account.name)'...")
            let calendarService = GoogleCalendarService(config: account, accountName: account.name)
            let authURL = calendarService.getAuthorizationURL()
            print("Please visit this URL to authorize:")
            print("\(authURL)")
            print("\nAfter authorizing, you'll be redirected. Copy the 'code' parameter from the URL and paste it here:")

            if let code = readLine() {
                do {
                    try await calendarService.exchangeCodeForToken(code: code)
                    print("\n✓ Authentication successful for '\(account.name)'!")
                } catch {
                    print("\n✗ Authentication failed for '\(account.name)': \(error)")
                }
            }
        }
        
        print("\nAuthentication complete. You can now use the calendar features.")
    }

    static func runGmailAuth(_ config: AppConfig) async {
        guard let emailConfig = config.messaging.email else {
            print("Error: Email not configured in config.json")
            return
        }

        print("\nGmail Authentication")
        print("====================\n")

        let gmailReader = GmailReader(config: emailConfig)
        let authURL = gmailReader.getAuthorizationURL()

        print("Please visit this URL to authorize Gmail access:")
        print("\(authURL)")
        print("\nAfter authorizing, you'll be redirected. Copy the 'code' parameter from the URL and paste it here:")

        if let code = readLine() {
            do {
                try await gmailReader.exchangeCodeForToken(code: code)
                print("\n✓ Gmail authentication successful!")
                print("\nYou can now use email reading features:")
                print("  alfred messages email 24h")
                print("  alfred briefing  (will include email analysis)")
            } catch {
                print("\n✗ Gmail authentication failed: \(error)")
            }
        }
    }

    static func runNotionTodos(_ orchestrator: BriefingOrchestrator) async {
        do {
            let todos = try await orchestrator.processWhatsAppTodos()
            if todos.createdTodos.isEmpty {
                print("\n✓ No todos detected in recent WhatsApp messages")
            } else {
                print("\n✓ Successfully created \(todos.createdTodos.count) todo(s) in Notion")
            }
        } catch {
            print("Error processing todos: \(error)")
        }
    }

    static func testNotion(_ orchestrator: BriefingOrchestrator) async {
        print("\n🧪 Testing Notion integration...\n")

        // Test creating a simple todo
        print("1. Testing todo creation...")
        do {
            let notionService = NotionService(config: orchestrator.config.notion)
            let pageId = try await notionService.createTodo(
                title: "Test Todo from Alfred",
                description: "This is a test todo created by the Notion integration",
                dueDate: Calendar.current.date(byAdding: .day, value: 1, to: Date())
            )
            print("   ✓ Successfully created test todo (ID: \(pageId))\n")
        } catch {
            print("   ✗ Failed to create test todo: \(error)\n")
        }

        // Test searching workspace
        print("2. Testing workspace search...")
        do {
            let notionService = NotionService(config: orchestrator.config.notion)
            let results = try await notionService.searchWorkspace(query: "test")
            print("   ✓ Found \(results.count) result(s)")
            for result in results.prefix(3) {
                print("     • \(result.title)")
            }
            print("")
        } catch {
            print("   ✗ Failed to search workspace: \(error)\n")
        }

        print("✓ Notion integration test complete")
    }

    static func runShowDrafts() async {
        print("\n📨 MESSAGE DRAFTS")
        print(String(repeating: "=", count: 60))

        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let draftsFile = homeDir.appendingPathComponent(".alfred/message_drafts.json")

        guard FileManager.default.fileExists(atPath: draftsFile.path) else {
            print("\nNo drafts found. Agents will create drafts when they detect messages needing responses.\n")
            return
        }

        do {
            let data = try Data(contentsOf: draftsFile)
            let drafts = try JSONDecoder().decode([MessageDraft].self, from: data)

            if drafts.isEmpty {
                print("\nNo drafts found. Agents will create drafts when they detect messages needing responses.\n")
                return
            }

            print("\nYou have \(drafts.count) draft message(s) ready to send:\n")

            for (index, draft) in drafts.enumerated() {
                print("[\(index + 1)] \(draft.platform.rawValue.uppercased()) → \(draft.recipient)")
                print("    Tone: \(draft.tone.rawValue)")
                print("    Message:")

                // Format message with proper indentation
                let lines = draft.content.split(separator: "\n")
                for line in lines {
                    print("    \"\(line)\"")
                }

                print("")
            }

            print("Commands:")
            print("  alfred clear-drafts         - Remove all drafts\n")
            print("💡 Note: Alfred creates drafts only - manual sending required\n")

        } catch {
            print("Error reading drafts: \(error)\n")
        }
    }


    static func runClearDrafts() async {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let draftsFile = homeDir.appendingPathComponent(".alfred/message_drafts.json")

        guard FileManager.default.fileExists(atPath: draftsFile.path) else {
            print("No drafts to clear.\n")
            return
        }

        do {
            try "[]".write(to: draftsFile, atomically: true, encoding: .utf8)
            print("✓ All drafts cleared\n")
        } catch {
            print("Error clearing drafts: \(error)\n")
        }
    }

    // MARK: - Agent Commands

    static func runAgentsCommand(_ args: [String]) async {
        let memoryService = AgentMemoryService.shared

        // alfred agents                    - show all agents summary
        // alfred agents memory [agent]     - show agent's memory
        // alfred agents skills [agent]     - show agent's skills
        // alfred agents forget [agent] "pattern" - forget a pattern

        guard args.count >= 2 else {
            printAgentsSummary(memoryService)
            return
        }

        if args.count == 2 {
            // Just "alfred agents" - show summary
            printAgentsSummary(memoryService)
            return
        }

        let subcommand = args[2]

        switch subcommand {
        case "memory":
            if args.count > 3 {
                let agentName = args[3].lowercased()
                if let agentType = parseAgentType(agentName) {
                    printAgentMemory(memoryService, agentType: agentType)
                } else {
                    print("Unknown agent: \(agentName)")
                    print("Available agents: communication, task, calendar, followup")
                }
            } else {
                // Show all agents' memory summaries
                print("\n🧠 AGENT MEMORIES")
                print(String(repeating: "=", count: 60))
                for agentType in [AgentType.communication, .task, .calendar, .followup] {
                    let summary = memoryService.getMemorySummary(for: agentType)
                    print("\n\(agentType.displayName) Agent:")
                    print("  • Taught rules: \(summary.taughtRulesCount)")
                    print("  • Learned patterns: \(summary.learnedPatternsCount)")
                    if !summary.contactsKnown.isEmpty {
                        print("  • Contacts known: \(summary.contactsKnown.joined(separator: ", "))")
                    }
                    print("  • Last updated: \(summary.formattedLastUpdated)")
                }
                print("\nUse 'alfred agents memory [agent]' to see full memory")
            }

        case "skills":
            if args.count > 3 {
                let agentName = args[3].lowercased()
                if let agentType = parseAgentType(agentName) {
                    printAgentSkills(memoryService, agentType: agentType)
                } else {
                    print("Unknown agent: \(agentName)")
                    print("Available agents: communication, task, calendar, followup")
                }
            } else {
                // Show all agents' skills summaries
                print("\n⚡ AGENT SKILLS")
                print(String(repeating: "=", count: 60))
                for agentType in [AgentType.communication, .task, .calendar, .followup] {
                    let skills = memoryService.getSkills(for: agentType)
                    print("\n\(agentType.displayName) Agent:")
                    for capability in skills.capabilities {
                        print("  • \(capability)")
                    }
                }
                print("\nUse 'alfred agents skills [agent]' to see full skills documentation")
            }

        case "forget":
            if args.count > 4 {
                let agentName = args[3].lowercased()
                let pattern = args[4]
                if let agentType = parseAgentType(agentName) {
                    do {
                        let found = try memoryService.forget(agentType: agentType, pattern: pattern)
                        if !found {
                            print("No patterns containing \"\(pattern)\" found in \(agentType.displayName) memory")
                        }
                    } catch {
                        print("Error: \(error)")
                    }
                } else {
                    print("Unknown agent: \(agentName)")
                }
            } else {
                print("Usage: alfred agents forget [agent] \"pattern\"")
                print("Example: alfred agents forget communication \"formal with\"")
            }

        case "consolidate":
            print("\n🧠 Learning Consolidation")
            print(String(repeating: "=", count: 60))

            // Show summary first
            let summary = memoryService.getConsolidationSummary()
            print("\nLearning Database Status:")
            print("  • Total patterns tracked: \(summary.totalPatterns)")
            print("  • Patterns ready for consolidation: \(summary.patternsReadyForConsolidation)")

            if !summary.patternsByAgent.isEmpty {
                print("  • By agent:")
                for (agent, count) in summary.patternsByAgent {
                    print("    - \(agent): \(count) patterns")
                }
            }

            if summary.patternsReadyForConsolidation > 0 {
                print("\nConsolidating learnings to memory files...")
                do {
                    try memoryService.consolidateLearnings()
                } catch {
                    print("Error during consolidation: \(error)")
                }
            } else {
                print("\nNo patterns ready for consolidation yet.")
                print("Patterns need confidence >= 70% and at least 5 feedback instances.")
            }

        case "status":
            print("\n🧠 Agent Learning Status")
            print(String(repeating: "=", count: 60))

            let summary = memoryService.getConsolidationSummary()
            print("\nLearning Database:")
            print("  • Total patterns tracked: \(summary.totalPatterns)")
            print("  • Ready for consolidation: \(summary.patternsReadyForConsolidation)")

            print("\nAgent Memories:")
            for agentType in [AgentType.communication, .task, .calendar, .followup] {
                let memorySummary = memoryService.getMemorySummary(for: agentType)
                print("\n  \(agentType.displayName) Agent:")
                print("    • Taught rules: \(memorySummary.taughtRulesCount)")
                print("    • Learned patterns: \(memorySummary.learnedPatternsCount)")
                print("    • Last updated: \(memorySummary.formattedLastUpdated)")
            }

        default:
            print("Unknown subcommand: \(subcommand)")
            printAgentsUsage()
        }
    }

    static func runAgentDigest(_ orchestrator: BriefingOrchestrator) async {
        print("\n📊 DAILY AGENT DIGEST\n")
        print("Generating digest...")

        do {
            let digest = try await orchestrator.generateAgentDigest()

            // Print summary
            print("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            print("📈 SUMMARY")
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
            print("  Total Decisions:      \(digest.summary.totalDecisions)")
            print("  Executed:             \(digest.summary.decisionsExecuted)")
            print("  Pending Review:       \(digest.summary.decisionsPending)")
            print("  New Learnings:        \(digest.summary.newLearningsCount)")
            print("  Follow-ups Created:   \(digest.summary.followupsCreated)")
            print("  Commitments Closed:   \(digest.summary.commitmentsClosed)")

            // Print agent activity
            if !digest.agentActivity.isEmpty {
                print("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                print("🤖 AGENT ACTIVITY")
                print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")

                for activity in digest.agentActivity where activity.decisionsCount > 0 {
                    let successPct = Int(activity.successRate * 100)
                    print("  \(activity.agentType.icon) \(activity.agentType.displayName)")
                    print("     Decisions: \(activity.decisionsCount) | Success: \(successPct)%")
                    if let topAction = activity.topAction {
                        print("     Top Action: \(topAction)")
                    }
                    if let insight = activity.keyInsight {
                        print("     Insight: \(insight)")
                    }
                    print("")
                }
            }

            // Print new learnings
            if !digest.newLearnings.isEmpty {
                print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                print("🧠 NEW LEARNINGS (\(digest.newLearnings.count))")
                print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")

                for learning in digest.newLearnings.prefix(5) {
                    print("  [\(learning.agentType.displayName)] \(learning.description)")
                }
                if digest.newLearnings.count > 5 {
                    print("  ... and \(digest.newLearnings.count - 5) more")
                }
                print("")
            }

            // Print commitment status
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            print("📋 COMMITMENT STATUS")
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
            print("  I Owe (Active):       \(digest.commitmentStatus.activeIOwe)")
            print("  They Owe Me (Active): \(digest.commitmentStatus.activeTheyOwe)")
            print("  Overdue:              \(digest.commitmentStatus.overdueCount)")
            print("  Due This Week:        \(digest.commitmentStatus.upcomingThisWeek)")

            // Print upcoming follow-ups
            if !digest.upcomingFollowups.isEmpty {
                print("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                print("🔔 UPCOMING FOLLOW-UPS (\(digest.upcomingFollowups.count))")
                print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")

                let formatter = DateFormatter()
                formatter.dateStyle = .short
                formatter.timeStyle = .short

                for followup in digest.upcomingFollowups.prefix(5) {
                    let overdueTag = followup.isOverdue ? " ⚠️" : ""
                    print("  • \(followup.title)\(overdueTag)")
                    print("    Due: \(formatter.string(from: followup.scheduledFor))")
                    print("")
                }
            }

            // Print recommendations
            if !digest.recommendations.isEmpty {
                print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                print("💡 RECOMMENDATIONS")
                print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")

                for rec in digest.recommendations {
                    print("  • \(rec)")
                }
            }

            print("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

            // Send email if configured
            if orchestrator.config.notifications.email.enabled {
                print("\n📧 Sending digest email...")
                let notificationService = NotificationService(config: orchestrator.config.notifications)
                try await notificationService.sendAgentDigest(digest)
                print("✅ Digest email sent successfully!")
            } else {
                print("\n💡 Tip: Enable email notifications in config to receive daily digest via email")
            }

        } catch {
            print("❌ Failed to generate digest: \(error)")
        }

        print("")
    }

    static func runTeachCommand(_ args: [String]) async {
        // alfred teach [agent] "rule"
        // alfred teach [agent] --category [category] "rule"

        guard args.count >= 4 else {
            printTeachUsage()
            return
        }

        let agentName = args[2].lowercased()
        guard let agentType = parseAgentType(agentName) else {
            print("Unknown agent: \(agentName)")
            print("Available agents: communication, task, calendar, followup")
            return
        }

        // Check for category flag
        var category: String? = nil
        var ruleStartIndex = 3

        if args.count > 4 && args[3] == "--category" {
            category = args[4]
            ruleStartIndex = 5
        }

        guard args.count > ruleStartIndex else {
            print("Please provide a rule to teach")
            printTeachUsage()
            return
        }

        // Combine remaining args as the rule (handles quoted strings)
        let rule = args[ruleStartIndex...].joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

        let memoryService = AgentMemoryService.shared
        do {
            try memoryService.teach(agentType: agentType, rule: rule, category: category)
            print("\n💡 The \(agentType.displayName) agent will now follow this rule.")
            print("   View with: alfred agents memory \(agentName)")
        } catch {
            print("Error teaching agent: \(error)")
        }
    }

    static func parseAgentType(_ name: String) -> AgentType? {
        switch name {
        case "communication", "comm", "com":
            return .communication
        case "task", "tasks":
            return .task
        case "calendar", "cal":
            return .calendar
        case "followup", "follow", "followups":
            return .followup
        default:
            return nil
        }
    }

    static func printAgentsSummary(_ memoryService: AgentMemoryService) {
        print("\n🤖 ALFRED AGENTS")
        print(String(repeating: "=", count: 60))

        for agentType in [AgentType.communication, .task, .calendar, .followup] {
            let summary = memoryService.getMemorySummary(for: agentType)
            let skills = memoryService.getSkills(for: agentType)

            print("\n\(agentType.displayName) Agent")
            print("  Skills: \(skills.capabilities.joined(separator: ", "))")
            print("  Memory: \(summary.taughtRulesCount) rules, \(summary.learnedPatternsCount) patterns learned")
            print("  Last updated: \(summary.formattedLastUpdated)")
        }

        print("\n" + String(repeating: "-", count: 60))
        print("Commands:")
        print("  alfred agents memory [agent]    - View agent's memory")
        print("  alfred agents skills [agent]    - View agent's capabilities")
        print("  alfred teach [agent] \"rule\"     - Teach agent a new rule")
        print("  alfred agents forget [agent] \"pattern\" - Remove a learned pattern")
        print("")
    }

    static func printAgentMemory(_ memoryService: AgentMemoryService, agentType: AgentType) {
        let memory = memoryService.getMemory(for: agentType)

        print("\n🧠 \(agentType.displayName.uppercased()) AGENT MEMORY")
        print(String(repeating: "=", count: 60))

        // Print the raw markdown content (formatted)
        print(memory.content)

        print(String(repeating: "-", count: 60))
        print("Edit at: ~/.alfred/agents/\(agentType.rawValue)/memory.md")
        print("Teach:   alfred teach \(agentType.rawValue) \"your rule here\"")
        print("")
    }

    static func printAgentSkills(_ memoryService: AgentMemoryService, agentType: AgentType) {
        let skills = memoryService.getSkills(for: agentType)

        print("\n⚡ \(agentType.displayName.uppercased()) AGENT SKILLS")
        print(String(repeating: "=", count: 60))

        // Print the raw markdown content
        print(skills.content)

        print(String(repeating: "-", count: 60))
        print("Skills file: ~/.alfred/agents/\(agentType.rawValue)/skills.md")
        print("")
    }

    static func printAgentsUsage() {
        print("\nUsage:")
        print("  alfred agents                    - Show all agents summary")
        print("  alfred agents memory             - Show all agents' memory summaries")
        print("  alfred agents memory [agent]     - Show specific agent's full memory")
        print("  alfred agents skills             - Show all agents' skills summaries")
        print("  alfred agents skills [agent]     - Show specific agent's full skills")
        print("  alfred agents forget [agent] \"pattern\" - Remove learned pattern")
        print("  alfred agents consolidate        - Consolidate learnings to memory files")
        print("  alfred agents status             - Show learning status and statistics")
        print("")
        print("Agents: communication, task, calendar, followup")
        print("")
    }

    static func printTeachUsage() {
        print("\nUsage:")
        print("  alfred teach [agent] \"rule\"")
        print("  alfred teach [agent] --category [category] \"rule\"")
        print("")
        print("Examples:")
        print("  alfred teach communication \"Always be formal with investors\"")
        print("  alfred teach task \"Friday afternoons are for deep work\"")
        print("  alfred teach calendar --category Prep \"Board meetings need 30 min prep\"")
        print("  alfred teach followup \"Always follow up with VCs within 24 hours\"")
        print("")
        print("Agents: communication, task, calendar, followup")
        print("")
    }

    static func printBriefing(_ briefing: DailyBriefing) {
        print("Date: \(briefing.date.formatted(date: .long, time: .omitted))\n")

        print("MESSAGES SUMMARY")
        print("----------------")
        print("Total Messages: \(briefing.messagingSummary.stats.totalMessages)")
        print("Unread: \(briefing.messagingSummary.stats.unreadMessages)")
        print("Threads Needing Response: \(briefing.messagingSummary.stats.threadsNeedingResponse)\n")

        if !briefing.messagingSummary.criticalMessages.isEmpty {
            print("CRITICAL MESSAGES:")
            for summary in briefing.messagingSummary.criticalMessages.prefix(5) {
                print("  • \(summary.thread.contactName ?? "Unknown") (\(summary.thread.platform.rawValue))")
                print("    \(summary.summary)")
                print("    Urgency: \(summary.urgency.rawValue)\n")
            }
        }

        print("\nTODAY'S SCHEDULE")
        print("----------------")
        print("Total Meeting Time: \(formatDuration(briefing.calendarBriefing.schedule.totalMeetingTime))")
        print("Focus Time Available: \(formatDuration(briefing.calendarBriefing.focusTime))")
        print("External Meetings: \(briefing.calendarBriefing.schedule.externalMeetings.count)\n")

        if !briefing.calendarBriefing.meetingBriefings.isEmpty {
            print("MEETING BRIEFINGS:")
            for meeting in briefing.calendarBriefing.meetingBriefings {
                print("\n\(meeting.event.title)")
                print("Time: \(meeting.event.startTime.formatted(date: .omitted, time: .shortened)) - \(meeting.event.endTime.formatted(date: .omitted, time: .shortened))")
                print("Context: \(meeting.context ?? "No context")")
                print("Preparation: \(meeting.preparation)")
            }
        }

        // Notion Context
        if let notionContext = briefing.notionContext {
            if !notionContext.tasks.isEmpty {
                print("\n\nACTIVE TASKS")
                print("------------")
                for task in notionContext.tasks.prefix(5) {
                    print("• \(task.title)")
                    print("  Status: \(task.status)")
                    if let dueDate = task.dueDate {
                        print("  Due: \(dueDate.formatted(date: .abbreviated, time: .omitted))")
                    }
                    print("")
                }
            }

            if !notionContext.notes.isEmpty {
                print("\nRELEVANT NOTES")
                print("--------------")
                for note in notionContext.notes.prefix(3) {
                    print("• \(note.title)")
                }
                print("")
            }
        }

        // Agent Decisions
        if let agentDecisions = briefing.agentDecisions, !agentDecisions.isEmpty {
            print("\n🤖 AGENT RECOMMENDATIONS")
            print("========================")
            print("Your AI agents have \(agentDecisions.count) suggestion(s) pending your approval:\n")

            for (index, decision) in agentDecisions.enumerated() {
                print("[\(index + 1)] \(decision.agentType.displayName.uppercased())")
                print("    Confidence: \(String(format: "%.0f%%", decision.confidence * 100))")
                print("    \(decision.reasoning)")
                print("")

                switch decision.action {
                case .draftResponse(let draft):
                    print("    📤 Draft response to \(draft.recipient):")
                    let preview = draft.content.prefix(80)
                    print("    \"\(preview)\(draft.content.count > 80 ? "..." : "")\"")

                case .adjustTaskPriority(let adj):
                    print("    ⚡ Change priority: \(adj.currentPriority.rawValue) → \(adj.newPriority.rawValue)")
                    print("    Task: \(adj.taskTitle)")

                case .scheduleMeetingPrep(let prep):
                    print("    📅 Schedule prep for: \(prep.meetingTitle)")
                    print("    Time: \(prep.scheduledFor.formatted(date: .omitted, time: .shortened))")
                    print("    Duration: \(Int(prep.estimatedDuration / 60))min")

                case .createFollowup(let followup):
                    print("    🔔 Follow-up reminder: \(followup.followupAction)")
                    print("    Scheduled: \(followup.scheduledFor.formatted(date: .abbreviated, time: .shortened))")

                case .noAction:
                    break
                }

                if !decision.risks.isEmpty {
                    print("    ⚠️  Risks: \(decision.risks.joined(separator: ", "))")
                }
                print("")
            }

            print("💡 These actions will be saved for your review. Future versions will support")
            print("   interactive approval via CLI commands (alfred approve-agent <number>)")
            print("")
        }

        // Agent Insights
        if let insights = briefing.agentInsights, !insights.isEmpty {
            print("\n🧠 AGENT INSIGHTS")
            print("=================")

            // Proactive Notices
            if !insights.proactiveNotices.isEmpty {
                print("\n📢 PROACTIVE NOTICES:")
                for notice in insights.proactiveNotices {
                    let priorityIcon = notice.priority == .critical ? "🔴" : (notice.priority == .high ? "🟠" : "🟡")
                    print("  \(priorityIcon) [\(notice.agentType.displayName)] \(notice.title)")
                    print("     \(notice.message)")
                    if let action = notice.suggestedAction {
                        print("     → \(action)")
                    }
                    print("")
                }
            }

            // Commitment Reminders
            if !insights.commitmentReminders.isEmpty {
                print("⏰ COMMITMENT REMINDERS:")
                for reminder in insights.commitmentReminders {
                    let overdueText = reminder.daysOverdue.map { $0 > 0 ? " (\($0) day(s) overdue!)" : "" } ?? ""
                    print("  • \(reminder.commitment)\(overdueText)")
                    if let to = reminder.committedTo {
                        print("    To: \(to)")
                    }
                    if let due = reminder.dueDate {
                        print("    Due: \(due.formatted(date: .abbreviated, time: .omitted))")
                    }
                    print("    → \(reminder.suggestedAction)")
                    print("")
                }
            }

            // Cross-Agent Suggestions
            if !insights.crossAgentSuggestions.isEmpty {
                print("🔗 CROSS-AGENT SUGGESTIONS:")
                for suggestion in insights.crossAgentSuggestions {
                    let agentNames = suggestion.involvedAgents.map { $0.displayName }.joined(separator: " + ")
                    print("  • [\(agentNames)] \(suggestion.title)")
                    print("    \(suggestion.description)")
                    print("")
                }
            }

            // Recent Learnings
            if !insights.recentLearnings.isEmpty {
                print("📚 WHAT AGENTS LEARNED RECENTLY:")
                for learning in insights.recentLearnings.prefix(5) {
                    print("  • [\(learning.agentType.displayName)] \(learning.description)")
                }
                print("")
            }
        }

        print("\nACTION ITEMS (\(briefing.actionItems.count))")
        print("------------")
        for item in briefing.actionItems.prefix(10) {
            print("[\(item.priority.rawValue)] \(item.title)")
            print("  \(item.description)")
            if let due = item.dueDate {
                print("  Due: \(due.formatted(date: .abbreviated, time: .shortened))")
            }
        }
    }

    static func printAttentionReport(_ report: AttentionDefenseReport) {
        print("Current Time: \(report.currentTime.formatted(date: .omitted, time: .shortened))\n")

        print("MUST COMPLETE TODAY (\(report.mustDoToday.count))")
        print("-------------------")
        for item in report.mustDoToday {
            print("• \(item.title)")
            print("  \(item.description)")
            print("  Priority: \(item.priority.rawValue)\n")
        }

        print("\nCAN PUSH TO TOMORROW (\(report.canPushOff.count))")
        print("--------------------")
        for suggestion in report.canPushOff {
            print("• \(suggestion.item.title)")
            print("  Reason: \(suggestion.reason)")
            print("  Impact: \(suggestion.impact.rawValue)\n")
        }

        print("\nRECOMMENDATIONS")
        print("---------------")
        for rec in report.recommendations {
            print("• \(rec)")
        }
    }

    static func printMessagesSummary(_ summaries: [MessageSummary]) {
        for summary in summaries {
            print("[\(summary.thread.platform.rawValue.uppercased())] \(summary.thread.contactName ?? "Unknown")")
            print("Messages: \(summary.thread.messages.count) | Unread: \(summary.thread.unreadCount)")
            print("Urgency: \(summary.urgency.rawValue)")
            print("\nSummary:")
            print(summary.summary)
            if !summary.actionItems.isEmpty {
                print("\nAction Items:")
                for item in summary.actionItems {
                    print("  • \(item)")
                }
            }
            print("\n" + String(repeating: "-", count: 60) + "\n")
        }
    }

    static func printFocusedThreadAnalysis(_ analysis: FocusedThreadAnalysis) {
        print("Contact: \(analysis.thread.contactName ?? "Unknown")")
        print("Messages: \(analysis.thread.messages.count)")
        print("Timeframe: \(analysis.thread.messages.last?.timestamp.formatted() ?? "Unknown") - \(analysis.thread.messages.first?.timestamp.formatted() ?? "Unknown")")
        print("\n" + String(repeating: "=", count: 60))

        print("\nCONTEXT")
        print(String(repeating: "-", count: 60))
        print(analysis.context)

        print("\n\nSUMMARY")
        print(String(repeating: "-", count: 60))
        print(analysis.summary)

        if !analysis.actionItems.isEmpty {
            print("\n\nTOP ACTION ITEMS FOR YOU")
            print(String(repeating: "-", count: 60))
            for (index, item) in analysis.actionItems.enumerated() {
                let priorityEmoji = item.priority.lowercased() == "high" ? "🔴" : (item.priority.lowercased() == "medium" ? "🟡" : "🟢")
                print("\n\(index + 1). \(priorityEmoji) \(item.item)")
                print("   Priority: \(item.priority)")
                if let deadline = item.deadline {
                    print("   Deadline: \(deadline)")
                }
            }
        }

        if !analysis.keyQuotes.isEmpty {
            print("\n\nKEY MESSAGES")
            print(String(repeating: "-", count: 60))
            for quote in analysis.keyQuotes {
                print("\n[\(quote.timestamp)] \(quote.speaker):")
                print("  \"\(quote.quote)\"")
            }
        }

        if !analysis.timeSensitive.isEmpty {
            print("\n\n⏰ TIME-SENSITIVE INFORMATION")
            print(String(repeating: "-", count: 60))
            for info in analysis.timeSensitive {
                print("  • \(info)")
            }
        }

        print("\n" + String(repeating: "=", count: 60) + "\n")
    }

    static func printCalendarBriefing(_ calendarBriefing: CalendarBriefing) {
        let schedule = calendarBriefing.schedule

        print("Date: \(schedule.date.formatted(date: .long, time: .omitted))\n")
        print("Total Events: \(schedule.events.count)")
        print("Total Meeting Time: \(formatDuration(schedule.totalMeetingTime))")
        print("Focus Time Available: \(formatDuration(calendarBriefing.focusTime))")
        print("External Meetings: \(schedule.externalMeetings.count)\n")

        if !schedule.events.isEmpty {
            print("TODAY'S SCHEDULE")
            print("----------------")
            for event in schedule.events {
                print("\n\(event.startTime.formatted(date: .omitted, time: .shortened)) - \(event.endTime.formatted(date: .omitted, time: .shortened))")
                print("  \(event.title)")
                if !event.attendees.isEmpty {
                    let externalCount = event.attendees.filter { !$0.isInternal }.count
                    if externalCount > 0 {
                        print("  👥 \(event.attendees.count) attendees (\(externalCount) external)")
                    } else {
                        print("  👥 \(event.attendees.count) attendees")
                    }
                }
                if let location = event.location {
                    print("  📍 \(location)")
                }
            }
        }

        if !calendarBriefing.meetingBriefings.isEmpty {
            print("\n\nEXTERNAL MEETING BRIEFINGS")
            print("---------------------------")
            for briefing in calendarBriefing.meetingBriefings {
                print("\n\(briefing.event.title)")
                print("Time: \(briefing.event.startTime.formatted(date: .omitted, time: .shortened)) - \(briefing.event.endTime.formatted(date: .omitted, time: .shortened))")
                print("\nContext:")
                print(briefing.context ?? "No context available")
                print("\nPreparation:")
                print(briefing.preparation)
                print("\n" + String(repeating: "-", count: 60))
            }
        }

        if !calendarBriefing.recommendations.isEmpty {
            print("\n\nRECOMMENDATIONS")
            print("---------------")
            for rec in calendarBriefing.recommendations {
                print("• \(rec)")
            }
        }
    }

    static func printUsage() {
        print("""
        Alfred - Your Personal Assistant 🦇

        Usage:
          alfred <command> [options]

        Commands:
          briefing [date]       Generate briefing for specific date
                                 Examples: briefing tomorrow
                                          briefing 2026-01-15
                                          briefing +2  (2 days from now)
                                 Add --email to send via email

          messages [platform] [timeframe]
                                 Get messages summary by platform
                                 Platforms: all, imessage, whatsapp, signal
                                 Timeframes: 1h, 24h, 7d
                                 Examples: messages imessage 1h
                                          messages all 24h

          messages whatsapp "Name" [timeframe]
                                 Get focused analysis of specific WhatsApp contact/group
                                 with action items and key quotes
                                 Examples: messages whatsapp "Family Group" 24h
                                          messages whatsapp "John Doe" 7d

          calendar [calendar] [date]
                                 Get calendar briefing for specific date
                                 Calendars: all, primary, work (default: all)
                                 Examples: calendar
                                          calendar tomorrow
                                          calendar primary tomorrow
                                          calendar work 2026-01-15
                                          calendar all +3

          attention             Generate attention defense report (3pm alert)
                                 Add --email to send via email

          attention init        Create attention preferences file
          attention report [scope] [period]
                                 Generate attention report
                                 Scopes: both, calendar, messaging (default: both)
                                 Periods:
                                   - Named: today, week, lastweek, nextweek
                                   - Custom: number of days (e.g., 7, 14, 30)
                                   - Lookback: negative days (e.g., -7, -30)
                                 Examples: attention report calendar week
                                          attention report messaging today
                                          attention report calendar 14 (next 14 days)
                                          attention report calendar -30 (last 30 days)

          attention calendar [period]
                                 Calendar-only attention report
                                 Examples: attention calendar week

          attention messaging [period]
                                 Messaging-only attention report
                                 Examples: attention messaging week

          attention plan [days]  Generate attention plan for next N days
                                 Examples: attention plan 7
                                          attention plan 14

          attention priorities   Collect meeting priorities (AI learns from you)

          attention config       Interactive configuration (lookback/lookforward, limits, goals)
                                 View and edit attention preferences interactively

          commitments init      Show setup instructions for Commitments Tracker
                                 Provides database schema and configuration guide
                                 Example: alfred commitments init

          schedule              Run in scheduled mode (auto-generates briefings)
          auth                  Authenticate with Google Calendar

          notion-todos          Process WhatsApp messages to yourself and create Notion todos
          test-notion           Test Notion integration (creates test todo and searches)

          drafts                View message drafts created by agents (review only)
          clear-drafts          Remove all drafts

          agents                View all agents and their status
          agents memory [agent] View what an agent has learned
          agents skills [agent] View an agent's capabilities
          agents forget [agent] "pattern"
                                Remove a learned pattern from agent memory

          teach [agent] "rule"  Teach an agent a new rule
                                Examples: teach communication "Be formal with investors"
                                         teach task "Fridays are for deep work"
                                         teach calendar "Board meetings need 30 min prep"

          digest                Generate daily agent digest
                                Summarizes agent decisions, learnings, and recommendations
                                Sends digest via email if configured
                                Example: alfred digest

        Flags:
          --notify              Send output via configured notification channels (email, Slack, push)

        Quick Start Examples:
          # Daily briefings
          alfred briefing                    # Generate today's briefing
          alfred briefing tomorrow --notify  # Tomorrow's briefing via email
          alfred briefing +3                 # Briefing for 3 days ahead

          # Message analysis
          alfred messages imessage 1h        # Last hour of iMessages
          alfred messages all 24h            # All messages, last 24h
          alfred messages whatsapp "Kunal Shah" 7d  # Specific contact, 7 days

          # Calendar management
          alfred calendar                    # Today's calendar
          alfred calendar tomorrow           # Tomorrow's schedule
          alfred calendar work next week     # Work calendar, next week

          # Attention management
          alfred attention --notify          # 3pm attention defense alert
          alfred attention init              # Setup attention preferences
          alfred attention report calendar week  # Weekly calendar report
          alfred attention plan 7            # Plan next 7 days

          # Commitments tracking
          alfred commitments init            # Setup commitment tracking in Notion

          # Agent drafts
          alfred drafts                      # Review agent-created message drafts
          alfred clear-drafts                # Clear all drafts

          # Agent learning
          alfred agents                      # See all agents status
          alfred agents memory communication # See communication agent's memory
          alfred teach communication "Always CC my assistant on external emails"
          alfred teach task "Deep work before 11am"

        Workflow Examples:
          # Morning routine
          alfred briefing --notify           # Get briefing via email
          alfred calendar                    # Review today's schedule

          # Quick message check
          alfred messages all 1h             # Check last hour
          alfred messages whatsapp "Team" 24h  # Team messages today

          # Weekly planning
          alfred attention plan 7            # Plan next week
          alfred calendar +7                 # See next week's calendar

          # Agent workflow
          alfred briefing                    # Agents analyze & create drafts
          alfred drafts                      # Review suggested responses
          # (Send messages manually based on drafts)

        Configuration:
          Edit ~/.config/alfred/config.json with your credentials
          Run 'alfred attention init' to setup attention preferences
          Run 'alfred commitments init' to setup commitment tracking
        """)
    }

    // MARK: - Server
    static func runServer(_ config: AppConfig, _ orchestrator: BriefingOrchestrator) async {
        guard let apiConfig = config.api else {
            print("❌ API configuration not found in config.json")
            print("Add the following to your config.json:")
            print("""
            "api": {
              "enabled": true,
              "port": 8080,
              "passcode": "your-secure-passcode"
            }
            """)
            return
        }

        guard apiConfig.enabled else {
            print("❌ API is disabled in config.json")
            print("Set 'enabled' to true in the 'api' section")
            return
        }

        print("🚀 Starting Alfred HTTP Server...")
        print("   Port: \(apiConfig.port)")
        print("   Passcode: \(apiConfig.passcode)")
        print("")

        // Get local IP for convenience
        let localIP = getLocalIP()
        if let ip = localIP {
            print("📍 Access the web interface at:")
            print("   Local:  http://localhost:\(apiConfig.port)/web/index-notion.html?passcode=\(apiConfig.passcode)")
            print("   Network: http://\(ip):\(apiConfig.port)/web/index-notion.html?passcode=\(apiConfig.passcode)")
        } else {
            print("📍 Access the web interface at:")
            print("   http://localhost:\(apiConfig.port)/web/index-notion.html?passcode=\(apiConfig.passcode)")
        }
        print("")
        print("Press Ctrl+C to stop the server")
        print("")

        do {
            let alfredService = await MainActor.run {
                AlfredService()
            }
            await alfredService.initialize(config: config, orchestrator: orchestrator)
            let server = HTTPServer(port: apiConfig.port, passcode: apiConfig.passcode, alfredService: alfredService)
            try server.start()

            // Keep the server running indefinitely
            try await Task.sleep(nanoseconds: UInt64.max)
        } catch {
            print("❌ Failed to start server: \(error)")
        }
    }

    static func getLocalIP() -> String? {
        // Simple approach: use ifconfig command
        let task = Process()
        task.launchPath = "/sbin/ifconfig"
        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                // Find first "inet " line that's not 127.0.0.1
                let lines = output.components(separatedBy: "\n")
                for line in lines {
                    if line.contains("inet ") && !line.contains("127.0.0.1") {
                        let components = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " ")
                        if let index = components.firstIndex(of: "inet"), index + 1 < components.count {
                            return components[index + 1]
                        }
                    }
                }
            }
        } catch {
            return nil
        }

        return nil
    }
}

class Scheduler {
    private let config: AppConfig
    private let orchestrator: BriefingOrchestrator
    private var timer: Timer?

    init(config: AppConfig, orchestrator: BriefingOrchestrator) {
        self.config = config
        self.orchestrator = orchestrator
    }

    func start() async {
        print("Scheduler started")
        print("Morning briefing scheduled for: \(config.app.briefingTime)")
        print("Attention defense scheduled for: \(config.app.attentionAlertTime)")

        // Check every minute if it's time to run tasks
        let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task {
                await self?.checkAndRunTasks()
            }
        }
        self.timer = timer

        // Keep the app running
        RunLoop.main.run()
    }

    private func checkAndRunTasks() async {
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let currentTime = formatter.string(from: now)

        if currentTime == config.app.briefingTime {
            print("\n\(Date()) - Running morning briefing...")
            do {
                _ = try await orchestrator.generateMorningBriefing()
                print("Morning briefing sent successfully")
            } catch {
                print("Error generating briefing: \(error)")
            }
        }

        if currentTime == config.app.attentionAlertTime {
            print("\n\(Date()) - Running attention defense alert...")
            do {
                _ = try await orchestrator.generateAttentionDefenseAlert()
                print("Attention defense alert sent successfully")
            } catch {
                print("Error generating alert: \(error)")
            }
        }
    }
}

// MARK: - Commitments Commands

func runCommitmentsInit(_ orchestrator: BriefingOrchestrator) async {
    print("\n🔧 COMMITMENTS TRACKER SETUP\n")

    print("To use the Commitments Tracker, you need to create a database in Notion first.")
    print("This allows you to choose where to place it in your workspace.\n")

    print("📋 REQUIRED PROPERTIES FOR YOUR DATABASE:\n")
    print("Create a new database in Notion with these properties:\n")

    print("1. Title (title) - The commitment description")
    print("2. Type (select) - Options: 'I Owe', 'They Owe Me'")
    print("3. Status (status) - Notion's built-in status property")
    print("4. Commitment Text (rich text) - Full commitment text")
    print("5. Committed By (rich text) - Who made the commitment")
    print("6. Committed To (rich text) - Who receives the commitment")
    print("7. Source Platform (select) - Options: 'iMessage', 'WhatsApp', 'Meeting', 'Email', 'Signal'")
    print("8. Source Thread (rich text) - Thread/conversation name")
    print("9. Due Date (date) - When it's due")
    print("10. Priority (select) - Options: 'Critical', 'High', 'Medium', 'Low'")
    print("11. Original Context (rich text) - Original message context")
    print("12. Follow-up Scheduled (date) - When to follow up")
    print("13. Unique Hash (rich text) - Unique identifier for deduplication")
    print("14. Created Date (created time) - Notion's built-in property")
    print("15. Last Updated (last edited time) - Notion's built-in property\n")

    print("📝 QUICK SETUP STEPS:\n")
    print("1. Create a new database in Notion (anywhere you like)")
    print("2. Add all the properties listed above")
    print("3. Copy the database ID from the URL (the part after the page name)")
    print("   Example: https://notion.so/Your-Database-1c8308445573809cb43edab74b5e0777")
    print("            Database ID: 1c8308445573809cb43edab74b5e0777")
    print("4. Add this to your ~/.config/alfred/config.json:\n")

    print("""
    "commitments": {
      "enabled": true,
      "notion_database_id": "YOUR_DATABASE_ID_HERE",
      "auto_scan_on_briefing": true,
      "auto_scan_contacts": ["Contact Name 1", "Contact Name 2"],
      "default_lookback_days": 14,
      "priority_keywords": {
        "critical": ["urgent", "asap", "critical", "immediately"],
        "high": ["important", "soon", "this week"],
        "medium": ["need to", "should"],
        "low": ["sometime", "eventually"]
      },
      "notification_preferences": {
        "notify_on_overdue": true,
        "notify_before_deadline_hours": 24
      }
    }
    """)

    print("\n💡 TIP: You can use Notion's 'Duplicate' feature to copy database templates if needed.")
    print("\n✅ Once configured, use 'alfred commitments scan' to start tracking commitments!")
}

func printCommitmentsUsage() {
    print("""

    📋 COMMITMENTS TRACKER COMMANDS:

    alfred commitments init
        Initialize commitments tracker and show setup instructions

    alfred commitments scan [contact_name] [lookback_period]
        Scan messages for commitments
        - contact_name: Name of the contact (optional, scans all if not provided)
        - lookback_period: Days to look back - supports "14" or "14d" (default: from config)
        Examples:
          alfred commitments scan "Kunal Shah" 14d
          alfred commitments scan "Akshay Aedula" 14d
          alfred commitments scan "Swamy Seetharaman" 7
          alfred commitments scan 7d (scans all auto_scan_contacts)

    alfred commitments list [type]
        List all commitments
        - type: Optional filter - "i_owe" or "they_owe"
        Examples:
          alfred commitments list
          alfred commitments list i_owe

    alfred commitments overdue
        Show all overdue commitments

    """)
}

/// Parse days argument supporting both "14" and "14d" formats
func parseDaysArgument(_ arg: String) -> Int? {
    // Try parsing as plain integer first
    if let days = Int(arg) {
        return days
    }

    // Try parsing with "d" suffix (e.g., "14d")
    if arg.hasSuffix("d") || arg.hasSuffix("D") {
        let numericPart = arg.dropLast()
        if let days = Int(numericPart) {
            return days
        }
    }

    return nil
}

func runCommitmentsScan(_ orchestrator: BriefingOrchestrator, args: [String]) async {
    print("\n🔍 SCANNING FOR COMMITMENTS\n")

    guard let config = orchestrator.config.commitments, config.enabled else {
        print("❌ Commitments feature is not enabled in config")
        return
    }

    guard let databaseId = config.notionDatabaseId else {
        print("❌ Notion database ID not configured")
        print("Run 'alfred commitments init' for setup instructions")
        return
    }

    // Parse arguments
    var contactName: String?
    var lookbackDays = config.defaultLookbackDays

    if args.count >= 2 {
        // alfred commitments scan "Contact Name" 14d
        contactName = args[0]
        if let days = parseDaysArgument(args[1]) {
            lookbackDays = days
        }
    } else if args.count == 1 {
        // Check if single arg is a number (days) or contact name
        if let days = parseDaysArgument(args[0]) {
            lookbackDays = days
        } else {
            contactName = args[0]
        }
    }

    // Determine which contacts to scan
    let contactsToScan: [String]
    if let contact = contactName {
        contactsToScan = [contact]
        print("📱 Scanning messages with: \(contact)")
    } else {
        contactsToScan = config.autoScanContacts
        print("📱 Scanning messages with: \(contactsToScan.joined(separator: ", "))")
    }

    print("📅 Looking back: \(lookbackDays) days\n")

    let startDate = Calendar.current.date(byAdding: .day, value: -lookbackDays, to: Date()) ?? Date()

    var totalCommitmentsFound = 0
    var totalCommitmentsSaved = 0

    for contact in contactsToScan {
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("👤 Scanning: \(contact)")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")

        // Fetch messages from all platforms
        print("  ↳ Fetching messages from all platforms...")
        do {
            let allMessages = try await orchestrator.fetchMessagesForContact(contact, since: startDate)

            if allMessages.isEmpty {
                print("\n  ℹ️  No messages found for \(contact)\n")
                continue
            }

            // Count by platform
            let whatsappCount = allMessages.filter { $0.platform == .whatsapp }.count
            let imessageCount = allMessages.filter { $0.platform == .imessage }.count

            print("  ✓ Found \(allMessages.count) message(s)")
            if whatsappCount > 0 {
                print("    • WhatsApp: \(whatsappCount)")
            }
            if imessageCount > 0 {
                print("    • iMessage: \(imessageCount)")
            }

            print("\n  🤖 Analyzing with AI...\n")

            // Group messages by thread and analyze
            let groupedByThread = Dictionary(grouping: allMessages) { $0.threadName }

            for (threadName, threadMessages) in groupedByThread {
                guard let firstMessage = threadMessages.first else { continue }
                let platform = firstMessage.platform
                let threadId = firstMessage.threadId
                let messages = threadMessages.map { $0.message }

                do {
                    let extraction = try await orchestrator.commitmentAnalyzer.analyzeMessages(
                        messages,
                        platform: platform,
                        threadName: threadName,
                        threadId: threadId
                    )

                    if extraction.commitments.isEmpty {
                        print("  ℹ️  No commitments found in: \(threadName)")
                    } else {
                        print("  ✓ Found \(extraction.commitments.count) commitment(s) in: \(threadName)")
                        totalCommitmentsFound += extraction.commitments.count

                        // Save to Notion
                        for commitment in extraction.commitments {
                            do {
                                // Check if commitment already exists
                                let existingCommitment = try await orchestrator.notionServicePublic.findCommitmentByHash(
                                    commitment.uniqueHash,
                                    databaseId: databaseId
                                )

                                if existingCommitment != nil {
                                    print("    ⊘ Skipped (duplicate): \(commitment.title)")
                                } else {
                                    try await orchestrator.notionServicePublic.createCommitment(
                                        commitment,
                                        databaseId: databaseId
                                    )
                                    print("    ✓ Saved: \(commitment.title)")
                                    totalCommitmentsSaved += 1
                                }
                            } catch {
                                print("    ✗ Failed to save: \(commitment.title) - \(error)")
                            }
                        }
                    }
                } catch {
                    print("  ✗ Analysis failed for \(threadName): \(error)")
                }
            }

            print("")
        } catch {
            print("  ✗ Failed to fetch messages: \(error)\n")
        }
    }

    print("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print("📊 SCAN SUMMARY")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print("Total commitments found: \(totalCommitmentsFound)")
    print("New commitments saved: \(totalCommitmentsSaved)")
    print("Duplicates skipped: \(totalCommitmentsFound - totalCommitmentsSaved)")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
}

func runCommitmentsList(_ orchestrator: BriefingOrchestrator, args: [String]) async {
    print("\n📋 COMMITMENTS & FOLLOW-UPS\n")

    guard let config = orchestrator.config.commitments, config.enabled else {
        print("❌ Commitments feature is not enabled in config")
        return
    }

    // Parse type filter
    var directionFilter: TaskItem.CommitmentDirection?
    var showFollowups = true
    if let arg = args.first {
        switch arg.lowercased() {
        case "i_owe", "iowe":
            directionFilter = .iOwe
            showFollowups = false
        case "they_owe", "theyowe":
            directionFilter = .theyOweMe
            showFollowups = false
        case "followups", "follow-ups":
            directionFilter = nil
            showFollowups = true
        default:
            print("⚠️  Unknown type filter: \(arg) (use 'i_owe', 'they_owe', or 'followups')\n")
        }
    }

    do {
        // Query Tasks database for commitments
        let commitmentTasks = try await orchestrator.notionServicePublic.queryActiveTasks(type: .commitment)

        // Query Tasks database for follow-ups
        let followupTasks = try await orchestrator.notionServicePublic.queryActiveTasks(type: .followup)

        // Filter by direction if specified
        var filteredCommitments = commitmentTasks
        if let direction = directionFilter {
            filteredCommitments = commitmentTasks.filter { $0.commitmentDirection == direction }
        }

        let hasCommitments = !filteredCommitments.isEmpty
        let hasFollowups = !followupTasks.isEmpty && showFollowups && directionFilter == nil

        if !hasCommitments && !hasFollowups {
            print("ℹ️  No active commitments or follow-ups found\n")
            return
        }

        // Group commitments by direction
        let iOwe = filteredCommitments.filter { $0.commitmentDirection == .iOwe }
        let theyOwe = filteredCommitments.filter { $0.commitmentDirection == .theyOweMe }

        if !iOwe.isEmpty && (directionFilter == nil || directionFilter == .iOwe) {
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            print("📤 I OWE (\(iOwe.count))")
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")

            for task in iOwe.sorted(by: { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }) {
                printTaskItemAsCommitment(task)
            }
        }

        if !theyOwe.isEmpty && (directionFilter == nil || directionFilter == .theyOweMe) {
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            print("📥 THEY OWE ME (\(theyOwe.count))")
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")

            for task in theyOwe.sorted(by: { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }) {
                printTaskItemAsCommitment(task)
            }
        }

        // Show follow-ups section
        if hasFollowups {
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            print("🔔 FOLLOW-UPS (\(followupTasks.count))")
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")

            for task in followupTasks.sorted(by: { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }) {
                printTaskItemAsFollowup(task)
            }
        }

        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")

    } catch {
        print("❌ Failed to fetch commitments: \(error)\n")
    }
}

func runCommitmentsOverdue(_ orchestrator: BriefingOrchestrator) async {
    print("\n⚠️  OVERDUE COMMITMENTS\n")

    guard let config = orchestrator.config.commitments, config.enabled else {
        print("❌ Commitments feature is not enabled in config")
        return
    }

    do {
        // Query Tasks database for all active commitments
        let tasks = try await orchestrator.notionServicePublic.queryActiveTasks(type: .commitment)

        // Filter for overdue commitments
        let overdueCommitments = tasks.filter { $0.isOverdue }

        if overdueCommitments.isEmpty {
            print("✅ No overdue commitments!\n")
            return
        }

        // Group by direction
        let iOwe = overdueCommitments.filter { $0.commitmentDirection == .iOwe }
        let theyOwe = overdueCommitments.filter { $0.commitmentDirection == .theyOweMe }

        if !iOwe.isEmpty {
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            print("📤 I OWE - OVERDUE (\(iOwe.count))")
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")

            for task in iOwe.sorted(by: { ($0.dueDate ?? .distantPast) < ($1.dueDate ?? .distantPast) }) {
                printTaskItemAsCommitment(task, showOverdueWarning: true)
            }
        }

        if !theyOwe.isEmpty {
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            print("📥 THEY OWE ME - OVERDUE (\(theyOwe.count))")
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")

            for task in theyOwe.sorted(by: { ($0.dueDate ?? .distantPast) < ($1.dueDate ?? .distantPast) }) {
                printTaskItemAsCommitment(task, showOverdueWarning: true)
            }
        }

        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")

    } catch {
        print("❌ Failed to fetch overdue commitments: \(error)\n")
    }
}

func printCommitmentDetails(_ commitment: Commitment, showOverdueWarning: Bool = false) {
    print("  \(commitment.status.emoji) \(commitment.title)")
    print("     From: \(commitment.committedBy) → To: \(commitment.committedTo)")
    print("     Source: \(commitment.sourcePlatform.displayName) - \(commitment.sourceThread)")

    if let dueDate = commitment.dueDate {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        let dueDateStr = formatter.string(from: dueDate)

        if showOverdueWarning, let daysOverdue = commitment.daysUntilDue {
            print("     Due: \(dueDateStr) ⚠️  \(abs(daysOverdue)) days overdue!")
        } else {
            print("     Due: \(dueDateStr)")
        }
    }

    print("     Priority: \(commitment.priority.emoji) \(commitment.priority.displayName)")
    print("")
}

func printTaskItemAsCommitment(_ task: TaskItem, showOverdueWarning: Bool = false) {
    // Status emoji
    let statusEmoji: String
    switch task.status {
    case .notStarted: statusEmoji = "⭕"
    case .inProgress: statusEmoji = "🔄"
    case .done: statusEmoji = "✅"
    case .blocked: statusEmoji = "🚫"
    case .cancelled: statusEmoji = "❌"
    }

    print("  \(statusEmoji) \(task.title)")

    if let committedBy = task.committedBy, let committedTo = task.committedTo {
        print("     From: \(committedBy) → To: \(committedTo)")
    }

    if let platform = task.sourcePlatform, let thread = task.sourceThread {
        print("     Source: \(platform.rawValue) - \(thread)")
    }

    if let dueDate = task.dueDate {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        let dueDateStr = formatter.string(from: dueDate)

        if showOverdueWarning && task.isOverdue {
            let daysOverdue = Calendar.current.dateComponents([.day], from: dueDate, to: Date()).day ?? 0
            print("     Due: \(dueDateStr) ⚠️  \(abs(daysOverdue)) days overdue!")
        } else {
            print("     Due: \(dueDateStr)")
        }
    }

    if let priority = task.priority {
        let priorityEmoji: String
        switch priority {
        case .critical: priorityEmoji = "🔴"
        case .high: priorityEmoji = "🟠"
        case .medium: priorityEmoji = "🟡"
        case .low: priorityEmoji = "⚪"
        }
        print("     Priority: \(priorityEmoji) \(priority.rawValue)")
    }

    print("")
}

func printTaskItemAsFollowup(_ task: TaskItem) {
    // Status emoji
    let statusEmoji: String
    switch task.status {
    case .notStarted: statusEmoji = "⏰"
    case .inProgress: statusEmoji = "🔄"
    case .done: statusEmoji = "✅"
    case .blocked: statusEmoji = "🚫"
    case .cancelled: statusEmoji = "❌"
    }

    print("  \(statusEmoji) \(task.title)")

    if let context = task.originalContext ?? task.description {
        print("     Context: \(context.prefix(60))\(context.count > 60 ? "..." : "")")
    }

    if let dueDate = task.dueDate {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let dueDateStr = formatter.string(from: dueDate)

        if task.isOverdue {
            let daysOverdue = Calendar.current.dateComponents([.day], from: dueDate, to: Date()).day ?? 0
            print("     Scheduled: \(dueDateStr) ⚠️  \(abs(daysOverdue)) days overdue!")
        } else {
            print("     Scheduled: \(dueDateStr)")
        }
    }

    if let priority = task.priority {
        let priorityEmoji: String
        switch priority {
        case .critical: priorityEmoji = "🔴"
        case .high: priorityEmoji = "🟠"
        case .medium: priorityEmoji = "🟡"
        case .low: priorityEmoji = "⚪"
        }
        print("     Priority: \(priorityEmoji) \(priority.rawValue)")
    }

    print("")
}

