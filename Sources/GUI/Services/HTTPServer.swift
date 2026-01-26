import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Simple HTTP server for remote API access
class HTTPServer {
    private let port: Int
    private let passcode: String
    private let alfredService: AlfredService
    private var listener: ServerSocket?

    init(port: Int, passcode: String, alfredService: AlfredService) {
        self.port = port
        self.passcode = passcode
        self.alfredService = alfredService
    }

    func start() throws {
        let listener = try ServerSocket(port: port)
        self.listener = listener

        print("🌐 HTTP API server started on port \(port)")

        Task {
            while true {
                do {
                    let client = try await listener.accept()
                    Task {
                        await handleClient(client)
                    }
                } catch {
                    print("❌ Error accepting connection: \(error)")
                }
            }
        }
    }

    func stop() {
        listener?.close()
        listener = nil
        print("🛑 HTTP API server stopped")
    }

    private func handleClient(_ client: ClientSocket) async {
        defer { client.close() }

        do {
            // Read request
            guard let request = try await client.readRequest() else {
                return
            }

            // Allow web UI without authentication
            if request.path == "/" || request.path == "/index.html" {
                let response = handleNotionUI()
                try await client.send(response)
                return
            }

            // Allow v2 web UI without authentication (legacy)
            if request.path == "/index-v2.html" {
                let response = handleWebUIv2()
                try await client.send(response)
                return
            }

            // Allow notion UI without authentication
            if request.path == "/index-notion.html" {
                let response = handleNotionUI()
                try await client.send(response)
                return
            }

            // Authenticate API requests
            guard authenticate(request) else {
                try await client.send(HTTPResponse(
                    statusCode: 401,
                    body: ["error": "Unauthorized - Invalid or missing passcode"]
                ))
                return
            }

            // Route request
            let response = await route(request)
            try await client.send(response)

        } catch {
            print("❌ Error handling request: \(error)")
        }
    }

    private func authenticate(_ request: HTTPRequest) -> Bool {
        // Check X-API-Key header
        if let apiKey = request.headers["x-api-key"], apiKey == passcode {
            return true
        }

        // Check query parameter
        if let queryPasscode = request.queryParams["passcode"], queryPasscode == passcode {
            return true
        }

        return false
    }

    private func route(_ request: HTTPRequest) async -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/api/health"):
            return handleHealth()

        case ("GET", "/api/commitments"):
            return await handleGetCommitments(request)

        case ("GET", "/api/commitments/overdue"):
            return await handleGetOverdueCommitments()

        case ("POST", "/api/commitments/scan"):
            return await handleScanCommitments(request)

        case ("GET", "/api/briefing"):
            return await handleGetDailyBriefing(request)

        case ("GET", "/api/calendar"):
            return await handleGetCalendar(request)

        case ("GET", "/api/messages"):
            return await handleGetMessages(request)

        case ("GET", "/api/attention-check"):
            return await handleGetAttentionCheck()

        case ("POST", "/api/todos/scan"):
            return await handleScanTodos()

        case ("GET", "/api/drafts"):
            return await handleGetDrafts()

        case ("POST", "/api/query"):
            return await handleNaturalLanguageQuery(request)

