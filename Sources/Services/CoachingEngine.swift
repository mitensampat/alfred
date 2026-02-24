import Foundation

/// Generates AI coaching cards inspired by Bill Campbell and Matt Mochary methodologies.
/// Four card types: Leverage (highest-impact action), Relationship (people signals), Avoidance (procrastination patterns), Attention (where focus is leaking).
class CoachingEngine {
    private let claudeService: ClaudeAIService
    private let alfredService: AlfredService

    // Cache coaching cards for 2 hours (expensive to compute)
    private var cachedCards: [CoachingCard]?
    private var cacheTimestamp: Date?
    private let cacheTTL: TimeInterval = 7200 // 2 hours

    // Debug context: stores the raw context data that drove each card
    var lastDebugContext: [String: [String]] = [:]
    var lastGeneratedAt: Date?

    struct CoachingCard: Codable {
        let type: String        // "leverage", "relationship", "avoidance", "attention"
        let label: String       // "Leverage", "Relationship", "Avoidance", "Attention"
        let insight: String     // The coaching text
        let context: String?    // Optional supporting detail
    }

    init(config: AppConfig, alfredService: AlfredService) {
        self.claudeService = ClaudeAIService(config: config.ai)
        self.alfredService = alfredService
    }

    func generateCoachingCards(forceRefresh: Bool = false) async throws -> [CoachingCard] {
        // Return cached if fresh (unless force-refreshing)
        if !forceRefresh, let cached = cachedCards, let ts = cacheTimestamp,
           Date().timeIntervalSince(ts) < cacheTTL {
            return cached
        }

        // Generate all four core cards concurrently
        async let leverageCard = generateLeverageCard()
        async let relationshipCard = generateRelationshipCard()
        async let avoidanceCard = generateAvoidanceCard()
        async let attentionCard = generateAttentionCard()

        var cards = [
            try await leverageCard,
            try await relationshipCard,
            try await avoidanceCard,
            try await attentionCard
        ].compactMap { $0 }

        // On Friday, Saturday, Sunday — add the Weekly Review card
        let weekday = Calendar.current.component(.weekday, from: Date())
        let isWeekendOrFriday = weekday == 1 || weekday == 6 || weekday == 7  // Sun=1, Fri=6, Sat=7
        if isWeekendOrFriday {
            if let reviewCard = try? await generateWeeklyReviewCard() {
                cards.append(reviewCard)
            }
        }

        cachedCards = cards
        cacheTimestamp = Date()
        lastGeneratedAt = Date()
        return cards
    }

    // MARK: - Leverage Card

