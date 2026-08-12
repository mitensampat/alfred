import Foundation

/// The one morning email: a tight, plain-text note written for a CEO — at most ~15 lines, no chrome.
/// It replaces the elaborate briefing + attention emails. Deterministic (pulls the same Desk data the
/// app shows) so it never says something the surface contradicts.
enum DailyNoteComposer {

    static func compose(orchestrator: BriefingOrchestrator?) async -> (subject: String, plain: String, html: String) {
        let config = AppConfig.load()
        let name = config?.user.name.split(separator: " ").first.map(String.init) ?? "there"
        let df = DateFormatter(); df.dateFormat = "EEE d MMM"
        let dateStr = df.string(from: Date())
        var lines: [String] = []

        // 1. Today's shape.
        let today = await calendarShape(orchestrator: orchestrator, dayOffset: 0)
        if today.count == 0 {
            lines.append("Today's calendar is clear — a rare open day. Spend it on the one thing only you can move.")
        } else {
            var l = "Today: \(today.count) meeting\(today.count == 1 ? "" : "s"), \(today.hoursStr) booked."
            if let gap = today.biggestGap { l += " Biggest open block: \(gap.durStr) at \(gap.startStr) — protect it." }
            lines.append(l)
        }

        // 2. Who's waiting on you (top 3, oldest first).
        let waiting = DeskService.buildPeople()
            .filter { (($0["you_owe"] as? Int) ?? 0) > 0 }
            .prefix(3)
        if !waiting.isEmpty {
            lines.append("")
            lines.append("Waiting on you:")
            for p in waiting {
                let who = p["name"] as? String ?? ""
                let owe = p["you_owe"] as? Int ?? 0
                let age = p["oldest_age"] as? Int ?? 0
                lines.append("• \(who) — \(age)d, \(owe) open")
            }
        }

        // 3. Decide (top 1–2 hot/deciding fronts, with the one question).
        let fronts = DeskService.buildFronts()
        let toDecide = fronts.filter {
            let stage = ($0["stage"] as? String ?? "").lowercased()
            let temp = ($0["temperature"] as? String ?? "")
            return (stage == "deciding" || temp == "hot") && !(($0["decision"] as? String ?? "").isEmpty)
        }.prefix(2)
        if !toDecide.isEmpty {
            lines.append("")
            lines.append("Decide:")
            for f in toDecide {
                let short = shortName(f["name"] as? String ?? "")
                let q = firstSentence(f["decision"] as? String ?? "", 110)
                lines.append("• \(short): \(q)")
            }
        }

        // 4. Going quiet + a relationship to tend (the two deterministic coach signals).
        let neglected = fronts
            .filter { (($0["owned_by_you"] as? Bool) ?? true) && (($0["days_since"] as? Int) ?? 0) >= 14 }
            .sorted { (($0["days_since"] as? Int) ?? 0) > (($1["days_since"] as? Int) ?? 0) }
        if let f = neglected.first {
            let d = f["days_since"] as? Int ?? 0
            lines.append("")
            lines.append("Going quiet: \(shortName(f["name"] as? String ?? "")) — \(d)d untouched, yours to restart.")
        }
        let reliability = Dictionary(
            TaskLifecycleTracker.shared.getStatsByCounterparty().map { ($0.name.lowercased(), $0) },
            uniquingKeysWith: { a, _ in a })
        if let c = DeskService.buildGoingCold(reliability: reliability, onDesk: Set()).first {
            let who = c["name"] as? String ?? ""
            lines.append("Tend: \(who) — \(firstSentence(c["reason"] as? String ?? "", 90))")
        }

        // 5. Tomorrow heads-up (only when heavy — reuses the evening-nudge logic).
        if let ev = await CoachingPushService.shared.eveningNudgeContent(orchestrator: orchestrator) {
            lines.append("")
            lines.append(ev.body)
        }

        let greeting = "Good morning, \(name). \(dateStr)."
        let plain = greeting + "\n\n" + lines.joined(separator: "\n")
        let html = "<pre style=\"font:15px/1.55 -apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;white-space:pre-wrap;color:#14171c;max-width:640px;margin:0;\">"
            + plain.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            + "</pre>"
        return (subject: "Your day — \(dateStr)", plain: plain, html: html)
    }

    // MARK: - helpers

    private struct DayShape { let count: Int; let hoursStr: String; let biggestGap: (durStr: String, startStr: String)? }

    private static func calendarShape(orchestrator: BriefingOrchestrator?, dayOffset: Int) async -> DayShape {
        guard let orch = orchestrator, let config = AppConfig.load(),
              let day = Calendar.current.date(byAdding: .day, value: dayOffset, to: Date()) else {
            return DayShape(count: 0, hoursStr: "0h", biggestGap: nil)
        }
        let events: [CalendarEvent]
        do {
            let sched = try await orch.calendarServicePublic.fetchEventsFromAllCalendars(for: day, userSettings: config.user)
            events = sched.events.filter { !$0.isAllDay }
        } catch { return DayShape(count: 0, hoursStr: "0h", biggestGap: nil) }
        guard !events.isEmpty else { return DayShape(count: 0, hoursStr: "0h", biggestGap: nil) }
        let hours = events.reduce(0.0) { $0 + $1.endTime.timeIntervalSince($1.startTime) } / 3600.0
        let hoursStr = hours.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(hours))h" : String(format: "%.1fh", hours)
        let cal = Calendar.current
        let dayStart = cal.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
        let dayEnd = cal.date(bySettingHour: 18, minute: 0, second: 0, of: day) ?? day
        let sorted = events.sorted { $0.startTime < $1.startTime }
        var cursor = dayStart, bestGap = 0.0, bestStart = dayStart
        for e in sorted {
            if e.startTime > cursor { let g = e.startTime.timeIntervalSince(cursor); if g > bestGap { bestGap = g; bestStart = cursor } }
            if e.endTime > cursor { cursor = e.endTime }
        }
        if dayEnd > cursor { let g = dayEnd.timeIntervalSince(cursor); if g > bestGap { bestGap = g; bestStart = cursor } }
        var gap: (String, String)? = nil
        if bestGap >= 45 * 60 {
            let m = Int(bestGap / 60)
            let durStr = m >= 60 ? "\(m/60)h\(m % 60 > 0 ? String(format: "%02d", m % 60) : "")" : "\(m)m"
            let hf = DateFormatter(); hf.dateFormat = "h:mm a"
            gap = (durStr, hf.string(from: bestStart))
        }
        return DayShape(count: events.count, hoursStr: hoursStr, biggestGap: gap.map { (durStr: $0.0, startStr: $0.1) })
    }

    private static func shortName(_ s: String) -> String {
        let head = s.split(separator: " ").prefix(4).joined(separator: " ")
        return head.count > 42 ? String(head.prefix(41)) + "…" : head
    }
    private static func firstSentence(_ s: String, _ cap: Int) -> String {
        var t = s.split(whereSeparator: { $0 == "." || $0 == "?" || $0 == "!" }).first.map(String.init) ?? s
        t = t.trimmingCharacters(in: .whitespaces)
        return t.count > cap ? String(t.prefix(cap - 1)) + "…" : t
    }
}
