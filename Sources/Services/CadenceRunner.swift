import Foundation

/// Dispatches cadence actions to the appropriate service methods.
/// Extracted from MenuBarController's per-cadence runner methods.
class CadenceRunner {
    private let alfredService: AlfredService?
    private let orchestrator: BriefingOrchestrator?
    private weak var menuBarController: MenuBarController?

    init(alfredService: AlfredService?, orchestrator: BriefingOrchestrator?, menuBarController: MenuBarController? = nil) {
        self.alfredService = alfredService
        self.orchestrator = orchestrator
        self.menuBarController = menuBarController
    }

    /// Run a cadence action, returning a summary string on success.
    func run(_ cadence: Cadence) async throws -> String {
        switch cadence.actionType {
        case .morningBriefing:
            return try await runMorningBriefing(cadence: cadence)
        case .attentionCheck:
            return try await runAttentionCheck(cadence: cadence)
        case .todoScan:
            return try await runTodoScan(cadence: cadence)
        case .commitmentScan:
            return try await runCommitmentScan(cadence: cadence)
        case .patternLearning:
            return try await runPatternLearning(cadence: cadence)
        case .groupAnalysis:
            return try await runGroupAnalysis(cadence: cadence)
        case .autoSummary:
            return try await runAutoSummary(cadence: cadence)
        case .weeklyReview:
            return try await runWeeklyReview(cadence: cadence)
        case .messageSummary:
            return try await runMessageSummary(cadence: cadence)
        case .playbookSync:
            return try await runPlaybookSync(cadence: cadence)
        case .coachingSync:
            return try await runCoachingSync(cadence: cadence)
        case .taskLifecycleScan:
            return try await runTaskLifecycleScan(cadence: cadence)
        }
    }

    // MARK: - Individual Runners

    private func runMorningBriefing(cadence: Cadence) async throws -> String {
        guard let orchestrator = orchestrator else {
            throw CadenceError.serviceUnavailable("BriefingOrchestrator")
        }
        let emailTo = cadence.emailOnSuccess ? loadEmailTo() : nil
        let today = Date()
        let briefing = try await orchestrator.generateBriefing(for: today, sendNotifications: true, toAddress: emailTo)

        // Pre-generate coaching cards and persist to disk
        await preGenerateCoachingCards()

        // Pre-generate coaching opener and persist to disk
        await preGenerateCoachingOpener(briefing: briefing)

        return "Morning briefing generated with \(briefing.actionItems.count) action items"
    }

    /// Pre-generate coaching cards during the morning briefing cadence and persist to disk.
    private func preGenerateCoachingCards() async {
        guard let config = AppConfig.load(), let svc = alfredService else {
            print("[CadenceRunner] Cannot pre-generate coaching cards: config or service unavailable")
            return
        }
        do {
            print("[CadenceRunner] Pre-generating coaching cards for today...")
            let engine = CoachingEngine(config: config, alfredService: svc)
            let cards = try await engine.generateCoachingCards(forceRefresh: true)
            print("[CadenceRunner] Pre-generated \(cards.count) coaching card(s)")
        } catch {
            print("[CadenceRunner] Failed to pre-generate coaching cards: \(error)")
        }
    }

