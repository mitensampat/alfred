import Foundation

struct DailyBriefing: Codable {
    let date: Date
    let messagingSummary: MessagingSummary
    let calendarBriefing: CalendarBriefing
    let actionItems: [ActionItem]
    let generatedAt: Date
}

struct MessagingSummary: Codable {
    let keyInteractions: [MessageSummary]
    let needsResponse: [MessageSummary]
    let criticalMessages: [MessageSummary]
    let stats: MessagingStats

    struct MessagingStats: Codable {
        let totalMessages: Int
        let unreadMessages: Int
        let threadsNeedingResponse: Int
        let byPlatform: [MessagePlatform: Int]
    }
}

struct CalendarBriefing: Codable {
    let schedule: DailySchedule
    let meetingBriefings: [MeetingBriefing]
    let focusTime: TimeInterval
    let recommendations: [String]
}

struct ActionItem: Codable, Identifiable {
    let id: String
    let title: String
    let description: String
    let source: ActionSource
    let priority: UrgencyLevel
    let dueDate: Date?
    let estimatedDuration: TimeInterval?
    let category: ActionCategory

    enum ActionSource: String, Codable {
        case message
        case meeting
        case calendar
        case system
    }

    enum ActionCategory: String, Codable {
        case respond
        case prepare
        case follow_up
        case decision
        case task
    }
}

struct AttentionDefenseReport: Codable {
    let currentTime: Date
    let upcomingDeadlines: [ActionItem]
    let criticalTasks: [ActionItem]
    let canPushOff: [PushOffSuggestion]
    let mustDoToday: [ActionItem]
    let timeAvailable: TimeInterval
    let recommendations: [String]
}

struct PushOffSuggestion: Codable {
    let item: ActionItem
    let reason: String
    let suggestedNewDate: Date
    let impact: ImpactLevel

    enum ImpactLevel: String, Codable {
        case none
        case low
        case medium
        case high
    }
}
