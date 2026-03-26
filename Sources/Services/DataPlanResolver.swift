import Foundation

/// Executes a compiled DataPlan at runtime, substituting dynamic parameters and fetching actual data.
/// Returns a context string that gets injected into the LLM prompt.
class DataPlanResolver {
    static let shared = DataPlanResolver()

    /// Runtime context — the dynamic values available at execution time
    struct RuntimeContext {
        let attendeeNames: [String]
        let meetingTitle: String
        let meetingDescription: String?
        let date: Date
        let orchestrator: BriefingOrchestrator
        let config: AppConfig
    }

    /// Execute a data plan and return the gathered context as a string for LLM injection
    func resolve(plan: PromptCompiler.DataPlan, context: RuntimeContext) async -> String {
        var sections: [String] = []

        // Execute all capabilities in parallel for speed
        await withTaskGroup(of: (String, String).self) { group in
            for planned in plan.capabilities {
                group.addTask {
                    let result = await self.executeCapability(
                        id: planned.capabilityId,
                        params: planned.runtimeParams,
                        context: context
                    )
                    return (planned.capabilityId, result)
                }
            }

            for await (capId, result) in group {
                if !result.isEmpty {
                    sections.append(result)
                }
            }
        }

        return sections.joined(separator: "\n\n")
    }

    // MARK: - Capability Executors

    private func executeCapability(id: String, params: [String], context: RuntimeContext) async -> String {
        switch id {

        case "commitments_with_person":
            return await fetchCommitmentsWithAttendees(context: context)

        case "overdue_commitments":
            return await fetchOverdueCommitments(context: context)

        case "active_tasks":
            return await fetchActiveTasks(context: context)

        case "completed_tasks":
            return await fetchCompletedTasks(context: context)

        case "notion_notes_search":
            return await fetchNotionNotes(context: context)

        case "recent_threads_with_person":
            return await fetchRecentThreads(context: context)

        case "calendar_events":
            return await fetchCalendarEvents(context: context)

        case "contact_lookup":
            return await lookupContacts(context: context)

        case "coaching_context":
            return await fetchCoachingContext(context: context)

        case "learned_patterns":
            return await fetchLearnedPatterns(context: context)

        case "attention_analysis":
            return await fetchAttentionAnalysis(context: context)

        default:
            return ""
        }
    }

    // MARK: - Individual Resolvers

    private func fetchCommitmentsWithAttendees(context: RuntimeContext) async -> String {
        guard !context.attendeeNames.isEmpty else { return "" }

        do {
            let allCommitments = try await context.orchestrator.notionServicePublic.queryActiveCommitmentsFromTasks(type: nil)
            var result = "COMMITMENTS WITH ATTENDEES:\n"
            var found = false

            for name in context.attendeeNames {
                let nameLower = name.lowercased()
                let matched = allCommitments.filter { c in
                    c.committedBy.lowercased().contains(nameLower) || c.committedTo.lowercased().contains(nameLower)
                }
                if matched.isEmpty {
                    result += "- \(name): No open commitments\n"
                } else {
                    found = true
                    for c in matched.prefix(3) {
                        let direction = c.type == .iOwe ? "You owe them" : "They owe you"
                        let dueStr = c.dueDate.map { " (due \(Self.dateFmt.string(from: $0)))" } ?? ""
                        result += "- \(name) — \(direction): \(c.title)\(dueStr)\n"
                    }
                }
            }
            return result
        } catch {
            return "COMMITMENTS: Unable to fetch — \(error.localizedDescription)\n"
        }
    }

    private func fetchOverdueCommitments(context: RuntimeContext) async -> String {
        do {
            let overdue = try await context.orchestrator.notionServicePublic.queryOverdueCommitmentsFromTasks()
            if overdue.isEmpty { return "OVERDUE COMMITMENTS: None\n" }
            var result = "OVERDUE COMMITMENTS:\n"
            for c in overdue.prefix(5) {
                let dueStr = c.dueDate.map { " (was due \(Self.dateFmt.string(from: $0)))" } ?? ""
                result += "- \(c.title) → \(c.committedTo)\(dueStr)\n"
            }
            return result
        } catch {
            return ""
        }
    }

    private func fetchActiveTasks(context: RuntimeContext) async -> String {
        do {
            let tasks = try await context.orchestrator.notionServicePublic.queryActiveTasks(type: nil)
            if tasks.isEmpty { return "ACTIVE TASKS: None\n" }
            var result = "ACTIVE TASKS (top 5):\n"
            for t in tasks.prefix(5) {
                let priority = t.priority.map { " [\($0.rawValue)]" } ?? ""
                let dueStr = t.dueDate.map { " due \(Self.dateFmt.string(from: $0))" } ?? ""
                result += "- \(t.title)\(priority)\(dueStr)\n"
            }
            return result
        } catch {
            return ""
        }
    }

