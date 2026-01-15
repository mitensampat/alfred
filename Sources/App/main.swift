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

        // Check for --email flag
        let shouldSendEmail = arguments.contains("--email")
        let filteredArgs = arguments.filter { $0 != "--email" }

        if filteredArgs.count > 1 {
            switch filteredArgs[1] {
            case "briefing":
                let date = filteredArgs.count > 2 ? parseDate(filteredArgs[2]) : nil
                await runBriefing(orchestrator, for: date, sendEmail: shouldSendEmail)
            case "messages":
                let platform = filteredArgs.count > 2 ? filteredArgs[2] : "all"
                let timeframe = filteredArgs.count > 3 ? filteredArgs[3] : "24h"
                await runMessagesSummary(orchestrator, platform: platform, timeframe: timeframe)
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
                await runAttentionDefense(orchestrator, sendEmail: shouldSendEmail)
            case "schedule":
                print("Starting scheduled mode...")
                await scheduler.start()
            case "auth":
                await runGoogleAuth(config)
            case "notion-todos":
                await runNotionTodos(orchestrator)
            case "test-notion":
                await testNotion(orchestrator)
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

    static func runBriefing(_ orchestrator: BriefingOrchestrator, for date: Date?, sendEmail: Bool) async {
        let targetDate = date ?? Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        print("\nGenerating briefing for \(targetDate.formatted(date: .long, time: .omitted))...\n")
        do {
            let briefing = try await orchestrator.generateBriefing(for: targetDate, sendEmail: sendEmail)
            print("\n=== DAILY BRIEFING ===\n")
            printBriefing(briefing)
            if sendEmail {
                print("\n✓ Briefing sent via email to \(orchestrator.config.notifications.email.smtpUsername)")
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
        } catch {
            print("Error fetching messages: \(error)")
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

    static func runAttentionDefense(_ orchestrator: BriefingOrchestrator, sendEmail: Bool) async {
        print("\nGenerating attention defense report...\n")
        do {
            let report = try await orchestrator.generateAttentionDefenseAlert(sendEmail: sendEmail)
            print("\n=== ATTENTION DEFENSE REPORT ===\n")
            printAttentionReport(report)
            if sendEmail {
                print("\n✓ Report sent via email to \(orchestrator.config.notifications.email.smtpUsername)")
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

        print("\n\nACTION ITEMS (\(briefing.actionItems.count))")
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

        Flags:
          --email               Send output via email (in addition to terminal)

        Examples:
          alfred briefing
          alfred briefing tomorrow --email
          alfred messages imessage 1h
          alfred calendar tomorrow
          alfred calendar primary tomorrow
          alfred calendar work
          alfred attention --email

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
