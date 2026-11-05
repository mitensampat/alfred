import Foundation

/// Coaching that speaks only when it is earned (docs/rewire/SPEC.md, "coaching").
///
/// Silence is the default. A line appears on the now tab only when one of these triggers fires,
/// every line cites its numbers, and the rules cap the noise:
///  - one line on screen at a time, at most two distinct lines a day;
///  - a dismissed trigger stays quiet for 7 days unless its number gets worse.
///
/// Everything else coaching produces (skill cards, lens signals) rolls into the weekly review.
enum CoachTriggerService {
    static let perDay = 2
    static let quietDays = 7

    struct Line { let key: String; let metric: Int; let text: String; let action: String; let target: String? }

    // MARK: - Evaluate

    static func candidates(todos: [TodoStore.Todo], schedules: [DailySchedule]) -> [Line] {
        var out: [Line] = []
        let cards = FrontService.activeCards(todos: todos)

        // 1. A front is stalled and nothing on your list moves it.
        for c in cards where (c["pulse"] as? String) == "stalled" && (c["todo_count"] as? Int ?? 0) == 0 {
            let days = c["stalled_days"] as? Int ?? FrontService.stalledAfterDays
            let name = c["name"] as? String ?? "A front"
            out.append(Line(key: "stalled:\(c["id"] as? String ?? "")", metric: days,
                            text: "\(name) has not moved in \(days) days, and nothing on your list moves it.",
                            action: "add_step", target: c["id"] as? String))
        }

        // 2. Small to-dos cleared while a front's decision ages.
        let weekAgo = Date().addingTimeInterval(-7 * 86400)
        let iso = ISO8601DateFormatter()
        let doneThisWeek = todos.filter { t in
            t.status == .done && t.source != "front_decision" && (t.doneAt.flatMap { iso.date(from: $0) } ?? .distantPast) > weekAgo
        }.count
        if doneThisWeek >= 5,
           let decision = todos.filter({ $0.status == .open && $0.source == "front_decision" })
            .max(by: { TodoService.ageDays($0.createdAt) < TodoService.ageDays($1.createdAt) }),
           TodoService.ageDays(decision.createdAt) >= 7 {
            let age = TodoService.ageDays(decision.createdAt)
            let front = decision.frontName ?? "front"
            out.append(Line(key: "decision_ages:\(decision.id)", metric: age,
                            text: "You closed \(doneThisWeek) items this week; the \(front) decision is \(age) days old.",
                            action: "block_hour", target: decision.id))
        }

        // 3. Tomorrow is heavy and something must happen tonight.
        let hour = Calendar.current.component(.hour, from: Date())
        if hour >= 17, schedules.count > 1 {
            let tmr = schedules[1]
            let hours = Int((tmr.totalMeetingTime / 3600).rounded())
            let count = tmr.events.filter { !$0.isAllDay }.count
            if hours >= 5 || count >= 6 {
                let tomorrow = TodoStore.dayFormatter.string(from: Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date())
                if let must = todos.filter({ $0.status == .open && $0.kind == .mine && ($0.due ?? "9999") <= tomorrow }).first {
                    out.append(Line(key: "heavy_tomorrow:\(tomorrow)", metric: hours,
                                    text: "Tomorrow has \(hours) hours of meetings. \"\(must.title)\" cannot wait.",
                                    action: "do_now", target: must.id))
                }
            }
        }

        // 4. Someone important is going quiet while you owe them.
        var silent: [String: Int] = [:]
        for th in ContactLearner.shared.getAllThreads() where !th.isGroup {
            let n = th.threadName.trimmingCharacters(in: .whitespaces).lowercased()
            silent[n] = min(silent[n] ?? Int.max, DeskService.ageDaysPublic(from: th.lastSeen))
        }
        for t in todos where t.status == .open && t.kind == .mine {
            guard let p = t.person, let days = silent[p.lowercased()], days >= 21 else { continue }
            let first = p.split(separator: " ").first.map(String.init) ?? p
            out.append(Line(key: "quiet:\(p.lowercased())", metric: days,
                            text: "\(first) has been silent \(days) days, and you still owe: \(FrontService.lowerFirst(t.title)).",
                            action: "draft", target: p))
        }

        // 5. A self-model pattern that repeats (weekly at most): the strongest recurring signal.
        if let pattern = recurringPattern() { out.append(pattern) }
        return out
    }

