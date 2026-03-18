import Foundation

/// Maps user intent to a coaching posture, selecting which installed skill tenets
/// should guide the coaching response. This ensures Coach Alfred stays on-topic
/// (e.g., thread analysis → reflection, not task prioritization).
enum CoachingPosture: String {
    case reflection      // Thread/message analysis — dynamics, energy, patterns
    case prioritization  // Task focus — leverage, avoidance
    case accountability  // Commitment focus — relationship debt, agreements
    case planning        // Calendar/schedule — time allocation, meeting ROI
    case operational     // Create/update/delete — no coaching overlay needed
    case general         // Fallback — balanced coaching, no forced angle
}

struct IntentCoachingRouter {

    // MARK: - Intent → Posture Mapping

    /// Determine the coaching posture for a given intent action + target
    static func posture(for action: UserIntent.Action, target: UserIntent.Target?) -> CoachingPosture {
        // Operational intents: no coaching overlay
        if action == .create || action == .update || action == .delete {
            return .operational
        }

        switch target {
        case .thread, .messages:
            return .reflection
        case .tasks, .todos, .attention:
            return .prioritization
        case .commitments:
            return .accountability
        case .calendar, .meeting:
            return .planning
        case .briefing:
            return action == .summarize ? .planning : .prioritization
        case .drafts:
            return .reflection  // Draft generation is about communication
        case .contacts, .preferences, nil:
            return .general
        }
    }

    // MARK: - Posture → Skill Mapping

    /// Get the installed skill IDs most relevant to this posture.
    /// Tenets from these skills are injected into the coaching overlay.
    /// Core skill IDs injected into every posture (always-on tenets)
    private static let coreSkillIds = ["alfred-voice", "alfred-rules", "campbell-rules", "mochary-rules"]

    static func relevantSkillIds(for posture: CoachingPosture) -> [String] {
        let postureSkills: [String]
        switch posture {
        case .reflection:
            postureSkills = ["mochary-attention", "campbell-relationship"]
        case .prioritization:
            postureSkills = ["campbell-leverage", "mochary-avoidance"]
        case .accountability:
            postureSkills = ["campbell-relationship", "mochary-avoidance"]
        case .planning:
            postureSkills = ["mochary-attention"]
        case .operational, .general:
            postureSkills = []
        }
        return coreSkillIds + postureSkills
    }

    // MARK: - Coaching Overlay Prompts

    /// Build a posture-aware coaching overlay prompt.
    /// Replaces the old hardcoded "priority call" overlay.
    static func buildCoachingOverlay(
        posture: CoachingPosture,
        query: String,
        toolName: String,
        dataSummary: String,
        relevantTenets: String
    ) -> String {
        let base = """
        The user asked: "\(query)"

        I just showed them a \(toolName) card with this data:
        \(dataSummary)

        CRITICAL: You may ONLY reference data, quotes, timestamps, names, and statistics that appear in the DATA section above. Never fabricate message content, conversation details, or statistics. If the data lacks specifics you'd need to answer fully, say what you CAN see and suggest the user ask a more targeted question.

        """

        let tenetsBlock = relevantTenets.isEmpty ? "" : """

        Relevant coaching lens:
        \(relevantTenets)
        """

        switch posture {
        case .reflection:
            return base + """
            Now respond as Coach Alfred — 2-4 sentences max. Lead with a concise, factual summary of what the data shows (key topics discussed, decisions made, action items, who said what). Be informative first, coach second. Only add a coaching observation if the data reveals something genuinely notable — a clear pattern worth flagging, not a forced insight. Do NOT psychoanalyze the user's communication style unless they explicitly ask for feedback on it. Reference only data, quotes, and timestamps that appear above. Stay on this topic — do NOT redirect to their task list or #1 goal.
            \(tenetsBlock)
            """

        case .prioritization:
            return base + """
            Now respond as Coach Alfred — 2-4 sentences max. What does this data reveal about their focus and prioritization? If something is overdue or being avoided, name it directly. Reference specific items (tasks, people, dates). Don't repeat the raw data — the card already shows it.
            \(tenetsBlock)
            """

        case .accountability:
            return base + """
            Now respond as Coach Alfred — 2-4 sentences max. Focus on relationship health and commitment reliability. Who is waiting on them? What's overdue? If there's a pattern of broken agreements with a specific person, name it. Reference specific people and commitments. Don't repeat the raw data — the card already shows it.
            \(tenetsBlock)
            """

        case .planning:
            return base + """
            Now respond as Coach Alfred — 2-4 sentences max. Comment on their time allocation and schedule structure. Flag back-to-back meetings, missing focus blocks, or meetings that could be async. If the calendar suggests they'll have no time for deep work, say it directly. Reference specific meetings or time blocks. Don't repeat the raw data — the card already shows it.
            \(tenetsBlock)
            """

        case .general:
            return base + """
            Now respond as Coach Alfred — 2-4 sentences max. Add a coaching observation or gentle challenge based on what the data shows. Reference specific items (names, times, tasks). Don't repeat the raw data — the card already shows it. If the data suggests something worth flagging (back-to-back meetings, overdue commitments, no focus time), say it directly.
            \(tenetsBlock)
            """

        case .operational:
            return ""  // Should never reach here — operational intents skip coaching
        }
    }

    // MARK: - Follow-Up Posture Hints

    /// Brief framing hint prepended to the user's query when they follow up
    /// in general chat after an intent-matched turn. Carries forward the
    /// coaching posture so Claude stays on-topic.
    static func followUpHint(for posture: CoachingPosture) -> String {
        switch posture {
        case .reflection:
            return "[Context: The user is reviewing message threads. Stay factual — summarize what was discussed, decisions made, and open items. Only add coaching observations if they ask for feedback or a clear pattern jumps out. Do not redirect to tasks, goals, or prioritization unless they explicitly shift topics.]"
        case .prioritization:
            return "[Context: The user is thinking about priorities, tasks, and focus. Coach on what they should prioritize, what they're avoiding, and where their leverage is highest.]"
        case .accountability:
            return "[Context: The user is working through commitment and relationship accountability. Coach on who's waiting, what's overdue, and how to maintain trust through follow-through.]"
        case .planning:
            return "[Context: The user is reviewing time allocation and scheduling. Coach on calendar structure, meeting ROI, and protecting focus time.]"
        case .general, .operational:
            return ""
        }
    }

    // MARK: - System Prompt Posture Hint

    /// Returns a posture-aware instruction for the coaching observations section
    /// of the system prompt, so Claude weights the right insights.
    static func observationsHint(for posture: CoachingPosture) -> String? {
        switch posture {
        case .reflection:
            return "The user's current focus is **communication dynamics and messaging patterns** — weight observations about attention allocation and relationship signals more heavily. Don't force task prioritization or avoidance coaching unless the user brings them up."
        case .prioritization:
            return "The user's current focus is **task prioritization and focus** — weight observations about leverage and avoidance more heavily."
        case .accountability:
            return "The user's current focus is **commitment accountability** — weight observations about relationship health and follow-through more heavily."
        case .planning:
            return "The user's current focus is **time allocation and scheduling** — weight observations about attention and calendar structure more heavily."
        case .general, .operational:
            return nil
        }
    }
}