        default:
            return HTTPResponse(
                statusCode: 404,
                body: ["error": "Endpoint not found"]
            )
        }
    }

    // MARK: - API Handlers

    private func handleWebUIv2() -> HTTPResponse {
        // Try to load from Resources directory
        let resourcePath = Bundle.main.resourcePath ?? ""
        let htmlPath = (resourcePath as NSString).appendingPathComponent("index-v2.html")

        // Fallback to project directory
        let projectPath = (NSString(string: "~/Documents/Claude apps/Alfred/Sources/GUI/Resources/index-v2.html").expandingTildeInPath)

        let paths = [htmlPath, projectPath]

        for path in paths {
            if let html = try? String(contentsOfFile: path, encoding: .utf8) {
                return HTTPResponse(
                    statusCode: 200,
                    headers: ["Content-Type": "text/html; charset=utf-8"],
                    htmlBody: html
                )
            }
        }

        // Fallback to v1
        return handleWebUI()
    }

    private func handleNotionUI() -> HTTPResponse {
        // Try to load from Resources directory
        let resourcePath = Bundle.main.resourcePath ?? ""
        let htmlPath = (resourcePath as NSString).appendingPathComponent("index-notion.html")

        // Fallback to project directory
        let projectPath = (NSString(string: "~/Documents/Claude apps/Alfred/Sources/GUI/Resources/index-notion.html").expandingTildeInPath)

        let paths = [htmlPath, projectPath]

        for path in paths {
            if let html = try? String(contentsOfFile: path, encoding: .utf8) {
                return HTTPResponse(
                    statusCode: 200,
                    headers: ["Content-Type": "text/html; charset=utf-8"],
                    htmlBody: html
                )
            }
        }

        // Fallback to original UI
        return handleWebUI()
    }

    private func handleWebUI() -> HTTPResponse {
        // Try to load from Resources directory
        let resourcePath = Bundle.main.resourcePath ?? ""
        let htmlPath = (resourcePath as NSString).appendingPathComponent("index.html")

        // Fallback to project directory
        let projectPath = (NSString(string: "~/Documents/Claude apps/Alfred/Sources/GUI/Resources/index.html").expandingTildeInPath)

        let paths = [htmlPath, projectPath]

        for path in paths {
            if let html = try? String(contentsOfFile: path, encoding: .utf8) {
                return HTTPResponse(
                    statusCode: 200,
                    headers: ["Content-Type": "text/html; charset=utf-8"],
                    htmlBody: html
                )
            }
        }

        // Fallback: simple inline HTML
        let fallbackHTML = """
        <!DOCTYPE html>
        <html><head><meta charset="UTF-8"><title>Alfred Remote</title></head>
        <body><h1>Alfred Remote</h1><p>Web UI file not found. API is available at /api endpoints.</p></body></html>
        """

        return HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "text/html; charset=utf-8"],
            htmlBody: fallbackHTML
        )
    }

    private func handleHealth() -> HTTPResponse {
        return HTTPResponse(
            statusCode: 200,
            body: [
                "status": "ok",
                "timestamp": ISO8601DateFormatter().string(from: Date())
            ]
        )
    }

    private func handleGetCommitments(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            let typeFilter = request.queryParams["type"]
            let commitments: [Commitment]

            if let typeString = typeFilter, let type = parseCommitmentType(typeString) {
                commitments = try await alfredService.fetchCommitments(type: type)
            } else {
                commitments = try await alfredService.fetchCommitments()
            }

            let response: [[String: Any]] = commitments.map { commitment in
                [
                    "id": commitment.id.uuidString,
                    "type": commitment.type.rawValue,
                    "status": commitment.status.rawValue,
                    "title": commitment.title,
                    "commitmentText": commitment.commitmentText,
                    "committedBy": commitment.committedBy,
                    "committedTo": commitment.committedTo,
                    "sourcePlatform": commitment.sourcePlatform.rawValue,
                    "sourceThread": commitment.sourceThread,
                    "dueDate": commitment.dueDate.map { ISO8601DateFormatter().string(from: $0) } as Any,
                    "priority": commitment.priority.rawValue,
                    "isOverdue": commitment.isOverdue
                ]
            }

            return HTTPResponse(
                statusCode: 200,
                body: ["commitments": response, "count": commitments.count]
            )
        } catch {
            return HTTPResponse(
                statusCode: 500,
                body: ["error": error.localizedDescription]
            )
        }
    }

    private func handleGetOverdueCommitments() async -> HTTPResponse {
        do {
            let commitments = try await alfredService.fetchOverdueCommitments()

            let response: [[String: Any]] = commitments.map { commitment in
                [
                    "id": commitment.id.uuidString,
                    "type": commitment.type.rawValue,
                    "status": commitment.status.rawValue,
                    "title": commitment.title,
                    "commitmentText": commitment.commitmentText,
                    "committedBy": commitment.committedBy,
                    "committedTo": commitment.committedTo,
                    "sourcePlatform": commitment.sourcePlatform.rawValue,
                    "sourceThread": commitment.sourceThread,
                    "dueDate": commitment.dueDate.map { ISO8601DateFormatter().string(from: $0) } as Any,
                    "priority": commitment.priority.rawValue,
                    "daysOverdue": commitment.daysUntilDue.map { -$0 } as Any
                ]
            }

            return HTTPResponse(
                statusCode: 200,
                body: ["commitments": response, "count": commitments.count]
            )
        } catch {
            return HTTPResponse(
                statusCode: 500,
                body: ["error": error.localizedDescription]
            )
        }
    }

    private func handleScanCommitments(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            // Parse body
            guard let body = request.body,
                  let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                return HTTPResponse(
                    statusCode: 400,
                    body: ["error": "Invalid JSON body"]
                )
            }

            let contactName = json["contactName"] as? String
            let lookbackDays = json["lookbackDays"] as? Int ?? 14

            let result = try await alfredService.scanCommitments(
                contactName: contactName,
                lookbackDays: lookbackDays
            )

            return HTTPResponse(
                statusCode: 200,
                body: [
                    "found": result.totalFound,
                    "saved": result.saved,
                    "duplicates": result.duplicates
                ]
            )
        } catch {
            return HTTPResponse(
                statusCode: 500,
                body: ["error": error.localizedDescription]
            )
        }
    }

    private func handleGetDailyBriefing(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            // Parse date parameter (default to today)
            let date: Date
            if let dateString = request.queryParams["date"],
               let parsedDate = ISO8601DateFormatter().date(from: dateString) {
                date = parsedDate
            } else {
                date = Date()
            }

            // Generate full daily briefing
            let briefing = try await alfredService.generateDailyBriefing(for: date)

            return HTTPResponse(
                statusCode: 200,
                body: [
                    "date": ISO8601DateFormatter().string(from: briefing.date),
                    "generatedAt": ISO8601DateFormatter().string(from: briefing.generatedAt),
                    "stats": [
                        "meetings": briefing.calendarBriefing.schedule.events.count,
                        "messages": briefing.messagingSummary.stats.totalMessages,
                        "focusTimeSeconds": briefing.calendarBriefing.focusTime
                    ],
                    "actionItems": briefing.actionItems.map { item in
                        [
                            "id": item.id,
                            "title": item.title,
                            "description": item.description,
                            "source": item.source.rawValue,
                            "priority": item.priority.rawValue,
                            "dueDate": item.dueDate.map { ISO8601DateFormatter().string(from: $0) } as Any,
                            "category": item.category.rawValue
                        ]
                    },
                    "calendar": [
                        "events": briefing.calendarBriefing.schedule.events.map { event in
                            [
                                "id": event.id,
                                "title": event.title,
                                "start": ISO8601DateFormatter().string(from: event.startTime),
                                "end": ISO8601DateFormatter().string(from: event.endTime),
                                "location": event.location as Any,
                                "isAllDay": event.isAllDay,
                                "hasExternalAttendees": event.hasExternalAttendees
                            ]
                        },
                        "totalMeetingTime": briefing.calendarBriefing.schedule.totalMeetingTime,
                        "focusTime": briefing.calendarBriefing.focusTime,
                        "recommendations": briefing.calendarBriefing.recommendations
                    ],
                    "messages": [
                        "keyInteractions": briefing.messagingSummary.keyInteractions.map { serializeMessageSummary($0) },
                        "needsResponse": briefing.messagingSummary.needsResponse.map { serializeMessageSummary($0) },
                        "criticalMessages": briefing.messagingSummary.criticalMessages.map { serializeMessageSummary($0) },
                        "stats": [
                            "totalMessages": briefing.messagingSummary.stats.totalMessages,
                            "unreadMessages": briefing.messagingSummary.stats.unreadMessages,
                            "threadsNeedingResponse": briefing.messagingSummary.stats.threadsNeedingResponse
                        ]
                    ]
                ]
            )
        } catch {
            return HTTPResponse(
                statusCode: 500,
                body: ["error": error.localizedDescription]
            )
        }
    }

    private func handleGetCalendar(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            // Parse date and calendar filter
            let date: Date
            if let dateString = request.queryParams["date"],
               let parsedDate = ISO8601DateFormatter().date(from: dateString) {
                date = parsedDate
            } else {
                date = Date()
            }

            let calendar = request.queryParams["calendar"] ?? "all"

            let briefing = try await alfredService.fetchCalendarBriefing(for: date, calendar: calendar)

            return HTTPResponse(
                statusCode: 200,
                body: [
                    "schedule": [
                        "date": ISO8601DateFormatter().string(from: briefing.schedule.date),
                        "events": briefing.schedule.events.map { event in
                            [
                                "id": event.id,
                                "title": event.title,
                                "start": ISO8601DateFormatter().string(from: event.startTime),
                                "end": ISO8601DateFormatter().string(from: event.endTime),
                                "location": event.location as Any,
                                "isAllDay": event.isAllDay,
                                "hasExternalAttendees": event.hasExternalAttendees,
                                "attendeeCount": event.attendees.count
                            ]
                        },
                        "totalMeetingTime": briefing.schedule.totalMeetingTime
                    ],
                    "meetingBriefings": briefing.meetingBriefings.map { meeting in
                        [
                            "event": [
                                "id": meeting.event.id,
                                "title": meeting.event.title,
                                "start": ISO8601DateFormatter().string(from: meeting.event.startTime),
                                "end": ISO8601DateFormatter().string(from: meeting.event.endTime)
                            ],
                            "preparation": meeting.preparation,
                            "suggestedTopics": meeting.suggestedTopics,
                            "context": meeting.context as Any,
                            "attendeeCount": meeting.attendeeBriefings.count
                        ]
                    },
                    "focusTime": briefing.focusTime,
                    "recommendations": briefing.recommendations
                ]
            )
        } catch {
            return HTTPResponse(
                statusCode: 500,
                body: ["error": error.localizedDescription]
            )
        }
    }

    private func handleGetMessages(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            let platform = request.queryParams["platform"] ?? "all"
            let timeframe = request.queryParams["timeframe"] ?? "24h"

            let summaries = try await alfredService.fetchMessagesSummary(
                platform: platform,
                timeframe: timeframe
            )

            return HTTPResponse(
                statusCode: 200,
                body: [
                    "messages": summaries.map { serializeMessageSummary($0) },
                    "count": summaries.count
                ]
            )
        } catch {
            return HTTPResponse(
                statusCode: 500,
                body: ["error": error.localizedDescription]
            )
        }
    }

    private func handleGetAttentionCheck() async -> HTTPResponse {
        do {
            let report = try await alfredService.generateAttentionCheck()

            return HTTPResponse(
                statusCode: 200,
                body: [
                    "currentTime": ISO8601DateFormatter().string(from: report.currentTime),
                    "mustDoToday": report.mustDoToday.map { item in
                        [
                            "id": item.id,
                            "title": item.title,
                            "description": item.description,
                            "priority": item.priority.rawValue,
                            "dueDate": item.dueDate.map { ISO8601DateFormatter().string(from: $0) } as Any
                        ]
                    },
                    "canPushOff": report.canPushOff.map { suggestion in
                        [
                            "item": [
                                "id": suggestion.item.id,
                                "title": suggestion.item.title,
                                "description": suggestion.item.description
                            ],
                            "reason": suggestion.reason,
                            "suggestedNewDate": ISO8601DateFormatter().string(from: suggestion.suggestedNewDate),
                            "impact": suggestion.impact.rawValue
                        ]
                    },
                    "upcomingDeadlines": report.upcomingDeadlines.map { item in
                        [
                            "id": item.id,
                            "title": item.title,
                            "dueDate": item.dueDate.map { ISO8601DateFormatter().string(from: $0) } as Any
                        ]
                    },
                    "timeAvailable": report.timeAvailable,
                    "recommendations": report.recommendations
                ]
            )
        } catch {
            return HTTPResponse(
                statusCode: 500,
                body: ["error": error.localizedDescription]
            )
        }
    }

    private func handleScanTodos() async -> HTTPResponse {
        do {
            let todos = try await alfredService.scanWhatsAppForTodos()

            return HTTPResponse(
                statusCode: 200,
                body: [
                    "todos": todos.map { todo in
                        [
                            "title": todo.title,
                            "description": todo.description as Any,
                            "dueDate": todo.dueDate.map { ISO8601DateFormatter().string(from: $0) } as Any,
                            "source": [
                                "platform": todo.sourceMessage.platform.rawValue,
                                "sender": todo.sourceMessage.senderName ?? todo.sourceMessage.sender,
                                "timestamp": ISO8601DateFormatter().string(from: todo.sourceMessage.timestamp)
                            ]
                        ]
                    },
                    "count": todos.count
                ]
            )
        } catch {
            return HTTPResponse(
                statusCode: 500,
                body: ["error": error.localizedDescription]
            )
        }
    }

    private func handleGetDrafts() async -> HTTPResponse {
        do {
            let drafts = try await alfredService.fetchDrafts()

            let response: [[String: Any]] = drafts.map { draft in
                [
                    "platform": draft.platform.rawValue,
                    "recipient": draft.recipient,
                    "content": draft.content,
                    "tone": draft.tone.rawValue,
                    "suggestedSendTime": draft.suggestedSendTime.map { ISO8601DateFormatter().string(from: $0) } as Any
                ]
            }

            return HTTPResponse(
                statusCode: 200,
                body: ["drafts": response, "count": drafts.count]
            )
        } catch {
            return HTTPResponse(
                statusCode: 500,
                body: ["error": error.localizedDescription]
            )
        }
    }

    private func handleNaturalLanguageQuery(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            // Parse request body
            guard let bodyData = request.body,
                  let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
                  let query = json["query"] as? String else {
                return HTTPResponse(
                    statusCode: 400,
                    body: ["error": "Missing 'query' parameter in request body"]
                )
            }

            // Extract optional session ID for conversation context
            let sessionId = json["sessionId"] as? String ?? "default"

            // Initialize intent recognition and executor
            guard let config = AppConfig.load() else {
                return HTTPResponse(
                    statusCode: 500,
                    body: ["error": "Configuration not loaded"]
                )
            }

            // Access orchestrator from main actor
            let orchestrator = await MainActor.run {
                alfredService.orchestrator
            }

            guard let orchestrator = orchestrator else {
                return HTTPResponse(
                    statusCode: 500,
                    body: ["error": "Alfred not initialized"]
                )
            }

            let intentService = IntentRecognitionService(config: config)
            let executor = IntentExecutor(orchestrator: orchestrator, config: config)

            // Recognize intent with session context
            let intentResponse = try await intentService.recognizeIntent(query, sessionId: sessionId)

            // If clarification needed, return early
            if intentResponse.clarificationNeeded {
                return HTTPResponse(
                    statusCode: 200,
                    body: [
                        "type": "clarification",
                        "question": intentResponse.clarificationQuestion as Any,
                        "originalQuery": query,
                        "sessionId": sessionId
                    ]
                )
            }

            // Execute intent
            let result = try await executor.execute(intentResponse.intent)

            // Record turn in conversation context
            intentService.recordTurn(
                sessionId: sessionId,
                query: query,
                intent: intentResponse.intent,
                result: result
            )

            // Return conversational response
            return HTTPResponse(
                statusCode: 200,
                body: [
                    "type": "result",
                    "query": query,
                    "response": result.conversationalResponse,
                    "data": result.structuredData as Any,
                    "intent": [
                        "action": intentResponse.intent.action.rawValue,
                        "target": intentResponse.intent.target?.rawValue as Any,
                        "confidence": intentResponse.intent.confidence
                    ],
                    "suggestedFollowUps": intentResponse.suggestedFollowUps as Any,
                    "sessionId": sessionId
                ]
            )
        } catch {
            return HTTPResponse(
                statusCode: 500,
                body: ["error": error.localizedDescription]
            )
        }
    }

    // MARK: - Helpers

    private func serializeMessageSummary(_ summary: MessageSummary) -> [String: Any] {
        return [
            "contact": summary.thread.contactName ?? summary.thread.contactIdentifier,
            "platform": summary.thread.platform.rawValue,
            "summary": summary.summary,
            "urgency": summary.urgency.rawValue,
            "unreadCount": summary.thread.unreadCount,
            "lastMessageDate": ISO8601DateFormatter().string(from: summary.thread.lastMessageDate),
            "actionItems": summary.actionItems,
            "sentiment": summary.sentiment,
            "suggestedResponse": summary.suggestedResponse as Any
        ]
    }

    private func parseCommitmentType(_ typeString: String) -> Commitment.CommitmentType? {
        switch typeString.lowercased() {
        case "i_owe", "iowe":
            return .iOwe
        case "they_owe", "theyowe":
            return .theyOwe
        default:
            return nil
        }
    }
}

