import Foundation

class GmailReader {
    private let config: MessagingConfig.EmailPlatformConfig
    private var accessToken: String?
    private var refreshToken: String?
    private let tokenStorePath: String

    init(config: MessagingConfig.EmailPlatformConfig) {
        self.config = config

        let tokenFilename = "gmail_tokens.json"
        let possiblePaths = [
            (NSString(string: "~/.config/alfred/\(tokenFilename)").expandingTildeInPath),
            "Config/\(tokenFilename)"
        ]

        self.tokenStorePath = possiblePaths.first { FileManager.default.fileExists(atPath: $0) }
            ?? (NSString(string: "~/.config/alfred/\(tokenFilename)").expandingTildeInPath)

        loadTokens()
    }

    private func loadTokens() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: tokenStorePath)),
              let tokens = try? JSONDecoder().decode(GmailStoredTokens.self, from: data) else {
            return
        }
        self.accessToken = tokens.accessToken
        self.refreshToken = tokens.refreshToken
    }

    private func saveTokens() {
        guard let accessToken = accessToken, let refreshToken = refreshToken else {
            return
        }

        let directory = (tokenStorePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: nil)

        let tokens = GmailStoredTokens(accessToken: accessToken, refreshToken: refreshToken)
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
            URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/gmail.readonly"),
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
        let response = try JSONDecoder().decode(GmailTokenResponse.self, from: data)

        self.accessToken = response.accessToken
        self.refreshToken = response.refreshToken
        saveTokens()
    }

    private func refreshAccessToken() async throws {
        guard let refreshToken = refreshToken else {
            throw GmailError.notAuthenticated
        }

        let url = URL(string: "https://oauth2.googleapis.com/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "refresh_token": refreshToken,
            "client_id": config.clientId,
            "client_secret": config.clientSecret,
            "grant_type": "refresh_token"
        ]

        request.httpBody = body.map { "\($0.key)=\($0.value)" }.joined(separator: "&").data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(GmailTokenResponse.self, from: data)

        self.accessToken = response.accessToken
        saveTokens()
    }

    // MARK: - Fetch Emails

    func fetchEmails(since: Date, maxResults: Int? = nil) async throws -> [Message] {
        guard accessToken != nil else {
            throw GmailError.notAuthenticated
        }

        // Build query to get emails since the specified date
        let timestamp = Int(since.timeIntervalSince1970)
        // Changed to search beyond just inbox - include primary, social, promotions
        let query = "after:\(timestamp)"
        let limit = maxResults ?? config.effectiveMaxEmails

        // Get list of message IDs
        let messageIds = try await listMessages(query: query, maxResults: limit)

        // Fetch full message details in parallel
        var messages: [Message] = []
        for messageId in messageIds {
            if let message = try? await fetchMessage(messageId: messageId) {
                messages.append(message)
            }
        }

        return messages.sorted { $0.timestamp > $1.timestamp }
    }

    private func listMessages(query: String, maxResults: Int) async throws -> [String] {
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "maxResults", value: "\(maxResults)")
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken!)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 {
            try await refreshAccessToken()
            return try await listMessages(query: query, maxResults: maxResults)
        }

        let listResponse = try JSONDecoder().decode(GmailMessageListResponse.self, from: data)
        return listResponse.messages?.map { $0.id } ?? []
    }

    private func fetchMessage(messageId: String) async throws -> Message {
        let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(messageId)?format=full")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken!)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 {
            try await refreshAccessToken()
            return try await fetchMessage(messageId: messageId)
        }

        let gmailMessage = try JSONDecoder().decode(GmailMessage.self, from: data)
        return parseGmailMessage(gmailMessage)
    }

    private func parseGmailMessage(_ gmailMessage: GmailMessage) -> Message {
        let headers = gmailMessage.payload.headers

        let from = headers.first { $0.name.lowercased() == "from" }?.value ?? "unknown"
        let to = headers.first { $0.name.lowercased() == "to" }?.value ?? "unknown"
        let subject = headers.first { $0.name.lowercased() == "subject" }?.value ?? "(No Subject)"
        let date = headers.first { $0.name.lowercased() == "date" }?.value

        // Extract email address from "Name <email@example.com>" format
        let fromEmail = extractEmail(from: from)
        let toEmail = extractEmail(from: to)

        // Get email body
        let body = extractBody(from: gmailMessage.payload)
        let content = "\(subject)\n\n\(body)"

        // Parse date
        let timestamp = parseEmailDate(date) ?? Date(timeIntervalSince1970: TimeInterval(gmailMessage.internalDate)! / 1000)

        // Determine direction based on label IDs
        let isSent = gmailMessage.labelIds?.contains("SENT") ?? false
        let isUnread = gmailMessage.labelIds?.contains("UNREAD") ?? false

        return Message(
            id: "gmail_\(gmailMessage.id)",
            platform: .email,
            sender: fromEmail,
            senderName: extractName(from: from),
            recipient: toEmail,
            content: content,
            timestamp: timestamp,
            direction: isSent ? .outgoing : .incoming,
            chatId: fromEmail,
            isRead: !isUnread,
            hasAttachment: gmailMessage.payload.parts?.contains { $0.filename != nil && !$0.filename!.isEmpty } ?? false
        )
    }

    private func extractEmail(from: String) -> String {
        if let range = from.range(of: "<(.+)>", options: .regularExpression) {
            let email = from[range].trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            return email
        }
        return from.trimmingCharacters(in: .whitespaces)
    }

    private func extractName(from: String) -> String? {
        if let range = from.range(of: "(.+)<", options: .regularExpression) {
            let name = String(from[range]).replacingOccurrences(of: "<", with: "").trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
        return nil
    }

    private func extractBody(from payload: GmailPayload) -> String {
        // Try to get plain text body
        if let body = payload.body.data, !body.isEmpty {
            return decodeBase64UrlSafe(body)
        }

        // Check parts for text/plain
        if let parts = payload.parts {
            for part in parts {
                if part.mimeType == "text/plain", let body = part.body.data {
                    return decodeBase64UrlSafe(body)
                }
            }

            // Fallback to text/html
            for part in parts {
                if part.mimeType == "text/html", let body = part.body.data {
                    return stripHTML(decodeBase64UrlSafe(body))
                }
            }
        }

        return ""
    }

    private func decodeBase64UrlSafe(_ string: String) -> String {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        while base64.count % 4 != 0 {
            base64.append("=")
        }

        guard let data = Data(base64Encoded: base64),
              let decoded = String(data: data, encoding: .utf8) else {
            return ""
        }
        return decoded
    }

    private func stripHTML(_ html: String) -> String {
        return html
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseEmailDate(_ dateString: String?) -> Date? {
        guard let dateString = dateString else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.date(from: dateString)
    }

    func fetchThreads(since: Date) async throws -> [MessageThread] {
        let emails = try await fetchEmails(since: since)
        return groupEmailsIntoThreads(emails)
    }

    private func groupEmailsIntoThreads(_ emails: [Message]) -> [MessageThread] {
        let grouped = Dictionary(grouping: emails, by: { $0.chatId })

        return grouped.map { senderEmail, messages in
            let sortedMessages = messages.sorted { $0.timestamp > $1.timestamp }
            let unreadCount = messages.filter { !$0.isRead && $0.direction == .incoming }.count

            return MessageThread(
                contactIdentifier: senderEmail,
                contactName: messages.first?.senderName,
                platform: .email,
                messages: sortedMessages,
                unreadCount: unreadCount,
                lastMessageDate: sortedMessages.first!.timestamp
            )
        }.sorted { $0.lastMessageDate > $1.lastMessageDate }
    }
}

// MARK: - Supporting Types

private struct GmailStoredTokens: Codable {
    let accessToken: String
    let refreshToken: String
}

private struct GmailTokenResponse: Codable {
    let accessToken: String
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}

private struct GmailMessageListResponse: Codable {
    let messages: [GmailMessageId]?
    let nextPageToken: String?
    let resultSizeEstimate: Int?
}

private struct GmailMessageId: Codable {
    let id: String
    let threadId: String
}

private struct GmailMessage: Codable {
    let id: String
    let threadId: String
    let labelIds: [String]?
    let snippet: String?
    let internalDate: String
    let payload: GmailPayload
}

private struct GmailPayload: Codable {
    let mimeType: String?
    let headers: [GmailHeader]
    let body: GmailBody
    let parts: [GmailPart]?
}

private struct GmailHeader: Codable {
    let name: String
    let value: String
}

private struct GmailBody: Codable {
    let data: String?
    let size: Int?
}

private struct GmailPart: Codable {
    let mimeType: String?
    let filename: String?
    let body: GmailBody
    let parts: [GmailPart]?
}

enum GmailError: Error, LocalizedError {
    case notAuthenticated
    case fetchFailed

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Gmail not authenticated. Run: alfred auth-gmail"
        case .fetchFailed:
            return "Failed to fetch Gmail messages"
        }
    }
}
