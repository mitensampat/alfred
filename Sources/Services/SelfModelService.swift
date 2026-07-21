import Foundation

/// Read-only synthesis of Alfred's durable self-model — the "You" surface.
///
/// Stage 1 is deliberately READ-ONLY: it reads existing stores (ReflectionStore +
/// WorkflowLearningService) and synthesizes the four registers. It never writes,
/// and never triggers an LLM call (all sources are SQLite SELECTs).
///
/// Registers:
///   - movement:   what changed recently (belief updates + theme state transitions)
///   - workspaces: active themes you're working inside
///   - questions:  open questions you're sitting with
///   - lenses:     durable patterns/beliefs + belief-shift trajectories
enum SelfModelService {

    /// Temperature ordering so hotter, more-active themes float to the top.
    private static let tempRank: [String: Int] = ["hot": 0, "warming": 1, "cooling": 2, "resolved": 3]

    static func synthesize() -> [String: Any] {
        let store = ReflectionStore.shared

        let themesRaw = store.getThemesWithState(days: 30, limit: 12)
        let questions = store.getOpenQuestions(limit: 6)
        let beliefShifts = store.getRecentBeliefShifts(days: 90, limit: 6)
        let week = store.getWeekInputSummary(days: 7)
        // Lenses should show durable beliefs/preferences, not journal-like context dumps.
        // `user_context` rows are single-session captures ("today I worked on X"), not standing patterns.
        let patterns = WorkflowLearningService.shared.getLearnedPatterns()
            .filter { !$0.isArchived && $0.type != "user_context" }

        // ---- Movement: what changed this week ----
        // Recent belief updates first (the emotional core), then theme state transitions.
        var movement: [[String: Any]] = []
        for shift in store.getRecentBeliefShifts(days: 14, limit: 3) {
            let to = shift["to"] ?? ""
            guard !to.isEmpty else { continue }
            movement.append([
                "kind": "belief_updated",
                "statement": to,
                "from": shift["from"] ?? "",
                "to": to,
                "when": shift["date"] ?? ""
            ])
        }
        for theme in themesRaw {
            guard let moved = theme["moved"] as? String, !moved.isEmpty else { continue }
            let name = theme["theme"] as? String ?? "A theme"
            movement.append([
                "kind": "theme_moved",
                "statement": "\(name) — \(moved)",
                "theme": name,
                "when": theme["last_activity"] as? String ?? ""
            ])
        }
        movement = Array(movement.prefix(4))

        // ---- Workspaces: active themes, hottest + freshest first ----
        let workspaces: [[String: Any]] = themesRaw
            .filter { ($0["state"] as? String) != "archived" }
            .sorted {
                let a = tempRank[$0["temperature"] as? String ?? ""] ?? 9
                let b = tempRank[$1["temperature"] as? String ?? ""] ?? 9
                if a != b { return a < b }
                return ($0["inputs_this_week"] as? Int ?? 0) > ($1["inputs_this_week"] as? Int ?? 0)
            }
            .prefix(6)
            .map { t in
                [
                    "theme": t["theme"] as? String ?? "",
                    "state": t["state"] as? String ?? "",
                    "temperature": t["temperature"] as? String ?? "cooling",
                    "inputs_this_week": t["inputs_this_week"] as? Int ?? 0,
                    "open_questions_count": t["open_questions_count"] as? Int ?? 0,
                    "edge": t["edge"] as? String ?? "",
                    "subtitle": t["subtitle"] as? String ?? ""
                ]
            }

        // ---- Lenses: durable patterns/beliefs, direct instructions + high-confidence first ----
        let patternsOut: [[String: Any]] = patterns
            .sorted {
                if $0.isDirect != $1.isDirect { return $0.isDirect && !$1.isDirect }
                return $0.confidence > $1.confidence
            }
            .prefix(8)
            .map { p in
                [
                    "id": p.id,
                    "type": p.type,
                    "description": p.description,
                    "confidence": p.confidence,
                    "isDirect": p.isDirect,
                    "isStale": p.isStale,
                    "reinforcements": p.reinforcements
                ]
            }

        // ---- Summary (maturity strip) ----
        let summary: [String: Any] = [
            "patterns": patternsOut.count,
            "themes": workspaces.count,
            "beliefs": beliefShifts.count,
            "questions": questions.count,
            "signals_this_week": week.count
        ]

        return [
            "enabled": true,
            "generated_at": ISO8601DateFormatter().string(from: Date()),
            "summary": summary,
            "movement": movement,
            "workspaces": workspaces,
            "questions": questions,
            "lenses": [
                "patterns": patternsOut,
                "belief_shifts": beliefShifts
            ]
        ]
    }
}
