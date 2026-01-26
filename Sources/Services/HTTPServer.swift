import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Simple HTTP server for remote API access
class HTTPServer {
    private let port: Int
    private var passcode: String  // Changed to var for hot reload
    private let alfredService: AlfredService
    private var listener: ServerSocket?
    private let cache: QueryCacheService

    init(port: Int, passcode: String, alfredService: AlfredService) {
        self.port = port
        self.passcode = passcode
        self.alfredService = alfredService
        self.cache = QueryCacheService()
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

        case ("GET", "/api/todos/scan"):
            return await handleScanTodos()

        case ("GET", "/api/commitment-check"):
            return await handleCommitmentCheck(request)

        case ("GET", "/api/messages/summary"):
            return await handleMessagesSummary(request)

        case ("GET", "/api/drafts"):
            return await handleGetDrafts()

        case ("GET", "/api/recent-activity"):
            return handleGetRecentActivity()

        case ("DELETE", "/api/recent-activity/delete"):
            return handleDeleteRecentActivity(request)

        case ("GET", "/api/config/notion"):
            return await handleGetNotionConfig()

        case ("POST", "/api/config/notion"):
            return await handleUpdateNotionConfig(request)

        case ("POST", "/api/config/passcode"):
            return handleUpdatePasscode(request)

        case ("POST", "/api/cache/clear"):
            return handleClearCache()

        case ("POST", "/api/query"):
            return await handleNaturalLanguageQuery(request)

        // Agent endpoints
        case ("GET", "/api/agents"):
            return handleGetAgents()

        case ("GET", "/api/agents/memory"):
            return handleGetAgentMemory(request)

        case ("GET", "/api/agents/skills"):
            return handleGetAgentSkills(request)

        case ("POST", "/api/agents/teach"):
            return handleTeachAgent(request)

        case ("POST", "/api/agents/forget"):
            return handleForgetPattern(request)

        case ("POST", "/api/agents/consolidate"):
            return handleConsolidateLearnings(request)

        case ("GET", "/api/agents/status"):
            return handleAgentLearningStatus(request)

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

            // Format as text response
            let formattedResponse = formatCommitmentsForAPI(commitments)

            return HTTPResponse(
                statusCode: 200,
                body: ["response": formattedResponse, "commitments": response, "count": commitments.count]
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
            let date = parseDate(from: request.queryParams["date"])

            // Generate full daily briefing
            let briefing = try await alfredService.generateDailyBriefing(for: date)

            // Format as text response
            let formattedResponse = formatBriefingForAPI(briefing)

            return HTTPResponse(
                statusCode: 200,
                body: [
                    "response": formattedResponse,
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
        // Parse date and calendar filter
        let date = parseDate(from: request.queryParams["date"])
        let calendar = request.queryParams["calendar"] ?? "all"
        let dateString = ISO8601DateFormatter().string(from: date)

        // Check cache
        let cacheParams = ["date": dateString, "calendar": calendar]
        if let cached = cache.getCached(endpoint: "/api/calendar", params: cacheParams) {
            if let data = cached.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return HTTPResponse(statusCode: 200, body: json)
            }
        }

        do {
            let briefing = try await alfredService.fetchCalendarBriefing(for: date, calendar: calendar)

            // Format as text response with calendar type
            var formattedResponse = "📅 **Calendar"
            if calendar == "personal" {
                formattedResponse += " (Personal)**"
            } else if calendar == "work" {
                formattedResponse += " (Work)**"
            } else {
                formattedResponse += " (All)**"
            }
            formattedResponse += " for \(briefing.schedule.date.formatted(date: .long, time: .omitted))\n\n"
            formattedResponse += formatCalendarForAPI(briefing)

            let responseBody: [String: Any] = [
                "response": formattedResponse,
                "calendar": calendar,
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

            // Cache (1 hour)
            if let jsonData = try? JSONSerialization.data(withJSONObject: responseBody),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                cache.cache(endpoint: "/api/calendar", params: cacheParams, response: jsonString, ttl: 3600)
            }

            return HTTPResponse(statusCode: 200, body: responseBody)
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

            // Format as text response
            var formattedResponse = "🎯 **Attention Check** - \(report.currentTime.formatted(date: .omitted, time: .shortened))\n\n"

            if !report.mustDoToday.isEmpty {
                formattedResponse += "**MUST DO TODAY:**\n"
                for item in report.mustDoToday {
                    let priorityEmoji = item.priority == .high ? "🔴" : item.priority == .medium ? "🟡" : "🟢"
                    formattedResponse += "\(priorityEmoji) \(item.title)\n"
                }
                formattedResponse += "\n"
            }

            if !report.upcomingDeadlines.isEmpty {
                formattedResponse += "**UPCOMING DEADLINES:**\n"
                for item in report.upcomingDeadlines {
                    if let dueDate = item.dueDate {
                        formattedResponse += "• \(item.title) - Due \(dueDate.formatted(date: .abbreviated, time: .omitted))\n"
                    } else {
                        formattedResponse += "• \(item.title)\n"
                    }
                }
                formattedResponse += "\n"
            }

            if !report.canPushOff.isEmpty {
                formattedResponse += "**CAN BE POSTPONED:**\n"
                for suggestion in report.canPushOff {
                    formattedResponse += "• \(suggestion.item.title)\n"
                    formattedResponse += "  Reason: \(suggestion.reason)\n"
                }
            }

            if report.mustDoToday.isEmpty && report.upcomingDeadlines.isEmpty {
                formattedResponse += "✨ You're all caught up! No urgent items requiring immediate attention.\n"
            }

            return HTTPResponse(
                statusCode: 200,
                body: [
                    "response": formattedResponse,
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
        // Check cache first (30 min TTL)
        if let cached = cache.getCached(endpoint: "/api/todos/scan") {
            if let data = cached.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return HTTPResponse(statusCode: 200, body: json)
            }
        }

        do {
            let todos = try await alfredService.scanWhatsAppForTodos()

            // Format response
            var formattedResponse = "📝 **Todo Scan Results**\n\n"
            if todos.isEmpty {
                formattedResponse += "No todos found in recent WhatsApp messages.\n"
            } else {
                formattedResponse += "Found \(todos.count) todo(s) from your messages:\n\n"
                for (index, todo) in todos.enumerated() {
                    formattedResponse += "\(index + 1). \(todo.title)\n"
                    if let description = todo.description, !description.isEmpty {
                        formattedResponse += "   \(description)\n"
                    }
                    if let dueDate = todo.dueDate {
                        formattedResponse += "   📅 Due: \(dueDate.formatted(date: .abbreviated, time: .omitted))\n"
                    }
                    let sender = todo.sourceMessage.senderName ?? todo.sourceMessage.sender
                    formattedResponse += "   👤 From: \(sender)\n\n"
                }
            }

            let responseBody: [String: Any] = [
                "response": formattedResponse,
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

            // Cache the response (30 min)
            if let jsonData = try? JSONSerialization.data(withJSONObject: responseBody),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                cache.cache(endpoint: "/api/todos/scan", response: jsonString, ttl: 1800)
            }

            return HTTPResponse(statusCode: 200, body: responseBody)
        } catch {
            return HTTPResponse(
                statusCode: 500,
                body: ["error": error.localizedDescription]
            )
        }
    }

    private func handleCommitmentCheck(_ request: HTTPRequest) async -> HTTPResponse {
        // Parse parameters
        guard let contact = request.queryParams["contact"] else {
            return HTTPResponse(
                statusCode: 400,
                body: ["error": "Missing 'contact' parameter"]
            )
        }

        let timeframe = request.queryParams["timeframe"] ?? "7d"

        // Check cache
        let cacheParams = ["contact": contact, "timeframe": timeframe]
        if let cached = cache.getCached(endpoint: "/api/commitment-check", params: cacheParams) {
            if let data = cached.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return HTTPResponse(statusCode: 200, body: json)
            }
        }

        do {
            // Scan messages for commitments with this contact
            let commitments = try await alfredService.scanMessagesForCommitments(
                contact: contact,
                timeframe: timeframe
            )

            // Format response
            var formattedResponse = "✅ **Commitment Check** for \(contact)\n"
            formattedResponse += "Period: Last \(timeframe)\n\n"

            if commitments.isEmpty {
                formattedResponse += "No commitments found with \(contact) in this period.\n"
            } else {
                formattedResponse += "Found \(commitments.count) commitment(s):\n\n"

                let toContact = commitments.filter { $0.committedTo == contact }
                let fromContact = commitments.filter { $0.committedBy == contact }

                if !toContact.isEmpty {
                    formattedResponse += "**You committed to \(contact):**\n"
                    for commitment in toContact {
                        let statusEmoji = commitment.status == .completed ? "✅" : "⏳"
                        formattedResponse += "\(statusEmoji) \(commitment.title)\n"
                        if let dueDate = commitment.dueDate {
                            formattedResponse += "   Due: \(dueDate.formatted(date: .abbreviated, time: .omitted))\n"
                        }
                    }
                    formattedResponse += "\n"
                }

                if !fromContact.isEmpty {
                    formattedResponse += "**\(contact) committed to you:**\n"
                    for commitment in fromContact {
                        let statusEmoji = commitment.status == .completed ? "✅" : "⏳"
                        formattedResponse += "\(statusEmoji) \(commitment.title)\n"
                        if let dueDate = commitment.dueDate {
                            formattedResponse += "   Due: \(dueDate.formatted(date: .abbreviated, time: .omitted))\n"
                        }
                    }
                }
            }

            let responseBody: [String: Any] = [
                "response": formattedResponse,
                "contact": contact,
                "timeframe": timeframe,
                "commitments": commitments.map { commitment in
                    [
                        "id": commitment.id.uuidString,
                        "title": commitment.title,
                        "committedBy": commitment.committedBy,
                        "committedTo": commitment.committedTo,
                        "status": commitment.status.rawValue,
                        "dueDate": commitment.dueDate.map { ISO8601DateFormatter().string(from: $0) } as Any
                    ]
                },
                "count": commitments.count
            ]

            // Cache (1 hour)
            if let jsonData = try? JSONSerialization.data(withJSONObject: responseBody),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                cache.cache(endpoint: "/api/commitment-check", params: cacheParams, response: jsonString, ttl: 3600)
            }

            return HTTPResponse(statusCode: 200, body: responseBody)
        } catch {
            // Provide helpful error message for Notion configuration issues
            let errorMessage: String
            if error.localizedDescription.contains("object_not_found") || error.localizedDescription.contains("database with ID") {
                errorMessage = """
❌ **Notion Database Not Found**

The Commitment Check feature requires a properly configured Notion database.

**Steps to fix:**
1. Check your config at `~/.config/alfred/config.json`
2. Verify the `notion_database_id` under `commitments` is correct
3. Make sure the database is shared with your Notion integration
4. Run `alfred commitments init` in the CLI for setup help

**Original error:** \(error.localizedDescription)
"""
            } else {
                errorMessage = error.localizedDescription
            }

            return HTTPResponse(
                statusCode: 500,
                body: [
                    "error": errorMessage,
                    "response": errorMessage
                ]
            )
        }
    }

    private func handleMessagesSummary(_ request: HTTPRequest) async -> HTTPResponse {
        // Parse parameters
        guard let contact = request.queryParams["contact"] else {
            return HTTPResponse(
                statusCode: 400,
                body: ["error": "Missing 'contact' parameter"]
            )
        }

        let platform = request.queryParams["platform"] ?? "whatsapp"
        let timeframe = request.queryParams["timeframe"] ?? "7d"

        // Check cache
        let cacheParams = ["contact": contact, "platform": platform, "timeframe": timeframe]
        if let cached = cache.getCached(endpoint: "/api/messages/summary", params: cacheParams) {
            if let data = cached.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return HTTPResponse(statusCode: 200, body: json)
            }
        }

        do {
            // Get messages summary
            let summary = try await alfredService.getMessagesSummaryForContact(
                contact: contact,
                platform: platform,
                timeframe: timeframe
            )

            // Format response
            var formattedResponse = "💬 **Messages Summary**\n"
            formattedResponse += "Contact: \(contact)\n"
            formattedResponse += "Platform: \(platform)\n"
            formattedResponse += "Period: Last \(timeframe)\n\n"

            formattedResponse += "**Summary:**\n\(summary.summary)\n\n"

            if !summary.keyPoints.isEmpty {
                formattedResponse += "**Key Points:**\n"
                for point in summary.keyPoints {
                    formattedResponse += "• \(point)\n"
                }
                formattedResponse += "\n"
            }

            if summary.needsResponse {
                formattedResponse += "⚠️ This conversation may need a response\n"
            }

            let responseBody: [String: Any] = [
                "response": formattedResponse,
                "contact": contact,
                "platform": platform,
                "timeframe": timeframe,
                "summary": summary.summary,
                "keyPoints": summary.keyPoints,
                "needsResponse": summary.needsResponse,
                "messageCount": summary.messageCount
            ]

            // Cache (30 min)
            if let jsonData = try? JSONSerialization.data(withJSONObject: responseBody),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                cache.cache(endpoint: "/api/messages/summary", params: cacheParams, response: jsonString, ttl: 1800)
            }

            return HTTPResponse(statusCode: 200, body: responseBody)
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

    private func handleGetRecentActivity() -> HTTPResponse {
        let recentQueries = cache.getRecentQueries(limit: 10)

        let activities: [[String: Any]] = recentQueries.map { (endpoint, paramsJSON, timestamp) in
            // Parse params JSON
            var params: [String: Any] = [:]
            if let data = paramsJSON.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                params = parsed
            }

            // Create readable label from endpoint and params
            var label = endpoint
            switch endpoint {
            case "/api/briefing":
                if let date = params["date"] as? String {
                    label = "Daily Briefing - \(date)"
                } else {
                    label = "Daily Briefing"
                }
            case "/api/calendar":
                let cal = params["calendar"] as? String ?? "all"
                if let date = params["date"] as? String {
                    label = "Calendar (\(cal)) - \(date)"
                } else {
                    label = "Calendar (\(cal))"
                }
            case "/api/commitments":
                label = "My Commitments"
            case "/api/commitment-check":
                if let contact = params["contact"] as? String {
                    let timeframe = params["timeframe"] as? String ?? "7d"
                    label = "Commitment Check: \(contact) (\(timeframe))"
                } else {
                    label = "Commitment Check"
                }
            case "/api/todos/scan":
                label = "Scan Todos"
            case "/api/messages/summary":
                if let contact = params["contact"] as? String {
                    let platform = params["platform"] as? String ?? "whatsapp"
                    let timeframe = params["timeframe"] as? String ?? "7d"
                    label = "Messages: \(contact) on \(platform) (\(timeframe))"
                } else {
                    label = "Messages Summary"
                }
            case "/api/attention-check":
                label = "Attention Check"
            default:
                break
            }

            // Format timestamp
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            let timeStr = formatter.string(from: timestamp)

            return [
                "label": label,
                "endpoint": endpoint,
                "params": params,
                "timestamp": timeStr,
                "rawTimestamp": timestamp.timeIntervalSince1970
            ]
        }

        return HTTPResponse(
            statusCode: 200,
            body: ["activities": activities, "count": activities.count]
        )
    }

    private func handleDeleteRecentActivity(_ request: HTTPRequest) -> HTTPResponse {
        guard let endpoint = request.queryParams["endpoint"] else {
            return HTTPResponse(
                statusCode: 400,
                body: ["error": "Missing endpoint parameter"]
            )
        }

        // Parse remaining query params as the cache params
        var params: [String: String] = [:]
        for (key, value) in request.queryParams {
            if key != "endpoint" && key != "passcode" {
                params[key] = value
            }
        }

        let success = cache.deleteEntry(endpoint: endpoint, params: params)

        if success {
            return HTTPResponse(
                statusCode: 200,
                body: ["message": "Cache entry deleted successfully"]
            )
        } else {
            return HTTPResponse(
                statusCode: 404,
                body: ["error": "Cache entry not found"]
            )
        }
    }

    private func handleGetNotionConfig() async -> HTTPResponse {
        // Read from config file
        let configPath = NSString(string: "~/.config/alfred/config.json").expandingTildeInPath

        guard FileManager.default.fileExists(atPath: configPath) else {
            return HTTPResponse(
                statusCode: 200,
                body: ["tasksDatabaseId": NSNull()]
            )
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
            let config = try JSONSerialization.jsonObject(with: data) as? [String: Any]

            // Try to find tasks_database_id in various locations
            var tasksDatabaseId: String?

            // Check notion.briefing_sources.tasks_database_id
            if let notion = config?["notion"] as? [String: Any],
               let briefingSources = notion["briefing_sources"] as? [String: Any],
               let dbId = briefingSources["tasks_database_id"] as? String {
                tasksDatabaseId = dbId
            }

            // Fallback to top-level tasks_database_id
            if tasksDatabaseId == nil {
                tasksDatabaseId = config?["tasks_database_id"] as? String
            }

            return HTTPResponse(
                statusCode: 200,
                body: ["tasksDatabaseId": tasksDatabaseId as Any]
            )
        } catch {
            return HTTPResponse(
                statusCode: 500,
                body: ["error": "Failed to read config: \(error.localizedDescription)"]
            )
        }
    }

    private func handleUpdateNotionConfig(_ request: HTTPRequest) async -> HTTPResponse {
        guard let bodyData = request.body,
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let tasksDatabaseId = json["tasksDatabaseId"] as? String else {
            return HTTPResponse(
                statusCode: 400,
                body: ["error": "Missing tasksDatabaseId in request body"]
            )
        }

        // Update the Tasks database ID in the orchestrator's NotionService
        await MainActor.run {
            guard let orchestrator = alfredService.orchestrator else {
                return
            }
            orchestrator.notionServicePublic.setTasksDatabaseId(tasksDatabaseId)
        }

        // Also update in config file
        let configPath = NSString(string: "~/.config/alfred/config.json").expandingTildeInPath
        do {
            if FileManager.default.fileExists(atPath: configPath) {
                let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
                var config = try JSONSerialization.jsonObject(with: data) as! [String: Any]

                // Update in notion.briefing_sources.tasks_database_id
                if var notion = config["notion"] as? [String: Any] {
                    if var briefingSources = notion["briefing_sources"] as? [String: Any] {
                        briefingSources["tasks_database_id"] = tasksDatabaseId
                        notion["briefing_sources"] = briefingSources
                        config["notion"] = notion
                    }
                }

                let updatedData = try JSONSerialization.data(withJSONObject: config, options: .prettyPrinted)
                try updatedData.write(to: URL(fileURLWithPath: configPath))
            }
        } catch {
            print("⚠️ Failed to update config file: \(error)")
        }

        return HTTPResponse(
            statusCode: 200,
            body: ["message": "Notion configuration updated successfully", "tasksDatabaseId": tasksDatabaseId]
        )
    }

    private func handleUpdatePasscode(_ request: HTTPRequest) -> HTTPResponse {
        guard let bodyData = request.body,
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let newPasscode = json["newPasscode"] as? String else {
            return HTTPResponse(
                statusCode: 400,
                body: ["error": "Missing newPasscode in request body"]
            )
        }

        // Validate new passcode
        guard !newPasscode.isEmpty else {
            return HTTPResponse(
                statusCode: 400,
                body: ["error": "Passcode cannot be empty"]
            )
        }

        // Update passcode in memory (hot reload)
        self.passcode = newPasscode

        // Persist to config file
        let configPath = NSString(string: "~/.config/alfred/config.json").expandingTildeInPath
        do {
            if FileManager.default.fileExists(atPath: configPath) {
                let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
                var config = try JSONSerialization.jsonObject(with: data) as! [String: Any]

                // Update passcode in config
                config["api_passcode"] = newPasscode

                let updatedData = try JSONSerialization.data(withJSONObject: config, options: .prettyPrinted)
                try updatedData.write(to: URL(fileURLWithPath: configPath))

                print("🔐 Passcode updated successfully (hot reload)")
            }
        } catch {
            print("⚠️ Failed to persist passcode to config file: \(error)")
            // Still return success since in-memory update worked
        }

        return HTTPResponse(
            statusCode: 200,
            body: ["message": "Passcode updated successfully", "requiresReauth": true]
        )
    }

    private func handleClearCache() -> HTTPResponse {
        cache.clearAll()
        return HTTPResponse(
            statusCode: 200,
            body: ["message": "All cache cleared successfully"]
        )
    }

    // MARK: - Agent Handlers

    private func handleGetAgents() -> HTTPResponse {
        let memoryService = AgentMemoryService.shared
        let agentTypes: [AgentType] = [.communication, .task, .calendar, .followup]

        var agents: [[String: Any]] = []
        for agentType in agentTypes {
            let summary = memoryService.getMemorySummary(for: agentType)
            let skills = memoryService.getSkills(for: agentType)

            agents.append([
                "type": agentType.rawValue,
                "displayName": agentType.displayName,
                "skills": skills.capabilities,
                "memory": [
                    "taughtRulesCount": summary.taughtRulesCount,
                    "learnedPatternsCount": summary.learnedPatternsCount,
                    "contactsKnown": summary.contactsKnown,
                    "lastUpdated": summary.formattedLastUpdated
                ]
            ])
        }

        return HTTPResponse(
            statusCode: 200,
            body: [
                "agents": agents,
                "response": formatAgentsSummary(agents)
            ]
        )
    }

    private func handleGetAgentMemory(_ request: HTTPRequest) -> HTTPResponse {
        guard let agentName = request.queryParams["agent"] else {
            // Return all agents' memory summaries
            let memoryService = AgentMemoryService.shared
            let agentTypes: [AgentType] = [.communication, .task, .calendar, .followup]

            var memories: [[String: Any]] = []
            for agentType in agentTypes {
                let summary = memoryService.getMemorySummary(for: agentType)
                memories.append([
                    "type": agentType.rawValue,
                    "displayName": agentType.displayName,
                    "taughtRulesCount": summary.taughtRulesCount,
                    "learnedPatternsCount": summary.learnedPatternsCount,
                    "contactsKnown": summary.contactsKnown,
                    "lastUpdated": summary.formattedLastUpdated
                ])
            }

            return HTTPResponse(
                statusCode: 200,
                body: ["memories": memories]
            )
        }

        guard let agentType = parseAgentType(agentName) else {
            return HTTPResponse(
                statusCode: 400,
                body: ["error": "Unknown agent: \(agentName). Valid agents: communication, task, calendar, followup"]
            )
        }

        let memoryService = AgentMemoryService.shared
        let memory = memoryService.getMemory(for: agentType)
        let summary = memoryService.getMemorySummary(for: agentType)

        return HTTPResponse(
            statusCode: 200,
            body: [
                "agent": agentType.rawValue,
                "displayName": agentType.displayName,
                "content": memory.content,
                "sections": memory.sections,
                "summary": [
                    "taughtRulesCount": summary.taughtRulesCount,
                    "learnedPatternsCount": summary.learnedPatternsCount,
                    "contactsKnown": summary.contactsKnown,
                    "lastUpdated": summary.formattedLastUpdated
                ],
                "response": "🧠 **\(agentType.displayName) Agent Memory**\n\n\(memory.content)"
            ]
        )
    }

    private func handleGetAgentSkills(_ request: HTTPRequest) -> HTTPResponse {
        guard let agentName = request.queryParams["agent"] else {
            // Return all agents' skills summaries
            let memoryService = AgentMemoryService.shared
            let agentTypes: [AgentType] = [.communication, .task, .calendar, .followup]

            var allSkills: [[String: Any]] = []
            for agentType in agentTypes {
                let skills = memoryService.getSkills(for: agentType)
                allSkills.append([
                    "type": agentType.rawValue,
                    "displayName": agentType.displayName,
                    "capabilities": skills.capabilities
                ])
            }

            return HTTPResponse(
                statusCode: 200,
                body: ["skills": allSkills]
            )
        }

        guard let agentType = parseAgentType(agentName) else {
            return HTTPResponse(
                statusCode: 400,
                body: ["error": "Unknown agent: \(agentName). Valid agents: communication, task, calendar, followup"]
            )
        }

        let memoryService = AgentMemoryService.shared
        let skills = memoryService.getSkills(for: agentType)

        return HTTPResponse(
            statusCode: 200,
            body: [
                "agent": agentType.rawValue,
                "displayName": agentType.displayName,
                "content": skills.content,
                "capabilities": skills.capabilities,
                "response": "⚡ **\(agentType.displayName) Agent Skills**\n\n\(skills.content)"
            ]
        )
    }

    private func handleTeachAgent(_ request: HTTPRequest) -> HTTPResponse {
        guard let bodyData = request.body,
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let agentName = json["agent"] as? String,
              let rule = json["rule"] as? String else {
            return HTTPResponse(
                statusCode: 400,
                body: ["error": "Missing required fields: 'agent' and 'rule'"]
            )
        }

        guard let agentType = parseAgentType(agentName) else {
            return HTTPResponse(
                statusCode: 400,
                body: ["error": "Unknown agent: \(agentName). Valid agents: communication, task, calendar, followup"]
            )
        }

        let category = json["category"] as? String

        let memoryService = AgentMemoryService.shared
        do {
            try memoryService.teach(agentType: agentType, rule: rule, category: category)
            return HTTPResponse(
                statusCode: 200,
                body: [
                    "success": true,
                    "message": "Taught \(agentType.displayName) agent: \"\(rule)\"",
                    "agent": agentType.rawValue,
                    "rule": rule,
                    "response": "✅ **Rule Taught**\n\nThe \(agentType.displayName) agent will now follow this rule:\n\n> \(rule)"
                ]
            )
        } catch {
            return HTTPResponse(
                statusCode: 500,
                body: ["error": "Failed to teach agent: \(error.localizedDescription)"]
            )
        }
    }

    private func handleForgetPattern(_ request: HTTPRequest) -> HTTPResponse {
        guard let bodyData = request.body,
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let agentName = json["agent"] as? String,
              let pattern = json["pattern"] as? String else {
            return HTTPResponse(
                statusCode: 400,
                body: ["error": "Missing required fields: 'agent' and 'pattern'"]
            )
        }

        guard let agentType = parseAgentType(agentName) else {
            return HTTPResponse(
                statusCode: 400,
                body: ["error": "Unknown agent: \(agentName). Valid agents: communication, task, calendar, followup"]
            )
        }

        let memoryService = AgentMemoryService.shared
        do {
            let found = try memoryService.forget(agentType: agentType, pattern: pattern)
            if found {
                return HTTPResponse(
                    statusCode: 200,
                    body: [
                        "success": true,
                        "message": "Removed pattern containing \"\(pattern)\" from \(agentType.displayName) memory",
                        "response": "✅ **Pattern Removed**\n\nRemoved patterns containing \"\(pattern)\" from \(agentType.displayName) agent memory."
                    ]
                )
            } else {
                return HTTPResponse(
                    statusCode: 404,
                    body: [
                        "success": false,
                        "message": "No patterns containing \"\(pattern)\" found in \(agentType.displayName) memory",
                        "response": "⚠️ No patterns containing \"\(pattern)\" found in \(agentType.displayName) agent memory."
                    ]
                )
            }
        } catch {
            return HTTPResponse(
                statusCode: 500,
                body: ["error": "Failed to forget pattern: \(error.localizedDescription)"]
            )
        }
    }

    private func parseAgentType(_ name: String) -> AgentType? {
        switch name.lowercased() {
        case "communication", "comm", "com":
            return .communication
        case "task", "tasks":
            return .task
        case "calendar", "cal":
            return .calendar
        case "followup", "follow", "followups":
            return .followup
        default:
            return nil
        }
    }

    private func handleConsolidateLearnings(_ request: HTTPRequest) -> HTTPResponse {
        let memoryService = AgentMemoryService.shared

        // Get summary first
        let summary = memoryService.getConsolidationSummary()

        if summary.patternsReadyForConsolidation == 0 {
            return HTTPResponse(
                statusCode: 200,
                body: [
                    "success": true,
                    "message": "No patterns ready for consolidation",
                    "response": "🧠 **Learning Consolidation**\n\nNo patterns ready for consolidation yet.\n\nPatterns need:\n- Confidence >= 70%\n- At least 5 feedback instances\n\nTotal patterns tracked: \(summary.totalPatterns)",
                    "summary": [
                        "totalPatterns": summary.totalPatterns,
                        "patternsReadyForConsolidation": summary.patternsReadyForConsolidation,
                        "patternsByAgent": summary.patternsByAgent
                    ]
                ]
            )
        }

        do {
            try memoryService.consolidateLearnings()

            var agentDetails = ""
            for (agent, count) in summary.patternsByAgent {
                agentDetails += "\n- \(agent): \(count) patterns"
            }

            return HTTPResponse(
                statusCode: 200,
                body: [
                    "success": true,
                    "message": "Consolidated \(summary.patternsReadyForConsolidation) patterns to agent memory files",
                    "response": "🧠 **Learning Consolidation Complete**\n\nConsolidated \(summary.patternsReadyForConsolidation) high-confidence patterns to agent memories.\n\n**By Agent:**\(agentDetails)\n\nThese learnings are now incorporated into agent prompts.",
                    "summary": [
                        "totalPatterns": summary.totalPatterns,
                        "patternsConsolidated": summary.patternsReadyForConsolidation,
                        "patternsByAgent": summary.patternsByAgent
                    ]
                ]
            )
        } catch {
            return HTTPResponse(
                statusCode: 500,
                body: ["error": "Failed to consolidate learnings: \(error.localizedDescription)"]
            )
        }
    }

    private func handleAgentLearningStatus(_ request: HTTPRequest) -> HTTPResponse {
        let memoryService = AgentMemoryService.shared
        let consolidationSummary = memoryService.getConsolidationSummary()

        var agentStatuses: [[String: Any]] = []

        for agentType in [AgentType.communication, .task, .calendar, .followup] {
            let memorySummary = memoryService.getMemorySummary(for: agentType)
            agentStatuses.append([
                "type": agentType.rawValue,
                "displayName": agentType.displayName,
                "taughtRulesCount": memorySummary.taughtRulesCount,
                "learnedPatternsCount": memorySummary.learnedPatternsCount,
                "contactsKnown": memorySummary.contactsKnown,
                "lastUpdated": memorySummary.formattedLastUpdated
            ])
        }

        var responseText = "🧠 **Agent Learning Status**\n\n"
        responseText += "**Learning Database:**\n"
        responseText += "- Total patterns tracked: \(consolidationSummary.totalPatterns)\n"
        responseText += "- Ready for consolidation: \(consolidationSummary.patternsReadyForConsolidation)\n\n"
        responseText += "**Agent Memories:**\n"

        for status in agentStatuses {
            let displayName = status["displayName"] as? String ?? ""
            let rules = status["taughtRulesCount"] as? Int ?? 0
            let patterns = status["learnedPatternsCount"] as? Int ?? 0
            let lastUpdated = status["lastUpdated"] as? String ?? "Never"
            responseText += "\n**\(displayName) Agent**\n"
            responseText += "- Taught rules: \(rules)\n"
            responseText += "- Learned patterns: \(patterns)\n"
            responseText += "- Last updated: \(lastUpdated)\n"
        }

        return HTTPResponse(
            statusCode: 200,
            body: [
                "response": responseText,
                "learningDatabase": [
                    "totalPatterns": consolidationSummary.totalPatterns,
                    "patternsReadyForConsolidation": consolidationSummary.patternsReadyForConsolidation,
                    "patternsByAgent": consolidationSummary.patternsByAgent
                ],
                "agents": agentStatuses
            ]
        )
    }

    private func formatAgentsSummary(_ agents: [[String: Any]]) -> String {
        var output = "🤖 **Alfred Agents**\n\n"

        for agent in agents {
            let displayName = agent["displayName"] as? String ?? "Unknown"
            let skills = agent["skills"] as? [String] ?? []
            let memory = agent["memory"] as? [String: Any] ?? [:]
            let rulesCount = memory["taughtRulesCount"] as? Int ?? 0
            let patternsCount = memory["learnedPatternsCount"] as? Int ?? 0

            output += "**\(displayName) Agent**\n"
            output += "• Skills: \(skills.joined(separator: ", "))\n"
            output += "• Memory: \(rulesCount) rules, \(patternsCount) patterns learned\n\n"
        }

        output += "---\n"
        output += "Use the Agents panel to view details, teach rules, or manage memory."

        return output
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

    /// Parse a date string from query parameters, supporting multiple formats.
    /// Handles both full ISO8601 (with time) and date-only formats (YYYY-MM-DD).
    private func parseDate(from dateString: String?) -> Date {
        guard let dateString = dateString else {
            return Date()
        }

        // Try full ISO8601 format first (e.g., "2026-01-27T00:00:00Z")
        let fullFormatter = ISO8601DateFormatter()
        if let parsedDate = fullFormatter.date(from: dateString) {
            return parsedDate
        }

        // Try date-only ISO8601 format (e.g., "2026-01-27")
        let dateOnlyFormatter = ISO8601DateFormatter()
        dateOnlyFormatter.formatOptions = [.withFullDate, .withDashSeparatorInDate]
        if let parsedDate = dateOnlyFormatter.date(from: dateString) {
            return parsedDate
        }

        // Fallback: try DateFormatter for YYYY-MM-DD with local timezone
        let fallbackFormatter = DateFormatter()
        fallbackFormatter.dateFormat = "yyyy-MM-dd"
        fallbackFormatter.timeZone = TimeZone.current
        return fallbackFormatter.date(from: dateString) ?? Date()
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
                    // URL decode the parameter value
                    let decodedValue = keyValue[1].removingPercentEncoding ?? keyValue[1]
                    queryParams[keyValue[0]] = decodedValue
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

// MARK: - Formatting Helpers for API Responses
extension HTTPServer {
    private func formatBriefingForAPI(_ briefing: DailyBriefing) -> String {
        var output = ""

        output += "📅 **Daily Briefing** for \(briefing.date.formatted(date: .long, time: .omitted))\n\n"

        // Messages Summary
        output += "**MESSAGES SUMMARY**\n"
        output += "• Total Messages: \(briefing.messagingSummary.stats.totalMessages)\n"
        output += "• Unread: \(briefing.messagingSummary.stats.unreadMessages)\n"
        output += "• Threads Needing Response: \(briefing.messagingSummary.stats.threadsNeedingResponse)\n\n"

        if !briefing.messagingSummary.criticalMessages.isEmpty {
            output += "**CRITICAL MESSAGES:**\n"
            for summary in briefing.messagingSummary.criticalMessages.prefix(5) {
                output += "• \(summary.thread.contactName ?? "Unknown") (\(summary.thread.platform.rawValue))\n"
                output += "  \(summary.summary)\n"
                output += "  Urgency: \(summary.urgency.rawValue)\n\n"
            }
        }

        // Calendar
        output += "**TODAY'S SCHEDULE**\n"
        output += "• Total Meeting Time: \(formatDurationForAPI(briefing.calendarBriefing.schedule.totalMeetingTime))\n"
        output += "• Focus Time Available: \(formatDurationForAPI(briefing.calendarBriefing.focusTime))\n"
        output += "• External Meetings: \(briefing.calendarBriefing.schedule.externalMeetings.count)\n\n"

        if !briefing.calendarBriefing.schedule.events.isEmpty {
            output += "**EVENTS:**\n"
            for event in briefing.calendarBriefing.schedule.events {
                let startTime = event.startTime.formatted(date: .omitted, time: .shortened)
                let endTime = event.endTime.formatted(date: .omitted, time: .shortened)
                output += "• \(startTime) - \(endTime): \(event.title)\n"
                if let location = event.location, !location.isEmpty {
                    output += "  📍 \(location)\n"
                }
                if event.hasExternalAttendees {
                    output += "  👥 External attendees\n"
                }
            }
            output += "\n"
        }

        // Action Items
        if !briefing.actionItems.isEmpty {
            output += "**ACTION ITEMS:**\n"
            for item in briefing.actionItems.prefix(10) {
                let priorityEmoji = item.priority == .high ? "🔴" : item.priority == .medium ? "🟡" : "🟢"
                output += "\(priorityEmoji) \(item.title)\n"
                if !item.description.isEmpty {
                    output += "  \(item.description)\n"
                }
            }
        }

        return output
    }

    private func formatCalendarForAPI(_ briefing: CalendarBriefing) -> String {
        var output = ""

        output += "📅 **Calendar** for \(briefing.schedule.date.formatted(date: .long, time: .omitted))\n\n"
        output += "• Total Meeting Time: \(formatDurationForAPI(briefing.schedule.totalMeetingTime))\n"
        output += "• Focus Time Available: \(formatDurationForAPI(briefing.focusTime))\n"
        output += "• External Meetings: \(briefing.schedule.externalMeetings.count)\n\n"

        if !briefing.schedule.events.isEmpty {
            output += "**EVENTS:**\n"
            for event in briefing.schedule.events {
                let startTime = event.startTime.formatted(date: .omitted, time: .shortened)
                let endTime = event.endTime.formatted(date: .omitted, time: .shortened)
                output += "• \(startTime) - \(endTime): \(event.title)\n"
                if let location = event.location, !location.isEmpty {
                    output += "  📍 \(location)\n"
                }
                if event.hasExternalAttendees {
                    output += "  👥 \(event.attendees.count) attendees (external meeting)\n"
                }
            }
        } else {
            output += "No events scheduled.\n"
        }

        if !briefing.recommendations.isEmpty {
            output += "\n**RECOMMENDATIONS:**\n"
            for rec in briefing.recommendations {
                output += "• \(rec)\n"
            }
        }

        return output
    }

    private func formatCommitmentsForAPI(_ commitments: [Commitment]) -> String {
        var output = ""

        if commitments.isEmpty {
            return "No commitments found."
        }

        output += "✅ **Commitments** (\(commitments.count) total)\n\n"

        for commitment in commitments {
            let statusEmoji = commitment.status == .completed ? "✅" : commitment.status == .inProgress ? "🔄" : "⏳"
            output += "\(statusEmoji) \(commitment.title)\n"
            output += "  From: \(commitment.committedBy)\n"
            output += "  To: \(commitment.committedTo)\n"
            if let dueDate = commitment.dueDate {
                output += "  Due: \(dueDate.formatted(date: .abbreviated, time: .omitted))\n"
            }
            output += "\n"
        }

        return output
    }

    private func formatAttentionCheckForAPI() -> String {
        return "🎯 **Attention Check**\n\nWhat needs your focus right now?\n\nThis feature analyzes your commitments, calendar, and messages to identify what requires immediate attention."
    }

    private func formatDurationForAPI(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60

        if hours > 0 && minutes > 0 {
            return "\(hours)h \(minutes)m"
        } else if hours > 0 {
            return "\(hours)h"
        } else if minutes > 0 {
            return "\(minutes)m"
        } else {
            return "0m"
        }
    }
}
