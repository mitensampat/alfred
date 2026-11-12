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
///                ("Acme's right to win is pure distribution.")
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

    // ── Model classifier ──────────────────────────────────────────────────────────
    /// How a durability tag was arrived at. Only `heuristic` and `model` are verdicts;
    /// `fallback` means nothing actually decided and the answer is a safe default.
    ///
    /// This distinction is the fix for a real defect: the promotion path asked only the
    /// heuristic, took its `nil` ("unsure") as `durable`, and stamped a tag + hash beside it —
    /// which told the nightly pass the statement was already classified. A coaching nudge became
    /// a permanent "durable principle" at the top of the Wiki. Callers now store a tag only when
    /// something decided it, so a default stays retryable instead of becoming a verdict.
    typealias Verdict = (durability: BeliefDurability, source: String)

    /// Classify statements via the `belief-durability` decision (~/.alfred/decisions/),
    /// reporting how each answer was reached.
    static func classifySourced(_ statements: [String]) async -> [String: Verdict] {
        var out: [String: Verdict] = [:]
        guard !statements.isEmpty else { return out }

        // Heuristic pre-pass — free, and shrinks the model batch.
        var needModel: [String] = []
        for s in statements {
            if let h = heuristic(s) { out[s] = (h, "heuristic") } else { needModel.append(s) }
        }
        guard !needModel.isEmpty else { return out }

        let decided = await DecisionEngine.decide(
            "belief-durability", items: needModel.map { DecisionEngine.Item(key: $0, text: $0) })
        for s in needModel {
            guard let d = decided[s], let cls = BeliefDurability(rawValue: d.label) else {
                out[s] = (modelFallback, "fallback")
                continue
            }
            // fact/action get archived out of the active set, so only take that call when the
            // model is confident enough to act; a hedged "fact" stays a belief.
            out[s] = (cls.isBelief || d.tier == .act) ? (cls, "model") : (modelFallback, "fallback")
        }
        return out
    }

    /// Classify a single statement. Used on the promotion path, where one statement is cheap to
    /// ask about and guessing is what caused the defect described above.
    static func classifyOne(_ s: String) async -> Verdict {
        await classifySourced([s])[s] ?? (modelFallback, "fallback")
    }

    /// The decision file's own Fallback, so editing `belief-durability.md` actually changes what
    /// an unclassified statement becomes. Only a belief class is honoured: a fallback of fact or
    /// action would archive everything the model skipped, and nothing should leave the
    /// self-model untouched.
    static var modelFallback: BeliefDurability {
        DecisionEngine.fallbackLabel("belief-durability")
            .flatMap(BeliefDurability.init(rawValue:))
            .flatMap { $0.isBelief ? $0 : nil } ?? .durable
    }
}
