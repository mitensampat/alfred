import Foundation

/// Fronts after the rewire (docs/rewire/SPEC.md, "fronts"; decisions 2026-11-05).
///
/// A front is an outcome the user owns, with stakes and a DATE. There are at most 10 active, and
/// nothing becomes a front on its own: Alfred proposes, the user confirms. Fronts are still self-model
/// themes underneath — the confirmation, date and outcome are user-authored keys in the theme's
/// metadata, carried across every recompute (SelfModelStore.userAuthoredMetaKeys).
///
/// Lifecycle (`front_state`): absent = a theme Alfred has not proposed or the user has not decided on;
/// `active` = a confirmed front; `paused`; `done`; `topic` = the user kept it as a plain tag.
enum FrontService {
    static let cap = 10
    /// A front with no completed to-do in this many days, or no open to-do at all, is stalled.
    static let stalledAfterDays = 7
    /// The bar: it must have moved in the last 14 days to be proposed.
    static let movedWithinDays = 14

    struct ThemeRow {
        let id: String
        let name: String
        let meta: [String: String]
        let state: [String: Any]   // ReflectionStore.getThemesWithState row (may be empty)
        let verdict: String?
    }

    // MARK: - Reads

    /// Themes are read several times per request (reconcile, ranking, cards); cache them briefly.
    /// Every write through setMeta clears the cache, so a change shows at once.
    private static var cache: (at: Date, rows: [ThemeRow])?
    private static let cacheLock = NSLock()
    static func invalidate() { cacheLock.lock(); cache = nil; cacheLock.unlock() }

    static func themes() -> [ThemeRow] {
        cacheLock.lock()
        if let c = cache, Date().timeIntervalSince(c.at) < 30 { cacheLock.unlock(); return c.rows }
        cacheLock.unlock()
        let rows = loadThemes()
        cacheLock.lock(); cache = (Date(), rows); cacheLock.unlock()
        return rows
    }

    private static func loadThemes() -> [ThemeRow] {
        let facets = SelfModelStore.shared.getFacets(kind: "theme")
        let states = ReflectionStore.shared.getThemesWithState(days: 120, limit: 400)
        var stateById: [String: [String: Any]] = [:]
        for s in states {
            let name = (s["theme"] as? String) ?? ""
            stateById[SelfModelSynthesizer.stableId("theme", name)] = s
        }
        return facets.compactMap { f in
            guard let id = f["id"] as? String else { return nil }
            let name = ((f["user_statement"] as? String)?.trimmedNonEmpty) ?? (f["statement"] as? String) ?? ""
            guard !name.isEmpty else { return nil }
            return ThemeRow(id: id, name: name,
                            meta: (f["metadata"] as? [String: String]) ?? [:],
                            state: stateById[id] ?? [:],
                            verdict: f["user_verdict"] as? String)
        }
    }

    static func activeThemes() -> [ThemeRow] {
        themes().filter { $0.meta["front_state"] == "active" && $0.verdict != "done" }
    }

    static func needsMigration() -> Bool {
        TodoStore.shared.meta("fronts_migrated") == nil
    }

    /// Short name for tags ("Series D raise" → "Series D raise"; long names are cut at 3 words).
    static func shortName(_ name: String) -> String {
        let words = name.split(separator: " ")
        return words.count <= 3 ? name : words.prefix(3).joined(separator: " ")
    }

