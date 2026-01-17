import Foundation

/// Service that analyzes how user's time and attention are allocated
class AttentionTracker {
    private let aiService: ClaudeAIService
    private let preferences: AttentionPreferences?
    private let preferencesPath = "Config/attention_preferences.json"

    init(aiService: ClaudeAIService) {
        self.aiService = aiService
        self.preferences = Self.loadPreferences()
    }

    // MARK: - Preferences Management

    static func loadPreferences() -> AttentionPreferences? {
        // Try multiple paths like AppConfig does
        let paths = [
            // 1. Current directory
            "Config/attention_preferences.json",
            // 2. User config directory
            (NSString(string: "~/.config/alfred/attention_preferences.json").expandingTildeInPath),
            // 3. Original project location
            (NSString(string: "~/Documents/Claude apps/Alfred/Config/attention_preferences.json").expandingTildeInPath)
        ]

        for configPath in paths {
            let expandedPath = (configPath as NSString).expandingTildeInPath
            let fileURL = URL(fileURLWithPath: expandedPath)

            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                continue
            }

            do {
                let data = try Data(contentsOf: fileURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let prefs = try decoder.decode(AttentionPreferences.self, from: data)
                return prefs
            } catch {
                print("⚠️  Failed to load attention preferences from \(fileURL.path): \(error)")
                continue
            }
        }

        print("ℹ️  No attention preferences found")
        print("💡 Run 'alfred attention init' to create preference file")
        return nil
    }

    // MARK: - Calendar Attention Analysis

    func analyzeCalendarAttention(
        events: [CalendarEvent],
        period: AttentionQuery.Period
    ) async throws -> AttentionReport.CalendarAttention {
        var breakdown: [MeetingCategory: AttentionReport.CalendarAttention.CategoryStats] = [:]
        var patterns: [String: (count: Int, time: TimeInterval, attendees: Int, external: Bool)] = [:]

        // Analyze each event
        for event in events {
            // Categorize meeting
            let category = await categorizeMeeting(event)

            // Update category stats
            let duration = event.duration
            if var stats = breakdown[category] {
                stats.timeSpent += duration
                stats.meetingCount += 1
                breakdown[category] = stats
            } else {
                breakdown[category] = AttentionReport.CalendarAttention.CategoryStats(
                    category: category,
                    timeSpent: duration,
                    meetingCount: 1,
                    percentage: 0,  // Will calculate after
                    averageMeetingDuration: duration
                )
            }

            // Track patterns
            let pattern = extractPattern(from: event)
            if var existing = patterns[pattern] {
                existing.count += 1
                existing.time += duration
                existing.attendees = max(existing.attendees, event.attendees.count)
                patterns[pattern] = existing
            } else {
                patterns[pattern] = (
                    count: 1,
                    time: duration,
                    attendees: event.attendees.count,
                    external: event.hasExternalAttendees
                )
            }
        }

        // Calculate totals and percentages
        let totalTime = events.reduce(0.0) { $0 + $1.duration }
        let meetingCount = events.count

        for category in breakdown.keys {
            var stats = breakdown[category]!
            stats.percentage = totalTime > 0 ? (stats.timeSpent / totalTime) * 100 : 0
            stats.averageMeetingDuration = stats.timeSpent / Double(stats.meetingCount)
            breakdown[category] = stats
        }

        // Identify top time consumers
        let topPatterns = patterns
            .sorted { $0.value.time > $1.value.time }
            .prefix(10)
            .map { pattern, data in
                AttentionReport.CalendarAttention.MeetingPattern(
                    pattern: pattern,
                    occurrences: data.count,
                    totalTime: data.time,
                    averageAttendees: data.attendees,
                    isExternal: data.external
                )
            }

        // Calculate utilization score and waste
        let (utilizationScore, wastedTime) = calculateCalendarUtilization(
            breakdown: breakdown,
            totalTime: totalTime
        )

        return AttentionReport.CalendarAttention(
            totalMeetingTime: totalTime,
            meetingCount: meetingCount,
            breakdown: breakdown,
            topTimeConsumers: topPatterns,
            utilizationScore: utilizationScore,
            wastedTimeEstimate: wastedTime
        )
    }

    // MARK: - Messaging Attention Analysis