    /// Pre-generate the coaching opener and persist to disk.
    private func preGenerateCoachingOpener(briefing: DailyBriefing) async {
        guard let config = AppConfig.load() else {
            print("[CadenceRunner] Cannot pre-generate opener: config unavailable")
            return
        }

        let events = briefing.calendarBriefing.schedule.events.filter { !$0.isAllDay }
        let timedSorted = events.sorted { $0.startTime < $1.startTime }
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "h:mm a"

        var contextParts: [String] = []
        contextParts.append("Today: \(events.count) meetings")

        // Back-to-back detection
        var backToBackCount = 0
        if timedSorted.count > 1 {
            for i in 1..<timedSorted.count {
                if timedSorted[i].startTime.timeIntervalSince(timedSorted[i-1].endTime) < 900 {
                    backToBackCount += 1
                }
            }
        }
        if backToBackCount > 0 {
            let first = timedSorted.first.map { timeFmt.string(from: $0.startTime) } ?? "morning"
            let last = timedSorted.last.map { timeFmt.string(from: $0.endTime) } ?? "afternoon"
            contextParts.append("Back-to-back meetings: \(backToBackCount) (spanning \(first)–\(last))")
        }

        // Overdue tasks
        let overdueItems = briefing.actionItems.filter {
            if let due = $0.dueDate { return due < Date() } else { return false }
        }
        if !overdueItems.isEmpty {
            let topOverdue = overdueItems.prefix(3).map { $0.title }.joined(separator: ", ")
            contextParts.append("Overdue tasks: \(overdueItems.count) (\(topOverdue))")
        } else {
            contextParts.append("No overdue tasks")
        }

        let focusHours = Int(briefing.calendarBriefing.focusTime / 3600)
        let focusMins = Int((briefing.calendarBriefing.focusTime.truncatingRemainder(dividingBy: 3600)) / 60)
        contextParts.append("Focus time available: \(focusHours)h \(focusMins)m")

        let liveContext = contextParts.joined(separator: "\n")

        let prompt = """
        Generate a brief, sharp coaching observation about this person's day. This is the first thing they see when they open Alfred — make it count. 1-2 sentences max.

        Context (morning snapshot):
        \(liveContext)

        Rules:
        - Be a Day Lens — tell them what their calendar and task data reveals that they might not see themselves
        - Channel Matt Mochary: energy awareness, zone of genius vs. grinding, radical prioritization
        - Be warm but direct. No emojis. No generic greetings.
        - Just the observation text, nothing else.
        """

        do {
            print("[CadenceRunner] Pre-generating coaching opener...")
            let claudeService = ClaudeAIService(config: config.ai)
            let opener = try await claudeService.generateText(
                prompt: prompt,
                system: "You are Coach Alfred, a warm but direct executive coach. Generate a single sharp coaching observation.",
                maxTokens: 150
            )
            let trimmed = opener.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            saveOpenerToDisk(trimmed)
            print("[CadenceRunner] Pre-generated coaching opener saved to disk")
        } catch {
            print("[CadenceRunner] Failed to pre-generate coaching opener: \(error)")
        }
    }

    /// Write opener to ~/.alfred/coaching_opener_today.json
    private func saveOpenerToDisk(_ opener: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = "\(home)/.alfred/coaching_opener_today.json"
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let payload: [String: Any] = [
            "date": dateFormatter.string(from: Date()),
            "opener": opener,
            "generatedAt": ISO8601DateFormatter().string(from: Date())
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            print("[CadenceRunner] Failed to save opener to disk: \(error)")
        }
    }

    private func runAttentionCheck(cadence: Cadence) async throws -> String {
        guard let orchestrator = orchestrator else {
            throw CadenceError.serviceUnavailable("BriefingOrchestrator")
        }
        let emailTo = cadence.emailOnSuccess ? loadEmailTo() : nil
        let report = try await orchestrator.generateAttentionDefenseAlert(sendNotifications: true, toAddress: emailTo)
        return "Attention check: \(report.criticalTasks.count) critical tasks, \(report.recommendations.count) recommendations"
    }

    private func runTodoScan(cadence: Cadence) async throws -> String {
        guard let orchestrator = orchestrator else {
            throw CadenceError.serviceUnavailable("BriefingOrchestrator")
        }
        let lookbackDays = cadence.params["lookback_days"]?.intValue ?? 7
        let result = try await orchestrator.processWhatsAppTodos(lookbackDays: lookbackDays)
        return "Todo scan: found \(result.todosFound), created \(result.todosCreated), dupes \(result.duplicatesSkipped)"
    }

    private func runCommitmentScan(cadence: Cadence) async throws -> String {
        guard let alfredService = alfredService else {
            throw CadenceError.serviceUnavailable("AlfredService")
        }
        let scanMode = cadence.params["scan_mode"]?.stringValue ?? "all"
        let result = try await alfredService.scanCommitments(contactName: nil, lookbackDays: 3, scanMode: scanMode)

        // Bidirectional sync: check Notion for manually-closed commitments
        let synced = (try? await alfredService.syncCommitmentsFromNotion()) ?? 0

        // Clean up orphaned data
        let cleanup = CommitmentScanTracker.shared.cleanupOrphanedData()

        var summary = "Commitment scan: \(result.totalFound) found, \(result.saved) saved"
        if synced > 0 { summary += ", \(synced) synced from Notion" }
        if cleanup.orphanedClosures > 0 { summary += ", \(cleanup.orphanedClosures) orphans cleaned" }
        return summary
    }

