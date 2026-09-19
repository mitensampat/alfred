import Foundation

/// The calendar side of @schedule, over Alfred's existing `GoogleCalendarService`: free-slot
/// computation (with the adjacency heuristic), free re-verification right before booking, booking
/// with an optional Google Meet link, and cancel. Mirrors Commit's schedule.CalendarService.
final class ScheduleCalendar {
    /// Every configured calendar, not just the first. Availability is the *union*: an event on any
    /// one of them means you are busy. Reading only `calendar.google.first` made every event on the
    /// work account look like free time, so Alfred proposed slots over real meetings and then booked
    /// over them — verifyFree() consulted the same single calendar, so the pre-booking check could
    /// not catch it either.
    private let cals: [(name: String, svc: GoogleCalendarService)]
    var prefs: ScheduleSlots.Prefs
    var travelBufferMin: Int

    /// Names the calendar a booking at this time should land on (e.g. "work" vs "primary").
    /// Returning nil, or a name that is not connected, falls back to the first live calendar.
    var bookingTarget: ((Date) -> String?)?

    init(cals: [(name: String, svc: GoogleCalendarService)],
         prefs: ScheduleSlots.Prefs = .default, travelBufferMin: Int = 30) {
        self.cals = cals
        self.prefs = prefs
        self.travelBufferMin = travelBufferMin
    }

    var connected: Bool { cals.contains { $0.svc.isConnected } }

    /// The calendars we can actually read right now.
    var liveCalendars: [String] { cals.filter { $0.svc.isConnected }.map { $0.name } }

    /// All events across [from, to) from every connected calendar, deduped by id (fetchEvents is
    /// per-day, and an event you are invited to can appear on more than one account).
    ///
    /// A calendar that fails to answer throws rather than being skipped. Skipping would hand the
    /// slot finder a *partial* busy set, and a missing event is indistinguishable from free time —
    /// the failure mode is booking over a real meeting. Failing loudly keeps @schedule honest: it
    /// stops working rather than quietly scheduling on top of you.
    private func fetchRange(_ from: Date, _ to: Date) async throws -> [CalendarEvent] {
        var c = Calendar(identifier: .gregorian); c.timeZone = prefs.timezone
        var days: [Date] = []
        var day = c.startOfDay(for: from)
        while day < to {
            days.append(day)
            guard let next = c.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }

        let targets = cals.filter { $0.svc.isConnected }
        guard !targets.isEmpty else {
            throw NSError(domain: "ScheduleCalendar", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No connected Google Calendar to read availability from."])
        }

        var seen = Set<String>(); var out: [CalendarEvent] = []
        try await withThrowingTaskGroup(of: [CalendarEvent].self) { group in
            for t in targets {
                for d in days {
                    group.addTask { try await t.svc.fetchEvents(for: d) }
                }
            }
            for try await evs in group {
                for e in evs where !seen.contains(e.id) { seen.insert(e.id); out.append(e) }
            }
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

    /// The busy set the slot finder is working from, annotated with which calendar each block came
    /// from. Availability bugs are invisible otherwise: a missing calendar looks exactly like a free
    /// afternoon. Used by /api/schedule/preview.
    func busyPreview(from: Date, to: Date) async throws -> [(start: Date, end: Date, calendar: String, title: String)] {
        var out: [(start: Date, end: Date, calendar: String, title: String)] = []
        var c = Calendar(identifier: .gregorian); c.timeZone = prefs.timezone
        var days: [Date] = []
        var day = c.startOfDay(for: from)
        while day < to {
            days.append(day)
            guard let next = c.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        for t in cals where t.svc.isConnected {
            var seen = Set<String>()
            for d in days {
                let evs = (try? await t.svc.fetchEvents(for: d)) ?? []
                for e in evs where !seen.contains(e.id) {
                    seen.insert(e.id)
                    if e.isAllDay || e.endTime <= e.startTime { continue }
                    out.append((e.startTime, e.endTime, t.name, e.title))
                }
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    /// Re-check one window right before proposing/booking it.
    func verifyFree(start: Date, end: Date) async throws -> Bool {
        let events = try await fetchRange(start.addingTimeInterval(-1), end.addingTimeInterval(1))
        let busy = ScheduleSlots.busyIntervals(from: events, ignoreTitles: prefs.ignoreTitles)
        return ScheduleSlots.isFree(busy, start, end.timeIntervalSince(start))
    }

    /// Which calendar a new event is written to. Availability is read from every calendar, but an
    /// event has to live on exactly one — see `bookingTarget`, which decides by context.
    private func writeTarget(for start: Date) -> (name: String, svc: GoogleCalendarService)? {
        let live = cals.filter { $0.svc.isConnected }
        guard !live.isEmpty else { return nil }
        if let want = bookingTarget?(start), let hit = live.first(where: { $0.name == want }) { return hit }
        return live.first
    }

    /// Book the event (with a Meet link for video meetings). Returns the id + links.
    func book(summary: String, description: String, start: Date, end: Date,
              withMeet: Bool) async throws -> (eventID: String, htmlLink: String, meetLink: String?) {
        guard let target = writeTarget(for: start) else {
            throw NSError(domain: "ScheduleCalendar", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "No connected Google Calendar to book into."])
        }
        let ev = try await target.svc.createEvent(title: summary, startTime: start, endTime: end,
                                                  location: nil, description: description,
                                                  attendees: nil, withMeet: withMeet)
        return (ev.id, ev.htmlLink, ev.meetLink)
    }

    /// Delete a previously booked event (@schedule move/cancel). The event id does not say which
    /// calendar holds it, so try each: a delete on the wrong one fails harmlessly.
    func cancel(eventID: String) async throws {
        var lastError: Error?
        for t in cals where t.svc.isConnected {
            do { try await t.svc.deleteEvent(eventId: eventID); return } catch { lastError = error }
        }
        if let e = lastError { throw e }
    }
}
