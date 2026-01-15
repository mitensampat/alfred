import Foundation

class MultiCalendarService {
    private let services: [String: GoogleCalendarService]
    
    init(configs: [CalendarConfig.GoogleCalendarConfig]) {
        var servicesDict: [String: GoogleCalendarService] = [:]
        for config in configs {
            servicesDict[config.name] = GoogleCalendarService(config: config, accountName: config.name)
        }
        self.services = servicesDict
    }
    
    func getAllServices() -> [String: GoogleCalendarService] {
        return services
    }
    
    func getService(named name: String) -> GoogleCalendarService? {
        return services[name]
    }
    
    func fetchEventsFromAllCalendars(for date: Date, userSettings: UserSettings) async throws -> DailySchedule {
        return try await fetchEvents(for: date, userSettings: userSettings, calendarFilter: "all")
    }

    func fetchEvents(for date: Date, userSettings: UserSettings, calendarFilter: String) async throws -> DailySchedule {
        var allEvents: [CalendarEvent] = []

        // Filter which calendars to fetch from
        let calendarsToFetch: [String: GoogleCalendarService]
        if calendarFilter == "all" {
            calendarsToFetch = services
        } else if let service = services[calendarFilter] {
            calendarsToFetch = [calendarFilter: service]
        } else {
            throw NSError(domain: "MultiCalendarService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Calendar '\(calendarFilter)' not found"])
        }

        print("📅 Fetching events from \(calendarsToFetch.count) calendar(s)...")

        // Fetch from selected calendars in parallel
        await withTaskGroup(of: (String, Result<[CalendarEvent], Error>).self) { group in
            for (name, service) in calendarsToFetch {
                group.addTask {
                    print("  ↳ Checking '\(name)' calendar...")
                    do {
                        let events = try await service.fetchEvents(for: date)
                        print("  ✓ Found \(events.count) event(s) in '\(name)' calendar")
                        return (name, .success(events))
                    } catch {
                        print("  ✗ Failed to fetch events from '\(name)': \(error)")
                        return (name, .failure(error))
                    }
                }
            }

            for await (_, result) in group {
                if case .success(let events) = result {
                    allEvents.append(contentsOf: events)
                }
            }
        }

        print("📊 Total events across \(calendarFilter) calendar(s): \(allEvents.count)")

        // Deduplicate events based on multiple criteria
        var uniqueEvents: [CalendarEvent] = []
        var processedIndices: Set<Int> = []

        for (i, event) in allEvents.enumerated() {
            if processedIndices.contains(i) {
                continue
            }

            // Check if this event overlaps with any later event
            var isDuplicate = false
            for (j, otherEvent) in allEvents.enumerated() {
                if j <= i || processedIndices.contains(j) {
                    continue
                }

                // Consider events duplicates if they have:
                // 1. Exact same title, or
                // 2. Overlapping time AND shared attendees
                let hasSameTitle = event.title == otherEvent.title
                let hasOverlappingTime = event.startTime == otherEvent.startTime && event.endTime == otherEvent.endTime
                let hasSharedAttendees = !Set(event.attendees.map { $0.email }).isDisjoint(with: Set(otherEvent.attendees.map { $0.email }))

                if hasSameTitle || (hasOverlappingTime && hasSharedAttendees) {
                    // When we find a duplicate, prefer to keep the one WITHOUT "block" in the title
                    let currentIsBlock = event.title.lowercased().contains("block")
                    let otherIsBlock = otherEvent.title.lowercased().contains("block")

                    if !currentIsBlock && otherIsBlock {
                        // Current is better (not a block), mark other as duplicate
                        processedIndices.insert(j)
                    } else if currentIsBlock && !otherIsBlock {
                        // Other is better (not a block), mark current as duplicate and use other
                        processedIndices.insert(i)
                        isDuplicate = true
                        break // Skip current event
                    } else {
                        // Both are blocks or both are not blocks, keep first occurrence
                        processedIndices.insert(j)
                    }
                    isDuplicate = true
                }
            }

            if !isDuplicate {
                uniqueEvents.append(event)
            }
        }

        print("📊 After deduplication: \(uniqueEvents.count) unique event(s)")

        // Filter events based on rules:
        // 1. Zero-duration events
        // 2. "block" type meetings
        // 3. Meetings less than 10 minutes
        // Exception: Always keep meetings with external attendees
        let filteredEvents = uniqueEvents.filter { event in
            // Always keep events with external attendees
            let hasExternalAttendees = event.attendees.contains { attendee in
                !userSettings.isInternal(email: attendee.email)
            }

            if hasExternalAttendees {
                print("  ✓ Keeping external meeting: '\(event.title)'")
                return true // Always include external meetings
            }

            // Filter zero-duration events
            if event.duration == 0 {
                print("  ⊗ Filtered out zero-duration event: '\(event.title)'")
                return false
            }

            // Filter "block" type meetings (but only if they don't have external attendees)
            if event.title.lowercased().contains("block") {
                print("  ⊗ Filtered out block event: '\(event.title)'")
                return false
            }

            // Filter meetings less than 10 minutes
            if event.duration < 600 { // 10 minutes = 600 seconds
                let durationMins = Int(event.duration / 60)
                print("  ⊗ Filtered out short event (\(durationMins)min): '\(event.title)'")
                return false
            }

            print("  ✓ Keeping internal meeting: '\(event.title)'")
            return true
        }
        print("📊 After filtering: \(filteredEvents.count) event(s)")

        // Mark attendees as internal/external
        let eventsWithInternalFlags = filteredEvents.map { event in
            var updatedEvent = event
            updatedEvent.attendees = event.attendees.map { attendee in
                var updatedAttendee = attendee
                updatedAttendee.isInternal = userSettings.isInternal(email: attendee.email)
                return updatedAttendee
            }
            return updatedEvent
        }

        // Sort by start time
        let sortedEvents = eventsWithInternalFlags.sorted { $0.startTime < $1.startTime }
        
        let totalMeetingTime = sortedEvents.reduce(0) { $0 + $1.duration }
        let externalMeetings = sortedEvents.filter { $0.hasExternalAttendees }
        let freeSlots = calculateFreeSlots(events: sortedEvents, date: date)
        
        return DailySchedule(
            date: date,
            events: sortedEvents,
            totalMeetingTime: totalMeetingTime,
            freeSlots: freeSlots,
            externalMeetings: externalMeetings
        )
    }
    
    private func calculateFreeSlots(events: [CalendarEvent], date: Date) -> [DailySchedule.TimeSlot] {
        let calendar = Calendar.current
        let workDayStart = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: date)!
        let workDayEnd = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: date)!
        
        var freeSlots: [DailySchedule.TimeSlot] = []
        var currentTime = workDayStart
        
        let sortedEvents = events.sorted { $0.startTime < $1.startTime }
        
        for event in sortedEvents {
            if event.startTime > currentTime {
                freeSlots.append(DailySchedule.TimeSlot(start: currentTime, end: event.startTime))
            }
            currentTime = max(currentTime, event.endTime)
        }
        
        if currentTime < workDayEnd {
            freeSlots.append(DailySchedule.TimeSlot(start: currentTime, end: workDayEnd))
        }
        
        return freeSlots.filter { $0.duration >= 900 } // Filter slots < 15 minutes
    }
}
