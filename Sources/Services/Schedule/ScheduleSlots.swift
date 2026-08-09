import Foundation

/// Pure slot computation — faithful port of Commit's calendar/slots.go. No network: it turns a set
/// of busy intervals + preferences into proposable meeting slots, preferring times adjacent to
/// existing meetings (so they keep large free blocks intact) and spreading picks across days.
/// Unit-verifiable with synthetic fixtures (see /api/schedule/slots-selftest).
enum ScheduleSlots {

    /// A half-open busy interval [start, end).
    struct Interval: Equatable { var start: Date; var end: Date }

    /// User scheduling preferences. Weekdays use Go's convention (Sun=0 … Sat=6); an empty
    /// `workdays` means "no restriction".
    struct Prefs {
        var dayStartMin: Int = 9 * 60        // meeting hours: minutes from midnight, local
        var dayEndMin: Int = 18 * 60
        var workdays: Set<Int> = [1, 2, 3, 4, 5]   // Mon–Fri
        var buffer: TimeInterval = 0          // travel buffer around busy blocks (in-person)
        var timezone: TimeZone = .current
        var ignoreTitles: [String] = ["block", "hold", "focus", "ooo", "lunch"]

        static let `default` = Prefs()
    }

    // MARK: - Busy extraction

    /// Alfred's CalendarEvent lacks Google's transparency/status/eventType, so we approximate:
    /// all-day events and ignore-listed titles are free; everything else with a real span is busy.
    static func busyIntervals(from events: [CalendarEvent], ignoreTitles: [String]) -> [Interval] {
        var out: [Interval] = []
        for e in events {
            if e.isAllDay { continue }
            if titleIgnored(e.title, ignoreTitles) { continue }
            guard e.endTime > e.startTime else { continue }
            out.append(Interval(start: e.startTime, end: e.endTime))
        }
        return mergeIntervals(out)
    }

    private static func titleIgnored(_ summary: String, _ ignoreTitles: [String]) -> Bool {
        let s = summary.lowercased()
        for ig0 in ignoreTitles {
            let ig = ig0.lowercased().trimmingCharacters(in: .whitespaces)
            if !ig.isEmpty && s.contains(ig) { return true }
        }
        return false
    }

    /// Sort + merge overlapping/adjacent intervals.
    static func mergeIntervals(_ input: [Interval]) -> [Interval] {
        if input.isEmpty { return [] }
        let sorted = input.sorted { $0.start < $1.start }
        var out = [sorted[0]]
        for iv in sorted.dropFirst() {
            if !(iv.start > out[out.count - 1].end) {
                if iv.end > out[out.count - 1].end { out[out.count - 1].end = iv.end }
            } else {
                out.append(iv)
            }
        }
        return out
    }

    /// Whether [start, start+dur) overlaps no busy interval.
    static func isFree(_ busy: [Interval], _ start: Date, _ dur: TimeInterval) -> Bool {
        let end = start.addingTimeInterval(dur)
        for b in busy where start < b.end && b.start < end { return false }
        return true
    }

    // MARK: - Slot computation

