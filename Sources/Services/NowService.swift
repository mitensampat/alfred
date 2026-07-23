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
    /// Minimum significance×neglect for slot 5 to appear. Tuned to the new score:
    /// significance is 0–1 (capped track record), neglect 1–8 (age). ~0.8 means a
    /// workspace needs real production behind it AND real neglect — a zero-decision
    /// cold topic scores 0 and never surfaces. Zero attention cards on a calm day is fine.
    private static let attentionFloor = 0.8

    static func build() -> [String: Any] {
        let store = SelfModelStore.shared
        let allThemes = ReflectionStore.shared.getThemesWithState(days: 60, limit: 200)
        // Now surfaces WORKSPACES, not topics — the promotion bar keeps the cheap
        // substrate out of the surface you open in the act of work.
        let promoted = SelfModelService.promotedThemeIds(store: store)
        let themes = allThemes.filter {
            promoted.contains(SelfModelSynthesizer.stableId("theme", ($0["theme"] as? String) ?? ""))
        }
        guard !themes.isEmpty else { return ["recent": [], "attention": NSNull()] }

        // ── signals ──
        let engagement = engagementWeights(store.engagementEvents())      // learned multiplier
        let captures = store.captureCountsByTheme(sinceDays: 7)           // authored
        let decisionsByTheme = decisionCounts(store)                     // track record (attention)

        func themeId(_ t: [String: Any]) -> String {
            SelfModelSynthesizer.stableId("theme", (t["theme"] as? String) ?? "")
        }

        // Recency-4 score: engagement × [0.50 momentum + 0.30 authored + 0.20 freshness].
        // "Recency" is weighted by YOUR engagement intensity and decay, not a raw
        // ingestion timestamp — a workspace you keep opening beats one Alfred just synced.
        func score(_ t: [String: Any]) -> Double {
            let id = themeId(t)
            let inputs = t["inputs_this_week"] as? Int ?? 0
            let days = Double(t["days_since"] as? Int ?? 99)
            let momentum = min(Double(inputs), 6) / 6.0
            let authored = min(Double(captures[id] ?? 0), 3) / 3.0
            let freshness = pow(0.5, days / 1.5)                         // half-life 36h
            let base = 0.50 * momentum + 0.30 * authored + 0.20 * freshness
            return (engagement[id] ?? 1.0) * base
        }

        let scored = themes.map { (t: $0, s: score($0)) }.sorted { $0.s > $1.s }

        // Diversify: one card per object — never four flavours of one workstream.
        var recent: [[String: Any]] = []
        var pickedTitles: [String] = []
        for cand in scored {
            let title = (cand.t["theme"] as? String) ?? ""
            if pickedTitles.contains(where: { titleSimilar($0, title) }) { continue }
            recent.append(cand.t)
            pickedTitles.append(title)
            if recent.count == 4 { break }
        }
        let recentThemes = Set(recent.compactMap { $0["theme"] as? String })

        // Attention (slot 5): significance × neglect among workspaces recency can't reach.
        // Significance is track record (produced decisions), not merely 'deciding' state —
        // neglect only counts against a workspace that earned attention.
        let attention = themes
            .filter { !recentThemes.contains(($0["theme"] as? String) ?? "") }
            .map { (t: $0, a: attentionScore($0, decisions: decisionsByTheme[themeId($0)] ?? 0)) }
            .filter { $0.a >= attentionFloor }
            .max { $0.a < $1.a }?.t

        var out: [String: Any] = [
            "recent": recent.map { card($0, attention: false) },
            "attention": attention.map { card($0, attention: true) } ?? NSNull()
        ]
        out["standing_coaching"] = standingCoaching(themes) ?? NSNull()
        return out
    }

    /// Learned per-workspace multiplier from Now interactions, decayed (half-life 7d),
    /// clamped to [0.3, 2.5]. Snooze three mornings → buried; open daily → anchored.
    private static func engagementWeights(_ events: [(workspace: String, event: String, ts: String)]) -> [String: Double] {
        let w: [String: Double] = ["open": 0.15, "capture": 0.4, "snooze": -0.5, "dismiss": -0.8]
        let iso = ISO8601DateFormatter()
        let now = Date()
        var sum: [String: Double] = [:]
        for e in events {
            guard let ev = w[e.event], let ts = iso.date(from: e.ts) else { continue }
            let ageDays = max(0, now.timeIntervalSince(ts) / 86400.0)
            sum[e.workspace, default: 0] += ev * pow(0.5, ageDays / 7.0)
        }
        var out: [String: Double] = [:]
        for (ws, s) in sum { out[ws] = min(max(1.0 + s, 0.3), 2.5) }
        return out
    }

    /// Decisions produced per theme (track record) via lineage.
    private static func decisionCounts(_ store: SelfModelStore) -> [String: Int] {
        let decisionIds = Set(store.getFacets(kind: "decision").compactMap { $0["id"] as? String })
        var out: [String: Int] = [:]
        for l in store.allLineage() where decisionIds.contains(l.facet) {
            out[l.theme, default: 0] += 1
        }
        return out
    }

    /// significance × neglect. Owed-commitment and user-promoted terms are deferred
    /// (they need mapping that doesn't exist yet); track record + neglect ship now.
    private static func attentionScore(_ t: [String: Any], decisions: Int) -> Double {
        let days = Double(t["days_since"] as? Int ?? 0)
        guard days >= Double(coldThreshold) else { return 0 }     // must be going cold
        let significance = min(Double(decisions), 10) / 10.0      // capped track record
        let neglect = min(days, 40) / 5.0                         // scales with age
        return significance * neglect
    }

    /// Token-Jaccard similarity — same shape as the graduation shortlist. Two workspaces
    /// above 0.5 are treated as the same object for diversification.
    private static let stop: Set<String> = ["the","and","for","with","from","that","this","strategy","management","and","through","during"]
    private static func tokens(_ s: String) -> Set<String> {
        Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 3 && !stop.contains($0) })
    }
    private static func titleSimilar(_ a: String, _ b: String) -> Bool {
        let ta = tokens(a), tb = tokens(b)
        guard !ta.isEmpty, !tb.isEmpty else { return false }
        let inter = Double(ta.intersection(tb).count)
        let uni = Double(ta.union(tb).count)
        return uni > 0 && inter / uni > 0.5
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