    private func fetchCompletedTasks(context: RuntimeContext) async -> String {
        do {
            let tasks = try await context.orchestrator.notionServicePublic.queryRecentlyCompletedTasks(days: 7)
            if tasks.isEmpty { return "RECENTLY COMPLETED: None in last 7 days\n" }
            var result = "RECENTLY COMPLETED TASKS:\n"
            for t in tasks.prefix(5) {
                result += "- \(t.title)\n"
            }
            return result
        } catch {
            return ""
        }
    }

    private func fetchNotionNotes(context: RuntimeContext) async -> String {
        let notesDbIds = (context.config.notion.contextDatabases ?? [])
            .filter { !$0.isEmpty && $0 != "YOUR_NOTES_DATABASE_ID" }

        guard !notesDbIds.isEmpty else { return "" }

        let searchContext = "\(context.meetingTitle) \(context.attendeeNames.joined(separator: " "))"

        var allNotes: [NotionNote] = []
        await withTaskGroup(of: [NotionNote].self) { group in
            for dbId in notesDbIds {
                group.addTask {
                    (try? await context.orchestrator.notionServicePublic.queryRelevantNotes(context: searchContext, databaseId: dbId)) ?? []
                }
            }
            for await notes in group {
                allNotes.append(contentsOf: notes)
            }
        }

        var seenIds = Set<String>()
        let deduped = allNotes.filter { seenIds.insert($0.id).inserted }
        let relevant = Array(deduped.prefix(5))

        if relevant.isEmpty { return "NOTION NOTES: No relevant notes found for '\(context.meetingTitle)'\n" }

        var result = "NOTION NOTES (Second Brain / Granola Notes):\n"
        for note in relevant {
            result += "- \(note.title)"
            if !note.content.isEmpty {
                result += ": \(String(note.content.prefix(200)))"
            }
            result += "\n"
        }
        return result
    }

    private func fetchRecentThreads(context: RuntimeContext) async -> String {
        guard !context.attendeeNames.isEmpty else { return "" }

        var result = "RECENT MESSAGE THREADS:\n"
        for name in context.attendeeNames.prefix(6) {
            if let thread = try? await context.orchestrator.getFocusedWhatsAppThread(contactName: name, timeframe: "7d") {
                if !thread.summary.isEmpty {
                    result += "- \(name): \(String(thread.summary.prefix(200)))\n"
                }
                if !thread.actionItems.isEmpty {
                    let items = thread.actionItems.prefix(2).map { $0.item }.joined(separator: "; ")
                    result += "  Action items: \(items)\n"
                }
            } else {
                result += "- \(name): No recent messages found\n"
            }
        }
        return result
    }

    private func fetchCalendarEvents(context: RuntimeContext) async -> String {
        do {
            let schedule = try await context.orchestrator.calendarServicePublic.fetchEventsFromAllCalendars(
                for: context.date, userSettings: context.config.user
            )
            let events = schedule.events.filter { !$0.isAllDay }
            if events.isEmpty { return "CALENDAR: No events today\n" }
            let timeFmt = DateFormatter()
            timeFmt.dateFormat = "h:mm a"
            var result = "TODAY'S CALENDAR (\(events.count) events):\n"
            for e in events.prefix(8) {
                result += "- \(timeFmt.string(from: e.startTime)) \(e.title)\n"
            }
            return result
        } catch {
            return ""
        }
    }

    private func lookupContacts(context: RuntimeContext) async -> String {
        guard !context.attendeeNames.isEmpty else { return "" }
        // Check if attendees are external (non-company email)
        var result = "ATTENDEE CONTEXT:\n"
        for name in context.attendeeNames {
            result += "- \(name): (lookup available via coaching context)\n"
        }
        return result
    }

    private func fetchCoachingContext(context: RuntimeContext) async -> String {
        let ctx = CoachingMemoryService.shared.getCoachingContext()
        if ctx.isEmpty { return "" }
        return "COACHING CONTEXT:\n\(String(ctx.prefix(500)))\n"
    }

    private func fetchLearnedPatterns(context: RuntimeContext) async -> String {
        let patterns = WorkflowLearningService.shared.getLearnedPatterns()
            .filter { !$0.isStale && !$0.isArchived && $0.confidence >= 0.6 }
        if patterns.isEmpty { return "" }
        var result = "LEARNED PATTERNS:\n"
        for p in patterns.prefix(5) {
            result += "- \(p.description)\n"
        }
        return result
    }

    private func fetchAttentionAnalysis(context: RuntimeContext) async -> String {
        // Lightweight — just return task + calendar stats
        do {
            let tasks = try await context.orchestrator.notionServicePublic.queryActiveTasks(type: nil)
            let overdue = tasks.filter { $0.dueDate != nil && $0.dueDate! < Date() }
            return "ATTENTION: \(tasks.count) active tasks, \(overdue.count) overdue\n"
        } catch {
            return ""
        }
    }

    // MARK: - Helpers

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()
}
