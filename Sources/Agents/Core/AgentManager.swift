import Foundation

class AgentManager {
    var pendingDecisions: [AgentDecision] = []
    var executedDecisions: [AgentDecision] = []
    var learningInsights: LearningInsights?

    private let config: AgentConfig
    private var agents: [any AgentProtocol] = []
    private let decisionLog: DecisionLog
    private let executionEngine: ExecutionEngine
    private let learningEngine: LearningEngine

    init(config: AgentConfig, appConfig: AppConfig) throws {
        self.config = config
        self.decisionLog = try DecisionLog()
        self.executionEngine = ExecutionEngine(appConfig: appConfig)
        self.learningEngine = try LearningEngine(config: config)

        // Initialize specialized agents based on enabled capabilities
        if config.capabilities.autoDraft {
            agents.append(CommunicationAgent(config: config, appConfig: appConfig, learningEngine: learningEngine))
        }
        if config.capabilities.smartPriority {
            agents.append(TaskAgent(config: config, appConfig: appConfig, learningEngine: learningEngine))
        }
        if config.capabilities.proactiveMeetingPrep {
            agents.append(CalendarAgent(config: config, appConfig: appConfig, learningEngine: learningEngine))
        }
        if config.capabilities.intelligentFollowups {
            agents.append(FollowupAgent(config: config, appConfig: appConfig, learningEngine: learningEngine))
        }
    }

    // MARK: - Evaluation

    func evaluateContext(_ context: AgentContext) async throws -> [AgentDecision] {
        var allDecisions: [AgentDecision] = []

        // Let each agent evaluate the context
        for agent in agents {
            let decisions = try await agent.evaluate(context: context)
            allDecisions.append(contentsOf: decisions)
        }

        // Sort by confidence (highest first)
        allDecisions.sort { $0.confidence > $1.confidence }

        // Determine which decisions require approval
        allDecisions = allDecisions.map { decision in
            var updatedDecision = decision
            updatedDecision = AgentDecision(
                id: decision.id,
                agentType: decision.agentType,
                action: decision.action,
                reasoning: decision.reasoning,
                confidence: decision.confidence,
                context: decision.context,
                risks: decision.risks,
                alternatives: decision.alternatives,
                requiresApproval: requiresApproval(decision: decision),
                timestamp: decision.timestamp
            )
            return updatedDecision
        }

        // Save ALL drafts (even those requiring approval) so user can review them
        for decision in allDecisions {
            if case .draftResponse = decision.action {
                // Save draft to file regardless of confidence
                try await saveDraft(decision)
            }
        }

        // Separate pending from auto-executable
        pendingDecisions = allDecisions.filter { $0.requiresApproval }
        let autoExecutable = allDecisions.filter { !$0.requiresApproval }

        // Auto-execute high-confidence decisions (non-draft actions)
        for decision in autoExecutable {
            if case .draftResponse = decision.action {
                // Drafts already saved above, skip execution
                continue
            }
            try await autoExecuteDecision(decision)
        }

        return allDecisions
    }

    // MARK: - Decision Approval Logic

    private func requiresApproval(decision: AgentDecision) -> Bool {
        // High confidence + low risk = auto-execute
        if decision.confidence >= config.autonomyLevel.confidenceThreshold && decision.risks.isEmpty {
            return false
        }

        // Always require approval for high-impact actions
        switch decision.action {
        case .draftResponse where decision.confidence < 0.7:
            return true
        case .adjustTaskPriority(let adj) where adj.currentPriority == .critical:
            return true  // Never auto-change critical tasks
        case .createFollowup where decision.confidence < 0.6:
            return true
        case .scheduleMeetingPrep:
            // Auto-schedule prep if confidence is high
            return decision.confidence < config.autonomyLevel.confidenceThreshold
        default:
            return decision.confidence < config.autonomyLevel.confidenceThreshold
        }
    }

    // MARK: - Decision Management

    func approveDecision(_ decisionId: UUID) async throws {
        guard let decision = pendingDecisions.first(where: { $0.id == decisionId }) else {
            throw AgentError.decisionNotFound
        }

        // Execute the decision
        let result = try await executionEngine.execute(decision)

        // Log execution
        try await decisionLog.recordExecution(decision, result: result)

        // Record implicit feedback
        let feedback = UserFeedback(
            decisionId: decisionId,
            feedbackType: .implicit,
            wasApproved: true,
            wasSuccessful: result.isSuccess,
            context: decision.context
        )
        try await learningEngine.recordFeedback(feedback)

        // Move to executed
        pendingDecisions.removeAll { $0.id == decisionId }
        executedDecisions.append(decision)
    }

