import Foundation

/// Generates AI coaching cards from a unified skill pipeline.
/// All coaching cards (installed methodologies + user-created) flow through the same architecture.
/// Installed skills: Relational Method (Leverage, Relationships) + Direct Method (Avoidance, Attention, Weekly Review).
/// User skills: custom coaching cards created by the user in ~/.alfred/skills/user/.
class CoachingEngine {
    private let claudeService: ClaudeAIService
    private let alfredService: AlfredService

    // Cache coaching cards for 2 hours (expensive to compute)
    private(set) var cachedCards: [CoachingCard]?
    private var cacheTimestamp: Date?
    private let cacheTTL: TimeInterval = 7200 // 2 hours

    // Short-TTL cache for data sources to avoid redundant fetches when multiple skills
    // request the same data source during a single generateCoachingCards() run
    private var dataSourceCache: [String: (data: String, timestamp: Date)] = [:]
    private let dataSourceCacheTTL: TimeInterval = 60 // 1 minute

    // Debug context: stores the raw context data that drove each card
    var lastDebugContext: [String: [String]] = [:]
    var lastGeneratedAt: Date?

    // Per-skill run results for QA/Preview (status, context, timestamp per skill)
    var lastSkillResults: [String: SkillRunResult] = [:]

    /// Internal result from generateSkillCard — bundles the card with side-effect data
    /// so that shared dictionary mutations happen serially, not from concurrent TaskGroup tasks.
    private struct SkillCardOutput: Sendable {
        let card: CoachingCard?
        let skillId: String
        let debugContext: [String]?
        let result: SkillRunResult
    }

    struct CoachingCard: Codable {
        let type: String        // "leverage", "relationship", "avoidance", "attention"
        let label: String       // "Leverage", "Relationship", "Avoidance", "Attention"
        let insight: String     // The coaching text
        let context: String?    // Optional supporting detail
    }

    struct SkillRunResult {
        let card: CoachingCard?
        let status: String       // "success" | "error" | "no_context" | "fallback" | "thin_context" | "no_signal"
        let context: [String]    // raw context data lines
        let error: String?
        let generatedAt: Date
    }

    /// Return cached coaching cards paired with the context data that generated each one.
    /// Zero-cost cache read — no LLM calls, no API calls.
    /// Returns nil if no cards have been generated yet or the cache has expired.
    func getCachedCardInsightsWithContext() -> [(card: CoachingCard, contextData: [String])]? {
        guard let cached = cachedCards, let ts = cacheTimestamp,
              Date().timeIntervalSince(ts) < cacheTTL else {
            return nil
        }
        return cached.map { card in
            let context = lastDebugContext[card.type] ?? []
            return (card: card, contextData: context)
        }
    }

    init(config: AppConfig, alfredService: AlfredService) {
        self.claudeService = ClaudeAIService(config: config.ai, userName: config.user.name)
        self.alfredService = alfredService
    }

    // MARK: - Disk Cache

