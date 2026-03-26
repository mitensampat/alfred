import Foundation

/// Registry of all data-fetching capabilities Alfred has.
/// Used by the PromptCompiler to map user intent phrases to executable data plans.
/// Each capability knows: what it does, what the user might say, and what params it needs at runtime.
class CapabilityRegistry {
    static let shared = CapabilityRegistry()

    /// A registered capability that Alfred can execute to fetch data
    struct Capability {
        let id: String                          // e.g. "commitments_list"
        let description: String                 // e.g. "List open commitments with a person"
        let triggerPhrases: [String]            // phrases that indicate this capability is needed
        let runtimeParams: [String]             // dynamic params needed at execution time (e.g. "$attendees")
        let category: Category

        enum Category: String, Codable {
            case commitments
            case tasks
            case notion
            case messages
            case calendar
            case contacts
            case coaching
            case attention
        }
    }

    /// All registered capabilities
    let capabilities: [Capability] = [
        // --- Commitments ---
        Capability(
            id: "commitments_with_person",
            description: "List open commitments between user and specific people",
            triggerPhrases: ["commitment", "commitments", "owe", "owes", "promised", "agreed to", "follow up", "follow-up"],
            runtimeParams: ["$attendee_names"],
            category: .commitments
        ),
        Capability(
            id: "overdue_commitments",
            description: "List overdue commitments",
            triggerPhrases: ["overdue", "behind on", "late", "missed deadline", "past due"],
            runtimeParams: [],
            category: .commitments
        ),

        // --- Tasks ---
        Capability(
            id: "active_tasks",
            description: "List active tasks/todos",
            triggerPhrases: ["task", "tasks", "todo", "todos", "to-do", "to do", "priorities", "top priority", "goals"],
            runtimeParams: [],
            category: .tasks
        ),
        Capability(
            id: "completed_tasks",
            description: "List recently completed tasks",
            triggerPhrases: ["completed", "finished", "done tasks", "accomplished"],
            runtimeParams: [],
            category: .tasks
        ),

        // --- Notion ---
        Capability(
            id: "notion_notes_search",
            description: "Search Notion Second Brain / Granola Notes for relevant context",
            triggerPhrases: ["notion", "notes", "second brain", "granola", "lookup notes", "relevant notes", "context from notes", "research"],
            runtimeParams: ["$search_context"],
            category: .notion
        ),

        // --- Messages ---
        Capability(
            id: "recent_threads_with_person",
            description: "Get recent message threads with specific people",
            triggerPhrases: ["thread", "threads", "messages", "conversation", "recent messages", "chat history", "what did.*say", "discussed"],
            runtimeParams: ["$attendee_names"],
            category: .messages
        ),

        // --- Calendar ---
        Capability(
            id: "calendar_events",
            description: "Get calendar events for a date",
            triggerPhrases: ["calendar", "schedule", "meetings today", "events", "what's on"],
            runtimeParams: ["$date"],
            category: .calendar
        ),
        Capability(
            id: "meeting_history_with_person",
            description: "Check past meetings with specific people",
            triggerPhrases: ["met before", "last meeting", "meeting history", "previous meetings"],
            runtimeParams: ["$attendee_names"],
            category: .calendar
        ),

        // --- Contacts ---
        Capability(
            id: "contact_lookup",
            description: "Look up information about a person (investor, operator, role)",
            triggerPhrases: ["investor", "operator", "external person", "who is", "look up", "background", "role", "interest in"],
            runtimeParams: ["$attendee_names"],
            category: .contacts
        ),

        // --- Coaching ---
        Capability(
            id: "coaching_context",
            description: "Get coaching history and themes",
            triggerPhrases: ["coaching", "coaching context", "previous sessions", "themes", "patterns"],
            runtimeParams: [],
            category: .coaching
        ),
        Capability(
            id: "learned_patterns",
            description: "Get learned behavioral patterns",
            triggerPhrases: ["pattern", "patterns", "tendency", "habit", "recurring", "avoidance"],
            runtimeParams: [],
            category: .coaching
        ),

        // --- Attention ---
        Capability(
            id: "attention_analysis",
            description: "Analyze attention and focus patterns",
            triggerPhrases: ["attention", "focus", "distracted", "fragmented", "deep work"],
            runtimeParams: [],
            category: .attention
        )
    ]

    /// Find capabilities that match a user's prompt text
    func matchCapabilities(for promptText: String) -> [Capability] {
        let lower = promptText.lowercased()
        return capabilities.filter { cap in
            cap.triggerPhrases.contains { phrase in
                // Support simple regex-like patterns (e.g. "what did.*say")
                if phrase.contains(".*") {
                    return lower.range(of: phrase, options: .regularExpression) != nil
                }
                return lower.contains(phrase)
            }
        }
    }
}