    /// What is the single highest-leverage action right now?
    private func generateLeverageCard() async throws -> CoachingCard? {
        var contextParts: [String] = []

        // Get active tasks
        if let orchestrator = alfredService.orchestrator {
            do {
                let tasks = try await orchestrator.notionServicePublic.queryActiveTasks()
                let overdue = tasks.filter { $0.isOverdue }
                let critical = tasks.filter { $0.priority == .critical || $0.priority == .high }

                contextParts.append("Active tasks: \(tasks.count)")
                contextParts.append("Overdue: \(overdue.count)")
                contextParts.append("Critical/High priority: \(critical.count)")

                // List top tasks
                let topTasks = tasks.sorted { a, b in
                    let priorityWeight: [TaskItem.Priority: Int] = [.critical: 0, .high: 1, .medium: 2, .low: 3]
                    let aPri = a.priority.map { priorityWeight[$0] ?? 4 } ?? 4
                    let bPri = b.priority.map { priorityWeight[$0] ?? 4 } ?? 4
                    if aPri != bPri { return aPri < bPri }
                    let aDate = a.dueDate ?? Date.distantFuture
                    let bDate = b.dueDate ?? Date.distantFuture
                    return aDate < bDate
                }.prefix(8)

                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "MMM d"

                for task in topTasks {
                    let due = task.dueDate.map { dateFormatter.string(from: $0) } ?? "no deadline"
                    let overdueMark = task.isOverdue ? " [OVERDUE]" : ""
                    contextParts.append("- [\(task.priority?.rawValue ?? "None")] \(task.title) (due: \(due))\(overdueMark)")
                }
            } catch {
                contextParts.append("Tasks: unavailable")
            }
        }

        // Calendar context
        do {
            let calBriefing = try await alfredService.fetchCalendarBriefing(for: Date())
            let meetings = calBriefing.schedule.events
            let remaining = meetings.filter { $0.startTime > Date() }
            contextParts.append("Meetings today: \(meetings.count) (\(remaining.count) remaining)")
        } catch {
            // Not critical
        }

        lastDebugContext["leverage"] = contextParts

        guard !contextParts.isEmpty else { return nil }

        let prompt = """
        You are a ruthlessly practical executive coach. Given this person's current workload, identify the SINGLE highest-leverage action they should take right now.

        Context:
        \(contextParts.joined(separator: "\n"))

        Rules:
        - Pick ONE specific action, not a list
        - Reference a specific task or person by name
        - Explain WHY it's the highest leverage in one sentence
        - No emojis, no fluff, plain language
        - Maximum 2 sentences total
        - If someone is waiting on something overdue, that's usually highest leverage

        Respond with ONLY the coaching insight text. No JSON, no labels, no preamble.
        """

        let response = try await claudeService.generateText(
            prompt: prompt,
            maxTokens: 200,
            useModel: nil // Use default model (Haiku is set as message model, but coaching needs quality)
        )

        return CoachingCard(
            type: "leverage",
            label: "Leverage",
            insight: response.trimmingCharacters(in: .whitespacesAndNewlines),
            context: nil
        )
    }

    // MARK: - Relationship Card

    /// Who needs attention? Unusual silence, piling-up obligations.
    private func generateRelationshipCard() async throws -> CoachingCard? {
        var contextParts: [String] = []

        // Get commitment stats by counterparty
        let counterpartyStats = TaskLifecycleTracker.shared.getStatsByCounterparty()
        if !counterpartyStats.isEmpty {
            contextParts.append("Commitment history by person:")
            for stat in counterpartyStats.prefix(8) {
                contextParts.append("- \(stat.name): \(stat.totalTasks) total, \(stat.completedTasks) completed, \(Int(stat.overdueRate * 100))% overdue rate")
            }
        }

        // Get open commitments grouped by person
        if let orchestrator = alfredService.orchestrator {
            do {
                let tasks = try await orchestrator.notionServicePublic.queryActiveTasks(type: .commitment)
                let byPerson = Dictionary(grouping: tasks) { $0.committedTo ?? $0.committedBy ?? "Unknown" }
                let sorted = byPerson.sorted { $0.value.count > $1.value.count }

                if !sorted.isEmpty {
                    contextParts.append("\nOpen commitments by person:")
                    for (person, tasks) in sorted.prefix(6) {
                        let overdue = tasks.filter { $0.isOverdue }.count
                        contextParts.append("- \(person): \(tasks.count) open\(overdue > 0 ? ", \(overdue) overdue" : "")")
                    }
                }
            } catch {
                // Not critical
            }
        }

        // Tracker stats
        let stats = CommitmentScanTracker.shared.getStats()
        contextParts.append("\nOverall: \(stats.openCommitments) open commitments across \(stats.threadsTracked) threads")

        // Recent message interactions (WhatsApp) — so we don't nudge about recently-contacted people
        if let config = alfredService.orchestrator?.config {
            do {
                let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
                let reader = WhatsAppReader(dbPath: config.messaging.whatsapp.dbPath)
                try reader.connect()
                let threads = try reader.fetchThreads(since: sevenDaysAgo)

                if !threads.isEmpty {
                    let formatter = RelativeDateTimeFormatter()
                    formatter.unitsStyle = .full
                    contextParts.append("\nRecent message interactions (last 7 days):")
                    for thread in threads.sorted(by: { $0.lastMessageDate > $1.lastMessageDate }).prefix(10) {
                        let name = thread.contactName ?? thread.contactIdentifier
                        let ago = formatter.localizedString(for: thread.lastMessageDate, relativeTo: Date())
                        contextParts.append("- \(name): last message \(ago) (WhatsApp)")
                    }
                }
            } catch {
                // Non-fatal — message data is supplementary
            }
        }

        lastDebugContext["relationship"] = contextParts

        guard contextParts.count > 1 else { return nil }

        let prompt = """
        You are an executive coach focused on relationship health. Based on this commitment and communication data, identify the ONE relationship that needs attention most.

        Context:
        \(contextParts.joined(separator: "\n"))

        Rules:
        - Name the specific person
        - Explain what the data suggests (e.g., piling obligations, high overdue rate, one-sided commitment flow)
        - Suggest one concrete action
        - NEVER suggest reaching out to someone who has had message interaction in the last 7 days — they don't need a nudge
        - Only flag relationships where there are BOTH commitment issues AND communication silence (no messages in 7+ days)
        - No emojis, no fluff
        - Maximum 2 sentences total

        Respond with ONLY the coaching insight text. No JSON, no labels, no preamble.
        """

        let response = try await claudeService.generateText(
            prompt: prompt,
            maxTokens: 200
        )

        return CoachingCard(
            type: "relationship",
            label: "Relationship",
            insight: response.trimmingCharacters(in: .whitespacesAndNewlines),
            context: nil
        )
    }