    private func runPatternLearning(cadence: Cadence) async throws -> String {
        guard let config = AppConfig.load() else {
            throw CadenceError.serviceUnavailable("AppConfig")
        }

        // 1. Compute v2 learned patterns (includes v1 pattern computation)
        await WorkflowLearningService.shared.computeLearnedPatterns(config: config)

        // 2. Generate and email learning digest
        if let digest = WorkflowLearningService.shared.generateLearningDigest() {
            let notifService = NotificationService(config: config.notifications)
            try await notifService.sendLearningDigest(subject: digest.subject, body: digest.body)
        }

        // 3. Sync patterns to Notion Playbook
        try await PlaybookService.shared.syncToNotion()

        // 4. Sync coaching context to Notion
        try await CoachingNotionSyncService.shared.syncToNotion(force: true)

        // 5. Sync "What Alfred Knows" memory page to Notion
        try await MemoryNotionSyncService.shared.syncToNotion(force: true)

        let stats = WorkflowLearningService.shared.getLearningV2Stats()
        let activePatterns = stats["activePatterns"] as? Int ?? 0
        let totalEvents = stats["totalEvents"] as? Int ?? 0
        let pendingReviews = stats["pendingReviews"] as? Int ?? 0

        return "Pattern learning complete: \(activePatterns) active patterns from \(totalEvents) events, \(pendingReviews) pending reviews, playbook & coaching & memory synced"
    }

    private func runGroupAnalysis(cadence: Cadence) async throws -> String {
        guard let config = AppConfig.load() else {
            throw CadenceError.serviceUnavailable("AppConfig")
        }

        // 1. Fetch all WhatsApp threads from the last 7 days
        let whatsappReader = WhatsAppReader(dbPath: config.messaging.whatsapp.dbPath)
        try whatsappReader.connect()
        let since = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        let threads = try whatsappReader.fetchThreads(since: since)
        whatsappReader.disconnect()

        // 2. Filter for groups (JID contains @g.us) and sort by message count
        let groupThreads = threads
            .filter { $0.contactIdentifier.contains("@g.us") }
            .sorted { $0.messages.count > $1.messages.count }

        // 3. Take top groups with >= 20 messages/week
        let busyGroups = groupThreads.filter { $0.messages.count >= 20 }

        // 4. Get existing auto-summary groups from config
        let existingAutoGroups = config.cadence?.autoSummaryGroups ?? []

        // 5. Filter out groups already approved for auto-summary
        let suggestions = busyGroups
            .filter { thread in
                let name = thread.contactName ?? thread.contactIdentifier
                return !existingAutoGroups.contains(where: { $0.lowercased() == name.lowercased() })
            }
            .prefix(10)
            .map { thread -> [String: Any] in
                [
                    "name": thread.contactName ?? thread.contactIdentifier,
                    "messageCount": thread.messages.count,
                    "contactId": thread.contactIdentifier
                ]
            }

        // 6. Save suggestions to ~/.alfred/group_suggestions.json
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let suggestionsPath = "\(homeDir)/.alfred/group_suggestions.json"
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let todayDate = dateFormatter.string(from: Date())

        let suggestionsData: [String: Any] = [
            "generated_at": ISO8601DateFormatter().string(from: Date()),
            "week_analyzed": todayDate,
            "suggestions": suggestions,
            "total_groups_scanned": groupThreads.count,
            "busy_groups_found": busyGroups.count
        ]
        if let jsonData = try? JSONSerialization.data(withJSONObject: suggestionsData, options: [.prettyPrinted, .sortedKeys]) {
            try jsonData.write(to: URL(fileURLWithPath: suggestionsPath))
        }

        return "Group analysis: \(groupThreads.count) groups scanned, \(busyGroups.count) busy, \(suggestions.count) new suggestions"
    }

