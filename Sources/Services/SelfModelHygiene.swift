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

    // MARK: - Reconciliation

    /// How long a proposal nobody answered stays in the queue before it is dropped.
    /// Dropped, not silenced: if the detector still believes it, the next run raises it again.
    static let proposalMaxAgeDays = 60
    /// Pending proposals one workspace may hold. Past this the detector stops adding to the pile.
    static let pendingPerWorkspaceCap = 10

    struct Reconciliation {
        var before = 0
        var deadTarget = 0      // destination workspace no longer exists
        var collapsed = 0       // source and destination merged into each other
        var superseded = 0      // the item already carries an override
        var expired = 0         // nobody answered it for proposalMaxAgeDays
        var remapped = 0        // endpoints rewritten through convergence
        var after = 0
    }

    /// Reconcile the pending queue with the world as it is now.
    ///
    /// 365 proposals had accumulated against 57 the user ever answered, and the queue read as a
    /// chore list nobody could face. Measured on that backlog, 248 of the 365 proposed moving an
    /// item into a workspace that no longer existed: the detector had queued them, convergence
    /// had then merged the destination away, and nothing ever went back. They were not decisions
    /// waiting to be made — they were questions about a world that had moved on.
    ///
    /// This runs on every read of the queue. It costs no model calls.
    @discardableResult
    static func reconcileProposals() -> Reconciliation {
        var r = Reconciliation()
        let store = ReflectionStore.shared
        let pending = store.getItemMoveProposals(status: "pending")
        r.before = pending.count
        guard !pending.isEmpty else { return r }

        let live = SelfModelStore.shared.liveThemeNames()
        guard !live.isEmpty else { return r }       // nothing to judge against; leave the queue alone
        let winners = SelfModelStore.shared.convergenceWinnerNames()
        let overrides = Set(store.itemOwnerOverrides().keys.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        let cutoff = ISO8601DateFormatter().string(from: Date()
            .addingTimeInterval(-Double(proposalMaxAgeDays) * 86400))

        /// A workspace name as it stands today: itself if it is live, else whatever absorbed it.
        func current(_ name: String) -> String? {
            var n = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            for _ in 0..<6 {
                if live.contains(n) { return n }
                guard let next = winners[n], next != n else { return nil }
                n = next
            }
            return live.contains(n) ? n : nil
        }

        var doomed: [String] = []
        for p in pending {
            guard let id = p["id"] as? String else { continue }
            let from = (p["from_theme"] as? String) ?? ""
            let to = (p["to_theme"] as? String) ?? ""
            let content = ((p["content"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

            if overrides.contains(content) { r.superseded += 1; doomed.append(id); continue }
            guard let liveTo = current(to) else { r.deadTarget += 1; doomed.append(id); continue }
            let liveFrom = current(from)
            if let f = liveFrom, f == liveTo { r.collapsed += 1; doomed.append(id); continue }
            // created_at is "YYYY-MM-DD HH:MM:SS" from SQLite; compare on the date alone.
            let created = String(((p["created_at"] as? String) ?? "").prefix(10))
            if !created.isEmpty, created < String(cutoff.prefix(10)) {
                r.expired += 1; doomed.append(id); continue
            }
            // Survivor: carry its endpoints forward to the names that exist today, so the row
            // the user reads names a workspace they can actually find.
            let keptFrom = liveFrom ?? from.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if keptFrom != from.lowercased() || liveTo != to.lowercased() {
                if store.updateItemMoveProposalThemes(id: id, fromTheme: keptFrom, toTheme: liveTo) {
                    r.remapped += 1
                }
            }
        }
        _ = store.deleteItemMoveProposals(ids: doomed)
        r.after = r.before - doomed.count
        return r
    }

    /// Run the detector and enqueue every proposal (INSERT OR IGNORE — resolved ones never return).
    /// Returns (scanned proposals, newly queued). Nothing is applied; the user decides each move.
    @discardableResult
    static func detectAndQueue(maxWorkspaces: Int = 12) async -> (found: Int, queued: Int) {
        // Clear the dead wood before adding to the pile, so the cap below counts live proposals.
        reconcileProposals()
        let props = await detectStrays(maxWorkspaces: maxWorkspaces)
        // What each workspace already has waiting, and what the user has already settled. Both
        // bound the queue: a backlog nobody is clearing is not improved by lengthening it.
        var pendingByWorkspace: [String: Int] = [:]
        for p in ReflectionStore.shared.getItemMoveProposals(status: "pending") {
            pendingByWorkspace[((p["from_theme"] as? String) ?? "").lowercased(), default: 0] += 1
        }
        let overridden = Set(ReflectionStore.shared.itemOwnerOverrides().keys.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        var queued = 0
        for p in props {
            let ws = p.fromTheme.lowercased()
            guard (pendingByWorkspace[ws] ?? 0) < pendingPerWorkspaceCap else { continue }
            guard !overridden.contains(p.content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            else { continue }
            if ReflectionStore.shared.addItemMoveProposal(
                id: p.id, reflectionId: p.reflectionId, itemType: p.itemType, content: p.content,
                aux: p.aux, fromTheme: p.fromTheme, toTheme: p.toTheme,
                rationale: p.rationale, confidence: p.confidence) {
                queued += 1
                pendingByWorkspace[ws, default: 0] += 1
            }
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
    {"strays":[{"item":3,"belongs_in":"Northstar","confidence":"high","why":"about Northstar MDR economics, not this hiring workspace"}]}
    Return {"strays":[]} if everything is correctly filed.
    """

    private static func extractJSON(_ s: String) -> String? {
        guard let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}"), start < end else { return nil }
        return String(s[start...end])
    }
}
