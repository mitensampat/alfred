import Foundation

/// Service for sharing context between agents
/// Enables cross-agent coordination and awareness
class SharedContextService {
    static let shared = SharedContextService()

    // MARK: - Shared State

    /// Recent decisions from all agents (last hour)
    private var recentDecisions: [AgentDecision] = []

    /// Current alerts/flags raised by agents
    private var activeAlerts: [AgentAlert] = []

    /// Cross-agent suggestions waiting for coordination
    private var pendingSuggestions: [CrossAgentSuggestion] = []

    /// Shared insights that agents have discovered
    private var sharedInsights: [SharedInsight] = []

    /// Last time each agent made a decision
    private var lastAgentActivity: [AgentType: Date] = [:]

    /// Lock for thread safety
    private let lock = NSLock()

    private init() {}

    // MARK: - Recording Activity

    /// Record a decision from an agent
    func recordDecision(_ decision: AgentDecision) {
        lock.lock()
        defer { lock.unlock() }

        recentDecisions.append(decision)
        lastAgentActivity[decision.agentType] = decision.timestamp

        // Prune old decisions (keep last hour)
        let oneHourAgo = Date().addingTimeInterval(-3600)
        recentDecisions = recentDecisions.filter { $0.timestamp > oneHourAgo }

        // Check for cross-agent coordination opportunities
        checkForCoordinationOpportunities(newDecision: decision)
    }

    /// Raise an alert that other agents should be aware of
    func raiseAlert(_ alert: AgentAlert) {
        lock.lock()
        defer { lock.unlock() }

        activeAlerts.append(alert)

        // Auto-expire alerts after their TTL
        let expiryTime = Date().addingTimeInterval(alert.ttl)
        DispatchQueue.global().asyncAfter(deadline: .now() + alert.ttl) { [weak self] in
            self?.expireAlert(alert.id)
        }
    }

    /// Share an insight with other agents
    func shareInsight(_ insight: SharedInsight) {
        lock.lock()
        defer { lock.unlock() }

        sharedInsights.append(insight)

        // Keep only recent insights (last 24 hours)
        let oneDayAgo = Date().addingTimeInterval(-86400)
        sharedInsights = sharedInsights.filter { $0.timestamp > oneDayAgo }
    }

    /// Add a cross-agent suggestion
    func addSuggestion(_ suggestion: CrossAgentSuggestion) {
        lock.lock()
        defer { lock.unlock() }

        pendingSuggestions.append(suggestion)
    }

    // MARK: - Querying Context

    /// Get recent decisions from a specific agent
    func getRecentDecisions(for agentType: AgentType, limit: Int = 10) -> [AgentDecision] {
        lock.lock()
        defer { lock.unlock() }

        return recentDecisions
            .filter { $0.agentType == agentType }
            .suffix(limit)
            .reversed()
            .map { $0 }
    }

    /// Get all recent decisions across agents
    func getAllRecentDecisions(limit: Int = 20) -> [AgentDecision] {
        lock.lock()
        defer { lock.unlock() }

        return Array(recentDecisions.suffix(limit).reversed())
    }

    /// Get active alerts relevant to a specific agent
    func getAlertsFor(agentType: AgentType) -> [AgentAlert] {
        lock.lock()
        defer { lock.unlock() }

        return activeAlerts.filter { $0.relevantAgents.contains(agentType) }
    }

    /// Get all active alerts
    func getAllActiveAlerts() -> [AgentAlert] {
        lock.lock()
        defer { lock.unlock() }

        return activeAlerts
    }

    /// Get insights shared by other agents
    func getSharedInsights(relevantTo agentType: AgentType) -> [SharedInsight] {
        lock.lock()
        defer { lock.unlock() }

        return sharedInsights.filter { $0.relevantAgents.contains(agentType) }
    }

    /// Get pending cross-agent suggestions
    func getPendingSuggestions() -> [CrossAgentSuggestion] {
        lock.lock()
        defer { lock.unlock() }

        return pendingSuggestions
    }

    /// Mark a suggestion as processed
    func markSuggestionProcessed(_ suggestionTitle: String) {
        lock.lock()
        defer { lock.unlock() }

        pendingSuggestions.removeAll { $0.title == suggestionTitle }
    }

