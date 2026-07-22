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

        let themeFacets = store.getFacets(kind: "theme").filter { verdict($0) != "dismissed" }
        let questionFacets = store.getFacets(kind: "question").filter { verdict($0) != "dismissed" && verdict($0) != "resolved" }
        let beliefFacets = store.getFacets(kind: "belief").filter { verdict($0) != "dismissed" }
        let patternFacets = store.getFacets(kind: "pattern").filter { verdict($0) != "dismissed" }

        // ---- Workspaces (theme facets, hottest + freshest first) ----
        let workspaces: [[String: Any]] = themeFacets.map { f -> [String: Any] in
            let meta = f["metadata"] as? [String: String] ?? [:]
            return [
                "id": f["id"] as? String ?? "",
                "theme": f["statement"] as? String ?? "",
                "state": meta["state"] ?? "",
                "temperature": meta["temperature"] ?? "cooling",
                "inputs_this_week": Int(meta["inputs_this_week"] ?? "0") ?? 0,
                "edge": meta["edge"] ?? "",
                "verdict": verdict(f)
            ]
        }.sorted {
            let a = tempRank[$0["temperature"] as? String ?? ""] ?? 9
            let b = tempRank[$1["temperature"] as? String ?? ""] ?? 9
            if a != b { return a < b }
            return ($0["inputs_this_week"] as? Int ?? 0) > ($1["inputs_this_week"] as? Int ?? 0)
        }
        let workspacesTop = Array(workspaces.prefix(6))

        // ---- Questions ----
        let questions: [[String: Any]] = questionFacets.prefix(6).map { f in
            ["id": f["id"] as? String ?? "", "text": f["statement"] as? String ?? "", "verdict": verdict(f)]
        }

        // ---- Lens ↔ belief links (many-to-many, browsable from either side) ----
        let links = store.allLinks()
        var lensIdsByBelief: [String: [String]] = [:]
        var beliefIdsByLens: [String: [String]] = [:]
        for l in links {
            lensIdsByBelief[l.belief, default: []].append(l.lens)
            beliefIdsByLens[l.lens, default: []].append(l.belief)
        }
        let patternById = Dictionary(patternFacets.map { (($0["id"] as? String ?? ""), $0) }, uniquingKeysWith: { a, _ in a })
        let beliefById = Dictionary(beliefFacets.map { (($0["id"] as? String ?? ""), $0) }, uniquingKeysWith: { a, _ in a })

        // ---- Belief lineage: which theme did this belief crystallize from? ----
        var themeIdsByBelief: [String: [String]] = [:]
        for l in store.allLineage() { themeIdsByBelief[l.belief, default: []].append(l.theme) }
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
            let emergentLensCount = (lensIdsByBelief[id] ?? []).filter {
                ((patternById[$0]?["origin"] as? String) ?? "emergent") != "declared"
            }.count
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
        let summary: [String: Any] = [
            "patterns": patternsOut.count,
            "themes": workspacesTop.count,
            "beliefs": beliefsOut.count,
            "questions": questions.count,
            "signals_this_week": week.count
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
                 "origin": f["origin"] as? String ?? "declared"]
            }

        return [
            "enabled": true,
            "durable": true,
            "generated_at": ISO8601DateFormatter().string(from: Date()),
            "summary": summary,
            "movement": movement,
            "workspaces": workspacesTop,
            "questions": questions,
            "lenses": ["patterns": patternsOut, "belief_shifts": beliefsOut],
            "values": valuesOut,
            "all_beliefs": allBeliefs
        ]
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

        // Links + lineage, both directions.
        var lensIdsByBelief: [String: [String]] = [:]
        for l in store.allLinks() { lensIdsByBelief[l.belief, default: []].append(l.lens) }
        var themeIdsByBelief: [String: [String]] = [:]
        var beliefIdsByTheme: [String: [String]] = [:]
        for l in store.allLineage() {
            themeIdsByBelief[l.belief, default: []].append(l.theme)
            beliefIdsByTheme[l.theme, default: []].append(l.belief)
        }
        let patternById = Dictionary(patternFacets.map { (($0["id"] as? String ?? ""), $0) }, uniquingKeysWith: { a, _ in a })
        let beliefById = Dictionary(beliefFacets.map { (($0["id"] as? String ?? ""), $0) }, uniquingKeysWith: { a, _ in a })
        let themeById = Dictionary(themeFacets.map { (($0["id"] as? String ?? ""), $0) }, uniquingKeysWith: { a, _ in a })

        let tempRankLocal = tempRank
        let themes: [[String: Any]] = themeFacets.map { f -> [String: Any] in
            let meta = f["metadata"] as? [String: String] ?? [:]
            let id = f["id"] as? String ?? ""
            let born: [[String: Any]] = (beliefIdsByTheme[id] ?? []).compactMap { bid in
                guard let b = beliefById[bid] else { return nil }
                return ["id": bid, "statement": b["statement"] as? String ?? ""]
            }
            return [
                "id": id,
                "theme": f["statement"] as? String ?? "",
                "state": meta["state"] ?? "",
                "temperature": meta["temperature"] ?? "cooling",
                "inputs_this_week": Int(meta["inputs_this_week"] ?? "0") ?? 0,
                "edge": meta["edge"] ?? "",
                "beliefs": born,
                "belief_count": born.count
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
            let emergentLensCount = (lensIdsByBelief[id] ?? []).filter {
                ((patternById[$0]?["origin"] as? String) ?? "emergent") != "declared"
            }.count
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

        return [
            "enabled": true,
            "counts": [
                "themes": themes.count,
                "beliefs": beliefs.count,
                "lenses": patternFacets.count,
                "values": values.count,
                "lineage": store.allLineage().count
            ],
            "themes": themes,
            "beliefs": beliefs,
            "values": values
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
