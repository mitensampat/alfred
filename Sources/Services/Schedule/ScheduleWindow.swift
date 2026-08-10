import Foundation

/// Freeform window phrases → search horizon, preferred weekdays, and slot formatting.
/// Faithful port of Commit's schedule/window.go + the shared slot formatters. Weekdays use Go's
/// convention (Sun=0 … Sat=6) to match ScheduleSlots.Prefs.
enum ScheduleWindow {

    private static func cal(_ tz: TimeZone) -> Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = tz; return c
    }
    /// Go weekday (Sun=0 … Sat=6).
    static func goWeekday(_ d: Date, _ tz: TimeZone) -> Int { cal(tz).component(.weekday, from: d) - 1 }
    private static func addDays(_ d: Date, _ n: Int, _ tz: TimeZone) -> Date {
        cal(tz).date(byAdding: .day, value: n, to: d) ?? d.addingTimeInterval(Double(n) * 86400)
    }

    /// Convert a window phrase into a [from, to) horizon. Unknown phrases → tomorrow..+7d.
    static func range(_ window: String, now: Date, tz: TimeZone) -> (from: Date, to: Date) {
        let c = cal(tz)
        let sod = { (t: Date) in c.startOfDay(for: t) }
        let n = now
        let w = window.lowercased().trimmingCharacters(in: .whitespaces)

        if w == "today" { return (n, addDays(sod(n), 1, tz)) }
        if w == "tomorrow" || w == "tmrw" { let d = addDays(sod(n), 1, tz); return (d, addDays(d, 1, tz)) }
        if w.contains("next week") {
            var d = sod(n)
            while goWeekday(d, tz) != 1 || !(d > sod(n)) { d = addDays(d, 1, tz) }
            return (d, addDays(d, 7, tz))
        }
        if w.contains("this week") || w == "week" {
            var d = sod(n)
            while goWeekday(d, tz) != 0 { d = addDays(d, 1, tz) }   // to Sunday
            return (n, addDays(d, 1, tz))
        }
        if w.contains("weekend") {
            var d = sod(n)
            while goWeekday(d, tz) != 6 { d = addDays(d, 1, tz) }   // to Saturday
            return (d, addDays(d, 2, tz))
        }
        if w.contains("next month") {
            let comps = c.dateComponents([.year, .month], from: n)
            let firstThis = c.date(from: comps) ?? sod(n)
            let d = c.date(byAdding: .month, value: 1, to: firstThis) ?? addDays(firstThis, 30, tz)
            return (d, addDays(d, 14, tz))
        }
        // Single weekday → next occurrence (from tomorrow).
        if let wd = firstWeekday(in: w) {
            var d = addDays(sod(n), 1, tz)
            while goWeekday(d, tz) != wd { d = addDays(d, 1, tz) }
            return (d, addDays(d, 1, tz))
        }
        return (addDays(sod(n), 1, tz), addDays(sod(n), 8, tz))   // default
    }

    // Sun=0 … Sat=6
    private static let weekdayWords: [String: Int] = [
        "sun": 0, "sunday": 0, "sundays": 0,
        "mon": 1, "monday": 1, "mondays": 1,
        "tue": 2, "tues": 2, "tuesday": 2, "tuesdays": 2,
        "wed": 3, "weds": 3, "wednesday": 3, "wednesdays": 3,
        "thu": 4, "thur": 4, "thurs": 4, "thursday": 4, "thursdays": 4,
        "fri": 5, "friday": 5, "fridays": 5,
        "sat": 6, "saturday": 6, "saturdays": 6
    ]

    private static func firstWeekday(in w: String) -> Int? {
        for (word, wd) in weekdayWords where w == word || w.hasPrefix(word + " ") || w.hasSuffix(" " + word) { return wd }
        return nil
    }

    /// Specific weekdays named in a window ("Tue/Wed preferred" → [2,3]); [] when none.
    static func preferredDays(_ window: String) -> [Int] {
        let w = window.lowercased()
        let fields = w.split(whereSeparator: { !($0.isLetter) }).map(String.init)
        var seen = Set<Int>(); var out: [Int] = []
        for f in fields { if let wd = weekdayWords[f], !seen.contains(wd) { seen.insert(wd); out.append(wd) } }
        return out
    }

    /// Render weekdays the way a person says them: "Tue/Wed".
    static func formatDays(_ days: [Int]) -> String {
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return days.map { names[$0] }.joined(separator: "/")
    }
}

/// Shared slot formatting, matching Commit's formatSlotLine / FormatSlotList / FormatSlotShort.
enum ScheduleFmt {
    private static func df(_ pattern: String, _ tz: TimeZone) -> DateFormatter {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = tz; f.dateFormat = pattern; return f
    }
    static func slotLine(_ i: Int, _ s: ScheduleSlot, _ tz: TimeZone) -> String {
        let day = df("EEE MMM d", tz), clock = df("h:mm a", tz)
        return "\(i + 1). \(day.string(from: s.start)), \(clock.string(from: s.start)) – \(clock.string(from: s.end))"
    }
    static func slotList(_ slots: [ScheduleSlot], _ tz: TimeZone) -> String {
        slots.enumerated().map { slotLine($0.offset, $0.element, tz) }.joined(separator: "\n")
    }
    static func slotShort(_ s: ScheduleSlot, _ tz: TimeZone) -> String {
        df("EEE d, h:mm a", tz).string(from: s.start)
    }
}
