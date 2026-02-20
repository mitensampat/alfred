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

    // Session management
    private var activeSessions: [String: Session] = [:]
    private let sessionLock = NSLock()
    private let sessionDuration: TimeInterval = 24 * 60 * 60 // 24 hours

    struct Session {
        let token: String
        let createdAt: Date
        let expiresAt: Date
    }

    init(port: Int, passcode: String, alfredService: AlfredService) {
        self.port = port
        self.passcode = passcode
        self.alfredService = alfredService
    }

    // MARK: - Session Management

    private func createSession() -> Session {
        let token = UUID().uuidString + "-" + UUID().uuidString
        let now = Date()
        let session = Session(
            token: token,
            createdAt: now,
            expiresAt: now.addingTimeInterval(sessionDuration)
        )

        sessionLock.lock()
        activeSessions[token] = session
        // Clean up expired sessions
        activeSessions = activeSessions.filter { $0.value.expiresAt > now }
        sessionLock.unlock()

        return session
    }

    private func validateSession(token: String) -> Bool {
        sessionLock.lock()
        defer { sessionLock.unlock() }

        guard let session = activeSessions[token] else {
            return false
        }

        return session.expiresAt > Date()
    }

    private func invalidateSession(token: String) {
        sessionLock.lock()
        activeSessions.removeValue(forKey: token)
        sessionLock.unlock()
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

            // Allow auth endpoints without authentication (they validate passcode internally)
            if request.path == "/api/auth/login" || request.path == "/api/auth/logout" || request.path == "/api/auth/validate" {
                let response = await routeAuth(request)
                try await client.send(response)
                return
            }

            // Allow FTUE setup endpoints without authentication (needed before setup is complete)
            if request.path.hasPrefix("/api/setup/") {
                let response = await route(request)
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
        // Check Authorization header for session token (preferred)
        if let authHeader = request.headers["authorization"] {
            let parts = authHeader.split(separator: " ")
            if parts.count == 2 && parts[0].lowercased() == "bearer" {
                let token = String(parts[1])
                if validateSession(token: token) {
                    return true
                }
            }
        }

        // Check X-API-Key header (legacy, still works with passcode)
        if let apiKey = request.headers["x-api-key"], apiKey == passcode {
            return true
        }

        // Check query parameter (legacy, still works with passcode)
        if let queryPasscode = request.queryParams["passcode"], queryPasscode == passcode {
            return true
        }

        return false
    }

    // MARK: - Auth Routes

    private func routeAuth(_ request: HTTPRequest) async -> HTTPResponse {
        switch (request.method, request.path) {
        case ("POST", "/api/auth/login"):
            return handleLogin(request)

        case ("POST", "/api/auth/logout"):
            return handleLogout(request)

        case ("GET", "/api/auth/validate"):
            return handleValidateSession(request)

        default:
            return HTTPResponse(statusCode: 404, body: ["error": "Auth endpoint not found"])
        }
    }

    private func handleLogin(_ request: HTTPRequest) -> HTTPResponse {
        guard let bodyData = request.body,
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let providedPasscode = json["passcode"] as? String else {
            return HTTPResponse(
                statusCode: 400,
                body: ["error": "Missing passcode in request body"]
            )
        }

        // Validate passcode
        guard providedPasscode == passcode else {
            return HTTPResponse(
                statusCode: 401,
                body: ["error": "Invalid passcode"]
            )
        }

        // Create session
        let session = createSession()

        return HTTPResponse(
            statusCode: 200,
            body: [
                "success": true,
                "token": session.token,
                "expiresAt": ISO8601DateFormatter().string(from: session.expiresAt)
            ]
        )
    }

    private func handleLogout(_ request: HTTPRequest) -> HTTPResponse {
        // Get token from Authorization header
        if let authHeader = request.headers["authorization"] {
            let parts = authHeader.split(separator: " ")
            if parts.count == 2 && parts[0].lowercased() == "bearer" {
                let token = String(parts[1])
                invalidateSession(token: token)
            }
        }

        return HTTPResponse(
            statusCode: 200,
            body: ["success": true, "message": "Logged out successfully"]
        )
    }

    private func handleValidateSession(_ request: HTTPRequest) -> HTTPResponse {
        // Check Authorization header
        if let authHeader = request.headers["authorization"] {
            let parts = authHeader.split(separator: " ")
            if parts.count == 2 && parts[0].lowercased() == "bearer" {
                let token = String(parts[1])
                if validateSession(token: token) {
                    return HTTPResponse(
                        statusCode: 200,
                        body: ["valid": true]
                    )
                }
            }
        }

        return HTTPResponse(
            statusCode: 401,
            body: ["valid": false, "error": "Invalid or expired session"]
        )
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

        case ("GET", "/api/commitment-tracker/stats"):
            return handleGetCommitmentTrackerStats()

        case ("GET", "/api/commitment-tracker/pending-closures"):
            return handleGetPendingClosures()

        case ("POST", "/api/commitment-tracker/confirm-closure"):
            return await handleConfirmClosure(request)

        case ("POST", "/api/commitment-tracker/reject-closure"):
            return handleRejectClosure(request)

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

        // Correction tracking for learning
        case ("POST", "/api/corrections"):
            return handleRecordCorrection(request)

        case ("GET", "/api/corrections"):
            return handleGetCorrections(request)

        // Contact learning
        case ("POST", "/api/contacts/participation"):
            return handleRecordParticipation(request)

        case ("POST", "/api/contacts/extraction"):
            return handleRecordExtraction(request)

        case ("GET", "/api/contacts"):
            return handleGetContacts(request)

        // Hot-reload endpoints
        case ("POST", "/api/reload-config"):
            return handleReloadConfig()

        case ("GET", "/api/hot-reload/status"):
            return handleHotReloadStatus()

        // FTUE Setup endpoints
        case ("GET", "/api/setup/status"):
            return handleGetSetupStatus()

        case ("POST", "/api/setup/step"):
            return await handleSaveSetupStep(request)

        case ("POST", "/api/setup/test-api-key"):
            return await handleTestApiKey(request)

        case ("POST", "/api/setup/test-notion"):
            return await handleTestNotion(request)

        case ("GET", "/api/setup/notion-databases"):
            return await handleGetNotionDatabases()

        case ("POST", "/api/setup/complete"):
            return handleCompleteSetup()

        // Task/Commitment status updates
        case ("PATCH", "/api/tasks/status"):
            return await handleUpdateTaskStatus(request)

        // Nudge message generation
        case ("POST", "/api/nudge/generate"):
            return await handleGenerateNudge(request)

        // Auto-completion detection
        case ("POST", "/api/commitments/detect-completions"):
            return await handleDetectCompletions(request)

        default:
            return HTTPResponse(
                statusCode: 404,
                body: ["error": "Endpoint not found"]
            )
        }
    }

    // MARK: - API Handlers

    private func handleWebUIv2() -> HTTPResponse {
        // Use HotReloadManager for hot-reloadable web files
        if let html = HotReloadManager.shared.getWebFile("index-v2.html") {
            return HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "text/html; charset=utf-8"],
                htmlBody: html
            )
        }

        // Fallback to v1
        return handleWebUI()
    }

    private func handleNotionUI() -> HTTPResponse {
        // Use HotReloadManager for hot-reloadable web files
        if let html = HotReloadManager.shared.getWebFile("index-notion.html") {
            return HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "text/html; charset=utf-8"],
                htmlBody: html
            )
        }

        // Fallback to original UI
        return handleWebUI()
    }

    private func handleWebUI() -> HTTPResponse {
        // Use HotReloadManager for hot-reloadable web files
        if let html = HotReloadManager.shared.getWebFile("index.html") {
            return HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "text/html; charset=utf-8"],
                htmlBody: html
            )
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
                    "notionId": commitment.notionId as Any,
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
                    "notionId": commitment.notionId as Any,
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

    /// Generate a nudge message for a "They Owe Me" commitment
    private func handleGenerateNudge(_ request: HTTPRequest) async -> HTTPResponse {
        guard let body = request.body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return HTTPResponse(
                statusCode: 400,
                body: ["error": "Invalid request body"]
            )
        }

        let title = json["title"] as? String ?? "the item"
        let committedBy = json["committedBy"] as? String ?? "them"
        let commitmentText = json["commitmentText"] as? String ?? title
        let dueDate = json["dueDate"] as? String
        let isOverdue = json["isOverdue"] as? Bool ?? false
        let sourceThread = json["sourceThread"] as? String

        // Build context for nudge generation
        var context = "Commitment: \(commitmentText)"
        if let thread = sourceThread {
            context += "\nFrom conversation with: \(thread)"
        }
        if let due = dueDate {
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: due) {
                let dateFormatter = DateFormatter()
                dateFormatter.dateStyle = .medium
                context += "\nDue date: \(dateFormatter.string(from: date))"
            }
        }
        if isOverdue {
            context += "\nStatus: OVERDUE"
        }

        do {
            let nudgeMessage = try await generateNudgeWithLLM(
                personName: committedBy,
                commitment: title,
                context: context,
                isOverdue: isOverdue
            )

            return HTTPResponse(
                statusCode: 200,
                body: [
                    "message": nudgeMessage,
                    "recipient": committedBy,
                    "commitment": title
                ]
            )
        } catch {
            print("❌ Failed to generate nudge: \(error)")
            return HTTPResponse(
                statusCode: 500,
                body: ["error": "Failed to generate nudge: \(error.localizedDescription)"]
            )
        }
    }

    /// Generate nudge message using Claude API
    private func generateNudgeWithLLM(personName: String, commitment: String, context: String, isOverdue: Bool) async throws -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(alfredService.claudeApiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")

        let urgency = isOverdue ? "The commitment is overdue, so be slightly more direct but still friendly." : "The commitment is not overdue yet, so keep it casual and friendly."

        let prompt = """
        Generate a short, friendly follow-up message to remind someone about something they committed to.

        Person to message: \(personName)
        \(context)

        \(urgency)

        Guidelines:
        - Keep it brief (2-3 sentences max)
        - Be friendly and professional
        - Don't be pushy or passive-aggressive
        - Reference the specific commitment
        - If overdue, gently acknowledge the timeline without being accusatory
        - End with an offer to help or a simple question

        Return ONLY the message text, no quotes or explanation.
        """

        let body: [String: Any] = [
            "model": "claude-3-haiku-20240307",  // Use Haiku for fast, cheap nudge generation
            "max_tokens": 200,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]

        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw NSError(domain: "NudgeGeneration", code: 1, userInfo: [NSLocalizedDescriptionKey: "API request failed"])
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let content = json?["content"] as? [[String: Any]],
              let firstContent = content.first,
              let text = firstContent["text"] as? String else {
            throw NSError(domain: "NudgeGeneration", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid response format"])
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Detect completion signals in messages and match to open commitments
    private func handleDetectCompletions(_ request: HTTPRequest) async -> HTTPResponse {
        guard let body = request.body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let contact = json["contact"] as? String else {
            return HTTPResponse(
                statusCode: 400,
                body: ["error": "Missing required field: contact"]
            )
        }

        let timeframe = json["timeframe"] as? String ?? "24h"

        do {
            // Get recent messages from this contact
            let messages = try await alfredService.fetchRecentMessages(from: contact, timeframe: timeframe)

            // Look for completion signals in messages
            let completionSignals = detectCompletionSignals(in: messages)

            if completionSignals.isEmpty {
                return HTTPResponse(
                    statusCode: 200,
                    body: ["completions": [], "message": "No completion signals detected"]
                )
            }

            // Get open commitments for this contact to match against
            let commitments = try await alfredService.fetchCommitments(contact: contact)
            let openCommitments = commitments.filter { $0.status == .open || $0.status == .inProgress }

            // Match completion signals to commitments
            let matches = matchCompletionsToCommitments(signals: completionSignals, commitments: openCommitments)

            let response: [[String: Any]] = matches.map { match in
                [
                    "signal": [
                        "message": match.signal.messageContent,
                        "timestamp": ISO8601DateFormatter().string(from: match.signal.timestamp),
                        "sender": match.signal.sender
                    ],
                    "commitment": match.commitment.map { c in
                        [
                            "id": c.id.uuidString,
                            "notionId": c.notionId as Any,
                            "title": c.title,
                            "type": c.type.rawValue,
                            "status": c.status.rawValue
                        ]
                    } as Any,
                    "confidence": match.confidence
                ]
            }

            return HTTPResponse(
                statusCode: 200,
                body: [
                    "completions": response,
                    "count": matches.count,
                    "contact": contact
                ]
            )
        } catch {
            print("❌ Failed to detect completions: \(error)")
            return HTTPResponse(
                statusCode: 500,
                body: ["error": "Failed to detect completions: \(error.localizedDescription)"]
            )
        }
    }

    // MARK: - Completion Detection Helpers

    struct CompletionSignal {
        let messageContent: String
        let timestamp: Date
        let sender: String
        let keywords: [String]
    }

    struct CompletionMatch {
        let signal: CompletionSignal
        let commitment: Commitment?
        let confidence: Double
    }

    /// Detect completion signals in messages
    private func detectCompletionSignals(in messages: [Message]) -> [CompletionSignal] {
        let completionPatterns: [(pattern: String, keywords: [String])] = [
            ("done", ["done", "finished", "completed"]),
            ("sent", ["sent", "sent it", "shared", "shared it"]),
            ("fixed", ["fixed", "fixed it", "resolved"]),
            ("updated", ["updated", "updated it", "changed"]),
            ("submitted", ["submitted", "filed", "delivered"]),
            ("called", ["called", "spoke with", "talked to"]),
            ("scheduled", ["scheduled", "booked", "set up"]),
            ("paid", ["paid", "transferred", "sent payment"]),
            ("replied", ["replied", "responded", "answered"]),
            ("reviewed", ["reviewed", "looked at", "checked"]),
            ("✅", ["✅", "✔️", "👍"]),
            ("here you go", ["here you go", "here it is", "attached"])
        ]

        var signals: [CompletionSignal] = []

        for message in messages {
            let lowercased = message.content.lowercased()
            var matchedKeywords: [String] = []

            for (_, keywords) in completionPatterns {
                for keyword in keywords {
                    if lowercased.contains(keyword) {
                        matchedKeywords.append(keyword)
                    }
                }
            }

            // If message has completion signals and is short (likely a status update)
            if !matchedKeywords.isEmpty && message.content.count < 200 {
                signals.append(CompletionSignal(
                    messageContent: message.content,
                    timestamp: message.timestamp,
                    sender: message.senderName ?? message.sender,
                    keywords: matchedKeywords
                ))
            }
        }

        return signals
    }

    /// Match completion signals to open commitments
    private func matchCompletionsToCommitments(signals: [CompletionSignal], commitments: [Commitment]) -> [CompletionMatch] {
        var matches: [CompletionMatch] = []

        for signal in signals {
            var bestMatch: Commitment?
            var bestConfidence = 0.0

            for commitment in commitments {
                let confidence = calculateMatchConfidence(signal: signal, commitment: commitment)
                if confidence > bestConfidence && confidence >= 0.3 {
                    bestMatch = commitment
                    bestConfidence = confidence
                }
            }

            matches.append(CompletionMatch(
                signal: signal,
                commitment: bestMatch,
                confidence: bestConfidence
            ))
        }

        return matches
    }

    /// Calculate how likely a completion signal relates to a commitment
    private func calculateMatchConfidence(signal: CompletionSignal, commitment: Commitment) -> Double {
        var confidence = 0.0

        let signalLower = signal.messageContent.lowercased()
        let titleLower = commitment.title.lowercased()
        let textLower = commitment.commitmentText.lowercased()

        // Check for word overlap with commitment title
        let signalWords = Set(signalLower.components(separatedBy: .alphanumerics.inverted).filter { $0.count > 2 })
        let titleWords = Set(titleLower.components(separatedBy: .alphanumerics.inverted).filter { $0.count > 2 })

        let overlap = signalWords.intersection(titleWords)
        if !overlap.isEmpty {
            confidence += Double(overlap.count) * 0.2
        }

        // Check if signal mentions similar topic words from commitment text
        let commitmentWords = Set(textLower.components(separatedBy: .alphanumerics.inverted).filter { $0.count > 3 })
        let topicOverlap = signalWords.intersection(commitmentWords)
        if !topicOverlap.isEmpty {
            confidence += Double(topicOverlap.count) * 0.1
        }

        // Sender match (person who made commitment confirming completion)
        if signal.sender.localizedCaseInsensitiveContains(commitment.committedBy) ||
           commitment.committedBy.localizedCaseInsensitiveContains(signal.sender) {
            confidence += 0.3
        }

        // Time proximity (more recent = more relevant)
        if let _ = commitment.createdAt {
            confidence += 0.1
        }

        // If commitment is overdue and there's a completion signal, higher confidence
        if commitment.isOverdue {
            confidence += 0.2
        }

        return min(confidence, 1.0)
    }

    /// Update task/commitment status (syncs to Notion)
    private func handleUpdateTaskStatus(_ request: HTTPRequest) async -> HTTPResponse {
        // Parse request body
        guard let body = request.body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let notionId = json["notionId"] as? String,
              let statusString = json["status"] as? String else {
            return HTTPResponse(
                statusCode: 400,
                body: ["error": "Missing required fields: notionId, status"]
            )
        }

        // Validate status
        guard let status = TaskItem.TaskStatus(rawValue: statusString) else {
            return HTTPResponse(
                statusCode: 400,
                body: ["error": "Invalid status. Valid values: Not Started, In Progress, Done, Cancelled"]
            )
        }

        do {
            // Update in Notion
            try await notionService.updateTaskStatus(notionId: notionId, status: status)

            print("✅ Updated task \(notionId) to status: \(status.rawValue)")

            return HTTPResponse(
                statusCode: 200,
                body: [
                    "success": true,
                    "notionId": notionId,
                    "newStatus": status.rawValue,
                    "message": "Status updated successfully"
                ]
            )
        } catch {
            print("❌ Failed to update task status: \(error)")
            return HTTPResponse(
                statusCode: 500,
                body: ["error": "Failed to update status: \(error.localizedDescription)"]
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

    // MARK: - Commitment Tracker Stats

    private func handleGetCommitmentTrackerStats() -> HTTPResponse {
        let stats = CommitmentScanTracker.shared.getStats()

        return HTTPResponse(
            statusCode: 200,
            body: [
                "openCommitments": stats.openCommitments,
                "closedCount": stats.closedCount,
                "autoClosedCount": stats.autoClosedCount,
                "pendingClosures": stats.pendingClosures,
                "totalExtracted": stats.totalExtracted,
                "threadsTracked": stats.threadsTracked,
                "favoritesCount": stats.favoritesCount,
                "activeThreadsCount": stats.activeThreadsCount,
                "lastScanTime": stats.lastScanTime.map { ISO8601DateFormatter().string(from: $0) } as Any
            ]
        )
    }

    private func handleGetPendingClosures() -> HTTPResponse {
        let pendingClosures = CommitmentScanTracker.shared.getPendingClosureConfirmations()

        let response: [[String: Any]] = pendingClosures.map { closure in
            [
                "hash": closure.hash,
                "title": closure.title,
                "signal": closure.signal,
                "confidence": closure.confidence
            ]
        }

        return HTTPResponse(
            statusCode: 200,
            body: ["pendingClosures": response, "count": pendingClosures.count]
        )
    }

    private func handleConfirmClosure(_ request: HTTPRequest) async -> HTTPResponse {
        guard let body = request.body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let hash = json["hash"] as? String else {
            return HTTPResponse(
                statusCode: 400,
                body: ["error": "Missing 'hash' in request body"]
            )
        }

        // Mark as closed in tracker (also records learning event)
        CommitmentScanTracker.shared.markCommitmentClosed(hash: hash, closureMethod: "user-confirmed")

        // Also close in Notion
        do {
            try await notionService.closeCommitmentInTasks(hash: hash, reason: "User confirmed closure")
            return HTTPResponse(
                statusCode: 200,
                body: ["success": true, "message": "Commitment closed"]
            )
        } catch {
            return HTTPResponse(
                statusCode: 500,
                body: ["error": error.localizedDescription]
            )
        }
    }

    private func handleRejectClosure(_ request: HTTPRequest) -> HTTPResponse {
        guard let body = request.body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let hash = json["hash"] as? String else {
            return HTTPResponse(
                statusCode: 400,
                body: ["error": "Missing 'hash' in request body"]
            )
        }

        // Mark the closure detection as rejected (user_confirmed = false)
        // This prevents it from being suggested again
        CommitmentScanTracker.shared.rejectClosureDetection(hash: hash)

        return HTTPResponse(
            statusCode: 200,
            body: ["success": true, "message": "Closure suggestion rejected"]
        )
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
            let result = try await alfredService.scanWhatsAppForTodos()
            let todos = result.createdTodos

            return HTTPResponse(
                statusCode: 200,
                body: [
                    "todosFound": result.todosFound,
                    "todosCreated": result.todosCreated,
                    "messagesScanned": result.messagesScanned,
                    "duplicatesSkipped": result.duplicatesSkipped,
                    "lookbackDays": result.lookbackDays,
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
                    "count": result.todosCreated
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

            let intentService = IntentRecognitionService(config: config, conversationContext: ConversationContext.shared)
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

    // MARK: - Correction Tracking

    private func handleRecordCorrection(_ request: HTTPRequest) -> HTTPResponse {
        guard let bodyData = request.body,
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            return HTTPResponse(
                statusCode: 400,
                body: ["error": "Invalid request body"]
            )
        }

        let type = json["type"] as? String ?? "false_positive"
        let itemType = json["itemType"] as? String ?? "Unknown"
        let title = json["title"] as? String ?? ""
        let description = json["description"] as? String
        let reason = json["reason"] as? String
        let source = json["source"] as? String

        if type == "false_positive" {
            CorrectionTracker.shared.recordFalsePositive(
                itemType: itemType,
                title: title,
                description: description,
                reason: reason,
                source: source
            )
        } else if type == "edited" {
            let editedTitle = json["editedTitle"] as? String
            let editedDescription = json["editedDescription"] as? String

            CorrectionTracker.shared.recordEdit(
                itemType: itemType,
                originalTitle: title,
                editedTitle: editedTitle,
                originalDescription: description,
                editedDescription: editedDescription,
                source: source
            )
        }

        return HTTPResponse(
            statusCode: 200,
            body: ["success": true, "message": "Correction recorded"]
        )
    }

    private func handleGetCorrections(_ request: HTTPRequest) -> HTTPResponse {
        let itemType = request.queryParams["itemType"]
        let corrections = CorrectionTracker.shared.getCorrections(forType: itemType)
        let stats = CorrectionTracker.shared.getStats()

        return HTTPResponse(
            statusCode: 200,
            body: [
                "corrections": corrections.map { correction -> [String: Any] in
                    var dict: [String: Any] = [
                        "id": correction.id,
                        "type": correction.type.rawValue,
                        "itemType": correction.itemType,
                        "title": correction.title,
                        "timestamp": ISO8601DateFormatter().string(from: correction.timestamp)
                    ]
                    if let desc = correction.description { dict["description"] = desc }
                    if let reason = correction.reason { dict["reason"] = reason }
                    if let source = correction.source { dict["source"] = source }
                    if let editedTitle = correction.editedTitle { dict["editedTitle"] = editedTitle }
                    if let editedDesc = correction.editedDescription { dict["editedDescription"] = editedDesc }
                    return dict
                },
                "stats": [
                    "total": stats.totalCorrections,
                    "falsePositives": stats.falsePositives,
                    "edits": stats.edits,
                    "byType": stats.byItemType
                ]
            ]
        )
    }

    // MARK: - Contact Learning

    private func handleRecordParticipation(_ request: HTTPRequest) -> HTTPResponse {
        guard let bodyData = request.body,
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            return HTTPResponse(
                statusCode: 400,
                body: ["error": "Invalid request body"]
            )
        }

        guard let platform = json["platform"] as? String,
              let threadId = json["threadId"] as? String,
              let threadName = json["threadName"] as? String,
              let userMessages = json["userMessages"] as? Int,
              let totalMessages = json["totalMessages"] as? Int else {
            return HTTPResponse(
                statusCode: 400,
                body: ["error": "Missing required fields: platform, threadId, threadName, userMessages, totalMessages"]
            )
        }

        let isGroup = json["isGroup"] as? Bool ?? false

        ContactLearner.shared.recordParticipation(
            platform: platform,
            threadId: threadId,
            threadName: threadName,
            isGroup: isGroup,
            userMessages: userMessages,
            totalMessages: totalMessages
        )

        return HTTPResponse(
            statusCode: 200,
            body: ["success": true, "message": "Participation recorded"]
        )
    }

    private func handleRecordExtraction(_ request: HTTPRequest) -> HTTPResponse {
        guard let bodyData = request.body,
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            return HTTPResponse(
                statusCode: 400,
                body: ["error": "Invalid request body"]
            )
        }

        guard let platform = json["platform"] as? String,
              let threadId = json["threadId"] as? String,
              let itemsExtracted = json["itemsExtracted"] as? Int,
              let itemsRejected = json["itemsRejected"] as? Int else {
            return HTTPResponse(
                statusCode: 400,
                body: ["error": "Missing required fields: platform, threadId, itemsExtracted, itemsRejected"]
            )
        }

        ContactLearner.shared.recordExtractionResult(
            platform: platform,
            threadId: threadId,
            itemsExtracted: itemsExtracted,
            itemsRejected: itemsRejected
        )

        return HTTPResponse(
            statusCode: 200,
            body: ["success": true, "message": "Extraction result recorded"]
        )
    }

    private func handleGetContacts(_ request: HTTPRequest) -> HTTPResponse {
        let classification = request.queryParams["classification"]
        let stats = ContactLearner.shared.getStats()

        var threads: [ThreadRecord]
        if let classStr = classification, let cls = ThreadClassification(rawValue: classStr) {
            threads = ContactLearner.shared.getThreads(classification: cls)
        } else {
            threads = ContactLearner.shared.getAllThreads()
        }

        return HTTPResponse(
            statusCode: 200,
            body: [
                "threads": threads.map { thread -> [String: Any] in
                    return [
                        "platform": thread.platform,
                        "threadId": thread.threadId,
                        "threadName": thread.threadName,
                        "isGroup": thread.isGroup,
                        "avgParticipation": thread.avgParticipation,
                        "classification": thread.classification.rawValue,
                        "lastSeen": thread.lastSeen,
                        "extractionStats": [
                            "itemsExtracted": thread.extractionStats.itemsExtracted,
                            "itemsRejected": thread.extractionStats.itemsRejected,
                            "rejectionRate": thread.extractionStats.rejectionRate
                        ]
                    ]
                },
                "stats": [
                    "totalThreads": stats.totalThreads,
                    "observeThreads": stats.observeThreads,
                    "minimalThreads": stats.minimalThreads,
                    "activeThreads": stats.activeThreads
                ]
            ]
        )
    }

    // MARK: - Hot Reload Handlers

    private func handleReloadConfig() -> HTTPResponse {
        if let config = HotReloadManager.shared.reloadConfig() {
            return HTTPResponse(
                statusCode: 200,
                body: [
                    "success": true,
                    "message": "Configuration reloaded successfully",
                    "timestamp": ISO8601DateFormatter().string(from: Date())
                ]
            )
        } else {
            return HTTPResponse(
                statusCode: 500,
                body: [
                    "success": false,
                    "error": "Failed to reload configuration"
                ]
            )
        }
    }

    private func handleHotReloadStatus() -> HTTPResponse {
        let status = HotReloadManager.shared.getStatus()
        return HTTPResponse(
            statusCode: 200,
            body: [
                "hotReload": [
                    "enabled": true,
                    "webDir": status["webDir"] as Any,
                    "promptsDir": status["promptsDir"] as Any,
                    "webFiles": status["webFiles"] as Any,
                    "promptFiles": status["promptFiles"] as Any,
                    "configPath": status["configPath"] as Any
                ],
                "instructions": [
                    "webUI": "Edit files in ~/.config/alfred/web/ and refresh browser",
                    "prompts": "Edit files in ~/.config/alfred/prompts/ - changes apply on next API call",
                    "config": "Edit ~/.config/alfred/config.json and call POST /api/reload-config"
                ]
            ]
        )
    }

    // MARK: - FTUE Setup Handlers

    private func handleGetSetupStatus() -> HTTPResponse {
        let status = SetupStatusService.shared.getStatus()
        return HTTPResponse(
            statusCode: 200,
            body: [
                "isComplete": status.isComplete,
                "completedSteps": status.completedSteps,
                "missingRequirements": status.missingRequirements,
                "currentStep": status.currentStep
            ]
        )
    }

    private func handleSaveSetupStep(_ request: HTTPRequest) async -> HTTPResponse {
        guard let bodyData = request.body,
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let step = json["step"] as? String else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing step in request"])
        }

        let data = json["data"] as? [String: Any] ?? [:]

        do {
            try SetupStatusService.shared.saveStepToConfig(step: step, data: data)
            SetupStatusService.shared.markStepComplete(step)

            return HTTPResponse(statusCode: 200, body: ["success": true, "step": step])
        } catch {
            return HTTPResponse(statusCode: 500, body: ["error": "Failed to save step: \(error.localizedDescription)"])
        }
    }

    private func handleTestApiKey(_ request: HTTPRequest) async -> HTTPResponse {
        guard let bodyData = request.body,
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let apiKey = json["apiKey"] as? String else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing apiKey in request"])
        }

        // Test Claude API key by making a simple request
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var testRequest = URLRequest(url: url)
        testRequest.httpMethod = "POST"
        testRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        testRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        testRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let testBody: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 10,
            "messages": [["role": "user", "content": "Say hi"]]
        ]

        testRequest.httpBody = try? JSONSerialization.data(withJSONObject: testBody)
        testRequest.timeoutInterval = 15

        do {
            let (_, response) = try await URLSession.shared.data(for: testRequest)
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    return HTTPResponse(statusCode: 200, body: ["valid": true, "message": "API key is valid"])
                } else if httpResponse.statusCode == 401 {
                    return HTTPResponse(statusCode: 200, body: ["valid": false, "error": "Invalid API key"])
                } else {
                    return HTTPResponse(statusCode: 200, body: ["valid": false, "error": "API returned status \(httpResponse.statusCode)"])
                }
            }
        } catch {
            return HTTPResponse(statusCode: 200, body: ["valid": false, "error": "Connection failed: \(error.localizedDescription)"])
        }

        return HTTPResponse(statusCode: 200, body: ["valid": false, "error": "Unknown error"])
    }

    private func handleTestNotion(_ request: HTTPRequest) async -> HTTPResponse {
        guard let bodyData = request.body,
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let apiKey = json["apiKey"] as? String else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing apiKey in request"])
        }

        // Test Notion API connection
        let url = URL(string: "https://api.notion.com/v1/users/me")!
        var testRequest = URLRequest(url: url)
        testRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        testRequest.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        testRequest.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: testRequest)
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    let userData = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    let userName = userData?["name"] as? String ?? "Connected"
                    return HTTPResponse(statusCode: 200, body: ["valid": true, "user": userName])
                } else if httpResponse.statusCode == 401 {
                    return HTTPResponse(statusCode: 200, body: ["valid": false, "error": "Invalid Notion token"])
                } else {
                    return HTTPResponse(statusCode: 200, body: ["valid": false, "error": "Notion returned status \(httpResponse.statusCode)"])
                }
            }
        } catch {
            return HTTPResponse(statusCode: 200, body: ["valid": false, "error": "Connection failed: \(error.localizedDescription)"])
        }

        return HTTPResponse(statusCode: 200, body: ["valid": false, "error": "Unknown error"])
    }

    private func handleGetNotionDatabases() async -> HTTPResponse {
        // Load config to get Notion API key
        guard let config = AppConfig.load(),
              !config.notion.apiKey.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Notion API key not configured"])
        }

        // Search for databases the integration has access to
        let url = URL(string: "https://api.notion.com/v1/search")!
        var searchRequest = URLRequest(url: url)
        searchRequest.httpMethod = "POST"
        searchRequest.setValue("Bearer \(config.notion.apiKey)", forHTTPHeaderField: "Authorization")
        searchRequest.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        searchRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let searchBody: [String: Any] = [
            "filter": ["property": "object", "value": "database"],
            "page_size": 100
        ]
        searchRequest.httpBody = try? JSONSerialization.data(withJSONObject: searchBody)
        searchRequest.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: searchRequest)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let results = json["results"] as? [[String: Any]] {

                    let databases = results.compactMap { db -> [String: Any]? in
                        guard let id = db["id"] as? String else { return nil }

                        // Extract title from title property
                        var title = "Untitled"
                        if let titleArray = db["title"] as? [[String: Any]],
                           let firstTitle = titleArray.first,
                           let plainText = firstTitle["plain_text"] as? String {
                            title = plainText
                        }

                        // Extract icon
                        var icon = ""
                        if let iconObj = db["icon"] as? [String: Any] {
                            if let emoji = iconObj["emoji"] as? String {
                                icon = emoji
                            }
                        }

                        return [
                            "id": id,
                            "title": title,
                            "icon": icon
                        ]
                    }

                    return HTTPResponse(statusCode: 200, body: ["databases": databases])
                }
            }
        } catch {
            return HTTPResponse(statusCode: 500, body: ["error": "Failed to fetch databases: \(error.localizedDescription)"])
        }

        return HTTPResponse(statusCode: 500, body: ["error": "Failed to parse Notion response"])
    }

    private func handleCompleteSetup() -> HTTPResponse {
        SetupStatusService.shared.completeSetup()
        return HTTPResponse(statusCode: 200, body: ["success": true, "message": "Setup completed"])
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