    // MARK: - Avoidance Card

    /// What are you avoiding? Tasks created >14 days ago still not started, or frequently rescheduled.
    private func generateAvoidanceCard() async throws -> CoachingCard? {
        var contextParts: [String] = []
        let calendar = Calendar.current
        let fourteenDaysAgo = calendar.date(byAdding: .day, value: -14, to: Date())!

        if let orchestrator = alfredService.orchestrator {
            do {
                let tasks = try await orchestrator.notionServicePublic.queryActiveTasks()

                // Tasks created >14 days ago still "Not Started"
                let stale = tasks.filter { task in
                    task.status == .notStarted && task.createdDate < fourteenDaysAgo
                }

                if !stale.isEmpty {
                    contextParts.append("Tasks created over 14 days ago, still Not Started:")
                    let dateFormatter = DateFormatter()
                    dateFormatter.dateFormat = "MMM d"
                    for task in stale.prefix(5) {
                        let age = calendar.dateComponents([.day], from: task.createdDate, to: Date()).day ?? 0
                        contextParts.append("- \(task.title) (created \(age) days ago, \(task.priority?.rawValue ?? "no priority"))")
                    }
                }

                // Escalated avoidance: tasks >21 days old, still not started
                let twentyOneDaysAgo = calendar.date(byAdding: .day, value: -21, to: Date())!
                let escalated = tasks.filter { task in
                    task.status == .notStarted && task.createdDate < twentyOneDaysAgo
                }
                if !escalated.isEmpty {
                    contextParts.append("\n=== ESCALATED AVOIDANCE (21+ days, still not started) ===")
                    for task in escalated.prefix(3) {
                        let age = calendar.dateComponents([.day], from: task.createdDate, to: Date()).day ?? 0
                        contextParts.append("- [ESCALATED] \(task.title) (untouched for \(age) days)")
                    }
                }

                // Tasks that are overdue and low priority (classic avoidance)
                let avoidedOverdue = tasks.filter { task in
                    task.isOverdue && (task.priority == .low || task.priority == .medium)
                }

                if !avoidedOverdue.isEmpty {
                    contextParts.append("\nOverdue low/medium priority tasks (potential avoidance):")
                    for task in avoidedOverdue.prefix(3) {
                        let daysOverdue = task.dueDate.map { calendar.dateComponents([.day], from: $0, to: Date()).day ?? 0 } ?? 0
                        contextParts.append("- \(task.title) (\(daysOverdue) days overdue)")
                    }
                }
            } catch {
                // Not critical
            }
        }

        lastDebugContext["avoidance"] = contextParts

        guard !contextParts.isEmpty else {
            // No avoidance signals — return a positive card
            return CoachingCard(
                type: "avoidance",
                label: "Avoidance",
                insight: "No stale or avoided tasks detected. Your task hygiene looks clean.",
                context: nil
            )
        }

        let prompt = """
        You are an executive coach helping someone recognize procrastination patterns. Based on this data, identify what they're most likely avoiding and why.

        Context:
        \(contextParts.joined(separator: "\n"))

        Rules:
        - Name the specific task or pattern
        - Be empathetic but direct about the avoidance
        - Suggest one concrete next step to break the avoidance (e.g., "spend 15 minutes on X" or "decide to drop it")
        - If there are ESCALATED items (21+ days untouched), be more forceful: "This is the third week X has sat here. Either do it today or decide to drop it. Which is it?"
        - Escalated items take priority over regular avoidance signals
        - No emojis, no fluff
        - Maximum 2 sentences total

        Respond with ONLY the coaching insight text. No JSON, no labels, no preamble.
        """

        let response = try await claudeService.generateText(
            prompt: prompt,
            maxTokens: 200
        )

        return CoachingCard(
            type: "avoidance",
            label: "Avoidance",
            insight: response.trimmingCharacters(in: .whitespacesAndNewlines),
            context: nil
        )
    }

