import Foundation

class GoogleCalendarService {
    private let config: CalendarConfig.GoogleCalendarConfig
    private let accountName: String
    private let calendarId: String
    private var accessToken: String?
    private var refreshToken: String?
    private var tokenStorePath: String

    /// Whether we have a usable access token (used by the @schedule calendar service).
    var isConnected: Bool { accessToken != nil }

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
            URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/calendar"),
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

    // MARK: - Event Creation

    func createEvent(
        title: String,
        startTime: Date,
        endTime: Date,
        location: String?,
        description: String?,
        attendees: [String]? = nil,  // email addresses to invite
        withMeet: Bool = false       // attach a Google Meet conference
    ) async throws -> CreatedEvent {
        guard let accessToken = accessToken else {
            throw CalendarError.notAuthenticated
        }

        let encodedCalendarId = calendarId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarId
        var urlComponents = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/\(encodedCalendarId)/events")!
        if withMeet { urlComponents.queryItems = [URLQueryItem(name: "conferenceDataVersion", value: "1")] }
        let url = urlComponents.url!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]

        var eventBody: [String: Any] = [
            "summary": title,
            "start": ["dateTime": isoFormatter.string(from: startTime), "timeZone": TimeZone.current.identifier],
            "end": ["dateTime": isoFormatter.string(from: endTime), "timeZone": TimeZone.current.identifier]
        ]
        if let location = location { eventBody["location"] = location }
        if let description = description { eventBody["description"] = description }
        if let attendees = attendees, !attendees.isEmpty {
            eventBody["attendees"] = attendees.map { ["email": $0] }
        }
        if withMeet {
            eventBody["conferenceData"] = ["createRequest": [
                "requestId": UUID().uuidString,
                "conferenceSolutionKey": ["type": "hangoutsMeet"]
            ]]
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: eventBody)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 {
            try await refreshAccessToken()
            return try await createEvent(title: title, startTime: startTime, endTime: endTime, location: location, description: description, attendees: attendees, withMeet: withMeet)
        }

        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
            print("⚠️ Calendar create failed: \(errorBody)")
            throw CalendarError.createFailed
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let eventId = json["id"] as? String,
              let htmlLink = json["htmlLink"] as? String else {
            throw CalendarError.invalidResponse
        }

        print("✅ Created calendar event: \(title) (\(eventId))")

        // Meet link: conferenceData.entryPoints[type=video].uri, else hangoutLink.
        var meetLink = json["hangoutLink"] as? String
        if meetLink == nil, let conf = json["conferenceData"] as? [String: Any],
           let entries = conf["entryPoints"] as? [[String: Any]] {
            meetLink = entries.first { ($0["entryPointType"] as? String) == "video" }?["uri"] as? String
        }

