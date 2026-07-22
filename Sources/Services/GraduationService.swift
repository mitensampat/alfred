import Foundation

/// Grounds declared beliefs in decisions you actually made.
///
/// A belief you declared is an *aspiration* until observed behaviour backs it. Until now
/// the only evidence class available was lenses — things you typed at Alfred — which is
/// thin proof of what you believe. Decisions are the real thing: dated, reasoned, and
/// costly to make.
///
/// This is the first part of the self-model that **judges** rather than counts. Everything
/// else is reproducible; this asks a model whether a decision evidences a belief, and that
/// can be wrong in ways arithmetic can't. So nothing is ever applied automatically — the
/// output is a proposal you confirm or reject.
enum GraduationService {

    /// Words too common to indicate a real topical match.
    private static let stop: Set<String> = [
        "the","and","for","that","this","with","from","into","your","you","are","not","but",
        "have","has","was","were","will","would","should","could","when","what","which","who",
        "how","why","its","it's","their","there","they","them","then","than","over","under",
        "more","most","less","least","only","also","because","about","after","before","while",
        "must","can","may","one","two","all","any","each","every","some","such","been","being",
        "does","did","done","make","makes","made","take","takes","get","gets","new","old"
    ]

    private static func terms(_ s: String) -> Set<String> {
        Set(s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 3 && !stop.contains($0) })
    }

    /// Rank decisions by lexical overlap with the belief. This is deliberately cheap —
    /// its only job is to cut 1,100+ decisions down to a shortlist worth paying a model
    /// to read. It will miss decisions that support a belief in different words; the
    /// answer to that is embeddings, not a bigger prompt.
    private static func shortlist(belief: String, decisions: [[String: Any]], limit: Int) -> [[String: Any]] {
        let bt = terms(belief)
        guard !bt.isEmpty else { return [] }
        return decisions
            .map { d -> ([String: Any], Int) in
                let overlap = terms(d["statement"] as? String ?? "").intersection(bt).count
                return (d, overlap)
            }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { $0.0 }
    }

    struct Result {
        var beliefsExamined = 0
        var candidatesRead = 0
        var proposed = 0
        var notes: [String] = []
    }

    /// Look for decisions that evidence each unbacked declared belief.
    @discardableResult
    static func groundDeclaredBeliefs(shortlistSize: Int = 40) async -> Result {
        let store = SelfModelStore.shared
        var result = Result()

        let decisions = store.getFacets(kind: "decision")
        guard !decisions.isEmpty else {
            result.notes.append("no decisions materialized yet"); return result
        }

        // Only declared beliefs that nothing observed supports yet.
        let supported = Set(store.allSupport().filter { $0.kind == "decision" }.map { $0.belief })
        let declared = store.getFacets(kind: "belief").filter {
            ($0["origin"] as? String) == "declared" && !supported.contains($0["id"] as? String ?? "")
        }
        guard !declared.isEmpty else {
            result.notes.append("no unbacked declared beliefs"); return result
        }

        for belief in declared {
            let beliefId = belief["id"] as? String ?? ""
            let statement = belief["statement"] as? String ?? ""
            guard !beliefId.isEmpty, !statement.isEmpty else { continue }
            result.beliefsExamined += 1

            let candidates = shortlist(belief: statement, decisions: decisions, limit: shortlistSize)
            guard candidates.count >= 3 else {
                result.notes.append("\(statement.prefix(40))…: only \(candidates.count) candidates")
                continue
            }
            result.candidatesRead += candidates.count

            let numbered = candidates.enumerated().map { i, d in
                "\(i + 1). \(d["statement"] as? String ?? "")"
            }.joined(separator: "\n")

            let system = """
            You judge whether real decisions are evidence for a stated belief.

            The user declared a belief about how they operate. You are given decisions they
            actually made. Identify ONLY decisions that genuinely evidence the belief — where
            the decision would be hard to explain unless the person held that belief.

            Be strict. Most decisions will not qualify. Topical overlap is NOT evidence: a
            decision about pricing is not evidence for a belief about pricing unless the
            decision reflects the belief's actual stance. If nothing qualifies, return an
            empty list. A wrong match is far worse than a missed one, because the user will
            treat confirmed evidence as proof they live by this belief.

            Return ONLY JSON:
            {"matches":[{"n":<number>,"why":"<max 15 words, how this decision evidences the belief>"}]}
            """
            let prompt = """
            BELIEF: \(statement)

            DECISIONS:
            \(numbered)
            """

            guard let appConfig = AppConfig.load() else {
                result.notes.append("config unavailable"); break
            }
            do {
                let raw = try await ClaudeAIService(config: appConfig.ai).generateText(
                    prompt: prompt, system: system, maxTokens: 900,
                    useModel: "claude-haiku-4-5-20251001")
                guard let json = extractJSON(raw),
                      let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                      let matches = obj["matches"] as? [[String: Any]] else {
                    result.notes.append("\(statement.prefix(30))…: unparseable response")
                    continue
                }
                for m in matches {
                    guard let n = m["n"] as? Int, n >= 1, n <= candidates.count else { continue }
                    let decision = candidates[n - 1]
                    let did = decision["id"] as? String ?? ""
                    guard !did.isEmpty else { continue }
                    let why = (m["why"] as? String) ?? ""
                    if store.addProposal(id: "\(beliefId)|\(did)", beliefId: beliefId, decisionId: did, rationale: why) {
                        result.proposed += 1
                    }
                }
            } catch {
                result.notes.append("\(statement.prefix(30))…: \(error)")
            }
        }
        return result
    }

    /// Accept a proposal: the decision becomes support, which retires the aspiration.
    static func confirm(proposalId: String) -> Bool {
        let store = SelfModelStore.shared
        guard let p = store.getProposals(status: "pending").first(where: { ($0["id"] as? String) == proposalId })
                ?? store.getProposals(status: "pending").first(where: { ($0["id"] as? String) == proposalId })
        else { return false }
        let ok = store.addSupport(
            supportId: p["decision_id"] as? String ?? "",
            beliefId: p["belief_id"] as? String ?? "",
            kind: "decision",
            rationale: p["rationale"] as? String)
        if ok { _ = store.setProposalStatus(id: proposalId, status: "confirmed") }
        return ok
    }

    static func reject(proposalId: String) -> Bool {
        SelfModelStore.shared.setProposalStatus(id: proposalId, status: "rejected")
    }

    private static func extractJSON(_ text: String) -> String? {
        if let s = text.firstIndex(of: "{"), let e = text.lastIndex(of: "}"), s < e {
            return String(text[s...e])
        }
        return nil
    }
}
