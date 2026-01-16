import Foundation

/// Represents a critical action item recommended from message/briefing analysis
struct RecommendedAction: Codable, Identifiable {
    let id: UUID
    let title: String
    let description: String
    let priority: ActionPriority
    let source: ActionSource
    let dueDate: Date?
    let context: String  // Additional context about why this is recommended

    init(id: UUID = UUID(), title: String, description: String, priority: ActionPriority, source: ActionSource, dueDate: Date? = nil, context: String) {
        self.id = id
        self.title = title
        self.description = description
        self.priority = priority
        self.source = source
        self.dueDate = dueDate
        self.context = context
    }
}

enum ActionPriority: String, Codable {
    case critical  // Absolutely must do
    case high      // Should do soon

    var emoji: String {
        switch self {
        case .critical: return "🔴"
        case .high: return "🟠"
        }
    }
}

enum ActionSource: Codable {
    case messageThread(contact: String, platform: MessagePlatform)
    case focusedAnalysis(contact: String)
    case briefing
    case calendar(eventTitle: String)

    var displayName: String {
        switch self {
        case .messageThread(let contact, let platform):
            return "\(platform.rawValue.capitalized) with \(contact)"
        case .focusedAnalysis(let contact):
            return "Thread with \(contact)"
        case .briefing:
            return "Daily Briefing"
        case .calendar(let title):
            return "Meeting: \(title)"
        }
    }
}

/// Enhanced analysis results with recommended actions
struct AnalysisWithRecommendations {
    let originalAnalysis: Any  // Can be MessageSummary or FocusedThreadAnalysis
    let recommendedActions: [RecommendedAction]
}