    private var alfredDataDir: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".alfred").path
    }

    private var cardsDiskPath: String {
        "\(alfredDataDir)/coaching_cards_today.json"
    }

    /// Save coaching cards to disk with today's date and generation timestamp.
    func saveCardsToDisk(_ cards: [CoachingCard]) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let payload: [String: Any] = [
            "date": dateFormatter.string(from: Date()),
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "cards": cards.map { card -> [String: Any] in
                var dict: [String: Any] = ["type": card.type, "label": card.label, "insight": card.insight]
                if let ctx = card.context { dict["context"] = ctx }
                return dict
            }
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
            try data.write(to: URL(fileURLWithPath: cardsDiskPath), options: .atomic)
            print("[CoachingEngine] Coaching cards saved to disk (\(cards.count) cards)")
        } catch {
            print("[CoachingEngine] Failed to save coaching cards to disk: \(error)")
        }
    }

    /// Load same-day coaching cards from disk. Returns nil if absent, stale (>4h), or different day.
    func loadCardsFromDisk() -> [CoachingCard]? {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let todayStr = dateFormatter.string(from: Date())
        guard FileManager.default.fileExists(atPath: cardsDiskPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: cardsDiskPath)),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let date = payload["date"] as? String, date == todayStr else { return nil }
        if let genStr = payload["generatedAt"] as? String,
           let genAt = ISO8601DateFormatter().date(from: genStr),
           Date().timeIntervalSince(genAt) > 14400 { return nil }
        guard let cardsRaw = payload["cards"] as? [[String: Any]] else { return nil }
        let cards: [CoachingCard] = cardsRaw.compactMap { dict in
            guard let type = dict["type"] as? String,
                  let label = dict["label"] as? String,
                  let insight = dict["insight"] as? String else { return nil }
            return CoachingCard(type: type, label: label, insight: insight, context: dict["context"] as? String)
        }
        guard !cards.isEmpty else { return nil }
        print("[CoachingEngine] Loaded \(cards.count) coaching cards from disk cache")
        return cards
    }

    func generateCoachingCards(forceRefresh: Bool = false) async throws -> [CoachingCard] {
        // Return cached if fresh (unless force-refreshing)
        if !forceRefresh, let cached = cachedCards, let ts = cacheTimestamp,
           Date().timeIntervalSince(ts) < cacheTTL {
            return cached
        }

        // Check disk cache (pre-generated during morning briefing cadence)
        if !forceRefresh, let diskCards = loadCardsFromDisk() {
            cachedCards = diskCards
            cacheTimestamp = Date()
            lastGeneratedAt = Date()
            return diskCards
        }

        // Clear per-source cache at the start of each generation cycle
        dataSourceCache.removeAll()

        // --- v2 Pipeline: Layer 1 — Run analysis lenses in parallel (Haiku, fast extraction) ---
        // Signals are persisted by LensExecutionEngine and available to skills + coaching prompt
        let enabledLenses = AnalysisLensLoader.shared.getEnabledLenses()
        if !enabledLenses.isEmpty {
            do {
                let dataContext = try await buildLensDataContext()
                let lensResults = try await LensExecutionEngine.shared.runAllLenses(dataContext: dataContext)
                let totalSignals = lensResults.reduce(0) { $0 + $1.signals.count }
                print("[CoachingEngine] Layer 1 complete: \(totalSignals) signals from \(lensResults.count) lenses")
            } catch {
                print("[CoachingEngine] Layer 1 lens execution failed: \(error.localizedDescription)")
                // Non-fatal — skills can still run without fresh signals
            }
        }

        let weekday = Calendar.current.component(.weekday, from: Date())
        let isWeekendOrFriday = weekday == 1 || weekday == 6 || weekday == 7  // Sun=1, Fri=6, Sat=7

        // All coaching cards now come from the skill pipeline
        let allSkills = SkillLoader.shared.getEnabledSkills()

        // Separate installed vs user skills
        let installedSkills = allSkills.filter { $0.origin == .installed }
        let userSkills = allSkills.filter { $0.origin == .user }

        // Filter by frequency: daily always runs, weekly only on Fri/Sat/Sun
        let installedToRun = installedSkills.filter { skill in
            skill.frequency == "daily" || (skill.frequency == "weekly" && isWeekendOrFriday)
        }
        let userDailySkills = userSkills.filter { $0.frequency == "daily" }
        let userWeeklySkills = userSkills.filter { $0.frequency == "weekly" }

        // Installed skills: ALL enabled run (curated by methodology authors, no cap)
        // User skills: capped at 5 per day
        var userSkillsToRun = Array(userDailySkills.prefix(5))
        if isWeekendOrFriday {
            let remaining = 5 - userSkillsToRun.count
            if remaining > 0 {
                userSkillsToRun.append(contentsOf: userWeeklySkills.prefix(remaining))
            }
        }

        let skillsToRun = installedToRun + userSkillsToRun

        // Run all skills concurrently — dictionary mutations happen serially in the for-await loop
        var cards: [CoachingCard] = []
        await withTaskGroup(of: (Int, SkillCardOutput).self) { group in
            for (index, skill) in skillsToRun.enumerated() {
                group.addTask {
                    let output = await self.generateSkillCard(skill)
                    return (index, output)
                }
            }

            var indexedCards: [(Int, CoachingCard)] = []
            for await (index, output) in group {
                // Apply side effects serially (safe — only one iteration at a time)
                applySkillOutput(output)
                if let card = output.card {
                    indexedCards.append((index, card))
                }
            }

            // Sort by original index to maintain deterministic order:
            // installed first (Leverage → Relationship → Avoidance → Attention → Weekly Review), then user skills
            cards = indexedCards.sorted { $0.0 < $1.0 }.map { $0.1 }
        }

        cachedCards = cards
        cacheTimestamp = Date()
        lastGeneratedAt = Date()

        // Persist to disk for instant loading after process restarts
        saveCardsToDisk(cards)

        return cards
    }

    // MARK: - Skill Card Generation

    /// Generate a coaching card from a skill definition (installed or user-authored).
    /// Returns a SkillCardOutput with all data — does NOT mutate shared dictionaries.
    /// Callers must apply the output to lastDebugContext/lastSkillResults serially.
    private func generateSkillCard(_ skill: SkillDefinition) async -> SkillCardOutput {
        let context = await gatherContextForSkill(dataSources: skill.dataSources)

        // If no context available, check for fallback text
        guard !context.isEmpty else {
            if let fallback = skill.fallback, !fallback.isEmpty {
                // Return a static card with the fallback text (no LLM call needed)
                let card = CoachingCard(
                    type: skill.id,
                    label: "\(skill.icon) \(skill.effectiveName)",
                    insight: fallback,
                    context: nil
                )
                return SkillCardOutput(
                    card: card, skillId: skill.id, debugContext: nil,
                    result: SkillRunResult(card: card, status: "fallback", context: [], error: nil, generatedAt: Date())
                )
            }
            print("[CoachingEngine] Skill '\(skill.name)': no context available for data sources \(skill.dataSources)")
            return SkillCardOutput(
                card: nil, skillId: skill.id, debugContext: nil,
                result: SkillRunResult(card: nil, status: "no_context", context: [], error: nil, generatedAt: Date())
            )
        }

        // Context quality gate: don't generate from thin data
        let contextQuality = scoreContextQuality(context)
        if contextQuality == "thin" {
            print("[CoachingEngine] Skill '\(skill.name)': context too thin (\(context.components(separatedBy: "\n").count) lines), skipping to prevent hallucination")
            if let fallback = skill.fallback, !fallback.isEmpty {
                let card = CoachingCard(
                    type: skill.id,
                    label: "\(skill.icon) \(skill.effectiveName)",
                    insight: fallback,
                    context: nil
                )
                return SkillCardOutput(
                    card: card, skillId: skill.id, debugContext: [context],
                    result: SkillRunResult(card: card, status: "thin_context", context: context.components(separatedBy: "\n"), error: nil, generatedAt: Date())
                )
            }
            return SkillCardOutput(
                card: nil, skillId: skill.id, debugContext: [context],
                result: SkillRunResult(card: nil, status: "thin_context", context: context.components(separatedBy: "\n"), error: nil, generatedAt: Date())
            )
        }

        let contextLines = context.components(separatedBy: "\n")

        var promptParts: [String] = []
        promptParts.append("You are an executive coach.")

        if !skill.tenets.isEmpty {
            promptParts.append("\nTenets to follow:\n\(skill.tenets)")
        }

        // Anti-hallucination grounding rules
        promptParts.append("""

CRITICAL RULES (override everything else):
- ONLY reference people, tasks, dates, and facts that appear VERBATIM in the Context section below.
- If the context doesn't clearly support a recommendation, respond with exactly: "No clear signal today."
- NEVER invent or guess task names, commitment details, or people not explicitly listed in the context.
- If data is sparse or ambiguous, be honest: "Limited data, but..." — never fill gaps with plausible-sounding fabrications.
- Counts and statistics in the context are summaries — do NOT extrapolate specific names or details from aggregate numbers alone.
""")

        promptParts.append("\nContext:\n\(context)")
        promptParts.append("\n\(skill.prompt)")

        let fullPrompt = promptParts.joined(separator: "\n")
        let maxTokens = skill.frequency == "weekly" ? 300 : 200

        do {
            let response = try await claudeService.generateText(
                prompt: fullPrompt,
                maxTokens: maxTokens
            )

            guard !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                // Empty LLM response but we have a fallback
                if let fallback = skill.fallback, !fallback.isEmpty {
                    let card = CoachingCard(
                        type: skill.id,
                        label: "\(skill.icon) \(skill.effectiveName)",
                        insight: fallback,
                        context: nil
                    )
                    return SkillCardOutput(
                        card: card, skillId: skill.id, debugContext: nil,
                        result: SkillRunResult(card: card, status: "fallback", context: contextLines, error: nil, generatedAt: Date())
                    )
                }
                return SkillCardOutput(
                    card: nil, skillId: skill.id, debugContext: nil,
                    result: SkillRunResult(card: nil, status: "error", context: contextLines, error: "Empty LLM response", generatedAt: Date())
                )
            }

            // Detect "no signal" responses from grounded LLM
            let trimmedResponse = response.trimmingCharacters(in: .whitespacesAndNewlines)
            let noSignalPhrases = ["no clear signal", "limited data", "not enough context", "insufficient data", "no strong signal"]
            let isNoSignal = noSignalPhrases.contains { trimmedResponse.lowercased().contains($0) }

            if isNoSignal {
                print("[CoachingEngine] Skill '\(skill.name)': LLM returned no-signal response")
                let card = CoachingCard(
                    type: skill.id,
                    label: "\(skill.icon) \(skill.effectiveName)",
                    insight: trimmedResponse,
                    context: nil
                )
                return SkillCardOutput(
                    card: card, skillId: skill.id, debugContext: [context],
                    result: SkillRunResult(card: card, status: "no_signal", context: contextLines, error: nil, generatedAt: Date())
                )
            }

            let card = CoachingCard(
                type: skill.id,
                label: "\(skill.icon) \(skill.effectiveName)",
                insight: trimmedResponse,
                context: nil
            )
            return SkillCardOutput(
                card: card, skillId: skill.id, debugContext: [context],
                result: SkillRunResult(card: card, status: "success", context: contextLines, error: nil, generatedAt: Date())
            )
        } catch {
            print("[CoachingEngine] Skill '\(skill.name)' failed: \(error)")
            return SkillCardOutput(
                card: nil, skillId: skill.id, debugContext: nil,
                result: SkillRunResult(card: nil, status: "error", context: contextLines, error: error.localizedDescription, generatedAt: Date())
            )
        }
    }

    /// Apply a SkillCardOutput's side effects to shared dictionaries.
    /// Must be called serially (from the for-await loop, not from inside TaskGroup tasks).
    private func applySkillOutput(_ output: SkillCardOutput) {
        lastSkillResults[output.skillId] = output.result
        if let debugCtx = output.debugContext {
            lastDebugContext[output.skillId] = debugCtx
        }
    }

    /// Score the quality/richness of gathered context to prevent hallucination on thin data.
    /// Returns "thin", "moderate", or "rich".
    private func scoreContextQuality(_ context: String) -> String {
        let lines = context.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let dataPoints = lines.filter { $0.hasPrefix("- ") || $0.contains(":") }.count
        let hasNamedEntities = lines.contains { line in
            // Check for lines that reference specific people or tasks (not just headers/stats)
            line.hasPrefix("- ") && !line.contains("unavailable") && line.count > 10
        }
        let hasUnavailable = context.contains("unavailable")

        if dataPoints < 3 || (hasUnavailable && dataPoints < 5) {
            return "thin"
        }
        if dataPoints < 8 || !hasNamedEntities {
            return "moderate"
        }
        return "rich"
    }

    /// Gather context data for a skill based on its requested data sources.
    /// Reuses the same data-fetching logic as the built-in cards.
    /// Uses a short-TTL cache so multiple skills requesting the same data source
    /// in the same generation cycle don't trigger redundant API/DB calls.
    private func gatherContextForSkill(dataSources: [String]) async -> String {
        var contextParts: [String] = []

        for source in dataSources {
            // Check cache first: if another skill already fetched this source recently, reuse it
            if let cached = dataSourceCache[source],
               Date().timeIntervalSince(cached.timestamp) < dataSourceCacheTTL {
                if !cached.data.isEmpty {
                    contextParts.append(cached.data)
                }
                continue
            }

            let sourceData = await fetchSingleDataSource(source)
            dataSourceCache[source] = (data: sourceData, timestamp: Date())
            if !sourceData.isEmpty {
                contextParts.append(sourceData)
            }
        }

        return contextParts.joined(separator: "\n")
    }

    /// Fetch a single data source by name. Returns the context string for that source.
    private func fetchSingleDataSource(_ source: String) async -> String {
        var contextParts: [String] = []

        switch source {
            case "tasks":
                if let orchestrator = alfredService.orchestrator {
                    do {
                        let tasks = try await orchestrator.notionServicePublic.queryActiveTasks()
                        let overdue = tasks.filter { $0.isOverdue }
                        let critical = tasks.filter { $0.priority == .critical || $0.priority == .high }

                        contextParts.append("=== Tasks ===")
                        contextParts.append("Active: \(tasks.count), Overdue: \(overdue.count), Critical/High: \(critical.count)")

                        let dateFormatter = DateFormatter()
                        dateFormatter.dateFormat = "MMM d"

                        let topTasks = tasks.sorted { a, b in
                            let priorityWeight: [TaskItem.Priority: Int] = [.critical: 0, .high: 1, .medium: 2, .low: 3]
                            let aPri = a.priority.map { priorityWeight[$0] ?? 4 } ?? 4
                            let bPri = b.priority.map { priorityWeight[$0] ?? 4 } ?? 4
                            if aPri != bPri { return aPri < bPri }
                            return (a.dueDate ?? Date.distantFuture) < (b.dueDate ?? Date.distantFuture)
                        }.prefix(8)

                        for task in topTasks {
                            let due = task.dueDate.map { dateFormatter.string(from: $0) } ?? "no deadline"
                            let overdueMark = task.isOverdue ? " [OVERDUE]" : ""
                            contextParts.append("- [\(task.priority?.rawValue ?? "None")] \(task.title) (due: \(due))\(overdueMark)")
                        }
                    } catch {
                        contextParts.append("Tasks: unavailable")
                    }
                }

            case "calendar":
                do {
                    let calBriefing = try await alfredService.fetchCalendarBriefing(for: Date())
                    let meetings = calBriefing.schedule.events.filter { !$0.isAllDay }
                    let remaining = meetings.filter { $0.startTime > Date() }

                    contextParts.append("=== Calendar ===")
                    contextParts.append("Meetings today: \(meetings.count) (\(remaining.count) remaining)")

                    var totalMinutes = 0
                    for event in meetings {
                        totalMinutes += Int(event.endTime.timeIntervalSince(event.startTime) / 60)
                    }
                    contextParts.append("Time in meetings: \(totalMinutes / 60)h \(totalMinutes % 60)m")

                    // Free blocks
                    let sorted = meetings.sorted { $0.startTime < $1.startTime }
                    var freeBlocks: [Int] = []
                    let workStart = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!
                    let workEnd = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: Date())!
                    var cursor = workStart
                    for event in sorted {
                        if event.startTime > cursor {
                            let gap = Int(event.startTime.timeIntervalSince(cursor) / 60)
                            if gap >= 30 { freeBlocks.append(gap) }
                        }
                        cursor = max(cursor, event.endTime)
                    }
                    if cursor < workEnd {
                        let gap = Int(workEnd.timeIntervalSince(cursor) / 60)
                        if gap >= 30 { freeBlocks.append(gap) }
                    }

                    if freeBlocks.isEmpty {
                        contextParts.append("Free blocks (30+ min): NONE")
                    } else {
                        let blockDescs = freeBlocks.map { "\($0)m" }.joined(separator: ", ")
                        contextParts.append("Free blocks: \(freeBlocks.count) (\(blockDescs))")
                    }

                    // Back-to-back detection
                    var backToBack = 0
                    for i in 1..<sorted.count {
                        let gap = sorted[i].startTime.timeIntervalSince(sorted[i-1].endTime)
                        if gap < 900 { backToBack += 1 }
                    }
                    if backToBack > 0 {
                        contextParts.append("Back-to-back meetings: \(backToBack)")
                    }
                } catch {
                    contextParts.append("Calendar: unavailable")
                }

            case "messages":
                if let config = alfredService.orchestrator?.config {
                    do {
                        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
                        let reader = WhatsAppSource.reader(config: config)
                        try reader.connect()
                        let threads = try reader.fetchThreads(since: sevenDaysAgo)

                        var totalIncoming = 0
                        var totalOutgoing = 0
                        for thread in threads {
                            totalIncoming += thread.messages.filter { $0.direction == .incoming }.count
                            totalOutgoing += thread.messages.filter { $0.direction == .outgoing }.count
                        }

                        contextParts.append("=== Messages (7 days) ===")
                        contextParts.append("Inbound: \(totalIncoming), Outbound: \(totalOutgoing)")
                        let ratio = totalOutgoing > 0 ? String(format: "%.1f", Double(totalIncoming) / Double(totalOutgoing)) : "∞"
                        contextParts.append("Ratio: \(ratio):1")
                        contextParts.append("Active threads: \(threads.count)")

                        reader.disconnect()
                    } catch {
                        contextParts.append("Messages: unavailable")
                    }
                }

            case "commitments":
                let counterpartyStats = TaskLifecycleTracker.shared.getStatsByCounterparty()
                let trackerStats = CommitmentScanTracker.shared.getStats()

                contextParts.append("=== Commitments ===")
                contextParts.append("Open: \(trackerStats.openCommitments), Threads tracked: \(trackerStats.threadsTracked)")

                if !counterpartyStats.isEmpty {
                    contextParts.append("By person:")
                    for stat in counterpartyStats.prefix(6) {
                        contextParts.append("- \(stat.name): \(stat.totalTasks) total, \(stat.completedTasks) done, \(Int(stat.overdueRate * 100))% overdue")
                    }
                }

            case "coaching_memory":
                let recentSessions = CoachingMemoryService.shared.getRecentSessions(limit: 3)
                if !recentSessions.isEmpty {
                    contextParts.append("=== Recent Coaching Themes ===")
                    for session in recentSessions {
                        let firstLine = session.components(separatedBy: "\n").first ?? session
                        contextParts.append("- \(String(firstLine.prefix(120)))")
                    }
                }

            case "tasks_detailed":
                // Enriched task data: stale tiers (14d/21d escalation), overdue low/med priority
                if let orchestrator = alfredService.orchestrator {
                    do {
                        let tasks = try await orchestrator.notionServicePublic.queryActiveTasks()
                        let cal = Calendar.current
                        let fourteenDaysAgo = cal.date(byAdding: .day, value: -14, to: Date())!
                        let twentyOneDaysAgo = cal.date(byAdding: .day, value: -21, to: Date())!

                        contextParts.append("=== Tasks (Detailed) ===")
                        contextParts.append("Active: \(tasks.count)")

                        // Stale tasks (14+ days, not started)
                        let stale = tasks.filter { $0.status == .notStarted && $0.createdDate < fourteenDaysAgo }
                        if !stale.isEmpty {
                            contextParts.append("\nTasks created over 14 days ago, still Not Started:")
                            let dateFormatter = DateFormatter()
                            dateFormatter.dateFormat = "MMM d"
                            for task in stale.prefix(5) {
                                let age = cal.dateComponents([.day], from: task.createdDate, to: Date()).day ?? 0
                                contextParts.append("- \(task.title) (created \(age) days ago, \(task.priority?.rawValue ?? "no priority"))")
                            }
                        }

                        // Escalated avoidance (21+ days)
                        let escalated = tasks.filter { $0.status == .notStarted && $0.createdDate < twentyOneDaysAgo }
                        if !escalated.isEmpty {
                            contextParts.append("\n=== ESCALATED AVOIDANCE (21+ days, still not started) ===")
                            for task in escalated.prefix(3) {
                                let age = cal.dateComponents([.day], from: task.createdDate, to: Date()).day ?? 0
                                contextParts.append("- [ESCALATED] \(task.title) (untouched for \(age) days)")
                            }
                        }

                        // Overdue low/medium priority (classic avoidance)
                        let avoidedOverdue = tasks.filter { $0.isOverdue && ($0.priority == .low || $0.priority == .medium) }
                        if !avoidedOverdue.isEmpty {
                            contextParts.append("\nOverdue low/medium priority tasks (potential avoidance):")
                            for task in avoidedOverdue.prefix(3) {
                                let daysOverdue = task.dueDate.map { cal.dateComponents([.day], from: $0, to: Date()).day ?? 0 } ?? 0
                                contextParts.append("- \(task.title) (\(daysOverdue) days overdue)")
                            }
                        }

                        // Also include summary stats
                        let overdue = tasks.filter { $0.isOverdue }
                        let critical = tasks.filter { $0.priority == .critical || $0.priority == .high }
                        contextParts.append("\nOverdue: \(overdue.count), Critical/High: \(critical.count)")

                        // Top priority tasks for cross-reference
                        let dateFormatter = DateFormatter()
                        dateFormatter.dateFormat = "MMM d"
                        let topTasks = tasks.sorted { a, b in
                            let priorityWeight: [TaskItem.Priority: Int] = [.critical: 0, .high: 1, .medium: 2, .low: 3]
                            let aPri = a.priority.map { priorityWeight[$0] ?? 4 } ?? 4
                            let bPri = b.priority.map { priorityWeight[$0] ?? 4 } ?? 4
                            if aPri != bPri { return aPri < bPri }
                            return (a.dueDate ?? Date.distantFuture) < (b.dueDate ?? Date.distantFuture)
                        }.prefix(8)
                        contextParts.append("\nTop priority tasks:")
                        for task in topTasks {
                            let due = task.dueDate.map { dateFormatter.string(from: $0) } ?? "no deadline"
                            let overdueMark = task.isOverdue ? " [OVERDUE]" : ""
                            contextParts.append("- [\(task.priority?.rawValue ?? "None")] \(task.title) (due: \(due))\(overdueMark)")
                        }

                        // Recently completed tasks (separate query — active tasks exclude Done)
                        let recentlyCompleted = try await orchestrator.notionServicePublic.queryRecentlyCompletedTasks(days: 7)
                        contextParts.append("\nCompleted this week: \(recentlyCompleted.count)")
                        if !recentlyCompleted.isEmpty {
                            contextParts.append("Recently completed tasks:")
                            for task in recentlyCompleted.prefix(8) {
                                let pri = task.priority?.rawValue ?? "None"
                                contextParts.append("- [DONE] [\(pri)] \(task.title)")
                            }
                        }

                        contextParts.append("Open: \(tasks.count)")
                        contextParts.append("Stale (14+ days): \(stale.count)")
                    } catch {
                        contextParts.append("Tasks (detailed): unavailable")
                    }
                }

            case "messages_detailed":
                // Enriched messaging data: per-thread/group counts, top 5 by volume
                if let config = alfredService.orchestrator?.config {
                    do {
                        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
                        let reader = WhatsAppSource.reader(config: config)
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

                        contextParts.append("=== Messages (Detailed, 7 days) ===")
                        contextParts.append("Total inbound: \(totalIncoming), Total outbound: \(totalOutgoing)")
                        let ratio = totalOutgoing > 0 ? String(format: "%.1f", Double(totalIncoming) / Double(totalOutgoing)) : "∞"
                        contextParts.append("Inbound/outbound ratio: \(ratio):1")
                        contextParts.append("Active groups: \(groupStats.count), Active DMs: \(dmStats.count)")

                        let topGroups = groupStats.sorted { $0.total > $1.total }.prefix(5)
                        if !topGroups.isEmpty {
                            contextParts.append("\nTop groups by message volume:")
                            for g in topGroups {
                                contextParts.append("- \(g.name): \(g.total) msgs (\(g.incoming) in, \(g.outgoing) out)")
                            }
                        }

                        let topDMs = dmStats.sorted { $0.total > $1.total }.prefix(5)
                        if !topDMs.isEmpty {
                            contextParts.append("\nTop direct conversations:")
                            for d in topDMs {
                                contextParts.append("- \(d.name): \(d.incoming + d.outgoing) msgs (\(d.incoming) in, \(d.outgoing) out)")
                            }
                        }

                        reader.disconnect()
                    } catch {
                        contextParts.append("Messages (detailed): unavailable")
                    }
                }

            case "commitments_by_person":
                // Enriched commitment data: per-person stats, open commitments, recent messages
                let counterpartyStats = TaskLifecycleTracker.shared.getStatsByCounterparty()
                contextParts.append("=== Commitments by Person ===")

                if !counterpartyStats.isEmpty {
                    contextParts.append("Commitment history by person:")
                    for stat in counterpartyStats.prefix(8) {
                        contextParts.append("- \(stat.name): \(stat.totalTasks) total, \(stat.completedTasks) completed, \(Int(stat.overdueRate * 100))% overdue rate")
                    }
                }

                // Open commitments grouped by person
                if let orchestrator = alfredService.orchestrator {
                    do {
                        let tasks = try await orchestrator.notionServicePublic.queryActiveTasks(type: .commitment)
                        let byPerson = Dictionary(grouping: tasks) { $0.committedTo ?? $0.committedBy ?? "Unknown" }
                        let sorted = byPerson.sorted { $0.value.count > $1.value.count }

                        if !sorted.isEmpty {
                            let dateFormatter = DateFormatter()
                            dateFormatter.dateFormat = "MMM d"
                            contextParts.append("\nOpen commitments by person:")
                            for (person, personTasks) in sorted.prefix(6) {
                                let overdue = personTasks.filter { $0.isOverdue }.count
                                contextParts.append("- \(person): \(personTasks.count) open\(overdue > 0 ? ", \(overdue) overdue" : "")")
                                // Include actual commitment titles so the model doesn't have to guess
                                for task in personTasks.prefix(3) {
                                    let due = task.dueDate.map { dateFormatter.string(from: $0) } ?? "no deadline"
                                    let overdueMark = task.isOverdue ? " [OVERDUE]" : ""
                                    contextParts.append("  > \"\(task.title)\" (due: \(due))\(overdueMark)")
                                }
                            }
                        }
                    } catch {
                        // Not critical
                    }
                }

                // Overall stats
                let trackerStats = CommitmentScanTracker.shared.getStats()
                contextParts.append("\nOverall: \(trackerStats.openCommitments) open commitments across \(trackerStats.threadsTracked) threads")

                // Recent message interactions (so coaching doesn't nudge about recently-contacted people)
                if let config = alfredService.orchestrator?.config {
                    do {
                        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
                        let reader = WhatsAppSource.reader(config: config)
                        try reader.connect()
                        let threads = try reader.fetchThreads(since: sevenDaysAgo)

                        if !threads.isEmpty {
                            let formatter = RelativeDateTimeFormatter()
                            formatter.unitsStyle = .full
                            contextParts.append("\nRecent message interactions (last 7 days):")
                            for thread in threads.sorted(by: { $0.lastMessageDate > $1.lastMessageDate }).prefix(10) {
                                let name = thread.contactName ?? thread.contactIdentifier
                                let ago = formatter.localizedString(for: thread.lastMessageDate, relativeTo: Date())
                                // Include last message snippet for relationship context
                                let lastMsg = thread.messages.last
                                let snippet = lastMsg.map { msg in
                                    let text = String(msg.content.prefix(80))
                                    return " — \"\(text)\(msg.content.count > 80 ? "..." : "")\""
                                } ?? ""
                                contextParts.append("- \(name): last message \(ago)\(snippet)")
                            }
                        }
                    } catch {
                        // Non-fatal
                    }
                }

            default:
                break
            }

        return contextParts.joined(separator: "\n")
    }

    // MARK: - Streaming Card Generation

    /// Stream coaching cards one at a time as they complete.
    /// Each card is yielded via the onCard callback as soon as its LLM call finishes.
    /// Cache is updated after all cards complete.
    func streamCoachingCards(
        forceRefresh: Bool = false,
        onCard: @escaping (CoachingCard, SkillRunResult) -> Void
    ) async throws {
        // If cached and not forcing refresh, emit all cached cards immediately
        if !forceRefresh, let cached = cachedCards, let ts = cacheTimestamp,
           Date().timeIntervalSince(ts) < cacheTTL {
            for card in cached {
                let result = lastSkillResults[card.type] ?? SkillRunResult(
                    card: card, status: "cached", context: [], error: nil, generatedAt: ts
                )
                onCard(card, result)
            }
            return
        }

        // Clear per-source cache at start
        dataSourceCache.removeAll()

        let weekday = Calendar.current.component(.weekday, from: Date())
        let isWeekendOrFriday = weekday == 1 || weekday == 6 || weekday == 7

        let allSkills = SkillLoader.shared.getEnabledSkills()
        let installedSkills = allSkills.filter { $0.origin == .installed }
        let userSkills = allSkills.filter { $0.origin == .user }

        let installedToRun = installedSkills.filter { skill in
            skill.frequency == "daily" || (skill.frequency == "weekly" && isWeekendOrFriday)
        }
        let userDailySkills = userSkills.filter { $0.frequency == "daily" }
        let userWeeklySkills = userSkills.filter { $0.frequency == "weekly" }

        var userSkillsToRun = Array(userDailySkills.prefix(5))
        if isWeekendOrFriday {
            let remaining = 5 - userSkillsToRun.count
            if remaining > 0 {
                userSkillsToRun.append(contentsOf: userWeeklySkills.prefix(remaining))
            }
        }

        let skillsToRun = installedToRun + userSkillsToRun

        // Pre-fetch shared data sources CONCURRENTLY before card generation
        // This prevents redundant API calls when multiple skills need the same data
        let allDataSources = Array(Set(skillsToRun.flatMap { $0.dataSources }))
        await withTaskGroup(of: (String, String).self) { prefetchGroup in
            for source in allDataSources {
                prefetchGroup.addTask {
                    let data = await self.fetchSingleDataSource(source)
                    return (source, data)
                }
            }
            for await (source, data) in prefetchGroup {
                dataSourceCache[source] = (data: data, timestamp: Date())
            }
        }

        // Run all skills concurrently, streaming each card as it completes
        // Dictionary mutations happen serially in the for-await loop (not inside TaskGroup tasks)
        var allCards: [(Int, CoachingCard)] = []

        await withTaskGroup(of: (Int, SkillCardOutput).self) { group in
            for (index, skill) in skillsToRun.enumerated() {
                group.addTask {
                    let output = await self.generateSkillCard(skill)
                    return (index, output)
                }
            }

            for await (index, output) in group {
                // Apply side effects serially (safe — only one iteration at a time)
                applySkillOutput(output)
                if let card = output.card {
                    allCards.append((index, card))
                    onCard(card, output.result)
                }
            }
        }

        // Update cache with all completed cards (sorted by original order)
        let sortedCards = allCards.sorted { $0.0 < $1.0 }.map { $0.1 }
        cachedCards = sortedCards
        cacheTimestamp = Date()
        lastGeneratedAt = Date()
    }

    // MARK: - Disk Cache Restore

    /// Restore cards from HTTP disk cache into in-memory cache (survives app restarts).
    func restoreFromDiskCache(_ cards: [CoachingCard]) {
        cachedCards = cards
        cacheTimestamp = Date()
    }

    // MARK: - Single Skill Refresh (for QA/Preview)

    /// Refresh a single skill by ID, returning the run result for immediate use.
    /// Also updates cachedCards in-place if a card for this skill already exists.
    func refreshSingleSkill(id: String) async -> SkillRunResult? {
        guard let skill = SkillLoader.shared.getSkill(id: id) else {
            return SkillRunResult(card: nil, status: "error", context: [], error: "Skill not found: \(id)", generatedAt: Date())
        }

        let output = await generateSkillCard(skill)
        applySkillOutput(output)

        // Update cached cards in-place (replace matching card by type, or append)
        if let card = output.card {
            if var cached = cachedCards {
                if let idx = cached.firstIndex(where: { $0.type == id }) {
                    cached[idx] = card
                } else {
                    cached.append(card)
                }
                cachedCards = cached
            }
        }

        return lastSkillResults[id]
    }

    // MARK: - v2 Pipeline Helpers

    /// Build a DataContext for lens execution by pre-fetching all data sources that lenses need.
    /// Reuses the existing data source cache to avoid redundant API calls.
    private func buildLensDataContext() async throws -> LensExecutionEngine.DataContext {
        let lenses = AnalysisLensLoader.shared.getEnabledLenses()
        let allSources = Array(Set(lenses.flatMap { $0.dataSources }))

        // Pre-fetch all needed data sources in parallel
        await withTaskGroup(of: (String, String).self) { group in
            for source in allSources {
                if dataSourceCache[source] == nil {
                    group.addTask {
                        let data = await self.fetchSingleDataSource(source)
                        return (source, data)
                    }
                }
            }
            for await (source, data) in group {
                dataSourceCache[source] = (data: data, timestamp: Date())
            }
        }

        // Map cached data into the DataContext struct
        var ctx = LensExecutionEngine.DataContext()
        ctx.tasks = dataSourceCache["tasks"]?.data ?? ""
        ctx.tasksDetailed = dataSourceCache["tasks_detailed"]?.data ?? ""
        ctx.calendar = dataSourceCache["calendar"]?.data ?? ""
        ctx.messages = dataSourceCache["messages"]?.data ?? ""
        ctx.messagesDetailed = dataSourceCache["messages_detailed"]?.data ?? ""
        ctx.commitments = dataSourceCache["commitments"]?.data ?? ""
        ctx.commitmentsByPerson = dataSourceCache["commitments_by_person"]?.data ?? ""
        ctx.coachingMemory = dataSourceCache["coaching_memory"]?.data ?? ""

        return ctx
    }
}
