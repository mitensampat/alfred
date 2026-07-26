import Foundation

/// Reads Alfred's durable self-model (SelfModelStore) and shapes the "You" surface.
///
/// Stage 3: the read path now serves FROM the durable `self_facet` store rather than
/// re-synthesizing live each call. It throttle-materializes (at most once/60s) so the
/// surface stays fresh, then applies user verdicts — dismissed/resolved facets are
/// hidden, confirmed facets are flagged. Every register item carries its facet `id`
/// so the UI can call verbs (confirm / dismiss / resolve) against it.
enum SelfModelService {

    private static var lastMaterialize: Date?
    private static let tempRank: [String: Int] = ["hot": 0, "warming": 1, "cooling": 2, "resolved": 3]

    private static func verdict(_ f: [String: Any]) -> String {
        (f["user_verdict"] as? String) ?? ""
    }

    /// Ensure the durable store is populated and reasonably fresh.
    private static func ensureMaterialized(_ store: SelfModelStore) {
        let empty = store.counts().values.reduce(0, +) == 0
        let stale = lastMaterialize.map { Date().timeIntervalSince($0) > 60 } ?? true
        if empty || stale {
            SelfModelSynthesizer.materialize()
            lastMaterialize = Date()
        }
    }

    static func synthesize() -> [String: Any] {
        let store = SelfModelStore.shared
        ensureMaterialized(store)

        // Done workspaces drop out of the active register (they're finished); they remain
        // in the Model browser, reopenable.
        let themeFacets = store.getFacets(kind: "theme").filter { verdict($0) != "dismissed" && verdict($0) != "done" }
        let questionFacets = store.getFacets(kind: "question").filter { verdict($0) != "dismissed" && verdict($0) != "resolved" }
        let beliefFacets = store.getFacets(kind: "belief").filter { verdict($0) != "dismissed" }
        let patternFacets = store.getFacets(kind: "pattern").filter { verdict($0) != "dismissed" }

        // ---- Workspaces (promoted themes, hottest + freshest first) ----
        // The register is a *curated* slice of what's active — the exhaustive, searchable
        // list lives in the Model browser. We surface the top N here and report the true
        // total so the pager can say "…of N · M total, see all in Model" rather than lie.
        let promotedIds = promotedThemeIds(store: store)
        let workspaces: [[String: Any]] = themeFacets
            .filter { promotedIds.contains(($0["id"] as? String) ?? "") }
            .map { f -> [String: Any] in
                let meta = f["metadata"] as? [String: String] ?? [:]
                return [
                    "id": f["id"] as? String ?? "",
                    "theme": f["statement"] as? String ?? "",
                    "state": meta["state"] ?? "",
                    "temperature": meta["temperature"] ?? "cooling",
                    "inputs_this_week": Int(meta["inputs_this_week"] ?? "0") ?? 0,
                    "edge": meta["edge"] ?? "",
                    "verdict": verdict(f),
                    "origin": f["origin"] as? String ?? "emergent",
                    "renamed": (f["renamed"] as? Bool) ?? false,
                    "frequency": Double(meta["frequency"] ?? "0") ?? 0,
                    "recurrence": Int(meta["recurrence"] ?? "0") ?? 0
                ]
            }.sorted {
                // Importance-first: how much a subject recurs (recency-weighted) is the
                // primary signal for which workspaces the curated slice should surface.
                // Temperature breaks ties so an equally-important-but-hotter one leads.
                let fa = $0["frequency"] as? Double ?? 0, fb = $1["frequency"] as? Double ?? 0
                if abs(fa - fb) > 0.001 { return fa > fb }
                let a = tempRank[$0["temperature"] as? String ?? ""] ?? 9
                let b = tempRank[$1["temperature"] as? String ?? ""] ?? 9
                if a != b { return a < b }
                return ($0["inputs_this_week"] as? Int ?? 0) > ($1["inputs_this_week"] as? Int ?? 0)
            }
        let workspacesTotal = workspaces.count
        let workspacesTop = Array(workspaces.prefix(24))

        // ---- Questions ----
        let questions: [[String: Any]] = questionFacets.prefix(6).map { f in
            ["id": f["id"] as? String ?? "", "text": f["statement"] as? String ?? "", "verdict": verdict(f)]
        }

        // ---- Support: what holds a belief up (lenses and decisions, both directions) ----
        var lensIdsByBelief: [String: [String]] = [:]
        var beliefIdsByLens: [String: [String]] = [:]
        var decisionIdsByBelief: [String: [String]] = [:]
        for s in store.allSupport() {
            if s.kind == "decision" {
                decisionIdsByBelief[s.belief, default: []].append(s.support)
            } else {
                lensIdsByBelief[s.belief, default: []].append(s.support)
                beliefIdsByLens[s.support, default: []].append(s.belief)
            }
        }
        let patternById = Dictionary(patternFacets.map { (($0["id"] as? String ?? ""), $0) }, uniquingKeysWith: { a, _ in a })
        let beliefById = Dictionary(beliefFacets.map { (($0["id"] as? String ?? ""), $0) }, uniquingKeysWith: { a, _ in a })

        // ---- Belief lineage: which theme did this belief crystallize from? ----
        var themeIdsByBelief: [String: [String]] = [:]
        for l in store.allLineage() { themeIdsByBelief[l.facet, default: []].append(l.theme) }
        let themeById = Dictionary(themeFacets.map { (($0["id"] as? String ?? ""), $0) }, uniquingKeysWith: { a, _ in a })

        // ---- Beliefs (trajectory, most recently updated first) ----
        let beliefsSorted = beliefFacets.sorted { ($0["last_seen"] as? String ?? "") > ($1["last_seen"] as? String ?? "") }

        // Preserve the contrast. Declared beliefs all land with last_seen = import time,
        // so pure recency would let them crowd out every emergent belief — turning the
        // mirror into a reflection of what you *said* rather than what you *do*. Show a
        // deliberate blend of both.
        let declaredBeliefs = beliefsSorted.filter { ($0["origin"] as? String) == "declared" }
        let emergentBeliefs = beliefsSorted.filter { ($0["origin"] as? String) != "declared" }
        let declaredSlice = declaredBeliefs.prefix(3)
        let emergentSlice = emergentBeliefs.prefix(max(3, 7 - declaredSlice.count))
        let beliefsShown = Array(declaredSlice) + Array(emergentSlice)

        let beliefsOut: [[String: Any]] = beliefsShown.map { f -> [String: Any] in
            let traj = f["trajectory"] as? [[String: String]] ?? []
            let id = f["id"] as? String ?? ""
            let attached: [[String: Any]] = (lensIdsByBelief[id] ?? []).compactMap { lid in
                guard let p = patternById[lid] else { return nil }
                return ["id": lid, "description": p["statement"] as? String ?? ""]
            }
            let lineage: [[String: Any]] = (themeIdsByBelief[id] ?? []).compactMap { tid in
                guard let t = themeById[tid] else { return nil }
                return ["id": tid, "theme": t["statement"] as? String ?? ""]
            }
            let origin = f["origin"] as? String ?? "emergent"
            // Only OBSERVED behaviour can retire an aspiration. Attaching a declared
            // instruction to a declared belief proves nothing — declarations must not
            // be able to validate each other.
            // A decision IS observed behaviour — it happened, at cost — so any decision
            // support retires an aspiration. Declared lenses still can't: a stated
            // instruction cannot validate a stated belief.
            let emergentLensCount = (lensIdsByBelief[id] ?? []).filter {
                ((patternById[$0]?["origin"] as? String) ?? "emergent") != "declared"
            }.count + (decisionIdsByBelief[id] ?? []).count
            return [
                "id": id,
                "from": traj.first?["from"] ?? "",
                "to": f["statement"] as? String ?? "",
                "date": f["last_seen"] as? String ?? "",
                "steps": traj.count,
                "verdict": verdict(f),
                "confirmed": verdict(f) == "confirmed",
                "lenses": attached,
                "origin": origin,
                "aspiration": origin == "declared" && emergentLensCount == 0,
                "themes": lineage
            ]
        }

        // ---- Patterns (direct + high-confidence first) ----
        let patternsOut: [[String: Any]] = patternFacets.sorted {
            let ad = (($0["metadata"] as? [String: String])?["isDirect"] ?? "") == "1"
            let bd = (($1["metadata"] as? [String: String])?["isDirect"] ?? "") == "1"
            if ad != bd { return ad && !bd }
            return ($0["confidence"] as? Double ?? 0) > ($1["confidence"] as? Double ?? 0)
        }.prefix(8).map { f -> [String: Any] in
            let meta = f["metadata"] as? [String: String] ?? [:]
            let id = f["id"] as? String ?? ""
            let attachedTo: [[String: Any]] = (beliefIdsByLens[id] ?? []).compactMap { bid in
                guard let b = beliefById[bid] else { return nil }
                return ["id": bid, "statement": b["statement"] as? String ?? ""]
            }
            return [
                "id": id,
                "type": meta["type"] ?? "",
                "description": f["statement"] as? String ?? "",
                "confidence": f["confidence"] as? Double ?? 0,
                "isDirect": meta["isDirect"] == "1",
                "isStale": (f["status"] as? String) == "fading",
                "reinforcements": Int(meta["reinforcements"] ?? "0") ?? 0,
                "verdict": verdict(f),
                "confirmed": verdict(f) == "confirmed",
                "beliefs": attachedTo,
                "origin": f["origin"] as? String ?? "emergent"
            ]
        }

        // ---- Movement: most recently updated beliefs ----
        // Emergent only — declaring a belief is an import event, not a shift in thinking.
        let movement: [[String: Any]] = emergentBeliefs.prefix(3).map { f -> [String: Any] in
            let traj = f["trajectory"] as? [[String: String]] ?? []
            return [
                "kind": "belief_updated",
                "statement": f["statement"] as? String ?? "",
                "from": traj.first?["from"] ?? "",
                "to": f["statement"] as? String ?? "",
                "when": f["last_seen"] as? String ?? ""
            ]
        }

        let week = ReflectionStore.shared.getWeekInputSummary(days: 7)
        // The header used to count what happened to be rendered — "6 themes" meant six
        // rows below, not 256 in the model. Inventory belongs in Explore; this space
        // should say what is waiting on the user's judgement.
        let pendingProposals = store.getProposals(status: "pending").count
        let unbackedDeclared = beliefFacets.filter { f in
            guard (f["origin"] as? String) == "declared" else { return false }
            let id = f["id"] as? String ?? ""
            let observedLenses = (lensIdsByBelief[id] ?? []).filter {
                ((patternById[$0]?["origin"] as? String) ?? "emergent") != "declared"
            }.count
            return observedLenses + (decisionIdsByBelief[id] ?? []).count == 0
        }.count

        let summary: [String: Any] = [
            "to_review": pendingProposals,
            "unbacked": unbackedDeclared,
            "open_questions": questionFacets.count,
            "signals_this_week": week.count,
            // Retained for any older reader; these are display counts, not model size.
            "patterns": patternsOut.count,
            "themes": workspacesTop.count,
            "beliefs": beliefsOut.count,
            "questions": questions.count
        ]

        // Every belief (not just the surfaced 6) so the assign/move picker can offer them all.
        let allBeliefs: [[String: Any]] = beliefsSorted.map { f in
            ["id": f["id"] as? String ?? "", "statement": f["statement"] as? String ?? ""]
        }

        // Declared values — the slowest-moving thing the user states about themselves.
        let valuesOut: [[String: Any]] = store.getFacets(kind: "value")
            .filter { verdict($0) != "dismissed" }
            .map { f in
                ["id": f["id"] as? String ?? "",
                 "statement": f["statement"] as? String ?? "",
                 "origin": f["origin"] as? String ?? "declared",
                 "renamed": (f["renamed"] as? Bool) ?? false]
            }

        return [
            "enabled": true,
            "durable": true,
            "generated_at": ISO8601DateFormatter().string(from: Date()),
            "summary": summary,
            "movement": movement,
            "workspaces": workspacesTop,
            "workspaces_total": workspacesTotal,
            "questions": questions,
            "lenses": ["patterns": patternsOut, "belief_shifts": beliefsOut],
            "values": valuesOut,
            "all_beliefs": allBeliefs
        ]
    }