    // MARK: - Attention Card

    /// Where is your attention going? Hybrid of messaging velocity (inbound/outbound), group noise, and calendar load.
    private func generateAttentionCard() async throws -> CoachingCard? {
        var contextParts: [String] = []

        // WhatsApp messaging velocity (last 7 days)
        if let config = alfredService.orchestrator?.config {
            do {
                let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
                let reader = WhatsAppReader(dbPath: config.messaging.whatsapp.dbPath)
                try reader.connect()
                let threads = try reader.fetchThreads(since: sevenDaysAgo)

                var totalIncoming = 0
                var totalOutgoing = 0
                var groupStats: [(name: String, incoming: Int, outgoing: Int, total: Int)] = []
                var dmStats: [(name: String, incoming: Int, outgoing: Int, total: Int)] = []

                for thread in threads {
                    let incoming = thread.messages.filter { $0.direction == .incoming }.count
                    let outgoing = thread.messages.filter { $0.direction == .outgoing }.count
                    let name = thread.contactName ?? thread.contactIdentifier
                    totalIncoming += incoming
                    totalOutgoing += outgoing

                    if thread.contactIdentifier.contains("@g.us") {
                        groupStats.append((name: name, incoming: incoming, outgoing: outgoing, total: incoming + outgoing))
                    } else {
                        dmStats.append((name: name, incoming: incoming, outgoing: outgoing, total: incoming + outgoing))
                    }
                }

                contextParts.append("Messaging velocity (last 7 days):")
                contextParts.append("Total inbound: \(totalIncoming), Total outbound: \(totalOutgoing)")
                let ratio = totalOutgoing > 0 ? String(format: "%.1f", Double(totalIncoming) / Double(totalOutgoing)) : "∞"
                contextParts.append("Inbound/outbound ratio: \(ratio):1")
                contextParts.append("Active groups: \(groupStats.count), Active DMs: \(dmStats.count)")

                // Top groups by volume
                let topGroups = groupStats.sorted { $0.total > $1.total }.prefix(5)
                if !topGroups.isEmpty {
                    contextParts.append("\nTop groups by message volume:")
                    for g in topGroups {
                        contextParts.append("- \(g.name): \(g.total) msgs (\(g.incoming) in, \(g.outgoing) out)")
                    }
                }

                // Top DMs by volume
                let topDMs = dmStats.sorted { $0.total > $1.total }.prefix(5)
                if !topDMs.isEmpty {
                    contextParts.append("\nTop direct conversations:")
                    for d in topDMs {
                        contextParts.append("- \(d.name): \(d.incoming + d.outgoing) msgs (\(d.incoming) in, \(d.outgoing) out)")
                    }
                }

                reader.disconnect()
            } catch {
                contextParts.append("WhatsApp messaging data: unavailable")
            }
        }

        // Calendar load (today)
        do {
            let calBriefing = try await alfredService.fetchCalendarBriefing(for: Date())
            let meetings = calBriefing.schedule.events.filter { !$0.isAllDay }
            let remaining = meetings.filter { $0.startTime > Date() }

            contextParts.append("\nCalendar today:")
            contextParts.append("Meetings: \(meetings.count) total (\(remaining.count) remaining)")

            // Calculate meeting hours
            var totalMinutes = 0
            for event in meetings {
                let duration = Int(event.endTime.timeIntervalSince(event.startTime) / 60)
                totalMinutes += duration
            }
            let hours = totalMinutes / 60
            let mins = totalMinutes % 60
            contextParts.append("Time in meetings: \(hours)h \(mins)m")

            // Detect back-to-back chains (< 15 min gap)
            let sorted = meetings.sorted { $0.startTime < $1.startTime }
            var backToBackCount = 0
            for i in 1..<sorted.count {
                let gap = sorted[i].startTime.timeIntervalSince(sorted[i-1].endTime)
                if gap < 900 { // Less than 15 minutes
                    backToBackCount += 1
                }
            }
            if backToBackCount > 0 {
                contextParts.append("Back-to-back meetings (< 15 min gap): \(backToBackCount)")
            }

            // Free blocks > 30 min
            var freeBlocks: [Int] = [] // in minutes
            let workStart = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!
            let workEnd = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: Date())!
            var cursor = workStart
            for event in sorted {
                if event.startTime > cursor {
                    let gap = Int(event.startTime.timeIntervalSince(cursor) / 60)
                    if gap >= 30 {
                        freeBlocks.append(gap)
                    }
                }
                cursor = max(cursor, event.endTime)
            }
            // After last meeting to work end
            if cursor < workEnd {
                let gap = Int(workEnd.timeIntervalSince(cursor) / 60)
                if gap >= 30 {
                    freeBlocks.append(gap)
                }
            }

            if freeBlocks.isEmpty {
                contextParts.append("Free blocks (30+ min): NONE — no deep work possible today")
            } else {
                let blockDescs = freeBlocks.map { "\($0)m" }.joined(separator: ", ")
                contextParts.append("Free blocks (30+ min): \(freeBlocks.count) (\(blockDescs))")
            }
        } catch {
            contextParts.append("\nCalendar: unavailable")
        }

