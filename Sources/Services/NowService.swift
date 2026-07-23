import Foundation

/// Builds the "Now" surface: the 4 workspaces you're most recently in, plus 1 that
/// needs you.
///
/// Ranking obeys the rule we settled: slots 1–4 are workspaces by recency of *your*
/// activity (reflections come from your threads, notes and calendar, so `last_activity`
/// is your signal, not Alfred's sync). Slot 5 is an urgency exception — a high-stakes
/// workspace going quiet that recency can't reach — scored Commit-style, with a floor so
/// a calm day shows four cards, not a padded five.
enum NowService {

    struct Card {
        let id: String
        let theme: String
        let state: String
        let temperature: String
        let reason: String
        let daysSince: Int
        let inputsThisWeek: Int
        let question: String
        let moved: [String]
        let isAttention: Bool
        let coaching: String?   // anchored, data-grounded; nil when nothing specific to say
    }

    /// Days of quiet before a workspace counts as "going cold" for the attention slot.
    private static let coldThreshold = 5
    /// Minimum urgency score for slot 5 to appear at all.
    private static let attentionFloor = 20.0

    static func build() -> [String: Any] {
        let themes = ReflectionStore.shared.getThemesWithState(days: 60, limit: 200)
        guard !themes.isEmpty else { return ["recent": [], "attention": NSNull()] }

        // Rank by recency of your activity. last_activity is an ISO-ish timestamp,
        // so lexical sort is chronological.
        let byRecency = themes.sorted {
            (($0["last_activity"] as? String) ?? "") > (($1["last_activity"] as? String) ?? "")
        }
        let recent = Array(byRecency.prefix(4))
        let recentThemes = Set(recent.compactMap { $0["theme"] as? String })

        // Attention: the most urgent workspace NOT already surfaced by recency.
        // Urgency rewards exactly what recency can't see — going cold on something
        // that still has an open decision.
        let attention = byRecency
            .filter { !recentThemes.contains(($0["theme"] as? String) ?? "") }
            .map { (t: $0, score: urgency($0)) }
            .filter { $0.score >= attentionFloor }
            .max { $0.score < $1.score }?.t

        var out: [String: Any] = [
            "recent": recent.map { card($0, attention: false) },
            "attention": attention.map { card($0, attention: true) } ?? NSNull()
        ]
        out["standing_coaching"] = standingCoaching(themes) ?? NSNull()
        return out
    }

    /// Commit-style urgency: cold + something pending outweighs mere age.
    private static func urgency(_ t: [String: Any]) -> Double {
        let days = t["days_since"] as? Int ?? 0
        let state = (t["state"] as? String) ?? ""
        let hasQuestion = !((t["edge"] as? String) ?? "").isEmpty
        var s = 0.0
        if days >= coldThreshold { s += min(Double(days) * 3, 40) }   // going cold
        if state == "deciding" { s += 20 }                            // a decision is sitting
        if hasQuestion { s += 12 }                                    // an open question
        return s
    }

    private static func card(_ t: [String: Any], attention: Bool) -> [String: Any] {
        let theme = (t["theme"] as? String) ?? ""
        let state = (t["state"] as? String) ?? ""
        let temp = (t["temperature"] as? String) ?? "cooling"
        let days = t["days_since"] as? Int ?? 0
        let inputs = t["inputs_this_week"] as? Int ?? 0
        let question = (t["edge"] as? String) ?? ""
        let subtitle = (t["subtitle"] as? String) ?? ""
        let moved = (t["moved"] as? String) ?? ""

        var movedLines: [String] = []
        if !moved.isEmpty { movedLines.append(moved) }
        if !subtitle.isEmpty && subtitle != moved { movedLines.append(subtitle) }

        let c = Card(
            id: SelfModelSynthesizer.stableId("theme", theme),
            theme: theme, state: state, temperature: temp,
            reason: reasonString(attention: attention, days: days, inputs: inputs, state: state),
            daysSince: days, inputsThisWeek: inputs,
            question: question, moved: movedLines, isAttention: attention,
            coaching: anchoredCoaching(state: state, days: days, question: question, attention: attention)
        )
        return [
            "id": c.id, "theme": c.theme, "state": c.state, "temperature": c.temperature,
            "reason": c.reason, "days_since": c.daysSince, "inputs_this_week": c.inputsThisWeek,
            "question": c.question, "moved": c.moved, "is_attention": c.isAttention,
            "coaching": c.coaching as Any
        ]
    }

    /// The "why this is here" line — the fix for truncated thread names.
    private static func reasonString(attention: Bool, days: Int, inputs: Int, state: String) -> String {
        if attention {
            let pending = state == "deciding" ? " · a decision is sitting" : ""
            return "no activity in \(days) day\(days == 1 ? "" : "s")\(pending)"
        }
        if days == 0 { return inputs > 1 ? "active today · \(inputs) inputs this week" : "active today" }
        if days == 1 { return "you were here yesterday" }
        if inputs >= 2 { return "\(inputs) inputs this week" }
        return "touched \(days) days ago"
    }

    /// Anchored coaching, derived from real state — never fabricated. Returns nil unless
    /// the data actually supports a specific observation.
    private static func anchoredCoaching(state: String, days: Int, question: String, attention: Bool) -> String? {
        if attention && state == "deciding" && days >= coldThreshold {
            return "This has sat in ‘deciding’ for \(days) days without moving. What's the blocker — the decision, or getting to it?"
        }
        if state == "deciding" && days >= 3 {
            return "You've been deciding here for \(days) days. Is more information going to help, or is it a call you're avoiding?"
        }
        return nil
    }

    /// One cross-cutting coaching card.
    ///
    /// Deliberately returns nil for now. The obvious data-derived signal — "N workspaces
    /// stuck in 'deciding'" — is measuring classifier noise, not insight: 'deciding' is
    /// ~40% of all themes, so the count reads alarming ("60 stuck decisions") without being
    /// true. A standing coaching card has to come from the real coaching pipeline, which
    /// reasons about the person; a count never earns that slot. Frontend omits when nil.
    private static func standingCoaching(_ themes: [[String: Any]]) -> [String: Any]? {
        return nil
    }
}
