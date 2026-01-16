import Foundation
import Combine

enum PriorityItemBadge {
    case count(Int)
    case alert
    case success
}

struct PriorityItem: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let badge: PriorityItemBadge?
    let hasDetail: Bool
    let action: PriorityItemAction
}

enum PriorityItemAction {
    case briefing
    case messages
    case calendar
    case attentionCheck
    case allCaughtUp
    case notionTodos
}

@MainActor
class MainMenuViewModel: ObservableObject {
    @Published var priorityItems: [PriorityItem] = []
    @Published var greetingText: String = ""
    @Published var currentView: ViewDestination = .main
    @Published var selectedContact: String?
    @Published var messageSummaries: [MessageSummary] = []
    @Published var unreadCount: Int = 0
    @Published var shouldExpandPopover: Bool = false

    // Calendar parameters
    @Published var selectedCalendarDate: Date = Date()
    @Published var selectedCalendarFilter: String = "all"

    // Briefing parameters
    @Published var selectedBriefingDate: Date = Date()

    // Message parameters
    @Published var selectedMessagePlatform: String = "all"
    @Published var selectedMessageTimeframe: String = "24h"
    @Published var selectedMessageContact: String = ""

    private var cancellables = Set<AnyCancellable>()
    let alfredService: AlfredService

    enum ViewDestination {
        case main
        case briefingOptions
        case briefing
        case calendarOptions
        case calendar
        case messagesOptions
        case messages
        case messageDetail
        case attentionCheck
        case notionTodos
    }

    init() {
        self.alfredService = AlfredService()
        updateGreeting()
    }

    func loadData() {
        // Generate context-aware priority items based on time of day
        priorityItems = generatePriorityItems()

        // Fetch real data in background
        Task {
            await fetchRealTimeData()
        }
    }

    private func fetchRealTimeData() async {
        guard alfredService.isInitialized else { return }

        do {
            // Fetch messages summary to get unread count
            let summaries = try await alfredService.fetchMessagesSummary(platform: "all", timeframe: "24h")
            await MainActor.run {
                self.messageSummaries = summaries
                self.unreadCount = summaries.filter { $0.thread.needsResponse }.count
                // Update priority items with real data
                self.priorityItems = generatePriorityItems()
            }
        } catch {
            print("Error fetching real-time data: \(error)")
        }
    }

