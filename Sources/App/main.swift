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
                await runAttentionDefense(orchestrator, sendNotifications: shouldSendNotifications)
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
            case "send-draft":
                let draftNumber = filteredArgs.count > 2 ? Int(filteredArgs[2]) : nil
                await runSendDraft(orchestrator, draftNumber: draftNumber)
            case "clear-drafts":
                await runClearDrafts()
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
            if todos.isEmpty {
                print("\n✓ No todos detected in recent WhatsApp messages")
            } else {
                print("\n✓ Successfully created \(todos.count) todo(s) in Notion")
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
            print("  alfred send-draft <number>  - Send a specific draft")
            print("  alfred send-draft all       - Send all drafts")
            print("  alfred clear-drafts         - Remove all drafts without sending\n")

        } catch {
            print("Error reading drafts: \(error)\n")
        }
    }

    static func runSendDraft(_ orchestrator: BriefingOrchestrator, draftNumber: Int?) async {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let draftsFile = homeDir.appendingPathComponent(".alfred/message_drafts.json")

        guard FileManager.default.fileExists(atPath: draftsFile.path) else {
            print("❌ No drafts found\n")
            return
        }

        do {
            let data = try Data(contentsOf: draftsFile)
            var drafts = try JSONDecoder().decode([MessageDraft].self, from: data)

            if drafts.isEmpty {
                print("❌ No drafts found\n")
                return
            }

            // Determine which drafts to send
            let draftsToSend: [MessageDraft]
            let remainingDrafts: [MessageDraft]

            if let number = draftNumber, number > 0, number <= drafts.count {
                // Send specific draft
                draftsToSend = [drafts[number - 1]]
                remainingDrafts = drafts.enumerated().filter { $0.offset != number - 1 }.map { $0.element }
            } else {
                print("❌ Invalid draft number. Use 'alfred drafts' to see available drafts.\n")
                return
            }

            // Send drafts
            let messageSender = MessageSender(config: orchestrator.config)
            var successCount = 0
            var failedCount = 0

            for draft in draftsToSend {
                print("\n📤 Sending to \(draft.recipient) via \(draft.platform.rawValue)...")
                do {
                    let result = try await messageSender.sendMessage(draft: draft)
                    if result.isSuccess {
                        successCount += 1
                    } else {
                        failedCount += 1
                    }
                } catch {
                    print("❌ Failed: \(error)")
                    failedCount += 1
                }
            }

            // Update drafts file
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let updatedData = try encoder.encode(remainingDrafts)
            try updatedData.write(to: draftsFile)

            // Summary
            print("\n" + String(repeating: "=", count: 60))
            print("✓ Sent: \(successCount)")
            if failedCount > 0 {
                print("❌ Failed: \(failedCount)")
            }
            print("\(remainingDrafts.count) draft(s) remaining\n")

        } catch {
            print("Error: \(error)\n")
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

    static func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration / 3600)
        let minutes = Int((duration.truncatingRemainder(dividingBy: 3600)) / 60)
        return "\(hours)h \(minutes)m"
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

          schedule              Run in scheduled mode (auto-generates briefings)
          auth                  Authenticate with Google Calendar

          notion-todos          Process WhatsApp messages to yourself and create Notion todos
          test-notion           Test Notion integration (creates test todo and searches)

          drafts                View message drafts created by agents
          send-draft <number>   Send a specific draft (use number from 'drafts' command)
          clear-drafts          Remove all drafts without sending

        Flags:
          --notify              Send output via configured notification channels (email, Slack, push)

        Examples:
          alfred briefing
          alfred briefing tomorrow --notify
          alfred messages imessage 1h
          alfred messages whatsapp "Family Group" 24h
          alfred calendar tomorrow
          alfred calendar primary tomorrow
          alfred calendar work
          alfred attention --notify

          alfred drafts         # View agent-created message drafts
          alfred send-draft 1   # Send first draft
          alfred clear-drafts   # Clear all drafts

        Agent Workflow:
          1. Run 'alfred briefing' - agents analyze messages and create drafts
          2. Run 'alfred drafts' - review what agents want to send
          3. Run 'alfred send-draft <number>' - approve and send specific drafts

        Configuration:
          Edit Config/config.json with your credentials
        """)
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