    func analyzeMessagingAttention(
        summaries: [MessageSummary],
        period: AttentionQuery.Period
    ) async throws -> AttentionReport.MessagingAttention {
        var breakdown: [MessageCategory: AttentionReport.MessagingAttention.CategoryStats] = [:]
        var threadPatterns: [String: (messages: Int, platform: String, isGroup: Bool)] = [:]

        // Analyze each thread
        for summary in summaries {
            let category = categorizeMessage(summary)
            let messageCount = summary.thread.messages.count

            // Update category stats
            if var stats = breakdown[category] {
                stats.threadCount += 1
                stats.messageCount += messageCount
                stats.needsResponseCount += summary.thread.needsResponse ? 1 : 0
                breakdown[category] = stats
            } else {
                breakdown[category] = AttentionReport.MessagingAttention.CategoryStats(
                    category: category,
                    threadCount: 1,
                    messageCount: messageCount,
                    percentage: 0,  // Calculate after
                    needsResponseCount: summary.thread.needsResponse ? 1 : 0
                )
            }

            // Track thread patterns
            let contact = summary.thread.contactName ?? "Unknown"
            if var existing = threadPatterns[contact] {
                existing.messages += messageCount
                threadPatterns[contact] = existing
            } else {
                // Heuristic: if contactIdentifier contains comma or "group", it's likely a group
                let isGroup = summary.thread.contactIdentifier.contains(",") ||
                             summary.thread.contactIdentifier.localizedCaseInsensitiveContains("group")
                threadPatterns[contact] = (
                    messages: messageCount,
                    platform: summary.thread.platform.rawValue,
                    isGroup: isGroup
                )
            }
        }

        // Calculate percentages
        let totalThreads = summaries.count
        for category in breakdown.keys {
            var stats = breakdown[category]!
            stats.percentage = totalThreads > 0 ? (Double(stats.threadCount) / Double(totalThreads)) * 100 : 0
            breakdown[category] = stats
        }

        // Calculate average response time
        let responseTime = calculateAverageResponseTime(summaries)

        // Identify top thread consumers
        let daysInPeriod = period.end.timeIntervalSince(period.start) / 86400
        let topThreads = threadPatterns
            .sorted { $0.value.messages > $1.value.messages }
            .prefix(10)
            .map { contact, data in
                AttentionReport.MessagingAttention.ThreadPattern(
                    contact: contact,
                    messageCount: data.messages,
                    platform: data.platform,
                    isGroup: data.isGroup,
                    averageMessagesPerDay: Double(data.messages) / max(daysInPeriod, 1)
                )
            }

        // Calculate messaging utilization score
        let utilizationScore = calculateMessagingUtilization(breakdown: breakdown)

        return AttentionReport.MessagingAttention(
            totalThreads: totalThreads,
            responsesGiven: summaries.filter { !$0.thread.needsResponse }.count,
            averageResponseTime: responseTime,
            breakdown: breakdown,
            topTimeConsumers: topThreads,
            utilizationScore: utilizationScore
        )
    }

    // MARK: - Overall Attention Analysis

    func generateAttentionReport(
        query: AttentionQuery,
        events: [CalendarEvent],
        messages: [MessageSummary]
    ) async throws -> AttentionReport {
        // Analyze calendar if requested
        let calendarAttention: AttentionReport.CalendarAttention
        if query.includeCalendar {
            calendarAttention = try await analyzeCalendarAttention(events: events, period: query.period)
        } else {
            calendarAttention = AttentionReport.CalendarAttention(
                totalMeetingTime: 0,
                meetingCount: 0,
                breakdown: [:],
                topTimeConsumers: [],
                utilizationScore: 0,
                wastedTimeEstimate: 0
            )
        }

        // Analyze messaging if requested
        let messagingAttention: AttentionReport.MessagingAttention
        if query.includeMessaging {
            messagingAttention = try await analyzeMessagingAttention(summaries: messages, period: query.period)
        } else {
            messagingAttention = AttentionReport.MessagingAttention(
                totalThreads: 0,
                responsesGiven: 0,
                averageResponseTime: nil,
                breakdown: [:],
                topTimeConsumers: [],
                utilizationScore: 0
            )
        }

        // Calculate overall scores
        let overall = calculateOverallAttention(
            calendar: calendarAttention,
            messaging: messagingAttention,
            preferences: preferences
        )

        // Generate recommendations
        let recommendations = try await generateRecommendations(
            calendar: calendarAttention,
            messaging: messagingAttention,
            overall: overall
        )

        return AttentionReport(
            period: AttentionReport.TimePeriod(
                start: query.period.start,
                end: query.period.end,
                type: query.period.start > Date() ? .future : .past
            ),
            calendar: calendarAttention,
            messaging: messagingAttention,
            overall: overall,
            recommendations: recommendations,
            generatedAt: Date()
        )
    }

    // MARK: - Future Planning