    private func runAutoSummary(cadence: Cadence) async throws -> String {
        guard let alfredService = alfredService else {
            throw CadenceError.serviceUnavailable("AlfredService")
        }
        let groups = cadence.params["groups"]?.stringArrayValue ?? []
        if groups.isEmpty {
            return "Auto summary: no groups configured"
        }

        var successCount = 0
        for groupName in groups {
            do {
                let result = try await alfredService.getMessagesSummaryForContact(
                    contact: groupName,
                    platform: "whatsapp",
                    timeframe: "24h"
                )
                if !result.summary.isEmpty {
                    if let config = AppConfig.load() {
                        let notifService = NotificationService(config: config.notifications)
                        let fontBody = "font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif;"
                        let fontDisplay = "font-family: 'Playfair Display', Georgia, 'Times New Roman', serif;"
                        var bodyHtml = NotificationService.emailHead()
                        bodyHtml += "<div style=\"\(fontDisplay) font-size: 22px; font-weight: 400; color: #1b2a4a; margin-bottom: 12px;\">\(groupName) Daily Summary</div>"
                        bodyHtml += "<div style=\"\(fontBody) font-size: 14px; line-height: 1.65; color: #1b2a4a; background-color: #f8f7f4; border-radius: 6px; border: 1px solid #e4e2dc; padding: 14px 16px;\">\(result.summary.replacingOccurrences(of: "\n\n", with: "<br><br>"))</div>"
                        if !result.keyPoints.isEmpty {
                            bodyHtml += "<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" style=\"margin-top: 20px; margin-bottom: 10px;\"><tr><td style=\"\(fontBody) font-size: 11px; font-weight: 600; color: #5c6370; text-transform: uppercase; letter-spacing: 0.06em; padding-right: 12px; white-space: nowrap;\">Key Points</td><td style=\"width: 100%;\"><div style=\"height: 1px; background-color: #e4e2dc;\"></div></td></tr></table>"
                            for point in result.keyPoints {
                                bodyHtml += "<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" style=\"margin-bottom: 6px;\"><tr><td style=\"background-color: #e4eef4; border-radius: 6px; padding: 10px 14px;\"><div style=\"\(fontBody) font-size: 13px; line-height: 1.5; color: #3d6888;\">• \(point)</div></td></tr></table>"
                            }
                        }
                        bodyHtml += NotificationService.emailFoot()
                        try await notifService.sendLearningDigest(
                            subject: "Coach Alfred: \(groupName) Daily Summary",
                            body: bodyHtml
                        )
                    }
                }
                successCount += 1
            } catch {
                // Log but continue — don't fail the whole cadence for one group
                print("⚠️ Auto-summary failed for \(groupName): \(error)")
            }
        }

        return "Auto-summaries: \(successCount)/\(groups.count) sent"
    }

    private func runWeeklyReview(cadence: Cadence) async throws -> String {
        guard let alfredService = alfredService else {
            throw CadenceError.serviceUnavailable("AlfredService")
        }
        guard let config = AppConfig.load() else {
            throw CadenceError.serviceUnavailable("AppConfig")
        }

        var contextParts: [String] = []
        var metrics: [String: Any] = [:]
        let calendar = Calendar.current
        let today = Date()

        // Task metrics
        if let orchestrator = orchestrator {
            let allTasks = try await orchestrator.notionServicePublic.queryActiveTasks()
            let sevenDaysAgoTasks = calendar.date(byAdding: .day, value: -7, to: today)!
            let completed = allTasks.filter { $0.status == .done }
            let completedThisWeek = completed.filter { $0.lastUpdated >= sevenDaysAgoTasks }
            let open = allTasks.filter { $0.status != .done }
            let overdue = open.filter { $0.isOverdue }
            let fourteenDaysAgo = calendar.date(byAdding: .day, value: -14, to: today)!
            let stale = open.filter { $0.status == .notStarted && $0.createdDate < fourteenDaysAgo }

            metrics["tasksCompleted"] = completedThisWeek.count
            metrics["tasksOpen"] = open.count
            metrics["tasksOverdue"] = overdue.count

            contextParts.append("TASK SUMMARY:")
            contextParts.append("- Completed this week: \(completedThisWeek.count)")
            contextParts.append("- Open: \(open.count)")
            contextParts.append("- Overdue: \(overdue.count)")
            contextParts.append("- Stale (14+ days, not started): \(stale.count)")

            if !completedThisWeek.isEmpty {
                contextParts.append("\nCOMPLETED THIS WEEK:")
                for task in completedThisWeek.prefix(15) {
                    contextParts.append("- \(task.title) [\(task.priority?.rawValue ?? "none")]")
                }
            }

            if !overdue.isEmpty {
                contextParts.append("\nOVERDUE:")
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "MMM d"
                for task in overdue.prefix(8) {
                    let daysOverdue = task.dueDate.map { calendar.dateComponents([.day], from: $0, to: today).day ?? 0 } ?? 0
                    contextParts.append("- \(task.title) (\(daysOverdue) days overdue)")
                }
            }

            if !stale.isEmpty {
                contextParts.append("\nSTALE / AVOIDED:")
                for task in stale.prefix(5) {
                    let age = calendar.dateComponents([.day], from: task.createdDate, to: today).day ?? 0
                    contextParts.append("- \(task.title) (untouched \(age) days)")
                }
            }
        }

        // Commitment stats
        let commitStats = CommitmentScanTracker.shared.getStats()
        metrics["commitmentsOpen"] = commitStats.openCommitments
        metrics["commitmentsClosed"] = commitStats.closedCount
        contextParts.append("\nCOMMITMENTS: \(commitStats.openCommitments) open, \(commitStats.closedCount) closed")

        let counterpartyStats = TaskLifecycleTracker.shared.getStatsByCounterparty()
        if !counterpartyStats.isEmpty {
            contextParts.append("\nRELATIONSHIP HEALTH:")
            for stat in counterpartyStats.prefix(8) {
                contextParts.append("- \(stat.name): \(stat.completedTasks)/\(stat.totalTasks) done, \(Int(stat.overdueRate * 100))% overdue")
            }
        }

        // Lifecycle stats
        let lifecycleStats = TaskLifecycleTracker.shared.getStats()
        let completionRate = Int(lifecycleStats.completionRate * 100)
        metrics["completionRate"] = completionRate
        contextParts.append("\nOVERALL: \(completionRate)% completion rate, \(Int(lifecycleStats.overdueRate * 100))% overdue rate")

        // Calendar meetings this week
        if let orchestrator = orchestrator {
            var weeklyMeetingCount = 0
            for dayOffset in (-6...0) {
                if let dayDate = calendar.date(byAdding: .day, value: dayOffset, to: today) {
                    do {
                        let schedule = try await orchestrator.calendarServicePublic.fetchEventsFromAllCalendars(for: dayDate, userSettings: config.user)
                        weeklyMeetingCount += schedule.events.count
                    } catch { }
                }
            }
            metrics["meetingsThisWeek"] = weeklyMeetingCount
            contextParts.append("\nMEETINGS: \(weeklyMeetingCount) events this week")
        }

        // Messaging velocity
        do {
            let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: today)!
            let reader = WhatsAppReader(dbPath: config.messaging.whatsapp.dbPath)
            try reader.connect()
            let threads = try reader.fetchThreads(since: sevenDaysAgo)
            let totalIn = threads.flatMap { $0.messages }.filter { $0.direction == .incoming }.count
            let totalOut = threads.flatMap { $0.messages }.filter { $0.direction == .outgoing }.count
            let ratio = totalOut > 0 ? String(format: "%.1f", Double(totalIn) / Double(totalOut)) : "∞"
            metrics["messagesInbound"] = totalIn
            metrics["messagesOutbound"] = totalOut
            contextParts.append("\nMESSAGING: \(totalIn) inbound, \(totalOut) outbound (ratio: \(ratio):1)")
            reader.disconnect()
        } catch { }

