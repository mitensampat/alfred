import Foundation

/// Builds "The Desk" surface — the CEO work environment that replaces the passive
/// Now workspace cards. The unit of work is *a person with a clock*, not a thought.
///
/// Three objects hold the screen:
///  - **queue**    who is blocked on you (commitments you owe), ranked by whose clock is
///                 running — calendar proximity + counterparty reliability + age/deadline.
///  - **fronts**   what the company is running (deal/raise/hire/product), from the
///                 promoted self-model themes + owner/stage metadata.
///  - **margin**   going-cold relationships + "your week, honestly".
///
/// A poster **first_move** leads with the anticipated next action — never the debt count.
/// The self-model is the ranking engine, surfaced as one cited "why this order" line;
/// it is NOT retired — the Model surface stays reachable and beliefs remain a capability.
///
/// `build` is pure/synchronous over the singleton stores; the caller supplies the
/// calendar `schedules` (index 0 = today, up to 7 days) since calendar fetch is async and
/// lives on the orchestrator. Everything degrades gracefully: no calendar → deadline-ranked
/// queue only; a front with no Notion stage → name + owner + last movement.
enum DeskService {

    /// A commitment I owe, "I Owe" in the tracker's raw type string.
    private static let iOweType = "I Owe"
    /// Age in days at which the clock turns hot.
    static let hotAgeDays = 7

    // MARK: - Entry point

