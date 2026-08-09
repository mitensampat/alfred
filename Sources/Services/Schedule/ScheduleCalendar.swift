import Foundation

/// The calendar side of @schedule, over Alfred's existing `GoogleCalendarService`: free-slot
/// computation (with the adjacency heuristic), free re-verification right before booking, booking
/// with an optional Google Meet link, and cancel. Mirrors Commit's schedule.CalendarService.
final class ScheduleCalendar {
    private let cal: GoogleCalendarService
    var prefs: ScheduleSlots.Prefs
    var travelBufferMin: Int

    init(cal: GoogleCalendarService, prefs: ScheduleSlots.Prefs = .default, travelBufferMin: Int = 30) {
        self.cal = cal
        self.prefs = prefs
        self.travelBufferMin = travelBufferMin
    }

    var connected: Bool { cal.isConnected }

    /// All events across [from, to), deduped by id (fetchEvents is per-day).
    private func fetchRange(_ from: Date, _ to: Date) async throws -> [CalendarEvent] {
        var c = Calendar(identifier: .gregorian); c.timeZone = prefs.timezone
        var day = c.startOfDay(for: from)
        var seen = Set<String>(); var out: [CalendarEvent] = []
        while day < to {
            let evs = try await cal.fetchEvents(for: day)
            for e in evs where !seen.contains(e.id) { seen.insert(e.id); out.append(e) }
            guard let next = c.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return out
    }

    /// Propose meeting slots. `requestedDays` (Go weekdays, Sun=0…Sat=6) narrows the search within
    /// the user's own workdays; an empty result means the preference can't be met (caller falls back).
    func computeSlots(from: Date, to: Date, durationMin: Int, inPerson: Bool,
                      requestedDays: [Int] = []) async throws -> [ScheduleSlot] {
        let events = try await fetchRange(from, to)
        var p = prefs
        if inPerson { p.buffer = TimeInterval(travelBufferMin * 60) }
        if !requestedDays.isEmpty {
            let base = p.workdays
            let narrowed = Set(requestedDays.filter { base.isEmpty || base.contains($0) })
            if narrowed.isEmpty { return [] }   // preference impossible
            p.workdays = narrowed
        }
        let busy = ScheduleSlots.busyIntervals(from: events, ignoreTitles: p.ignoreTitles)
        return ScheduleSlots.computeSlots(busy: busy, from: from, to: to,
                                          dur: TimeInterval(durationMin * 60), prefs: p, want: 3)
    }

    /// Re-check one window right before proposing/booking it.
    func verifyFree(start: Date, end: Date) async throws -> Bool {
        let events = try await fetchRange(start.addingTimeInterval(-1), end.addingTimeInterval(1))
        let busy = ScheduleSlots.busyIntervals(from: events, ignoreTitles: prefs.ignoreTitles)
        return ScheduleSlots.isFree(busy, start, end.timeIntervalSince(start))
    }

    /// Book the event (with a Meet link for video meetings). Returns the id + links.
    func book(summary: String, description: String, start: Date, end: Date,
              withMeet: Bool) async throws -> (eventID: String, htmlLink: String, meetLink: String?) {
        let ev = try await cal.createEvent(title: summary, startTime: start, endTime: end,
                                           location: nil, description: description,
                                           attendees: nil, withMeet: withMeet)
        return (ev.id, ev.htmlLink, ev.meetLink)
    }

    /// Delete a previously booked event (@schedule move/cancel).
    func cancel(eventID: String) async throws {
        try await cal.deleteEvent(eventId: eventID)
    }
}