        // Recent coaching themes
        let sessions = CoachingMemoryService.shared.getRecentSessions(limit: 5)
        if !sessions.isEmpty {
            contextParts.append("\nRECENT COACHING THEMES:")
            for session in sessions {
                let firstLine = session.components(separatedBy: "\n").first ?? session
                contextParts.append("- \(String(firstLine.prefix(150)))")
            }
        }

        // Generate narrative via Claude
        let claudeService = ClaudeAIService(config: config.ai)
        let prompt = """
        You are Coach Alfred writing a comprehensive weekly reflection email. This is a Sunday morning review — the founder's chance to step back and see the week clearly before planning the next one.

        Context:
        \(contextParts.joined(separator: "\n"))

        Write a weekly reflection covering these dimensions:

        ## WINS
        What was accomplished this week? Name specific completed tasks. Acknowledge real progress — even small wins matter.

        ## ACCOUNTABILITY
        What was supposed to happen but didn't? Name specific overdue tasks. Don't be harsh, but be honest. Frame as curiosity, not judgment.

        ## PATTERNS
        Based on the data, what patterns are emerging? Are they operating in their Zone of Genius or grinding? Which relationships need investment? What keeps getting avoided? Reference messaging velocity if relevant.

        ## THIS WEEK
        ONE clear priority for the coming week. Be specific — name the task, the person, or the decision. End with a motivating challenge.

        Style:
        - Write in second person ("You completed...", "Your overdue rate...")
        - Be direct and warm. Like a friend who remembers everything.
        - Each section: 2-3 sentences, with specific names and numbers
        - Total: ~300 words
        - No emojis. Use ## headers for sections. Plain prose.

        Respond with ONLY the review text.
        """

        let reviewText = try await claudeService.generateText(
            prompt: prompt,
            maxTokens: 500
        )

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let todayDate = dateFormatter.string(from: today)

