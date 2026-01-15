import Foundation

class GoogleCalendarService {
    private let config: CalendarConfig.GoogleCalendarConfig
    private let accountName: String
    private let calendarId: String
    private var accessToken: String?
    private var refreshToken: String?
    private var tokenStorePath: String

    init(config: CalendarConfig.GoogleCalendarConfig, accountName: String = "primary") {
        self.config = config
        self.accountName = accountName
        self.calendarId = config.calendarId ?? "primary"

        // Try to find token file in multiple locations
        let tokenFilename = "google_tokens_\(accountName).json"
        let possiblePaths = [
            (NSString(string: "~/.config/alfred/\(tokenFilename)").expandingTildeInPath),
            (NSString(string: "~/.config/exec-assistant/\(tokenFilename)").expandingTildeInPath),
            (NSString(string: "~/Documents/Claude apps/Alfred/Config/\(tokenFilename)").expandingTildeInPath),
            "Config/\(tokenFilename)"
        ]

        // Find the first existing token file or use the standard location
        self.tokenStorePath = possiblePaths.first { FileManager.default.fileExists(atPath: $0) }
            ?? (NSString(string: "~/.config/alfred/\(tokenFilename)").expandingTildeInPath)

        loadTokens()
    }

    private func loadTokens() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: tokenStorePath)),
              let tokens = try? JSONDecoder().decode(StoredTokens.self, from: data) else {
            return
        }
        self.accessToken = tokens.accessToken
        self.refreshToken = tokens.refreshToken
    }

    private func saveTokens() {
        guard let accessToken = accessToken, let refreshToken = refreshToken else {
            return
        }

        // Ensure directory exists
        let directory = (tokenStorePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: nil)

        let tokens = StoredTokens(accessToken: accessToken, refreshToken: refreshToken)
        if let data = try? JSONEncoder().encode(tokens) {
            try? data.write(to: URL(fileURLWithPath: tokenStorePath))
        }
    }

    // MARK: - Authentication

    func getAuthorizationURL() -> URL {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientId),
            URLQueryItem(name: "redirect_uri", value: config.redirectUri),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/calendar.readonly"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]
        return components.url!
    }

    func exchangeCodeForToken(code: String) async throws {
        let url = URL(string: "https://oauth2.googleapis.com/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "code": code,
            "client_id": config.clientId,
            "client_secret": config.clientSecret,
            "redirect_uri": config.redirectUri,
            "grant_type": "authorization_code"
        ]

        request.httpBody = body.map { "\($0.key)=\($0.value)" }.joined(separator: "&").data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(TokenResponse.self, from: data)

        self.accessToken = response.accessToken
        self.refreshToken = response.refreshToken
        saveTokens()
    }

    func refreshAccessToken() async throws {
        guard let refreshToken = refreshToken else {
            throw CalendarError.notAuthenticated
        }

        let url = URL(string: "https://oauth2.googleapis.com/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "client_id": config.clientId,
            "client_secret": config.clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ]

        request.httpBody = body.map { "\($0.key)=\($0.value)" }.joined(separator: "&").data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(TokenResponse.self, from: data)

        self.accessToken = response.accessToken
        saveTokens()
    }

    // MARK: - Calendar Operations

    func fetchEvents(for date: Date) async throws -> [CalendarEvent] {
        guard let accessToken = accessToken else {
            throw CalendarError.notAuthenticated
        }

        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

        let dateFormatter = ISO8601DateFormatter()
        let timeMin = dateFormatter.string(from: startOfDay)
        let timeMax = dateFormatter.string(from: endOfDay)

        // URL encode the calendar ID
        let encodedCalendarId = calendarId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarId
        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/\(encodedCalendarId)/events")!
        components.queryItems = [
            URLQueryItem(name: "timeMin", value: timeMin),
            URLQueryItem(name: "timeMax", value: timeMax),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime")
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 {
            try await refreshAccessToken()
            return try await fetchEvents(for: date)
        }

        let calendarResponse = try JSONDecoder().decode(CalendarEventsResponse.self, from: data)
        return calendarResponse.items.map { $0.toCalendarEvent() }
    }

    func fetchDailySchedule(for date: Date, userSettings: UserSettings) async throws -> DailySchedule {
        let events = try await fetchEvents(for: date)

        // Mark attendees as internal/external
        let eventsWithInternalFlags = events.map { event in
            var updatedEvent = event
            updatedEvent.attendees = event.attendees.map { attendee in
                var updatedAttendee = attendee
                updatedAttendee.isInternal = userSettings.isInternal(email: attendee.email)
                return updatedAttendee
            }
            return updatedEvent
        }

        let totalMeetingTime = eventsWithInternalFlags.reduce(0) { $0 + $1.duration }
        let externalMeetings = eventsWithInternalFlags.filter { $0.hasExternalAttendees }
        let freeSlots = calculateFreeSlots(events: eventsWithInternalFlags, date: date)

        return DailySchedule(
            date: date,
            events: eventsWithInternalFlags,
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

// MARK: - Supporting Types

private struct TokenResponse: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

private struct CalendarEventsResponse: Codable {
    let items: [GoogleCalendarEvent]
}

private struct GoogleCalendarEvent: Codable {
    let id: String
    let summary: String?
    let start: EventDateTime
    let end: EventDateTime
    let location: String?
    let description: String?
    let attendees: [GoogleAttendee]?
    let organizer: GoogleAttendee?
    let hangoutLink: String?

    struct EventDateTime: Codable {
        let dateTime: String?
        let date: String?
    }

    struct GoogleAttendee: Codable {
        let email: String
        let displayName: String?
        let organizer: Bool?
        let responseStatus: String?
    }

    func toCalendarEvent() -> CalendarEvent {
        let dateFormatter = ISO8601DateFormatter()
        let startDate = start.dateTime.flatMap { dateFormatter.date(from: $0) } ?? Date()
        let endDate = end.dateTime.flatMap { dateFormatter.date(from: $0) } ?? Date()

        let mappedAttendees = (attendees ?? []).map { googleAttendee in
            Attendee(
                id: googleAttendee.email,
                name: googleAttendee.displayName,
                email: googleAttendee.email,
                isOrganizer: googleAttendee.organizer ?? false,
                responseStatus: mapResponseStatus(googleAttendee.responseStatus ?? "needsAction"),
                isInternal: false // Will be set by the service
            )
        }

        let mappedOrganizer = organizer.map { googleOrganizer in
            Attendee(
                id: googleOrganizer.email,
                name: googleOrganizer.displayName,
                email: googleOrganizer.email,
                isOrganizer: true,
                responseStatus: .accepted,
                isInternal: false
            )
        }

        return CalendarEvent(
            id: id,
            title: summary ?? "Untitled Event",
            startTime: startDate,
            endTime: endDate,
            location: location,
            attendees: mappedAttendees,
            organizer: mappedOrganizer,
            description: description,
            meetingLink: hangoutLink,
            isAllDay: start.dateTime == nil
        )
    }

    private func mapResponseStatus(_ status: String) -> Attendee.ResponseStatus {
        switch status {
        case "accepted": return .accepted
        case "declined": return .declined
        case "tentative": return .tentative
        default: return .needsAction
        }
    }
}

struct StoredTokens: Codable {
    let accessToken: String
    let refreshToken: String
}

enum CalendarError: Error, LocalizedError {
    case notAuthenticated
    case fetchFailed
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Not authenticated with Google Calendar"
        case .fetchFailed:
            return "Failed to fetch calendar events"
        case .invalidResponse:
            return "Invalid response from Google Calendar API"
        }
    }
}