    static func build(config: AppConfig?, schedules: [DailySchedule]) -> [String: Any] {
        let today = schedules.first

        // ── signals ──
        let counterparty = TaskLifecycleTracker.shared.getStatsByCounterparty()
        let reliabilityByName: [String: CounterpartyStats] = Dictionary(
            counterparty.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        // People you are meeting today — a clock you do not fully control.
        let todayAttendees = attendeeNames(today)

        // ── fronts (needed first so queue rows can cite their front) ──
        let fronts = buildFronts()
        let frontNames = fronts.compactMap { $0["name"] as? String }

        // ── queue ──
        // People = individuals with a clock. Commitments extracted from GROUP threads
        // (JID ends @g.us / @broadcast) are not a single person waiting on you — exclude
        // them so the People column stays people, not WhatsApp groups.
        let rawQueue = CommitmentScanTracker.shared.getAllOpenCommitments()
            .filter { $0.type == iOweType && !isGroupThread($0.threadId) && isQualityCommitment($0.title) }
        var scored: [(row: [String: Any], score: Double)] = []
        for c in rawQueue {
            let age = ageDays(from: c.extractedAt)
            let who = c.counterparty.trimmingCharacters(in: .whitespaces)
            let stats = reliabilityByName[who.lowercased()]
            let meetingToday = todayAttendees.contains { nameMatches($0, who) }
            let frontName = frontNames.first { nameMatches($0, c.title) || titleShares(c.title, $0) }

            // Ranking: a meeting today is the loudest clock; then a reliable counterparty
            // (your silence lands on them, not on the deal); then raw age.
            let reliability = stats?.completionRate ?? 0.5
            let score = (meetingToday ? 100.0 : 0)
                + reliability * 30.0
                + min(Double(age), 30) * 1.5

            scored.append((row: [
                "id": c.hash,
                "who": firstName(who),
                "who_full": who,
                "contact_id": who,
                "text": c.title,
                "age_days": age,
                "hot": age >= hotAgeDays,
                "front_id": frontName.map { SelfModelSynthesizer.stableId("theme", $0) } as Any,
                "front_name": frontName as Any,
                "verbs": verbs(for: c.title),
                "meeting_today": meetingToday,
                "reliability": Int((reliability * 100).rounded()),
                "time_critical": timeCritical(text: c.title, stats: stats)
            ], score: score))
        }
        let queue = scored.sorted { $0.score > $1.score }.map { $0.row }

        // ── margin ──
        // People already on the desk (open commitments) are surfaced in People — going-cold is
        // for relationships you're NOT tracking, so exclude them (full name + first name).
        var onDesk = Set<String>()
        for r in queue {
            if let full = (r["contact_id"] as? String)?.lowercased().trimmingCharacters(in: .whitespaces), !full.isEmpty {
                onDesk.insert(full)
                if let first = full.split(separator: " ").first { onDesk.insert(String(first)) }
            }
        }
        let goingCold = buildGoingCold(reliability: reliabilityByName, onDesk: onDesk)
        let frontsCold = buildFrontsCold(fronts: fronts)
        let week = buildWeek(queue: queue, fronts: fronts, schedules: schedules)

        // ── counts ──
        let deskCount = queue.count
        let overWeek = queue.filter { ($0["age_days"] as? Int ?? 0) >= hotAgeDays }.count
        let avgAge = queue.isEmpty ? 0.0
            : Double(queue.reduce(0) { $0 + ($1["age_days"] as? Int ?? 0) }) / Double(queue.count)

        // ── first move + why this order ──
        let firstMove = buildFirstMove(queue: queue, fronts: fronts, today: today,
                                       overWeek: overWeek, deskCount: deskCount)
        let why = whyThisOrder(queue: queue)

        // The board keeps its "what's running" order (stuck → moving → delegated). Send the
        // full promoted set (bounded) so search reaches every front; the client caps the
        // visible rows. front/person detail lookups still use the full set server-side.
        let frontsForBoard = Array(fronts.prefix(200))   // send all so top-stack/board search is complete

        // Top of the desk = ANTICIPATION, not just size: what is most likely top-of-mind right
        // now. Signals — a person in the front is on today's calendar (loudest), the front had
        // fresh activity this week, it recurs a lot, it's fresh, it's stuck on you. Pinned always
        // wins its slot; dismissed fronts are out. This drives only the 3-card stack.
        var frontMeetingToday = Set<String>()
        var frontMinAge: [String: Int] = [:]
        for r in queue {
            guard let fn = r["front_name"] as? String else { continue }
            if (r["meeting_today"] as? Bool) == true { frontMeetingToday.insert(fn) }
            let a = r["age_days"] as? Int ?? 99
            frontMinAge[fn] = min(frontMinAge[fn] ?? 99, a)
        }
        // Learned nudge (tenet 10): net act−skip per front id from prior top-card interactions.
        let learned = topEngagement()
        // A front top card, shaped to the frozen v2 tenets: move · why-now · stake, ranked by
        // leverage × asymmetry, cleared only if it truly earns the top.
        func frontTopCard(_ f: [String: Any]) -> (card: [String: Any], score: Double, clears: Bool) {
            let name = f["name"] as? String ?? ""
            let status = f["status"] as? String ?? "moving"
            let daysSinceF = f["days_since"] as? Int ?? 0
            let inputs = f["inputs_this_week"] as? Int ?? 0
            let ownedByYou = (f["owned_by_you"] as? Bool) ?? true
            let decision = (f["decision"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let pinned = (f["pinned"] as? Bool) == true
            let onCalendar = frontMeetingToday.contains(name)
            let recentAge = frontMinAge[name] ?? 99
            let recentBoost = recentAge <= 2 ? 80.0 : (recentAge <= 5 ? 40.0 : 0)
            // Tenet 1 (leverage): yours to move counts; delegated is not your top.
            // Tenet 3 (asymmetry): a crisp decision is one move that unlocks the whole front.
            let leverage = ownedByYou ? 50.0 : -40.0
            let actionable = decision.isEmpty ? 0.0 : 30.0
            let nudge = (Double(learned[(f["id"] as? String) ?? ""] ?? 0)) * 15.0   // tenet 10
            let score = (pinned ? 1000.0 : 0)
                + (onCalendar ? 300.0 : 0)
                + Double(inputs) * 20.0
                + recentBoost + leverage + actionable + nudge
                + max(0, 45 - Double(daysSinceF)) * 2.0
                + (status == "stuck" ? 40.0 : (status == "moving" ? 12.0 : 0))

            // Tenet 2: a real why-now — meeting/deadline OR neglect. Freshness alone is NOT one.
            var realWhyNow = true
            let whyNow: String
            if pinned { whyNow = "You pinned this" }
            else if onCalendar { whyNow = "On today's calendar" }
            else if status == "stuck" && ownedByYou { whyNow = "Stuck \(daysSinceF)d, on you" }
            else if inputs >= 3 { whyNow = "Came up \(inputs)× this week" }
            else if recentAge <= 2 { whyNow = "Active this week" }
            else if daysSinceF >= 21 && ownedByYou { whyNow = "Deferred \(daysSinceF)d — highest-leverage open" }
            else { whyNow = "Moving"; realWhyNow = false }

            // Tenet 4: a move, not a status.
            let move: String
            if !decision.isEmpty { move = "Decide: " + clause(decision) }
            else if status == "stuck" && ownedByYou { move = "Unblock " + shortTheme(name) }
            else { move = "Move " + shortTheme(name) + " forward" }

            // Tenet 5: stakes on the face.
            let stake: String
            if status == "stuck" { stake = shortTheme(name) + " stalls until you move" }
            else { stake = "Keeps " + shortTheme(name) + " alive" }

            // Tenet 9: earns the top only with a real why-now AND leverage (yours, or pinned).
            let clears = (pinned || (realWhyNow && ownedByYou)) && score >= 60

            var card = f
            card["move"] = move
            card["why_now"] = whyNow
            card["top_reason"] = whyNow
            card["stake"] = stake
            return (card, score, clears)
        }
        let rankedFronts = fronts
            .filter { ($0["top_dismissed"] as? Bool) != true }
            .map { frontTopCard($0) }
            .sorted { $0.score > $1.score }
        // Scarce (tenet 9): only cards that clear the bar; may be fewer than 3, may be none.
        let topFronts: [[String: Any]] = rankedFronts.filter { $0.clears }.prefix(3).map { $0.card }

        return [
            "enabled": true,
            "date_label": dateLabel(),
            "first_move": firstMove,
            "top_fronts": topFronts,
            "queue": queue,
            "fronts": frontsForBoard,
            "fronts_total": fronts.count,
            "going_cold": goingCold,
            "fronts_cold": frontsCold,
            "top_engagement": learned,
            "week": week,
            "desk_count": deskCount,
            "over_week": overWeek,
            "avg_unblock_days": (avgAge * 10).rounded() / 10,
            "why_this_order": why
        ]
    }

    // MARK: - Fronts

    /// Promoted self-model themes become fronts. `owner`/`stage`/`next_date`/`type`
    /// live in the theme facet metadata (new fields, set via /api/desk/front/meta); when
    /// absent we degrade to name + state + last movement rather than showing blank cells.
    static func buildFronts() -> [[String: Any]] {
        let store = SelfModelStore.shared
        let promoted = SelfModelService.promotedThemeIds(store: store)
        let facets = store.getFacets(kind: "theme")
        let doneIds = Set(facets
            .filter { ($0["user_verdict"] as? String) == "done" }
            .compactMap { $0["id"] as? String })
        // metadata by theme id, for owner/stage overrides.
        var metaById: [String: [String: String]] = [:]
        for f in facets {
            if let id = f["id"] as? String, let m = f["metadata"] as? [String: String] {
                metaById[id] = m
            }
        }

        let themes = ReflectionStore.shared.getThemesWithState(days: 60, limit: 200).filter {
            let id = SelfModelSynthesizer.stableId("theme", ($0["theme"] as? String) ?? "")
            return promoted.contains(id) && !doneIds.contains(id)
        }

        var out: [[String: Any]] = []
        for t in themes {
            let name = (t["theme"] as? String) ?? ""
            guard !name.isEmpty else { continue }
            let id = SelfModelSynthesizer.stableId("theme", name)
            let meta = metaById[id] ?? [:]
            let state = (meta["stage"]?.nonEmpty) ?? (t["state"] as? String) ?? "moving"
            let owner = (meta["owner"]?.nonEmpty) ?? "you"
            let daysSince = t["days_since"] as? Int ?? 0
            let decision = (meta["decision"]?.nonEmpty) ?? (t["edge"] as? String)?.nonEmpty ?? (t["question"] as? String) ?? ""
            let moved = (t["moved"] as? String) ?? (t["subtitle"] as? String) ?? ""
            let ownedByYou = owner.lowercased() == "you"

            // Status: accent = stuck on you; neutral-700 = moving; neutral-400 = running w/o you.
            let stuckOnYou = ownedByYou && daysSince >= hotAgeDays
            let status = stuckOnYou ? "stuck" : (ownedByYou ? "moving" : "delegated")

            var front: [String: Any] = [
                "id": id,
                "name": name,
                "type": (meta["type"]?.nonEmpty) ?? "workspace",
                "owner": owner,
                "stage": state,
                "days_since": daysSince,
                "status": status,
                "decision": decision,
                "moved": moved,
                "owned_by_you": ownedByYou,
                "pinned": meta["pinned"] == "1",
                "top_dismissed": meta["top_dismissed"] == "1",
                "inputs_this_week": Int(meta["inputs_this_week"] ?? "0") ?? 0
            ]
            if let next = meta["next_date"]?.nonEmpty { front["next_date"] = next }
            if stuckOnYou { front["stuck"] = ["days": daysSince, "on": "you"] }
            out.append(front)
        }

        // Pinned first; then stuck-on-you, moving, running-without-you; ties by recency.
        let rank: [String: Int] = ["stuck": 0, "moving": 1, "delegated": 2]
        out.sort {
            let pa = (($0["pinned"] as? Bool) == true) ? 0 : 1
            let pb = (($1["pinned"] as? Bool) == true) ? 0 : 1
            if pa != pb { return pa < pb }
            let ra = rank[$0["status"] as? String ?? "moving"] ?? 1
            let rb = rank[$1["status"] as? String ?? "moving"] ?? 1
            if ra != rb { return ra < rb }
            return ($0["days_since"] as? Int ?? 0) < ($1["days_since"] as? Int ?? 0)
        }
        return out
    }

    // MARK: - Going cold

    /// A going-cold row must clear four tenets, or it doesn't belong here:
    ///   1. It's a PERSON with a real human name — never a phone/JID/hex id, never a room
    ///      ("CRED Treasury Strategy", "peercheque founders" are topics, not relationships).
    ///   2. It's actually COLD — quiet ≥ `coldMinDays`. Someone you spoke to yesterday is not
    ///      cooling, no matter what a noisy engagement trend says.
    ///   3. It's NOT already on your desk — those are surfaced in People; showing them twice is
    ///      the redundancy that made this list read as noise.
    ///   4. The reason is specific to the row (days, reliability), never one canned sentence.
    static let coldMinDays = 7
    static let coldMaxDays = 60
    private static let roomWords: Set<String> = [
        "founders", "treasury", "strategy", "revenue", "team", "group", "leads", "directs",
        "updates", "channel", "board", "ops", "desk", "fund", "cohort", "sync", "standup",
        "room", "announcements", "broadcast", "circle", "council", "committee", "guild",
        "members", "core", "cards", "squad", "crew", "chapter", "club", "musketeers"
    ]
    /// True only for something that reads as a person's name (tenet 1). The desk is thick with
    /// company/room names ("CRED: Card Core", "FACE Members", "3 Musketeers", "Nash CRED"), so
    /// reject the tells: colons, leading digits, ALL-CAPS org acronyms, room words, multi-party.
    static func isRelationshipName(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, !s.hasPrefix("+") else { return false }        // empty / raw phone
        if let first = s.first, first.isNumber { return false }          // "3 Musketeers"
        if s.contains(":") { return false }                              // "CRED: Card Core"
        let letterCount = s.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        guard letterCount >= 2 else { return false }                     // needs real letters
        if s.range(of: "^[0-9a-fA-F]{16,}$", options: .regularExpression) != nil { return false }  // hex JID/id
        if s.contains("<>") || s.contains("|") || s.contains("/") || s.contains(" - ")
            || s.contains(" and ") || s.contains("&") { return false }   // multi-party room titles
        let words = s.split(separator: " ").map(String.init)
        // Real contacts are overwhelmingly "First Last"; 3+ capitalised tokens is far more often
        // a group of first names ("Ankit Sahil Miten") than a person. Bias to precision here.
        if words.count > 2 { return false }
        // An ALL-CAPS token of 3+ letters is an org/acronym (CRED, FACE, HDFC, NBFC), not a name.
        for w in words {
            let letters = w.filter { $0.isLetter }
            if letters.count >= 3 && letters == letters.uppercased() && letters != letters.lowercased() { return false }
        }
        let tokens = Set(s.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        if !tokens.isDisjoint(with: roomWords) { return false }          // topic/room, not a person
        return true
    }
    static func buildGoingCold(reliability: [String: CounterpartyStats], onDesk: Set<String>) -> [[String: Any]] {
        let threads = ContactLearner.shared.getAllThreads().filter { !$0.isGroup }
        var rows: [(row: [String: Any], days: Int)] = []
        var seen = Set<String>()
        for t in threads {
            let name = t.threadName.trimmingCharacters(in: .whitespaces)
            // Tenet 1: a real person's name.
            guard isRelationshipName(name) else { continue }
            let key = name.lowercased()
            if seen.contains(key) { continue }
            // Tenet 3: not already on your desk (by full name or first name).
            if onDesk.contains(key) { continue }
            if let first = key.split(separator: " ").first, onDesk.contains(String(first)) { continue }

            // Tenet 2: genuinely quiet — a real window, not yesterday, not ancient.
            let days = daysSince(t.lastSeen)
            guard days >= coldMinDays && days <= coldMaxDays else { continue }
            seen.insert(key)

            let summary = ContactLearner.shared.getContactSummary(name: name)
            let decreasing = summary?.engagementTrend == "decreasing"
            let stats = reliability[key]
            let unreliable = (stats?.overdueRate ?? 0) > 0.4 && (stats?.totalTasks ?? 0) >= 3
            // Tenet 4: specific to this row.
            var reason: String
            if unreliable, let s = stats {
                let late = Int((s.overdueRate * Double(s.completedTasks)).rounded())
                reason = "Owes you and runs late — \(late) of \(s.completedTasks). Chase, don't wait."
            } else if decreasing {
                reason = "\(days)d quiet and replies were thinning. Reopen before it sets."
            } else {
                reason = "\(days)d quiet. A nudge now beats a reintroduction later."
            }

            rows.append((row: [
                "name": name,
                "contact_id": name,
                "days": days,
                "hot": days >= hotAgeDays,
                "reason": reason,
                "chase": unreliable
            ], days: days))
        }
        // Freshest-cooling first (a 7-day slide is more recoverable than a 40-day one).
        return rows.sorted { $0.days < $1.days }.prefix(5).map { $0.row }
    }

    /// Fronts going cold — promoted fronts that have stalled: no movement in `coldFrontMinDays`,
    /// not yet decided. The Fronts-side analogue of relationships going cold (which is People-side).
    static let coldFrontMinDays = 14
    static func buildFrontsCold(fronts: [[String: Any]]) -> [[String: Any]] {
        var rows: [(row: [String: Any], days: Int)] = []
        for f in fronts {
            let days = f["days_since"] as? Int ?? 0
            let stage = (f["stage"] as? String ?? "").lowercased()
            guard days >= coldFrontMinDays, stage != "decided" else { continue }
            let owner = f["owner"] as? String ?? "you"
            let ownedByYou = owner.lowercased() == "you"
            let reason = ownedByYou
                ? "\(days)d without movement — it's yours to restart."
                : "\(days)d quiet under \(owner). Check it hasn't stalled."
            rows.append((row: [
                "id": f["id"] as? String ?? "",
                "name": f["name"] as? String ?? "",
                "days": days,
                "owner": owner,
                "hot": days >= 30,
                "reason": reason
            ], days: days))
        }
        // Longest-stalled first — the ones most in danger of quietly dying.
        return rows.sorted { $0.days > $1.days }.prefix(5).map { $0.row }
    }

    // MARK: - Week, honestly

    static func buildWeek(queue: [[String: Any]], fronts: [[String: Any]],
                          schedules: [DailySchedule]) -> [String: Any] {
        var meetingSecs = 0.0
        var focusSecs = 0.0
        for s in schedules {
            meetingSecs += s.events.filter { !$0.isAllDay }.reduce(0) { $0 + $1.duration }
            focusSecs += s.freeSlots.reduce(0) { $0 + $1.duration }
        }
        let overWeek = queue.filter { ($0["age_days"] as? Int ?? 0) >= hotAgeDays }.count
        let handedOff = fronts.filter { !(($0["owned_by_you"] as? Bool) ?? true) }.count
        let unattended = fronts.filter {
            !(($0["owned_by_you"] as? Bool) ?? true) && ($0["days_since"] as? Int ?? 0) >= hotAgeDays
        }.count

        return [
            "meeting_h": Int((meetingSecs / 3600.0).rounded()),
            "focus_h": Int((focusSecs / 3600.0).rounded()),
            "over_week": overWeek,
            "handed_off": handedOff,
            "unattended_fronts": unattended
        ]
    }

    // MARK: - First move (anticipation)

    /// next meeting attendee with an open owed item → oldest promise with a deadline →
    /// hottest front decision → protect focus time. Never leads with the debt count.
    static func buildFirstMove(queue: [[String: Any]], fronts: [[String: Any]],
                               today: DailySchedule?, overWeek: Int, deskCount: Int) -> [String: Any] {
        // 1. A person you are meeting today with something open on you.
        if let row = queue.first(where: { ($0["meeting_today"] as? Bool) ?? false }),
           let when = nextMeetingLabel(with: row["who_full"] as? String ?? "", today: today) {
            let who = row["who"] as? String ?? "them"
            return [
                "eyebrow": "First move · before your \(when)",
                "headline": "Send \(who) the \(shortThing(row["text"] as? String ?? "answer")) before you see \(pronounObject(who)) at \(when).",
                "sub": "The draft is written in your voice. Send it and the meeting starts from agreement instead of apology.",
                "clear_id": row["id"] as Any,
                "contact_id": row["contact_id"] as Any,
                "verb": "Done, sent it",
                "kind": "meeting"
            ]
        }
        // 2. The oldest promise still on you.
        if let row = queue.max(by: { ($0["age_days"] as? Int ?? 0) < ($1["age_days"] as? Int ?? 0) }),
           (row["age_days"] as? Int ?? 0) >= 2 {
            let who = row["who"] as? String ?? "them"
            let age = row["age_days"] as? Int ?? 0
            return [
                "eyebrow": "Next · oldest on your desk",
                "headline": "\(who): \(shortThing(row["text"] as? String ?? "the answer")). \(age) days old.",
                "sub": "Attach what you have and make the ask one sentence. Silence is the only answer they cannot work with.",
                "clear_id": row["id"] as Any,
                "contact_id": row["contact_id"] as Any,
                "verb": "Ship it now",
                "kind": "oldest"
            ]
        }
        // 3. The hottest front decision.
        if let f = fronts.first(where: { ($0["status"] as? String) == "stuck" }),
           let decision = (f["decision"] as? String)?.nonEmpty {
            return [
                "eyebrow": "Front · needs a call",
                "headline": decision,
                "sub": "\(f["name"] as? String ?? "This front") has been stuck on you. Whatever you pick, it can move on.",
                "front_id": f["id"] as Any,
                "verb": "Open the front",
                "kind": "front"
            ]
        }
        // 4. Nothing urgent — protect focus.
        return [
            "eyebrow": "Desk is moving",
            "headline": "Nothing urgent left. Protect an hour for deep work.",
            "sub": "\(deskCount) item\(deskCount == 1 ? "" : "s") can wait until tomorrow. Alfred re-ranks overnight and opens with the first move.",
            "verb": NSNull(),
            "kind": "clear"
        ]
    }

    // MARK: - Why this order

    static func whyThisOrder(queue: [[String: Any]]) -> [String: Any] {
        guard let top = queue.first else {
            return ["text": "Nothing is blocked on you right now.", "pattern": NSNull()]
        }
        let who = top["who"] as? String ?? "This"
        let meeting = (top["meeting_today"] as? Bool) ?? false
        let text: String
        if meeting {
            text = "\(who) is first because you see \(pronounObject(who)) today — the cost of your silence lands in the room."
        } else {
            text = "\(who) is first because they deliver — the cost of your silence lands on \(pronounObject(who)), not on the deal."
        }
        // Cite a real self-model pattern when one exists.
        let pattern = topPattern()
        return ["text": text, "pattern": pattern as Any]
    }

    /// A short, cited self-model pattern for the ranking-reason line.
    private static func topPattern() -> [String: Any]? {
        let patterns = SelfModelStore.shared.getFacets(kind: "pattern")
        guard let p = patterns.first,
              let stmt = (p["statement"] as? String)?.nonEmpty else { return nil }
        // reinforcement count from evidence, when present.
        var reinforced = 0
        if let ev = p["evidence"] as? [[String: String]] { reinforced = ev.count }
        return ["statement": stmt, "reinforced": reinforced]
    }

    // MARK: - Helpers

    private static func verbs(for text: String) -> [[String: Any]] {
        let t = text.lowercased()
        var primary: (String, String)
        if t.contains("approv") || t.contains("offer") || t.contains("sign off") || t.contains("decide") || t.contains("decision") {
            primary = ("Decide", "decided")
        } else if t.contains("reply") || t.contains("respond") || t.contains("feedback") || t.contains("answer") || t.contains("get back") {
            primary = ("Reply", "replied")
        } else if t.contains("send") || t.contains("share") || t.contains("ship") {
            primary = ("Ship it", "decided")
        } else {
            primary = ("Decide", "decided")
        }
        return [
            ["label": primary.0, "how": primary.1, "primary": true],
            ["label": "Hand off", "how": "handed_off", "primary": false]
        ]
    }

    private static func timeCritical(text: String, stats: CounterpartyStats?) -> Bool {
        let t = text.lowercased()
        // A rival offer / external clock you do not control.
        return t.contains("rival") || t.contains("another offer") || t.contains("competing") || t.contains("deadline")
    }

    private static func attendeeNames(_ schedule: DailySchedule?) -> [String] {
        guard let schedule = schedule else { return [] }
        return schedule.events
            .filter { !$0.isAllDay && $0.startTime > Date() }
            .flatMap { $0.attendees }
            .compactMap { $0.name?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The label ("2pm") of the next meeting today that includes `name`.
    private static func nextMeetingLabel(with name: String, today: DailySchedule?) -> String? {
        guard let today = today, !name.isEmpty else { return nil }
        let upcoming = today.events
            .filter { !$0.isAllDay && $0.startTime > Date() }
            .sorted { $0.startTime < $1.startTime }
        for e in upcoming where e.attendees.contains(where: { nameMatches($0.name ?? "", name) }) {
            let f = DateFormatter(); f.dateFormat = "ha"
            return f.string(from: e.startTime).lowercased()
        }
        return nil
    }

    private static func nameMatches(_ a: String, _ b: String) -> Bool {
        let al = a.lowercased(), bl = b.lowercased()
        guard !al.isEmpty, !bl.isEmpty else { return false }
        if al == bl { return true }
        let af = firstName(a).lowercased(), bf = firstName(b).lowercased()
        return af == bf || al.contains(bl) || bl.contains(al)
    }

    private static func titleShares(_ title: String, _ theme: String) -> Bool {
        let stop: Set<String> = ["the","and","for","with","from","that","this"]
        func toks(_ s: String) -> Set<String> {
            Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 3 && !stop.contains($0) })
        }
        return !toks(title).intersection(toks(theme)).isEmpty
    }

    private static func firstName(_ s: String) -> String {
        s.split(separator: " ").first.map(String.init) ?? s
    }

    private static func shortThing(_ text: String) -> String {
        // First clause before an em-dash / dash. Case preserved so acronyms (ESOP, TOFU)
        // stay legible.
        let head = text.components(separatedBy: CharacterSet(charactersIn: "—-–")).first ?? text
        return head.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ".", with: "")
    }

    private static func pronounObject(_ name: String) -> String { "them" }
    private static func pronounSubject(_ name: String) -> String { "they" }

    /// First sentence/clause of a decision, capped — the move fits one line.
    static func clause(_ s: String) -> String {
        let head = s.split(whereSeparator: { $0 == "." || $0 == "?" || $0 == "!" }).first.map(String.init) ?? s
        let t = head.trimmingCharacters(in: .whitespaces)
        return t.count > 88 ? String(t.prefix(86)).trimmingCharacters(in: .whitespaces) + "…" : t
    }
    /// Fronts are long theme names; keep the first few words for the move/stake lines.
    static func shortTheme(_ s: String) -> String {
        let t = s.split(separator: " ").prefix(5).joined(separator: " ")
        return t.count > 42 ? String(t.prefix(40)).trimmingCharacters(in: .whitespaces) + "…" : t
    }

    // MARK: - Top-desk learning (tenet 10)

    /// Where top-card act/skip events are persisted. Kept out of the self-model DB so a wipe of
    /// one never touches the other; small JSON, appended to on each interaction.
    static var topEventsPath: String {
        let dir = ProcessInfo.processInfo.environment["ALFRED_DIR"] ?? (NSHomeDirectory() + "/.alfred")
        return dir + "/desk_top_events.json"
    }
    /// Net signal per top-card id: +1 per act, −1 per skip/dismiss, decayed to the last 60 days.
    /// This is the seed of "it learns what amazing means to you" — it only bites once data exists.
    static func topEngagement() -> [String: Int] {
        guard let data = FileManager.default.contents(atPath: topEventsPath),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [:] }
        var net: [String: Int] = [:]
        for e in arr {
            guard let id = e["id"] as? String, let action = e["action"] as? String else { continue }
            if let ts = e["ts"] as? String, daysSince(ts) > 60 { continue }
            net[id, default: 0] += (action == "act" ? 1 : -1)
        }
        return net
    }
    /// Append one top-card interaction. `action` = "act" | "skip".
    @discardableResult
    static func recordTopEvent(id: String, kind: String, action: String) -> Bool {
        guard !id.isEmpty else { return false }
        var arr: [[String: Any]] = []
        if let data = FileManager.default.contents(atPath: topEventsPath),
           let existing = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            arr = existing
        }
        arr.append(["id": id, "kind": kind, "action": action,
                    "ts": ISO8601DateFormatter().string(from: Date())])
        if arr.count > 2000 { arr = Array(arr.suffix(2000)) }   // bound the file
        guard let out = try? JSONSerialization.data(withJSONObject: arr) else { return false }
        let dir = (topEventsPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return (try? out.write(to: URL(fileURLWithPath: topEventsPath))) != nil
    }

    private static func ageDays(from iso: String) -> Int {
        daysSince(iso)
    }

    /// Robust age-in-days for callers outside DeskService (e.g. HTTPServer.deskCounts).
    static func ageDaysPublic(from iso: String) -> Int { daysSince(iso) }

    /// True when a thread JID is a group / broadcast (not a single person).
    static func isGroupThread(_ jid: String) -> Bool {
        let j = jid.lowercased()
        return j.hasSuffix("@g.us") || j.contains("@broadcast")
    }

    /// A HIGH bar for what earns a spot on the desk. The extractor stamps every item at 0.8
    /// confidence (useless as a filter), so we gate on the title itself: reject vague filler
    /// ("working on it", "update on progress", "think about it") and pronoun-only stubs —
    /// things that name no concrete deliverable. Real, specific commitments pass.
    static func isQualityCommitment(_ title: String) -> Bool {
        let t = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let words = t.split(separator: " ")
        if words.count < 3 || t.count < 14 { return false }
        let vague = [
            "working on it","work through it","write it up","think more about it","think about it",
            "look into it","look into this","get back to","figure it out","figured out","do something",
            "sort it out","update on progress","update in evening","update in the","share idea in mind",
            "try one change","call him shortly","call her shortly","ask him to ping","ask her to ping",
            "circle back","will revert","will do it","keep you posted","keep him posted","let you know",
            "on it soon","will soon","update you soon","get to it","take a look","have a look","revert on this"
        ]
        for v in vague where t.contains(v) { return false }
        if words.count <= 4, let last = words.last,
           ["it","this","that","them","stuff","things","something","anything","soon","later","tomorrow"].contains(String(last)) { return false }
        return true
    }

    private static func daysSince(_ iso: String) -> Int {
        guard let d = parseDate(iso) else { return 0 }
        return max(0, Calendar.current.dateComponents([.day], from: d, to: Date()).day ?? 0)
    }

    private static func parseDate(_ s: String) -> Date? {
        if s.isEmpty || s == "unknown" { return nil }
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        if let d = f2.date(from: s) { return d }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if let d = df.date(from: s) { return d }
        df.dateFormat = "yyyy-MM-dd"
        return df.date(from: s)
    }

    private static func dateLabel() -> String {
        let f = DateFormatter(); f.dateFormat = "EEE dd MMM"
        return f.string(from: Date())
    }
}

private extension String {
    /// The string if non-empty after trimming, else nil — for metadata fallbacks.
    var nonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