    func generateAttentionPlan(
        request: AttentionPlanRequest,
        currentEvents: [CalendarEvent]
    ) async throws -> AttentionPlan {
        // Filter events for the requested period
        let relevantEvents = currentEvents.filter { event in
            event.startTime >= request.period.start && event.startTime <= request.period.end
        }

        // Analyze current commitments
        let commitments = relevantEvents.map { event -> AttentionPlan.Commitment in
            let category = MeetingCategory.uncategorized  // Would use AI categorization
            return AttentionPlan.Commitment(
                title: event.title,
                date: event.startTime,
                duration: event.duration,
                category: category,
                canReschedule: !event.hasExternalAttendees,  // Heuristic
                priority: 3  // Would use AI to determine
            )
        }

        // Generate recommendations using AI
        let recommendations = try await generatePlanningRecommendations(
            request: request,
            commitments: commitments
        )

        // Project attention scores
        let projected = projectAttentionScores(
            request: request,
            commitments: commitments,
            recommendations: recommendations
        )

        // Identify conflicts
        let conflicts = identifyConflicts(
            request: request,
            commitments: commitments
        )

        return AttentionPlan(
            request: request,
            currentCommitments: commitments,
            recommendations: recommendations,
            projectedAttention: projected,
            conflicts: conflicts
        )
    }

    // MARK: - Private Helpers

    private func categorizeMeeting(_ event: CalendarEvent) async -> MeetingCategory {
        // Check for user overrides first
        if let prefs = preferences {
            for (pattern, category) in prefs.meetingPreferences.categoryOverrides {
                if event.title.localizedCaseInsensitiveContains(pattern) {
                    return category
                }
            }
        }

        // Use AI to categorize
        let prompt = """
        Categorize this meeting into one of these categories:
        - Strategic: High-value, long-term impact
        - Tactical: Important for execution
        - Collaborative: Team coordination
        - Informational: Status updates, FYIs
        - Ceremonial: Could be async
        - Waste: Low value

        Meeting: \(event.title)
        Duration: \(Int(event.duration / 60)) minutes
        Attendees: \(event.attendees.count)
        Is external: \(event.hasExternalAttendees)

        Respond with just the category name.
        """

        do {
            let response = try await aiService.generateText(prompt: prompt, maxTokens: 50)
            let cleaned = response.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

            if cleaned.contains("strategic") { return .strategic }
            if cleaned.contains("tactical") { return .tactical }
            if cleaned.contains("collaborative") { return .collaborative }
            if cleaned.contains("informational") { return .informational }
            if cleaned.contains("ceremonial") { return .ceremonial }
            if cleaned.contains("waste") { return .waste }
        } catch {
            print("⚠️  AI categorization failed: \(error)")
        }

        return .uncategorized
    }

    private func categorizeMessage(_ summary: MessageSummary) -> MessageCategory {
        switch summary.urgency {
        case .critical:
            return .urgent
        case .high:
            return .important
        case .medium:
            return .routine
        case .low:
            return .social
        }
    }

    private func extractPattern(from event: CalendarEvent) -> String {
        // Extract recurring pattern from title
        // Examples: "Weekly sync" -> "Weekly sync", "1:1 with John" -> "1:1 meetings"
        let title = event.title.lowercased()

        if title.contains("1:1") || title.contains("1-1") {
            return "1:1 meetings"
        }
        if title.contains("weekly") {
            return "Weekly \(title.replacingOccurrences(of: "weekly", with: "").trimmingCharacters(in: .whitespaces))"
        }
        if title.contains("standup") || title.contains("stand-up") {
            return "Team standups"
        }
        if title.contains("sync") {
            return "Sync meetings"
        }

        return event.title
    }

    private func calculateCalendarUtilization(
        breakdown: [MeetingCategory: AttentionReport.CalendarAttention.CategoryStats],
        totalTime: TimeInterval
    ) -> (score: Double, wastedTime: TimeInterval) {
        var wastedTime: TimeInterval = 0
        var valuableTime: TimeInterval = 0

        for (category, stats) in breakdown {
            switch category {
            case .strategic, .tactical:
                valuableTime += stats.timeSpent
            case .ceremonial, .waste:
                wastedTime += stats.timeSpent
            case .collaborative, .informational:
                valuableTime += stats.timeSpent * 0.5  // Partial value
                wastedTime += stats.timeSpent * 0.5
            case .uncategorized:
                // Assume 50% valuable
                valuableTime += stats.timeSpent * 0.5
            }
        }

        let score = totalTime > 0 ? (valuableTime / totalTime) * 100 : 0
        return (min(score, 100), wastedTime)
    }