        // Format as HTML email using inline styles (email-safe)
        let fontBody = "font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif;"
        let fontDisplay = "font-family: 'Playfair Display', Georgia, 'Times New Roman', serif;"

        let sectionStyle = "\(fontBody) font-size: 11px; font-weight: 600; color: #5c6370; text-transform: uppercase; letter-spacing: 0.06em;"
        let formattedBody = reviewText.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "## WINS", with: "</div><div style=\"\(sectionStyle) margin-top: 24px; padding-bottom: 6px; border-bottom: 1px solid #e4e2dc;\">🏆 Wins</div><div style=\"\(fontBody) font-size: 14px; line-height: 1.65; color: #1b2a4a; margin-top: 8px;\">")
            .replacingOccurrences(of: "## ACCOUNTABILITY", with: "</div><div style=\"\(sectionStyle) margin-top: 24px; padding-bottom: 6px; border-bottom: 1px solid #e4e2dc;\">📋 Accountability</div><div style=\"\(fontBody) font-size: 14px; line-height: 1.65; color: #1b2a4a; margin-top: 8px;\">")
            .replacingOccurrences(of: "## PATTERNS", with: "</div><div style=\"\(sectionStyle) margin-top: 24px; padding-bottom: 6px; border-bottom: 1px solid #e4e2dc;\">🔍 Patterns</div><div style=\"\(fontBody) font-size: 14px; line-height: 1.65; color: #1b2a4a; margin-top: 8px;\">")
            .replacingOccurrences(of: "## THIS WEEK", with: "</div><div style=\"\(sectionStyle) margin-top: 24px; padding-bottom: 6px; border-bottom: 1px solid #e4e2dc;\">🎯 This Week</div><div style=\"\(fontBody) font-size: 14px; line-height: 1.65; color: #1b2a4a; margin-top: 8px;\">")
            .replacingOccurrences(of: "\n\n", with: "<br><br>")

        let htmlBody = NotificationService.emailHead()
        + "<div style=\"\(fontDisplay) font-size: 22px; font-weight: 400; color: #1b2a4a; margin-bottom: 4px;\">Weekly Reflection</div>"
        + "<div style=\"\(fontBody) font-size: 12px; color: #8890a0; margin-bottom: 8px;\">\(todayDate) · from Coach Alfred</div>"
        + "<div style=\"\(fontBody) font-size: 14px; line-height: 1.65; color: #1b2a4a;\">\(formattedBody)</div>"
        + NotificationService.emailFoot()

        let notifService = NotificationService(config: config.notifications)
        try await notifService.sendLearningDigest(
            subject: "Coach Alfred: Weekly Reflection — \(todayDate)",
            body: htmlBody
        )

        // Save to Notion Reflections database
        if let reflectionsDbId = config.notion.reflectionsDatabaseId, !reflectionsDbId.isEmpty {
            await saveReflectionToNotion(
                dbId: reflectionsDbId,
                apiKey: config.notion.apiKey,
                narrative: reviewText.trimmingCharacters(in: .whitespacesAndNewlines),
                metrics: metrics,
                date: today
            )
        }

        return "Weekly reflection complete: email sent, saved to Notion"
    }

    private func runMessageSummary(cadence: Cadence) async throws -> String {
        guard let alfredService = alfredService else {
            throw CadenceError.serviceUnavailable("AlfredService")
        }
        guard let contact = cadence.params["contact"]?.stringValue else {
            throw CadenceError.missingParameter("contact")
        }
        let platform = cadence.params["platform"]?.stringValue ?? "whatsapp"
        let timeframe = cadence.params["timeframe"]?.stringValue ?? "24h"

        let result = try await alfredService.getMessagesSummaryForContact(
            contact: contact,
            platform: platform,
            timeframe: timeframe
        )

        if cadence.emailOnSuccess && !result.summary.isEmpty {
            if let config = AppConfig.load() {
                let notifService = NotificationService(config: config.notifications)
                let fontBody = "font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif;"
                let fontDisplay = "font-family: 'Playfair Display', Georgia, 'Times New Roman', serif;"
                var bodyHtml = NotificationService.emailHead()
                bodyHtml += "<div style=\"\(fontDisplay) font-size: 22px; font-weight: 400; color: #1b2a4a; margin-bottom: 4px;\">\(contact) Summary</div>"
                bodyHtml += "<div style=\"\(fontBody) font-size: 12px; color: #8890a0; margin-bottom: 12px;\">Timeframe: \(timeframe)</div>"
                bodyHtml += "<div style=\"\(fontBody) font-size: 14px; line-height: 1.65; color: #1b2a4a; background-color: #f8f7f4; border-radius: 6px; border: 1px solid #e4e2dc; padding: 14px 16px;\">\(result.summary.replacingOccurrences(of: "\n\n", with: "<br><br>"))</div>"
                if !result.keyPoints.isEmpty {
                    bodyHtml += "<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" style=\"margin-top: 20px; margin-bottom: 10px;\"><tr><td style=\"\(fontBody) font-size: 11px; font-weight: 600; color: #5c6370; text-transform: uppercase; letter-spacing: 0.06em; padding-right: 12px; white-space: nowrap;\">Key Points</td><td style=\"width: 100%;\"><div style=\"height: 1px; background-color: #e4e2dc;\"></div></td></tr></table>"
                    for point in result.keyPoints {
                        bodyHtml += "<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" style=\"margin-bottom: 6px;\"><tr><td style=\"background-color: #e4eef4; border-radius: 6px; padding: 10px 14px;\"><div style=\"\(fontBody) font-size: 13px; line-height: 1.5; color: #3d6888;\">• \(point)</div></td></tr></table>"
                    }
                }
                bodyHtml += NotificationService.emailFoot()
                try await notifService.sendLearningDigest(
                    subject: "Coach Alfred: \(contact) Summary (\(timeframe))",
                    body: bodyHtml
                )
            }
        }

        return "Message summary for \(contact): \(result.messageCount) messages analyzed"
    }

    private func runPlaybookSync(cadence: Cadence) async throws -> String {
        try await PlaybookService.shared.syncToNotion()
        return "Playbook synced to Notion"
    }

    private func runCoachingSync(cadence: Cadence) async throws -> String {
        try await CoachingNotionSyncService.shared.syncToNotion(force: true)
        return "Coaching context synced to Notion"
    }

    private func runTaskLifecycleScan(cadence: Cadence) async throws -> String {
        guard let orchestrator = orchestrator else {
            throw CadenceError.serviceUnavailable("BriefingOrchestrator")
        }
        let result = try await TaskLifecycleTracker.shared.scan(notionService: orchestrator.notionServicePublic)
        return "Task lifecycle scan: \(result.tasksScanned) tasks scanned, \(result.changesDetected) changes detected"
    }

    // MARK: - Helpers

    private func loadEmailTo() -> String? {
        let config = AppConfig.load()
        let emailTo = config?.scheduled?.emailTo
        return (emailTo?.isEmpty == false) ? emailTo : nil
    }

    private func saveReflectionToNotion(dbId: String, apiKey: String, narrative: String, metrics: [String: Any], date: Date) async {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateStr = dateFormatter.string(from: date)

        let weekFormatter = DateFormatter()
        weekFormatter.dateFormat = "MMM d, yyyy"
        let weekLabel = "Week of \(weekFormatter.string(from: date))"

        let overdue = (metrics["tasksOverdue"] as? Int) ?? 0
        let completedThisWeek = (metrics["tasksCompleted"] as? Int) ?? 0
        let totalActive = ((metrics["tasksOpen"] as? Int) ?? 0) + completedThisWeek
        let weeklyCompletionRate = totalActive > 0 ? Int((Double(completedThisWeek) / Double(totalActive)) * 100) : 0

        let mood: String
        if weeklyCompletionRate >= 70 && overdue <= 3 { mood = "Strong" }
        else if weeklyCompletionRate >= 40 && overdue <= 8 { mood = "Steady" }
        else if overdue > 15 || weeklyCompletionRate < 20 { mood = "Overwhelmed" }
        else { mood = "Struggling" }

        let inbound = (metrics["messagesInbound"] as? Int) ?? 0
        let outbound = (metrics["messagesOutbound"] as? Int) ?? 0
        let ratioStr = outbound > 0 ? String(format: "%.1f:1", Double(inbound) / Double(outbound)) : "N/A"

        // Dedup: check if a reflection for this week already exists, and update it instead of creating a duplicate
        let existingPageId = await findExistingReflection(dbId: dbId, apiKey: apiKey, weekLabel: weekLabel)

        let properties: [String: Any] = [
            "Week": ["title": [["text": ["content": weekLabel]]]],
            "Date": ["date": ["start": dateStr]],
            "Tasks Completed": ["number": completedThisWeek],
            "Tasks Overdue": ["number": overdue],
            "Completion Rate": ["number": Double(weeklyCompletionRate) / 100.0],
            "Meetings": ["number": (metrics["meetingsThisWeek"] as? Int) ?? 0],
            "Open Commitments": ["number": (metrics["commitmentsOpen"] as? Int) ?? 0],
            "In/Out Ratio": ["rich_text": [["text": ["content": ratioStr]]]],
            "Mood": ["select": ["name": mood]]
        ]

        let contentBlocks: [[String: Any]] = narrative.components(separatedBy: "\n").prefix(90).map { line -> [String: Any] in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") {
                return [
                    "object": "block",
                    "type": "heading_2",
                    "heading_2": ["rich_text": [["type": "text", "text": ["content": String(trimmed.dropFirst(3))]]]]
                ]
            } else if trimmed.isEmpty {
                return [
                    "object": "block",
                    "type": "paragraph",
                    "paragraph": ["rich_text": [] as [[String: Any]]]
                ]
            } else {
                return [
                    "object": "block",
                    "type": "paragraph",
                    "paragraph": ["rich_text": [["type": "text", "text": ["content": trimmed]]]]
                ]
            }
        }

        if let pageId = existingPageId {
            // Update existing page properties
            await updateReflectionPage(pageId: pageId, apiKey: apiKey, properties: properties, contentBlocks: contentBlocks)
        } else {
            // Create new page
            await createReflectionPage(dbId: dbId, apiKey: apiKey, properties: properties, contentBlocks: contentBlocks)
        }
    }

    private func findExistingReflection(dbId: String, apiKey: String, weekLabel: String) async -> String? {
        let url = URL(string: "https://api.notion.com/v1/databases/\(dbId)/query")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let filter: [String: Any] = [
            "filter": [
                "property": "Week",
                "title": ["equals": weekLabel]
            ]
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: filter)
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let results = json["results"] as? [[String: Any]],
               let first = results.first,
               let id = first["id"] as? String {
                return id
            }
        } catch { }
        return nil
    }

    private func updateReflectionPage(pageId: String, apiKey: String, properties: [String: Any], contentBlocks: [[String: Any]]) async {
        // Update properties
        let url = URL(string: "https://api.notion.com/v1/pages/\(pageId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["properties": properties]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await URLSession.shared.data(for: request)

            // Delete existing content blocks and replace with new ones
            await replacePageContent(pageId: pageId, apiKey: apiKey, newBlocks: contentBlocks)

            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                print("  ✓ Weekly reflection updated in Notion (dedup)")
            } else {
                print("  ⚠️ Notion update failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
        } catch {
            print("  ⚠️ Notion update error: \(error)")
        }
    }

    private func replacePageContent(pageId: String, apiKey: String, newBlocks: [[String: Any]]) async {
        // First, get existing blocks
        let listUrl = URL(string: "https://api.notion.com/v1/blocks/\(pageId)/children?page_size=100")!
        var listRequest = URLRequest(url: listUrl)
        listRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        listRequest.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")

        do {
            let (data, _) = try await URLSession.shared.data(for: listRequest)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let results = json["results"] as? [[String: Any]] {
                // Delete each existing block
                for block in results {
                    if let blockId = block["id"] as? String {
                        let deleteUrl = URL(string: "https://api.notion.com/v1/blocks/\(blockId)")!
                        var deleteRequest = URLRequest(url: deleteUrl)
                        deleteRequest.httpMethod = "DELETE"
                        deleteRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                        deleteRequest.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
                        _ = try? await URLSession.shared.data(for: deleteRequest)
                    }
                }
            }

            // Append new blocks
            let appendUrl = URL(string: "https://api.notion.com/v1/blocks/\(pageId)/children")!
            var appendRequest = URLRequest(url: appendUrl)
            appendRequest.httpMethod = "PATCH"
            appendRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            appendRequest.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
            appendRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let appendBody: [String: Any] = ["children": newBlocks]
            appendRequest.httpBody = try JSONSerialization.data(withJSONObject: appendBody)
            _ = try await URLSession.shared.data(for: appendRequest)
        } catch {
            print("  ⚠️ Notion content replace error: \(error)")
        }
    }

    private func createReflectionPage(dbId: String, apiKey: String, properties: [String: Any], contentBlocks: [[String: Any]]) async {
        let url = URL(string: "https://api.notion.com/v1/pages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "parent": ["database_id": dbId],
            "properties": properties,
            "children": contentBlocks
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                print("  ✓ Weekly reflection saved to Notion")
            } else {
                print("  ⚠️ Notion save failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
        } catch {
            print("  ⚠️ Notion save error: \(error)")
        }
    }
}