    // ───────────── workspace promotion ─────────────

    /// A theme is a WORKSPACE (earned) if it produced a graduated belief or sustained
    /// decision-making. Everything else is a TOPIC — the cheap substrate. A user
    /// override always wins. This is the theme→workspace boundary.
    static let promotionBeliefBar = 1
    static let promotionDecisionBar = 8
    // Frequency path: a subject you keep coming back to is a workspace even before it has
    // produced 8 decisions — recurrence is a direct signal of importance. Guarded by
    // distinct sources so one loud thread can't promote itself.
    static let promotionFrequencyBar = 4.0     // recency-weighted recurrence (Σ 0.5^(age/30d))
    static let promotionSourcesBar = 2

    /// Returns the set of theme *ids* that are workspaces, given produced counts, recurrence,
    /// and overrides.
    static func promotedThemeIds(store: SelfModelStore) -> Set<String> {
        let decisionIds = Set(store.getFacets(kind: "decision").compactMap { $0["id"] as? String })
        let beliefIds = Set(store.getFacets(kind: "belief").compactMap { $0["id"] as? String })
        var dec: [String: Int] = [:], bel: [String: Int] = [:]
        for l in store.allLineage() {
            if decisionIds.contains(l.facet) { dec[l.theme, default: 0] += 1 }
            else if beliefIds.contains(l.facet) { bel[l.theme, default: 0] += 1 }
        }
        let overrides = store.workspaceOverrides()
        var out = Set<String>()
        for t in store.getFacets(kind: "theme") {
            guard let id = t["id"] as? String else { continue }
            if let o = overrides[id] { if o == "promoted" { out.insert(id) }; continue }
            let meta = t["metadata"] as? [String: String] ?? [:]
            let freq = Double(meta["frequency"] ?? "0") ?? 0
            let sources = Int(meta["distinct_sources"] ?? "0") ?? 0
            if (bel[id] ?? 0) >= promotionBeliefBar
                || (dec[id] ?? 0) >= promotionDecisionBar
                || (freq >= promotionFrequencyBar && sources >= promotionSourcesBar) {
                out.insert(id)
            }
        }
        return out
    }

