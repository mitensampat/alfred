import Foundation

struct CalendarEvent: Codable, Identifiable {
    let id: String
    let title: String
    let startTime: Date
    let endTime: Date
    let location: String?
    var attendees: [Attendee]
    let organizer: Attendee?
    let description: String?
    let meetingLink: String?
    let isAllDay: Bool

    var duration: TimeInterval {
        endTime.timeIntervalSince(startTime)
    }

    var externalAttendees: [Attendee] {
        attendees.filter { !$0.isInternal }
    }

    var hasExternalAttendees: Bool {
        !externalAttendees.isEmpty
    }
}

struct Attendee: Codable, Identifiable {
    let id: String
    let name: String?
    let email: String
    let isOrganizer: Bool
    let responseStatus: ResponseStatus
    var isInternal: Bool

    enum ResponseStatus: String, Codable {
        case accepted
        case declined
        case tentative
        case needsAction
    }
}

struct DailySchedule: Codable {
    let date: Date
    let events: [CalendarEvent]
    let totalMeetingTime: TimeInterval
    let freeSlots: [TimeSlot]
    let externalMeetings: [CalendarEvent]

    struct TimeSlot: Codable {
        let start: Date
        let end: Date
        var duration: TimeInterval {
            end.timeIntervalSince(start)
        }
    }
}

struct MeetingBriefing: Codable {
    let event: CalendarEvent
    let attendeeBriefings: [AttendeeBriefing]
    let preparation: String
    let suggestedTopics: [String]
    let context: String?
}

struct AttendeeBriefing: Codable {
    let attendee: Attendee
    let bio: String
    let recentActivity: [String]
    let lastInteraction: LastInteraction?
    let companyInfo: CompanyInfo?
    let notes: String?

    struct LastInteraction: Codable {
        let date: Date
        let platform: MessagePlatform
        let summary: String
    }

    struct CompanyInfo: Codable {
        let name: String
        let description: String?
        let recentNews: [String]
    }
}