    private func calculateMessagingUtilization(
        breakdown: [MessageCategory: AttentionReport.MessagingAttention.CategoryStats]
    ) -> Double {
        let totalThreads = breakdown.values.reduce(0) { $0 + $1.threadCount }
        var valuableThreads = 0

        for (category, stats) in breakdown {
            switch category {
            case .urgent, .important:
                valuableThreads += stats.threadCount
            case .routine:
                valuableThreads += stats.threadCount / 2
            case .social, .noise:
                break
            case .uncategorized:
                valuableThreads += stats.threadCount / 2
            }
        }

        return totalThreads > 0 ? (Double(valuableThreads) / Double(totalThreads)) * 100 : 0
    }

    private func calculateAverageResponseTime(_ summaries: [MessageSummary]) -> TimeInterval? {
        // Would calculate based on message timestamps
        // For now, return nil (not implemented)
        return nil
    }

    private func calculateOverallAttention(
        calendar: AttentionReport.CalendarAttention,
        messaging: AttentionReport.MessagingAttention,
        preferences: AttentionPreferences?
    ) -> AttentionReport.OverallAttention {
        // Calculate composite scores
        let focusScore = (calendar.utilizationScore + messaging.utilizationScore) / 2

        // Balance: how evenly time is distributed
        let balanceScore = calculateBalanceScore(calendar: calendar)

        // Efficiency: ratio of valuable time to total time
        let efficiencyScore = calendar.utilizationScore

        // Alignment with goals
        let alignmentScore = preferences != nil ? calculateGoalAlignment(calendar: calendar, preferences: preferences!) : 50.0

        let summary = """
        Focus: \(Int(focusScore))% | Balance: \(Int(balanceScore))% | Efficiency: \(Int(efficiencyScore))% | Goal Alignment: \(Int(alignmentScore))%
        """

        return AttentionReport.OverallAttention(
            focusScore: focusScore,
            balanceScore: balanceScore,
            efficiencyScore: efficiencyScore,
            alignmentWithGoals: alignmentScore,
            summary: summary
        )
    }

    private func calculateBalanceScore(calendar: AttentionReport.CalendarAttention) -> Double {
        // Check if time is balanced across categories or heavily skewed
        let stats = Array(calendar.breakdown.values)
        guard !stats.isEmpty else { return 100 }

        let percentages = stats.map { $0.percentage }
        let avgPercentage = percentages.reduce(0, +) / Double(percentages.count)
        let variance = percentages.map { pow($0 - avgPercentage, 2) }.reduce(0, +) / Double(percentages.count)

        // Lower variance = better balance
        // Scale to 0-100 (100 = perfectly balanced)
        let balanceScore = max(0, 100 - (variance / 10))
        return balanceScore
    }

    private func calculateGoalAlignment(calendar: AttentionReport.CalendarAttention, preferences: AttentionPreferences) -> Double {
        // Compare actual time allocation to goals
        var alignment = 0.0
        var totalWeight = 0.0

        for goal in preferences.timeAllocation.goals {
            totalWeight += 1.0

            // Find matching category
            for (category, stats) in calendar.breakdown {
                if goal.category.lowercased().contains(category.rawValue.lowercased()) {
                    let actualPercentage = stats.percentage
                    let targetPercentage = goal.targetPercentage
                    let difference = abs(actualPercentage - targetPercentage)

                    // Score: 100 - difference (capped at 0)
                    let categoryScore = max(0, 100 - difference)
                    alignment += categoryScore
                    break
                }
            }
        }

        return totalWeight > 0 ? alignment / totalWeight : 50.0
    }

