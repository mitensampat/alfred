import Foundation

// MARK: - Agent Protocol

protocol AgentProtocol {
    var agentType: AgentType { get }
    var autonomyLevel: AutonomyLevel { get }
    var config: AgentConfig { get }

    func evaluate(context: AgentContext) async throws -> [AgentDecision]
    func execute(decision: AgentDecision) async throws -> ExecutionResult
    func learn(feedback: UserFeedback) async throws
}

// MARK: - Autonomy Level

enum AutonomyLevel: String, Codable {
    case conservative  // Always ask permission (confidence threshold: never auto-execute)
    case moderate      // Ask for high-impact decisions (confidence threshold: 0.8+)
    case aggressive    // Full autonomy with audit trail (confidence threshold: 0.65+)

    var confidenceThreshold: Double {
        switch self {
        case .conservative: return 1.0  // Never auto-execute
        case .moderate: return 0.8
        case .aggressive: return 0.65
        }
    }

    var description: String {
        switch self {
        case .conservative:
            return "Always ask permission before taking action"
        case .moderate:
            return "Auto-execute low-risk decisions, ask for high-impact ones"
        case .aggressive:
            return "Full autonomy with audit trail for all decisions"
        }
    }
}

// MARK: - Agent Configuration

struct AgentConfig: Codable {
    let enabled: Bool
    let autonomyLevel: AutonomyLevel
    let capabilities: AgentCapabilities
    let learningMode: LearningMode

    struct AgentCapabilities: Codable {
        let autoDraft: Bool
        let smartPriority: Bool
        let proactiveMeetingPrep: Bool
        let intelligentFollowups: Bool

        static var all: AgentCapabilities {
            AgentCapabilities(
                autoDraft: true,
                smartPriority: true,
                proactiveMeetingPrep: true,
                intelligentFollowups: true
            )
        }
    }

    enum LearningMode: String, Codable {
        case explicitOnly    // Only learn from explicit thumbs up/down
        case implicitOnly    // Only learn from approval/rejection patterns
        case hybrid          // Combine both approaches

        var explicitWeight: Double {
            switch self {
            case .explicitOnly: return 1.0
            case .implicitOnly: return 0.0
            case .hybrid: return 0.6
            }
        }

        var implicitWeight: Double {
            switch self {
            case .explicitOnly: return 0.0
            case .implicitOnly: return 1.0
            case .hybrid: return 0.4
            }
        }
    }

    static var aggressive: AgentConfig {
        AgentConfig(
            enabled: true,
            autonomyLevel: .aggressive,
            capabilities: .all,
            learningMode: .hybrid
        )
    }
}

// MARK: - Learning Insights

struct LearningInsights: Codable {
    let totalDecisions: Int
    let approvalRate: Double
    let successRate: Double
    let averageConfidence: Double
    let improvementRate: Double
    let topPatterns: [PatternInsight]

    struct PatternInsight: Codable {
        let pattern: String
        let occurrences: Int
        let approvalRate: Double
    }
}
