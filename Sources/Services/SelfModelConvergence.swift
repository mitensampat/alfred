import Foundation

/// Converges fragmented themes into their true workspaces.
///
/// The extractor mints a fresh theme per angle of a subject ("CCBP MTU decline",
/// "CCBP TPV underperformance", "CCBP user churn"…) so one workspace shatters into
/// many. Lexical (token-Jaccard) merge detection is blind to this — the titles share
/// the *subject* but almost no words. So we cluster by *meaning*: one LLM pass groups
/// the titles into subjects, and each cluster flat-merges into a single workspace, its
/// angles surviving as that workspace's decisions and questions.
///
/// Fragmentation also HIDES importance: a 19-conversation subject split into seven
/// fragments looks like seven trivial ones. Converge first, then count frequency.
///
/// Autonomy is tiered on the model's own confidence: `high` clusters auto-apply; `medium`
/// and `low` are held for a one-click confirm — because a dry-run proved fully-automatic
/// merging makes a handful of real errors (a behavioural pattern swallowed into a project,
/// two distinct subjects joined on a shared domain). Every applied merge is reversible.
enum SelfModelConvergence {

    struct Cluster {
        let canonicalName: String
        let confidence: String       // high | medium | low
        let survivorId: String
        let survivorName: String
        let memberIds: [String]      // losers merged into survivor; excludes survivor
        let memberNames: [String]
    }

    private static let confRank = ["high": 0, "medium": 1, "low": 2]

    // MARK: - Dry run (no writes)