    private func generateRecommendations(
        calendar: AttentionReport.CalendarAttention,
        messaging: AttentionReport.MessagingAttention,
        overall: AttentionReport.OverallAttention
    ) async throws -> [AttentionReport.AttentionRecommendation] {
        var recommendations: [AttentionReport.AttentionRecommendation] = []

        // Check for excessive meeting time
        if calendar.totalMeetingTime > 25200 { // > 7 hours
            recommendations.append(AttentionReport.AttentionRecommendation(
                type: .reduceMeetings,
                priority: .high,
                title: "Excessive meeting time detected",
                description: "You have \(Int(calendar.totalMeetingTime / 3600)) hours of meetings. Consider declining or delegating some.",
                impact: AttentionReport.AttentionRecommendation.Impact(
                    timeRecovered: calendar.wastedTimeEstimate,
                    focusImprovement: 20,
                    description: "Could recover \(Int(calendar.wastedTimeEstimate / 3600)) hours"
                ),
                actionable: true,
                suggestedAction: "Review 'Ceremonial' and 'Waste' category meetings"
            ))
        }

        // Check for low utilization
        if calendar.utilizationScore < 60 {
            recommendations.append(AttentionReport.AttentionRecommendation(
                type: .rebalanceAttention,
                priority: .high,
                title: "Low calendar utilization",
                description: "Only \(Int(calendar.utilizationScore))% of meeting time is high-value. Focus on Strategic and Tactical meetings.",
                impact: AttentionReport.AttentionRecommendation.Impact(
                    timeRecovered: calendar.wastedTimeEstimate,
                    focusImprovement: 40 - calendar.utilizationScore,
                    description: "Could improve focus by \(Int(40 - calendar.utilizationScore))%"
                ),
                actionable: true,
                suggestedAction: "Use 'alfred attention plan' to optimize schedule"
            ))
        }

        // Check for message overload
        if messaging.totalThreads > 50 {
            recommendations.append(AttentionReport.AttentionRecommendation(
                type: .reduceMessageLoad,
                priority: .medium,
                title: "High message volume",
                description: "\(messaging.totalThreads) active threads detected. Consider batch processing.",
                impact: AttentionReport.AttentionRecommendation.Impact(
                    timeRecovered: 3600,  // Estimate 1 hour
                    focusImprovement: 15,
                    description: "Batch processing could save ~1 hour/day"
                ),
                actionable: true,
                suggestedAction: "Set specific times for message checking"
            ))
        }

        return recommendations
    }

    private func generatePlanningRecommendations(
        request: AttentionPlanRequest,
        commitments: [AttentionPlan.Commitment]
    ) async throws -> [AttentionPlan.PlanRecommendation] {
        // Use AI to generate personalized recommendations
        var recommendations: [AttentionPlan.PlanRecommendation] = []

        // Check if commitments exceed constraints
        let totalMeetingHours = commitments.reduce(0.0) { $0 + $1.duration } / 3600

        for constraint in request.constraints {
            switch constraint.type {
            case .maxMeetingHours:
                if let maxHours = constraint.value, totalMeetingHours > maxHours {
                    recommendations.append(AttentionPlan.PlanRecommendation(
                        action: .declineMeeting,
                        title: "Reduce meeting load",
                        description: "Current: \(Int(totalMeetingHours))h, Target: \(Int(maxHours))h",
                        impact: "Free up \(Int(totalMeetingHours - maxHours)) hours",
                        effort: "Medium"
                    ))
                }
            case .requiredFocusTime:
                recommendations.append(AttentionPlan.PlanRecommendation(
                    action: .blockFocusTime,
                    title: "Block focus time",
                    description: constraint.description,
                    impact: "Protect deep work time",
                    effort: "Low"
                ))
            default:
                break
            }
        }

        return recommendations
    }

    private func projectAttentionScores(
        request: AttentionPlanRequest,
        commitments: [AttentionPlan.Commitment],
        recommendations: [AttentionPlan.PlanRecommendation]
    ) -> AttentionReport.OverallAttention {
        // Project what scores would be if recommendations are followed
        let currentEfficiency = 60.0  // Baseline
        let improvement = Double(recommendations.count) * 10  // Each rec improves by 10%

        return AttentionReport.OverallAttention(
            focusScore: min(100, currentEfficiency + improvement),
            balanceScore: 75.0,
            efficiencyScore: min(100, currentEfficiency + improvement),
            alignmentWithGoals: 80.0,
            summary: "Projected improvement: +\(Int(improvement))%"
        )
    }

    private func identifyConflicts(
        request: AttentionPlanRequest,
        commitments: [AttentionPlan.Commitment]
    ) -> [AttentionPlan.Conflict] {
        var conflicts: [AttentionPlan.Conflict] = []

        // Check for goal conflicts
        for goal in request.goals {
            if let targetHours = goal.targetHours {
                let relevantCommitments = commitments.filter { $0.category.rawValue.contains(goal.category) }
                let committedHours = relevantCommitments.reduce(0.0) { $0 + $1.duration } / 3600

                if committedHours < targetHours * 0.5 {
                    conflicts.append(AttentionPlan.Conflict(
                        description: "Only \(Int(committedHours))h allocated to '\(goal.description)', target is \(Int(targetHours))h",
                        severity: .high,
                        affectedGoal: goal.description,
                        suggestedResolution: "Block additional focus time or reduce lower-priority meetings"
                    ))
                }
            }
        }

        return conflicts
    }
}