// MARK: - HTTP Models

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let queryParams: [String: String]
    let body: Data?
}

struct HTTPResponse {
    let statusCode: Int
    let headers: [String: String]
    let body: Data?

    init(statusCode: Int, headers: [String: String] = [:], body: [String: Any]) {
        self.statusCode = statusCode
        var allHeaders = headers
        allHeaders["Content-Type"] = "application/json"
        self.headers = allHeaders
        self.body = try? JSONSerialization.data(withJSONObject: body)
    }

    init(statusCode: Int, headers: [String: String] = [:], htmlBody: String) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = htmlBody.data(using: .utf8)
    }
}

// MARK: - Socket Implementation

class ServerSocket {
    private var socket: Int32

    init(port: Int) throws {
        socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else {
            throw NSError(domain: "HTTPServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create socket"])
        }

        // Set socket options
        var yes: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        // Bind to port
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult >= 0 else {
            Darwin.close(socket)
            throw NSError(domain: "HTTPServer", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to bind to port \(port)"])
        }

        // Listen
        guard Darwin.listen(socket, 5) >= 0 else {
            Darwin.close(socket)
            throw NSError(domain: "HTTPServer", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to listen on socket"])
        }
    }

    func accept() async throws -> ClientSocket {
        return try await withCheckedThrowingContinuation { continuation in
            var addr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

            let clientSocket = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(socket, $0, &addrLen)
                }
            }

            if clientSocket >= 0 {
                continuation.resume(returning: ClientSocket(socket: clientSocket))
            } else {
                continuation.resume(throwing: NSError(domain: "HTTPServer", code: -4, userInfo: [NSLocalizedDescriptionKey: "Failed to accept connection"]))
            }
        }
    }

    func close() {
        Darwin.close(socket)
    }
}

