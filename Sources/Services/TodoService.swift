import Foundation

/// The rewire's to-do engine (docs/rewire/SPEC.md): pulls every source into TodoStore, ranks the
/// list, and builds the payloads the new app reads (now, to-dos, people, agenda).
///
/// Nothing here replaces an existing pipeline. The commitment extractor, the WhatsApp to-do scan and
/// the Notion task databases keep doing what they did; this layer reconciles their output into one
/// list and keeps the two in step (closing a to-do closes its commitment, and a commitment the tracker
/// closes on its own closes the to-do).
enum TodoService {

    // MARK: - Suggestions (every extracted to-do comes in through here)

    /// Add an extracted to-do as a suggestion, applying what Alfred has learned: corrected person
    /// names, the user's own front tagging, and hiding what the user keeps dismissing (with a reason,
    /// recoverable from the tray for 14 days). Returns the to-do id and whether it was new.
    @discardableResult
    static func suggest(title: String, person rawPerson: String?, due: String? = nil, source: String, sourceRef: String,
                        sourceNote: String?, threadId: String? = nil, confidence: Double = 1.0,
                        status: TodoStore.Status = .suggested, kind: TodoStore.Kind = .mine,
                        fronts: [FrontService.ThemeRow]? = nil) -> (id: String, created: Bool) {
        let store = TodoStore.shared
        if let existing = store.linkedTodoId(source: source, ref: sourceRef) { return (existing, false) }
        let person = TodoLearning.canonicalPerson(rawPerson)
        let active = fronts ?? FrontService.activeThemes()
        let front = TodoLearning.learnedFront(title: title, active: active) ?? matchFront(title: title, fronts: active)
        let r = store.upsert(title: title, status: status, kind: kind, due: due, frontId: front?.id,
                             frontName: front.map { FrontService.shortName($0.name) }, person: person,
                             source: source, sourceRef: sourceRef, sourceNote: sourceNote, threadId: threadId, confidence: confidence)
        if r.created, status == .suggested, let why = TodoLearning.hideReason(title: title, person: person, source: source) {
            store.update(r.id, ["status": TodoStore.Status.dismissed.rawValue, "hidden_reason": why], markDirty: false)
        }
        return r
    }

    // MARK: - Reconcile sources

    /// Bring the commitment tracker into the to-do list. Cheap; called on every list read.
    ///
    ///  - "I owe" → a to-do you own. New ones arrive as SUGGESTED (they were extracted, not typed).
    ///    The very first reconcile imports what is already on the user's desk as OPEN, because those
    ///    are items they have been working from; only items extracted after the switch wait in the tray.
    ///  - "They owe me" → `waiting`, shown only inside the person / front.
    ///  - a linked commitment the tracker closed (auto-closure, 30-day sweep, desk clear) → done.
    static func reconcileCommitments() {
        let store = TodoStore.shared
        let firstRun = store.meta("commitments_imported") == nil
        let open = CommitmentScanTracker.shared.getAllOpenCommitments()
            .filter { !DeskService.isGroupThread($0.threadId) && DeskService.isQualityCommitment($0.title) }
        let fronts = FrontService.activeThemes()
        for c in open {
            let mine = c.type == "I Owe"
            let person = c.counterparty.trimmingCharacters(in: .whitespaces).trimmedNonEmpty
            let status: TodoStore.Status = mine ? (firstRun ? .open : .suggested) : .open
            let platform = c.threadId.contains("@") ? "WhatsApp" : "a thread"
            let r = suggest(title: c.title, person: person, source: "commitment", sourceRef: c.hash,
                    sourceNote: person.map { "From \(platform) with \($0.split(separator: " ").first.map(String.init) ?? $0)" },
                    threadId: c.threadId, confidence: c.confidence, status: status, kind: mine ? .mine : .waiting, fronts: fronts)
            // A new to-do arrives with the words it came from.
            if r.created, let ev = CommitmentScanTracker.shared.evidence(hash: c.hash) {
                store.update(r.id, ["evidence": ev.quote, "evidence_by": ev.saidBy ?? NSNull(), "evidence_at": ev.saidAt ?? NSNull()],
                             markDirty: false, touch: false)
            }
        }
        if firstRun { store.setMeta("commitments_imported", TodoStore.nowISO()) }
        normalizeAndMerge()
        TodoEvidence.backfillIfDue()

        // Closures that happened in the tracker flow back.
        let openHashes = Set(CommitmentScanTracker.shared.getOpenCommitmentHashes())
        for t in store.all(where: "status IN ('open', 'suggested') AND source = 'commitment'") {
            let refs = store.sources(of: t.id).filter { $0.source == "commitment" }.map { $0.ref }
            guard !refs.isEmpty, refs.allSatisfy({ !openHashes.contains($0) }) else { continue }
            store.update(t.id, ["status": TodoStore.Status.done.rawValue, "done_at": TodoStore.nowISO()])
            store.appendHistory(t.id, ["at": TodoStore.nowISO(), "event": "closed by the commitment tracker"])
        }
    }