        return CreatedEvent(
            id: eventId,
            title: title,
            startTime: startTime,
            endTime: endTime,
            location: location,
            description: description,
            htmlLink: htmlLink,
            shareableLink: Self.makeShareableLink(title: title, startTime: startTime, endTime: endTime, location: location, description: description),
            meetLink: meetLink
        )
    }

    /// Update an existing calendar event (partial update — only non-nil fields are changed)
    func updateEvent(
        eventId: String,
        title: String? = nil,
        startTime: Date? = nil,
        endTime: Date? = nil,
        location: String? = nil,
        description: String? = nil
    ) async throws -> CreatedEvent {
        guard let accessToken = accessToken else {
            throw CalendarError.notAuthenticated
        }

        let encodedCalendarId = calendarId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarId
        let encodedEventId = eventId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? eventId
        let url = URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(encodedCalendarId)/events/\(encodedEventId)")!

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]

        var eventBody: [String: Any] = [:]
        if let title = title { eventBody["summary"] = title }
        if let startTime = startTime {
            eventBody["start"] = ["dateTime": isoFormatter.string(from: startTime), "timeZone": TimeZone.current.identifier]
        }
        if let endTime = endTime {
            eventBody["end"] = ["dateTime": isoFormatter.string(from: endTime), "timeZone": TimeZone.current.identifier]
        }
        if let location = location { eventBody["location"] = location }
        if let description = description { eventBody["description"] = description }

        request.httpBody = try JSONSerialization.data(withJSONObject: eventBody)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 {
            try await refreshAccessToken()
            return try await updateEvent(eventId: eventId, title: title, startTime: startTime, endTime: endTime, location: location, description: description)
        }

        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
            print("⚠️ Calendar update failed: \(errorBody)")
            throw CalendarError.updateFailed
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let returnedId = json["id"] as? String,
              let htmlLink = json["htmlLink"] as? String else {
            throw CalendarError.invalidResponse
        }

        let returnedTitle = json["summary"] as? String ?? title ?? "Updated Event"
        print("✅ Updated calendar event: \(returnedTitle) (\(returnedId))")

        // Parse returned start/end times
        let returnedStart: Date
        let returnedEnd: Date
        if let startObj = json["start"] as? [String: Any], let dtStr = startObj["dateTime"] as? String {
            returnedStart = isoFormatter.date(from: dtStr) ?? startTime ?? Date()
        } else {
            returnedStart = startTime ?? Date()
        }
        if let endObj = json["end"] as? [String: Any], let dtStr = endObj["dateTime"] as? String {
            returnedEnd = isoFormatter.date(from: dtStr) ?? endTime ?? Date()
        } else {
            returnedEnd = endTime ?? Date()
        }

        return CreatedEvent(
            id: returnedId,
            title: returnedTitle,
            startTime: returnedStart,
            endTime: returnedEnd,
            location: json["location"] as? String ?? location,
            description: json["description"] as? String ?? description,
            htmlLink: htmlLink,
            shareableLink: Self.makeShareableLink(title: returnedTitle, startTime: returnedStart, endTime: returnedEnd, location: location, description: description)
        )
    }

    /// Delete a calendar event
    func deleteEvent(eventId: String) async throws {
        guard let accessToken = accessToken else {
            throw CalendarError.notAuthenticated
        }

        let encodedCalendarId = calendarId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarId
        let encodedEventId = eventId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? eventId
        let url = URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(encodedCalendarId)/events/\(encodedEventId)")!

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 {
            try await refreshAccessToken()
            return try await deleteEvent(eventId: eventId)
        }

        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 204 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
            print("⚠️ Calendar delete failed: \(errorBody)")
            throw CalendarError.deleteFailed
        }

        print("✅ Deleted calendar event: \(eventId)")
    }

    /// Generate a Google Calendar template URL that anyone can use to add the event to their own calendar
    static func makeShareableLink(
        title: String,
        startTime: Date,
        endTime: Date,
        location: String?,
        description: String?
    ) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd'T'HHmmss"
        fmt.timeZone = TimeZone.current

        let dates = "\(fmt.string(from: startTime))/\(fmt.string(from: endTime))"

        var components = URLComponents(string: "https://calendar.google.com/calendar/render")!
        var queryItems = [
            URLQueryItem(name: "action", value: "TEMPLATE"),
            URLQueryItem(name: "text", value: title),
            URLQueryItem(name: "dates", value: dates),
            URLQueryItem(name: "ctz", value: TimeZone.current.identifier)
        ]
        if let location = location { queryItems.append(URLQueryItem(name: "location", value: location)) }
        if let description = description { queryItems.append(URLQueryItem(name: "details", value: description)) }
        components.queryItems = queryItems

        return components.url?.absoluteString ?? ""
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
    case createFailed
    case updateFailed
    case deleteFailed

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Not authenticated with Google Calendar"
        case .fetchFailed:
            return "Failed to fetch calendar events"
        case .invalidResponse:
            return "Invalid response from Google Calendar API"
        case .createFailed:
            return "Failed to create calendar event"
        case .updateFailed:
            return "Failed to update calendar event"
        case .deleteFailed:
            return "Failed to delete calendar event"
        }
    }
}