class ClientSocket {
    private var socket: Int32

    init(socket: Int32) {
        self.socket = socket
    }

    func readRequest() async throws -> HTTPRequest? {
        // Read from socket
        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = recv(socket, &buffer, buffer.count, 0)

        guard bytesRead > 0 else { return nil }

        let data = Data(buffer[..<bytesRead])
        guard let requestString = String(data: data, encoding: .utf8) else { return nil }

        let lines = requestString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }

        let requestParts = requestLine.components(separatedBy: " ")
        guard requestParts.count >= 2 else { return nil }

        let method = requestParts[0]
        let fullPath = requestParts[1]

        // Parse path and query params
        let pathComponents = fullPath.components(separatedBy: "?")
        let path = pathComponents[0]
        var queryParams: [String: String] = [:]

        if pathComponents.count > 1 {
            let queryString = pathComponents[1]
            for param in queryString.components(separatedBy: "&") {
                let keyValue = param.components(separatedBy: "=")
                if keyValue.count == 2 {
                    queryParams[keyValue[0]] = keyValue[1]
                }
            }
        }

        // Parse headers
        var headers: [String: String] = [:]
        var bodyStartIndex = 0

        for (index, line) in lines.enumerated() {
            if line.isEmpty {
                bodyStartIndex = index + 1
                break
            }

            if index > 0 {
                let headerParts = line.components(separatedBy: ": ")
                if headerParts.count == 2 {
                    headers[headerParts[0].lowercased()] = headerParts[1]
                }
            }
        }