    /// The active workspaces the extractor should attach new activity to, importance-ranked
    /// (recurrence). Names are the resolved display names (canonical where a workspace was
    /// renamed by convergence), so new reflections converge on the durable name rather than
    /// spawning yet another variant. Capped to keep the extraction prompt bounded.
    static func canonicalWorkspaceNames(limit: Int = 45) -> [String] {
        let store = SelfModelStore.shared
        let promoted = promotedThemeIds(store: store)
        let ws = store.getFacets(kind: "theme").filter {
            guard let id = $0["id"] as? String else { return false }
            let v = $0["user_verdict"] as? String
            return promoted.contains(id) && v != "dismissed" && v != "done"
        }
        return ws.sorted {
            let fa = Double(($0["metadata"] as? [String: String])?["frequency"] ?? "0") ?? 0
            let fb = Double(($1["metadata"] as? [String: String])?["frequency"] ?? "0") ?? 0
            return fa > fb
        }.prefix(limit).compactMap { $0["statement"] as? String }.filter { !$0.isEmpty }
    }

    /// Two workspaces describe the same object — token-Jaccard, a touch stricter than
    /// Now's diversify (0.45) since a merge is destructive and proposed, not silent.
    private static let mergeStop: Set<String> = ["the","and","for","with","from","that","this","strategy","management","through","during","and","product","business","model"]
    static func workspacesSimilar(_ a: String, _ b: String) -> Bool {
        func tk(_ s: String) -> Set<String> {
            Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 3 && !mergeStop.contains($0) })
        }
        let ta = tk(a), tb = tk(b)
        guard ta.count >= 2, tb.count >= 2 else { return false }
        let inter = Double(ta.intersection(tb).count)
        let uni = Double(ta.union(tb).count)
        return uni > 0 && inter / uni >= 0.45
    }

    // ───────────── browse (the immersive "You" surface) ─────────────

    /// The whole model, at scale, for exploration — not the curated read path.
    ///
    /// Themes are the navigation spine (they emerge organically); beliefs firm up around
    /// them. Both directions are resolved so the UI can traverse either way: a theme
    /// lists the beliefs that crystallized from it, and a belief lists its source themes
    /// and the lenses that express it.
    static func browse() -> [String: Any] {
        let store = SelfModelStore.shared
        ensureMaterialized(store)

        let themeFacets = store.getFacets(kind: "theme").filter { verdict($0) != "dismissed" }
        let beliefFacets = store.getFacets(kind: "belief").filter { verdict($0) != "dismissed" }
        let patternFacets = store.getFacets(kind: "pattern").filter { verdict($0) != "dismissed" }
        let decisionFacets = store.getFacets(kind: "decision").filter { verdict($0) != "dismissed" }
        let decisionIds = Set(decisionFacets.compactMap { $0["id"] as? String })

        // Links + lineage, both directions.
        var lensIdsByBelief: [String: [String]] = [:]
        var decisionIdsByBelief: [String: [String]] = [:]
        for s in store.allSupport() {
            if s.kind == "decision" { decisionIdsByBelief[s.belief, default: []].append(s.support) }
            else { lensIdsByBelief[s.belief, default: []].append(s.support) }
        }
        var themeIdsByBelief: [String: [String]] = [:]
        var beliefIdsByTheme: [String: [String]] = [:]
        for l in store.allLineage() {
            themeIdsByBelief[l.facet, default: []].append(l.theme)
            beliefIdsByTheme[l.theme, default: []].append(l.facet)
        }
        let patternById = Dictionary(patternFacets.map { (($0["id"] as? String ?? ""), $0) }, uniquingKeysWith: { a, _ in a })
        let beliefById = Dictionary(beliefFacets.map { (($0["id"] as? String ?? ""), $0) }, uniquingKeysWith: { a, _ in a })
        let themeById = Dictionary(themeFacets.map { (($0["id"] as? String ?? ""), $0) }, uniquingKeysWith: { a, _ in a })

        let workspaceIds = promotedThemeIds(store: store)
        let tempRankLocal = tempRank
        let themes: [[String: Any]] = themeFacets.map { f -> [String: Any] in
            let meta = f["metadata"] as? [String: String] ?? [:]
            let id = f["id"] as? String ?? ""
            let born: [[String: Any]] = (beliefIdsByTheme[id] ?? []).compactMap { bid in
                guard let b = beliefById[bid] else { return nil }
                return ["id": bid, "statement": b["statement"] as? String ?? ""]
            }
            let decidedHere = (beliefIdsByTheme[id] ?? []).filter { decisionIds.contains($0) }.count
            return [
                "id": id,
                "theme": f["statement"] as? String ?? "",
                "state": meta["state"] ?? "",
                "temperature": meta["temperature"] ?? "cooling",
                "inputs_this_week": Int(meta["inputs_this_week"] ?? "0") ?? 0,
                "edge": meta["edge"] ?? "",
                "beliefs": born,
                "belief_count": born.count,
                "decision_count": decidedHere,
                "is_workspace": workspaceIds.contains(id),
                "done": verdict(f) == "done",
                "recurrence": Int(meta["recurrence"] ?? "0") ?? 0,
                "frequency": Double(meta["frequency"] ?? "0") ?? 0
            ]
        }.sorted {
            let a = tempRankLocal[$0["temperature"] as? String ?? ""] ?? 9
            let b = tempRankLocal[$1["temperature"] as? String ?? ""] ?? 9
            if a != b { return a < b }
            // then by how much this theme has produced, then recent input
            let ba = $0["belief_count"] as? Int ?? 0, bb = $1["belief_count"] as? Int ?? 0
            if ba != bb { return ba > bb }
            return ($0["inputs_this_week"] as? Int ?? 0) > ($1["inputs_this_week"] as? Int ?? 0)
        }

        let beliefs: [[String: Any]] = beliefFacets.sorted {
            ($0["last_seen"] as? String ?? "") > ($1["last_seen"] as? String ?? "")
        }.map { f -> [String: Any] in
            let id = f["id"] as? String ?? ""
            let traj = f["trajectory"] as? [[String: String]] ?? []
            let lenses: [[String: Any]] = (lensIdsByBelief[id] ?? []).compactMap { lid in
                guard let p = patternById[lid] else { return nil }
                return ["id": lid, "description": p["statement"] as? String ?? ""]
            }
            let lineage: [[String: Any]] = (themeIdsByBelief[id] ?? []).compactMap { tid in
                guard let t = themeById[tid] else { return nil }
                return ["id": tid, "theme": t["statement"] as? String ?? ""]
            }
            let origin = f["origin"] as? String ?? "emergent"
            // Only observed behaviour retires an aspiration (see synthesize()).
            // A decision IS observed behaviour — it happened, at cost — so any decision
            // support retires an aspiration. Declared lenses still can't: a stated
            // instruction cannot validate a stated belief.
            let emergentLensCount = (lensIdsByBelief[id] ?? []).filter {
                ((patternById[$0]?["origin"] as? String) ?? "emergent") != "declared"
            }.count + (decisionIdsByBelief[id] ?? []).count
            return [
                "id": id,
                "statement": f["statement"] as? String ?? "",
                "from": traj.first?["from"] ?? "",
                "steps": traj.count,
                "date": f["last_seen"] as? String ?? "",
                "origin": origin,
                "aspiration": origin == "declared" && emergentLensCount == 0,
                "confirmed": verdict(f) == "confirmed",
                "lenses": lenses,
                "themes": lineage
            ]
        }

        let values: [[String: Any]] = store.getFacets(kind: "value")
            .filter { verdict($0) != "dismissed" }
            .map { ["id": $0["id"] as? String ?? "", "statement": $0["statement"] as? String ?? ""] }

        // Decisions — conclusions reached inside a workspace. Newest first: a decision's
        // meaning is bound to when it was made.
        let decisions: [[String: Any]] = decisionFacets.sorted {
            (($0["metadata"] as? [String: String])?["decided_on"] ?? "") >
            (($1["metadata"] as? [String: String])?["decided_on"] ?? "")
        }.map { f -> [String: Any] in
            let id = f["id"] as? String ?? ""
            let lineage: [[String: Any]] = (themeIdsByBelief[id] ?? []).prefix(2).compactMap { tid in
                guard let t = themeById[tid] else { return nil }
                return ["id": tid, "theme": t["statement"] as? String ?? ""]
            }
            return [
                "id": id,
                "statement": f["statement"] as? String ?? "",
                "date": (f["metadata"] as? [String: String])?["decided_on"] ?? "",
                "confirmed": verdict(f) == "confirmed",
                "themes": lineage
            ]
        }

        return [
            "enabled": true,
            "counts": [
                "themes": themes.count,
                "decisions": decisions.count,
                "beliefs": beliefs.count,
                "lenses": patternFacets.count,
                "values": values.count,
                "lineage": store.allLineage().count,
                "proposals": store.getProposals(status: "pending").count,
                "reflections": (ReflectionStore.shared.getStats()["total_reflections"] as? Int) ?? 0
            ],
            "themes": themes,
            "decisions": decisions,
            "beliefs": beliefs,
            "values": values
        ]
    }

    /// One facet plus every edge touching it, resolved to {id,kind,statement} so the
    /// UI can render each as a link and walk the graph. Only real edges are returned
    /// (lineage + support, both directions) — sources aren't facets, so a decision
    /// doesn't fake a source link it doesn't have.
    static func facetDetail(id: String) -> [String: Any]? {
        let store = SelfModelStore.shared
        guard let f = store.getFacet(id: id) else { return nil }
        let kind = (f["kind"] as? String) ?? ""

        // Resolve helpers
        func node(_ fid: String) -> [String: Any]? {
            guard let n = store.getFacet(id: fid) else { return nil }
            return ["id": fid, "kind": n["kind"] as? String ?? "", "statement": n["statement"] as? String ?? ""]
        }
        let lineage = store.allLineage()      // (facet, theme)
        let support = store.allSupport()      // (support, belief, kind)

        var edges: [String: Any] = [:]
        switch kind {
        case "belief":
            edges["from"] = lineage.filter { $0.facet == id }.compactMap { node($0.theme) }
            edges["grounded_by"] = support.filter { $0.belief == id }.compactMap { node($0.support) }
        case "decision":
            edges["decided_in"] = lineage.filter { $0.facet == id }.compactMap { node($0.theme) }
            edges["grounds"] = support.filter { $0.support == id }.compactMap { node($0.belief) }
        case "theme":
            let facetsHere = lineage.filter { $0.theme == id }.map { $0.facet }
            edges["produced_decisions"] = facetsHere.compactMap { node($0) }.filter { ($0["kind"] as? String) == "decision" }
            edges["produced_beliefs"] = facetsHere.compactMap { node($0) }.filter { ($0["kind"] as? String) == "belief" }
        case "pattern":
            edges["supports"] = support.filter { $0.support == id }.compactMap { node($0.belief) }
        default: break
        }

        let origin = (f["origin"] as? String) ?? "emergent"
        let traj = f["trajectory"] as? [[String: String]] ?? []
        return [
            "id": id, "kind": kind,
            "statement": f["statement"] as? String ?? "",
            "origin": origin,
            "verdict": verdict(f),
            "from_shift": traj.first?["from"] ?? "",
            "date": (f["metadata"] as? [String: String])?["decided_on"] ?? (f["last_seen"] as? String ?? ""),
            "edges": edges
        ]
    }

    // ───────────── callable verbs ─────────────

    /// Confirm / dismiss a facet (the "you are the final editor" tenet).
    static func setVerdict(id: String, verdict: String?) -> Bool {
        return SelfModelStore.shared.setVerdict(id: id, verdict: verdict)
    }

    /// Resolve an open question into a durable belief: marks the question resolved
    /// (hidden from the surface) and mints a belief facet from the resolution text.
    /// Returns the minted belief id, or nil on failure.
    static func resolveQuestion(id: String, resolution: String) -> String? {
        let store = SelfModelStore.shared
        guard let q = store.getFacet(id: id) else { return nil }
        let questionText = q["statement"] as? String ?? ""
        let now = ISO8601DateFormatter().string(from: Date())
        let beliefId = SelfModelSynthesizer.stableId("belief_minted", resolution + "|" + questionText)
        let ok = store.upsertFacet(
            id: beliefId, kind: "belief", statement: resolution, confidence: 0.8,
            status: "active", firstSeen: now, lastSeen: now,
            trajectory: [["from": "open question: \(questionText)", "to": resolution, "date": now]],
            evidence: [], metadata: ["minted": "1", "from_question": questionText])
        guard ok else { return nil }
        _ = store.setVerdict(id: id, verdict: "resolved")
        return beliefId
    }

    /// A single belief to surface on the Now surface — the most recently updated,
    /// non-dismissed belief. Closes the You→Now loop. Returns nil if none.
    static func nowCard() -> [String: Any]? {
        let store = SelfModelStore.shared
        ensureMaterialized(store)
        let beliefs = store.getFacets(kind: "belief")
            .filter { verdict($0) != "dismissed" }
            .sorted { ($0["last_seen"] as? String ?? "") > ($1["last_seen"] as? String ?? "") }
        guard let f = beliefs.first else { return nil }
        let traj = f["trajectory"] as? [[String: String]] ?? []
        return [
            "id": f["id"] as? String ?? "",
            "belief": f["statement"] as? String ?? "",
            "from": traj.first?["from"] ?? "",
            "when": f["last_seen"] as? String ?? "",
            "confirmed": verdict(f) == "confirmed"
        ]
    }
}
