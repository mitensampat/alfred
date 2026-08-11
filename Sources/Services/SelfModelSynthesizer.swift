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

    /// Stable, deterministic facet id from a prefix + text. Used by callers that
    /// mint facets outside the materialize pass (e.g. resolving a question → belief).
    static func stableId(_ prefix: String, _ text: String) -> String {
        return "\(prefix)_" + fnv1a(text)
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

    /// Only one materialize may run at a time. Two concurrent runs deadlock: beginBulk
    /// holds dbLock while acquiring the SQLite write-lock, so A-holds-write / B-holds-dbLock
    /// cross-wait. A concurrent caller returns the last counts rather than piling up.
    private static let materializeLock = NSLock()
    private static var lastCounts: [String: Int] = [:]

    /// Run `work` on a background queue and return its result, or nil if it doesn't
    /// finish within `seconds`. Used to keep materialize from hanging on a contended
    /// dependency (the learning service holding its lock during LLM calls).
    private static func withTimeout<T>(seconds: Double, _ work: @escaping () -> T) -> T? {
        let sem = DispatchSemaphore(value: 0)
        var result: T?
        DispatchQueue.global().async { result = work(); sem.signal() }
        return sem.wait(timeout: .now() + seconds) == .success ? result : nil
    }

    /// Materialize all facets. Returns per-kind counts after the run.
    @discardableResult
    static func materialize() -> [String: Int] {
        guard materializeLock.try() else { return lastCounts }
        defer { materializeLock.unlock() }
        let store = ReflectionStore.shared
        let facets = SelfModelStore.shared
        let now = ISO8601DateFormatter().string(from: Date())

        // ---- Themes ----
        // Materialize broadly (the store is the substrate); the read path curates what's
        // shown. A wide theme layer is also what gives belief lineage something to attach to.
        for t in store.getThemesWithState(days: 180, limit: 250) {
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
                           "edge": t["edge"] as? String ?? "",
                           // Frequency signal — how much this subject actually recurs, and how broadly.
                           "frequency": String(format: "%.3f", t["frequency"] as? Double ?? 0),
                           "recurrence": String(t["recurrence"] as? Int ?? 0),
                           "distinct_sources": String(t["distinct_sources"] as? Int ?? 0)]
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
        // getLearnedPatterns takes WorkflowLearningService's lock, which computeLearnedPatterns
        // holds during (sometimes hanging) LLM calls. Bound the wait so materialize — and thus
        // the whole You/Now surface — never hangs waiting on the learning service.
        let learnedPatterns = withTimeout(seconds: 3) { WorkflowLearningService.shared.getLearnedPatterns() } ?? []
        for p in learnedPatterns where !p.isArchived && p.type != "user_context" {
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

        // ---- Decisions ----
        materializeDecisions()

        // ---- Lineage ----
        backfillLineage()

        lastCounts = facets.counts()
        return lastCounts
    }

    /// Promote extracted decisions into first-class facets.
    ///
    /// A decision is a conclusion reached inside a workspace — dated, final, and the
    /// closest thing in the model to a record of judgement. They already exist in
    /// `decisions_json`; this only promotes them, no new extraction.
    @discardableResult
    static func materializeDecisions() -> Int {
        let store = SelfModelStore.shared
        let reflections = ReflectionStore.shared.getRecentReflections(limit: 2000, days: 400)
        let themeIds = Set(store.getFacets(kind: "theme", includeArchived: true).compactMap { $0["id"] as? String })

        var seen = Set<String>()
        var pending: [(id: String, text: String, date: String, owner: String?)] = []

        for r in reflections {
            guard let decisions = r["decisions"] as? [String], !decisions.isEmpty else { continue }
            let created = (r["created_at"] as? String) ?? ""
            let date = created.count >= 10 ? String(created.prefix(10)) : created
            let themes = (r["themes"] as? [String]) ?? []
            let itemThemes = (r["item_themes"] as? [String: String]) ?? [:]

            for raw in decisions {
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                // One-liners with no content aren't judgements. Everything else stands —
                // the extracted set is clean (1 of 1,138 under this bar).
                guard text.count >= 25 else { continue }
                let id = stableId("decision", text)
                guard !seen.contains(id) else { continue }
                seen.insert(id)
                pending.append((id: id, text: text, date: date, owner: owningTheme(text, itemThemes: itemThemes, among: themes)))
            }
        }
        guard !pending.isEmpty else { return 0 }

        store.beginBulk()
        for d in pending {
            _ = store.upsertFacet(
                id: d.id, kind: "decision", statement: d.text,
                confidence: 1.0,                       // a decision happened; it isn't inferred
                status: "active", firstSeen: d.date, lastSeen: d.date,
                trajectory: [],
                evidence: [["source_type": "reflection", "snippet": d.text, "ts": d.date]],
                metadata: ["decided_on": d.date],
                origin: "emergent"
            )
            // Attach to the ONE owning theme, not every theme the conversation touched.
            if let owner = d.owner {
                let tid = stableId("theme", owner)
                if themeIds.contains(tid) { _ = store.linkFacetToTheme(facetId: d.id, themeId: tid) }
            }
        }
        store.endBulk()
        return pending.count
    }

    /// The single workspace an item belongs to: the LLM's per-item tag if present, else the
    /// deterministic best-fit among the reflection's own themes. Never "all of them".
    static func owningTheme(_ text: String, itemThemes: [String: String], among themes: [String]) -> String? {
        if let t = itemThemes[text], !t.isEmpty { return t }
        if themes.count <= 1 { return themes.first }
        return ReflectionStore.bestFitTheme(text, among: themes)
    }

    /// Link each belief back to the theme(s) it crystallized from.
    ///
    /// A reflection carries BOTH its themes and its mental-model shifts, so a belief
    /// extracted from that reflection inherits its themes as ancestry. Idempotent
    /// (INSERT OR IGNORE + deterministic ids), so this both backfills existing beliefs
    /// and keeps lineage current for new ones.
    @discardableResult
    static func backfillLineage() -> Int {
        let store = SelfModelStore.shared
        let themeIds = Set(store.getFacets(kind: "theme", includeArchived: true).compactMap { $0["id"] as? String })
        let beliefIds = Set(store.getFacets(kind: "belief", includeArchived: true).compactMap { $0["id"] as? String })
        guard !themeIds.isEmpty, !beliefIds.isEmpty else { return 0 }

        // Wide window — lineage is historical, not recent-only.
        let reflections = ReflectionStore.shared.getRecentReflections(limit: 2000, days: 400)
        for r in reflections {
            guard let shifts = r["mental_model_shifts"] as? [[String: String]], !shifts.isEmpty,
                  let themes = r["themes"] as? [String], !themes.isEmpty else { continue }
            let itemThemes = (r["item_themes"] as? [String: String]) ?? [:]
            for shift in shifts {
                let to = shift["to"] ?? ""
                guard !to.isEmpty else { continue }
                // Belief ids are derived from the shift that opened the chain.
                let beliefId = stableId("belief", (shift["from"] ?? "") + "|" + to)
                guard beliefIds.contains(beliefId) else { continue }
                // Attach to the ONE owning theme (LLM tag → best-fit), not every reflection theme.
                if let owner = owningTheme(to, itemThemes: itemThemes, among: themes) {
                    let themeId = stableId("theme", owner)
                    if themeIds.contains(themeId) { _ = store.linkFacetToTheme(facetId: beliefId, themeId: themeId) }
                }
            }
        }
        return store.allLineage().count
    }
}