    /// Propose up to `want` slots between `from` and `to`, honoring meeting hours, workdays, travel
    /// buffer, and slot aesthetics (adjacency beats fragmenting a free block; spread across ≥2 days).
    static func computeSlots(busy busy0: [Interval], from: Date, to: Date, dur: TimeInterval,
                             prefs: Prefs, want want0: Int = 3) -> [ScheduleSlot] {
        let want = want0 <= 0 ? 3 : want0
        var busy = busy0
        if prefs.buffer > 0 {
            busy = mergeIntervals(busy.map { Interval(start: $0.start.addingTimeInterval(-prefs.buffer),
                                                      end: $0.end.addingTimeInterval(prefs.buffer)) })
        }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = prefs.timezone

        struct Candidate { var slot: ScheduleSlot; var score: Double; var dayKey: Int }
        var cands: [Candidate] = []

        var day = cal.startOfDay(for: from)
        while day < to {
            defer { day = cal.date(byAdding: .day, value: 1, to: day) ?? to.addingTimeInterval(1) }
            let goWeekday = cal.component(.weekday, from: day) - 1
            if !prefs.workdays.isEmpty && !prefs.workdays.contains(goWeekday) { continue }

            var dayStart = day.addingTimeInterval(Double(prefs.dayStartMin) * 60)
            var dayEnd = day.addingTimeInterval(Double(prefs.dayEndMin) * 60)
            if dayStart < from { dayStart = from }
            if dayEnd > to { dayEnd = to }
            guard dayEnd > dayStart else { continue }

            for blk in freeBlocks(busy, dayStart, dayEnd) {
                let blockLen = blk.end.timeIntervalSince(blk.start)
                if blockLen < dur { continue }
                let startAdj = blockBoundedByBusy(busy, blk.start, isStart: true)
                let endAdj = blockBoundedByBusy(busy, blk.end, isStart: false)

                func addCand(_ s0: Date, _ adjacent: Bool) {
                    let s = roundUpQuarter(s0)
                    if s.addingTimeInterval(dur) > blk.end || s < blk.start { return }
                    var score = 0.0
                    if adjacent { score += 10 }             // adjacency beats splitting a free block
                    score -= s.timeIntervalSince(from) / 3600.0 * 0.1   // earlier is mildly better
                    let dayKey = Int(cal.startOfDay(for: s).timeIntervalSince1970)
                    cands.append(Candidate(slot: ScheduleSlot(start: s, end: s.addingTimeInterval(dur),
                                                              origin: "computed", adjacent: adjacent),
                                           score: score, dayKey: dayKey))
                }
                addCand(blk.start, startAdj)
                if blockLen >= 2 * dur { addCand(blk.end.addingTimeInterval(-dur), endAdj) }
            }
        }

        // Stable sort by score desc.
        cands = cands.enumerated().sorted {
            $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset
        }.map { $0.element }

        var picked: [ScheduleSlot] = []
        var perDay: [Int: Int] = [:]
        func overlaps(_ s: ScheduleSlot) -> Bool {
            for p in picked where s.start < p.end && p.start < s.end { return true }
            return false
        }
        // First pass: ≤1 per day to force spread.
        for c in cands {
            if picked.count >= want { break }
            if (perDay[c.dayKey] ?? 0) >= 1 || overlaps(c.slot) { continue }
            picked.append(c.slot); perDay[c.dayKey, default: 0] += 1
        }
        // Second pass: fill from best regardless of day.
        for c in cands {
            if picked.count >= want { break }
            if overlaps(c.slot) { continue }
            picked.append(c.slot); perDay[c.dayKey, default: 0] += 1
        }
        return picked.sorted { $0.start < $1.start }
    }

    // MARK: - Helpers

    private static func freeBlocks(_ busy: [Interval], _ start: Date, _ end: Date) -> [Interval] {
        var out: [Interval] = []
        var cur = start
        for b in busy {
            if !(b.end > cur) || !(b.start < end) { continue }
            if b.start > cur { out.append(Interval(start: cur, end: min(b.start, end))) }
            if b.end > cur { cur = b.end }
            if !(cur < end) { return out }
        }
        if cur < end { out.append(Interval(start: cur, end: end)) }
        return out
    }

    private static func blockBoundedByBusy(_ busy: [Interval], _ t: Date, isStart: Bool) -> Bool {
        for b in busy {
            if isStart && b.end == t { return true }
            if !isStart && b.start == t { return true }
        }
        return false
    }

    private static func roundUpQuarter(_ t: Date) -> Date {
        let q: TimeInterval = 15 * 60
        let floored = (t.timeIntervalSince1970 / q).rounded(.down) * q
        return floored < t.timeIntervalSince1970 ? Date(timeIntervalSince1970: floored + q)
                                                 : Date(timeIntervalSince1970: floored)
    }
}
