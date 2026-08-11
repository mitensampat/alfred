import Foundation

/// Finds items sitting in the wrong workspace and PROPOSES a move — it never re-files silently.
///
/// Convergence (`SelfModelConvergence`) collapses duplicate *workspaces*; this is the other axis:
/// a single workspace accumulates *items* that bled in from a co-tagged conversation (you talked to
/// one person about three subjects in one thread, so a decision about subject B landed in subject A's
/// workspace). Phase A's owning-theme gate stops new bleed at the source, but historical items whose
/// only signal was token-overlap can still be misfiled.
///
/// One LLM pass per workspace reads its items against the universe of workspace names and flags the
/// ones that clearly belong elsewhere, naming the better home. Each flag is QUEUED as a pending
/// proposal (`ReflectionStore.item_move_proposal`); the user accepts or rejects. An accepted move
/// writes a `reflection_item_override`, which `SelfModelSynthesizer.owningTheme()` honours on every
/// subsequent rebuild — so the correction is durable, not cosmetic. Merge, never purge.
enum SelfModelHygiene {

    struct StrayProposal {
        let id: String            // stable — re-running never duplicates or resurrects a resolved move
        let reflectionId: Int
        let itemType: String      // "decision" | "shift"
        let content: String       // decision text, or the shift's "to" (the durable override key)
        let aux: String?          // shift "from"; nil for decisions
        let fromTheme: String
        let toTheme: String
        let rationale: String
        let confidence: String    // high | medium | low
    }

