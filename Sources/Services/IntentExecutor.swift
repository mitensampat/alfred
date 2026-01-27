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
        case (.analyze, .messages), (.list, .messages):
            let platform = intent.filters.platform?.rawValue ?? "all"
            let timeframe = intent.filters.lookbackDays.map { "\($0)d" } ?? "24h"
            let summaries = try await orchestrator.getMessagesSummary(platform: platform, timeframe: timeframe)
            return formatMessagesResponse(summaries, query: intent.originalQuery)

        case (.find, .thread), (.summarize, .thread):
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

        // MARK: - Attention Check
        case (.check, .attention), (.generate, .attention):
            let report = try await orchestrator.generateAttentionDefenseAlert(sendNotifications: false)
            return formatAttentionCheckResponse(report, query: intent.originalQuery)

        // MARK: - Drafts
        case (.list, .drafts):
            let drafts = try await fetchDrafts()
            return formatDraftsResponse(drafts, query: intent.originalQuery)

        case (_, nil):
            // Target is ambiguous - this should have been caught by clarification
            return IntentExecutionResult(
                data: [:] as [String: Any],
                conversationalResponse: "I'm not sure what you'd like me to help with. Could you be more specific?",
                structuredData: nil
            )

        default:
            throw IntentExecutionError.unsupportedIntent(action: intent.action.rawValue, target: intent.target?.rawValue ?? "unknown")
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
                    // Use unified Tasks database
                    let existingCommitment = try await orchestrator.notionServicePublic.findCommitmentByHashInTasks(
                        commitment.uniqueHash
                    )

                    if existingCommitment == nil {
                        _ = try await orchestrator.notionServicePublic.createCommitmentInTasks(commitment)
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
        return IntentExecutionResult(data: thread, conversationalResponse: "Here's the thread analysis", structuredData: nil)
    }

    private func formatCommitmentScanResponse(_ result: CommitmentScanResult, query: String) -> IntentExecutionResult {
        let response = "I found \(result.totalFound) commitments. Saved \(result.saved) new ones (\(result.duplicates) were duplicates)."
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