        lastDebugContext["attention"] = contextParts

        guard contextParts.count > 2 else { return nil }

        let prompt = """
        You are an executive coach analyzing where this person's attention is going. Based on messaging patterns and calendar data, provide ONE sharp observation about their attention allocation.

        Context:
        \(contextParts.joined(separator: "\n"))

        Rules:
        - Focus on the PATTERN, not individual messages
        - A high inbound/outbound ratio (e.g., >10:1) means they're absorbing rather than directing
        - Name specific groups or people that are consuming disproportionate attention
        - If calendar is packed with meetings AND messaging is high, name the double-drain
        - If there are no free blocks, say so directly — "you have no time to think today"
        - Suggest one concrete change (e.g., "mute X group", "block 2 hours for deep work", "decline one meeting")
        - No emojis, no fluff
        - Maximum 2 sentences total

        Respond with ONLY the coaching insight text. No JSON, no labels, no preamble.
        """

        let response = try await claudeService.generateText(
            prompt: prompt,
            maxTokens: 200
        )

        return CoachingCard(
            type: "attention",
            label: "Attention",
            insight: response.trimmingCharacters(in: .whitespacesAndNewlines),
            context: nil
        )
    }

    // MARK: - Weekly Review Card

    /// Matt Mochary-style weekly review: wins, energy, relationships, carry-forward.
    /// Only shown on Friday, Saturday, Sunday.
    private func generateWeeklyReviewCard() async throws -> CoachingCard? {
        var contextParts: [String] = []
        let calendar = Calendar.current

        let today = Date()

        if let orchestrator = alfredService.orchestrator {
            do {
                let allTasks = try await orchestrator.notionServicePublic.queryActiveTasks()

                // Completed tasks this week (approximate: tasks with status .done)
                let completed = allTasks.filter { $0.status == .done }
                let recentCompleted = completed.prefix(10)

                contextParts.append("Tasks completed (showing up to 10):")
                if recentCompleted.isEmpty {
                    contextParts.append("- None found in active view")
                } else {
                    for task in recentCompleted {
                        contextParts.append("- \(task.title) [\(task.priority?.rawValue ?? "none")]")
                    }
                }

                // Open / overdue / stale counts
                let open = allTasks.filter { $0.status != .done }
                let overdue = open.filter { $0.isOverdue }
                let fourteenDaysAgo = calendar.date(byAdding: .day, value: -14, to: today)!
                let stale = open.filter { $0.status == .notStarted && $0.createdDate < fourteenDaysAgo }

                contextParts.append("\nOpen tasks: \(open.count)")
                contextParts.append("Overdue: \(overdue.count)")
                contextParts.append("Stale (14+ days, not started): \(stale.count)")

                // Top priority task (the focus item)
                if let topTask = try? await orchestrator.notionServicePublic.getTopPriorityTask() {
                    let due = topTask.dueDate.map {
                        let df = DateFormatter()
                        df.dateFormat = "MMM d"
                        return df.string(from: $0)
                    } ?? "no deadline"
                    contextParts.append("\nTop priority task: \(topTask.title) (due: \(due))")
                }
            } catch {
                contextParts.append("Tasks: unavailable")
            }
        }

        // Commitment/relationship health
        let commitStats = CommitmentScanTracker.shared.getStats()
        contextParts.append("\nCommitments: \(commitStats.openCommitments) open, \(commitStats.closedCount) closed this period")

        let counterpartyStats = TaskLifecycleTracker.shared.getStatsByCounterparty()
        if !counterpartyStats.isEmpty {
            contextParts.append("\nRelationship health:")
            for stat in counterpartyStats.prefix(5) {
                contextParts.append("- \(stat.name): \(stat.completedTasks)/\(stat.totalTasks) completed, \(Int(stat.overdueRate * 100))% overdue rate")
            }
        }

        // Lifecycle stats
        let lifecycleStats = TaskLifecycleTracker.shared.getStats()
        contextParts.append("\nOverall completion rate: \(Int(lifecycleStats.completionRate * 100))%")
        contextParts.append("Overall overdue rate: \(Int(lifecycleStats.overdueRate * 100))%")

        // Recent coaching sessions for continuity
        let recentSessions = CoachingMemoryService.shared.getRecentSessions(limit: 3)
        if !recentSessions.isEmpty {
            contextParts.append("\nRecent coaching themes:")
            for session in recentSessions {
                // Take first line of each session as summary
                let firstLine = session.components(separatedBy: "\n").first ?? session
                contextParts.append("- \(String(firstLine.prefix(120)))")
            }
        }

        lastDebugContext["weekly_review"] = contextParts

        guard contextParts.count > 2 else { return nil }

        let prompt = """
        You are an executive coach running a weekly review (Matt Mochary style). Assess this person's week across 4 dimensions:

        Context:
        \(contextParts.joined(separator: "\n"))

        Dimensions to assess:
        1. WINS: What did they accomplish? Name specifics from the completed tasks.
        2. ENERGY: Based on the task mix and stale count, are they in their Zone of Genius or stuck grinding through Zone 3 work?
        3. RELATIONSHIPS: Any commitment debt? Who did they neglect?
        4. CARRY FORWARD: ONE thing to focus on next week.

        Rules:
        - Be specific — reference actual tasks and people by name
        - Be honest but encouraging. Acknowledge wins before pushing on gaps.
        - If completion rate is low or stale tasks are high, name the pattern directly
        - 3 sentences maximum. One per dimension is ideal, combine where natural.
        - No emojis, no fluff, no bullet points — flowing prose

        Respond with ONLY the coaching insight text. No JSON, no labels, no preamble.
        """

        let response = try await claudeService.generateText(
            prompt: prompt,
            maxTokens: 300
        )

        return CoachingCard(
            type: "weekly_review",
            label: "Weekly Review",
            insight: response.trimmingCharacters(in: .whitespacesAndNewlines),
            context: nil
        )
    }
}
