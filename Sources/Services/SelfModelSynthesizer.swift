import Foundation

/// Stage 2 — materializes the durable self-model.
///
/// Reads the same live sources as `SelfModelService` and writes them into
/// `SelfModelStore` as durable `self_facet` rows with STABLE ids, so re-runs
/// upsert-in-place rather than duplicate. Its distinguishing job is **trajectory
/// chaining**: belief shifts (`{from,to}`) that continue one another are linked
/// into a single belief facet whose trajectory is the ordered chain — this is
/// what turns "a shift happened" into "this belief evolved".
///
/// Fully deterministic: same inputs → same facet ids, statements, and chains.
/// It never calls an LLM.
enum SelfModelSynthesizer {

    /// Deterministic (seed-independent) hash for stable facet ids across process runs.
    /// Swift's String.hashValue is randomized per-process, so we can't use it here.
    private static func fnv1a(_ s: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    private static func tokens(_ s: String) -> Set<String> {
        Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 3 })
    }

    /// Two belief statements "continue" one another if they share enough salient tokens.
    private static func fuzzyMatch(_ a: String, _ b: String) -> Bool {
        let ta = tokens(a), tb = tokens(b)
        guard !ta.isEmpty, !tb.isEmpty else { return false }
        let overlap = Double(ta.intersection(tb).count) / Double(min(ta.count, tb.count))
        return overlap >= 0.6
    }

    /// Materialize all facets. Returns per-kind counts after the run.
    @discardableResult
    static func materialize() -> [String: Int] {
        let store = ReflectionStore.shared
        let facets = SelfModelStore.shared
        let now = ISO8601DateFormatter().string(from: Date())

        // ---- Themes ----
        for t in store.getThemesWithState(days: 60, limit: 20) {
            guard let name = t["theme"] as? String, !name.isEmpty else { continue }
            let state = t["state"] as? String ?? "researching"
            if state == "archived" { continue }
            let temp = t["temperature"] as? String ?? "cooling"
            let conf = temp == "hot" ? 0.9 : (temp == "warming" ? 0.7 : 0.5)
            _ = facets.upsertFacet(
                id: "theme_" + fnv1a(name), kind: "theme", statement: name,
                confidence: conf, status: "active",
                firstSeen: t["first_seen"] as? String ?? now,
                lastSeen: t["last_activity"] as? String ?? now,
                trajectory: [], evidence: [],
                metadata: ["temperature": temp, "state": state,
                           "inputs_this_week": String(t["inputs_this_week"] as? Int ?? 0),
                           "edge": t["edge"] as? String ?? ""]
            )
        }

        // ---- Questions ----
        for q in store.getOpenQuestions(limit: 12) where !q.isEmpty {
            _ = facets.upsertFacet(
                id: "question_" + fnv1a(q), kind: "question", statement: q,
                confidence: 0.5, status: "active", firstSeen: now, lastSeen: now,
                trajectory: [], evidence: [], metadata: [:])
        }

        // ---- Patterns (durable preferences/instructions; skip journal-like context) ----
        for p in WorkflowLearningService.shared.getLearnedPatterns() where !p.isArchived && p.type != "user_context" {
            _ = facets.upsertFacet(
                id: "pattern_" + p.id, kind: "pattern", statement: p.description,
                confidence: p.confidence, status: p.isStale ? "fading" : "active",
                firstSeen: nil, lastSeen: p.lastReinforced, trajectory: [], evidence: [],
                metadata: ["type": p.type, "isDirect": p.isDirect ? "1" : "0",
                           "reinforcements": String(p.reinforcements)])
        }

        // ---- Beliefs (trajectory chaining) ----
        // Build chains deterministically in memory (oldest-first), then upsert each chain
        // as ONE belief facet. This keeps the whole pass idempotent — no reliance on
        // prior DB state, so re-running produces identical chains rather than appending.
        let ordered: [[String: String]] = store.getRecentBeliefShifts(days: 180, limit: 40)
            .reversed()  // getRecentBeliefShifts is newest-first
            .map { ["from": $0["from"] ?? "", "to": $0["to"] ?? "", "date": $0["date"] ?? now] }

        var chains: [[[String: String]]] = []
        for shift in ordered {
            guard let to = shift["to"], !to.isEmpty else { continue }
            let from = shift["from"] ?? ""
            if let idx = chains.firstIndex(where: { fuzzyMatch($0.last?["to"] ?? "", from) }) {
                chains[idx].append(shift)
            } else {
                chains.append([shift])
            }
        }
        for chain in chains {
            guard let first = chain.first, let last = chain.last else { continue }
            let id = "belief_" + fnv1a((first["from"] ?? "") + "|" + (first["to"] ?? ""))
            let conf = min(1.0, 0.55 + 0.1 * Double(chain.count))
            _ = facets.upsertFacet(
                id: id, kind: "belief", statement: last["to"] ?? "", confidence: conf,
                status: "active", firstSeen: first["date"], lastSeen: last["date"],
                trajectory: chain, evidence: [], metadata: ["shift_count": String(chain.count)])
        }

        return facets.counts()
    }
}