    /// Detect strays across the busiest workspaces (where bleed concentrates). Returns proposals;
    /// does NOT write them — the caller enqueues. `maxWorkspaces`/`itemsPerWorkspace` bound the LLM cost.
    static func detectStrays(maxWorkspaces: Int = 12, itemsPerWorkspace: Int = 24) async -> [StrayProposal] {
        guard let config = AppConfig.load() else { return [] }

        // Workspace universe, ordered by importance. The busiest few get scanned for strays; the full
        // name list is the menu of valid destinations the model may move an item into.
        let rows = ReflectionStore.shared.getThemesWithState(days: 180, limit: 250)
        let names: [String] = rows.compactMap { ($0["theme"] as? String)?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard names.count > 1 else { return [] }
        let universe = Array(names.prefix(80))              // destinations menu (already frequency-ordered)
        let toScan = Array(names.prefix(maxWorkspaces))     // workspaces we inspect for strays

        let svc = ClaudeAIService(config: config.ai, userName: config.user.name)
        var proposals: [StrayProposal] = []

        for workspace in toScan {
            let detail = ReflectionStore.shared.getThemeDetail(theme: workspace, days: 400)
            let timeline = (detail["timeline"] as? [[String: Any]]) ?? []
            // Only movable items carry a reflection_id + durable content: decisions and shifts.
            struct Item { let idx: Int; let type: String; let content: String; let aux: String?; let rid: Int; let display: String }
            var items: [Item] = []
            for t in timeline {
                guard let type = t["type"] as? String, type == "decision" || type == "shift" || type == "question",
                      let ridStr = t["rid"] as? String, let rid = Int(ridStr) else { continue }
                if type == "decision" || type == "question" {
                    let c = (t["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard c.count >= (type == "question" ? 15 : 20) else { continue }
                    items.append(Item(idx: items.count + 1, type: type, content: c, aux: nil, rid: rid, display: c))
                } else {
                    let to = (t["shift_to"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let from = (t["shift_from"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard to.count >= 12 else { continue }
                    let disp = from.isEmpty ? to : "was: \(from) → now: \(to)"
                    items.append(Item(idx: items.count + 1, type: "shift", content: to, aux: from.isEmpty ? nil : from, rid: rid, display: disp))
                }
                if items.count >= itemsPerWorkspace { break }
            }
            guard items.count >= 4 else { continue }   // too few to judge misfit meaningfully

            let itemListing = items.map { "\($0.idx). [\($0.type)] \($0.display)" }.joined(separator: "\n")
            let destinations = universe.filter { $0 != workspace }.map { "- \($0)" }.joined(separator: "\n")
            let prompt = """
            WORKSPACE UNDER REVIEW: "\(workspace)"

            ITEMS currently filed in it:
            \(itemListing)

            OTHER WORKSPACES it could belong to instead:
            \(destinations)
            """

            guard let raw = try? await svc.generateText(prompt: prompt, system: systemPrompt, maxTokens: 1500),
                  let data = extractJSON(raw)?.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let strays = obj["strays"] as? [[String: Any]] else { continue }

            for s in strays {
                guard let idx = (s["item"] as? Int) ?? Int("\(s["item"] ?? "")"),
                      idx >= 1, idx <= items.count,
                      let dest = (s["belongs_in"] as? String)?.trimmingCharacters(in: .whitespaces),
                      !dest.isEmpty, dest != workspace,
                      universe.contains(where: { $0.caseInsensitiveCompare(dest) == .orderedSame }) else { continue }
                // Resolve to the exact casing in the universe (the LLM may paraphrase capitalisation).
                let target = universe.first(where: { $0.caseInsensitiveCompare(dest) == .orderedSame }) ?? dest
                let it = items[idx - 1]
                let conf = ((s["confidence"] as? String)?.lowercased()).flatMap { ["high","medium","low"].contains($0) ? $0 : nil } ?? "medium"
                let why = (s["why"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
                let pid = SelfModelSynthesizer.stableId("move", "\(it.rid)|\(it.type)|\(it.content)|\(workspace)")
                proposals.append(StrayProposal(
                    id: pid, reflectionId: it.rid, itemType: it.type, content: it.content, aux: it.aux,
                    fromTheme: workspace, toTheme: target, rationale: why, confidence: conf))
            }
        }
        return proposals
    }

    /// Run the detector and enqueue every proposal (INSERT OR IGNORE — resolved ones never return).
    /// Returns (scanned proposals, newly queued). Nothing is applied; the user decides each move.
    @discardableResult
    static func detectAndQueue(maxWorkspaces: Int = 12) async -> (found: Int, queued: Int) {
        let props = await detectStrays(maxWorkspaces: maxWorkspaces)
        var queued = 0
        for p in props {
            if ReflectionStore.shared.addItemMoveProposal(
                id: p.id, reflectionId: p.reflectionId, itemType: p.itemType, content: p.content,
                aux: p.aux, fromTheme: p.fromTheme, toTheme: p.toTheme,
                rationale: p.rationale, confidence: p.confidence) { queued += 1 }
        }
        return (props.count, queued)
    }

    private static let systemPrompt = """
    You are auditing whether items are filed in the right workspace. A workspace is a subject the person works on (a deal, a product, a company, a recurring theme). Items bleed into the wrong workspace when a single conversation covered several subjects and everything got tagged to one of them.

    You are given ONE workspace, the items filed in it, and a menu of OTHER workspaces. Flag ONLY items that clearly do NOT belong in the workspace under review AND clearly belong in one of the listed other workspaces.

    Rules:
    - Be conservative. If an item plausibly belongs where it is, leave it. Only flag obvious misfiles.
    - belongs_in MUST be copied verbatim from the "OTHER WORKSPACES" menu. Never invent a destination.
    - Do not flag an item just because it is broad or abstract — a general belief can legitimately live in a specific workspace. Flag only when a DIFFERENT specific workspace is a clearly better home.
    - Return at most 5 strays for this workspace.

    For each stray return: item (its index number), belongs_in (verbatim workspace name from the menu), confidence ("high" only if unmistakable), why (one short clause).

    Return ONLY JSON, no prose:
    {"strays":[{"item":3,"belongs_in":"CCBP","confidence":"high","why":"about CCBP MDR economics, not this hiring workspace"}]}
    Return {"strays":[]} if everything is correctly filed.
    """

    private static func extractJSON(_ s: String) -> String? {
        guard let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}"), start < end else { return nil }
        return String(s[start...end])
    }
}
