import Foundation

/// Generates AI coaching cards inspired by Bill Campbell and Matt Mochary methodologies.
/// Three card types: Leverage (highest-impact action), Relationship (people signals), Avoidance (procrastination patterns).
class CoachingEngine {
    private let claudeService: ClaudeAIService
    private let alfredService: AlfredService

    // Cache coaching cards for 2 hours (expensive to compute)
    private var cachedCards: [CoachingCard]?
    private var cacheTimestamp: Date?
    private let cacheTTL: TimeInterval = 7200 // 2 hours

    struct CoachingCard: Codable {
        let type: String        // "leverage", "relationship", "avoidance"
        let label: String       // "Leverage", "Relationship", "Avoidance"
        let insight: String     // The coaching text
        let context: String?    // Optional supporting detail
    }

    init(config: AppConfig, alfredService: AlfredService) {
        self.claudeService = ClaudeAIService(config: config.ai)
        self.alfredService = alfredService
    }

    func generateCoachingCards() async throws -> [CoachingCard] {
        // Return cached if fresh
        if let cached = cachedCards, let ts = cacheTimestamp,
           Date().timeIntervalSince(ts) < cacheTTL {
            return cached
        }

        // Generate all three cards concurrently
        async let leverageCard = generateLeverageCard()
        async let relationshipCard = generateRelationshipCard()
        async let avoidanceCard = generateAvoidanceCard()

        let cards = [
            try await leverageCard,
            try await relationshipCard,
            try await avoidanceCard
        ].compactMap { $0 }

        cachedCards = cards
        cacheTimestamp = Date()
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

        guard contextParts.count > 1 else { return nil }

        let prompt = """
        You are an executive coach focused on relationship health. Based on this commitment data, identify the ONE relationship that needs attention most.

        Context:
        \(contextParts.joined(separator: "\n"))

        Rules:
        - Name the specific person
        - Explain what the data suggests (e.g., piling obligations, high overdue rate, one-sided commitment flow)
        - Suggest one concrete action
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
}