    /// The single line to show now, honouring the caps and dismissals. nil = stay silent.
    static func current(todos: [TodoStore.Todo], schedules: [DailySchedule]) -> [String: Any]? {
        let today = TodoStore.today()
        var shown = decode(TodoStore.shared.meta("coach_shown_\(today)")) as? [String] ?? []
        let dismissed = decode(TodoStore.shared.meta("coach_dismissed")) as? [String: [String: Any]] ?? [:]
        let live = candidates(todos: todos, schedules: schedules).filter { line in
            guard let d = dismissed[line.key] else { return true }
            let until = d["until"] as? String ?? ""
            let metric = d["metric"] as? Int ?? 0
            return until < today || line.metric > metric
        }
        // Keep showing a line already shown today; otherwise only if today's budget allows.
        let pick = live.first { shown.contains($0.key) } ?? (shown.count < perDay ? live.first : nil)
        guard let line = pick else { return nil }
        if !shown.contains(line.key) {
            shown.append(line.key)
            TodoStore.shared.setMeta("coach_shown_\(today)", encode(shown))
        }
        var out: [String: Any] = ["key": line.key, "text": line.text, "action": line.action, "metric": line.metric]
        out["target"] = line.target as Any? ?? NSNull()
        out["action_label"] = [
            "add_step": "Add the next step", "block_hour": "Block an hour", "do_now": "Do it now",
            "draft": "Draft a message", "protect": "Protect the slot"
        ][line.action] ?? "Open"
        return out
    }

    static func dismiss(key: String, metric: Int) {
        var dismissed = decode(TodoStore.shared.meta("coach_dismissed")) as? [String: [String: Any]] ?? [:]
        let until = TodoStore.dayFormatter.string(from: Calendar.current.date(byAdding: .day, value: quietDays, to: Date()) ?? Date())
        dismissed[key] = ["until": until, "metric": metric]
        TodoStore.shared.setMeta("coach_dismissed", encode(dismissed))
    }

    // MARK: - Pattern (trigger 5)

    /// At most weekly: the analysis lens signal that recurred most this week, if it recurred 3+ times.
    static func recurringPattern() -> Line? {
        let week = Calendar.current.component(.weekOfYear, from: Date())
        let key = "pattern_week:\(week)"
        // Count each signal type across the last 7 days; a pattern is a type seen on 3+ days.
        var days: [String: Int] = [:]
        var evidence: [String: String] = [:]
        for offset in 0..<7 {
            guard let d = Calendar.current.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let types = Set(SignalStore.shared.getSignalsForDate(TodoStore.dayFormatter.string(from: d))
                .filter { $0.confidence >= 0.6 }
                .map { s -> String in
                    if evidence[s.type] == nil, let e = s.evidence?.trimmedNonEmpty { evidence[s.type] = e }
                    return s.type
                })
            for t in types { days[t, default: 0] += 1 }
        }
        guard let (name, n) = days.max(by: { $0.value < $1.value }), n >= 3 else { return nil }
        let label = name.replacingOccurrences(of: "_", with: " ")
        let detail = evidence[name].map { " " + $0 } ?? ""
        return Line(key: key, metric: n, text: "\(label.capitalizedFirst) showed up on \(n) of the last 7 days.\(detail)",
                    action: "protect", target: nil)
    }

    // MARK: - JSON helpers

    private static func decode(_ s: String?) -> Any? {
        guard let s = s, let d = s.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d)
    }
    private static func encode(_ v: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: v)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
