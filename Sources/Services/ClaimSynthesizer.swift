import Foundation

/// The interpret stage.
///
/// Everything before this reads the stream and files what it finds: a reflection's
/// `mental_model_shifts` became one belief per shift, its `open_questions` became one question
/// per thread. Nothing ever looked across those artifacts and concluded anything, so the Model
/// page showed 140 beliefs — 131 of them from a single thread, at a flat 0.65 — and 456 open
/// questions, none of which had ever been closed. The pipeline was extract → store → display.
///
/// This pass is the missing middle. It groups the substrate by workspace (the lineage graph
/// already says which decisions and shifts belong to which subject), then asks a model, one
/// workspace at a time, what this person actually believes and what they protect when two goods
/// conflict. The answers are *claims*: statements supported by named evidence, recomputed every
/// run so wording sharpens and unsupported claims fall away.
///
/// Two rules do most of the work:
///   • **A claim needs independent support** — at least two evidence items from two different
///     days. One thread never gets to be a belief. That single gate is what separates this from
///     the shift-chain path it replaces.
///   • **A re-run updates, it does not accumulate.** A new claim that reads like one already
///     stored for that workspace takes over the existing row (keeping its id, its verdict and
///     any wording you chose), and a stored claim the run no longer makes is retired.
enum ClaimSynthesizer {

    struct Outcome {
        var clusters = 0        // workspaces examined
        var beliefs = 0         // belief claims written
        var values = 0         // value claims written
        var kept = 0            // claims the run reaffirmed unchanged
        var updated = 0         // existing claims restated in place
        var thin = 0            // claims rejected for lack of independent support
        var retired = 0         // stored claims this run no longer makes
        var legacyRetired = 0   // old one-thread beliefs archived by the migration
        var questionsRead = 0   // open questions handed to the pass
        var questionsAnswered = 0  // questions the evidence closed
        var questionsMerged = 0 // questions folded into a near-duplicate
        var failures = 0        // clusters where the model call failed
        var model = ""
    }

    /// Minimum items in a workspace before it is worth paying a model to read.
    static let minClusterItems = 4
    /// Evidence rule: this many refs, across this many distinct days.
    static let minSupport = 2
    static let minDistinctDays = 2
    /// How many claims one workspace may contribute per run.
    /// Two beliefs and one value per workspace. A workspace that genuinely supports three
    /// durable principles is rarer than a model asked for three will admit, and 27 workspaces ×
    /// 5 claims is the 140-fragment pile again with better prose. The surface ranks what is left.
    static let maxBeliefsPerCluster = 2
    static let maxValuesPerCluster = 1

    // MARK: - Entry point

