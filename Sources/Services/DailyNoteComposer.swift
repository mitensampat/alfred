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

        // The morning email is the now tab in words (docs/rewire/SPEC.md, "channels"): the up-next line,
        // the top 3 from the same ranking, and at most one coach line. Same data as the app, so the two
        // never disagree.
        var schedules: [DailySchedule] = []
        if let orch = orchestrator, let cfg = config {
            for offset in 0..<2 {
                guard let day = Calendar.current.date(byAdding: .day, value: offset, to: Date()) else { continue }
                if let s = try? await orch.calendarServicePublic.fetchEventsFromAllCalendars(for: day, userSettings: cfg.user) {
                    schedules.append(s)
                }
            }
        }
        let now = TodoService.now(schedules: schedules, userFirstName: name)

        // 1. Today's shape (and the biggest open block worth protecting).
        let today = await calendarShape(orchestrator: orchestrator, dayOffset: 0)
        if today.count == 0 {
            lines.append("Today's calendar is clear. Spend it on the one thing only you can move.")
        } else {
            var l = "Today: \(today.count) meeting\(today.count == 1 ? "" : "s"), \(today.hoursStr) booked."
            if let gap = today.biggestGap { l += " Biggest open block: \(gap.durStr) at \(gap.startStr). Protect it." }
            lines.append(l)
        }

        // 2. The pinned to-do, then the top 3.
        let pinned = now["pinned"] as? [String: Any]
        let top = (now["top"] as? [[String: Any]]) ?? []
        func item(_ t: [String: Any]) -> String {
            let who = (t["person"] as? String) ?? (t["front_name"] as? String)
            let why = (t["why"] as? String) ?? ""
            return "• " + (t["title"] as? String ?? "") + (who.map { " (\($0)" + (why.isEmpty ? ")" : ", \(why))") } ?? (why.isEmpty ? "" : " (\(why))"))
        }
        if let p = pinned {
            lines.append("")
            lines.append("Pinned by you:")
            lines.append(item(p))
        }
        if !top.isEmpty {
            lines.append("")
            lines.append("Top of your list:")
            for t in top { lines.append(item(t)) }
            let more = ((now["more"] as? [[String: Any]]) ?? []).count
            if more > 0 { lines.append("…and \(more) more today.") }
        } else if pinned == nil {
            lines.append("")
            lines.append("Nothing is waiting on you. You are clear.")
        }

        // 3. One coach line, only if a trigger fired.
        if let coach = now["coach"] as? [String: Any], let text = coach["text"] as? String {
            lines.append("")
            lines.append("Alfred noticed: " + text)
        }
        let suggested = (now["suggested_count"] as? Int) ?? 0
        if suggested > 0 {
            lines.append("")
            lines.append("\(suggested) suggested to-do\(suggested == 1 ? "" : "s") waiting for you in Alfred.")
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
        let stop: Set<String> = ["in","and","of","the","for","to","vs","with","on","a","an","through","from","as","at","&"]
        let words = s.split(separator: " ").map(String.init)
        var out: [String] = []
        var len = 0
        for w in words {                        // keep whole words up to ~40 chars
            if len + w.count + 1 > 40 && !out.isEmpty { break }
            out.append(w); len += w.count + 1
        }
        while let last = out.last, stop.contains(last.lowercased()) { out.removeLast() }   // no dangling "in"/"and"
        if out.isEmpty { out = Array(words.prefix(3)) }
        return out.joined(separator: " ")
    }
    private static func firstSentence(_ s: String, _ cap: Int) -> String {
        var t = s.split(whereSeparator: { $0 == "." || $0 == "?" || $0 == "!" }).first.map(String.init) ?? s
        t = t.trimmingCharacters(in: .whitespaces)
        return t.count > cap ? String(t.prefix(cap - 1)) + "…" : t
    }
}