    static func dryRun() async -> (clusters: [Cluster], themeCount: Int) {
        let store = SelfModelStore.shared
        let themes = store.getFacets(kind: "theme").filter {
            let v = $0["user_verdict"] as? String
            return v != "dismissed" && v != "done"
        }
        guard themes.count > 1 else { return ([], themes.count) }

        let decisionIds = Set(store.getFacets(kind: "decision").compactMap { $0["id"] as? String })
        let beliefIds = Set(store.getFacets(kind: "belief").compactMap { $0["id"] as? String })
        var dec: [String: Int] = [:], bel: [String: Int] = [:]
        for l in store.allLineage() {
            if decisionIds.contains(l.facet) { dec[l.theme, default: 0] += 1 }
            else if beliefIds.contains(l.facet) { bel[l.theme, default: 0] += 1 }
        }

        struct Row { let idx: Int; let id: String; let name: String }
        let rows: [Row] = themes.enumerated().map { (i, f) in
            Row(idx: i + 1, id: f["id"] as? String ?? "", name: f["statement"] as? String ?? "")
        }
        let idByIdx = Dictionary(uniqueKeysWithValues: rows.map { ($0.idx, $0.id) })
        let nameByIdx = Dictionary(uniqueKeysWithValues: rows.map { ($0.idx, $0.name) })

        let listing = rows.map { r -> String in
            "\(r.idx). \(r.name)  [\(dec[r.id] ?? 0) decisions, \(bel[r.id] ?? 0) beliefs]"
        }.joined(separator: "\n")

        guard let config = AppConfig.load() else { return ([], themes.count) }
        let svc = ClaudeAIService(config: config.ai, userName: config.user.name)
        guard let raw = try? await svc.generateText(prompt: "Themes (index. title [signals]):\n\(listing)",
                                                    system: systemPrompt, maxTokens: 4000),
              let data = extractJSON(raw)?.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawClusters = obj["clusters"] as? [[String: Any]] else {
            return ([], themes.count)
        }

        // Parse.
        var parsed: [Cluster] = []
        for c in rawClusters {
            guard let members = (c["members"] as? [Any])?.compactMap({ ($0 as? Int) ?? Int("\($0)") }) else { continue }
            let valid = Array(Set(members.filter { idByIdx[$0] != nil }))
            guard valid.count >= 2 else { continue }
            let survivorIdx = (c["survivor"] as? Int).flatMap { valid.contains($0) ? $0 : nil } ?? valid[0]
            let conf = (c["confidence"] as? String).map { $0.lowercased() }.flatMap { confRank[$0] != nil ? $0 : nil } ?? "medium"
            let loserIdxs = valid.filter { $0 != survivorIdx }
            parsed.append(Cluster(
                canonicalName: (c["canonical_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (nameByIdx[survivorIdx] ?? ""),
                confidence: conf,
                survivorId: idByIdx[survivorIdx] ?? "",
                survivorName: nameByIdx[survivorIdx] ?? "",
                memberIds: loserIdxs.map { idByIdx[$0] ?? "" },
                memberNames: loserIdxs.map { nameByIdx[$0] ?? "" }
            ))
        }
        return (dedupe(parsed), themes.count)
    }

    /// A theme may only be merged once. Process high-confidence, then larger, clusters
    /// first; each claims its themes, and any theme already claimed is dropped from later
    /// clusters. A cluster left with no losers is discarded.
    private static func dedupe(_ clusters: [Cluster]) -> [Cluster] {
        let ordered = clusters.sorted {
            let a = confRank[$0.confidence] ?? 1, b = confRank[$1.confidence] ?? 1
            if a != b { return a < b }
            return $0.memberIds.count > $1.memberIds.count
        }
        var claimed = Set<String>()
        var out: [Cluster] = []
        for c in ordered {
            if claimed.contains(c.survivorId) { continue }           // survivor taken by a stronger cluster
            var keptIds: [String] = [], keptNames: [String] = []
            for (id, name) in zip(c.memberIds, c.memberNames) where !claimed.contains(id) {
                keptIds.append(id); keptNames.append(name)
            }
            guard !keptIds.isEmpty else { continue }
            claimed.insert(c.survivorId); keptIds.forEach { claimed.insert($0) }
            out.append(Cluster(canonicalName: c.canonicalName, confidence: c.confidence,
                               survivorId: c.survivorId, survivorName: c.survivorName,
                               memberIds: keptIds, memberNames: keptNames))
        }
        return out.sorted {
            let a = confRank[$0.confidence] ?? 1, b = confRank[$1.confidence] ?? 1
            if a != b { return a < b }
            return $0.memberIds.count > $1.memberIds.count
        }
    }

    // MARK: - Apply (writes)

    /// Merge each cluster's members into its survivor and rename the survivor to the
    /// canonical name. When `highOnly`, only high-confidence clusters are applied.
    /// Returns (clustersApplied, themesMerged). Reversible: losers are dismissed, not deleted.
    @discardableResult
    static func apply(_ clusters: [Cluster], highOnly: Bool) -> (applied: Int, merged: Int) {
        let store = SelfModelStore.shared
        let nameById = Dictionary(store.getFacets(kind: "theme").map {
            (($0["id"] as? String ?? ""), ($0["statement"] as? String ?? ""))
        }, uniquingKeysWith: { x, _ in x })
        var applied = 0, merged = 0
        for c in clusters where !(highOnly && c.confidence != "high") {
            guard let survivorName = nameById[c.survivorId] else { continue }
            for loserId in c.memberIds {
                guard let loserName = nameById[loserId] else { continue }
                _ = ReflectionStore.shared.mergeThemes(source: loserName, target: survivorName)
                for l in store.allLineage() where l.theme == loserId {
                    _ = store.unlinkFacetFromTheme(facetId: l.facet, themeId: loserId)
                    _ = store.linkFacetToTheme(facetId: l.facet, themeId: c.survivorId)
                }
                _ = store.setVerdict(id: loserId, verdict: "dismissed")
                store.recordModelFeedback(facetId: loserId, kind: "converge", action: nil,
                                          detail: "\(loserName) → \(survivorName)")
                merged += 1
            }
            // Canonical name (also marks the survivor user-renamed, so it won't be re-merged).
            if c.canonicalName != survivorName {
                _ = store.setUserStatement(id: c.survivorId, statement: c.canonicalName)
            }
            applied += 1
        }
        return (applied, merged)
    }

    // MARK: - Prompt

    private static let systemPrompt = """
    You converge a person's fragmented workspace themes. Each theme below is a subject they've worked on; several titles often describe the SAME underlying workspace from different angles (e.g. "CCBP MTU decline", "CCBP TPV underperformance", "CCBP user churn" are all the ONE CCBP workspace — cluster them together).

    Group themes that are the same underlying subject/workspace. Rules:
    - Put each theme in AT MOST ONE cluster. A cluster has ≥2 members.
    - Titles that repeatedly name the same specific product, deal, company, or entity (CCBP, ESOP, Meta, a named portfolio company) are usually ONE workspace even when each describes a different metric or angle — cluster them.
    - Do NOT merge a general principle, philosophy, mental model, or behavioural pattern into a specific project. Those are beliefs, not workspaces. (e.g. "commitment without follow-through" or "bottom-up vs top-down goal setting" must NOT be swallowed into a project workspace.)
    - Do NOT merge two distinct specific subjects merely because they share a domain (two different portfolio companies; two different products; a thesis vs a specific deal).
    - Prefer fewer, cleaner clusters over aggressive merging. Leave genuine singletons alone (do not return them).

    For each cluster return:
    - canonical_name: the clearest, most durable workspace name (reuse the best existing title or write a crisp one).
    - confidence: "high" if the members are unambiguously the same object of work; "medium" if the same subject but with some doubt; "low" if plausible but speculative.
    - survivor: index of the member that should absorb the others (strongest signal / clearest name).
    - members: indices of ALL members, including the survivor.

    Return ONLY JSON, no prose:
    {"clusters":[{"canonical_name":"...","confidence":"high","survivor":12,"members":[12,45,88]}]}
    Return {"clusters":[]} if nothing should merge.
    """

    private static func extractJSON(_ s: String) -> String? {
        guard let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}"), start < end else { return nil }
        return String(s[start...end])
    }
}