    /// One active front as the app shows it: card + pulse, computed from the to-do list.
    static func card(_ t: ThemeRow, todos: [TodoStore.Todo]) -> [String: Any] {
        let mine = todos.filter { $0.frontId == t.id && $0.kind == .mine }
        let open = mine.filter { $0.status == .open }
        let doneRecently = mine.filter { td in
            guard td.status == .done, let d = td.doneAt, let date = ISO8601DateFormatter().date(from: d) else { return false }
            return Date().timeIntervalSince(date) < Double(stalledAfterDays) * 86400
        }
        let waiting = todos.filter { $0.frontId == t.id && $0.kind == .waiting && $0.status == .open }
        let daysSince = (t.state["days_since"] as? Int) ?? 0
        // Stalled: nothing moved it this week (no to-do done), or there is nothing on the list to move it.
        let stalled = doneRecently.isEmpty && (open.isEmpty || daysSince >= stalledAfterDays)
        let lastDone = mine.compactMap { $0.doneAt }.max()
        let stalledDays: Int = {
            if let l = lastDone, let d = ISO8601DateFormatter().date(from: l) {
                return max(stalledAfterDays, Int(Date().timeIntervalSince(d) / 86400))
            }
            return max(daysSince, stalledAfterDays)
        }()
        let decision = (t.meta["decision"]?.trimmedNonEmpty) ?? ""
        let next: String
        if !decision.isEmpty { next = "Decide: " + lowerFirst(decision) }
        else if let first = open.first { next = "Next: " + lowerFirst(first.title) }
        else { next = "No next step on your list" }
        var people = Set<String>()
        for td in mine + waiting { if let p = td.person, !p.isEmpty { people.insert(p) } }
        if let pj = t.meta["people_json"], let data = pj.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for p in arr { if let n = (p["name"] as? String)?.trimmedNonEmpty { people.insert(n) } }
        }
        let date = t.meta["front_date"] ?? ""
        return [
            "id": t.id,
            "name": t.name,
            "short": shortName(t.name),
            "outcome": t.meta["outcome"] ?? "",
            "date": date,
            "date_label": dateLabel(date),
            "decision": decision,
            "owner": t.meta["owner"] ?? "you",
            "pulse": stalled ? "stalled" : "moving",
            "stalled_days": stalled ? stalledDays : 0,
            "next": next,
            "todo_count": open.count,
            "people_count": people.count,
            "people": Array(people).sorted(),
            "last_activity": (t.state["last_activity"] as? String) ?? "",
            "days_since": daysSince,
            "pinned": t.meta["pinned"] == "1"
        ]
    }

    static func activeCards(todos: [TodoStore.Todo]) -> [[String: Any]] {
        let cards = activeThemes().map { card($0, todos: todos) }
        // Stalled first, then by date (soonest first; "none" last).
        return cards.sorted { a, b in
            let sa = (a["pulse"] as? String) == "stalled" ? 0 : 1
            let sb = (b["pulse"] as? String) == "stalled" ? 0 : 1
            if sa != sb { return sa < sb }
            let da = (a["date"] as? String).flatMap { $0 == "none" ? nil : $0.trimmedNonEmpty } ?? "9999"
            let db = (b["date"] as? String).flatMap { $0 == "none" ? nil : $0.trimmedNonEmpty } ?? "9999"
            return da < db
        }
    }

    /// Score a theme against the new bar. `passes` = all four tests hold.
    static func barScore(_ t: ThemeRow, todos: [TodoStore.Todo]) -> (score: Double, passes: Bool, reasons: [String]) {
        let owner = (t.meta["owner"] ?? "you").lowercased()
        let ownsIt = owner == "you" || t.meta["pinned"] == "1"
        let daysSince = (t.state["days_since"] as? Int) ?? 999
        let moved = daysSince <= movedWithinDays
        let inputs = (t.state["inputs_this_week"] as? Int) ?? 0
        let related = todos.filter { $0.frontId == t.id }
        var people = Set(related.compactMap { $0.person?.trimmedNonEmpty })
        if let pj = t.meta["people_json"], !pj.isEmpty, pj != "[]" { people.insert("curated") }
        let involvesOthers = !people.isEmpty || ((t.state["distinct_sources"] as? Int) ?? 0) >= 2
        let hasStakes = !((t.meta["decision"] ?? "").isEmpty) || ((t.state["open_questions_count"] as? Int) ?? 0) > 0
            || ((t.state["state"] as? String) ?? "") == "deciding"
        var reasons: [String] = []
        if inputs > 0 { reasons.append("\(inputs) thread\(inputs == 1 ? "" : "s") this week") }
        if !people.subtracting(["curated"]).isEmpty { reasons.append(people.subtracting(["curated"]).sorted().prefix(2).joined(separator: " and ") + " involved") }
        if let d = t.meta["decision"]?.trimmedNonEmpty { reasons.append("a decision is pending: " + lowerFirst(d)) }
        if ownsIt { reasons.append("you own the call") }
        var score: Double = Double(min(inputs, 10)) * 6
        if ownsIt { score += 30 }
        if moved { score += 25 }
        if involvesOthers { score += 20 }
        if hasStakes { score += 20 }
        score -= Double(min(daysSince, 60)) * 0.5
        return (score, ownsIt && moved && involvesOthers && hasStakes, reasons)
    }

    /// The single best proposal ("make this a front?"), or nil. Never shown while migration is pending
    /// or when the cap is full.
    static func proposal(todos: [TodoStore.Todo]) -> [String: Any]? {
        guard !needsMigration(), activeThemes().count < cap else { return nil }
        let candidates = themes().filter { $0.meta["front_state"] == nil && $0.verdict != "done" }
        let ranked = candidates.map { ($0, barScore($0, todos: todos)) }
            .filter { $0.1.passes }
            .sorted { $0.1.score > $1.1.score }
        guard let (t, s) = ranked.first else { return nil }
        let why = s.reasons.isEmpty ? "It keeps coming up and you own it." : (s.reasons.joined(separator: ", ").capitalizedFirst + ".")
        return ["id": t.id, "name": t.name, "why": why]
    }

    /// The one-time review of today's fronts, ranked by the new bar.
    static func migrationCandidates(todos: [TodoStore.Todo]) -> [[String: Any]] {
        let legacy = DeskService.buildFronts()
        let byId = Dictionary(themes().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let rows: [[String: Any]] = legacy.compactMap { f in
            guard let id = f["id"] as? String, let t = byId[id] else { return nil }
            let s = barScore(t, todos: todos)
            return ["id": id, "name": t.name, "score": s.score, "recommended": s.passes,
                    "why": s.reasons.joined(separator: ", "),
                    "date": t.meta["front_date"] ?? t.meta["next_date"] ?? "",
                    "decision": t.meta["decision"] ?? ""]
        }
        return rows.sorted { ($0["score"] as? Double ?? 0) > ($1["score"] as? Double ?? 0) }
    }

    // MARK: - Writes

    enum FrontError: Error { case dateRequired, cap(active: [[String: String]]), notFound }

    /// Write user-authored keys onto a theme facet (same path the desk front editor uses).
    @discardableResult
    static func setMeta(_ id: String, _ changes: [String: String?], name fallbackName: String? = nil) -> Bool {
        let store = SelfModelStore.shared
        let existing = store.getFacets(kind: "theme").first { ($0["id"] as? String) == id }
        guard existing != nil || fallbackName != nil else { return false }
        var meta = (existing?["metadata"] as? [String: String]) ?? [:]
        for (k, v) in changes {
            if let v = v { meta[k] = v } else { meta.removeValue(forKey: k) }
        }
        let now = ISO8601DateFormatter().string(from: Date())
        defer { invalidate() }
        return store.upsertFacet(
            id: id, kind: "theme",
            statement: (existing?["statement"] as? String) ?? fallbackName ?? "",
            confidence: (existing?["confidence"] as? Double) ?? 0.8,
            status: (existing?["status"] as? String) ?? "active",
            firstSeen: (existing?["first_seen"] as? String) ?? now,
            lastSeen: now,
            trajectory: (existing?["trajectory"] as? [[String: String]]) ?? [],
            evidence: (existing?["evidence"] as? [[String: String]]) ?? [],
            metadata: meta,
            origin: (existing?["origin"] as? String) ?? "manual",
            preserveUserMeta: false)
    }

    /// Valid date: yyyy-MM-dd, or the explicit "none" (decision: require a date, allow "no fixed date").
    static func validDate(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s == "none" { return s }
        return TodoStore.dayFormatter.date(from: s) != nil ? s : nil
    }

    static func activate(_ id: String, date: String?, outcome: String?, name: String? = nil) throws {
        guard let d = validDate(date) else { throw FrontError.dateRequired }
        let active = activeThemes()
        if !active.contains(where: { $0.id == id }) && active.count >= cap {
            throw FrontError.cap(active: active.map { ["id": $0.id, "name": $0.name] })
        }
        var changes: [String: String?] = ["front_state": "active", "front_date": d]
        if let o = outcome?.trimmingCharacters(in: .whitespacesAndNewlines), !o.isEmpty { changes["outcome"] = o }
        guard setMeta(id, changes, name: name) else { throw FrontError.notFound }
        if let decision = activeThemes().first(where: { $0.id == id })?.meta["decision"]?.trimmedNonEmpty {
            syncDecisionTodo(frontId: id, decision: decision)
        }
    }

    /// `none` clears the decision (used to undo "keep as a topic").
    static func setState(_ id: String, _ state: String) -> Bool {
        if state == "none" { return setMeta(id, ["front_state": nil]) }
        guard ["active", "paused", "done", "topic"].contains(state) else { return false }
        return setMeta(id, ["front_state": state])
    }

    /// Create a brand-new front from the add box ("+ new front").
    static func create(name: String, date: String?, outcome: String?) throws -> String {
        let id = SelfModelSynthesizer.stableId("theme", name)
        try activate(id, date: date, outcome: outcome, name: name)
        return id
    }

    /// The one-time migration: keep up to 10 (each with a date), everything else becomes a topic.
    static func migrate(keep: [String: String]) throws {
        guard keep.count <= cap else { throw FrontError.cap(active: []) }
        for (_, d) in keep where validDate(d) == nil { throw FrontError.dateRequired }
        for f in DeskService.buildFronts() {
            guard let id = f["id"] as? String else { continue }
            if let d = keep[id] {
                _ = setMeta(id, ["front_state": "active", "front_date": validDate(d)])
            } else {
                _ = setMeta(id, ["front_state": "topic"])
            }
        }
        TodoStore.shared.setMeta("fronts_migrated", TodoStore.nowISO())
        for t in activeThemes() {
            if let decision = t.meta["decision"]?.trimmedNonEmpty { syncDecisionTodo(frontId: t.id, decision: decision) }
        }
    }

    /// The open decision on an active front is also a to-do (high in the ranking).
    static func syncDecisionTodo(frontId: String, decision: String) {
        let name = activeThemes().first { $0.id == frontId }?.name
        let title = "Decide: " + lowerFirst(decision)
        let ref = frontId + "#" + SelfModelSynthesizer.stableId("decision", decision)
        TodoStore.shared.upsert(title: title, status: .open, kind: .mine, frontId: frontId,
                                frontName: name.map(shortName), source: "front_decision", sourceRef: ref,
                                sourceNote: "The one decision on \(name ?? "this front")")
    }

    // MARK: - Helpers

    static func lowerFirst(_ s: String) -> String {
        guard let f = s.first else { return s }
        // Keep acronyms and proper nouns ("RBI", "Kunal") as they are.
        let second = s.dropFirst().first
        if f.isUppercase, let c = second, c.isUppercase { return s }
        return f.lowercased() + s.dropFirst()
    }

    static func dateLabel(_ d: String) -> String {
        if d == "none" { return "no fixed date" }
        guard let date = TodoStore.dayFormatter.date(from: d) else { return "" }
        let f = DateFormatter(); f.dateFormat = "d MMM"
        return "by " + f.string(from: date)
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

extension String {
    /// The string trimmed, or nil when that leaves nothing (DeskService keeps its own private `nonEmpty`).
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