    private func generatePriorityItems() -> [PriorityItem] {
        let hour = Calendar.current.component(.hour, from: Date())
        var items: [PriorityItem] = []

        // Morning (6am-12pm): Show briefing first
        if hour >= 6 && hour < 12 {
            items.append(PriorityItem(
                title: "today's briefing",
                subtitle: "7 meetings, 12 messages",
                badge: .count(1),
                hasDetail: true,
                action: .briefing
            ))

            // Add messages if there are unread
            let messageCount = max(unreadCount, 5) // Show at least 5 for demo, or real count
            items.append(PriorityItem(
                title: "\(messageCount) unread messages",
                subtitle: "tap to review",
                badge: .count(messageCount),
                hasDetail: true,
                action: .messages
            ))

            // Add notion todos scanner
            items.append(PriorityItem(
                title: "scan for todos",
                subtitle: "check whatsapp notes",
                badge: nil,
                hasDetail: true,
                action: .notionTodos
            ))

            // Add next meeting
            items.append(PriorityItem(
                title: "next meeting in 2 hours",
                subtitle: "team sync @ 10:00 AM",
                badge: nil,
                hasDetail: true,
                action: .calendar
            ))
        }
        // Afternoon (12pm-3pm): Focus on immediate tasks
        else if hour >= 12 && hour < 15 {
            // Next meeting
            items.append(PriorityItem(
                title: "next meeting in 15 min",
                subtitle: "1:1 with Alex",
                badge: .alert,
                hasDetail: true,
                action: .calendar
            ))

            // Unread messages
            items.append(PriorityItem(
                title: "5 unread messages",
                subtitle: "tap to review",
                badge: .count(5),
                hasDetail: true,
                action: .messages
            ))

            // Notion todos scanner
            items.append(PriorityItem(
                title: "scan for todos",
                subtitle: "check whatsapp notes",
                badge: nil,
                hasDetail: true,
                action: .notionTodos
            ))

            // Upcoming calendar
            items.append(PriorityItem(
                title: "3 more meetings today",
                subtitle: "view schedule",
                badge: nil,
                hasDetail: true,
                action: .calendar
            ))
        }
        // 3pm: Attention check
        else if hour >= 15 && hour < 16 {
            items.append(PriorityItem(
                title: "attention check",
                subtitle: "3 critical tasks today",
                badge: .alert,
                hasDetail: true,
                action: .attentionCheck
            ))

            items.append(PriorityItem(
                title: "5 unread messages",
                subtitle: "tap to review",
                badge: .count(5),
                hasDetail: true,
                action: .messages
            ))

            items.append(PriorityItem(
                title: "2 meetings left today",
                subtitle: "view schedule",
                badge: nil,
                hasDetail: true,
                action: .calendar
            ))
        }
        // Evening (5pm+): Wrap up
        else if hour >= 17 {
            items.append(PriorityItem(
                title: "all caught up",
                subtitle: "great work today",
                badge: .success,
                hasDetail: false,
                action: .allCaughtUp
            ))

            items.append(PriorityItem(
                title: "scan for todos",
                subtitle: "check whatsapp notes",
                badge: nil,
                hasDetail: true,
                action: .notionTodos
            ))

            items.append(PriorityItem(
                title: "tomorrow's schedule",
                subtitle: "4 meetings, 2 hours focus time",
                badge: nil,
                hasDetail: true,
                action: .calendar
            ))

            items.append(PriorityItem(
                title: "unread messages",
                subtitle: "2 threads need response",
                badge: .count(2),
                hasDetail: true,
                action: .messages
            ))
        }
        // Night/Early Morning: Minimal info
        else {
            items.append(PriorityItem(
                title: "all caught up",
                subtitle: "rest well",
                badge: .success,
                hasDetail: false,
                action: .allCaughtUp
            ))

            items.append(PriorityItem(
                title: "tomorrow's briefing",
                subtitle: "ready when you are",
                badge: nil,
                hasDetail: true,
                action: .briefing
            ))
        }

        return items
    }

    private func updateGreeting() {
        let hour = Calendar.current.component(.hour, from: Date())

        if hour >= 6 && hour < 12 {
            greetingText = "good morning"
        } else if hour >= 12 && hour < 17 {
            greetingText = "good afternoon"
        } else if hour >= 17 && hour < 22 {
            greetingText = "good evening"
        } else {
            greetingText = "good night"
        }
    }

    func handleItemTap(_ item: PriorityItem) {
        switch item.action {
        case .briefing:
            currentView = .briefing
        case .messages:
            currentView = .messages
        case .calendar:
            currentView = .calendar
        case .attentionCheck:
            currentView = .attentionCheck
        case .notionTodos:
            currentView = .notionTodos
        case .allCaughtUp:
            // Do nothing, just a status indicator
            break
        }
    }

    func navigateBack() {
        currentView = .main
        shouldExpandPopover = false
    }

    func navigate(to destination: ViewDestination) {
        currentView = destination
        updatePopoverSize(for: destination)
    }

    private func updatePopoverSize(for destination: ViewDestination) {
        // Expand popover for content-heavy views
        switch destination {
        case .briefing, .calendar, .messages, .messageDetail, .notionTodos:
            shouldExpandPopover = true
        case .main, .briefingOptions, .calendarOptions, .messagesOptions, .attentionCheck:
            shouldExpandPopover = false
        }
    }

    func showBriefingOptions() {
        currentView = .briefingOptions
        shouldExpandPopover = false
    }

    func showCalendarOptions() {
        currentView = .calendarOptions
        shouldExpandPopover = false
    }

    func showMessagesOptions() {
        currentView = .messagesOptions
        shouldExpandPopover = false
    }

    func openMessageDetail(contact: String) {
        selectedContact = contact
        selectedMessageContact = contact
        currentView = .messageDetail
        shouldExpandPopover = true
    }

    func showMoreOptions() {
        print("Show more options menu")
    }
}