    func rejectDecision(_ decisionId: UUID, reason: String) async throws {
        guard let decision = pendingDecisions.first(where: { $0.id == decisionId }) else {
            throw AgentError.decisionNotFound
        }

        // Log rejection
        try await decisionLog.recordRejection(decision, reason: reason)

        // Record implicit feedback
        let feedback = UserFeedback(
            decisionId: decisionId,
            feedbackType: .implicit,
            wasApproved: false,
            wasSuccessful: false,
            userComment: reason,
            context: decision.context
        )
        try await learningEngine.recordFeedback(feedback)

        // Remove from pending
        pendingDecisions.removeAll { $0.id == decisionId }
    }

    func modifyAndApprove(_ decisionId: UUID, modifications: DecisionModifications) async throws {
        guard var decision = pendingDecisions.first(where: { $0.id == decisionId }) else {
            throw AgentError.decisionNotFound
        }

        // Apply modifications
        if let modifiedAction = modifications.modifiedAction {
            decision = AgentDecision(
                id: decision.id,
                agentType: decision.agentType,
                action: modifiedAction,
                reasoning: modifications.modifiedReasoning ?? decision.reasoning,
                confidence: decision.confidence,
                context: decision.context,
                risks: decision.risks,
                alternatives: decision.alternatives,
                requiresApproval: decision.requiresApproval,
                timestamp: decision.timestamp
            )
        }

        // Execute modified decision
        let result = try await executionEngine.execute(decision)

        // Log with modifications
        try await decisionLog.recordModifiedExecution(decision, modifications: modifications, result: result)

        // Record feedback with modification note
        let feedback = UserFeedback(
            decisionId: decisionId,
            feedbackType: .implicit,
            wasApproved: true,
            wasSuccessful: result.isSuccess,
            userComment: modifications.userNotes,
            context: decision.context
        )
        try await learningEngine.recordFeedback(feedback)

        // Move to executed
        pendingDecisions.removeAll { $0.id == decisionId }
        executedDecisions.append(decision)
    }

    private func saveDraft(_ decision: AgentDecision) async throws {
        // Save draft to file regardless of confidence level
        // This allows user to review ALL drafts via 'alfred drafts'
        let result = try await executionEngine.execute(decision)

        // Don't log as execution - just saving for review
        if case .failure(let error) = result {
            print("⚠️  Warning: Failed to save draft: \(error)")
        }
    }

    private func autoExecuteDecision(_ decision: AgentDecision) async throws {
        let result = try await executionEngine.execute(decision)

        // Log auto-execution
        try await decisionLog.recordAutoExecution(decision, result: result)

        // Record implicit feedback
        let feedback = UserFeedback(
            decisionId: decision.id,
            feedbackType: .implicit,
            wasApproved: true,  // Auto-approved by system
            wasSuccessful: result.isSuccess,
            context: decision.context
        )
        try await learningEngine.recordFeedback(feedback)

        executedDecisions.append(decision)
    }

    // MARK: - Explicit Feedback

    func provideFeedback(decisionId: UUID, wasHelpful: Bool, comment: String? = nil) async throws {
        guard let decision = executedDecisions.first(where: { $0.id == decisionId }) else {
            throw AgentError.decisionNotFound
        }

        let feedback = UserFeedback(
            decisionId: decisionId,
            feedbackType: .explicit,
            wasApproved: wasHelpful,
            wasSuccessful: wasHelpful,
            userComment: comment,
            context: decision.context
        )

        try await learningEngine.recordFeedback(feedback)

        // Update learning insights
        learningInsights = try await learningEngine.getInsights()
    }

    // MARK: - Audit Trail

    func getAuditTrail(since: Date) async throws -> [AuditEntry] {
        return try await decisionLog.getEntries(since: since)
    }

    func getAuditTrail(for agentType: AgentType, since: Date) async throws -> [AuditEntry] {
        return try await decisionLog.getEntries(for: agentType, since: since)
    }

    // MARK: - Learning Insights

    func refreshInsights() async throws {
        learningInsights = try await learningEngine.getInsights()
    }
}

// MARK: - Agent Errors

enum AgentError: Error, LocalizedError {
    case decisionNotFound
    case executionFailed(String)
    case learningFailed(String)

    var errorDescription: String? {
        switch self {
        case .decisionNotFound:
            return "Decision not found"
        case .executionFailed(let message):
            return "Execution failed: \(message)"
        case .learningFailed(let message):
            return "Learning failed: \(message)"
        }
    }
}