    /// Check if a specific agent has been active recently
    func hasRecentActivity(for agentType: AgentType, withinMinutes: Int = 30) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let lastActivity = lastAgentActivity[agentType] else { return false }
        let threshold = Date().addingTimeInterval(-Double(withinMinutes * 60))
        return lastActivity > threshold
    }

    // MARK: - Cross-Agent Coordination

    /// Check for opportunities where agents should coordinate
    private func checkForCoordinationOpportunities(newDecision: AgentDecision) {
        // Communication + Calendar coordination
        // If communication agent drafts a message and calendar agent sees an upcoming meeting with that person
        if newDecision.agentType == .communication,
           case .draftResponse(let draft) = newDecision.action {
            // Check if there's a recent calendar decision about the same recipient
            let calendarDecisions = recentDecisions.filter { $0.agentType == .calendar }
            for calDecision in calendarDecisions {
                if case .scheduleMeetingPrep(let prep) = calDecision.action {
                    // Check if meeting involves the same person
                    if prep.meetingTitle.lowercased().contains(draft.recipient.lowercased()) {
                        let suggestion = CrossAgentSuggestion(
                            title: "Consider waiting until after meeting",
                            description: "You're drafting a message to \(draft.recipient) but have a meeting with them soon (\(prep.meetingTitle)). Consider discussing in person instead.",
                            involvedAgents: [.communication, .calendar],
                            confidence: 0.7
                        )
                        pendingSuggestions.append(suggestion)
                    }
                }
            }
        }

        // Task + Follow-up coordination
        // If task agent adjusts priority, follow-up agent might need to update reminders
        if newDecision.agentType == .task,
           case .adjustTaskPriority(let adjustment) = newDecision.action {
            if adjustment.newPriority == .critical || adjustment.newPriority == .high {
                let insight = SharedInsight(
                    sourceAgent: .task,
                    relevantAgents: [.followup, .calendar],
                    title: "High priority task flagged",
                    content: "Task '\(adjustment.taskTitle)' was marked as \(adjustment.newPriority.rawValue). Related follow-ups or meetings may need attention.",
                    timestamp: Date()
                )
                sharedInsights.append(insight)
            }
        }

        // Follow-up + Communication coordination
        // If follow-up is created for someone, communication agent should know
        if newDecision.agentType == .followup,
           case .createFollowup(let followup) = newDecision.action {
            let insight = SharedInsight(
                sourceAgent: .followup,
                relevantAgents: [.communication],
                title: "Follow-up scheduled",
                content: "Follow-up created: \(followup.followupAction). Communication agent should be aware for context.",
                timestamp: Date()
            )
            sharedInsights.append(insight)
        }
    }

    /// Expire an alert by ID
    private func expireAlert(_ alertId: UUID) {
        lock.lock()
        defer { lock.unlock() }

        activeAlerts.removeAll { $0.id == alertId }
    }

    // MARK: - Context Summary

    /// Get a summary of shared context for an agent
    func getContextSummary(for agentType: AgentType) -> SharedContextSummary {
        lock.lock()
        defer { lock.unlock() }

        let alerts = activeAlerts.filter { $0.relevantAgents.contains(agentType) }
        let insights = sharedInsights.filter { $0.relevantAgents.contains(agentType) }
        let suggestions = pendingSuggestions.filter { $0.involvedAgents.contains(agentType) }

        // Get what other agents have been doing
        var otherAgentActivity: [AgentType: String] = [:]
        for (agent, lastTime) in lastAgentActivity where agent != agentType {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            otherAgentActivity[agent] = formatter.localizedString(for: lastTime, relativeTo: Date())
        }

        return SharedContextSummary(
            activeAlerts: alerts,
            relevantInsights: insights,
            pendingSuggestions: suggestions,
            otherAgentActivity: otherAgentActivity,
            timestamp: Date()
        )
    }

    /// Clear all shared context (for testing or reset)
    func clearAll() {
        lock.lock()
        defer { lock.unlock() }

        recentDecisions.removeAll()
        activeAlerts.removeAll()
        pendingSuggestions.removeAll()
        sharedInsights.removeAll()
        lastAgentActivity.removeAll()
    }
}

// MARK: - Supporting Types

struct AgentAlert: Codable, Identifiable {
    let id: UUID
    let sourceAgent: AgentType
    let relevantAgents: [AgentType]
    let alertType: AlertType
    let title: String
    let message: String
    let priority: UrgencyLevel
    let ttl: TimeInterval  // Time to live in seconds
    let timestamp: Date

    enum AlertType: String, Codable {
        case urgent           // Needs immediate attention
        case contextChange    // Something important changed
        case coordination     // Agents need to coordinate
        case conflict         // Potential conflict detected
    }

    init(
        id: UUID = UUID(),
        sourceAgent: AgentType,
        relevantAgents: [AgentType],
        alertType: AlertType,
        title: String,
        message: String,
        priority: UrgencyLevel = .medium,
        ttl: TimeInterval = 3600,  // Default 1 hour
        timestamp: Date = Date()
    ) {
        self.id = id
        self.sourceAgent = sourceAgent
        self.relevantAgents = relevantAgents
        self.alertType = alertType
        self.title = title
        self.message = message
        self.priority = priority
        self.ttl = ttl
        self.timestamp = timestamp
    }
}

struct SharedInsight: Codable {
    let sourceAgent: AgentType
    let relevantAgents: [AgentType]
    let title: String
    let content: String
    let timestamp: Date
}

struct SharedContextSummary: Codable {
    let activeAlerts: [AgentAlert]
    let relevantInsights: [SharedInsight]
    let pendingSuggestions: [CrossAgentSuggestion]
    let otherAgentActivity: [AgentType: String]
    let timestamp: Date

    var hasActionableItems: Bool {
        !activeAlerts.isEmpty || !pendingSuggestions.isEmpty
    }

    var summary: String {
        var parts: [String] = []

        if !activeAlerts.isEmpty {
            parts.append("\(activeAlerts.count) active alerts")
        }
        if !relevantInsights.isEmpty {
            parts.append("\(relevantInsights.count) shared insights")
        }
        if !pendingSuggestions.isEmpty {
            parts.append("\(pendingSuggestions.count) coordination suggestions")
        }

        return parts.isEmpty ? "No shared context" : parts.joined(separator: ", ")
    }
}