    /// Synthesize claims for the workspaces most in need of it.
    ///
    /// `maxClusters` bounds the cost per run; clusters are taken never-synthesized-first and
    /// then stalest-first, so repeated runs cover everything without re-reading the same
    /// subjects. `migrate` retires the legacy one-thread beliefs of each workspace it covers —
    /// off by default so the first run can be inspected before anything is archived.
    @discardableResult
    static func run(maxClusters: Int = 40, migrate: Bool = false,
                    sweepLegacy: Bool = false) async -> Outcome {
        var out = Outcome()
        guard let config = AppConfig.load() else { return out }
        let store = SelfModelStore.shared
        let ai = ClaudeAIService(config: config.ai)
        let preferred = config.ai.effectiveSynthesisModel
        let fallbackModel = config.ai.model
        out.model = preferred

        // ---- Substrate, grouped by workspace ----
        // `done` workspaces stay in: a subject you finished still shaped what you believe.
        // Only the ones convergence merged away are excluded — their evidence is read through
        // the merge instead, below.
        let themes = store.getFacets(kind: "theme").filter {
            ($0["user_verdict"] as? String) != "dismissed"
        }
        let themeById = Dictionary(themes.map { (($0["id"] as? String) ?? "", $0) },
                                   uniquingKeysWith: { a, _ in a })
        var substrate: [String: [String: Any]] = [:]   // facet id → row
        for f in store.getFacets(kind: "decision") + store.getFacets(kind: "belief") {
            guard let id = f["id"] as? String else { continue }
            // A synthesized claim is this pass's own output — never its own input.
            guard (f["origin"] as? String) != "synthesized" else { continue }
            substrate[id] = f
        }
        // Read evidence through the merges. Two thirds of the lineage graph points at themes
        // convergence dismissed; without this the pass sees a sliver of the substrate and most
        // workspaces look too thin to be worth reading.
        let winners = store.convergenceWinners()
        var itemsByTheme: [String: [[String: Any]]] = [:]
        for l in store.allLineage() {
            let themeId = winners[l.theme] ?? l.theme
            guard themeById[themeId] != nil, let item = substrate[l.facet] else { continue }
            itemsByTheme[themeId, default: []].append(item)
        }

        // ---- Order: never synthesized first, then the biggest ----
        let candidates = itemsByTheme
            .filter { $0.value.count >= minClusterItems }
            .map { (themeId: $0.key, items: $0.value) }
            .sorted { a, b in
                let sa = (themeById[a.themeId]?["metadata"] as? [String: String])?["claims_at"] ?? ""
                let sb = (themeById[b.themeId]?["metadata"] as? [String: String])?["claims_at"] ?? ""
                if sa != sb { return sa < sb }          // "" (never) sorts first
                return a.items.count > b.items.count
            }
            .prefix(max(0, maxClusters))

        // ---- Open questions, by workspace ----
        // A question only becomes answerable once it sits next to the decisions taken in the
        // same subject afterwards; `backfillQuestionLineage` is what makes that edge exist.
        var questionsByTheme: [String: [[String: Any]]] = [:]
        let openQuestions = store.getFacets(kind: "question").filter { q in
            let v = (q["user_verdict"] as? String) ?? ""
            return v != "resolved" && v != "dismissed"
        }
        let questionById = Dictionary(openQuestions.map { (($0["id"] as? String) ?? "", $0) },
                                      uniquingKeysWith: { a, _ in a })
        for l in store.allLineage() {
            guard let q = questionById[l.facet] else { continue }
            questionsByTheme[winners[l.theme] ?? l.theme, default: []].append(q)
        }

        let existing = store.getFacets(kind: "belief") + store.getFacets(kind: "value")
        var claimsByTheme: [String: [[String: Any]]] = [:]
        var themeOfClaim: [String: String] = [:]
        let existingById = Dictionary(existing.map { (($0["id"] as? String) ?? "", $0) },
                                      uniquingKeysWith: { a, _ in a })
        for l in store.allLineage() {
            guard let c = existingById[l.facet],
                  (c["origin"] as? String) == "synthesized" else { continue }
            let themeId = winners[l.theme] ?? l.theme
            claimsByTheme[themeId, default: []].append(c)
            themeOfClaim[l.facet] = themeId
        }

        for cluster in candidates {
            guard let theme = themeById[cluster.themeId],
                  let name = theme["statement"] as? String, !name.isEmpty else { continue }
            out.clusters += 1

            let standing = claimsByTheme[cluster.themeId] ?? []
            let questions = Array((questionsByTheme[cluster.themeId] ?? []).sorted {
                (($0["last_seen"] as? String) ?? "") > (($1["last_seen"] as? String) ?? "")
            }.prefix(10))
            out.questionsRead += questions.count
            let (prompt, refs, claimRefs, qRefs) = buildPrompt(
                workspace: name, items: cluster.items, standing: standing, questions: questions)
            var parsed = await ask(ai, prompt: prompt, model: preferred)
            if parsed == nil, preferred != fallbackModel {
                // The preferred model may not exist on this account; don't let the whole pass
                // die of a 404 — say so in the log and finish the run on the configured model.
                print("[ClaimSynthesizer] \(preferred) unavailable; retrying on \(fallbackModel)")
                parsed = await ask(ai, prompt: prompt, model: fallbackModel)
                if parsed != nil { out.model = fallbackModel }
            }
            guard let answer = parsed else { out.failures += 1; continue }
            let claims = answer.claims

            // Validate everything first, then keep only the best few. A big workspace hands back
            // four or five good claims per run; left uncapped that is 300+ claims across the
            // model, which is the same unusable pile as the 140 fragments, only better written.
            struct Candidate {
                let kind: String
                let statement: String
                let durability: String
                let rationale: String
                let cited: [[String: Any]]
                let days: Int
                /// The standing claim this one supersedes, when the model named one.
                let replaces: String?
            }
            var candidates: [Candidate] = []
            var writtenIds = Set<String>()
            // Reaffirmed: the model says these still stand. Left exactly as they are — same
            // wording, same id, same confidence — and counted so the retire sweep skips them.
            for ref in answer.keep {
                for token in ref.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
                    where !token.isEmpty {
                    guard let id = claimRefs[token], !id.isEmpty else { continue }
                    if writtenIds.insert(id).inserted { out.kept += 1 }
                }
            }
            for c in claims {
                let kind = ((c["kind"] as? String) ?? "").lowercased()
                guard kind == "belief" || kind == "value" else { continue }
                let statement = ((c["statement"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard statement.count >= 12 else { continue }

                // Resolve the model's refs back to real facets, and apply the support rule.
                // Tolerant on purpose: the model answers "[d3]", "d3" or "d3, s1" depending on
                // the day, and a strict key lookup silently rejected every claim in the first
                // run — 11 good claims thrown away because of a pair of brackets.
                var cited: [[String: Any]] = []
                var seenRefs = Set<String>()
                for raw in ((c["evidence"] as? [String]) ?? []) {
                    for token in raw.lowercased()
                        .components(separatedBy: CharacterSet.alphanumerics.inverted)
                        .filter({ !$0.isEmpty }) {
                        guard let item = refs[token], seenRefs.insert(token).inserted else { continue }
                        cited.append(item)
                    }
                }
                let days = Set(cited.compactMap { ($0["last_seen"] as? String).map { String($0.prefix(10)) } })
                guard cited.count >= minSupport, days.count >= minDistinctDays else {
                    print("[ClaimSynthesizer] thin: \(cited.count) refs / \(days.count) days "
                        + "— \(((c["evidence"] as? [String]) ?? []).joined(separator: ",")) "
                        + "— \(statement.prefix(60))")
                    out.thin += 1
                    continue
                }

                var durability = ((c["durability"] as? String) ?? "durable").lowercased()
                if BeliefDurability(rawValue: durability)?.isBelief != true { durability = "durable" }
                var replacesId: String?
                if let raw = (c["replaces"] as? String)?.lowercased() {
                    for token in raw.components(separatedBy: CharacterSet.alphanumerics.inverted)
                        where !token.isEmpty {
                        if let id = claimRefs[token], !id.isEmpty { replacesId = id; break }
                    }
                }
                candidates.append(Candidate(
                    kind: kind, statement: statement, durability: durability,
                    rationale: String(((c["rationale"] as? String) ?? "").prefix(300)),
                    cited: cited, days: days.count, replaces: replacesId))
            }

            // Best-evidenced first, then most recent. Caps are per workspace, per run.
            func topN(_ kind: String, _ n: Int) -> [Candidate] {
                candidates.filter { $0.kind == kind }.sorted { a, b in
                    if a.cited.count != b.cited.count { return a.cited.count > b.cited.count }
                    if a.days != b.days { return a.days > b.days }
                    let an = a.cited.compactMap { $0["last_seen"] as? String }.max() ?? ""
                    let bn = b.cited.compactMap { $0["last_seen"] as? String }.max() ?? ""
                    return an > bn
                }.prefix(n).map { $0 }
            }
            func budget(_ kind: String, _ cap: Int) -> Int {
                let standingKept = standing.filter {
                    ($0["kind"] as? String) == kind && writtenIds.contains(($0["id"] as? String) ?? "")
                }.count
                return max(0, cap - standingKept)
            }
            for cand in topN("belief", budget("belief", maxBeliefsPerCluster))
                + topN("value", budget("value", maxValuesPerCluster)) {
                let statement = cand.statement
                let kind = cand.kind
                let cited = cand.cited

                // Identity, in order of trust: the claim the model said it was replacing, then a
                // stored claim that says the same thing (a backstop for when it restates without
                // saying so), then a new row. Taking over a row keeps its verdict and any
                // wording the user chose.
                let twin = standing.first { ($0["id"] as? String) == cand.replaces }
                    ?? standing.first {
                        ($0["kind"] as? String) == kind
                            && similar(($0["statement"] as? String) ?? "", statement)
                    }
                let id = (twin?["id"] as? String)
                    ?? "claim_" + fnv1a("\(cluster.themeId)|\(kind)|\(statement.lowercased())")
                if twin != nil { out.updated += 1 }

                let dates = cited.compactMap { $0["last_seen"] as? String }.sorted()
                let evidence: [[String: String]] = cited.prefix(6).map { item in
                    ["source_type": (item["kind"] as? String) ?? "signal",
                     "snippet": String(((item["statement"] as? String) ?? "").prefix(220)),
                     "ts": (item["last_seen"] as? String) ?? ""]
                }
                _ = store.upsertFacet(
                    id: id, kind: kind, statement: statement,
                    confidence: confidence(support: cited.count, days: cand.days, newest: dates.last),
                    status: "active",
                    firstSeen: dates.first, lastSeen: dates.last, trajectory: [],
                    evidence: evidence,
                    metadata: [
                        "workspace": name,
                        "support": String(cited.count),
                        "support_days": String(cand.days),
                        "rationale": cand.rationale,
                        "durability": cand.durability,
                        "durability_source": "synthesis",
                        "durability_hash": BeliefDurability.hash(statement),
                        // A value Alfred inferred is its read until you say otherwise. The UI
                        // labels these; nothing pretends you declared it.
                        "proposed": kind == "value" ? "1" : "0"
                    ],
                    origin: "synthesized", preserveUserMeta: true)
                _ = store.linkFacetToTheme(facetId: id, themeId: cluster.themeId)
                writtenIds.insert(id)
                if kind == "belief" { out.beliefs += 1 } else { out.values += 1 }
            }

            func protected(_ f: [String: Any]) -> Bool {
                let v = f["user_verdict"] as? String
                return v == "confirmed" || v == "kept" || (f["renamed"] as? Bool) == true
            }

            // Retire what this run no longer claims — unless you confirmed or re-worded it.
            for stored in standing {
                guard let id = stored["id"] as? String, !writtenIds.contains(id) else { continue }
                guard !protected(stored) else { continue }
                _ = store.archiveFacet(id: id)
                out.retired += 1
            }

            // Then hold the workspace to its budget. Reaffirming is how a claim survives a run,
            // so without this a workspace that once produced five claims keeps all five for
            // ever — the cap would only ever apply to new ones. Weakest evidence goes first.
            let live = store.getFacets(kind: "belief") + store.getFacets(kind: "value")
            let mine = live.filter { writtenIds.contains(($0["id"] as? String) ?? "") }
            for (kind, cap) in [("belief", maxBeliefsPerCluster), ("value", maxValuesPerCluster)] {
                let ofKind = mine.filter { ($0["kind"] as? String) == kind }
                guard ofKind.count > cap else { continue }
                let ranked = ofKind.sorted { a, b in
                    // Anything you touched outranks everything else, then evidence.
                    if protected(a) != protected(b) { return protected(a) }
                    let ca = (a["confidence"] as? Double) ?? 0, cb = (b["confidence"] as? Double) ?? 0
                    if ca != cb { return ca > cb }
                    return ((a["last_seen"] as? String) ?? "") > ((b["last_seen"] as? String) ?? "")
                }
                for extra in ranked.dropFirst(cap) where !protected(extra) {
                    guard let id = extra["id"] as? String else { continue }
                    _ = store.archiveFacet(id: id)
                    out.retired += 1
                }
            }

            // ---- Questions: close what the evidence has since answered ----
            // Silently, by choice: a question Alfred can answer from the decisions you took is
            // not a question to put back in front of you. The answer and its evidence are kept
            // on the row, and the page lists what was closed, so a wrong close is visible and
            // one click away from being reopened.
            for q in answer.questions {
                guard let qid = resolveRef(q["ref"] as? String, qRefs), !qid.isEmpty else { continue }
                switch ((q["status"] as? String) ?? "open").lowercased() {
                case "answered":
                    let text = ((q["answer"] as? String) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard text.count >= 12 else { continue }
                    var cited: [[String: Any]] = []
                    var seen = Set<String>()
                    for raw in ((q["evidence"] as? [String]) ?? []) {
                        for token in raw.lowercased()
                            .components(separatedBy: CharacterSet.alphanumerics.inverted)
                            .filter({ !$0.isEmpty }) {
                            guard let item = refs[token], seen.insert(token).inserted else { continue }
                            cited.append(item)
                        }
                    }
                    // An answer with nothing behind it is a guess, and a guess is not grounds
                    // for closing something the person wrote down as unsettled. Two refs, the
                    // same independence rule the claims live under: the first live run closed
                    // nine questions and every bad close was a single-reference one — "should I
                    // be thinking about what comes after CRED?" was closed with "yes, taking a
                    // company public is worth pursuing", which answers a different question.
                    guard cited.count >= minSupport else {
                        print("[ClaimSynthesizer] answer too thin (\(cited.count) ref): "
                            + "\(text.prefix(60))")
                        continue
                    }
                    let snippet = cited.compactMap { $0["statement"] as? String }.first ?? ""
                    _ = store.mergeFacetMetadata(id: qid, [
                        "answer": String(text.prefix(400)),
                        "answered_at": ISO8601DateFormatter().string(from: Date()),
                        "answered_by": "synthesis",
                        "answer_support": String(cited.count),
                        "answer_evidence": String(snippet.prefix(220)),
                        "workspace": name
                    ])
                    if store.setVerdict(id: qid, verdict: "resolved") { out.questionsAnswered += 1 }
                case "duplicate":
                    guard let other = resolveRef(q["same_as"] as? String, qRefs),
                          !other.isEmpty, other != qid else { continue }
                    _ = store.mergeFacetMetadata(id: qid, [
                        "duplicate_of": other,
                        "answered_at": ISO8601DateFormatter().string(from: Date()),
                        "workspace": name
                    ])
                    if store.setVerdict(id: qid, verdict: "resolved") { out.questionsMerged += 1 }
                default:
                    break
                }
            }

            if migrate {
                out.legacyRetired += retireLegacyBeliefs(
                    themeId: cluster.themeId, store: store, winners: winners)
            }
            _ = store.mergeFacetMetadata(id: cluster.themeId, [
                "claims_at": ISO8601DateFormatter().string(from: Date())
            ])
        }

        // Some fragments belong to no live workspace at all — their reflection carried no theme,
        // or their theme was merged away and never rebuilt. A per-workspace migration can never
        // reach them, and nothing refreshes them any more now that the shift-chain path is gone,
        // so they would sit on the page for ever. The sweep is deliberate and separate: it runs
        // once, after a full backfill, not on the weekly cadence.
        if sweepLegacy {
            for b in store.getFacets(kind: "belief") {
                guard let id = b["id"] as? String,
                      (b["origin"] as? String) == "emergent" else { continue }
                let v = b["user_verdict"] as? String
                guard v == nil || v!.isEmpty, (b["renamed"] as? Bool) != true else { continue }
                _ = store.mergeFacetMetadata(id: id, ["superseded": "claims"])
                if store.archiveFacet(id: id) { out.legacyRetired += 1 }
            }
        }
        return out
    }

    // MARK: - The ask

    private static func buildPrompt(workspace: String, items: [[String: Any]],
                                    standing: [[String: Any]], questions: [[String: Any]])
        -> (String, [String: [String: Any]], [String: String], [String: String]) {
        // Newest first, decisions and shifts kept separate so the model can see which is which.
        let sorted = items.sorted { (($0["last_seen"] as? String) ?? "") > (($1["last_seen"] as? String) ?? "") }
        let decisions = sorted.filter { ($0["kind"] as? String) == "decision" }.prefix(30)
        let shifts = sorted.filter { ($0["kind"] as? String) == "belief" }.prefix(12)

        var refs: [String: [String: Any]] = [:]
        var lines: [String] = []
        for (i, d) in decisions.enumerated() {
            let ref = "d\(i + 1)"
            refs[ref] = d
            let when = String(((d["last_seen"] as? String) ?? "").prefix(10))
            lines.append("[\(ref)] (decision, \(when)) \((d["statement"] as? String) ?? "")")
        }
        for (i, s) in shifts.enumerated() {
            let ref = "s\(i + 1)"
            refs[ref] = s
            let when = String(((s["last_seen"] as? String) ?? "").prefix(10))
            let traj = (s["trajectory"] as? [[String: String]])?.first
            let from = traj?["from"] ?? ""
            let text = (s["statement"] as? String) ?? ""
            lines.append("[\(ref)] (shift in thinking, \(when)) "
                + (from.isEmpty ? text : "from “\(from)” to “\(text)”"))
        }

        // What Alfred already concluded here. Without this the pass re-derives the workspace
        // from scratch every week: 13 re-read workspaces produced 15 retirements and not one
        // reaffirmation, so the user would watch their beliefs get rewritten rather than built
        // on. Stability is part of the output.
        var claimRefs: [String: String] = [:]   // c-ref → facet id
        var standingLines: [String] = []
        for (i, c) in standing.enumerated() {
            let ref = "c\(i + 1)"
            claimRefs[ref] = (c["id"] as? String) ?? ""
            let kind = (c["kind"] as? String) ?? "belief"
            let dur = ((c["metadata"] as? [String: String])?["durability"]).map { " \($0)" } ?? ""
            standingLines.append("[\(ref)] (\(kind)\(dur)) \((c["statement"] as? String) ?? "")")
        }

        // The open questions asked inside this subject. Handed over with the evidence so the
        // pass can close the ones the evidence has since answered — 456 questions had
        // accumulated and not one had ever been closed, because nothing ever looked.
        var qRefs: [String: String] = [:]      // q-ref → facet id
        var questionLines: [String] = []
        for (i, q) in questions.enumerated() {
            let ref = "q\(i + 1)"
            qRefs[ref] = (q["id"] as? String) ?? ""
            questionLines.append("[\(ref)] \((q["statement"] as? String) ?? "")")
        }

        var prompt = """
        Workspace: \(workspace)

        Evidence:
        \(lines.joined(separator: "\n"))
        """
        if !standingLines.isEmpty {
            prompt += """


            Claims already concluded for this workspace:
            \(standingLines.joined(separator: "\n"))
            """
        }
        if !questionLines.isEmpty {
            prompt += """


            Open questions recorded in this workspace:
            \(questionLines.joined(separator: "\n"))
            """
        }
        return (prompt, refs, claimRefs, qRefs)
    }

    private static let system = """
    You are reading one workspace from a person's working life — the decisions they made and the \
    shifts in their thinking, each with a date and a reference like [d3] or [s1].

    Your job is to say what this evidence shows the person BELIEVES and what they VALUE. Not what \
    the evidence is about. Not a summary. A claim about the person.

    Return claims of two kinds:

    - "belief": how they think something works. Mark it "durable" if it is a general principle \
    about how they operate, decide or lead — true across situations, people and quarters. Mark it \
    "tactical" if it is a current read on a specific business, metric or market that could flip \
    next quarter.
    - "value": what they protect when two good things conflict. A value is visible in what LOST. \
    If the evidence shows no trade-off, return no value — do not infer one from a single choice.

    Rules:
    - Every claim must cite at least two references, from at least two different dates. A claim \
    supported by one moment is not a claim; leave it out.
    - Write in plain second person, their own vocabulary, one sentence: "You will delay a launch \
    rather than ship something you would not use yourself."
    - State the claim. Do not open with "You believe", "You think" or "You tend to" — the \
    surface already calls these beliefs, so the prefix just costs the reader a few words.
    - Never restate an event ("Secured funding in Q2") or an instruction ("Mute the group"). \
    Those are not beliefs.
    - Prefer three well-supported claims to eight thin ones. Returning nothing is correct when \
    the evidence is all logistics.
    - rationale: one short sentence on what in the evidence makes this true of them.

    When the input lists claims already concluded for this workspace, treat them as yours:

    - A claim the evidence still supports: put its ref in "keep". Do not restate it. Keeping the \
    wording you already used is worth more than a better sentence — the person reads this surface \
    every week and needs it to settle.
    - A claim that is close but now wrong in substance: return a new claim with "replaces" set to \
    its ref. Only when the meaning changed, not the phrasing.
    - A claim the evidence no longer supports at all: leave it out entirely. It will be retired.
    - Then add claims for anything the evidence shows that the standing set does not already cover.

    When the input lists open questions, sort them out in "questions". These were recorded as \
    things the person had not settled, and nothing has ever closed one:

    - "answered": the evidence here settles it. Give the answer in one sentence, in their own \
    terms, and cite at least two evidence refs that settle it. Only when the evidence decides \
    the question that was actually asked: if your answer would not make the question disappear \
    for them, it is still open. A decision taken nearby, on a related matter, is not an answer.
    - "duplicate": another question in this list asks the same thing. Name that one in "same_as" \
    and keep the clearer wording as the survivor.
    - "open": still live. Say nothing else about it.
    Judge the question on its substance, not its phrasing: a decision taken is an answer even if \
    nobody wrote it as one.
    """

    private static func schema() -> [String: Any] {
        [
            "type": "object",
            "properties": [
                "claims": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "kind": ["type": "string", "enum": ["belief", "value"]],
                            "statement": ["type": "string"],
                            "durability": ["type": "string", "enum": ["durable", "tactical"]],
                            "evidence": ["type": "array", "items": ["type": "string"]],
                            "rationale": ["type": "string"],
                            "replaces": ["type": "string"]
                        ],
                        "required": ["kind", "statement", "durability", "evidence", "rationale"],
                        "additionalProperties": false
                    ]
                ],
                "keep": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": "refs of already-concluded claims that still stand, unchanged"
                ],
                "questions": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "ref": ["type": "string"],
                            "status": ["type": "string", "enum": ["open", "answered", "duplicate"]],
                            "answer": ["type": "string"],
                            "evidence": ["type": "array", "items": ["type": "string"]],
                            "same_as": ["type": "string"]
                        ],
                        "required": ["ref", "status"],
                        "additionalProperties": false
                    ]
                ]
            ],
            "required": ["claims", "keep", "questions"],
            "additionalProperties": false
        ]
    }

    private static func ask(_ ai: ClaudeAIService, prompt: String, model: String)
        async -> (claims: [[String: Any]], keep: [String], questions: [[String: Any]])? {
        do {
            let obj = try await ai.generateStructured(
                prompt: prompt, system: system, schema: schema(), maxTokens: 3200, useModel: model)
            return ((obj["claims"] as? [[String: Any]]) ?? [], (obj["keep"] as? [String]) ?? [],
                    (obj["questions"] as? [[String: Any]]) ?? [])
        } catch {
            print("[ClaimSynthesizer] cluster failed on \(model): \(error)")
            return nil
        }
    }

    // MARK: - Scoring, identity, migration

    /// Confidence that means something: how much independent evidence there is, and how recent.
    /// The path this replaces returned 0.55 + 0.1 × shifts, which made almost every belief 0.65
    /// and left the Wiki's confidence ordering arbitrary.
    static func confidence(support: Int, days: Int, newest: String?) -> Double {
        // Weighted so a well-evidenced claim still has somewhere to go: 2 refs over 2 days lands
        // near 0.71, six refs over three-plus days near 0.92. The first cut used 0.1 per ref
        // capped at four, which saturated almost everything at the ceiling — the same flatness
        // that made the old 0.65-for-everything confidence meaningless.
        var c = 0.45 + 0.06 * Double(min(support, 6)) + 0.07 * Double(min(days, 3))
        if let newest = newest, let d = ISO8601DateFormatter().date(from: newest),
           Date().timeIntervalSince(d) > 120 * 86400 {
            c *= 0.85   // the evidence is old; the claim may be too
        }
        return min(0.92, max(0.45, c))
    }

    /// Two statements say the same thing — the test that keeps a re-worded claim on its own row.
    static func similar(_ a: String, _ b: String) -> Bool {
        let stop: Set<String> = ["that", "this", "with", "from", "your", "when", "will", "what",
                                 "than", "they", "them", "their", "would", "could", "should",
                                 "rather", "because", "about", "more", "most", "over", "into"]
        func tk(_ s: String) -> Set<String> {
            Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 3 && !stop.contains($0) })
        }
        let ta = tk(a), tb = tk(b)
        guard ta.count >= 3, tb.count >= 3 else { return false }
        let inter = Double(ta.intersection(tb).count)
        return inter / Double(ta.union(tb).count) >= 0.5
            || inter / Double(min(ta.count, tb.count)) >= 0.7
    }

    /// Archive the one-thread beliefs of a workspace now that it has real claims.
    ///
    /// "Replace, keep my edits": anything you confirmed, kept or re-worded stays exactly as it
    /// is. Everything else is a fragment the synthesis pass has now superseded — archived, so it
    /// is still in the store and still browsable, just out of the active set.
    private static func retireLegacyBeliefs(themeId: String, store: SelfModelStore,
                                            winners: [String: String]) -> Int {
        var n = 0
        let beliefs = store.getFacets(kind: "belief")
        // Through the merges: a fragment's own lineage usually points at the theme convergence
        // dismissed, not the workspace it now belongs to.
        let linked = Set(store.allLineage()
            .filter { (winners[$0.theme] ?? $0.theme) == themeId }
            .map { $0.facet })
        for b in beliefs {
            guard let id = b["id"] as? String, linked.contains(id) else { continue }
            guard (b["origin"] as? String) == "emergent" else { continue }
            let v = b["user_verdict"] as? String
            guard v == nil || v!.isEmpty else { continue }
            guard (b["renamed"] as? Bool) != true else { continue }
            // Marked, not just archived: workspace promotion counts these so retiring a
            // fragment can't demote a front (see SelfModelService.promotedThemeIds).
            _ = store.mergeFacetMetadata(id: id, ["superseded": "claims"])
            if store.archiveFacet(id: id) { n += 1 }
        }
        return n
    }

    /// The model writes a ref as "[q3]", "q3" or "q3 (the duplicate)" depending on the day.
    /// A strict lookup threw away eleven good claims in the first run over a pair of brackets,
    /// so every ref is resolved the same tolerant way.
    private static func resolveRef(_ raw: String?, _ map: [String: String]) -> String? {
        guard let raw = raw?.lowercased() else { return nil }
        for token in raw.components(separatedBy: CharacterSet.alphanumerics.inverted)
            where !token.isEmpty {
            if let id = map[token] { return id }
        }
        return nil
    }

    private static func fnv1a(_ s: String) -> String {
        var h: UInt64 = 1469598103934665603
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return String(h, radix: 16)
    }
}