    // MARK: - One to-do, one row

    /// "→ Asha: Send the deck" / "← Asha: Review the proposal": the old commitment format, where
    /// the arrow is the direction (→ you owe, ← they owe) and the name is the counterparty.
    static func parseArrowTitle(_ raw: String) -> (direction: String, person: String, title: String)? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard let arrow = t.first, arrow == "→" || arrow == "←" else { return nil }
        let rest = t.dropFirst().trimmingCharacters(in: .whitespaces)
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let person = rest[..<colon].trimmingCharacters(in: .whitespaces)
        let title = rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !person.isEmpty, person.count <= 60, !title.isEmpty else { return nil }
        return (arrow == "→" ? "i_owe" : "they_owe", person, title)
    }

    private static var normalizedThisProcess = false

    /// Make each promise one row.
    ///
    /// The old Notion task database stored commitments as "→ Name: title", and the one-time import
    /// took those titles whole. So the person and the direction sat inside the title where nothing
    /// could use them: the same promise appeared twice (once from the commitment tracker, once from
    /// Notion) because the two titles no longer matched, the person filters missed every import, and
    /// what others owed the user sat in the user's own list.
    ///
    /// This parses the prefix into real fields, moves "they owe" items to `waiting` (the store's own
    /// rule for them), recovers the thread and the true age from the extraction log where it can,
    /// then merges any live rows that are now the same promise. Nothing is deleted: the losing row
    /// is closed with a history entry naming the row it was merged into, and its source links move
    /// to the survivor so a later scan does not recreate it.
    static func normalizeAndMerge() {
        if normalizedThisProcess { return }
        normalizedThisProcess = true
        let store = TodoStore.shared
        let live = "status IN ('open', 'suggested')"
        var parsed = 0, moved = 0, merged = 0
        for t in store.all(where: live) {
            guard let p = parseArrowTitle(t.title) else { continue }
            let person = TodoLearning.canonicalPerson(p.person) ?? p.person
            var f: [String: Any?] = ["title": p.title, "person": person, "direction": p.direction]
            if p.direction == "they_owe", t.kind == .mine { f["kind"] = TodoStore.Kind.waiting.rawValue; moved += 1 }
            // Never a group thread: a to-do with a person and a thread offers "reply", and that
            // reply must go to the person, not to everyone in the group it was said in.
            if t.threadId == nil, let ex = CommitmentScanTracker.shared.findExtraction(title: p.title, counterparty: p.person),
               !DeskService.isGroupThread(ex.threadId) {
                f["thread_id"] = ex.threadId
                if let at = ex.extractedAt { f["created_at"] = ISO8601DateFormatter().string(from: at) }
            }
            store.update(t.id, f)
            store.appendHistory(t.id, ["at": TodoStore.nowISO(), "event": "person and direction read from the title", "was": t.title])
            parsed += 1
        }
        var groups: [String: [TodoStore.Todo]] = [:]
        for t in store.all(where: live, order: "created_at ASC") {
            groups[t.kind.rawValue + "|" + TodoStore.dedupeKey(title: t.title, person: t.person), default: []].append(t)
        }
        for (_, rows) in groups where rows.count > 1 {
            // The tracker's row survives: it has the thread, the evidence and the closure machinery.
            let winner = rows.first { $0.source == "commitment" } ?? rows.first { $0.threadId != nil } ?? rows[0]
            for loser in rows where loser.id != winner.id { merge(loser, into: winner.id); merged += 1 }
        }
        if parsed + merged > 0 {
            print("🧹 To-dos: \(parsed) titles parsed into person + direction, \(moved) moved to waiting, \(merged) duplicates merged")
        }
    }

    /// Fold one row into another that is the same promise.
    static func merge(_ loser: TodoStore.Todo, into winnerId: String) {
        let store = TodoStore.shared
        guard let winner = store.get(winnerId), winner.id != loser.id else { return }
        var f: [String: Any?] = [:]
        if winner.due == nil, let d = loser.due { f["due"] = d }
        if winner.frontId == nil, let fr = loser.frontId { f["front_id"] = fr; f["front_name"] = loser.frontName ?? NSNull() }
        if winner.threadId == nil, let th = loser.threadId { f["thread_id"] = th }
        // A copy the user wrote themselves means it is on the list. A copy that came back from the
        // old Notion database does not: that is Alfred's own extraction returning by another road,
        // and an extraction waits in the tray until the user accepts it.
        if winner.status == .suggested, loser.status == .open, ["capture", "notion_mirror"].contains(loser.source) {
            f["status"] = TodoStore.Status.open.rawValue
        }
        if loser.pinned { f["pinned"] = true }
        if !f.isEmpty { store.update(winner.id, f) }
        store.relinkSources(from: loser.id, to: winner.id)
        store.update(loser.id, ["status": TodoStore.Status.dismissed.rawValue, "done_at": TodoStore.nowISO(), "pinned": false])
        store.appendHistory(loser.id, ["at": TodoStore.nowISO(), "event": "merged into \(winner.id)"])
        store.appendHistory(winner.id, ["at": TodoStore.nowISO(), "event": "absorbed duplicate \(loser.id)", "was": loser.title])
    }

    /// A front a title belongs to: a distinctive word (>4 chars, not a stopword) of the front's name
    /// appears in the title.
    static func matchFront(title: String, fronts: [FrontService.ThemeRow]) -> FrontService.ThemeRow? {
        let stop: Set<String> = ["about", "their", "there", "these", "which", "other", "would", "could", "should",
                                 "review", "update", "follow", "meeting", "product", "design", "program", "launch"]
        let words = Set(title.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 3 })
        var best: (FrontService.ThemeRow, Int)?
        for f in fronts {
            let fw = f.name.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 4 && !stop.contains($0) }
            let hits = fw.filter { words.contains($0) }.count
            if hits > 0, hits > (best?.1 ?? 0) { best = (f, hits) }
        }
        return best?.0
    }

    /// One-time import of the old Notion task databases (open items only) as open to-dos.
    /// Runs only once — so it must not record success after a failure. A Notion outage on the very
    /// first run used to mark the import done anyway, silently skipping the user's existing tasks
    /// for good. The marker is written only when every configured database was actually read.
    static func importNotionTasks(notion: NotionService, databaseIds: [String]) async -> Int {
        let store = TodoStore.shared
        guard store.meta("notion_imported") == nil else { return 0 }
        let ids = databaseIds.filter { !$0.isEmpty }
        guard !ids.isEmpty else { return 0 }   // nothing configured yet: try again next cycle
        var n = 0
        var allRead = true
        for dbId in ids {
            guard let pages = try? await NotionTodoMirror.queryOpenPages(notion: notion, databaseId: dbId) else {
                print("⚠️ Notion import: could not read database \(dbId); will retry")
                allRead = false
                continue
            }
            for p in pages {
                // Commitments in the old database are titled "→ Name: …": read the person and the
                // direction out of the title instead of importing them as part of it.
                let arrow = parseArrowTitle(p.title)
                // A commitment the tracker extracted is written to that database by the scanner
                // itself. Importing it back would put an extraction straight onto the list, past
                // the suggestion tray, and a second time. The tracker is its way in.
                if let a = arrow, CommitmentScanTracker.shared.findExtraction(title: a.title, counterparty: a.person) != nil { continue }
                let r = store.upsert(title: arrow?.title ?? p.title, status: .open,
                                     kind: arrow?.direction == "they_owe" ? .waiting : .mine, due: p.due,
                                     person: arrow.map { TodoLearning.canonicalPerson($0.person) ?? $0.person },
                                     source: "notion_import", sourceRef: p.id, sourceNote: "Imported from Notion")
                if r.created, let a = arrow { store.update(r.id, ["direction": a.direction], markDirty: false, touch: false) }
                if r.created { n += 1 }
            }
        }
        if allRead { store.setMeta("notion_imported", TodoStore.nowISO()) }
        return n
    }

    // MARK: - Actions

    struct ActionResult { let ok: Bool; let receipt: String; let closeHashes: [String]; let reopenHashes: [String] }

    static func complete(_ id: String) -> ActionResult {
        let store = TodoStore.shared
        guard let t = store.get(id) else { return ActionResult(ok: false, receipt: "Not found", closeHashes: [], reopenHashes: []) }
        store.update(id, ["status": TodoStore.Status.done.rawValue, "done_at": TodoStore.nowISO(), "pinned": false])
        let hashes = store.sources(of: id).filter { $0.source == "commitment" }.map { $0.ref }
        for h in hashes { CommitmentScanTracker.shared.markCommitmentClosed(hash: h, closureMethod: "done") }
        return ActionResult(ok: true, receipt: "Done · " + t.title, closeHashes: hashes, reopenHashes: [])
    }

    static func reopen(_ id: String) -> ActionResult {
        let store = TodoStore.shared
        guard let t = store.get(id) else { return ActionResult(ok: false, receipt: "Not found", closeHashes: [], reopenHashes: []) }
        store.update(id, ["status": TodoStore.Status.open.rawValue, "done_at": NSNull(), "snoozed_until": NSNull()])
        let hashes = store.sources(of: id).filter { $0.source == "commitment" }.map { $0.ref }
        return ActionResult(ok: true, receipt: "Back on your list · " + t.title, closeHashes: [], reopenHashes: hashes)
    }

    static func accept(_ id: String) -> Bool {
        guard let t = TodoStore.shared.get(id) else { return false }
        TodoLearning.accepted(t)
        return TodoStore.shared.update(id, ["status": TodoStore.Status.open.rawValue, "hidden_reason": NSNull()])
    }

    /// Dismiss a suggestion. A dismissed commitment is closed in the tracker too, so it does not
    /// come back on the next scan; the dismissal itself is the learning signal.
    static func dismiss(_ id: String) -> [String] {
        let store = TodoStore.shared
        if let t = store.get(id) { TodoLearning.dismissed(t) }
        store.update(id, ["status": TodoStore.Status.dismissed.rawValue, "done_at": TodoStore.nowISO()])
        let hashes = store.sources(of: id).filter { $0.source == "commitment" }.map { $0.ref }
        for h in hashes { CommitmentScanTracker.shared.markCommitmentClosed(hash: h, closureMethod: "dismissed") }
        return hashes
    }

    /// Take back a dismissal: the to-do returns to where it was (the suggestion tray or the list),
    /// its commitments reopen, and the dismissal stops counting as a lesson.
    static func undismiss(_ id: String, to: String?) -> ActionResult {
        let store = TodoStore.shared
        guard let t = store.get(id), t.status == .dismissed else { return ActionResult(ok: false, receipt: "Not found", closeHashes: [], reopenHashes: []) }
        let status: TodoStore.Status = to == "suggested" ? .suggested : .open
        store.update(id, ["status": status.rawValue, "done_at": NSNull(), "hidden_reason": NSNull()])
        store.removeLatestFeedback(event: "dismissed", todoId: id)
        CorrectionTracker.shared.withdrawFalsePositive(title: t.title)
        TodoLearning.invalidate()
        let hashes = store.sources(of: id).filter { $0.source == "commitment" }.map { $0.ref }
        return ActionResult(ok: true, receipt: "Restored · " + t.title, closeHashes: [], reopenHashes: hashes)
    }

    /// "Not now": move to tomorrow (or a given day) and count the skip, which lowers its rank.
    static func snooze(_ id: String, until: String?) -> String {
        let store = TodoStore.shared
        let day = until.flatMap { TodoStore.dayFormatter.date(from: $0) != nil ? $0 : nil }
            ?? TodoStore.dayFormatter.string(from: Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date())
        let skips = (store.get(id)?.skipCount ?? 0) + 1
        store.update(id, ["snoozed_until": day, "skip_count": skips, "pinned": false], markDirty: false)
        return day
    }

    // MARK: - Ranking

    struct Context {
        let todayEvents: [CalendarEvent]
        let tomorrow: DailySchedule?
        let activeFrontIds: Set<String>
    }

    static func isSnoozed(_ t: TodoStore.Todo) -> Bool {
        guard let s = t.snoozedUntil else { return false }
        return s > TodoStore.today()
    }

    /// today / upcoming / someday for one to-do.
    static func bucket(_ t: TodoStore.Todo) -> String {
        let today = TodoStore.today()
        if isSnoozed(t) { return "upcoming" }
        if t.pinned { return "today" }
        if let d = t.due { return d <= today ? "today" : "upcoming" }
        // Someone is waiting, or it is a front's decision: that is today's business.
        if t.source == "front_decision" || t.source == "commitment" { return "today" }
        // A person on an undated item from the old Notion list is a label, not a deadline: those
        // stay in someday (grouped by person) rather than flooding today.
        if t.person != nil && t.source != "notion_import" { return "today" }
        return "someday"
    }

    static func ageDays(_ iso: String) -> Int {
        guard let d = ISO8601DateFormatter().date(from: iso) else { return 0 }
        return max(0, Int(Date().timeIntervalSince(d) / 86400))
    }

    static func meetsToday(_ person: String?, ctx: Context) -> CalendarEvent? {
        guard let p = person?.lowercased(), let first = p.split(separator: " ").first.map(String.init) else { return nil }
        return ctx.todayEvents.first { e in
            !e.isAllDay && e.endTime > Date() && e.attendees.contains { a in
                let n = (a.name ?? a.email).lowercased()
                return n == p || n.hasPrefix(first + " ") || n == first || a.email.lowercased().hasPrefix(first)
            }
        }
    }

    /// Score + the "why now" line for one to-do (SPEC.md, "how the top 3 are ranked").
    static func score(_ t: TodoStore.Todo, ctx: Context) -> (score: Double, why: String, urgent: Bool) {
        var s = 0.0
        var why: String? = nil
        var urgent = false
        let today = TodoStore.today()
        let age = ageDays(t.createdAt)
        if let e = meetsToday(t.person, ctx: ctx) {
            s += 100
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            why = "you meet at " + f.string(from: e.startTime)
        }
        if t.source == "front_decision" {
            s += 60
            if why == nil { why = age > 0 ? "decision \(age) day\(age == 1 ? "" : "s") old" : "the open decision"; urgent = age >= 7 }
        }
        if let d = t.due {
            if d < today { s += 70; if why == nil { why = "overdue"; urgent = true } }
            else if d == today { s += 60; if why == nil { why = "due today" } }
            else if let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()),
                    d == TodoStore.dayFormatter.string(from: tomorrow) { s += 20; if why == nil { why = "due tomorrow" } }
        }
        if t.person != nil && age >= 7 {
            s += 30 + Double(min(age, 30))
            if why == nil { why = "waiting \(age) days"; urgent = true }
        } else if t.person != nil {
            s += Double(age) * 2
            if why == nil { why = age == 0 ? "asked today" : "waiting \(age) day\(age == 1 ? "" : "s")" }
        }
        if let f = t.frontId, ctx.activeFrontIds.contains(f) { s += 20 }
        s -= Double(t.skipCount) * 15
        return (s, why ?? (t.frontName.map { "on \($0)" } ?? "on your list"), urgent)
    }

    static func card(_ t: TodoStore.Todo, ctx: Context) -> [String: Any] {
        var d = t.dict
        let sc = score(t, ctx: ctx)
        d["score"] = sc.score
        d["why"] = sc.why
        d["urgent"] = sc.urgent
        d["bucket"] = bucket(t)
        d["action"] = t.source == "front_decision" ? "decide" : ((t.person != nil && t.threadId != nil) ? "reply" : "done")
        d["age_days"] = ageDays(t.createdAt)
        return d
    }

    // MARK: - Payloads

    static func context(schedules: [DailySchedule]) -> Context {
        Context(todayEvents: schedules.first?.events ?? [],
                tomorrow: schedules.count > 1 ? schedules[1] : nil,
                activeFrontIds: Set(FrontService.activeThemes().map { $0.id }))
    }

    /// The now tab: up next (Alfred's line or the pinned to-do), top 3, the rest of today, coach line.
    /// `coach: false` for callers that will not show the coach line (push, WhatsApp): evaluating it
    /// counts against the two-a-day budget.
    static func now(schedules: [DailySchedule], userFirstName: String, coach: Bool = true) -> [String: Any] {
        reconcileCommitments()
        let ctx = context(schedules: schedules)
        let all = TodoStore.shared.openMine()
        let today = all.filter { bucket($0) == "today" }
        let pinned = all.first { $0.pinned && !isSnoozed($0) }
        let ranked = today.filter { $0.id != pinned?.id }
            .map { (t: $0, s: score($0, ctx: ctx).score) }
            .sorted { $0.s > $1.s }
            .map { $0.t }
        let top = Array(ranked.prefix(3))
        let rest = Array(ranked.dropFirst(3))
        var out: [String: Any] = [
            "date_label": dateLabel(),
            "top": top.map { card($0, ctx: ctx) },
            "more": rest.map { card($0, ctx: ctx) },
            "suggested_count": TodoStore.shared.suggestions().count
        ]
        if let p = pinned { out["pinned"] = card(p, ctx: ctx) }
        out["up_next"] = upNext(top: top, ctx: ctx, schedules: schedules)
        out["coach"] = coach ? (CoachTriggerService.current(todos: TodoStore.shared.all(), schedules: schedules) ?? NSNull()) : NSNull()
        return out
    }

    /// Alfred's one sentence for this moment (SPEC.md, "up next card").
    static func upNext(top: [TodoStore.Todo], ctx: Context, schedules: [DailySchedule]) -> [String: Any] {
        let now = Date()
        let hour = Calendar.current.component(.hour, from: now)
        let tf = DateFormatter(); tf.dateFormat = "HH:mm"
        let events = ctx.todayEvents.filter { !$0.isAllDay }.sorted { $0.startTime < $1.startTime }
        let first = top.first

        // Within 60 minutes of a meeting: prep for it.
        if let e = events.first(where: { $0.startTime > now && $0.startTime.timeIntervalSince(now) <= 3600 }) {
            let mins = max(1, Int(e.startTime.timeIntervalSince(now) / 60))
            let who = e.attendees.first { !$0.isOrganizer }?.name ?? e.attendees.first?.name
            let owed = TodoStore.shared.openMine().first { t in
                guard let p = t.person?.lowercased(), let w = who?.lowercased() else { return false }
                return p == w || p.split(separator: " ").first == w.split(separator: " ").first
            }
            var line = "\(e.title) in \(mins) minute\(mins == 1 ? "" : "s")."
            if let o = owed, let w = who { line += " Still open with \(w.split(separator: " ").first.map(String.init) ?? w): " + FrontService.lowerFirst(o.title) + "." }
            return ["kind": "prep", "text": line, "time": tf.string(from: now),
                    "action": "Open prep", "person": who as Any? ?? NSNull(), "event_title": e.title]
        }
        // Evening: what tomorrow needs tonight.
        if hour >= 18 {
            let tmr = ctx.tomorrow
            let hours = Int(((tmr?.totalMeetingTime ?? 0) / 3600).rounded())
            let count = tmr?.events.filter { !$0.isAllDay }.count ?? 0
            var line = count == 0 ? "Tomorrow is open." : "Tomorrow has \(count) meeting\(count == 1 ? "" : "s"), \(hours) hour\(hours == 1 ? "" : "s") in all."
            if let f = first { line += " Clear \"\(f.title)\" tonight." }
            return ["kind": "evening", "text": line, "time": tf.string(from: now), "action": first == nil ? NSNull() : "Open" as Any]
        }
        // Morning / day: the shape of the day.
        let remaining = events.filter { $0.endTime > now }
        var line: String
        if remaining.isEmpty { line = "No more meetings today." }
        else if let next = remaining.first {
            line = "\(remaining.count) meeting\(remaining.count == 1 ? "" : "s") left today. Next: \(next.title) at \(tf.string(from: next.startTime))."
        } else { line = "" }
        if let f = first { line += " The one that matters: " + FrontService.lowerFirst(f.title) + "." }
        return ["kind": hour < 12 ? "morning" : "day", "text": line.trimmingCharacters(in: .whitespaces),
                "time": tf.string(from: now), "action": NSNull()]
    }

    /// The to-dos tab: suggested tray + today / upcoming / someday, optionally filtered.
    static func list(filter: String?, schedules: [DailySchedule]) -> [String: Any] {
        reconcileCommitments()
        let ctx = context(schedules: schedules)
        let f = (filter ?? "all").lowercased()
        let pass: (TodoStore.Todo) -> Bool = { t in
            f == "all" || t.frontId?.lowercased() == f || (t.person?.lowercased() ?? "") == f
                || (t.person?.lowercased().split(separator: " ").first.map(String.init) ?? "") == f
        }
        let open = TodoStore.shared.openMine().filter(pass)
        func section(_ b: String) -> [[String: Any]] {
            var rows = open.filter { bucket($0) == b }
            if b == "today" { rows.sort { score($0, ctx: ctx).score > score($1, ctx: ctx).score } }
            if b == "upcoming" { rows.sort { ($0.snoozedUntil ?? $0.due ?? "9") < ($1.snoozedUntil ?? $1.due ?? "9") } }
            return rows.map { card($0, ctx: ctx) }
        }
        // Filter chips: active fronts + the people with the most open to-dos.
        var personCounts: [String: Int] = [:]
        for t in TodoStore.shared.openMine() { if let p = t.person { personCounts[p, default: 0] += 1 } }
        let topPeople = personCounts.sorted { $0.value > $1.value }.prefix(4).map { ["key": $0.key, "label": $0.key.split(separator: " ").first.map(String.init) ?? $0.key] }
        let frontChips = FrontService.activeThemes().map { ["key": $0.id, "label": FrontService.shortName($0.name)] }
        return [
            "suggested": TodoStore.shared.suggestions()
                .sorted { TodoLearning.acceptance(source: $0.source, person: $0.person) > TodoLearning.acceptance(source: $1.source, person: $1.person) }
                .map { $0.dict },
            "hidden": TodoStore.shared.hidden().map { t -> [String: Any] in
                var d = t.dict; d["hidden_reason"] = TodoStore.shared.hiddenReason(t.id) ?? ""; return d },
            "learning": TodoLearning.summary(),
            "today": section("today"),
            "upcoming": section("upcoming"),
            "someday": section("someday"),
            // What others owe you. Never ranked with your own work; listed so it stays in sight.
            "waiting": TodoStore.shared.waiting().filter(pass)
                .sorted { ($0.due ?? "9") == ($1.due ?? "9") ? $0.createdAt < $1.createdAt : ($0.due ?? "9") < ($1.due ?? "9") }
                .map { t -> [String: Any] in var d = t.dict; d["age_days"] = ageDays(t.createdAt); d["bucket"] = "waiting"; return d },
            "chips": [["key": "all", "label": "All"]] + frontChips + topPeople,
            "filter": f
        ]
    }

    /// The people tab: one flat list, every candidate exactly once.
    ///
    /// The server no longer pre-sorts rows into "waiting on you" and "going quiet" and drops the
    /// rest — that is how anyone who only owed *you* something, and had been in touch inside three
    /// weeks, used to be built into a row and then thrown away. Every candidate comes back with its
    /// counts and flags, and the app sections the pins and filters the rest.
    ///
    /// Candidates are anyone named on an open to-do in either direction, plus everyone pinned
    /// (`PinnedPeopleStore`) — so a pinned person has a row even with nothing open, which is the
    /// whole point of pinning them.
    static func people() -> [String: Any] {
        reconcileCommitments()
        // Group by a case-folded key and keep the first spelling seen as the display name, so a pin
        // saved as "alex carter" and a to-do that says "Alex Carter" are one person, not two.
        var mineBy: [String: [TodoStore.Todo]] = [:]
        var waitBy: [String: [TodoStore.Todo]] = [:]
        var display: [String: String] = [:]
        func key(_ raw: String) -> String {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let k = trimmed.lowercased()
            if display[k] == nil { display[k] = trimmed }
            return k
        }
        for t in TodoStore.shared.openMine() { if let p = t.person { mineBy[key(p), default: []].append(t) } }
        for t in TodoStore.shared.waiting() { if let p = t.person { waitBy[key(p), default: []].append(t) } }

        var lastSeen: [String: Int] = [:]
        for th in ContactLearner.shared.getAllThreads() where !th.isGroup {
            let n = th.threadName.trimmingCharacters(in: .whitespaces).lowercased()
            lastSeen[n] = min(lastSeen[n] ?? Int.max, DeskService.ageDaysPublic(from: th.lastSeen))
        }

        let pins = PinnedPeopleStore.shared.all()
        let pinKeys = Set(pins.map { key($0) })

        func row(_ k: String) -> [String: Any] {
            let name = display[k] ?? k
            let items = (mineBy[k] ?? []).sorted { $0.createdAt < $1.createdAt }
            let owed = waitBy[k] ?? []
            let silent = lastSeen[k]
            let anythingOpen = !items.isEmpty || !owed.isEmpty
            return ["name": name,
                    "initials": initials(name),
                    "you_owe": items.count,
                    "they_owe": owed.count,
                    "oldest_days": items.first.map { ageDays($0.createdAt) } ?? 0,
                    "line": items.first?.title ?? (owed.first.map { "Waiting on: " + $0.title } ?? "Nothing open yet."),
                    "more": max(0, items.count - 1),
                    "silent_days": silent as Any? ?? NSNull(),
                    "quiet": (silent ?? 0) >= 21 && anythingOpen,
                    "pinned": pinKeys.contains(k)]
        }

        // Pins first, in the order you pinned them; then everyone else, longest-waiting first,
        // falling back to the longest silence so a they-owe-only row still sorts sensibly.
        let pinnedRows = pins.map { row(key($0)) }
        let rest = Set(mineBy.keys).union(waitBy.keys).subtracting(pinKeys).map(row)
            .sorted {
                let a = $0["oldest_days"] as? Int ?? 0, b = $1["oldest_days"] as? Int ?? 0
                if a != b { return a > b }
                let qa = $0["silent_days"] as? Int ?? 0, qb = $1["silent_days"] as? Int ?? 0
                if qa != qb { return qa > qb }
                // Name last, so the order is stable: the candidates come out of a Set, whose
                // iteration order varies between requests, and without this the tab visibly
                // reshuffles people every time it loads.
                return ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "")
            }
        return ["people": pinnedRows + rest, "pinned_count": pinnedRows.count]
    }

    /// A person's page: what you owe, what you are waiting on, fronts together, next meeting.
    static func person(_ name: String, schedules: [DailySchedule]) -> [String: Any] {
        let key = name.lowercased()
        let first = key.split(separator: " ").first.map(String.init) ?? key
        let match: (TodoStore.Todo) -> Bool = { t in
            guard let p = t.person?.lowercased() else { return false }
            return p == key || p.split(separator: " ").first.map(String.init) == first && key.split(separator: " ").count == 1
        }
        let ctx = context(schedules: schedules)
        let owe = TodoStore.shared.openMine().filter(match).map { card($0, ctx: ctx) }
        let wait = TodoStore.shared.waiting().filter(match).map { t -> [String: Any] in
            var d = t.dict; d["age_days"] = ageDays(t.createdAt); return d
        }
        var frontIds = Set<String>()
        for t in TodoStore.shared.all(where: "status IN ('open', 'done')") where match(t) { if let f = t.frontId { frontIds.insert(f) } }
        let fronts = FrontService.activeThemes().filter { frontIds.contains($0.id) }.map { ["id": $0.id, "name": FrontService.shortName($0.name)] }
        // Next meeting across the loaded days.
        let tf = DateFormatter(); tf.dateFormat = "EEE d MMM, HH:mm"
        var next: String? = nil
        outer: for s in schedules {
            for e in s.events.sorted(by: { $0.startTime < $1.startTime }) where e.startTime > Date() {
                if e.attendees.contains(where: { (($0.name ?? $0.email).lowercased()).hasPrefix(first) }) {
                    next = "\(e.title) · \(tf.string(from: e.startTime))"; break outer
                }
            }
        }
        // Reliability only with 5+ completed items (SPEC.md, "people").
        let stats = TaskLifecycleTracker.shared.getStatsByCounterparty().first { $0.name.lowercased() == key }
        var reliability: Any = NSNull()
        if let s = stats, s.completedTasks >= 5 { reliability = Int(((1 - s.overdueRate) * 100).rounded()) }
        return ["name": name, "initials": initials(name), "owe": owe, "waiting": wait,
                "fronts": fronts, "next_meeting": next as Any? ?? NSNull(), "on_time_pct": reliability,
                "pinned": PinnedPeopleStore.shared.isPinned(name)]
    }

    /// Today's agenda for the wide layouts' right column.
    static func agenda(schedules: [DailySchedule]) -> [[String: Any]] {
        let tf = DateFormatter(); tf.dateFormat = "HH:mm"
        let open = TodoStore.shared.openMine()
        return (schedules.first?.events ?? []).filter { !$0.isAllDay && $0.endTime > Date() }
            .sorted { $0.startTime < $1.startTime }
            .map { e in
                let who = e.attendees.first { !$0.isOrganizer }?.name
                let owed = open.first { t in
                    guard let p = t.person?.lowercased(), let w = who?.lowercased() else { return false }
                    return p.split(separator: " ").first == w.split(separator: " ").first
                }
                var note = who ?? ""
                if let o = owed { note += (note.isEmpty ? "" : " · ") + "open: " + FrontService.lowerFirst(o.title) }
                return ["time": tf.string(from: e.startTime), "title": e.title, "note": note,
                        "person": who as Any? ?? NSNull(), "owed": owed != nil]
            }
    }

    // MARK: - Helpers

    static func initials(_ name: String) -> String {
        name.split(separator: " ").prefix(2).compactMap { $0.first.map { String($0).uppercased() } }.joined()
    }

    static func dateLabel() -> String {
        let f = DateFormatter(); f.dateFormat = "EEEE, d MMMM"
        return f.string(from: Date())
    }
}