        // Parse body
        var body: Data?
        if bodyStartIndex < lines.count {
            let bodyString = lines[bodyStartIndex...].joined(separator: "\r\n")
            if !bodyString.isEmpty {
                body = bodyString.data(using: .utf8)
            }
        }

        // If Content-Length header exists but body is empty/nil, try reading more
        if let contentLengthStr = headers["content-length"],
           let contentLength = Int(contentLengthStr),
           contentLength > 0,
           (body == nil || body!.count < contentLength) {
            // Calculate how much body data we already have
            let existingBodyLength = body?.count ?? 0
            let remainingBytes = contentLength - existingBodyLength

            if remainingBytes > 0 {
                var bodyBuffer = [UInt8](repeating: 0, count: remainingBytes)
                let bodyBytesRead = recv(socket, &bodyBuffer, remainingBytes, 0)

                if bodyBytesRead > 0 {
                    let additionalData = Data(bodyBuffer[..<bodyBytesRead])
                    if let existingBody = body {
                        body = existingBody + additionalData
                    } else {
                        body = additionalData
                    }
                }
            }
        }

        return HTTPRequest(
            method: method,
            path: path,
            headers: headers,
            queryParams: queryParams,
            body: body
        )
    }

    func send(_ response: HTTPResponse) async throws {
        var responseString = "HTTP/1.1 \(response.statusCode) \(statusText(response.statusCode))\r\n"

        for (key, value) in response.headers {
            responseString += "\(key): \(value)\r\n"
        }

        if let body = response.body {
            responseString += "Content-Length: \(body.count)\r\n"
        }

        responseString += "\r\n"

        var data = Data(responseString.utf8)
        if let body = response.body {
            data.append(body)
        }

        _ = data.withUnsafeBytes { buffer in
            Darwin.send(socket, buffer.baseAddress, data.count, 0)
        }
    }

    func close() {
        Darwin.close(socket)
    }

    private func statusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default: return "Unknown"
        }
    }
}
