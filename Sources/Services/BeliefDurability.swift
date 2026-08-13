import Foundation

/// Classifies a self-model "belief" statement by how durable it is. The self-model's belief
/// extraction is loose — it turns thread-level shifts into "beliefs" at a flat confidence, so
/// the belief set ends up mixing genuine operating principles with situational reads, past
/// events, and even coaching nudges. This tag is the gate that keeps the Model (and the Wiki)
/// holding the right set:
///
///   • durable  — a general principle about how you operate/decide/lead. True across
///                situations, people, and quarters. ("CEO command of strategy + detail first.")
///   • tactical — a current thesis/read on a specific business, metric, or market. Legitimately
///                part of how you're thinking now, but could flip next quarter.
///                ("Kuvera's right to win is pure distribution.")
///   • fact     — a past event, status, or arrangement. Something that happened or is in place —
///                not a belief at all. ("Secured 100% bank funding for Q2.")
///   • action   — an instruction, todo, or nudge. Tells someone to do something.
///                ("Mute the group immediately and set read-only hours.")
///
/// Rule the rest of the system applies: **beliefs = durable + tactical.** `fact` and `action`
/// are not beliefs and get archived out of the active set.
enum BeliefDurability: String {
    case durable, tactical, fact, action

    var isBelief: Bool { self == .durable || self == .tactical }

    // ── Fast deterministic pre-filter ─────────────────────────────────────────────
    // Catches the egregious cases (imperative nudges, dated facts) with no LLM cost, and
    // is the fallback whenever the model is unavailable. Returns nil when genuinely unsure —
    // the caller then defers to the LLM pass (or treats unknown as durable, never dropping).
    static func heuristic(_ raw: String) -> BeliefDurability? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count > 4 else { return nil }
        let lower = s.lowercased()
        let firstWord = lower.split(whereSeparator: { $0 == " " || $0 == "," }).first.map(String.init) ?? ""

        // Action: opens with an imperative, or carries a do-it-now marker.
        let imperatives: Set<String> = [
            "mute", "set", "send", "call", "reply", "watch", "stop", "start", "block",
            "schedule", "add", "remove", "drop", "close", "confirm", "check", "ping",
            "message", "ask", "tell", "review", "prioritize", "prioritise", "escalate",
            "follow", "chase", "book", "cut", "kill", "avoid", "don't", "dont", "make"
        ]
        if imperatives.contains(firstWord) { return .action }
        for marker in [" immediately", "read-only hours", "reclaim attention", " asap", "right away"] {
            if lower.contains(marker) { return .action }
        }

        // Fact: a completed past event with a concrete figure/date — a status, not a stance.
        let pastEvent = ["secured ", "closed ", "raised ", "signed ", "hired ", "fired ",
                         "launched ", "shipped ", "acquired ", "agreed ", "departed", "departure"]
        let hasFigure = lower.range(of: "[₹$]?[0-9]+ ?(cr|crore|m|k|%|bn|million)", options: .regularExpression) != nil
        for p in pastEvent where lower.contains(p) {
            if hasFigure || lower.contains(" for q") || lower.contains(" in q") { return .fact }
        }

        return nil   // unsure — let the LLM decide (or default to durable)
    }

    /// A stable hash of the statement, so the nightly pass only re-classifies beliefs whose
    /// text actually changed rather than paying for the LLM every night.
    static func hash(_ s: String) -> String {
        var h: UInt64 = 1469598103934665603
        for b in s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().utf8 {
            h = (h ^ UInt64(b)) &* 1099511628211
        }
        return String(h, radix: 16)
    }

    // ── LLM batch classifier ──────────────────────────────────────────────────────
    /// Classify many statements in one Haiku call. Anything the model can't be coaxed to
    /// return falls back to the heuristic, and unknowns default to `.durable` (we never silently
    /// drop a belief — worst case it stays in "what you believe" until the user dismisses it).
    static func classify(_ statements: [String]) async -> [String: BeliefDurability] {
        var out: [String: BeliefDurability] = [:]
        guard !statements.isEmpty else { return out }

        // Heuristic pre-pass — free, and shrinks the LLM batch.
        var needLLM: [String] = []
        for s in statements {
            if let h = heuristic(s) { out[s] = h } else { needLLM.append(s) }
        }
        guard !needLLM.isEmpty else { return out }

        let numbered = needLLM.enumerated().map { "\($0.offset): \($0.element)" }.joined(separator: "\n")
        let prompt = """
        You are sorting statements from a CEO's self-model. Classify EACH by durability:

        - durable: a general principle about how they operate, decide, or lead — true across situations, people, and quarters (e.g. "CEO should command strategy and detail first, then let the team fill blanks").
        - tactical: a current thesis or read on a specific business, metric, or market — legitimate now but could flip next quarter (e.g. "Kuvera's right to win is pure distribution").
        - fact: a past event, status, or arrangement — something that happened or is in place, not a stance (e.g. "Secured 100% bank funding for Q2").
        - action: an instruction, todo, or nudge that tells someone to do something (e.g. "Mute the group and set read-only hours").

        Statements:
        \(numbered)

        Return ONLY a JSON array like [{"i":0,"c":"durable"},{"i":1,"c":"fact"}] — one object per statement, no prose.
        """

        guard let cfg = AppConfig.load() else {
            for s in needLLM { out[s] = heuristic(s) ?? .durable }
            return out
        }
        do {
            let resp = try await ClaudeAIService(config: cfg.ai).generateText(prompt: prompt, maxTokens: 1024, useModel: "claude-haiku-4-5-20251001")
            if let json = extractJSONArray(resp)?.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: json) as? [[String: Any]] {
                for row in arr {
                    guard let i = (row["i"] as? Int) ?? (row["i"] as? NSNumber)?.intValue,
                          i >= 0, i < needLLM.count,
                          let c = (row["c"] as? String)?.lowercased(),
                          let cls = BeliefDurability(rawValue: c) else { continue }
                    out[needLLM[i]] = cls
                }
            }
        } catch {
            // Model unavailable — leave the LLM batch to the default below.
        }

        for s in needLLM where out[s] == nil { out[s] = .durable }   // never drop a belief
        return out
    }

    private static func extractJSONArray(_ s: String) -> String? {
        guard let start = s.firstIndex(of: "["), let end = s.lastIndex(of: "]"), start < end else { return nil }
        return String(s[start...end])
    }
}
