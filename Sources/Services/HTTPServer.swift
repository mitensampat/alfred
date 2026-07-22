import Foundation
import AppKit
import SQLite3
import Contacts
import UserNotifications
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Simple HTTP server for remote API access
/// Fast in-memory cache entry
private struct MemoryCacheEntry {
    let data: Any
    let expiresAt: Date
}

class HTTPServer {
    private let port: Int
    private var passcode: String  // Changed to var for hot reload
    private let alfredService: AlfredService
    private var listener: ServerSocket?
    private let cache: QueryCacheService

    // Fast in-memory cache for expensive operations (bypasses SQLite overhead)
    private var memoryCache: [String: MemoryCacheEntry] = [:]
    private let memoryCacheLock = NSLock()
    private let memoryCacheTTL: TimeInterval = 300 // 5 minutes

    // Reusable CoachingEngine (its internal 2h cache is only useful if the instance persists)
    private var coachingEngine: CoachingEngine?

    // Relationship data cache (WhatsApp reads are expensive — 5 min TTL)
    private var relationshipDataCache: (data: String, timestamp: Date)?
    private let relationshipCacheTTL: TimeInterval = 300 // 5 minutes

    // AppConfig cache (avoid re-reading JSON from disk on every request)
    private var _cachedConfig: AppConfig?
    private var _configLoadTime: Date?

    // CadenceRunner for manual cadence execution via API
    private var cadenceRunner: CadenceRunner?

    // Static date formatters (expensive to create, reuse across requests)
    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        return formatter
    }()

    private static let iso8601DateOnlyFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withDashSeparatorInDate]
        return formatter
    }()

    private static let iso8601FractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let simpleDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    // Session management
    private var activeSessions: [String: Session] = [:]
    private let sessionLock = NSLock()
    private let sessionDuration: TimeInterval = 24 * 60 * 60 // 24 hours
    private var lastSessionCleanup: Date = Date()
    private let sessionsFilePath: String

    struct Session: Codable {
        let token: String
        let createdAt: Date
        let expiresAt: Date
    }

    init(port: Int, passcode: String, alfredService: AlfredService, cadenceRunner: CadenceRunner? = nil) {
        self.port = port
        self.passcode = passcode
        self.alfredService = alfredService
        self.cadenceRunner = cadenceRunner
        self.cache = QueryCacheService()

        // Setup sessions file path
        let alfredDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".alfred")
        try? FileManager.default.createDirectory(at: alfredDir, withIntermediateDirectories: true)
        self.sessionsFilePath = alfredDir.appendingPathComponent("sessions.json").path

        // Load persisted sessions
        loadSessions()
    }

    // MARK: - Session Persistence

    private func loadSessions() {
        sessionLock.lock()
        defer { sessionLock.unlock() }

        guard FileManager.default.fileExists(atPath: sessionsFilePath),
              let data = FileManager.default.contents(atPath: sessionsFilePath) else {
            return
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let sessions = try decoder.decode([String: Session].self, from: data)

            // Only load non-expired sessions
            let now = Date()
            activeSessions = sessions.filter { $0.value.expiresAt > now }
            print("✓ Loaded \(activeSessions.count) valid sessions from disk")
        } catch {
            print("⚠️ Failed to load sessions: \(error)")
        }
    }

    private func saveSessions() {
        // Called within sessionLock, so don't lock again
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(activeSessions)
            try data.write(to: URL(fileURLWithPath: sessionsFilePath))
        } catch {
            print("⚠️ Failed to save sessions: \(error)")
        }
    }

    // MARK: - Memory Cache Helpers

    private func getFromMemoryCache<T>(_ key: String) -> T? {
        memoryCacheLock.lock()
        defer { memoryCacheLock.unlock() }

        guard let entry = memoryCache[key],
              entry.expiresAt > Date() else {
            return nil
        }
        return entry.data as? T
    }

    private func setInMemoryCache(_ key: String, value: Any, ttl: TimeInterval? = nil) {
        memoryCacheLock.lock()
        defer { memoryCacheLock.unlock() }

        let expiresAt = Date().addingTimeInterval(ttl ?? memoryCacheTTL)
        memoryCache[key] = MemoryCacheEntry(data: value, expiresAt: expiresAt)
    }

    /// Remove a specific key from the in-memory cache
    private func invalidateMemoryCache(_ key: String) {
        memoryCacheLock.lock()
        defer { memoryCacheLock.unlock() }
        memoryCache.removeValue(forKey: key)
    }

    /// Remove all keys matching a prefix from the in-memory cache
    private func invalidateMemoryCacheByPrefix(_ prefix: String) {
        memoryCacheLock.lock()
        defer { memoryCacheLock.unlock() }
        memoryCache = memoryCache.filter { !$0.key.hasPrefix(prefix) }
    }

    /// Clear the entire in-memory cache
    private func clearAllMemoryCache() {
        memoryCacheLock.lock()
        defer { memoryCacheLock.unlock() }
        memoryCache.removeAll()
    }

    // MARK: - Cached AppConfig

    /// Returns a cached AppConfig, re-reading from disk at most once per minute
    private func getConfig() -> AppConfig? {
        if let config = _cachedConfig,
           let loadTime = _configLoadTime,
           Date().timeIntervalSince(loadTime) < 60 {
            return config
        }
        let config = AppConfig.load()
        _cachedConfig = config
        _configLoadTime = Date()
        return config
    }

    // MARK: - Session Management

    private func createSession() -> Session {
        let token = UUID().uuidString + "-" + UUID().uuidString
        let now = Date()
        let session = Session(token: token, createdAt: now, expiresAt: now.addingTimeInterval(sessionDuration))

        sessionLock.lock()
        activeSessions[token] = session

        // Only cleanup expired sessions every 5 minutes (not every request)
        if now.timeIntervalSince(lastSessionCleanup) > 300 {
            lastSessionCleanup = now
            activeSessions = activeSessions.filter { $0.value.expiresAt > now }
        }

        // Persist sessions to disk
        saveSessions()
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
        saveSessions()
        sessionLock.unlock()
    }

    func start() throws {
        let listener = try ServerSocket(port: port)
        self.listener = listener

        print("🌐 HTTP API server started on port \(port)")

        // Start scheduled task lifecycle scanning (every hour)
        startScheduledTaskScanning()

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

    private func startScheduledTaskScanning() {
        // Run task lifecycle scan every hour
        Task {
            // Initial delay of 5 minutes after server start
            try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)

            while true {
                do {
                    print("⏰ Running scheduled task lifecycle scan...")
                    if let orchestrator = await MainActor.run(body: { alfredService.orchestrator }) {
                        let notionService = orchestrator.notionServicePublic
                        let result = try await TaskLifecycleTracker.shared.scan(notionService: notionService)
                        print("✓ Scheduled scan complete: \(result.tasksScanned) tasks, \(result.changesDetected) changes")
                    }
                } catch {
                    print("⚠️ Scheduled task scan failed: \(error)")
                }

                // Sleep for 1 hour
                try? await Task.sleep(nanoseconds: 60 * 60 * 1_000_000_000)
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
            if request.path == "/" || request.path == "/index.html" || request.path == "/home.html" {
                let response = handleNotionUI()
                try await client.send(response)
                return
            }

            // Serve any HTML file from web directory (prototypes, etc.)
            if request.path.hasSuffix(".html") && request.path != "/home.html" && request.path != "/index.html" {
                let filename = String(request.path.dropFirst()) // strip leading /
                if let html = HotReloadManager.shared.getWebFile(filename) {
                    let response = HTTPResponse(statusCode: 200, headers: ["Content-Type": "text/html; charset=utf-8"], htmlBody: html)
                    try await client.send(response)
                    return
                }
            }

            // Serve PWA manifest
            if request.path == "/manifest.json" {
                let response = handleManifestJSON()
                try await client.send(response)
                return
            }

            // Serve service worker (must be served from root scope for push notifications)
            if request.path == "/sw.js" {
                if let js = HotReloadManager.shared.getWebFile("sw.js") {
                    let response = HTTPResponse(
                        statusCode: 200,
                        headers: [
                            "Content-Type": "application/javascript",
                            "Service-Worker-Allowed": "/",
                            "Cache-Control": "no-cache"
                        ],
                        htmlBody: js
                    )
                    try await client.send(response)
                    return
                }
            }

            // Allow auth endpoints without authentication (they validate passcode internally)
            if request.path == "/api/auth/login" || request.path == "/api/auth/logout" || request.path == "/api/auth/validate" {
                let response = await routeAuth(request)
                try await client.send(response)
                return
            }

            // Allow health endpoint without authentication (version/status is not sensitive)
            if request.path == "/api/health" {
                let response = await route(request)
                try await client.send(response)
                return
            }

            // Allow Google OAuth flow without authentication (redirect from Google)
            if request.path == "/auth/google" || request.path == "/auth/callback" {
                let response = await handleGoogleOAuth(request)
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

            // Check if client wants streaming (SSE) response
            let wantsStreaming = request.headers["accept"]?.contains("text/event-stream") == true

            // Handle streaming endpoints specially
            if wantsStreaming {
                switch (request.method, request.path) {
                case ("GET", "/api/briefing/stream"):
                    await handleStreamingBriefing(request, client: client)
                    return
                case ("GET", "/api/calendar/stream"):
                    await handleStreamingCalendar(request, client: client)
                    return
                case ("GET", "/api/messages/stream"):
                    await handleStreamingMessages(request, client: client)
                    return
                case ("GET", "/api/messages/summary/stream"):
                    await handleStreamingMessagesSummary(request, client: client)
                    return
                case ("GET", "/api/attention-check/stream"):
                    await handleStreamingAttentionCheck(request, client: client)
                    return
                case ("GET", "/api/chat/stream"):
                    await handleChatStream(request, client: client)
                    return
                case ("GET", "/api/self-model/reflect"):
                    await handleReflectStream(request, client: client)
                    return
                case ("GET", "/api/coaching/cards/stream"):
                    await handleStreamingCoachingCards(request, client: client)
                    return
                default:
                    break
                }
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

        // Check session cookie (for sendBeacon, PWA, and other cookied requests)
        if let cookieHeader = request.headers["cookie"] {
            let cookies = cookieHeader.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            for cookie in cookies {
                let parts = cookie.split(separator: "=", maxSplits: 1)
                if parts.count == 2 && parts[0] == "alfred_session" {
                    let token = String(parts[1])
                    if validateSession(token: token) {
                        return true
                    }
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

        // Set session cookie (SameSite=Strict, HttpOnly for security, 30-day expiry)
        let maxAge = 30 * 24 * 60 * 60 // 30 days
        let cookieHeader = "alfred_session=\(session.token); Path=/; Max-Age=\(maxAge); SameSite=Strict; HttpOnly"

        return HTTPResponse(
            statusCode: 200,
            headers: ["Set-Cookie": cookieHeader],
            body: [
                "success": true,
                "token": session.token,
                "expiresAt": Self.iso8601Formatter.string(from: session.expiresAt)
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

        // Clear session cookie
        let clearCookie = "alfred_session=; Path=/; Max-Age=0; SameSite=Strict; HttpOnly"
        return HTTPResponse(statusCode: 200, headers: ["Set-Cookie": clearCookie], body: ["success": true])
    }

    // MARK: - Google OAuth Flow

    private func handleGoogleOAuth(_ request: HTTPRequest) async -> HTTPResponse {
        switch request.path {
        case "/auth/google":
            return handleGoogleAuthRedirect(request)
        case "/auth/callback":
            return await handleGoogleAuthCallback(request)
        default:
            return HTTPResponse(statusCode: 404, body: ["error": "Not found"])
        }
    }

    /// GET /auth/google — Redirects user to Google OAuth consent screen
    private func handleGoogleAuthRedirect(_ request: HTTPRequest) -> HTTPResponse {
        guard let config = AppConfig.load() else {
            return HTTPResponse(statusCode: 500, headers: ["Content-Type": "text/html; charset=utf-8"],
                htmlBody: "<html><body><h2>Error</h2><p>Configuration not loaded. Please complete the FTUE setup first.</p></body></html>")
        }

        guard let googleConfig = config.calendar.google.first,
              !googleConfig.clientId.isEmpty else {
            return HTTPResponse(statusCode: 400, headers: ["Content-Type": "text/html; charset=utf-8"],
                htmlBody: """
                <html><body style="font-family: system-ui; max-width: 500px; margin: 60px auto; text-align: center;">
                <h2>Google Not Configured</h2>
                <p>Please enter your Google client ID and secret in the setup wizard first.</p>
                <button onclick="window.close()">Close</button>
                </body></html>
                """)
        }

        let calService = GoogleCalendarService(config: googleConfig, accountName: "primary")
        let authURL = calService.getAuthorizationURL()

        // 302 redirect to Google
        return HTTPResponse(
            statusCode: 302,
            headers: [
                "Location": authURL.absoluteString,
                "Content-Type": "text/html; charset=utf-8"
            ],
            htmlBody: "<html><body>Redirecting to Google...</body></html>"
        )
    }

    /// GET /auth/callback?code=X — Handles Google OAuth callback, exchanges code for tokens
    private func handleGoogleAuthCallback(_ request: HTTPRequest) async -> HTTPResponse {
        guard let code = request.queryParams["code"], !code.isEmpty else {
            let error = request.queryParams["error"] ?? "No authorization code received"
            return HTTPResponse(statusCode: 400, headers: ["Content-Type": "text/html; charset=utf-8"],
                htmlBody: """
                <html><body style="font-family: system-ui; max-width: 500px; margin: 60px auto; text-align: center;">
                <h2>Authorization Failed</h2>
                <p>\(error)</p>
                <button onclick="window.close()">Close</button>
                </body></html>
                """)
        }

        guard let config = AppConfig.load(),
              let googleConfig = config.calendar.google.first else {
            return HTTPResponse(statusCode: 500, headers: ["Content-Type": "text/html; charset=utf-8"],
                htmlBody: "<html><body><h2>Error</h2><p>Configuration not loaded.</p></body></html>")
        }

        let calService = GoogleCalendarService(config: googleConfig, accountName: "primary")

        do {
            try await calService.exchangeCodeForToken(code: code)

            // Mark Google OAuth as complete in setup status
            SetupStatusService.shared.markStepComplete("googleOauth")

            return HTTPResponse(statusCode: 200, headers: ["Content-Type": "text/html; charset=utf-8"],
                htmlBody: """
                <html>
                <body style="font-family: system-ui; max-width: 500px; margin: 60px auto; text-align: center;">
                <h2 style="color: #16a34a;">✓ Google Calendar Connected</h2>
                <p>Authorization successful. You can close this window and return to the setup wizard.</p>
                <script>
                    // Signal the parent window that OAuth is complete
                    if (window.opener) {
                        window.opener.postMessage({ type: 'google-oauth-complete' }, '*');
                    }
                    setTimeout(() => window.close(), 3000);
                </script>
                </body>
                </html>
                """)
        } catch {
            return HTTPResponse(statusCode: 500, headers: ["Content-Type": "text/html; charset=utf-8"],
                htmlBody: """
                <html>
                <body style="font-family: system-ui; max-width: 500px; margin: 60px auto; text-align: center;">
                <h2 style="color: #dc2626;">Token Exchange Failed</h2>
                <p>\(error.localizedDescription)</p>
                <p>Please try again from the setup wizard.</p>
                <button onclick="window.close()">Close</button>
                </body>
                </html>
                """)
        }
    }

    private func handleValidateSession(_ request: HTTPRequest) -> HTTPResponse {
        // Check Authorization header
        guard let authHeader = request.headers["authorization"] else {
            return HTTPResponse(statusCode: 401, body: ["valid": false, "error": "No token provided"])
        }

        let parts = authHeader.split(separator: " ")
        guard parts.count == 2 && parts[0].lowercased() == "bearer" else {
            return HTTPResponse(statusCode: 401, body: ["valid": false, "error": "Invalid token format"])
        }

        let token = String(parts[1])

        if validateSession(token: token) {
            return HTTPResponse(statusCode: 200, body: ["valid": true])
        } else {
            return HTTPResponse(statusCode: 401, body: ["valid": false, "error": "Token expired or invalid"])
        }
    }

    private func route(_ request: HTTPRequest) async -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/api/health"):
            return handleHealth()

        case ("GET", "/api/health/detailed"):
            return await handleDetailedHealth()

        case ("GET", "/api/trust"):
            return handleTrustState()

        case ("GET", "/api/commitments"):
            return await handleGetCommitments(request)

        case ("GET", "/api/commitments/overdue"):
            return await handleGetOverdueCommitments()

        case ("POST", "/api/commitments/scan"):
            return await handleScanCommitments(request)

        // Home pulse (consolidated endpoint for v2 Home tab)
        case ("GET", "/api/home/pulse"):
            return await handleHomePulse()

        // Next meeting brief (LLM-generated meeting prep card)
        case ("GET", "/api/home/next-meeting-brief"):
            return await handleNextMeetingBrief()

        // Home config (meeting brief prompt)
        case ("GET", "/api/config/home"):
            return handleGetHomeConfig()
        case ("POST", "/api/config/home"):
            return handleUpdateHomeConfig(request)

        // Notification settings
        case ("GET", "/api/config/notifications"):
            return handleGetNotificationConfig()
        case ("POST", "/api/config/notifications"):
            return handleUpdateNotificationConfig(request)

        // Push notifications
        case ("POST", "/api/push/setup"):
            return handlePushSetup()
        case ("GET", "/api/push/vapid-public-key"):
            return handleGetVAPIDPublicKey()
        case ("POST", "/api/push/subscribe"):
            return handlePushSubscribe(request)
        case ("DELETE", "/api/push/subscribe"):
            return handlePushUnsubscribe(request)
        case ("GET", "/api/push/subscriptions"):
            return handleGetPushSubscriptions()
        case ("POST", "/api/push/test"):
            return await handlePushTest(request)
        case ("GET", "/api/push/budget"):
            return handleGetPushBudget()

        // Coaching cards (AI-generated insights)
        case ("GET", "/api/coaching/cards"):
            return await handleCoachingCards()

        case ("GET", "/api/coaching/context"):
            return handleCoachingContext()

        case ("GET", "/api/coaching/opener"):
            return await handleCoachingOpener()

        case ("GET", "/api/coaching/debug"):
            return await handleCoachingDebug(request)

        case ("GET", "/api/coaching/tenets"):
            return handleGetCoachingTenets()

        case ("PUT", "/api/coaching/tenets"):
            return handlePutCoachingTenets(request)

        case ("GET", "/api/coaching/tenets/sections"):
            return handleGetTenetSections()

        case ("POST", "/api/coaching/tenets/sections/toggle"):
            return handleToggleTenetSection(request)

        case ("POST", "/api/coaching/debug/refresh"):
            return await handleRefreshSingleSkill(request)

        case ("POST", "/api/coaching/feedback"):
            return handleCoachingFeedback(request)

        // Focus Pin (user's #1 goal)
        case ("POST", "/api/focus-pin"):
            return await handlePinFocus(request)

        case ("DELETE", "/api/focus-pin"):
            return handleUnpinFocus()

        case ("GET", "/api/focus-pin/suggestions"):
            return await handleFocusPinSuggestions(request)

        case ("GET", "/api/weekly-reflection"):
            return await handleWeeklyReflection()

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

        case ("POST", "/api/capture"):
            return await handlePostMeetingCapture(request)

        case ("GET", "/api/capture/pending"):
            return handleGetPendingCapture()

        case ("DELETE", "/api/capture/pending"):
            return handleClearPendingCapture()

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

        case ("GET", "/api/config/scheduled"):
            return handleGetScheduledConfig()

        case ("POST", "/api/config/scheduled"):
            return handleUpdateScheduledConfig(request)

        case ("GET", "/api/config/theme"):
            return handleGetTheme()

        case ("POST", "/api/config/theme"):
            return handleUpdateTheme(request)

        case ("POST", "/api/cache/clear"):
            return handleClearCache()

        // Favorites endpoints
        case ("GET", "/api/favorites"):
            return handleGetFavorites()

        case ("POST", "/api/favorites/contacts"):
            return handleAddFavoriteContact(request)

        case ("DELETE", "/api/favorites/contacts"):
            return handleRemoveFavoriteContact(request)

        case ("POST", "/api/favorites/groups"):
            return handleAddFavoriteGroup(request)

        case ("DELETE", "/api/favorites/groups"):
            return handleRemoveFavoriteGroup(request)

        // Playbook endpoints
        case ("GET", "/api/playbook/status"):
            return handleGetPlaybookStatus()

        case ("POST", "/api/playbook/sync"):
            return await handleSyncPlaybook()

        case ("POST", "/api/playbook/setup"):
            return await handleSetupPlaybook(request)

        // Coaching Context Notion sync endpoints
        case ("GET", "/api/coaching-context/status"):
            return handleGetCoachingContextStatus()

        case ("POST", "/api/coaching-context/sync"):
            return await handleSyncCoachingContext(request)

        case ("POST", "/api/coaching-context/setup"):
            return await handleSetupCoachingContext(request)

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

        case ("GET", "/api/agent-digest"):
            return await handleAgentDigest()

        // Interactive extraction endpoints (for GUI approval flow)
        case ("POST", "/api/extract/commitments"):
            return await handleExtractCommitments(request)

        case ("POST", "/api/extract/todos"):
            return await handleExtractTodos(request)

        case ("POST", "/api/extract/thread"):
            return await handleExtractFromThread(request)

        case ("POST", "/api/extract/approve"):
            return await handleApproveExtractedItems(request)

        // Correction tracking for learning
        case ("POST", "/api/corrections"):
            return handleRecordCorrection(request)

        case ("GET", "/api/corrections"):
            return handleGetCorrections(request)

        // Contact learning endpoints
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

        // Task lifecycle tracking
        case ("POST", "/api/task-lifecycle/scan"):
            return await handleTaskLifecycleScan()

        case ("GET", "/api/task-lifecycle/progress"):
            return handleTaskLifecycleScanProgress()

        case ("GET", "/api/task-lifecycle/stats"):
            return handleTaskLifecycleStats()

        case ("GET", "/api/task-lifecycle/changes"):
            return handleTaskLifecycleChanges(request)

        case ("GET", "/api/task-lifecycle/counterparties"):
            return handleTaskLifecycleCounterparties()

        // Simplified teach endpoint (single Alfred memory)
        case ("POST", "/api/teach"):
            return handleTeachAlfred(request)

        case ("GET", "/api/learnings"):
            return handleGetLearnings()

        case ("GET", "/api/memory/unified"):
            return handleGetUnifiedMemory()

        case ("GET", "/api/learning/status"):
            return handleGetLearningStatus()

        case ("POST", "/api/learning/compute"):
            return await handleComputeLearnedPatterns()

        case ("GET", "/api/learning/patterns"):
            return handleGetLearnedPatterns()

        case ("POST", "/api/learning/review"):
            return handlePatternReview(request)

        case ("GET", "/api/workflow-patterns"):
            return handleGetWorkflowPatterns()

        case ("POST", "/api/workflow-patterns/compute"):
            return handleComputeWorkflowPatterns()

        case ("GET", "/api/workflow-patterns/digest"):
            return handleGetLearningDigest()

        case ("POST", "/api/workflow-patterns/send-digest"):
            return await handleSendLearningDigest()

        case ("GET", "/api/memory/all"):
            return handleGetAllMemory()

        case ("DELETE", "/api/learning/patterns"):
            return handleDeleteLearnedPattern(request)

        case ("PUT", "/api/learning/patterns"):
            return handleUpdateLearnedPattern(request)

        case ("POST", "/api/memory/feedback"):
            return handleMemoryFeedback(request)

        case ("PATCH", "/api/memory/edit"):
            return handleEditMemory(request)

        case ("GET", "/api/memory/notion-status"):
            return handleGetMemoryNotionStatus()

        case ("POST", "/api/memory/notion-sync"):
            return await handleMemoryNotionSync()

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

        case ("POST", "/api/setup/open-system-preferences"):
            return await handleOpenSystemPreferences(request)

        case ("GET", "/api/setup/permissions"):
            return await handleGetPermissionStatus()

        case ("POST", "/api/setup/request-contacts"):
            return await handleRequestContactsPermission()

        // Commitment management endpoints
        case ("PATCH", "/api/tasks/status"):
            return await handleUpdateTaskStatus(request)

        case ("POST", "/api/nudge/generate"):
            return await handleGenerateNudge(request)

        case ("POST", "/api/commitments/detect-completions"):
            return await handleDetectCompletions(request)

        // Commitment Tracker endpoints
        case ("GET", "/api/commitment-tracker/stats"):
            return await handleGetCommitmentTrackerStats()

        case ("GET", "/api/commitment-tracker/pending-closures"):
            return handleGetPendingClosures()

        case ("POST", "/api/commitment-tracker/confirm-closure"):
            return await handleConfirmClosure(request)

        case ("POST", "/api/commitment-tracker/reject-closure"):
            return handleRejectClosure(request)

        case ("GET", "/api/commitment-tracker/recent-closures"):
            return handleGetRecentClosures()

        case ("POST", "/api/commitment-tracker/dedup-cleanup"):
            return await handleDedupCleanup()

        case ("POST", "/api/commitment-tracker/cleanup-orphans"):
            return handleCleanupOrphans()

        case ("POST", "/api/commitment-tracker/sync-from-notion"):
            return await handleSyncFromNotion()

        // MARK: Cadence CRUD Endpoints (new)
        case ("GET", "/api/cadences"):
            return handleGetCadences()

        case ("GET", "/api/cadences/catalog"):
            return handleGetToolCatalog()

        case ("POST", "/api/cadences"):
            return handleCreateCadence(request)

        case ("PUT", "/api/cadences"):
            return handleUpdateCadence(request)

        case ("DELETE", "/api/cadences"):
            return handleDeleteCadence(request)

        case ("POST", "/api/cadences/run"):
            return handleRunCadence(request)

        // MARK: Legacy Cadence Endpoints (backward compat)
        case ("GET", "/api/cadence/status"):
            return handleCadenceStatus()

        case ("GET", "/api/cadence/group-suggestions"):
            return handleGetGroupSuggestions()

        case ("POST", "/api/cadence/run-group-analysis"):
            return await handleRunGroupAnalysis()

        case ("POST", "/api/cadence/approve-auto-summary"):
            return handleApproveAutoSummary(request)

        case ("POST", "/api/cadence/config"):
            return handleUpdateCadenceConfig(request)

        // MARK: Custom Coaching Skills
        case ("GET", "/api/skills"):
            return handleGetSkills()

        case ("GET", "/api/skills/detail"):
            return handleGetSkillDetail(request)

        case ("POST", "/api/skills"):
            return handleCreateSkill(request)

        case ("PUT", "/api/skills"):
            return handleUpdateSkill(request)

        case ("DELETE", "/api/skills"):
            return handleDeleteSkill(request)

        case ("POST", "/api/skills/toggle"):
            return handleToggleSkill(request)

        case ("POST", "/api/skills/rename"):
            return handleRenameSkill(request)

        // MARK: Skill Library
        case ("GET", "/api/skills/library"):
            return handleGetSkillLibrary()

        case ("POST", "/api/skills/library/install"):
            return handleInstallLibrarySkill(request)

        // MARK: Tenet Pack Endpoints (v2)
        case ("GET", "/api/tenets"):
            return handleGetTenetPacks()

        case ("GET", "/api/tenets/detail"):
            return handleGetTenetPackDetail(request)

        case ("POST", "/api/tenets/toggle"):
            return handleToggleTenetPack(request)

        case ("POST", "/api/tenets"):
            return handleCreateTenetPack(request)

        case ("PUT", "/api/tenets"):
            return handleUpdateTenetPack(request)

        case ("DELETE", "/api/tenets"):
            return handleDeleteTenetPack(request)

        // MARK: Analysis Lens Endpoints (v2)
        case ("GET", "/api/analyses"):
            return handleGetAnalysisLenses()

        case ("GET", "/api/analyses/detail"):
            return handleGetAnalysisLensDetail(request)

        case ("POST", "/api/analyses/toggle"):
            return handleToggleAnalysisLens(request)

        case ("POST", "/api/analyses"):
            return handleCreateAnalysisLens(request)

        case ("PUT", "/api/analyses"):
            return handleUpdateAnalysisLens(request)

        case ("DELETE", "/api/analyses"):
            return handleDeleteAnalysisLens(request)

        // MARK: Signal Endpoints (v2)
        case ("GET", "/api/signals/today"):
            return handleGetTodaysSignals()

        case ("GET", "/api/signals/history"):
            return handleGetSignalHistory(request)

        case ("GET", "/api/signals/stats"):
            return handleGetSignalStats()

        // MARK: Past Conversations Endpoints
        case ("GET", "/api/conversations"):
            return handleGetConversations(request)

        case ("GET", "/api/conversations/detail"):
            return handleGetConversationDetail(request)

        case ("POST", "/api/conversations/close"):
            return await handleCloseConversation(request)

        case ("DELETE", "/api/conversations"):
            return handleDeleteConversation(request)

        case ("POST", "/api/conversations/restore"):
            return handleRestoreConversation(request)

        // Reflection Mode endpoints
        case ("POST", "/api/reflect/ingest"):
            return await handleReflectIngest(request)

        case ("GET", "/api/reflect/recent"):
            return handleReflectRecent(request)

        case ("GET", "/api/reflect/themes"):
            return handleReflectThemes(request)

        case ("GET", "/api/self-model"):
            return handleSelfModel(request)

        case ("POST", "/api/self-model/compute"):
            return handleSelfModelCompute(request)

        case ("POST", "/api/self-model/verdict"):
            return handleSelfModelVerdict(request)

        case ("POST", "/api/self-model/link"):
            return handleSelfModelLink(request)

        case ("POST", "/api/self-model/seed"):
            return handleSelfModelSeed(request)

        case ("POST", "/api/self-model/graduate"):
            return handleGraduate(request)

        case ("GET", "/api/self-model/proposals"):
            return handleGraduationProposals(request)

        case ("POST", "/api/self-model/proposals/resolve"):
            return handleResolveProposal(request)

        case ("POST", "/api/self-model/resolve"):
            return handleSelfModelResolve(request)

        case ("GET", "/api/self-model/now-card"):
            return handleSelfModelNowCard(request)

        case ("GET", "/api/self-model/browse"):
            return handleSelfModelBrowse(request)

        case ("GET", "/api/self-model/reflections"):
            return handleSelfModelReflections(request)

        case ("GET", "/api/reflection/thread-candidates"):
            return handleThreadCandidates(request)

        case ("GET", let p) where p.hasPrefix("/api/reflect/theme/detail"):
            return handleReflectThemeDetail(request)

        case ("POST", "/api/reflect/theme/advance"):
            return handleReflectThemeAdvance(request)
        case ("POST", "/api/reflect/themes/merge"):
            return handleReflectThemesMerge(request)
        case ("POST", "/api/reflect/item/move"):
            return handleReflectItemMove(request)
        case ("POST", "/api/reflect/item/restore"):
            return handleReflectItemRestore(request)
        case ("GET", "/api/reflect/tidy"):
            return handleReflectTidy()
        case ("POST", "/api/reflect/tidy/dismiss"):
            return handleReflectTidyDismiss(request)

        case ("GET", "/api/reflect/stats"):
            return handleReflectStats()

        case ("POST", "/api/reflect/pull"):
            return handleReflectPull(request)

        case ("POST", "/api/reflect/reset"):
            return handleReflectReset()

        default:
            return HTTPResponse(
                statusCode: 404,
                body: ["error": "Endpoint not found"]
            )
        }
    }

    // MARK: - API Handlers

    private func handleManifestJSON() -> HTTPResponse {
        if let json = HotReloadManager.shared.getWebFile("manifest.json") {
            return HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/manifest+json"],
                htmlBody: json
            )
        }
        return HTTPResponse(statusCode: 404, body: ["error": "Manifest not found"])
    }

    private func handleNotionUI() -> HTTPResponse {
        // Use HotReloadManager for hot-reloadable web files
        if let html = HotReloadManager.shared.getWebFile("home.html") {
            return HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "text/html; charset=utf-8"],
                htmlBody: html
            )
        }

        // Fallback: simple inline HTML
        let fallbackHTML = """
        <!DOCTYPE html>
        <html><head><meta charset="UTF-8"><title>Alfred</title></head>
        <body><h1>Alfred</h1><p>Web UI file not found. API is available at /api endpoints.</p></body></html>
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
                "version": AlfredApp.version,
                "timestamp": Self.iso8601Formatter.string(from: Date())
            ]
        )
    }

    private func handleDetailedHealth() async -> HTTPResponse {
        guard let config = alfredService.orchestrator?.config else {
            return HTTPResponse(statusCode: 503, body: [
                "status": "error",
                "error": "Service not initialized"
            ])
        }

        var services: [[String: Any]] = []
        var warnings: [String] = []
        var overallOk = true

        // 1. Claude API — check key is configured
        let claudeKeyOk = !config.ai.anthropicApiKey.isEmpty && config.ai.anthropicApiKey != "YOUR_API_KEY"
        services.append([
            "name": "Claude API",
            "status": claudeKeyOk ? "ok" : "error",
            "detail": claudeKeyOk ? "API key configured (model: \(config.ai.model))" : "API key missing or placeholder"
        ])
        if !claudeKeyOk { overallOk = false; warnings.append("Claude API key not configured") }

        // 2. Notion API — check key + database ID
        let notionKeyOk = !config.notion.apiKey.isEmpty && config.notion.apiKey != "YOUR_NOTION_API_KEY"
        let notionDbOk = !config.notion.databaseId.isEmpty
        let notionOk = notionKeyOk && notionDbOk
        services.append([
            "name": "Notion",
            "status": notionOk ? "ok" : "error",
            "detail": notionOk ? "API key and database configured" : (!notionKeyOk ? "API key missing" : "Database ID missing")
        ])
        if !notionOk { overallOk = false; warnings.append("Notion not fully configured") }

        // 3. Google Calendar — check token files exist for each account
        for account in config.calendar.google {
            let tokenFilename = "google_tokens_\(account.name).json"
            let possiblePaths = [
                (NSString(string: "~/.config/alfred/\(tokenFilename)").expandingTildeInPath),
                (NSString(string: "~/.config/exec-assistant/\(tokenFilename)").expandingTildeInPath)
            ]
            let tokenExists = possiblePaths.contains { FileManager.default.fileExists(atPath: $0) }
            services.append([
                "name": "Google Calendar (\(account.name))",
                "status": tokenExists ? "ok" : "warning",
                "detail": tokenExists ? "Token file found" : "Token file missing — calendar will fail until re-authed"
            ])
            if !tokenExists { warnings.append("Google Calendar token missing for '\(account.name)'") }
        }

        // 4. iMessage — check chat.db exists AND is readable (Full Disk Access)
        if config.messaging.imessage.enabled {
            let chatDbPath = config.messaging.imessage.expandedPath
            let chatDbExists = FileManager.default.fileExists(atPath: chatDbPath)
            var imsgStatus = "warning"
            var imsgDetail = "chat.db not found at \(chatDbPath)"
            if chatDbExists {
                // Actually try to open the database — this is the real FDA test
                var testDb: OpaquePointer?
                let rc = sqlite3_open_v2(chatDbPath, &testDb, SQLITE_OPEN_READONLY, nil)
                if rc == SQLITE_OK {
                    // Try a trivial query to confirm read access
                    var stmt: OpaquePointer?
                    let queryRc = sqlite3_prepare_v2(testDb, "SELECT COUNT(*) FROM message LIMIT 1", -1, &stmt, nil)
                    if queryRc == SQLITE_OK {
                        imsgStatus = "ok"
                        imsgDetail = "chat.db readable (Full Disk Access verified)"
                    } else {
                        imsgStatus = "error"
                        imsgDetail = "chat.db found but query failed (error \(queryRc)) — Full Disk Access may be revoked"
                        warnings.append("iMessage: Full Disk Access appears revoked — re-grant to /Applications/Alfred.app in System Settings → Privacy & Security")
                    }
                    sqlite3_finalize(stmt)
                    sqlite3_close(testDb)
                } else {
                    imsgStatus = "error"
                    imsgDetail = "chat.db found but can't open (error \(rc)) — Full Disk Access revoked"
                    warnings.append("iMessage: Full Disk Access revoked — re-grant to /Applications/Alfred.app in System Settings → Privacy & Security")
                    sqlite3_close(testDb)
                }
            } else {
                warnings.append("iMessage chat.db not found")
            }
            services.append([
                "name": "iMessage",
                "status": imsgStatus,
                "detail": imsgDetail
            ])
        }

        // 5. WhatsApp — check DB file exists
        if config.messaging.whatsapp.enabled {
            let waDbPath = config.messaging.whatsapp.expandedPath
            let waDbExists = FileManager.default.fileExists(atPath: waDbPath)
            services.append([
                "name": "WhatsApp",
                "status": waDbExists ? "ok" : "warning",
                "detail": waDbExists ? "Database found" : "Database not found at \(waDbPath)"
            ])
            if !waDbExists { warnings.append("WhatsApp database not found") }
        }

        // 6. Email (SMTP) — check config has non-empty host/port/username
        let emailConfig = config.notifications.email
        let smtpOk = emailConfig.enabled && !emailConfig.smtpHost.isEmpty && emailConfig.smtpPort > 0 && !emailConfig.smtpUsername.isEmpty
        services.append([
            "name": "Email (SMTP)",
            "status": emailConfig.enabled ? (smtpOk ? "ok" : "warning") : "disabled",
            "detail": !emailConfig.enabled ? "Email notifications disabled" : (smtpOk ? "SMTP configured (\(emailConfig.smtpHost):\(emailConfig.smtpPort))" : "SMTP config incomplete")
        ])
        if emailConfig.enabled && !smtpOk { warnings.append("SMTP configuration incomplete") }

        // 7. Commitment DB — check file exists
        let commitmentDbPath = (NSString(string: "~/.alfred/commitment_scan.db").expandingTildeInPath)
        let commitmentDbExists = FileManager.default.fileExists(atPath: commitmentDbPath)
        services.append([
            "name": "Commitment DB",
            "status": commitmentDbExists ? "ok" : "warning",
            "detail": commitmentDbExists ? "Database exists" : "Database not initialized — run commitment scan to create"
        ])
        if !commitmentDbExists { warnings.append("Commitment database not initialized") }

        // 8. Workflow Learning DB
        let workflowDbPath = (NSString(string: "~/.alfred/workflow_learning.db").expandingTildeInPath)
        let workflowDbExists = FileManager.default.fileExists(atPath: workflowDbPath)
        services.append([
            "name": "Workflow Learning DB",
            "status": workflowDbExists ? "ok" : "warning",
            "detail": workflowDbExists ? "Database exists" : "Database not initialized — will be created on first learning cycle"
        ])
        if !workflowDbExists { warnings.append("Workflow learning database not initialized") }

        let result: [String: Any] = [
            "status": overallOk ? "ok" : "degraded",
            "version": AlfredApp.version,
            "timestamp": Self.iso8601Formatter.string(from: Date()),
            "services": services,
            "warnings": warnings
        ]

        return HTTPResponse(statusCode: 200, body: result)
    }

    private func handleGetCommitments(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            let typeFilter = request.queryParams["type"]
            var commitments: [Commitment]

            if let typeString = typeFilter, let type = parseCommitmentType(typeString) {
                commitments = try await alfredService.fetchCommitments(type: type)
            } else {
                commitments = try await alfredService.fetchCommitments()
            }

            // Sort commitments by urgency:
            // 1. Overdue items first (most overdue at top)
            // 2. Due soon (within 2 days) next
            // 3. Higher priority before lower
            // 4. Sooner due date before later
            commitments.sort { a, b in
                // Overdue items first
                if a.isOverdue != b.isOverdue {
                    return a.isOverdue
                }

                // If both overdue, most overdue first
                if a.isOverdue && b.isOverdue {
                    let aDays = a.daysUntilDue ?? 0
                    let bDays = b.daysUntilDue ?? 0
                    return aDays < bDays  // More negative = more overdue
                }

                // Due soon items next (within 2 days)
                let aDueSoon = (a.daysUntilDue ?? 999) <= 2
                let bDueSoon = (b.daysUntilDue ?? 999) <= 2
                if aDueSoon != bDueSoon {
                    return aDueSoon
                }

                // Higher priority first (critical < high < medium < low in raw value)
                if a.priority != b.priority {
                    return a.priority.rawValue < b.priority.rawValue
                }

                // Sooner due date first
                let aDays = a.daysUntilDue ?? 999
                let bDays = b.daysUntilDue ?? 999
                return aDays < bDays
            }

            let response: [[String: Any]] = commitments.map { commitment in
                // Calculate urgency zone for frontend
                let urgencyZone: String
                if commitment.isOverdue {
                    urgencyZone = "overdue"
                } else if (commitment.daysUntilDue ?? 999) <= 2 {
                    urgencyZone = "due_soon"
                } else if (commitment.daysUntilDue ?? 999) <= 7 {
                    urgencyZone = "this_week"
                } else {
                    urgencyZone = "later"
                }

                var result: [String: Any] = [
                    "id": commitment.id.uuidString,
                    "type": commitment.type.rawValue,
                    "status": commitment.status.rawValue,
                    "title": commitment.title,
                    "commitmentText": commitment.commitmentText,
                    "committedBy": commitment.committedBy,
                    "committedTo": commitment.committedTo,
                    "sourcePlatform": commitment.sourcePlatform.rawValue,
                    "sourceThread": commitment.sourceThread,
                    "priority": commitment.priority.rawValue,
                    "isOverdue": commitment.isOverdue,
                    "urgencyZone": urgencyZone,
                    "originalContext": commitment.originalContext
                ]

                // Explicitly set optional fields with NSNull for nil values
                if let dueDate = commitment.dueDate {
                    result["dueDate"] = Self.iso8601Formatter.string(from: dueDate)
                } else {
                    result["dueDate"] = NSNull()
                }

                if let daysUntilDue = commitment.daysUntilDue {
                    result["daysUntilDue"] = daysUntilDue
                } else {
                    result["daysUntilDue"] = NSNull()
                }

                if let notionId = commitment.notionId {
                    result["notionId"] = notionId
                } else {
                    result["notionId"] = NSNull()
                }

                return result
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
                    "dueDate": commitment.dueDate.map { Self.iso8601Formatter.string(from: $0) } as Any,
                    "priority": commitment.priority.rawValue,
                    "daysOverdue": commitment.daysUntilDue.map { -$0 } as Any,
                    "notionId": commitment.notionId as Any,
                    "isOverdue": commitment.isOverdue,
                    "originalContext": commitment.originalContext
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
            // Parse body (optional — use defaults if no body provided)
            var json: [String: Any] = [:]
            if let body = request.body,
               let parsed = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                json = parsed
            }

            let contactName = json["contactName"] as? String
            let lookbackDays = json["lookbackDays"] as? Int ?? 14
            let scanMode = json["scanMode"] as? String ?? "favorites"

            let result = try await alfredService.scanCommitments(
                contactName: contactName,
                lookbackDays: lookbackDays,
                scanMode: scanMode
            )

            // Invalidate affected caches
            invalidateMemoryCache("tracker_stats")
            invalidateMemoryCache("home_pulse")
            cache.deleteByEndpoint("/api/home/pulse")

            // Update scheduler state: date key for scheduler, timestamp key for UI
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            let now = Date()
            updateSchedulerState([
                "lastCommitmentScanDate": fmt.string(from: now),
                "lastCommitmentScanTimestamp": ISO8601DateFormatter().string(from: now)
            ])

            return HTTPResponse(
                statusCode: 200,
                body: [
                    "found": result.totalFound,
                    "saved": result.saved,
                    "duplicates": result.duplicates,
                    "autoClosed": result.autoClosed,
                    "pendingClosures": result.pendingClosures
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
        // Parse date parameter (default to today)
        let date = parseDate(from: request.queryParams["date"])
        let dateString = Self.simpleDateFormatter.string(from: date)
        let cacheParams = ["date": dateString]

        // Check cache first (4 hour TTL for briefings - they're expensive to generate)
        if let cached = cache.getCached(endpoint: "/api/briefing", params: cacheParams) {
            if let data = cached.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                print("⚡ Returning cached briefing for \(dateString)")
                return HTTPResponse(statusCode: 200, body: json)
            }
        }

        do {
            // Generate full daily briefing
            let briefing = try await alfredService.generateDailyBriefing(for: date)

            // Format as text response
            let formattedResponse = formatBriefingForAPI(briefing)

            let responseBody: [String: Any] = [
                "response": formattedResponse,
                "date": Self.iso8601Formatter.string(from: briefing.date),
                "generatedAt": Self.iso8601Formatter.string(from: briefing.generatedAt),
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
                        "dueDate": item.dueDate.map { Self.iso8601Formatter.string(from: $0) } as Any,
                        "category": item.category.rawValue
                    ]
                },
                "calendar": [
                    "events": briefing.calendarBriefing.schedule.events.map { event in
                        [
                            "id": event.id,
                            "title": event.title,
                            "start": Self.iso8601Formatter.string(from: event.startTime),
                            "end": Self.iso8601Formatter.string(from: event.endTime),
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

            // Cache for 4 hours (briefings are expensive but should be reasonably fresh)
            if let jsonData = try? JSONSerialization.data(withJSONObject: responseBody),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                cache.cache(endpoint: "/api/briefing", params: cacheParams, response: jsonString, ttl: 14400)
            }

            return HTTPResponse(statusCode: 200, body: responseBody)
        } catch {
            return HTTPResponse(
                statusCode: 500,
                body: ["error": error.localizedDescription]
            )
        }
    }

    // MARK: - Home Pulse (consolidated endpoint for v2)

    /// Track whether a background pulse refresh is already running
    private static var _pulseRefreshInFlight = false

    private func handleHomePulse() async -> HTTPResponse {
        // Check memory cache (2min TTL) — fastest path
        if let cached: [String: Any] = getFromMemoryCache("home_pulse") {
            return HTTPResponse(statusCode: 200, body: cached)
        }

        // Check disk cache (10min TTL — survives restarts)
        if let diskCached = cache.getCached(endpoint: "/api/home/pulse") {
            if let data = diskCached.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                setInMemoryCache("home_pulse", value: json, ttl: 120)
                return HTTPResponse(statusCode: 200, body: json)
            }
        }

        // Stale-while-revalidate: check for ANY cached version (even expired)
        // Return it instantly so the user sees data, then refresh in background
        if let staleCached = cache.getCachedEvenIfExpired(endpoint: "/api/home/pulse") {
            if let data = staleCached.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // Cache stale data in memory briefly so rapid successive calls don't miss
                setInMemoryCache("home_pulse", value: json, ttl: 30)
                // Kick off background refresh (only if one isn't already running)
                if !Self._pulseRefreshInFlight {
                    Self._pulseRefreshInFlight = true
                    Task { [weak self] in
                        defer { Self._pulseRefreshInFlight = false }
                        _ = await self?.refreshPulseData()
                    }
                }
                // Return stale data immediately — user sees content in <20ms
                var staleJson = json
                staleJson["_stale"] = true
                return HTTPResponse(statusCode: 200, body: staleJson)
            }
        }

        var topGoal: [String: Any]? = nil
        var openTasks = 0
        var overdueCount = 0
        var meetingsToday = 0
        var reliabilityScore = 0
        var pendingActions: [[String: Any]] = []

        // Run all 4 independent API calls in parallel
        let trackerStats = CommitmentScanTracker.shared.getStats()

        if let orchestrator = alfredService.orchestrator {
            async let topGoalTask = fetchTopGoalForPulse(orchestrator)
            async let statsTask = orchestrator.notionServicePublic.getCommitmentStatsFromNotion()
            async let overdueTask = alfredService.fetchOverdueCommitments()
            // Fetch raw calendar events (no LLM briefings) — just need the count
            async let calendarTask: DailySchedule? = {
                if let config = AppConfig.load() {
                    return try? await orchestrator.calendarServicePublic.fetchEventsFromAllCalendars(for: Date(), userSettings: config.user)
                }
                return nil
            }()

            // Await all results (gracefully handle failures)
            topGoal = await topGoalTask

            if let notionStats = try? await statsTask {
                openTasks = notionStats.open
            } else {
                openTasks = trackerStats.openCommitments
            }

            if let overdue = try? await overdueTask {
                overdueCount = overdue.count
                pendingActions = overdue.prefix(3).map { commitment in
                    var action: [String: Any] = [
                        "title": commitment.title,
                        "subtitle": "With \(commitment.committedTo)"
                    ]
                    if let id = commitment.notionId {
                        action["id"] = id
                    }
                    if let dueDate = commitment.dueDate {
                        let daysOverdue = Calendar.current.dateComponents([.day], from: dueDate, to: Date()).day ?? 0
                        if daysOverdue > 0 {
                            action["subtitle"] = "Due \(daysOverdue) day\(daysOverdue == 1 ? "" : "s") ago"
                        }
                    }
                    return action
                }
            }

            if let schedule = await calendarTask {
                meetingsToday = schedule.events.count
            }
        } else {
            openTasks = trackerStats.openCommitments

            // No orchestrator — still fetch overdue
            if let overdue = try? await alfredService.fetchOverdueCommitments() {
                overdueCount = overdue.count
                pendingActions = overdue.prefix(3).map { commitment in
                    var action: [String: Any] = [
                        "title": commitment.title,
                        "subtitle": "With \(commitment.committedTo)"
                    ]
                    if let id = commitment.notionId {
                        action["id"] = id
                    }
                    if let dueDate = commitment.dueDate {
                        let daysOverdue = Calendar.current.dateComponents([.day], from: dueDate, to: Date()).day ?? 0
                        if daysOverdue > 0 {
                            action["subtitle"] = "Due \(daysOverdue) day\(daysOverdue == 1 ? "" : "s") ago"
                        }
                    }
                    return action
                }
            }
            // Calendar count not available without orchestrator
            meetingsToday = 0
        }

        // 5. Reliability score
        let lifecycleStats = TaskLifecycleTracker.shared.getStats()
        reliabilityScore = Int(lifecycleStats.completionRate * 100)

        var responseBody: [String: Any] = [
            "metrics": [
                "openTasks": openTasks,
                "overdueCount": overdueCount,
                "meetingsToday": meetingsToday,
                "reliabilityScore": reliabilityScore
            ],
            "pendingActions": pendingActions
        ]

        if let goal = topGoal {
            responseBody["topGoal"] = goal
        }

        // Cache in memory (2min) and disk (10min)
        setInMemoryCache("home_pulse", value: responseBody, ttl: 120)
        if let jsonData = try? JSONSerialization.data(withJSONObject: responseBody),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            cache.cache(endpoint: "/api/home/pulse", response: jsonString, ttl: 600)
        }

        return HTTPResponse(statusCode: 200, body: responseBody)
    }

    /// Background refresh: fetch fresh pulse data and update caches
    /// Called by stale-while-revalidate to update caches silently
    /// Clears all caches first, then does a full fetch. Stale data remains
    /// in memory cache (30s TTL) so concurrent user requests stay fast.
    private func refreshPulseData() async -> HTTPResponse {
        print("♻️ [Pulse] Background refresh started")
        // Clear both caches — stale data is held in memory (30s) for concurrent requests
        invalidateMemoryCache("home_pulse")
        cache.deleteByEndpoint("/api/home/pulse")
        // handleHomePulse will now miss memory + disk + stale → do a full fresh fetch
        let result = await handleHomePulse()
        print("♻️ [Pulse] Background refresh complete")
        return result
    }

    /// Helper: fetch the top goal (pinned or algorithmic) for home pulse
    private func fetchTopGoalForPulse(_ orchestrator: BriefingOrchestrator) async -> [String: Any]? {
        let stateInfo = loadSchedulerStateRaw()
        // Check if user has pinned a focus goal
        if let pinnedId = stateInfo["pinnedGoalNotionId"] as? String, !pinnedId.isEmpty {
            do {
                if let task = try await orchestrator.notionServicePublic.fetchTaskById(notionId: pinnedId) {
                    // Auto-clear if task is done or cancelled
                    if task.status == TaskItem.TaskStatus.done || task.status == TaskItem.TaskStatus.cancelled {
                        updateSchedulerState(["pinnedGoalNotionId": "", "pinnedGoalAt": ""])
                        // Fall through to algorithmic top-priority
                    } else {
                        var goalDict: [String: Any] = [
                            "title": task.title,
                            "priority": task.priority?.rawValue ?? "None",
                            "pinned": true
                        ]
                        if !task.notionId.isEmpty {
                            goalDict["notionId"] = task.notionId
                        }
                        if let dueDate = task.dueDate {
                            goalDict["dueDate"] = Self.simpleDateFormatter.string(from: dueDate)
                        }
                        return goalDict
                    }
                } else {
                    // Pinned task no longer exists — clear pin
                    updateSchedulerState(["pinnedGoalNotionId": "", "pinnedGoalAt": ""])
                }
            } catch {
                print("⚠️ Home pulse: failed to fetch pinned task: \(error)")
            }
        }

        // Fall back to algorithmic top-priority if no pin (or pin was cleared)
        do {
            if let task = try await orchestrator.notionServicePublic.getTopPriorityTask() {
                var goalDict: [String: Any] = [
                    "title": task.title,
                    "priority": task.priority?.rawValue ?? "None",
                    "pinned": false
                ]
                if !task.notionId.isEmpty {
                    goalDict["notionId"] = task.notionId
                }
                if let dueDate = task.dueDate {
                    goalDict["dueDate"] = Self.simpleDateFormatter.string(from: dueDate)
                }
                return goalDict
            }
        } catch {
            print("⚠️ Home pulse: failed to get top priority task: \(error)")
        }
        return nil
    }

    // MARK: - Next Meeting Brief

    private static let defaultMeetingBriefPrompt = """
    Prepare me for this meeting. For each attendee:
    - What are the open commitments between us?
    - Summarize recent message threads (last 7 days) — focus on unresolved items, not pleasantries
    - Any patterns I should be aware of (delayed responses, escalating tone, repeated asks)

    Then give me:
    - 2-3 specific talking points (not generic — grounded in the data above)
    - One thing I should NOT forget to raise

    Keep it concise — bullet points, not paragraphs. Be direct.
    """

    private func handleNextMeetingBrief() async -> HTTPResponse {
        // Step 1: Fetch raw calendar events (fast — Google API only, no LLM briefing generation)
        guard let config = AppConfig.load(),
              let orchestrator = alfredService.orchestrator else {
            return HTTPResponse(statusCode: 200, body: ["noMeeting": true] as [String: Any])
        }

        let now = Date()
        let cutoff = now.addingTimeInterval(-15 * 60) // Include meetings started within 15 min

        guard let schedule = try? await orchestrator.calendarServicePublic.fetchEventsFromAllCalendars(
            for: now, userSettings: config.user
        ) else {
            return HTTPResponse(statusCode: 200, body: ["noMeeting": true] as [String: Any])
        }

        let nextEvent = schedule.events
            .filter { !$0.isAllDay }
            .filter { $0.startTime > cutoff && $0.endTime > now }
            .sorted { $0.startTime < $1.startTime }
            .first

        guard let event = nextEvent else {
            return HTTPResponse(statusCode: 200, body: ["noMeeting": true] as [String: Any])
        }

        // Step 2: Check per-event cache FIRST (before any expensive work)
        let cacheKey = "meeting_brief_\(event.id)"
        if let cached: [String: Any] = getFromMemoryCache(cacheKey) {
            return HTTPResponse(statusCode: 200, body: cached)
        }

        // Step 3: Compile user's meeting brief prompt into a data plan, then resolve
        // Classify each attendee as internal/external based on email domain (excluding the user themselves)
        let userEmailLower = config.user.email.lowercased()
        let otherAttendees = event.attendees.filter { $0.email.lowercased() != userEmailLower }

        // Use explicit internal/external classification from config — do NOT let the LLM guess
        func nameFor(_ a: Attendee) -> String {
            return a.name ?? a.email.components(separatedBy: "@").first ?? a.email
        }
        let internalAttendees = otherAttendees.filter { config.user.isInternal(email: $0.email) }
        let externalAttendees = otherAttendees.filter { !config.user.isInternal(email: $0.email) }
        let internalNames = internalAttendees.map { nameFor($0) }
        let externalNames = externalAttendees.map { nameFor($0) }

        // Build an explicit classified list for the LLM — domain of external attendees is the signal
        var classifiedAttendeeLines: [String] = []
        for a in otherAttendees.prefix(12) {
            let name = nameFor(a)
            let domain = a.email.components(separatedBy: "@").last ?? ""
            let label = config.user.isInternal(email: a.email) ? "internal" : "external"
            classifiedAttendeeLines.append("- \(name) @\(domain) [\(label)]")
        }
        let classifiedAttendeesStr = classifiedAttendeeLines.isEmpty ? "(none)" : classifiedAttendeeLines.joined(separator: "\n")

        // attendeeNames is used by the data plan resolver for message/commitment lookups — prioritize external attendees
        let prioritizedForLookup = externalAttendees + internalAttendees
        let attendeeNames = prioritizedForLookup.prefix(6).compactMap { $0.name ?? $0.email.components(separatedBy: "@").first }

        let userPrompt = config.home?.meetingBriefPrompt ?? Self.defaultMeetingBriefPrompt

        // Compile the user's prompt into a data plan (cached — only recompiles if prompt changes)
        let dataPlan = PromptCompiler.shared.compile(prompt: userPrompt)
        print("📋 [MeetingBrief] Data plan: \(dataPlan.capabilities.count) capabilities → \(dataPlan.capabilities.map { $0.capabilityId }.joined(separator: ", "))")

        // Resolve the data plan with runtime context (parallel data fetching)
        let runtimeContext = DataPlanResolver.RuntimeContext(
            attendeeNames: attendeeNames,
            meetingTitle: event.title,
            meetingDescription: event.description,
            date: now,
            orchestrator: orchestrator,
            config: config
        )
        let resolvedContext = await DataPlanResolver.shared.resolve(plan: dataPlan, context: runtimeContext)

        // Step 4: Build the LLM prompt with resolved data
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "h:mm a"
        let startStr = timeFmt.string(from: event.startTime)
        let endStr = timeFmt.string(from: event.endTime)

        let minutesUntil = Int(event.startTime.timeIntervalSince(now) / 60)
        let countdown: String
        if minutesUntil <= 0 {
            countdown = "starting now"
        } else if minutesUntil < 60 {
            countdown = "in \(minutesUntil) min"
        } else {
            let hours = minutesUntil / 60
            let mins = minutesUntil % 60
            countdown = mins > 0 ? "in \(hours)h \(mins)m" : "in \(hours)h"
        }

        let attendeeListStr = attendeeNames.isEmpty ? "Solo event" : attendeeNames.joined(separator: ", ")
        let locationStr = event.location ?? "No location"

        // Build a definitive internal/external summary — this is ground truth, not a guess
        let totalAttendeeCount = event.attendees.count
        let internalCount = internalAttendees.count + (event.attendees.contains { $0.email.lowercased() == userEmailLower } ? 1 : 0)
        let externalCount = externalAttendees.count
        let classificationSummary: String
        if externalCount == 0 {
            classificationSummary = "This is an INTERNAL meeting — all \(totalAttendeeCount) attendees are from \(config.user.companyDomain)."
        } else if internalCount == 0 {
            classificationSummary = "This is fully EXTERNAL — no internal \(config.user.companyDomain) attendees."
        } else {
            let extNames = externalNames.prefix(4).joined(separator: ", ")
            classificationSummary = "This is a MIXED meeting: \(internalCount) internal (\(config.user.companyDomain)) + \(externalCount) external attendees. External: \(extNames)\(externalNames.count > 4 ? ", …" : "")."
        }

        let systemPrompt = """
        You are Coach Alfred, a concise executive assistant. The user has an upcoming meeting and wants a briefing.

        MEETING: \(event.title)
        TIME: \(startStr) - \(endStr) (\(countdown))
        LOCATION: \(locationStr)
        MEETING DESCRIPTION: \(event.description ?? "None")

        ATTENDEE CLASSIFICATION (ground truth — do NOT guess internal vs external from names):
        \(classificationSummary)

        FULL ATTENDEE LIST with domains and classification:
        \(classifiedAttendeesStr)

        RESOLVED DATA (gathered from Alfred's data sources based on the user's briefing configuration):
        \(resolvedContext)

        CRITICAL:
        - When the brief mentions internal vs external, use the classification above as absolute ground truth. Never infer it from names.
        - If external attendees are present, name them explicitly and flag their organizations (derived from their email domain).

        Respond to the user's briefing request below. Be concise, use bullet points. No emojis. Use markdown formatting (bold for names, bullet lists). Reference the resolved data above — do NOT say you cannot access any data source.
        """

        // Step 5: Call LLM for THIS ONE meeting only
        var briefText: String? = nil
        do {
            let claudeService = ClaudeAIService(config: config.ai)
            briefText = try await claudeService.generateText(
                prompt: userPrompt,
                system: systemPrompt,
                maxTokens: 800,
                useModel: config.ai.effectiveCoachingModel
            )
        } catch {
            print("⚠️ Meeting brief LLM call failed: \(error)")
        }

        // Step 6: Build response
        let responseBody: [String: Any] = [
            "meeting": [
                "id": event.id,
                "title": event.title,
                "startTime": Self.iso8601Formatter.string(from: event.startTime),
                "endTime": Self.iso8601Formatter.string(from: event.endTime),
                "countdown": countdown,
                "countdownMinutes": minutesUntil,
                "attendeeCount": event.attendees.count,
                "location": event.location as Any,
                "meetingLink": event.meetingLink as Any
            ],
            "brief": briefText as Any,
            "generatedAt": Self.iso8601Formatter.string(from: Date())
        ]

        // Cache until meeting ends (min 5 min, max 30 min)
        let ttlSeconds = max(300, min(1800, event.endTime.timeIntervalSince(Date())))
        setInMemoryCache(cacheKey, value: responseBody, ttl: ttlSeconds)

        return HTTPResponse(statusCode: 200, body: responseBody)
    }

    // MARK: - Home Config

    private func handleGetHomeConfig() -> HTTPResponse {
        let configPath = NSString(string: "~/.config/alfred/config.json").expandingTildeInPath

        guard FileManager.default.fileExists(atPath: configPath) else {
            return HTTPResponse(statusCode: 200, body: ["meeting_brief_prompt": ""] as [String: Any])
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
            let config = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let home = config?["home"] as? [String: Any]

            return HTTPResponse(statusCode: 200, body: [
                "meeting_brief_prompt": home?["meeting_brief_prompt"] as? String ?? ""
            ] as [String: Any])
        } catch {
            return HTTPResponse(statusCode: 500, body: ["error": "Failed to read config: \(error.localizedDescription)"])
        }
    }

    private func handleUpdateHomeConfig(_ request: HTTPRequest) -> HTTPResponse {
        guard let bodyData = request.body,
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            return HTTPResponse(statusCode: 400, body: ["error": "Invalid request body"])
        }

        let configPath = NSString(string: "~/.config/alfred/config.json").expandingTildeInPath

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
            var config = try JSONSerialization.jsonObject(with: data) as! [String: Any]

            var home = config["home"] as? [String: Any] ?? [:]
            if let prompt = json["meeting_brief_prompt"] as? String {
                home["meeting_brief_prompt"] = prompt
            }
            config["home"] = home

            let updatedData = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            try updatedData.write(to: URL(fileURLWithPath: configPath))

            // Note: meeting brief cache is keyed by event ID and has 7min TTL,
            // so the next request after config change will naturally re-generate

            return HTTPResponse(statusCode: 200, body: ["success": true] as [String: Any])
        } catch {
            return HTTPResponse(statusCode: 500, body: ["error": "Failed to update config: \(error.localizedDescription)"])
        }
    }

    // MARK: - Push Notifications

    // MARK: - Notification Config

    private func handleGetNotificationConfig() -> HTTPResponse {
        guard let config = AppConfig.load() else {
            return HTTPResponse(statusCode: 500, body: ["error": "Failed to load config"])
        }
        let push = config.notifications.push
        let budget = PushBudgetService.shared.getStats()
        let subs = WebPushService.shared.getSubscriptions()

        return HTTPResponse(statusCode: 200, body: [
            "enabled": push.enabled,
            "briefingTime": config.app.briefingTime ?? "08:15",
            "morningNudgeEnabled": push.morningNudgeEnabled ?? true,
            "postMeetingCaptureEnabled": push.postMeetingCaptureEnabled ?? true,
            "maxPerDay": push.maxPerDay ?? 5,
            "quietHoursStart": push.quietHoursStart ?? 22,
            "quietHoursEnd": push.quietHoursEnd ?? 7,
            "budget": budget,
            "subscriberCount": subs.count,
            "subscriptions": subs.map { sub -> [String: Any] in
                [
                    "endpoint": String(sub.endpoint.prefix(60)) + "...",
                    "subscribedAt": ISO8601DateFormatter().string(from: sub.subscribedAt),
                    "lastPushAt": sub.lastPushAt.map { ISO8601DateFormatter().string(from: $0) } as Any
                ]
            }
        ] as [String: Any])
    }

    private func handleUpdateNotificationConfig(_ request: HTTPRequest) -> HTTPResponse {
        guard let bodyData = request.body,
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            return HTTPResponse(statusCode: 400, body: ["error": "Invalid JSON body"])
        }

        let configPath = NSString(string: "~/.config/alfred/config.json").expandingTildeInPath
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
            var config = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            var notifications = config["notifications"] as? [String: Any] ?? [:]
            var push = notifications["push"] as? [String: Any] ?? [:]
            var app = config["app"] as? [String: Any] ?? [:]

            // Update push settings
            if let maxPerDay = json["maxPerDay"] as? Int {
                push["max_per_day"] = max(1, min(20, maxPerDay))
            }
            if let quietStart = json["quietHoursStart"] as? Int {
                push["quiet_hours_start"] = max(0, min(23, quietStart))
            }
            if let quietEnd = json["quietHoursEnd"] as? Int {
                push["quiet_hours_end"] = max(0, min(23, quietEnd))
            }
            if let morningNudge = json["morningNudgeEnabled"] as? Bool {
                push["morning_nudge_enabled"] = morningNudge
            }
            if let postMeeting = json["postMeetingCaptureEnabled"] as? Bool {
                push["post_meeting_capture_enabled"] = postMeeting
            }

            // Update briefing time (in app settings, not push)
            if let briefingTime = json["briefingTime"] as? String {
                // Validate HH:MM format
                let parts = briefingTime.split(separator: ":").compactMap { Int($0) }
                if parts.count == 2 && parts[0] >= 0 && parts[0] <= 23 && parts[1] >= 0 && parts[1] <= 59 {
                    app["briefing_time"] = briefingTime
                }
            }

            notifications["push"] = push
            config["notifications"] = notifications
            config["app"] = app

            let updatedData = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            try updatedData.write(to: URL(fileURLWithPath: configPath))

            // Reload budget service with new settings
            if let newConfig = AppConfig.load() {
                PushBudgetService.shared.configure(from: newConfig.notifications.push)
            }

            print("⚙️ [Config] Notification settings updated")
            return HTTPResponse(statusCode: 200, body: ["success": true])
        } catch {
            return HTTPResponse(statusCode: 500, body: ["error": "Failed to save: \(error.localizedDescription)"])
        }
    }

    private func handlePushSetup() -> HTTPResponse {
        // Generate VAPID keys and store in config
        let keys = WebPushService.generateVAPIDKeys()
        let configPath = NSString(string: "~/.config/alfred/config.json").expandingTildeInPath

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
            var config = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            var notifications = config["notifications"] as? [String: Any] ?? [:]
            var push = notifications["push"] as? [String: Any] ?? [:]

            push["enabled"] = true
            push["vapid_public_key"] = keys.publicKey
            push["vapid_private_key"] = keys.privateKey
            push["vapid_subject"] = "mailto:\((config["user"] as? [String: Any])?["email"] as? String ?? "user@example.com")"
            push["max_per_day"] = 5
            push["quiet_hours_start"] = 22
            push["quiet_hours_end"] = 7

            notifications["push"] = push
            config["notifications"] = notifications

            let updatedData = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            try updatedData.write(to: URL(fileURLWithPath: configPath))

            print("🔑 [WebPush] VAPID keys generated and saved")

            return HTTPResponse(statusCode: 200, body: [
                "success": true,
                "vapid_public_key": keys.publicKey
            ] as [String: Any])
        } catch {
            return HTTPResponse(statusCode: 500, body: ["error": "Failed to save VAPID keys: \(error.localizedDescription)"])
        }
    }

    private func handleGetVAPIDPublicKey() -> HTTPResponse {
        guard let config = AppConfig.load(),
              let publicKey = config.notifications.push.vapidPublicKey, !publicKey.isEmpty else {
            return HTTPResponse(statusCode: 404, body: ["error": "VAPID keys not configured. Call POST /api/push/setup first."])
        }
        // Return as plain text (needed by PushManager.subscribe)
        return HTTPResponse(statusCode: 200, body: ["vapid_public_key": publicKey] as [String: Any])
    }

    private func handlePushSubscribe(_ request: HTTPRequest) -> HTTPResponse {
        guard let bodyData = request.body,
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let endpoint = json["endpoint"] as? String,
              let keys = json["keys"] as? [String: Any],
              let p256dh = keys["p256dh"] as? String,
              let auth = keys["auth"] as? String else {
            return HTTPResponse(statusCode: 400, body: ["error": "Invalid subscription object. Expected {endpoint, keys: {p256dh, auth}}"])
        }

        WebPushService.shared.addSubscription(endpoint: endpoint, p256dh: p256dh, auth: auth)
        return HTTPResponse(statusCode: 200, body: ["success": true, "message": "Subscribed"] as [String: Any])
    }

    private func handlePushUnsubscribe(_ request: HTTPRequest) -> HTTPResponse {
        guard let bodyData = request.body,
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let endpoint = json["endpoint"] as? String else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing endpoint"])
        }

        WebPushService.shared.removeSubscription(endpoint: endpoint)
        return HTTPResponse(statusCode: 200, body: ["success": true, "message": "Unsubscribed"] as [String: Any])
    }

    private func handleGetPushSubscriptions() -> HTTPResponse {
        let subs = WebPushService.shared.getSubscriptions()
        let list = subs.map { sub -> [String: Any] in
            [
                "endpoint": String(sub.endpoint.prefix(80)) + "...",
                "subscribedAt": ISO8601DateFormatter().string(from: sub.subscribedAt),
                "lastPushAt": sub.lastPushAt.map { ISO8601DateFormatter().string(from: $0) } as Any,
                "pushCountToday": sub.pushCountToday
            ]
        }
        return HTTPResponse(statusCode: 200, body: [
            "count": subs.count,
            "subscriptions": list
        ] as [String: Any])
    }

    private func handlePushTest(_ request: HTTPRequest) async -> HTTPResponse {
        guard let config = AppConfig.load(),
              let publicKey = config.notifications.push.vapidPublicKey,
              let privateKey = config.notifications.push.vapidPrivateKey,
              let subject = config.notifications.push.vapidSubject else {
            return HTTPResponse(statusCode: 400, body: ["error": "VAPID keys not configured. Call POST /api/push/setup first."])
        }

        let subs = WebPushService.shared.getSubscriptions()
        guard !subs.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "No push subscriptions. Open Alfred in a browser and grant notification permission first."])
        }

        // Use custom payload from request body if provided
        var customTitle = "Coach Alfred"
        var customBody = "Push notifications are working. You'll receive coaching insights here."
        var customTag = "test"
        var customUrl = "/home.html"
        var customType = "test"
        var customActions: [WebPushService.PushPayload.PushAction] = [
            WebPushService.PushPayload.PushAction(action: "open", title: "Open Alfred")
        ]

        if let bodyData = request.body,
           let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
            customTitle = json["title"] as? String ?? customTitle
            customBody = json["body"] as? String ?? customBody
            customTag = json["tag"] as? String ?? customTag
            customUrl = json["url"] as? String ?? customUrl
            customType = json["type"] as? String ?? customType
            if let acts = json["actions"] as? [[String: String]] {
                customActions = acts.compactMap { a in
                    guard let action = a["action"], let title = a["title"] else { return nil }
                    return WebPushService.PushPayload.PushAction(action: action, title: title)
                }
            }

            // If type is post-meeting, also set pending capture
            if customType == "post-meeting" {
                let meetingTitle = json["title"] as? String ?? "Meeting"
                let meetingId = json["meetingId"] as? String ?? "test"
                CoachingPushService.shared.setPendingCapture(
                    meetingId: meetingId,
                    meetingTitle: meetingTitle.replacingOccurrences(of: "Just left: ", with: "")
                )
            }
        }

        let payload = WebPushService.PushPayload(
            title: customTitle,
            body: customBody,
            tag: customTag,
            url: customUrl,
            type: customType,
            actions: customActions
        )

        var results: [String] = []
        results.append("Starting push to \(subs.count) subscriber(s)")

        for i in subs.indices {
            do {
                try await WebPushService.shared.sendSingle(
                    to: subs[i],
                    payload: payload,
                    vapidPublicKey: publicKey,
                    vapidPrivateKey: privateKey,
                    vapidSubject: subject
                )
                results.append("✅ Sent to subscriber \(i + 1)")
            } catch {
                results.append("❌ Failed subscriber \(i + 1): \(error.localizedDescription ?? String(describing: error))")
            }
        }

        return HTTPResponse(statusCode: 200, body: [
            "success": true,
            "sentTo": subs.count,
            "results": results
        ] as [String: Any])
    }

    private func handleGetPushBudget() -> HTTPResponse {
        return HTTPResponse(statusCode: 200, body: PushBudgetService.shared.getStats())
    }

    // MARK: - Focus Pin

    /// Pin a task as the user's #1 focus goal
    private func handlePinFocus(_ request: HTTPRequest) async -> HTTPResponse {
        guard let body = request.body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let notionId = json["notionId"] as? String, !notionId.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'notionId' in request body"])
        }

        // Validate task exists and is active
        guard let orchestrator = alfredService.orchestrator else {
            return HTTPResponse(statusCode: 500, body: ["error": "Service unavailable"])
        }

        do {
            guard let task = try await orchestrator.notionServicePublic.fetchTaskById(notionId: notionId) else {
                return HTTPResponse(statusCode: 404, body: ["error": "Task not found"])
            }

            guard task.status != .done && task.status != .cancelled else {
                return HTTPResponse(statusCode: 400, body: ["error": "Cannot pin a completed or cancelled task"])
            }

            // Save pin state
            updateSchedulerState([
                "pinnedGoalNotionId": notionId,
                "pinnedGoalAt": ISO8601DateFormatter().string(from: Date())
            ])

            // Bust pulse cache so Home refreshes immediately
            invalidateMemoryCache("home_pulse")
            cache.deleteByEndpoint("/api/home/pulse")

            var taskDict: [String: Any] = [
                "title": task.title,
                "priority": task.priority?.rawValue ?? "None",
                "notionId": task.notionId
            ]
            if let dueDate = task.dueDate {
                taskDict["dueDate"] = Self.simpleDateFormatter.string(from: dueDate)
            }

            return HTTPResponse(statusCode: 200, body: ["pinned": true, "task": taskDict])
        } catch {
            return HTTPResponse(statusCode: 500, body: ["error": "Failed to fetch task: \(error.localizedDescription)"])
        }
    }

    /// Unpin the current focus goal
    private func handleUnpinFocus() -> HTTPResponse {
        updateSchedulerState(["pinnedGoalNotionId": "", "pinnedGoalAt": ""])

        // Bust pulse cache
        invalidateMemoryCache("home_pulse")
        cache.deleteByEndpoint("/api/home/pulse")

        return HTTPResponse(statusCode: 200, body: ["unpinned": true])
    }

    /// Generate ranked suggestions for what to pin as #1
    private func handleFocusPinSuggestions(_ request: HTTPRequest) async -> HTTPResponse {
        guard let orchestrator = alfredService.orchestrator else {
            return HTTPResponse(statusCode: 500, body: ["error": "Service unavailable"])
        }

        let calendar = Calendar.current
        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMM d"

        do {
            let tasks = try await orchestrator.notionServicePublic.queryActiveTasks()

            // Score each task
            var scored: [(task: TaskItem, score: Int, reason: String)] = []

            for task in tasks {
                guard task.status != .done && task.status != .cancelled else { continue }

                var score = 0
                var reason = ""
                let age = calendar.dateComponents([.day], from: task.createdDate, to: now).day ?? 0
                let daysOverdue = task.dueDate.flatMap { calendar.dateComponents([.day], from: $0, to: now).day } ?? 0

                // Overdue + someone waiting (I Owe commitment)
                if task.isOverdue && task.commitmentDirection == .iOwe {
                    let person = task.committedTo ?? "someone"
                    score += 100
                    reason = "\(person) waiting — \(daysOverdue)d overdue"
                }

                // Critical priority
                if task.priority == .critical {
                    score += 80
                    if reason.isEmpty {
                        let due = task.dueDate.map { dateFormatter.string(from: $0) } ?? "no deadline"
                        reason = "Critical — due \(due)"
                    }
                }

                // High priority + due within 3 days
                if task.priority == .high, let dueDate = task.dueDate {
                    let daysUntilDue = calendar.dateComponents([.day], from: now, to: dueDate).day ?? 999
                    if daysUntilDue <= 3 && daysUntilDue >= 0 {
                        score += 70
                        if reason.isEmpty {
                            reason = "Due \(dateFormatter.string(from: dueDate)) — high priority"
                        }
                    }
                }

                // Escalated avoidance (21+ days stale, not started)
                if task.status == .notStarted && age > 21 {
                    score += 60
                    if reason.isEmpty {
                        reason = "Untouched \(age) days — decide: do or drop"
                    }
                }

                // Stale avoidance (14+ days, not started)
                if task.status == .notStarted && age > 14 && age <= 21 {
                    score += 40
                    if reason.isEmpty {
                        reason = "Sitting for \(age) days — avoidance signal"
                    }
                }

                // Any overdue task
                if task.isOverdue && daysOverdue > 0 {
                    score += 30
                    if reason.isEmpty {
                        reason = "\(daysOverdue)d overdue"
                    }
                    // Overdue bonus: +5 per day
                    score += min(daysOverdue * 5, 50)
                }

                // High priority (no imminent deadline)
                if task.priority == .high {
                    score += 20
                    if reason.isEmpty {
                        reason = "High priority"
                    }
                }

                if score > 0 {
                    scored.append((task: task, score: score, reason: reason))
                }
            }

            // Sort by score descending
            let sorted = scored.sorted { $0.score > $1.score }
            let showAll = request.queryParams["all"] == "true"
            let top = showAll ? Array(sorted) : Array(sorted.prefix(5))

            let suggestions: [[String: Any]] = top.map { item in
                var dict: [String: Any] = [
                    "notionId": item.task.notionId,
                    "title": item.task.title,
                    "priority": item.task.priority?.rawValue ?? "None",
                    "reason": item.reason,
                    "score": item.score
                ]
                if let dueDate = item.task.dueDate {
                    dict["dueDate"] = dateFormatter.string(from: dueDate)
                }
                if let person = item.task.committedTo ?? item.task.committedBy {
                    dict["person"] = person
                }
                return dict
            }

            // Include current pin if any
            var response: [String: Any] = ["suggestions": suggestions]
            let stateInfo = loadSchedulerStateRaw()
            if let pinnedId = stateInfo["pinnedGoalNotionId"] as? String, !pinnedId.isEmpty {
                if let pinnedTask = try? await orchestrator.notionServicePublic.fetchTaskById(notionId: pinnedId) {
                    response["currentPin"] = [
                        "notionId": pinnedTask.notionId,
                        "title": pinnedTask.title
                    ]
                }
            }

            return HTTPResponse(statusCode: 200, body: response)
        } catch {
            return HTTPResponse(statusCode: 500, body: ["error": "Failed to generate suggestions: \(error.localizedDescription)"])
        }
    }

    // MARK: - Weekly Reflection

    private func handleWeeklyReflection() async -> HTTPResponse {
        guard let config = alfredService.orchestrator?.config else {
            return HTTPResponse(statusCode: 500, body: ["error": "Config not available"])
        }

        var contextParts: [String] = []
        var metrics: [String: Any] = [:]
        let calendar = Calendar.current
        let today = Date()

        print("📊 Weekly reflection: starting data gathering...")

        // 1. Task metrics
        print("📊 Weekly reflection: fetching tasks...")
        if let orchestrator = alfredService.orchestrator {
            do {
                let allTasks = try await orchestrator.notionServicePublic.queryActiveTasks()
                let completed = allTasks.filter { $0.status == .done }
                let open = allTasks.filter { $0.status != .done }
                let overdue = open.filter { $0.isOverdue }
                let fourteenDaysAgo = calendar.date(byAdding: .day, value: -14, to: today)!
                let stale = open.filter { $0.status == .notStarted && $0.createdDate < fourteenDaysAgo }

                metrics["tasksCompleted"] = completed.count
                metrics["tasksOpen"] = open.count
                metrics["tasksOverdue"] = overdue.count
                metrics["tasksStale"] = stale.count

                contextParts.append("TASK SUMMARY:")
                contextParts.append("- Completed: \(completed.count)")
                contextParts.append("- Open: \(open.count)")
                contextParts.append("- Overdue: \(overdue.count)")
                contextParts.append("- Stale (14+ days, not started): \(stale.count)")

                if !completed.isEmpty {
                    contextParts.append("\nCOMPLETED THIS PERIOD:")
                    for task in completed.prefix(15) {
                        contextParts.append("- \(task.title) [\(task.priority?.rawValue ?? "none")]")
                    }
                }

                if !overdue.isEmpty {
                    contextParts.append("\nOVERDUE:")
                    let dateFormatter = DateFormatter()
                    dateFormatter.dateFormat = "MMM d"
                    for task in overdue.prefix(8) {
                        let daysOverdue = task.dueDate.map { calendar.dateComponents([.day], from: $0, to: today).day ?? 0 } ?? 0
                        contextParts.append("- \(task.title) (\(daysOverdue) days overdue)")
                    }
                }

                if !stale.isEmpty {
                    contextParts.append("\nSTALE / AVOIDED:")
                    for task in stale.prefix(5) {
                        let age = calendar.dateComponents([.day], from: task.createdDate, to: today).day ?? 0
                        contextParts.append("- \(task.title) (untouched \(age) days)")
                    }
                }
            } catch {
                contextParts.append("Tasks: unavailable")
            }
        }

        // 2. Commitment stats
        print("📊 Weekly reflection: fetching commitment stats...")
        let commitStats = CommitmentScanTracker.shared.getStats()
        metrics["commitmentsOpen"] = commitStats.openCommitments
        metrics["commitmentsClosed"] = commitStats.closedCount
        contextParts.append("\nCOMMITMENTS: \(commitStats.openCommitments) open, \(commitStats.closedCount) closed")

        let counterpartyStats = TaskLifecycleTracker.shared.getStatsByCounterparty()
        if !counterpartyStats.isEmpty {
            contextParts.append("\nRELATIONSHIP HEALTH:")
            for stat in counterpartyStats.prefix(8) {
                contextParts.append("- \(stat.name): \(stat.completedTasks)/\(stat.totalTasks) done, \(Int(stat.overdueRate * 100))% overdue")
            }
        }

        // 3. Overall lifecycle stats
        let lifecycleStats = TaskLifecycleTracker.shared.getStats()
        let completionRate = Int(lifecycleStats.completionRate * 100)
        let overdueRate = Int(lifecycleStats.overdueRate * 100)
        metrics["completionRate"] = completionRate
        metrics["overdueRate"] = overdueRate
        contextParts.append("\nOVERALL: \(completionRate)% completion rate, \(overdueRate)% overdue rate")

        // 4. Calendar snapshot (today only — lightweight, uses 10min cache)
        print("📊 Weekly reflection: fetching today's calendar...")
        do {
            let todayBriefing = try await alfredService.fetchCalendarBriefing(for: today)
            let todayMeetings = todayBriefing.schedule.events.filter { !$0.isAllDay }.count
            let totalHours = todayBriefing.schedule.events.filter { !$0.isAllDay }.reduce(0.0) { $0 + $1.duration } / 3600.0
            metrics["meetingsToday"] = todayMeetings
            metrics["meetingHoursToday"] = String(format: "%.1f", totalHours)
            contextParts.append("\nCALENDAR TODAY: \(todayMeetings) meetings (\(String(format: "%.1f", totalHours))h)")

            // List today's meetings for context
            for event in todayBriefing.schedule.events.filter({ !$0.isAllDay }).prefix(8) {
                let timeFormatter = DateFormatter()
                timeFormatter.dateFormat = "HH:mm"
                contextParts.append("- \(timeFormatter.string(from: event.startTime)): \(event.title)")
            }
        } catch {
            contextParts.append("\nCALENDAR: unavailable")
        }
        print("📊 Weekly reflection: calendar done")

        // 5. Recent coaching themes
        print("📊 Weekly reflection: fetching coaching themes...")
        let sessions = CoachingMemoryService.shared.getRecentSessions(limit: 5)
        if !sessions.isEmpty {
            contextParts.append("\nRECENT COACHING THEMES:")
            for session in sessions {
                let firstLine = session.components(separatedBy: "\n").first ?? session
                contextParts.append("- \(String(firstLine.prefix(150)))")
            }
        }

        // 6. Messaging velocity for attention patterns
        print("📊 Weekly reflection: fetching messaging velocity...")
        if let msgConfig = alfredService.orchestrator?.config {
            do {
                let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: today)!
                let reader = WhatsAppReader.shared(dbPath: msgConfig.messaging.whatsapp.dbPath)
                try reader.connect()
                let threads = try reader.fetchThreads(since: sevenDaysAgo)
                let totalIncoming = threads.flatMap { $0.messages }.filter { $0.direction == .incoming }.count
                let totalOutgoing = threads.flatMap { $0.messages }.filter { $0.direction == .outgoing }.count
                let ratio = totalOutgoing > 0 ? String(format: "%.1f", Double(totalIncoming) / Double(totalOutgoing)) : "∞"
                metrics["messagesInbound"] = totalIncoming
                metrics["messagesOutbound"] = totalOutgoing
                contextParts.append("\nMESSAGING: \(totalIncoming) inbound, \(totalOutgoing) outbound (ratio: \(ratio):1)")
                reader.disconnect()
            } catch { }
        }

        // Generate AI narrative
        print("📊 Weekly reflection: generating AI narrative...")
        let claudeService = ClaudeAIService(config: config.ai)
        let prompt = """
        You are Coach Alfred writing a comprehensive weekly reflection. This is a Sunday morning review — the founder's chance to step back and see the week clearly before planning the next one.

        Context:
        \(contextParts.joined(separator: "\n"))

        Write a weekly reflection covering these dimensions:

        ## WINS
        What was accomplished this week? Name specific completed tasks. Acknowledge real progress — even small wins matter.

        ## ACCOUNTABILITY
        What was supposed to happen but didn't? Name specific overdue tasks. Don't be harsh, but be honest: "The portfolio update for Sid was due Tuesday and it's still open. What got in the way?" Frame as curiosity, not judgment.

        ## PATTERNS
        Based on the data, what patterns are emerging? Are they operating in their Zone of Genius or grinding? Which relationships need investment? What keeps getting avoided?

        ## THIS WEEK
        ONE clear priority for the coming week. Be specific — name the task, the person, or the decision. End with a motivating challenge.

        Style:
        - Write in second person ("You completed...", "Your overdue rate...")
        - Be direct and warm. Like a friend who remembers everything.
        - Each section: 2-3 sentences, with specific names and numbers
        - Total: ~250 words
        - No emojis. Use ## headers for sections. Plain prose.

        Respond with ONLY the review text.
        """

        do {
            let narrative = try await claudeService.generateText(
                prompt: prompt,
                maxTokens: 600
            )

            let trimmedNarrative = narrative.trimmingCharacters(in: .whitespacesAndNewlines)

            // Save to Notion Reflections database (fire-and-forget)
            if let reflectionsDbId = config.notion.reflectionsDatabaseId, !reflectionsDbId.isEmpty {
                Task {
                    await self.saveReflectionToNotion(
                        dbId: reflectionsDbId,
                        apiKey: config.notion.apiKey,
                        narrative: trimmedNarrative,
                        metrics: metrics,
                        date: today
                    )
                }
            }

            let responseBody: [String: Any] = [
                "metrics": metrics,
                "narrative": trimmedNarrative,
                "generatedAt": Self.iso8601Formatter.string(from: Date())
            ]

            return HTTPResponse(statusCode: 200, body: responseBody)
        } catch {
            return HTTPResponse(statusCode: 500, body: ["error": "Failed to generate weekly reflection: \(error.localizedDescription)"])
        }
    }

    /// Save weekly reflection to Notion's Weekly Reflections database
    private func saveReflectionToNotion(dbId: String, apiKey: String, narrative: String, metrics: [String: Any], date: Date) async {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateStr = dateFormatter.string(from: date)

        // Week label: "Week of Feb 24, 2026"
        let weekFormatter = DateFormatter()
        weekFormatter.dateFormat = "MMM d, yyyy"
        let weekLabel = "Week of \(weekFormatter.string(from: date))"

        // Dedup check — don't create duplicate weekly reflections
        do {
            let checkUrl = URL(string: "https://api.notion.com/v1/databases/\(dbId)/query")!
            var checkReq = URLRequest(url: checkUrl)
            checkReq.httpMethod = "POST"
            checkReq.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            checkReq.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
            checkReq.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let filterBody: [String: Any] = [
                "filter": [
                    "property": "Week",
                    "title": ["equals": weekLabel]
                ],
                "page_size": 1
            ]
            checkReq.httpBody = try? JSONSerialization.data(withJSONObject: filterBody)

            let (checkData, _) = try await URLSession.shared.data(for: checkReq)
            if let checkJson = try? JSONSerialization.jsonObject(with: checkData) as? [String: Any],
               let results = checkJson["results"] as? [[String: Any]],
               !results.isEmpty {
                print("📊 Weekly reflection for '\(weekLabel)' already exists in Notion — skipping duplicate")
                return
            }
        } catch {
            print("⚠️ Could not check for duplicate reflection: \(error) — proceeding with creation")
        }

        // Determine mood based on metrics
        let overdue = (metrics["tasksOverdue"] as? Int) ?? 0
        let completionRate = (metrics["completionRate"] as? Int) ?? 0
        let mood: String
        if completionRate >= 85 && overdue <= 3 {
            mood = "Strong"
        } else if completionRate >= 70 && overdue <= 6 {
            mood = "Steady"
        } else if overdue > 8 || completionRate < 50 {
            mood = "Overwhelmed"
        } else {
            mood = "Struggling"
        }

        // Build In/Out ratio string
        let inbound = (metrics["messagesInbound"] as? Int) ?? 0
        let outbound = (metrics["messagesOutbound"] as? Int) ?? 0
        let ratioStr = outbound > 0 ? String(format: "%.1f:1", Double(inbound) / Double(outbound)) : "N/A"

        // Build Notion API request
        let url = URL(string: "https://api.notion.com/v1/pages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "parent": ["database_id": dbId],
            "properties": [
                "Week": ["title": [["text": ["content": weekLabel]]]],
                "Date": ["date": ["start": dateStr]],
                "Tasks Completed": ["number": (metrics["tasksCompleted"] as? Int) ?? 0],
                "Tasks Overdue": ["number": overdue],
                "Completion Rate": ["number": Double(completionRate) / 100.0],
                "Meetings": ["number": (metrics["meetingsToday"] as? Int) ?? 0],
                "Open Commitments": ["number": (metrics["commitmentsOpen"] as? Int) ?? 0],
                "In/Out Ratio": ["rich_text": [["text": ["content": ratioStr]]]],
                "Mood": ["select": ["name": mood]]
            ],
            "children": narrative.components(separatedBy: "\n").prefix(90).map { line -> [String: Any] in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("## ") {
                    return [
                        "object": "block",
                        "type": "heading_2",
                        "heading_2": [
                            "rich_text": [["type": "text", "text": ["content": String(trimmed.dropFirst(3))]]]
                        ]
                    ]
                } else if trimmed.isEmpty {
                    return [
                        "object": "block",
                        "type": "paragraph",
                        "paragraph": ["rich_text": [] as [[String: Any]]]
                    ]
                } else {
                    return [
                        "object": "block",
                        "type": "paragraph",
                        "paragraph": [
                            "rich_text": [["type": "text", "text": ["content": trimmed]]]
                        ]
                    ]
                }
            }
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                print("📊 Weekly reflection saved to Notion")
            } else {
                print("⚠️ Failed to save reflection to Notion: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
        } catch {
            print("⚠️ Failed to save reflection to Notion: \(error)")
        }
    }

    private func handleCoachingCards() async -> HTTPResponse {
        // Check memory cache first (2h TTL)
        if let cached: [String: Any] = getFromMemoryCache("coaching_cards") {
            return HTTPResponse(statusCode: 200, body: cached)
        }

        // Check disk cache (2h TTL — survives restarts)
        if let diskCached = cache.getCached(endpoint: "/api/coaching/cards") {
            if let data = diskCached.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                setInMemoryCache("coaching_cards", value: json, ttl: 7200)
                return HTTPResponse(statusCode: 200, body: json)
            }
        }

        guard let config = getConfig() else {
            return HTTPResponse(statusCode: 500, body: ["error": "Configuration not loaded"])
        }

        // Reuse stored CoachingEngine so its internal 2h cache works
        if coachingEngine == nil {
            coachingEngine = CoachingEngine(config: config, alfredService: alfredService)
        }

        do {
            let cards = try await coachingEngine!.generateCoachingCards()
            let cardsArray: [[String: Any]] = cards.map { card in
                var dict: [String: Any] = [
                    "type": card.type,
                    "label": card.label,
                    "insight": card.insight
                ]
                if let context = card.context {
                    dict["context"] = context
                }
                return dict
            }
            let body: [String: Any] = ["cards": cardsArray]

            // Cache in memory (2h) and disk (2h)
            setInMemoryCache("coaching_cards", value: body, ttl: 7200)
            if let jsonData = try? JSONSerialization.data(withJSONObject: body),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                cache.cache(endpoint: "/api/coaching/cards", response: jsonString, ttl: 7200)
            }

            return HTTPResponse(statusCode: 200, body: body)
        } catch {
            return HTTPResponse(statusCode: 500, body: ["error": "Failed to generate coaching cards: \(error.localizedDescription)"])
        }
    }

    private func handleGetCalendar(_ request: HTTPRequest) async -> HTTPResponse {
        // Parse date and calendar filter
        let date = parseDate(from: request.queryParams["date"])
        let calendar = request.queryParams["calendar"] ?? "all"
        let dateString = Self.iso8601Formatter.string(from: date)

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
                    "date": Self.iso8601Formatter.string(from: briefing.schedule.date),
                    "events": briefing.schedule.events.map { event in
                        [
                            "id": event.id,
                            "title": event.title,
                            "start": Self.iso8601Formatter.string(from: event.startTime),
                            "end": Self.iso8601Formatter.string(from: event.endTime),
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
                            "start": Self.iso8601Formatter.string(from: meeting.event.startTime),
                            "end": Self.iso8601Formatter.string(from: meeting.event.endTime)
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
                cache.cache(endpoint: "/api/calendar", params: cacheParams, response: jsonString, ttl: 600)
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
        let platform = request.queryParams["platform"] ?? "all"
        let timeframe = request.queryParams["timeframe"] ?? "24h"

        // Check cache first (10 min TTL for messages)
        let cacheParams = ["platform": platform, "timeframe": timeframe]
        if let cached = cache.getCached(endpoint: "/api/messages", params: cacheParams) {
            if let data = cached.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                print("⚡ Returning cached messages")
                return HTTPResponse(statusCode: 200, body: json)
            }
        }

        do {
            let summaries = try await alfredService.fetchMessagesSummary(
                platform: platform,
                timeframe: timeframe
            )

            let responseBody: [String: Any] = [
                "messages": summaries.map { serializeMessageSummary($0) },
                "count": summaries.count
            ]

            // Cache result (10 min TTL)
            if let jsonData = try? JSONSerialization.data(withJSONObject: responseBody),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                cache.cache(endpoint: "/api/messages", params: cacheParams, response: jsonString, ttl: 600)
            }

            return HTTPResponse(statusCode: 200, body: responseBody)
        } catch {
            return HTTPResponse(
                statusCode: 500,
                body: ["error": error.localizedDescription]
            )
        }
    }

    private func handleGetAttentionCheck() async -> HTTPResponse {
        // Check cache first (4 hour TTL for attention check)
        if let cached = cache.getCached(endpoint: "/api/attention-check", params: [:]) {
            if let data = cached.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                print("⚡ Returning cached attention check")
                return HTTPResponse(statusCode: 200, body: json)
            }
        }

        do {
            let report = try await alfredService.generateAttentionCheck()

            // Get favorites for highlighting
            let favorites = FavoritesService.shared.getFavorites()

            // Calculate time remaining for response body
            let calendar = Calendar.current
            let endOfDay = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: report.currentTime)!
            let timeRemaining = max(0, endOfDay.timeIntervalSince(report.currentTime))

            // Use shared formatting helper
            let formattedResponse = formatAttentionCheckReport(report, favorites: favorites)

            let responseBody: [String: Any] = [
                "response": formattedResponse,
                "currentTime": Self.iso8601Formatter.string(from: report.currentTime),
                "timeRemaining": timeRemaining,
                "mustDoToday": report.mustDoToday.map { item in
                    [
                        "id": item.id,
                        "title": item.title,
                        "description": item.description,
                        "priority": item.priority.rawValue,
                        "dueDate": item.dueDate.map { Self.iso8601Formatter.string(from: $0) } as Any,
                        "counterparty": item.counterparty as Any,
                        "isFavorite": item.counterparty.map { favorites.isFavorite($0) } ?? false
                    ] as [String: Any]
                },
                "canPushOff": report.canPushOff.map { suggestion in
                    [
                        "item": [
                            "id": suggestion.item.id,
                            "title": suggestion.item.title,
                            "description": suggestion.item.description
                        ],
                        "reason": suggestion.reason,
                        "suggestedNewDate": Self.iso8601Formatter.string(from: suggestion.suggestedNewDate),
                        "impact": suggestion.impact.rawValue
                    ] as [String: Any]
                },
                "recommendations": report.recommendations,
                "stats": [
                    "mustDoCount": report.mustDoToday.count,
                    "canPushCount": report.canPushOff.count,
                    "totalTasks": report.mustDoToday.count + report.canPushOff.count
                ]
            ]

            // Cache for 4 hours
            if let jsonData = try? JSONSerialization.data(withJSONObject: responseBody),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                cache.cache(endpoint: "/api/attention-check", params: [:], response: jsonString, ttl: 14400)
            }

            return HTTPResponse(statusCode: 200, body: responseBody)
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
            let result = try await alfredService.scanWhatsAppForTodos()
            let todos = result.createdTodos

            // Format response
            var formattedResponse = "📝 **Todo Scan Results**\n\n"
            if result.todosFound == 0 {
                formattedResponse += "No todos found in recent WhatsApp messages.\n"
            } else {
                formattedResponse += "Found \(result.todosFound) todo(s), created \(result.todosCreated) new, skipped \(result.duplicatesSkipped) duplicate(s).\n\n"
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
                "todosFound": result.todosFound,
                "todosCreated": result.todosCreated,
                "messagesScanned": result.messagesScanned,
                "duplicatesSkipped": result.duplicatesSkipped,
                "lookbackDays": result.lookbackDays,
                "todos": todos.map { todo in
                    [
                        "title": todo.title,
                        "description": todo.description as Any,
                        "dueDate": todo.dueDate.map { Self.iso8601Formatter.string(from: $0) } as Any,
                        "source": [
                            "platform": todo.sourceMessage.platform.rawValue,
                            "sender": todo.sourceMessage.senderName ?? todo.sourceMessage.sender,
                            "timestamp": Self.iso8601Formatter.string(from: todo.sourceMessage.timestamp)
                        ]
                    ]
                },
                "count": result.todosCreated
            ]

            // Cache the response (30 min)
            if let jsonData = try? JSONSerialization.data(withJSONObject: responseBody),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                cache.cache(endpoint: "/api/todos/scan", response: jsonString, ttl: 600)
            }

            // Update scheduler state (todoScan already uses ISO timestamp)
            updateSchedulerState(["lastTodoScanTime": ISO8601DateFormatter().string(from: Date())])

            return HTTPResponse(statusCode: 200, body: responseBody)
        } catch {
            return HTTPResponse(
                statusCode: 500,
                body: ["error": error.localizedDescription]
            )
        }
    }

    // MARK: - Post-Meeting Capture

    private func handlePostMeetingCapture(_ request: HTTPRequest) async -> HTTPResponse {
        // Parse JSON body
        guard let bodyData = request.body,
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let text = json["text"] as? String, !text.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'text' in request body"])
        }

        let meetingTitle = json["meetingTitle"] as? String ?? "Meeting"
        let meetingId = json["meetingId"] as? String

        guard let orchestrator = alfredService.orchestrator else {
            return HTTPResponse(statusCode: 500, body: ["error": "Service not available"])
        }

        // Create a follow-up task with the raw capture text
        let task = TaskItem(
            notionId: "",
            title: "Follow-up: \(meetingTitle)",
            type: .followup,
            status: .notStarted,
            description: text,
            dueDate: nil,
            priority: nil,
            assignee: nil,
            commitmentDirection: nil,
            committedBy: nil,
            committedTo: nil,
            originalContext: "Post-meeting capture for: \(meetingTitle)",
            sourcePlatform: .manual,
            sourceThread: meetingId,
            sourceThreadId: nil,
            tags: ["post-meeting-capture"],
            followUpDate: nil,
            uniqueHash: nil,
            notes: nil,
            createdDate: Date(),
            lastUpdated: Date()
        )

        do {
            let notionId = try await orchestrator.notionServicePublic.createTask(task)
            print("✅ [Capture] Created follow-up for '\(meetingTitle)': \(notionId)")

            return HTTPResponse(statusCode: 200, body: [
                "success": true,
                "notionId": notionId,
                "tasksCreated": 1,
                "meetingTitle": meetingTitle
            ] as [String: Any])
        } catch {
            print("❌ [Capture] Failed to create follow-up: \(error)")
            return HTTPResponse(statusCode: 500, body: ["error": "Failed to save capture: \(error.localizedDescription)"])
        }
    }

    private func handleGetPendingCapture() -> HTTPResponse {
        if let pending = CoachingPushService.shared.pendingCapture {
            // Auto-expire after 30 minutes
            if Date().timeIntervalSince(pending.createdAt) > 1800 {
                CoachingPushService.shared.clearPendingCapture()
                return HTTPResponse(statusCode: 200, body: ["pending": false] as [String: Any])
            }
            return HTTPResponse(statusCode: 200, body: [
                "pending": true,
                "meetingId": pending.meetingId,
                "meetingTitle": pending.meetingTitle
            ] as [String: Any])
        }
        return HTTPResponse(statusCode: 200, body: ["pending": false] as [String: Any])
    }

    private func handleClearPendingCapture() -> HTTPResponse {
        CoachingPushService.shared.clearPendingCapture()
        return HTTPResponse(statusCode: 200, body: ["cleared": true] as [String: Any])
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
                        "dueDate": commitment.dueDate.map { Self.iso8601Formatter.string(from: $0) } as Any
                    ]
                },
                "count": commitments.count
            ]

            // Cache (1 hour)
            if let jsonData = try? JSONSerialization.data(withJSONObject: responseBody),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                cache.cache(endpoint: "/api/commitment-check", params: cacheParams, response: jsonString, ttl: 600)
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

        print("💬 [Messages Summary] Starting for contact: \(contact), platform: \(platform), timeframe: \(timeframe)")

        // Wrap in a timeout to prevent hanging forever
        do {
            let result = try await withThrowingTaskGroup(of: HTTPResponse.self) { group in
                group.addTask {
                    // The actual summary work
                    let summary = try await self.alfredService.getMessagesSummaryForContact(
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
                        "messageCount": summary.messageCount,
                        "actionItems": summary.actionItems.map { item in
                            [
                                "id": UUID().uuidString,
                                "title": item.item,
                                "priority": item.priority,
                                "deadline": item.deadline as Any,
                                "source": "message",
                                "category": "task"
                            ] as [String: Any]
                        }
                    ]

                    // Cache (10 min)
                    if let jsonData = try? JSONSerialization.data(withJSONObject: responseBody),
                       let jsonString = String(data: jsonData, encoding: .utf8) {
                        self.cache.cache(endpoint: "/api/messages/summary", params: cacheParams, response: jsonString, ttl: 600)
                    }

                    print("✅ [Messages Summary] Complete for \(contact): \(summary.messageCount) messages")
                    return HTTPResponse(statusCode: 200, body: responseBody)
                }

                // Timeout task
                group.addTask {
                    try await Task.sleep(nanoseconds: 60_000_000_000) // 60 seconds
                    print("⏰ [Messages Summary] Timed out for \(contact) after 60s")
                    return HTTPResponse(
                        statusCode: 504,
                        body: [
                            "error": "Summary generation timed out. This typically happens when analyzing large chat groups.",
                            "contact": contact,
                            "timeout": true
                        ]
                    )
                }

                // Return whichever finishes first
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
            return result
        } catch {
            print("❌ [Messages Summary] Error for \(contact): \(error.localizedDescription)")
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
                    "suggestedSendTime": draft.suggestedSendTime.map { Self.iso8601Formatter.string(from: $0) } as Any
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
        // Check memory cache (30min TTL)
        if let cached: [String: Any] = getFromMemoryCache("config_notion") {
            return HTTPResponse(statusCode: 200, body: cached)
        }

        // Read from config file
        let configPath = NSString(string: "~/.config/alfred/config.json").expandingTildeInPath

        guard FileManager.default.fileExists(atPath: configPath) else {
            return HTTPResponse(
                statusCode: 200,
                body: ["tasksDatabaseId": NSNull(), "contextDatabases": [], "contextDatabaseNames": [:] as [String: String]]
            )
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
            let fileConfig = try JSONSerialization.jsonObject(with: data) as? [String: Any]

            // Try to find tasks_database_id - check top-level first, then briefing_sources as fallback
            var tasksDatabaseId: String?

            // Check notion.tasks_database_id first (top-level takes priority)
            if let notion = fileConfig?["notion"] as? [String: Any],
               let dbId = notion["tasks_database_id"] as? String,
               dbId != "YOUR_TASKS_DATABASE_ID" {
                tasksDatabaseId = dbId
            }

            // Fallback to notion.briefing_sources.tasks_database_id
            if tasksDatabaseId == nil,
               let notion = fileConfig?["notion"] as? [String: Any],
               let briefingSources = notion["briefing_sources"] as? [String: Any],
               let dbId = briefingSources["tasks_database_id"] as? String,
               dbId != "YOUR_TASKS_DATABASE_ID" {
                tasksDatabaseId = dbId
            }

            // Get context databases
            var contextDatabases: [String] = []
            if let notion = fileConfig?["notion"] as? [String: Any],
               let contextDbs = notion["context_databases"] as? [String] {
                contextDatabases = contextDbs.filter { !$0.isEmpty }
            }

            // Resolve database names from Notion API
            var contextDatabaseNames: [String: String] = [:]
            let apiKey: String = {
                if let notion = fileConfig?["notion"] as? [String: Any],
                   let key = notion["api_key"] as? String { return key }
                return ""
            }()
            if !apiKey.isEmpty && apiKey != "YOUR_NOTION_API_KEY" {
                for dbId in contextDatabases {
                    if let name = await fetchNotionDatabaseTitle(dbId: dbId, apiKey: apiKey) {
                        contextDatabaseNames[dbId] = name
                    }
                }
                // Also resolve tasks database name
                if let tasksId = tasksDatabaseId,
                   let name = await fetchNotionDatabaseTitle(dbId: tasksId, apiKey: apiKey) {
                    contextDatabaseNames[tasksId] = name
                }
            }

            let body: [String: Any] = [
                "tasksDatabaseId": tasksDatabaseId as Any,
                "contextDatabases": contextDatabases,
                "contextDatabaseNames": contextDatabaseNames
            ]

            // Cache in memory (30min)
            setInMemoryCache("config_notion", value: body, ttl: 1800)

            return HTTPResponse(statusCode: 200, body: body)
        } catch {
            return HTTPResponse(
                statusCode: 500,
                body: ["error": "Failed to read config: \(error.localizedDescription)"]
            )
        }
    }

    /// Fetch a Notion database title by ID
    private func fetchNotionDatabaseTitle(dbId: String, apiKey: String) async -> String? {
        guard let url = URL(string: "https://api.notion.com/v1/databases/\(dbId)") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2025-09-03", forHTTPHeaderField: "Notion-Version")
        request.timeoutInterval = 5

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return nil }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let titleArray = json?["title"] as? [[String: Any]],
               let firstTitle = titleArray.first,
               let plainText = firstTitle["plain_text"] as? String {
                return plainText
            }
        } catch {
            // Silently fail — name resolution is best-effort
        }
        return nil
    }

    private func handleUpdateNotionConfig(_ request: HTTPRequest) async -> HTTPResponse {
        guard let bodyData = request.body,
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            return HTTPResponse(
                statusCode: 400,
                body: ["error": "Invalid request body"]
            )
        }

        // Extract tasksDatabaseId (optional now)
        let tasksDatabaseId = json["tasksDatabaseId"] as? String

        // Extract context databases (optional)
        let contextDatabases = json["contextDatabases"] as? [String] ?? []

        // At least one must be provided
        if tasksDatabaseId == nil && contextDatabases.isEmpty {
            return HTTPResponse(
                statusCode: 400,
                body: ["error": "At least tasksDatabaseId or contextDatabases must be provided"]
            )
        }

        // Update the Tasks database ID in the orchestrator's NotionService if provided
        if let tasksDatabaseId = tasksDatabaseId {
            guard let orchestrator = alfredService.orchestrator else {
                return HTTPResponse(
                    statusCode: 500,
                    body: ["error": "Alfred not initialized"]
                )
            }
            orchestrator.notionServicePublic.setTasksDatabaseId(tasksDatabaseId)
        }

        // Update in config file
        let configPath = NSString(string: "~/.config/alfred/config.json").expandingTildeInPath
        do {
            if FileManager.default.fileExists(atPath: configPath) {
                let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
                var config = try JSONSerialization.jsonObject(with: data) as! [String: Any]

                // Update notion section
                if var notion = config["notion"] as? [String: Any] {
                    // Update tasks_database_id if provided
                    if let tasksDatabaseId = tasksDatabaseId {
                        notion["tasks_database_id"] = tasksDatabaseId
                    }

                    // Update context_databases
                    if !contextDatabases.isEmpty {
                        notion["context_databases"] = contextDatabases
                    } else {
                        // If empty array was explicitly sent, clear it
                        notion["context_databases"] = []
                    }

                    config["notion"] = notion
                }

                let updatedData = try JSONSerialization.data(withJSONObject: config, options: .prettyPrinted)
                try updatedData.write(to: URL(fileURLWithPath: configPath))
            }
        } catch {
            print("⚠️ Failed to update config file: \(error)")
        }

        // Invalidate config cache
        invalidateMemoryCache("config_notion")

        var responseBody: [String: Any] = ["message": "Notion configuration updated successfully"]
        if let tasksDatabaseId = tasksDatabaseId {
            responseBody["tasksDatabaseId"] = tasksDatabaseId
        }
        if !contextDatabases.isEmpty {
            responseBody["contextDatabases"] = contextDatabases
        }

        return HTTPResponse(
            statusCode: 200,
            body: responseBody
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
        clearAllMemoryCache()
        return HTTPResponse(
            statusCode: 200,
            body: ["message": "All cache cleared successfully (memory + disk)"]
        )
    }

    // MARK: - Scheduled Config Handlers

    private func handleGetScheduledConfig() -> HTTPResponse {
        // Check memory cache (30min TTL)
        if let cached: [String: Any] = getFromMemoryCache("config_scheduled") {
            return HTTPResponse(statusCode: 200, body: cached)
        }

        let configPath = NSString(string: "~/.config/alfred/config.json").expandingTildeInPath

        guard FileManager.default.fileExists(atPath: configPath) else {
            return HTTPResponse(statusCode: 200, body: [
                "briefing_time": "07:00",
                "attention_alert_time": "15:00",
                "briefing_enabled": true,
                "attention_enabled": true,
                "email_to": ""
            ] as [String: Any])
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
            let config = try JSONSerialization.jsonObject(with: data) as? [String: Any]

            let app = config?["app"] as? [String: Any]
            let scheduled = config?["scheduled"] as? [String: Any]

            let body: [String: Any] = [
                "briefing_time": app?["briefing_time"] as? String ?? "07:00",
                "attention_alert_time": app?["attention_alert_time"] as? String ?? "15:00",
                "briefing_enabled": scheduled?["briefing_enabled"] as? Bool ?? true,
                "attention_enabled": scheduled?["attention_enabled"] as? Bool ?? true,
                "email_to": scheduled?["email_to"] as? String ?? ""
            ]

            // Cache in memory (30min)
            setInMemoryCache("config_scheduled", value: body, ttl: 1800)

            return HTTPResponse(statusCode: 200, body: body)
        } catch {
            return HTTPResponse(statusCode: 500, body: ["error": "Failed to read config: \(error.localizedDescription)"])
        }
    }

    private func handleUpdateScheduledConfig(_ request: HTTPRequest) -> HTTPResponse {
        guard let bodyData = request.body,
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            return HTTPResponse(statusCode: 400, body: ["error": "Invalid request body"])
        }

        let configPath = NSString(string: "~/.config/alfred/config.json").expandingTildeInPath

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
            var config = try JSONSerialization.jsonObject(with: data) as! [String: Any]

            // Update app.briefing_time and app.attention_alert_time
            if var app = config["app"] as? [String: Any] {
                if let briefingTime = json["briefing_time"] as? String, !briefingTime.isEmpty {
                    app["briefing_time"] = briefingTime
                }
                if let attentionAlertTime = json["attention_alert_time"] as? String, !attentionAlertTime.isEmpty {
                    app["attention_alert_time"] = attentionAlertTime
                }
                config["app"] = app
            }

            // Update scheduled section
            var scheduled = config["scheduled"] as? [String: Any] ?? [:]
            if let briefingEnabled = json["briefing_enabled"] as? Bool {
                scheduled["briefing_enabled"] = briefingEnabled
            }
            if let attentionEnabled = json["attention_enabled"] as? Bool {
                scheduled["attention_enabled"] = attentionEnabled
            }
            if let emailTo = json["email_to"] as? String {
                scheduled["email_to"] = emailTo
            }
            config["scheduled"] = scheduled

            let updatedData = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            try updatedData.write(to: URL(fileURLWithPath: configPath))

            print("📅 Scheduled config updated successfully")
            invalidateMemoryCache("config_scheduled")

            return HTTPResponse(statusCode: 200, body: ["message": "Schedule settings saved successfully"])
        } catch {
            return HTTPResponse(statusCode: 500, body: ["error": "Failed to update config: \(error.localizedDescription)"])
        }
    }

    // MARK: - Theme Handlers

    private func handleGetTheme() -> HTTPResponse {
        let configPath = NSString(string: "~/.config/alfred/config.json").expandingTildeInPath

        guard FileManager.default.fileExists(atPath: configPath) else {
            return HTTPResponse(statusCode: 200, body: ["theme": "light"])
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
            let config = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let app = config?["app"] as? [String: Any]
            let theme = app?["theme"] as? String ?? "light"

            return HTTPResponse(statusCode: 200, body: ["theme": theme])
        } catch {
            return HTTPResponse(statusCode: 500, body: ["error": "Failed to read config: \(error.localizedDescription)"])
        }
    }

    private func handleUpdateTheme(_ request: HTTPRequest) -> HTTPResponse {
        guard let bodyData = request.body,
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let theme = json["theme"] as? String else {
            return HTTPResponse(statusCode: 400, body: ["error": "Invalid request body. Expected {\"theme\": \"light\" | \"dark\"}"])
        }

        guard theme == "light" || theme == "dark" else {
            return HTTPResponse(statusCode: 400, body: ["error": "Invalid theme value. Must be \"light\" or \"dark\""])
        }

        let configPath = NSString(string: "~/.config/alfred/config.json").expandingTildeInPath

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
            var config = try JSONSerialization.jsonObject(with: data) as! [String: Any]

            var app = config["app"] as? [String: Any] ?? [:]
            app["theme"] = theme
            config["app"] = app

            let updatedData = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            try updatedData.write(to: URL(fileURLWithPath: configPath))

            print("🎨 Theme updated to: \(theme)")

            return HTTPResponse(statusCode: 200, body: ["message": "Theme updated to \(theme)", "theme": theme])
        } catch {
            return HTTPResponse(statusCode: 500, body: ["error": "Failed to update config: \(error.localizedDescription)"])
        }
    }

    // MARK: - Favorites Handlers

    private func handleGetFavorites() -> HTTPResponse {
        // Check memory cache (10min TTL)
        if let cached: [String: Any] = getFromMemoryCache("favorites") {
            return HTTPResponse(statusCode: 200, body: cached)
        }

        let favorites = FavoritesService.shared.getFavorites()

        let contactsArray = favorites.contacts.map { contact -> [String: Any] in
            [
                "name": contact.name,
                "aliases": contact.aliases,
                "platforms": contact.platforms,
                "notes": contact.notes ?? "",
                "addedAt": ISO8601DateFormatter().string(from: contact.addedAt)
            ]
        }

        let groupsArray = favorites.groups.map { group -> [String: Any] in
            [
                "name": group.name,
                "aliases": group.aliases,
                "platform": group.platform,
                "notes": group.notes ?? "",
                "addedAt": ISO8601DateFormatter().string(from: group.addedAt)
            ]
        }

        let body: [String: Any] = [
            "contacts": contactsArray,
            "groups": groupsArray
        ]

        // Cache in memory (10min)
        setInMemoryCache("favorites", value: body, ttl: 600)

        return HTTPResponse(statusCode: 200, body: body)
    }

    private func handleAddFavoriteContact(_ request: HTTPRequest) -> HTTPResponse {
        guard let bodyData = request.body,
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let name = json["name"] as? String, !name.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Name is required"])
        }

        let aliases = json["aliases"] as? [String] ?? []
        let platforms = json["platforms"] as? [String] ?? ["whatsapp", "imessage"]
        let notes = json["notes"] as? String

        let contact = FavoriteContact(name: name, aliases: aliases, platforms: platforms, notes: notes)

        do {
            try FavoritesService.shared.addContact(contact)
            invalidateMemoryCache("favorites")
            return HTTPResponse(statusCode: 200, body: [
                "success": true,
                "message": "Added \(name) to favorites"
            ])
        } catch FavoritesError.duplicateEntry {
            return HTTPResponse(statusCode: 400, body: ["error": "\(name) is already a favorite"])
        } catch {
            return HTTPResponse(statusCode: 500, body: ["error": "Failed to add favorite: \(error.localizedDescription)"])
        }
    }

    private func handleRemoveFavoriteContact(_ request: HTTPRequest) -> HTTPResponse {
        let name = request.queryParams["name"] ?? ""

        guard !name.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Name is required"])
        }

        do {
            try FavoritesService.shared.removeContact(name: name)
            invalidateMemoryCache("favorites")
            return HTTPResponse(statusCode: 200, body: [
                "success": true,
                "message": "Removed \(name) from favorites"
            ])
        } catch {
            return HTTPResponse(statusCode: 500, body: ["error": "Failed to remove favorite: \(error.localizedDescription)"])
        }
    }

    private func handleAddFavoriteGroup(_ request: HTTPRequest) -> HTTPResponse {
        guard let bodyData = request.body,
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let name = json["name"] as? String, !name.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Name is required"])
        }

        let aliases = json["aliases"] as? [String] ?? []
        let platform = json["platform"] as? String ?? "whatsapp"
        let notes = json["notes"] as? String

        let group = FavoriteGroup(name: name, aliases: aliases, platform: platform, notes: notes)

        do {
            try FavoritesService.shared.addGroup(group)
            invalidateMemoryCache("favorites")
            return HTTPResponse(statusCode: 200, body: [
                "success": true,
                "message": "Added \(name) to favorite groups"
            ])
        } catch FavoritesError.duplicateEntry {
            return HTTPResponse(statusCode: 400, body: ["error": "\(name) is already a favorite group"])
        } catch {
            return HTTPResponse(statusCode: 500, body: ["error": "Failed to add favorite group: \(error.localizedDescription)"])
        }
    }

    private func handleRemoveFavoriteGroup(_ request: HTTPRequest) -> HTTPResponse {
        let name = request.queryParams["name"] ?? ""

        guard !name.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Name is required"])
        }

        do {
            try FavoritesService.shared.removeGroup(name: name)
            invalidateMemoryCache("favorites")
            return HTTPResponse(statusCode: 200, body: [
                "success": true,
                "message": "Removed \(name) from favorite groups"
            ])
        } catch {
            return HTTPResponse(statusCode: 500, body: ["error": "Failed to remove favorite group: \(error.localizedDescription)"])
        }
    }

    // MARK: - Playbook Handlers

    private func handleGetPlaybookStatus() -> HTTPResponse {
        // Check memory cache (15min TTL)
        if let cached: [String: Any] = getFromMemoryCache("playbook_status") {
            return HTTPResponse(statusCode: 200, body: cached)
        }

        let playbookService = PlaybookService.shared

        let pageId = playbookService.getPlaybookPageId()
        let lastSync = playbookService.getLastSyncTimestamp()

        var response: [String: Any] = [
            "configured": pageId != nil
        ]

        if let id = pageId {
            response["pageId"] = id
            response["notionUrl"] = "https://notion.so/\(id.replacingOccurrences(of: "-", with: ""))"
        }

        if let sync = lastSync {
            response["lastSync"] = Self.iso8601Formatter.string(from: sync)
            response["lastSyncFormatted"] = formatRelativeDate(sync)
        }

        // Cache in memory (15min)
        setInMemoryCache("playbook_status", value: response, ttl: 900)

        return HTTPResponse(statusCode: 200, body: response)
    }

    private func handleSyncPlaybook() async -> HTTPResponse {
        let playbookService = PlaybookService.shared

        do {
            try await playbookService.syncToNotion()

            // Invalidate playbook status cache
            invalidateMemoryCache("playbook_status")

            let pageId = playbookService.getPlaybookPageId() ?? ""
            return HTTPResponse(statusCode: 200, body: [
                "success": true,
                "message": "Playbook synced to Notion",
                "pageId": pageId,
                "notionUrl": "https://notion.so/\(pageId.replacingOccurrences(of: "-", with: ""))"
            ])
        } catch {
            return HTTPResponse(statusCode: 500, body: [
                "error": "Failed to sync Playbook: \(error.localizedDescription)"
            ])
        }
    }

    private func handleSetupPlaybook(_ request: HTTPRequest) async -> HTTPResponse {
        let playbookService = PlaybookService.shared

        // Optional parent page ID from request
        var parentPageId: String?
        if let bodyData = request.body,
           let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
            parentPageId = json["parentPageId"] as? String
        }

        do {
            let pageId = try await playbookService.ensurePlaybookExists(parentPageId: parentPageId)

            // Update config with the new page ID
            playbookService.setPlaybookPageId(pageId)

            // Sync initial content
            try await playbookService.syncToNotion()

            return HTTPResponse(statusCode: 200, body: [
                "success": true,
                "message": "Playbook created and synced",
                "pageId": pageId,
                "notionUrl": "https://notion.so/\(pageId.replacingOccurrences(of: "-", with: ""))"
            ])
        } catch {
            return HTTPResponse(statusCode: 500, body: [
                "error": "Failed to setup Playbook: \(error.localizedDescription)"
            ])
        }
    }

    // MARK: - Coaching Context Notion Sync Handlers

    private func handleGetCoachingContextStatus() -> HTTPResponse {
        let status = CoachingNotionSyncService.shared.getStatus()
        return HTTPResponse(statusCode: 200, body: status)
    }

    private func handleSyncCoachingContext(_ request: HTTPRequest) async -> HTTPResponse {
        let force = request.queryParams["force"] == "true"

        do {
            try await CoachingNotionSyncService.shared.syncToNotion(force: force)

            let pageId = CoachingNotionSyncService.shared.getPageId() ?? ""
            return HTTPResponse(statusCode: 200, body: [
                "success": true,
                "message": "Coaching context synced to Notion",
                "pageId": pageId,
                "notionUrl": "https://notion.so/\(pageId.replacingOccurrences(of: "-", with: ""))"
            ])
        } catch {
            return HTTPResponse(statusCode: 500, body: [
                "error": "Failed to sync coaching context: \(error.localizedDescription)"
            ])
        }
    }

    private func handleSetupCoachingContext(_ request: HTTPRequest) async -> HTTPResponse {
        var parentPageId: String?
        if let bodyData = request.body,
           let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
            parentPageId = json["parentPageId"] as? String
        }

        do {
            let pageId = try await CoachingNotionSyncService.shared.ensurePageExists(parentPageId: parentPageId)

            // Sync initial content
            try await CoachingNotionSyncService.shared.syncToNotion(force: true)

            return HTTPResponse(statusCode: 200, body: [
                "success": true,
                "message": "Coach Alfred Context page created and synced",
                "pageId": pageId,
                "notionUrl": "https://notion.so/\(pageId.replacingOccurrences(of: "-", with: ""))"
            ])
        } catch {
            return HTTPResponse(statusCode: 500, body: [
                "error": "Failed to setup coaching context: \(error.localizedDescription)"
            ])
        }
    }

    private func formatRelativeDate(_ date: Date) -> String {
        let now = Date()
        let interval = now.timeIntervalSince(date)

        if interval < 60 {
            return "just now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes) minute\(minutes == 1 ? "" : "s") ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours) hour\(hours == 1 ? "" : "s") ago"
        } else {
            let days = Int(interval / 86400)
            return "\(days) day\(days == 1 ? "" : "s") ago"
        }
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

    private func handleAgentDigest() async -> HTTPResponse {
        do {
            let digest = try await alfredService.generateAgentDigest()

            var responseText = "📊 **Daily Agent Digest**\n\n"

            // Summary
            responseText += "**Summary**\n"
            responseText += "- Total Decisions: \(digest.summary.totalDecisions)\n"
            responseText += "- Executed: \(digest.summary.decisionsExecuted)\n"
            responseText += "- Pending Review: \(digest.summary.decisionsPending)\n"
            responseText += "- New Learnings: \(digest.summary.newLearningsCount)\n"
            responseText += "- Follow-ups Created: \(digest.summary.followupsCreated)\n\n"

            // Agent Activity
            responseText += "**Agent Activity**\n"
            for activity in digest.agentActivity where activity.decisionsCount > 0 {
                let successPct = Int(activity.successRate * 100)
                responseText += "\n**\(activity.agentType.displayName)**: \(activity.decisionsCount) decisions (\(successPct)% success)\n"
                if let topAction = activity.topAction {
                    responseText += "  Top action: \(topAction)\n"
                }
            }

            // Commitment Status
            responseText += "\n**Commitment Status**\n"
            responseText += "- I Owe (Active): \(digest.commitmentStatus.activeIOwe)\n"
            responseText += "- They Owe Me: \(digest.commitmentStatus.activeTheyOwe)\n"
            responseText += "- Overdue: \(digest.commitmentStatus.overdueCount)\n"
            responseText += "- Due This Week: \(digest.commitmentStatus.upcomingThisWeek)\n"

            // Upcoming Follow-ups
            if !digest.upcomingFollowups.isEmpty {
                responseText += "\n**Upcoming Follow-ups (\(digest.upcomingFollowups.count))**\n"
                for followup in digest.upcomingFollowups.prefix(3) {
                    let overdueTag = followup.isOverdue ? " ⚠️" : ""
                    responseText += "- \(followup.title)\(overdueTag)\n"
                }
            }

            // Recommendations
            if !digest.recommendations.isEmpty {
                responseText += "\n**Recommendations**\n"
                for rec in digest.recommendations {
                    responseText += "• \(rec)\n"
                }
            }

            return HTTPResponse(
                statusCode: 200,
                body: [
                    "response": responseText,
                    "data": [
                        "summary": [
                            "totalDecisions": digest.summary.totalDecisions,
                            "decisionsExecuted": digest.summary.decisionsExecuted,
                            "decisionsPending": digest.summary.decisionsPending,
                            "newLearningsCount": digest.summary.newLearningsCount,
                            "followupsCreated": digest.summary.followupsCreated
                        ],
                        "commitmentStatus": [
                            "activeIOwe": digest.commitmentStatus.activeIOwe,
                            "activeTheyOwe": digest.commitmentStatus.activeTheyOwe,
                            "overdueCount": digest.commitmentStatus.overdueCount,
                            "upcomingThisWeek": digest.commitmentStatus.upcomingThisWeek
                        ],
                        "upcomingFollowups": digest.upcomingFollowups.map { [
                            "title": $0.title,
                            "scheduledFor": Self.iso8601Formatter.string(from: $0.scheduledFor),
                            "context": $0.context,
                            "isOverdue": $0.isOverdue
                        ] },
                        "recommendations": digest.recommendations
                    ]
                ]
            )
        } catch {
            return HTTPResponse(
                statusCode: 500,
                body: [
                    "error": "Failed to generate agent digest",
                    "details": error.localizedDescription
                ]
            )
        }
    }

    // MARK: - Interactive Extraction Handlers (for GUI approval flow)

    private func handleExtractCommitments(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            // Parse body
            let json = request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let contactName = json["contactName"] as? String
            let lookbackDays = json["lookbackDays"] as? Int ?? 14

            let items = try await alfredService.extractCommitmentsForReview(
                contactName: contactName,
                lookbackDays: lookbackDays
            )

            return HTTPResponse(
                statusCode: 200,
                body: [
                    "success": true,
                    "count": items.count,
                    "items": items.map { serializeExtractedItem($0) }
                ]
            )
        } catch {
            return HTTPResponse(
                statusCode: 500,
                body: ["error": error.localizedDescription]
            )
        }
    }

    private func handleExtractTodos(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            let json = request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let lookbackDays = json["lookbackDays"] as? Int ?? 7

            let items = try await alfredService.extractTodosForReview(lookbackDays: lookbackDays)

            return HTTPResponse(
                statusCode: 200,
                body: [
                    "success": true,
                    "count": items.count,
                    "items": items.map { serializeExtractedItem($0) }
                ]
            )
        } catch {
            return HTTPResponse(
                statusCode: 500,
                body: ["error": error.localizedDescription]
            )
        }
    }

    private func handleExtractFromThread(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            guard let bodyData = request.body,
                  let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
                  let contactName = json["contactName"] as? String else {
                return HTTPResponse(
                    statusCode: 400,
                    body: ["error": "Missing 'contactName' parameter"]
                )
            }

            let timeframe = json["timeframe"] as? String ?? "24h"

            let items = try await alfredService.extractItemsFromThread(
                contactName: contactName,
                timeframe: timeframe
            )

            return HTTPResponse(
                statusCode: 200,
                body: [
                    "success": true,
                    "count": items.count,
                    "contact": contactName,
                    "timeframe": timeframe,
                    "items": items.map { serializeExtractedItem($0) }
                ]
            )
        } catch {
            return HTTPResponse(
                statusCode: 500,
                body: ["error": error.localizedDescription]
            )
        }
    }

    private func handleApproveExtractedItems(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            guard let bodyData = request.body,
                  let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
                  let itemsArray = json["items"] as? [[String: Any]] else {
                return HTTPResponse(
                    statusCode: 400,
                    body: ["error": "Missing 'items' array in request body"]
                )
            }

            // Deserialize items back to ExtractedItem
            var items: [ExtractedItem] = []
            for itemDict in itemsArray {
                if let item = deserializeExtractedItem(itemDict) {
                    items.append(item)
                }
            }

            if items.isEmpty {
                return HTTPResponse(
                    statusCode: 400,
                    body: ["error": "No valid items to save"]
                )
            }

            // Record scan feedback for learning (approved items)
            let learningService = WorkflowLearningService.shared
            for item in items {
                learningService.recordScanFeedback(
                    threadId: item.source.threadId ?? item.source.contact,
                    threadName: item.source.threadName ?? item.source.contact,
                    platform: item.source.platform.rawValue,
                    itemType: item.type.rawValue,
                    accepted: true,
                    edited: false,
                    originalTitle: item.title,
                    editedTitle: nil
                )
            }

            // Also record rejections if provided in request
            if let rejectedArray = json["rejected"] as? [[String: Any]] {
                for rejectedDict in rejectedArray {
                    if let sourceDict = rejectedDict["source"] as? [String: Any],
                       let contact = sourceDict["contact"] as? String,
                       let platformStr = sourceDict["platform"] as? String,
                       let typeStr = rejectedDict["type"] as? String {
                        learningService.recordScanFeedback(
                            threadId: sourceDict["threadId"] as? String ?? contact,
                            threadName: sourceDict["threadName"] as? String ?? contact,
                            platform: platformStr,
                            itemType: typeStr,
                            accepted: false
                        )
                    }
                }
            }

            let (saved, failed, duplicates) = try await alfredService.saveApprovedItems(items)

            return HTTPResponse(
                statusCode: 200,
                body: [
                    "success": true,
                    "saved": saved,
                    "failed": failed,
                    "duplicates": duplicates,
                    "message": "Successfully saved \(saved) item(s) to Notion"
                ]
            )
        } catch {
            return HTTPResponse(
                statusCode: 500,
                body: ["error": error.localizedDescription]
            )
        }
    }

    private func serializeExtractedItem(_ item: ExtractedItem) -> [String: Any] {
        var dict: [String: Any] = [
            "id": item.id.uuidString,
            "type": item.type.rawValue,
            "title": item.title,
            "priority": item.priority.rawValue,
            "uniqueHash": item.uniqueHash,
            "source": [
                "platform": item.source.platform.rawValue,
                "contact": item.source.contact,
                "threadName": item.source.threadName as Any,
                "threadId": item.source.threadId as Any
            ]
        ]

        if let desc = item.description {
            dict["description"] = desc
        }
        if let dueDate = item.dueDate {
            dict["dueDate"] = Self.iso8601Formatter.string(from: dueDate)
        }
        if let direction = item.commitmentDirection {
            dict["commitmentDirection"] = direction.rawValue
        }
        if let by = item.committedBy {
            dict["committedBy"] = by
        }
        if let to = item.committedTo {
            dict["committedTo"] = to
        }
        if let context = item.originalContext {
            dict["originalContext"] = context
        }

        return dict
    }

    private func deserializeExtractedItem(_ dict: [String: Any]) -> ExtractedItem? {
        guard let typeStr = dict["type"] as? String,
              let type = ExtractedItem.ItemType(rawValue: typeStr),
              let title = dict["title"] as? String,
              let priorityStr = dict["priority"] as? String,
              let priority = ExtractedItem.ItemPriority(rawValue: priorityStr),
              let sourceDict = dict["source"] as? [String: Any],
              let platformStr = sourceDict["platform"] as? String,
              let platform = ExtractedItem.ItemSource.SourcePlatform(rawValue: platformStr),
              let contact = sourceDict["contact"] as? String else {
            return nil
        }

        let uniqueHash = dict["uniqueHash"] as? String ?? UUID().uuidString

        var direction: ExtractedItem.CommitmentDirection?
        if let dirStr = dict["commitmentDirection"] as? String {
            direction = ExtractedItem.CommitmentDirection(rawValue: dirStr)
        }

        var dueDate: Date?
        if let dueDateStr = dict["dueDate"] as? String {
            dueDate = Self.iso8601Formatter.date(from: dueDateStr)
        }

        return ExtractedItem(
            type: type,
            title: title,
            description: dict["description"] as? String,
            priority: priority,
            source: ExtractedItem.ItemSource(
                platform: platform,
                contact: contact,
                threadName: sourceDict["threadName"] as? String,
                threadId: sourceDict["threadId"] as? String
            ),
            dueDate: dueDate,
            commitmentDirection: direction,
            committedBy: dict["committedBy"] as? String,
            committedTo: dict["committedTo"] as? String,
            originalContext: dict["originalContext"] as? String,
            uniqueHash: uniqueHash
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
            guard let config = getConfig() else {
                return HTTPResponse(
                    statusCode: 500,
                    body: ["error": "Configuration not loaded"]
                )
            }

            // Access orchestrator directly (no longer needs MainActor)
            guard let orchestrator = alfredService.orchestrator else {
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

            // Execute intent (pass raw user query for keyword matching)
            let result = try await executor.execute(intentResponse.intent, rawQuery: query)

            // Record turn in shared conversation context
            ConversationContext.shared.addTurn(
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

    // MARK: - Chat Streaming

    private func handleChatStream(_ request: HTTPRequest, client: ClientSocket) async {
        client.beginSSE()

        guard let query = request.queryParams["q"], !query.isEmpty else {
            client.sendSSEJSON(event: "error", json: ["error": "Missing 'q' parameter"])
            client.endSSE()
            return
        }

        let sessionId = request.queryParams["sessionId"] ?? "default"

        guard let config = getConfig() else {
            client.sendSSEJSON(event: "error", json: ["error": "Configuration not loaded"])
            client.endSSE()
            return
        }

        // Build rich coaching system prompt
        let userName = config.user.name.isEmpty ? "User" : config.user.name
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a"
        let now = dateFormatter.string(from: Date())

        // Ensure coaching engine exists for cached card reads (lazy init — doesn't generate cards)
        if coachingEngine == nil {
            coachingEngine = CoachingEngine(config: config, alfredService: alfredService)
        }

        // Gather base context for coaching prompt
        // Fast/cached calls — keep sequential
        let coachingContext = CoachingMemoryService.shared.getCoachingContext()
        let agentMemoryRules = gatherAgentMemoryRules()
        let coachingInsights = gatherAllCoachingInsights()
        let unifiedFollowups = gatherUnifiedFollowups()
        // Expensive calls — run in parallel
        async let liveContextTask = gatherLiveContext(config: config)
        async let relationshipTask = Task { self.gatherRelationshipData(config: config) }.value

        let liveContext = await liveContextTask
        let relationshipData = await relationshipTask

        // On-demand: detailed commitments + messages (only when topic/person is relevant)
        let knownContacts = getKnownContactNames()
        let (needsCommitments, needsMessages, mentionedPerson) = ChatContextRouter.detectContext(
            query: query, knownContacts: knownContacts
        )
        let detailedCommitments = needsCommitments
            ? gatherDetailedCommitments(mentionedPerson: mentionedPerson)
            : ""

        // On-demand: actual messages with mentioned person (for commitment verification)
        var recentMessages = ""
        if needsMessages, let person = mentionedPerson {
            recentMessages = await gatherRecentMessages(for: person, config: config)
        }

        let currentTrustLevel = TrustStateService.shared.getCurrentLevel()
        let reflectionContext = ReflectionStore.shared.getFormattedContextForCoaching(maxChars: 1200)
        let systemPrompt = CoachingPromptBuilder.build(
            userName: userName,
            dateTime: now,
            coachingContext: coachingContext,
            agentMemoryRules: agentMemoryRules,
            liveContext: liveContext,
            relationshipData: relationshipData,
            coachingInsights: coachingInsights,
            detailedCommitments: detailedCommitments,
            recentMessages: recentMessages,
            unifiedFollowups: unifiedFollowups,
            trustLevel: currentTrustLevel,
            mentionedContact: mentionedPerson,
            reflectionContext: reflectionContext
        )

        // Use shared conversation context (persists across requests for same session)
        let sharedContext = ConversationContext.shared

        // Try intent recognition first for structured queries
        let intentService = IntentRecognitionService(config: config, conversationContext: sharedContext)
        do {
            let intentResponse = try await intentService.recognizeIntent(query, sessionId: sessionId)

            // If clarification needed, stream it as a question back to the user
            if intentResponse.clarificationNeeded, let question = intentResponse.clarificationQuestion {
                // Record the clarification exchange so follow-up messages have context
                sharedContext.addTurn(sessionId: sessionId, query: query, intent: intentResponse.intent, result: nil)
                ConversationHistoryService.shared.addTurn(sessionId: sessionId, role: "user", content: query)
                ConversationHistoryService.shared.addTurn(sessionId: sessionId, role: "assistant", content: question)

                client.sendSSEJSON(event: "chunk", json: ["text": question])
                client.sendSSEJSON(event: "done", json: ["sessionId": sessionId])
                client.endSSE()
                return
            }

            // If high confidence structured intent, execute it and stream the result
            if intentResponse.intent.confidence > 0.8 {
                if let orchestrator = alfredService.orchestrator {
                    let toolName = intentResponse.intent.target?.rawValue ?? "unknown"

                    // Emit tool_start so frontend can show a loading indicator
                    client.sendSSEJSON(event: "tool_start", json: [
                        "tool": toolName,
                        "query": query
                    ])

                    let executor = IntentExecutor(orchestrator: orchestrator, config: config)
                    let result = try await executor.execute(intentResponse.intent, rawQuery: query)

                    // Record the turn in shared context
                    sharedContext.addTurn(sessionId: sessionId, query: query, intent: intentResponse.intent, result: result)

                    // Emit tool_result with structured data for rich rendering
                    var structuredPayload = serializeToolResult(toolName: toolName, data: result.data)
                    // Merge any extra metadata from structuredData (e.g. needsFollowUp, unresolvedAttendees)
                    if let extra = result.structuredData {
                        for (key, value) in extra {
                            if structuredPayload[key] == nil {
                                structuredPayload[key] = value
                            }
                        }
                    }
                    client.sendSSEJSON(event: "tool_result", json: structuredPayload)

                    let dataSummary = result.conversationalResponse
                    var fullCoachingResponse = ""

                    // For successful create actions, the card has all the info — no text response needed
                    // For update/delete actions, stream the confirmation directly (no coaching overlay)
                    // For check actions (availability, status checks), stream the answer directly — benign queries don't need coaching
                    // Exception: if needsFollowUp is set (e.g. unresolved attendees), stream the text
                    let wasRendered = structuredPayload["rendered"] as? Bool != false
                    let needsFollowUp = structuredPayload["needsFollowUp"] as? Bool == true
                    let skipCoaching = (intentResponse.intent.action == .create && wasRendered && !needsFollowUp) || intentResponse.intent.action == .update || intentResponse.intent.action == .check || intentResponse.intent.action == .delete

                    if intentResponse.intent.action == .create && wasRendered && !needsFollowUp {
                        // Card-only — no text streamed, just record internally
                        fullCoachingResponse = dataSummary
                    } else if skipCoaching || (intentResponse.intent.action == .create && !wasRendered) {
                        // Stream the conversationalResponse directly as chunks
                        let words = dataSummary.split(separator: " ", omittingEmptySubsequences: false)
                        var chunk = ""
                        var isFirstChunk = true
                        for (i, word) in words.enumerated() {
                            chunk += (chunk.isEmpty ? "" : " ") + word
                            if chunk.count > 20 || i == words.count - 1 {
                                let textToSend = isFirstChunk ? chunk : " " + chunk
                                client.sendSSEJSON(event: "chunk", json: ["text": textToSend])
                                fullCoachingResponse += textToSend
                                chunk = ""
                                isFirstChunk = false
                                try? await Task.sleep(nanoseconds: 15_000_000)
                            }
                        }
                    } else {
                        // Stream a coaching-flavored response through Claude
                        // The tool card already shows the raw data — Claude adds the coaching insight
                        // Route coaching posture based on intent (reflection vs prioritization vs etc.)
                        let posture = IntentCoachingRouter.posture(
                            for: intentResponse.intent.action,
                            target: intentResponse.intent.target
                        )
                        // v2: Pull tenets from TenetPackLoader (scope-based), fallback to legacy skill tenets
                        var relevantTenets = IntentCoachingRouter.relevantTenetsForPosture(posture)
                        if relevantTenets.isEmpty {
                            // Fallback: legacy skill-based tenets
                            let relevantSkillIds = IntentCoachingRouter.relevantSkillIds(for: posture)
                            relevantTenets = SkillLoader.shared.getEnabledSkills()
                                .filter { relevantSkillIds.contains($0.id) }
                                .map { "[\($0.effectiveName)]: \($0.tenets)" }
                                .joined(separator: "\n")
                        }

                        let coachingOverlayPrompt = IntentCoachingRouter.buildCoachingOverlay(
                            posture: posture,
                            query: query,
                            toolName: toolName,
                            dataSummary: dataSummary,
                            relevantTenets: relevantTenets
                        )

                        let claudeService = ClaudeAIService(config: config.ai)

                        do {
                            // Build messages with conversation history for context
                            var coachingMessages = sharedContext.getMessagesArray(for: sessionId, limit: 10)
                            coachingMessages.append(["role": "user", "content": coachingOverlayPrompt])

                            try await claudeService.streamChat(
                                messages: coachingMessages,
                                system: systemPrompt,
                                maxTokens: 1024,
                                useModel: config.ai.effectiveCoachingModel,
                                onChunk: { text in
                                    fullCoachingResponse += text
                                    client.sendSSEJSON(event: "chunk", json: ["text": text])
                                }
                            )
                        } catch {
                            // Fallback to static response if Claude fails
                            let words = dataSummary.split(separator: " ", omittingEmptySubsequences: false)
                            var chunk = ""
                            var isFirstChunk = true
                            for (i, word) in words.enumerated() {
                                chunk += (chunk.isEmpty ? "" : " ") + word
                                if chunk.count > 20 || i == words.count - 1 {
                                    let textToSend = isFirstChunk ? chunk : " " + chunk
                                    client.sendSSEJSON(event: "chunk", json: ["text": textToSend])
                                    fullCoachingResponse += textToSend
                                    chunk = ""
                                    isFirstChunk = false
                                    try? await Task.sleep(nanoseconds: 15_000_000)
                                }
                            }
                        }
                    }

                    // Record the response
                    let finalResponse = fullCoachingResponse.isEmpty ? dataSummary : fullCoachingResponse

                    // Fire-and-forget: update coaching memory for intent-based exchanges too
                    let intentQuery = query
                    let intentResponseText = finalResponse
                    let intentConfig = config
                    Task {
                        await self.updateCoachingMemoryIfNeeded(
                            userMessage: intentQuery,
                            assistantResponse: intentResponseText,
                            config: intentConfig
                        )
                    }

                    // Learning v3: Record signals from this exchange (hybrid keyword + LLM)
                    WorkflowLearningService.shared.detectAndRecordCorrections(
                        userMessage: query,
                        assistantResponse: finalResponse,
                        config: config
                    )

                    // Persist turns to conversation history
                    ConversationHistoryService.shared.addTurn(sessionId: sessionId, role: "user", content: query)
                    ConversationHistoryService.shared.addTurn(sessionId: sessionId, role: "assistant", content: finalResponse)

                    // Increment trust turns counter (persisted to disk)
                    TrustStateService.shared.incrementTurns()

                    let trustLevel = TrustStateService.shared.getCurrentLevel()
                    client.sendSSEJSON(event: "done", json: [
                        "sessionId": sessionId,
                        "trustLevel": trustLevel.rawValue
                    ])
                    client.endSSE()
                    return
                }
            }
        } catch let error as MessageReaderError {
            // Check for "did you mean?" suggestions — surface them as a special SSE event
            if case .didYouMean(let original, let suggestions) = error {
                print("💡 Chat: surfacing 'did you mean?' for '\(original)': \(suggestions)")
                client.sendSSEJSON(event: "did_you_mean", json: [
                    "original": original,
                    "suggestions": suggestions
                ])
                client.sendSSEJSON(event: "done", json: ["sessionId": sessionId])
                client.endSSE()
                return
            }
            // Other MessageReaderErrors fall through to general chat
            print("⚠️ Intent execution failed with message reader error, falling back to general chat: \(error)")
        } catch {
            // Intent recognition failed, fall through to general chat
            print("⚠️ Intent recognition failed, falling back to general chat: \(error)")
        }

        // General chat: stream from Claude WITH full conversation history
        // Carry forward coaching posture from recent intent-matched turns (10-min window)
        let recentTurns = sharedContext.getRecentContext(for: sessionId, limit: 3)
        let activePosture: CoachingPosture
        if let lastIntentTurn = recentTurns.last(where: { $0.intent != nil }),
           let action = lastIntentTurn.intent?.action,
           let target = lastIntentTurn.intent?.target,
           Date().timeIntervalSince(lastIntentTurn.timestamp) < 600 {
            activePosture = IntentCoachingRouter.posture(for: action, target: target)
        } else {
            activePosture = .general
        }

        // Rebuild system prompt with posture awareness if we have an active posture
        let chatSystemPrompt: String
        if activePosture != .general && activePosture != .operational {
            chatSystemPrompt = CoachingPromptBuilder.build(
                userName: userName,
                dateTime: now,
                coachingContext: coachingContext,
                agentMemoryRules: agentMemoryRules,
                liveContext: liveContext,
                relationshipData: relationshipData,
                coachingInsights: coachingInsights,
                detailedCommitments: detailedCommitments,
                recentMessages: recentMessages,
                unifiedFollowups: unifiedFollowups,
                activePosture: activePosture,
                trustLevel: currentTrustLevel,
                reflectionContext: reflectionContext
            )
        } else {
            chatSystemPrompt = systemPrompt
        }

        let claudeService = ClaudeAIService(config: config.ai)
        do {
            // Build messages array from conversation history + current query
            var messages = sharedContext.getMessagesArray(for: sessionId, limit: 20)

            // Prepend posture hint if continuing a themed conversation
            if activePosture != .general && activePosture != .operational {
                let hint = IntentCoachingRouter.followUpHint(for: activePosture)
                messages.append(["role": "user", "content": hint + "\n\n" + query])
            } else {
                messages.append(["role": "user", "content": query])
            }

            // Collect the full response for recording back into context
            var fullResponse = ""

            try await claudeService.streamChat(
                messages: messages,
                system: chatSystemPrompt,
                maxTokens: 2048,
                useModel: config.ai.effectiveCoachingModel,
                onChunk: { text in
                    fullResponse += text
                    client.sendSSEJSON(event: "chunk", json: ["text": text])
                }
            )

            // Record this turn so future messages have context
            sharedContext.addChatTurn(sessionId: sessionId, userMessage: query, assistantResponse: fullResponse)

            // Persist turns to conversation history
            ConversationHistoryService.shared.addTurn(sessionId: sessionId, role: "user", content: query)
            ConversationHistoryService.shared.addTurn(sessionId: sessionId, role: "assistant", content: fullResponse)

            // Increment trust turns counter (persisted to disk)
            TrustStateService.shared.incrementTurns()

            // Fire-and-forget: update coaching memory if this was a coaching exchange
            let capturedQuery = query
            let capturedResponse = fullResponse
            let capturedConfig = config
            Task {
                await self.updateCoachingMemoryIfNeeded(
                    userMessage: capturedQuery,
                    assistantResponse: capturedResponse,
                    config: capturedConfig
                )
            }

            // Learning v3: Record signals from this exchange (hybrid keyword + LLM)
            WorkflowLearningService.shared.detectAndRecordCorrections(
                userMessage: query,
                assistantResponse: fullResponse,
                config: config
            )

            let trustLevelFinal = TrustStateService.shared.getCurrentLevel()
            client.sendSSEJSON(event: "done", json: [
                "sessionId": sessionId,
                "trustLevel": trustLevelFinal.rawValue
            ])
        } catch {
            client.sendSSEJSON(event: "error", json: ["error": "Failed to generate response: \(error.localizedDescription)"])
        }

        client.endSSE()
    }

    // MARK: - Reflect Mode (anchored, generative reflection on a self-model facet)

    /// Streams a reflective conversation anchored to one self-model facet. Grounded in
    /// the user's self-model, but with a distinct *listening* posture — it asks, reflects
    /// back, and helps the user reach their own conclusion (which they can then mint as a
    /// belief). Reuses the general-chat streaming path minus intent/tool execution.
    private func handleReflectStream(_ request: HTTPRequest, client: ClientSocket) async {
        client.beginSSE()

        guard getConfig()?.features?.selfModel ?? false else {
            client.sendSSEJSON(event: "error", json: ["error": "Self-model is off"]); client.endSSE(); return
        }
        guard let config = getConfig() else {
            client.sendSSEJSON(event: "error", json: ["error": "Configuration not loaded"]); client.endSSE(); return
        }
        guard let facetId = request.queryParams["facetId"],
              let facet = SelfModelStore.shared.getFacet(id: facetId) else {
            client.sendSSEJSON(event: "error", json: ["error": "Facet not found"]); client.endSSE(); return
        }

        let kind = (facet["kind"] as? String) ?? "thing"
        let statement = (facet["statement"] as? String) ?? ""
        let kindWord = kind == "question" ? "open question" : kind
        var anchorDetail = ""
        if kind == "belief", let traj = facet["trajectory"] as? [[String: String]], let first = traj.first,
           let from = first["from"], !from.isEmpty {
            anchorDetail = " (it evolved from an earlier view: \"\(from)\")"
        }

        // Lighter, reflection-focused grounding — skip the operational live/relationship/
        // commitment gathering (not needed to think, and expensive). Use the richer
        // reflection context built specifically for this posture.
        let userName = config.user.name.isEmpty ? "User" : config.user.name
        let df = DateFormatter(); df.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a"
        let now = df.string(from: Date())
        let coachingContext = CoachingMemoryService.shared.getCoachingContext()
        let agentMemoryRules = gatherAgentMemoryRules()
        let reflectionContext = ReflectionStore.shared.getExtendedContextForReflection(maxChars: 2400)

        let base = CoachingPromptBuilder.build(
            userName: userName,
            dateTime: now,
            coachingContext: coachingContext,
            agentMemoryRules: agentMemoryRules,
            liveContext: "",
            relationshipData: "",
            trustLevel: TrustStateService.shared.getCurrentLevel(),
            reflectionContext: reflectionContext
        )

        let reflectDirective = """


        ## Reflection mode — you are thinking WITH \(userName), not advising them
        \(userName) has opened a reflection on this \(kindWord): "\(statement)"\(anchorDetail)

        This is not a task or a Q&A. It is thinking out loud. Your job:
        - LISTEN more than you talk. Ask ONE good, specific question at a time, then stop and let them think.
        - Reflect back what you actually hear — name the tension, the pattern, or the thing they keep circling.
        - Do NOT lecture, give advice, or list options unless they explicitly ask. No bullet points, no headers.
        - Draw on what you already know about them (above), but reference it lightly — don't recite it.
        - Keep every reply short: 2–4 sentences. Leave room for them to think.
        - When they arrive at something that sounds like a conclusion, reflect it back as ONE clean sentence they could keep as a belief.

        To open: name in one line what you notice about this \(kindWord), then ask one inviting question. Nothing more.
        """
        let systemPrompt = base + reflectDirective

        // Messages: synthetic anchor turn → prior visible history → current user turn.
        var messages: [[String: String]] = [["role": "user", "content": "Let's reflect on this \(kindWord): \"\(statement)\"."]]
        if let historyRaw = request.queryParams["history"]?.removingPercentEncoding,
           let data = historyRaw.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
            messages.append(contentsOf: arr.suffix(12))
        }
        if let q = request.queryParams["q"]?.removingPercentEncoding, !q.isEmpty {
            // avoid two consecutive user turns if history already ends with one
            if messages.last?["role"] == "user" && messages.count > 1 {
                messages.append(["role": "assistant", "content": "…"])
            }
            messages.append(["role": "user", "content": q])
        }

        let claude = ClaudeAIService(config: config.ai)
        do {
            try await claude.streamChat(
                messages: messages,
                system: systemPrompt,
                maxTokens: 700,
                useModel: config.ai.effectiveCoachingModel,
                onChunk: { text in client.sendSSEJSON(event: "chunk", json: ["text": text]) }
            )
            client.sendSSEJSON(event: "done", json: ["facetId": facetId])
        } catch {
            client.sendSSEJSON(event: "error", json: ["error": "Reflection failed: \(error.localizedDescription)"])
        }
        client.endSSE()
    }

    // MARK: - Coaching Endpoint Handlers

    /// Returns the current trust state
    private func handleTrustState() -> HTTPResponse {
        let state = TrustStateService.shared.loadState()
        let effectiveLevel = TrustStateService.shared.getCurrentLevel()
        let dateFormatter = ISO8601DateFormatter()
        return HTTPResponse(statusCode: 200, body: [
            "level": effectiveLevel.rawValue,
            "displayName": effectiveLevel.displayName,
            "storedLevel": state.level.rawValue,
            "totalSessions": state.totalSessions,
            "totalTurns": state.totalTurns,
            "resolvedThemes": state.resolvedThemes,
            "levelSince": dateFormatter.string(from: state.levelSince),
            "lastComputedAt": dateFormatter.string(from: state.lastComputedAt),
            "oldestSessionDate": state.oldestSessionDate.map { dateFormatter.string(from: $0) } as Any,
            "thresholds": [
                "developing": "5 sessions, 7 days, 1 resolved theme",
                "established": "20 sessions, 30 days, 3 resolved themes, 50 turns",
                "deep": "50 sessions, 90 days, 5 resolved themes, 150 turns"
            ]
        ])
    }

    /// Returns the raw coaching context file contents
    private func handleCoachingContext() -> HTTPResponse {
        let context = CoachingMemoryService.shared.getCoachingContext()
        return HTTPResponse(statusCode: 200, body: ["context": context])
    }

    /// Returns debug info: each coaching card with the context data that drove it
    // MARK: - Streaming Coaching Cards

    private func handleStreamingCoachingCards(_ request: HTTPRequest, client: ClientSocket) async {
        client.beginSSE()

        guard let config = getConfig() else {
            client.sendSSEJSON(event: "error", json: ["error": "Configuration not loaded"])
            client.endSSE()
            return
        }

        if coachingEngine == nil {
            coachingEngine = CoachingEngine(config: config, alfredService: alfredService)
        }

        guard let engine = coachingEngine else {
            client.sendSSEJSON(event: "error", json: ["error": "Coaching engine unavailable"])
            client.endSSE()
            return
        }

        let forceRefresh = request.queryParams["force"] == "true"
        let isoFormatter = Self.iso8601Formatter

        // Warm engine's in-memory cache from disk cache (survives restarts)
        if !forceRefresh && engine.cachedCards == nil,
           let diskCached = cache.getCached(endpoint: "/api/coaching/cards"),
           let data = diskCached.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cardsArray = json["cards"] as? [[String: Any]] {
            let restoredCards = cardsArray.compactMap { dict -> CoachingEngine.CoachingCard? in
                guard let type = dict["type"] as? String,
                      let label = dict["label"] as? String,
                      let insight = dict["insight"] as? String else { return nil }
                return CoachingEngine.CoachingCard(type: type, label: label, insight: insight, context: dict["context"] as? String)
            }
            if !restoredCards.isEmpty {
                engine.restoreFromDiskCache(restoredCards)
            }
        }

        // Emit skill manifest first so frontend knows how many cards to expect
        let allSkills = SkillLoader.shared.getEnabledSkills().filter { $0.origin == .installed || $0.frequency == "daily" }
        let skillManifest: [[String: String]] = allSkills.map { ["id": $0.id, "label": "\($0.icon) \($0.effectiveName)"] }
        client.sendSSEJSON(event: "manifest", json: ["skills": skillManifest, "force": forceRefresh])

        var cardCount = 0

        do {
            try await engine.streamCoachingCards(forceRefresh: forceRefresh) { card, result in
                cardCount += 1
                var cardJson: [String: Any] = [
                    "type": card.type,
                    "label": card.label,
                    "insight": card.insight,
                    "status": result.status,
                    "generatedAt": isoFormatter.string(from: result.generatedAt)
                ]
                if let error = result.error {
                    cardJson["error"] = error
                }
                client.sendSSEJSON(event: "card", json: cardJson)
            }
        } catch {
            client.sendSSEJSON(event: "error", json: ["error": "Card generation failed: \(error.localizedDescription)"])
        }

        // Final done event
        var doneJson: [String: Any] = ["totalCards": cardCount]
        if let generatedAt = engine.lastGeneratedAt {
            doneJson["generatedAt"] = isoFormatter.string(from: generatedAt)
        }
        client.sendSSEJSON(event: "done", json: doneJson)
        client.endSSE()
    }

    private func handleCoachingDebug(_ request: HTTPRequest) async -> HTTPResponse {
        guard let config = getConfig() else {
            return HTTPResponse(statusCode: 500, body: ["error": "Configuration not loaded"])
        }

        // Ensure coaching engine exists (reuse or create)
        if coachingEngine == nil {
            coachingEngine = CoachingEngine(config: config, alfredService: alfredService)
        }

        guard let engine = coachingEngine else {
            return HTTPResponse(statusCode: 500, body: ["error": "Coaching engine unavailable"])
        }

        // Check if caller wants to force-refresh (bust the 2h cache)
        let forceRefresh = request.queryParams["force"] == "true"

        // Generate cards (uses 2h cache unless force-refreshed)
        let cards: [CoachingEngine.CoachingCard]
        do {
            cards = try await engine.generateCoachingCards(forceRefresh: forceRefresh)
        } catch {
            return HTTPResponse(statusCode: 500, body: ["error": "Failed to generate cards: \(error.localizedDescription)"])
        }

        // Build debug response with per-card context and skill run results
        let isoFormatter = Self.iso8601Formatter
        let relativeFormatter = RelativeDateTimeFormatter()
        relativeFormatter.unitsStyle = .full

        let debugCards: [[String: Any]] = cards.map { card in
            var entry: [String: Any] = [
                "type": card.type,
                "label": card.label,
                "insight": card.insight
            ]
            // Attach context and status from skill run results (fixed: was "skill_\(id)" key, now matches card.type)
            if let result = engine.lastSkillResults[card.type] {
                entry["context"] = result.context
                entry["status"] = result.status
                entry["generatedAt"] = isoFormatter.string(from: result.generatedAt)
                entry["generatedAgo"] = relativeFormatter.localizedString(for: result.generatedAt, relativeTo: Date())
                if let error = result.error {
                    entry["error"] = error
                }
            } else if let ctx = engine.lastDebugContext[card.type] {
                // Fallback to old debug context (backward compat)
                entry["context"] = ctx
                entry["status"] = "success"
            }
            return entry
        }

        // Also include skills that ran but produced no card (no_context, error)
        let cardTypes = Set(cards.map { $0.type })
        let failedSkills: [[String: Any]] = engine.lastSkillResults.compactMap { (skillId, result) in
            guard !cardTypes.contains(skillId) else { return nil }
            var entry: [String: Any] = [
                "type": skillId,
                "status": result.status,
                "generatedAt": isoFormatter.string(from: result.generatedAt),
                "generatedAgo": relativeFormatter.localizedString(for: result.generatedAt, relativeTo: Date())
            ]
            // Try to get label from skill definition
            if let skill = SkillLoader.shared.getSkill(id: skillId) {
                entry["label"] = "\(skill.icon) \(skill.effectiveName)"
            }
            if let error = result.error {
                entry["error"] = error
            }
            return entry
        }

        var response: [String: Any] = ["cards": debugCards + failedSkills]

        // Cache age
        if let generatedAt = engine.lastGeneratedAt {
            response["generatedAt"] = isoFormatter.string(from: generatedAt)
            response["cacheAge"] = relativeFormatter.localizedString(for: generatedAt, relativeTo: Date())
        }

        return HTTPResponse(statusCode: 200, body: response)
    }

    /// Returns the coaching tenets content + Notion URL for editing
    private func handleGetCoachingTenets() -> HTTPResponse {
        let tenetsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".alfred/coaching_tenets.md").path

        let content: String
        if let fileContent = try? String(contentsOfFile: tenetsPath, encoding: .utf8) {
            content = fileContent
        } else {
            content = CoachingPromptBuilder.defaultTenets
        }

        var response: [String: Any] = ["content": content]

        // Include Notion URL if configured
        if let config = getConfig(),
           let pageId = config.notion.tenetsPageId, !pageId.isEmpty {
            response["notionUrl"] = "https://www.notion.so/\(pageId.replacingOccurrences(of: "-", with: ""))"
            response["notionPageId"] = pageId
        }

        return HTTPResponse(statusCode: 200, body: response)
    }

    /// Saves updated coaching tenets to disk and busts Notion cache
    private func handlePutCoachingTenets(_ request: HTTPRequest) -> HTTPResponse {
        guard let body = request.body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let content = json["content"] as? String else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'content' in request body"])
        }

        let tenetsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".alfred/coaching_tenets.md").path

        do {
            try content.write(toFile: tenetsPath, atomically: true, encoding: .utf8)
            // Bust the Notion cache so next coaching prompt picks up local changes
            CoachingPromptBuilder.invalidateNotionTenetsCache()
            return HTTPResponse(statusCode: 200, body: ["saved": true])
        } catch {
            return HTTPResponse(statusCode: 500, body: ["error": "Failed to save: \(error.localizedDescription)"])
        }
    }

    // MARK: - Tenets Sections Handlers

    /// Returns parsed tenet sections with toggle states
    private func handleGetTenetSections() -> HTTPResponse {
        let sections = CoachingPromptBuilder.getTenetSectionsWithState()
        let sectionDicts: [[String: Any]] = sections.map { section in
            [
                "id": section.id,
                "title": section.title,
                "content": section.content,
                "enabled": section.enabled
            ]
        }

        var response: [String: Any] = ["sections": sectionDicts]

        // Include Notion URL if configured
        if let config = getConfig(),
           let pageId = config.notion.tenetsPageId, !pageId.isEmpty {
            response["notionUrl"] = "https://www.notion.so/\(pageId.replacingOccurrences(of: "-", with: ""))"
        }

        return HTTPResponse(statusCode: 200, body: response)
    }

    /// Toggle a tenet section on/off
    private func handleToggleTenetSection(_ request: HTTPRequest) -> HTTPResponse {
        guard let body = request.body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let sectionId = json["id"] as? String else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'id' in request body"])
        }

        let enabled: Bool
        if let explicitEnabled = json["enabled"] as? Bool {
            enabled = explicitEnabled
        } else {
            // Toggle: read current state and invert
            let currentState = CoachingPromptBuilder.loadTenetsToggleState()
            enabled = !(currentState[sectionId] ?? true)
        }

        // Save updated state
        var state = CoachingPromptBuilder.loadTenetsToggleState()
        state[sectionId] = enabled
        CoachingPromptBuilder.saveTenetsToggleState(state)

        // Bust caches so coaching prompt reflects the change
        CoachingPromptBuilder.invalidateNotionTenetsCache()
        coachingEngine = nil
        invalidateMemoryCache("coaching_cards")
        cache.deleteByEndpoint("/api/coaching/cards")

        return HTTPResponse(statusCode: 200, body: ["id": sectionId, "enabled": enabled])
    }

    // MARK: - Single Skill Refresh Handler

    /// Refresh a single skill's coaching card via live LLM call
    private func handleRefreshSingleSkill(_ request: HTTPRequest) async -> HTTPResponse {
        guard let skillId = request.queryParams["skill"], !skillId.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'skill' query parameter"])
        }

        guard let config = getConfig() else {
            return HTTPResponse(statusCode: 500, body: ["error": "Configuration not loaded"])
        }

        // Ensure coaching engine exists
        if coachingEngine == nil {
            coachingEngine = CoachingEngine(config: config, alfredService: alfredService)
        }

        guard let engine = coachingEngine else {
            return HTTPResponse(statusCode: 500, body: ["error": "Coaching engine unavailable"])
        }

        guard let result = await engine.refreshSingleSkill(id: skillId) else {
            return HTTPResponse(statusCode: 404, body: ["error": "Skill not found: \(skillId)"])
        }

        var response: [String: Any] = [
            "skillId": skillId,
            "status": result.status,
            "generatedAt": ISO8601DateFormatter().string(from: result.generatedAt)
        ]

        if let card = result.card {
            response["card"] = [
                "type": card.type,
                "label": card.label,
                "insight": card.insight
            ]
        }

        if !result.context.isEmpty {
            response["context"] = result.context
        }

        if let error = result.error {
            response["error"] = error
        }

        return HTTPResponse(statusCode: 200, body: response)
    }

    private func handleCoachingFeedback(_ request: HTTPRequest) -> HTTPResponse {
        let body = request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]

        guard let cardType = body["cardType"] as? String, !cardType.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'cardType' field"])
        }
        guard let feedback = body["feedback"] as? String, ["thumbs_up", "thumbs_down"].contains(feedback) else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing or invalid 'feedback' field (thumbs_up or thumbs_down)"])
        }

        let reason = body["reason"] as? String  // "not_accurate", "already_handled", "not_helpful"
        let cardInsight = body["insight"] as? String ?? ""

        // Build feedback entry
        let entry: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "cardType": cardType,
            "feedback": feedback,
            "reason": reason as Any,
            "insight": String(cardInsight.prefix(200)),
            "context": coachingEngine?.lastSkillResults[cardType]?.context.prefix(20).joined(separator: "\n") ?? ""
        ]

        // Append to feedback log (JSONL format)
        let alfredDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".alfred").path
        let feedbackPath = "\(alfredDir)/nudge_feedback.jsonl"

        if let data = try? JSONSerialization.data(withJSONObject: entry),
           let line = String(data: data, encoding: .utf8) {
            let appendLine = line + "\n"
            if FileManager.default.fileExists(atPath: feedbackPath) {
                if let handle = FileHandle(forWritingAtPath: feedbackPath) {
                    handle.seekToEndOfFile()
                    handle.write(appendLine.data(using: .utf8)!)
                    handle.closeFile()
                }
            } else {
                try? appendLine.write(toFile: feedbackPath, atomically: true, encoding: .utf8)
            }
        }

        print("[Coaching] Feedback recorded: \(feedback) for \(cardType)\(reason.map { " (\($0))" } ?? "")")

        return HTTPResponse(statusCode: 200, body: ["success": true, "message": "Feedback recorded"])
    }

    // MARK: - Skill Library Handlers

    /// Returns the library catalog with install status, including already-installed skills
    private func handleGetSkillLibrary() -> HTTPResponse {
        let templates = SkillLibrary.catalog
        let existingSkills = SkillLoader.shared.loadSkills()
        let existingIds = Set(existingSkills.map { $0.id })
        let templateIds = Set(templates.map { $0.id })

        // Library templates with install status
        var allDicts: [[String: Any]] = templates.map { template in
            [
                "id": template.id,
                "name": template.name,
                "description": template.description,
                "icon": template.icon,
                "author": template.author,
                "dataSources": template.dataSources,
                "frequency": template.frequency,
                "installed": existingIds.contains(template.id)
            ]
        }

        // Add installed/user skills not already in library catalog (excluding tenet-only skills)
        let extraSkills = existingSkills.filter { !templateIds.contains($0.id) && $0.frequency != "none" }
        for skill in extraSkills {
            allDicts.insert([
                "id": skill.id,
                "name": skill.effectiveName,
                "description": skill.description,
                "icon": skill.icon,
                "author": skill.author ?? (skill.origin == .installed ? "Alfred Core" : "Custom"),
                "dataSources": skill.dataSources,
                "frequency": skill.frequency,
                "installed": true
            ] as [String: Any], at: 0)
        }

        return HTTPResponse(statusCode: 200, body: ["templates": allDicts, "count": allDicts.count])
    }

    /// Install a library skill template as a user skill
    private func handleInstallLibrarySkill(_ request: HTTPRequest) -> HTTPResponse {
        guard let templateId = request.queryParams["id"], !templateId.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'id' query parameter"])
        }

        // Check if already installed
        if SkillLoader.shared.getSkill(id: templateId) != nil {
            return HTTPResponse(statusCode: 409, body: ["error": "Skill '\(templateId)' is already installed"])
        }

        // Find template
        guard let template = SkillLibrary.catalog.first(where: { $0.id == templateId }) else {
            return HTTPResponse(statusCode: 404, body: ["error": "Template not found: \(templateId)"])
        }

        // Write to user skills directory
        let skillsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".alfred/skills/user")
        try? FileManager.default.createDirectory(at: skillsDir, withIntermediateDirectories: true)

        let skillPath = skillsDir.appendingPathComponent("\(templateId).md").path
        do {
            try template.markdownContent.write(toFile: skillPath, atomically: true, encoding: .utf8)

            // Bust coaching caches (SkillLoader reads from disk each time, no explicit reload needed)
            coachingEngine = nil
            invalidateMemoryCache("coaching_cards")
            cache.deleteByEndpoint("/api/coaching/cards")

            return HTTPResponse(statusCode: 201, body: ["installed": true, "id": templateId, "name": template.name])
        } catch {
            return HTTPResponse(statusCode: 500, body: ["error": "Failed to install: \(error.localizedDescription)"])
        }
    }

    // MARK: - Custom Skills Handlers

    private func handleGetSkills() -> HTTPResponse {
        let skills = SkillLoader.shared.loadSkills()
        let skillDicts = skills.map { $0.toDictionary() }
        return HTTPResponse(statusCode: 200, body: [
            "skills": skillDicts,
            "count": skills.count,
            "enabledCount": skills.filter { $0.enabled }.count
        ])
    }

    private func handleToggleSkill(_ request: HTTPRequest) -> HTTPResponse {
        guard let skillId = request.queryParams["id"], !skillId.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'id' query parameter"])
        }

        let newState = SkillLoader.shared.toggleSkill(id: skillId)

        // Bust coaching cards cache so next refresh picks up the change
        coachingEngine = nil
        invalidateMemoryCache("coaching_cards")
        cache.deleteByEndpoint("/api/coaching/cards")

        return HTTPResponse(statusCode: 200, body: [
            "id": skillId,
            "enabled": newState,
            "message": newState ? "Skill enabled" : "Skill disabled"
        ])
    }

    private func handleRenameSkill(_ request: HTTPRequest) -> HTTPResponse {
        guard let skillId = request.queryParams["id"], !skillId.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'id' query parameter"])
        }

        let body = request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let displayName = body["displayName"] as? String

        // Verify skill exists
        guard SkillLoader.shared.getSkill(id: skillId) != nil else {
            return HTTPResponse(statusCode: 404, body: ["error": "Skill '\(skillId)' not found"])
        }

        // Set the display name (nil clears the override)
        SkillLoader.shared.setDisplayName(id: skillId, displayName: displayName?.isEmpty == true ? nil : displayName)

        // Bust coaching cards cache
        coachingEngine = nil
        invalidateMemoryCache("coaching_cards")
        cache.deleteByEndpoint("/api/coaching/cards")

        return HTTPResponse(statusCode: 200, body: [
            "id": skillId,
            "displayName": displayName ?? "",
            "message": displayName != nil ? "Skill renamed to '\(displayName!)'" : "Display name reset to default"
        ])
    }

    private func handleGetSkillDetail(_ request: HTTPRequest) -> HTTPResponse {
        guard let skillId = request.queryParams["id"], !skillId.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'id' query parameter"])
        }

        guard let skill = SkillLoader.shared.getSkill(id: skillId) else {
            return HTTPResponse(statusCode: 404, body: ["error": "Skill not found"])
        }

        // Return full detail including tenets and prompt (for editor)
        var dict = skill.toDictionary()
        dict["tenets"] = skill.tenets
        dict["prompt"] = skill.prompt
        return HTTPResponse(statusCode: 200, body: dict)
    }

    private func handleCreateSkill(_ request: HTTPRequest) -> HTTPResponse {
        let body = request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]

        guard let name = body["name"] as? String, !name.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'name' field"])
        }
        guard let prompt = body["prompt"] as? String, !prompt.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'prompt' field"])
        }

        let description = body["description"] as? String ?? ""
        let icon = body["icon"] as? String ?? "🔧"
        let dataSources = body["dataSources"] as? [String] ?? ["tasks"]
        let frequency = body["frequency"] as? String ?? "daily"
        let tenets = body["tenets"] as? String ?? ""

        // Lint skill prompt for hallucination-inducing patterns
        let lintWarnings = lintSkillPrompt(prompt: prompt, tenets: tenets)
        let lintBlockers = lintWarnings.filter { $0["severity"] as? String == "block" }
        if !lintBlockers.isEmpty {
            let messages = lintBlockers.compactMap { $0["message"] as? String }.joined(separator: "; ")
            return HTTPResponse(statusCode: 422, body: ["error": "Prompt quality issue: \(messages)", "warnings": lintWarnings])
        }

        guard let skill = SkillLoader.shared.createSkill(
            name: name, description: description, icon: icon,
            dataSources: dataSources, frequency: frequency,
            tenets: tenets, prompt: prompt
        ) else {
            return HTTPResponse(statusCode: 409, body: ["error": "Skill already exists or invalid name"])
        }

        // Bust coaching cache
        coachingEngine = nil
        invalidateMemoryCache("coaching_cards")
        cache.deleteByEndpoint("/api/coaching/cards")

        return HTTPResponse(statusCode: 201, body: skill.toDictionary())
    }

    private func handleUpdateSkill(_ request: HTTPRequest) -> HTTPResponse {
        guard let skillId = request.queryParams["id"], !skillId.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'id' query parameter"])
        }

        // Check if skill exists and is editable
        guard let existing = SkillLoader.shared.getSkill(id: skillId) else {
            return HTTPResponse(statusCode: 404, body: ["error": "Skill not found"])
        }
        guard existing.isEditable else {
            return HTTPResponse(statusCode: 403, body: ["error": "Installed skills cannot be edited — they are managed by the skill author"])
        }

        let body = request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]

        // Tenet-only installed skills: only allow editing tenets
        if existing.origin == .installed && existing.isTenetOnly {
            guard let newTenets = body["tenets"] as? String, !newTenets.isEmpty else {
                return HTTPResponse(statusCode: 400, body: ["error": "Tenet-only skills can only update tenets"])
            }
            guard let updated = SkillLoader.shared.updateInstalledSkillTenets(id: skillId, tenets: newTenets) else {
                return HTTPResponse(statusCode: 500, body: ["error": "Failed to update skill tenets"])
            }
            coachingEngine = nil
            invalidateMemoryCache("coaching_cards")
            cache.deleteByEndpoint("/api/coaching/cards")
            return HTTPResponse(statusCode: 200, body: updated.toDictionary())
        }

        // Lint prompt if being updated
        if let newPrompt = body["prompt"] as? String, !newPrompt.isEmpty {
            let newTenets = body["tenets"] as? String ?? existing.tenets
            let lintWarnings = lintSkillPrompt(prompt: newPrompt, tenets: newTenets)
            let lintBlockers = lintWarnings.filter { $0["severity"] as? String == "block" }
            if !lintBlockers.isEmpty {
                let messages = lintBlockers.compactMap { $0["message"] as? String }.joined(separator: "; ")
                return HTTPResponse(statusCode: 422, body: ["error": "Prompt quality issue: \(messages)", "warnings": lintWarnings])
            }
        }

        guard let updated = SkillLoader.shared.updateSkill(
            id: skillId,
            name: body["name"] as? String,
            description: body["description"] as? String,
            icon: body["icon"] as? String,
            dataSources: body["dataSources"] as? [String],
            frequency: body["frequency"] as? String,
            tenets: body["tenets"] as? String,
            prompt: body["prompt"] as? String
        ) else {
            return HTTPResponse(statusCode: 500, body: ["error": "Failed to update skill"])
        }

        coachingEngine = nil
        invalidateMemoryCache("coaching_cards")
        cache.deleteByEndpoint("/api/coaching/cards")

        return HTTPResponse(statusCode: 200, body: updated.toDictionary())
    }

    private func handleDeleteSkill(_ request: HTTPRequest) -> HTTPResponse {
        guard let skillId = request.queryParams["id"], !skillId.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'id' query parameter"])
        }

        // Check if skill exists and is editable
        guard let existing = SkillLoader.shared.getSkill(id: skillId) else {
            return HTTPResponse(statusCode: 404, body: ["error": "Skill not found"])
        }
        guard existing.isEditable else {
            return HTTPResponse(statusCode: 403, body: ["error": "Installed skills cannot be deleted — they are managed by the skill author"])
        }

        guard SkillLoader.shared.deleteSkill(id: skillId) else {
            return HTTPResponse(statusCode: 500, body: ["error": "Failed to delete skill"])
        }

        coachingEngine = nil
        invalidateMemoryCache("coaching_cards")
        cache.deleteByEndpoint("/api/coaching/cards")

        return HTTPResponse(statusCode: 200, body: ["id": skillId, "deleted": true])
    }

    // MARK: - Signal Handlers (v2)

    private func handleGetTodaysSignals() -> HTTPResponse {
        let signals = SignalStore.shared.getTodaysSignals()
        let signalDicts: [[String: Any]] = signals.map { signal in
            var dict: [String: Any] = [
                "type": signal.type,
                "lensId": signal.lensId,
                "confidence": signal.confidence,
                "timestamp": signal.timestamp
            ]
            if let subject = signal.subject { dict["subject"] = subject }
            if let evidence = signal.evidence { dict["evidence"] = evidence }
            if let metadata = signal.metadata { dict["metadata"] = metadata }

            // Add temporal context
            let streak = SignalStore.shared.getStreak(lensId: signal.lensId, signalType: signal.type)
            if streak > 1 { dict["streak"] = streak }

            return dict
        }
        return HTTPResponse(statusCode: 200, body: [
            "signals": signalDicts,
            "count": signals.count,
            "date": {
                let df = DateFormatter()
                df.dateFormat = "yyyy-MM-dd"
                return df.string(from: Date())
            }()
        ])
    }

    private func handleGetSignalHistory(_ request: HTTPRequest) -> HTTPResponse {
        guard let lensId = request.queryParams["lens"], !lensId.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'lens' query parameter"])
        }
        let days = Int(request.queryParams["days"] ?? "7") ?? 7
        let history = SignalStore.shared.getSignalHistory(lensId: lensId, days: days)

        let historyDicts: [[String: Any]] = history.map { day in
            [
                "date": day.date,
                "lensId": day.lensId,
                "signalCount": day.signals.count,
                "signals": day.signals.map { signal -> [String: Any] in
                    var dict: [String: Any] = [
                        "type": signal.type,
                        "confidence": signal.confidence
                    ]
                    if let subject = signal.subject { dict["subject"] = subject }
                    if let evidence = signal.evidence { dict["evidence"] = evidence }
                    return dict
                }
            ]
        }

        return HTTPResponse(statusCode: 200, body: [
            "lensId": lensId,
            "days": days,
            "history": historyDicts
        ])
    }

    private func handleGetSignalStats() -> HTTPResponse {
        return HTTPResponse(statusCode: 200, body: SignalStore.shared.getStats())
    }

    // MARK: - Tenet Pack Handlers (v2)

    private func handleGetTenetPacks() -> HTTPResponse {
        let packs = TenetPackLoader.shared.loadTenetPacks()
        return HTTPResponse(statusCode: 200, body: [
            "tenets": packs.map { $0.toDictionary() },
            "count": packs.count,
            "enabledCount": packs.filter { $0.enabled }.count
        ])
    }

    private func handleGetTenetPackDetail(_ request: HTTPRequest) -> HTTPResponse {
        guard let packId = request.queryParams["id"], !packId.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'id' query parameter"])
        }
        guard let pack = TenetPackLoader.shared.getTenetPack(id: packId) else {
            return HTTPResponse(statusCode: 404, body: ["error": "Tenet pack not found"])
        }
        var dict = pack.toDictionary()
        dict["principles"] = pack.principles
        return HTTPResponse(statusCode: 200, body: dict)
    }

    private func handleToggleTenetPack(_ request: HTTPRequest) -> HTTPResponse {
        guard let packId = request.queryParams["id"], !packId.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'id' query parameter"])
        }
        let newState = TenetPackLoader.shared.toggleTenetPack(id: packId)

        // Bust coaching caches — tenets affect all coaching prompts
        coachingEngine = nil
        invalidateMemoryCache("coaching_cards")
        cache.deleteByEndpoint("/api/coaching/cards")

        return HTTPResponse(statusCode: 200, body: [
            "id": packId,
            "enabled": newState,
            "message": newState ? "Tenet pack enabled" : "Tenet pack disabled"
        ])
    }

    private func handleCreateTenetPack(_ request: HTTPRequest) -> HTTPResponse {
        let body = request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]

        guard let name = body["name"] as? String, !name.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'name' field"])
        }
        guard let principles = body["principles"] as? String, !principles.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'principles' field"])
        }

        let description = body["description"] as? String ?? ""
        let icon = body["icon"] as? String ?? "📜"
        let scope = body["scope"] as? [String] ?? ["all"]

        guard let pack = TenetPackLoader.shared.createTenetPack(
            name: name, description: description, icon: icon,
            scope: scope, principles: principles
        ) else {
            return HTTPResponse(statusCode: 409, body: ["error": "Tenet pack already exists or invalid name"])
        }

        coachingEngine = nil
        invalidateMemoryCache("coaching_cards")
        cache.deleteByEndpoint("/api/coaching/cards")

        return HTTPResponse(statusCode: 201, body: pack.toDictionary())
    }

    private func handleUpdateTenetPack(_ request: HTTPRequest) -> HTTPResponse {
        guard let packId = request.queryParams["id"], !packId.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'id' query parameter"])
        }

        guard let existing = TenetPackLoader.shared.getTenetPack(id: packId) else {
            return HTTPResponse(statusCode: 404, body: ["error": "Tenet pack not found"])
        }
        guard existing.isEditable else {
            return HTTPResponse(statusCode: 403, body: ["error": "Installed tenet packs cannot be edited"])
        }

        let body = request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]

        guard let updated = TenetPackLoader.shared.updateTenetPack(
            id: packId,
            name: body["name"] as? String,
            description: body["description"] as? String,
            icon: body["icon"] as? String,
            scope: body["scope"] as? [String],
            principles: body["principles"] as? String
        ) else {
            return HTTPResponse(statusCode: 500, body: ["error": "Failed to update tenet pack"])
        }

        coachingEngine = nil
        invalidateMemoryCache("coaching_cards")
        cache.deleteByEndpoint("/api/coaching/cards")

        return HTTPResponse(statusCode: 200, body: updated.toDictionary())
    }

    private func handleDeleteTenetPack(_ request: HTTPRequest) -> HTTPResponse {
        guard let packId = request.queryParams["id"], !packId.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'id' query parameter"])
        }

        guard let existing = TenetPackLoader.shared.getTenetPack(id: packId) else {
            return HTTPResponse(statusCode: 404, body: ["error": "Tenet pack not found"])
        }
        guard existing.isEditable else {
            return HTTPResponse(statusCode: 403, body: ["error": "Installed tenet packs cannot be deleted"])
        }

        guard TenetPackLoader.shared.deleteTenetPack(id: packId) else {
            return HTTPResponse(statusCode: 500, body: ["error": "Failed to delete tenet pack"])
        }

        coachingEngine = nil
        invalidateMemoryCache("coaching_cards")
        cache.deleteByEndpoint("/api/coaching/cards")

        return HTTPResponse(statusCode: 200, body: ["id": packId, "deleted": true])
    }

    // MARK: - Analysis Lens Handlers (v2)

    private func handleGetAnalysisLenses() -> HTTPResponse {
        let lenses = AnalysisLensLoader.shared.loadLenses()
        return HTTPResponse(statusCode: 200, body: [
            "analyses": lenses.map { $0.toDictionary() },
            "count": lenses.count,
            "enabledCount": lenses.filter { $0.enabled }.count
        ])
    }

    private func handleGetAnalysisLensDetail(_ request: HTTPRequest) -> HTTPResponse {
        guard let lensId = request.queryParams["id"], !lensId.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'id' query parameter"])
        }
        guard let lens = AnalysisLensLoader.shared.getLens(id: lensId) else {
            return HTTPResponse(statusCode: 404, body: ["error": "Analysis lens not found"])
        }
        var dict = lens.toDictionary()
        dict["prompt"] = lens.prompt
        if let schema = lens.outputSchema { dict["outputSchema"] = schema }
        return HTTPResponse(statusCode: 200, body: dict)
    }

    private func handleToggleAnalysisLens(_ request: HTTPRequest) -> HTTPResponse {
        guard let lensId = request.queryParams["id"], !lensId.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'id' query parameter"])
        }
        let newState = AnalysisLensLoader.shared.toggleLens(id: lensId)

        coachingEngine = nil
        invalidateMemoryCache("coaching_cards")
        cache.deleteByEndpoint("/api/coaching/cards")

        return HTTPResponse(statusCode: 200, body: [
            "id": lensId,
            "enabled": newState,
            "message": newState ? "Analysis lens enabled" : "Analysis lens disabled"
        ])
    }

    private func handleCreateAnalysisLens(_ request: HTTPRequest) -> HTTPResponse {
        let body = request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]

        guard let name = body["name"] as? String, !name.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'name' field"])
        }
        guard let prompt = body["prompt"] as? String, !prompt.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'prompt' field"])
        }

        let description = body["description"] as? String ?? ""
        let icon = body["icon"] as? String ?? "🔍"
        let dataSources = body["dataSources"] as? [String] ?? []
        let signals = body["signals"] as? String ?? ""
        let outputSchema = body["outputSchema"] as? String

        guard let lens = AnalysisLensLoader.shared.createLens(
            name: name, description: description, icon: icon,
            dataSources: dataSources, signals: signals, prompt: prompt,
            outputSchema: outputSchema
        ) else {
            return HTTPResponse(statusCode: 409, body: ["error": "Analysis lens already exists or invalid name"])
        }

        coachingEngine = nil
        invalidateMemoryCache("coaching_cards")
        cache.deleteByEndpoint("/api/coaching/cards")

        return HTTPResponse(statusCode: 201, body: lens.toDictionary())
    }

    private func handleUpdateAnalysisLens(_ request: HTTPRequest) -> HTTPResponse {
        guard let lensId = request.queryParams["id"], !lensId.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'id' query parameter"])
        }

        guard let existing = AnalysisLensLoader.shared.getLens(id: lensId) else {
            return HTTPResponse(statusCode: 404, body: ["error": "Analysis lens not found"])
        }
        guard existing.isEditable else {
            return HTTPResponse(statusCode: 403, body: ["error": "Installed analysis lenses cannot be edited"])
        }

        let body = request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]

        guard let updated = AnalysisLensLoader.shared.updateLens(
            id: lensId,
            name: body["name"] as? String,
            description: body["description"] as? String,
            icon: body["icon"] as? String,
            dataSources: body["dataSources"] as? [String],
            signals: body["signals"] as? String,
            prompt: body["prompt"] as? String,
            outputSchema: body["outputSchema"] as? String
        ) else {
            return HTTPResponse(statusCode: 500, body: ["error": "Failed to update analysis lens"])
        }

        coachingEngine = nil
        invalidateMemoryCache("coaching_cards")
        cache.deleteByEndpoint("/api/coaching/cards")

        return HTTPResponse(statusCode: 200, body: updated.toDictionary())
    }

    private func handleDeleteAnalysisLens(_ request: HTTPRequest) -> HTTPResponse {
        guard let lensId = request.queryParams["id"], !lensId.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'id' query parameter"])
        }

        guard let existing = AnalysisLensLoader.shared.getLens(id: lensId) else {
            return HTTPResponse(statusCode: 404, body: ["error": "Analysis lens not found"])
        }
        guard existing.isEditable else {
            return HTTPResponse(statusCode: 403, body: ["error": "Installed analysis lenses cannot be deleted"])
        }

        guard AnalysisLensLoader.shared.deleteLens(id: lensId) else {
            return HTTPResponse(statusCode: 500, body: ["error": "Failed to delete analysis lens"])
        }

        coachingEngine = nil
        invalidateMemoryCache("coaching_cards")
        cache.deleteByEndpoint("/api/coaching/cards")

        return HTTPResponse(statusCode: 200, body: ["id": lensId, "deleted": true])
    }

    /// Lint a skill prompt for patterns known to induce hallucination
    private func lintSkillPrompt(prompt: String, tenets: String) -> [[String: Any]] {
        var warnings: [[String: Any]] = []
        let promptLower = prompt.lowercased()

        // Check for forced specificity without grounding
        let forcePatterns = [
            "reference a specific .* by name",
            "name the specific",
            "always mention",
            "must include .* name"
        ]
        for pattern in forcePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               regex.firstMatch(in: prompt, range: NSRange(prompt.startIndex..., in: prompt)) != nil {
                // Check if there's a grounding qualifier
                let groundingQualifiers = ["if .*(data|context|clearly|appear)", "only if", "from the context"]
                let hasGrounding = groundingQualifiers.contains { qualifier in
                    (try? NSRegularExpression(pattern: qualifier, options: .caseInsensitive))
                        .flatMap { $0.firstMatch(in: prompt, range: NSRange(prompt.startIndex..., in: prompt)) } != nil
                }
                if !hasGrounding {
                    warnings.append([
                        "message": "Prompt forces specific names without grounding clause. Add 'ONLY if they appear in the context' to prevent fabrication.",
                        "severity": "block",
                        "pattern": pattern
                    ])
                }
            }
        }

        // Check for no data/context reference
        let groundingTerms = ["context", "data provided", "data above", "data below"]
        if !groundingTerms.contains(where: { promptLower.contains($0) }) {
            warnings.append([
                "message": "Prompt doesn't reference the provided context data. The coach may extrapolate beyond available information.",
                "severity": "warn",
                "pattern": "missing_grounding"
            ])
        }

        // Check for no fallback/graceful-exit instruction
        let fallbackTerms = ["no clear signal", "not enough data", "if uncertain", "if nothing stands out", "don't force", "rather than guessing"]
        if !fallbackTerms.contains(where: { promptLower.contains($0) }) {
            warnings.append([
                "message": "No fallback instruction for thin data. Consider adding: 'If the data doesn't clearly support a recommendation, say so.'",
                "severity": "warn",
                "pattern": "missing_fallback"
            ])
        }

        // Check for overly long prompts
        if prompt.count > 2000 {
            warnings.append([
                "message": "Prompt is very long (\(prompt.count) chars). Shorter prompts tend to produce more focused, grounded outputs.",
                "severity": "warn",
                "pattern": "too_long"
            ])
        }

        return warnings
    }

    /// Returns a contextual welcome opener for the Chat tab
    private var openerCache: (text: String, timestamp: Date)? = nil

    /// Disk path for pre-generated opener
    private var openerDiskPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.alfred/coaching_opener_today.json"
    }

    /// Load a same-day opener from disk. Returns nil if absent, stale (>4h), or wrong day.
    private func loadOpenerFromDisk() -> String? {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let todayStr = dateFormatter.string(from: Date())

        guard FileManager.default.fileExists(atPath: openerDiskPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: openerDiskPath)),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        guard let date = payload["date"] as? String, date == todayStr else { return nil }

        if let generatedAtStr = payload["generatedAt"] as? String,
           let generatedAt = ISO8601DateFormatter().date(from: generatedAtStr) {
            if Date().timeIntervalSince(generatedAt) > 14400 {
                return nil  // >4h old — stale
            }
        }

        return payload["opener"] as? String
    }

    /// Build a time-of-day label and posture hint for the opener prompt.
    private func timeOfDayContext() -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 0..<10:
            return "It is early morning. The person is starting their day — help them set up for success."
        case 10..<14:
            return "It is mid-day. The person is in the thick of things — help them see what's slipping."
        case 14..<17:
            return "It is afternoon. Help them identify what would make today a genuine win."
        default:
            return "It is evening. Help them reflect on the day and prepare for tomorrow."
        }
    }

    private func handleCoachingOpener() async -> HTTPResponse {
        // Layer 1: in-memory cache (1-hour TTL)
        if let cached = openerCache, Date().timeIntervalSince(cached.timestamp) < 3600 {
            return HTTPResponse(statusCode: 200, body: ["opener": cached.text])
        }

        // Layer 2: disk cache (pre-generated during morning briefing, 4-hour TTL)
        if let diskOpener = loadOpenerFromDisk() {
            openerCache = (diskOpener, Date())
            return HTTPResponse(statusCode: 200, body: ["opener": diskOpener])
        }

        guard let config = getConfig() else {
            return HTTPResponse(statusCode: 200, body: ["opener": "What's on your mind?"])
        }

        // Gather context for the opener
        let followups = CoachingMemoryService.shared.getOpenFollowups()
        let recentSessions = CoachingMemoryService.shared.getRecentSessions(limit: 2)
        let liveContext = await gatherLiveContext(config: config)

        // Enrich opener with full coaching context (no user query to route against, include everything)
        if coachingEngine == nil {
            coachingEngine = CoachingEngine(config: config, alfredService: alfredService)
        }
        let allInsights = gatherAllCoachingInsights()
        let commitments = gatherDetailedCommitments()
        let unifiedFollowups = gatherUnifiedFollowups()

        var contextForOpener = ""
        contextForOpener += "Time of day: \(timeOfDayContext())\n"
        if !followups.isEmpty {
            contextForOpener += "Open follow-ups from past coaching:\n" + followups.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        if !recentSessions.isEmpty {
            contextForOpener += "Recent coaching sessions:\n" + recentSessions.joined(separator: "\n") + "\n"
        }
        contextForOpener += "Today's context:\n\(liveContext)"
        if !allInsights.isEmpty {
            contextForOpener += "\nCoaching observations from today:\n\(allInsights)\n"
        }
        if !commitments.isEmpty {
            contextForOpener += "\nCommitment status:\n\(commitments)\n"
        }
        if !unifiedFollowups.isEmpty {
            contextForOpener += "\nOpen follow-ups & reminders:\n\(unifiedFollowups)\n"
        }

        let prompt = """
        Generate a brief, sharp coaching observation about this person's day. This is the first thing they see when they open Alfred — make it count. 1-2 sentences max.

        Context:
        \(contextForOpener)

        Rules:
        - Lead with warmth. A coach greets you before coaching you. Start with something human — acknowledge their day, a recent win, or what's coming up. NEVER open with task pressure or overdue counts.
        - Adapt your posture to the time of day (morning = set up the day, mid-day = check in, afternoon = what would make today a win, evening = reflect)
        - If there are open follow-ups, reference one naturally ("Last time we talked about X. How did that go?")
        - You can be a Day Lens — share ONE observation about what their calendar or task data reveals. But frame it as helpful, not as an ambush:
          • Good: "You've got a packed morning but a clear afternoon — good day to tackle that deep work."
          • Bad: "You have 8 overdue tasks piling up. What's blocking you?" (this is an interrogation, not a greeting)
        - Save the hard coaching for when they engage. The opener earns the right to coach later in the conversation.
        - Be warm and specific. Like a friend who remembers everything and brings it up naturally, not forcefully.
        - No emojis. No generic greetings like "How can I help?" — but warmth is not generic.
        - Just the observation text, nothing else.
        """

        let claudeService = ClaudeAIService(config: config.ai)
        do {
            let opener = try await claudeService.generateText(
                prompt: prompt,
                system: "You are Coach Alfred, a warm but direct executive coach. You see the shape of someone's day and tell them what they're not seeing. Generate a single sharp coaching observation.",
                maxTokens: 150
            )
            let trimmed = opener.trimmingCharacters(in: .whitespacesAndNewlines)
            openerCache = (trimmed, Date())
            return HTTPResponse(statusCode: 200, body: ["opener": trimmed])
        } catch {
            return HTTPResponse(statusCode: 200, body: ["opener": "What's on your mind?"])
        }
    }

    // MARK: - Coaching Context Helpers

    /// Gather user-taught rules from all agent memory files
    private func gatherAgentMemoryRules() -> String {
        let memService = AgentMemoryService.shared
        var rules: [String] = []

        for agentType in AgentType.allCases {
            let memory = memService.getMemory(for: agentType)
            if let taughtRules = memory.sections["User-Taught Rules"],
               !taughtRules.isEmpty,
               !taughtRules.contains("_Rules you've explicitly") {
                // Strip timestamps for brevity, keep the rule text
                let ruleLines = taughtRules.components(separatedBy: "\n")
                    .filter { $0.starts(with: "- ") }
                    .compactMap { line -> String? in
                        if let bracketEnd = line.range(of: "] ") {
                            return "- " + String(line[bracketEnd.upperBound...])
                        }
                        return line
                    }
                if !ruleLines.isEmpty {
                    rules.append("**\(agentType.displayName):**\n" + ruleLines.joined(separator: "\n"))
                }
            }
        }

        return rules.isEmpty ? "" : rules.joined(separator: "\n")
    }

    /// Gather expanded live context (tasks, calendar, commitments)
    private func gatherLiveContext(config: AppConfig) async -> String {
        var parts: [String] = []
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "h:mm a"

        // Pinned goal: user's declared #1 focus
        let stateRaw = loadSchedulerStateRaw()
        if let pinnedId = stateRaw["pinnedGoalNotionId"] as? String, !pinnedId.isEmpty,
           let pinnedAtStr = stateRaw["pinnedGoalAt"] as? String {
            // Fetch task title from Notion (best-effort)
            var pinnedTitle = "their pinned task"
            if let orchestrator = alfredService.orchestrator,
               let task = try? await orchestrator.notionServicePublic.fetchTaskById(notionId: pinnedId) {
                pinnedTitle = task.title
            }
            // Calculate time since pinned
            let isoFmt = Self.iso8601FractionalFormatter
            let timeAgo: String
            if let pinnedDate = isoFmt.date(from: pinnedAtStr) {
                let interval = Date().timeIntervalSince(pinnedDate)
                if interval < 3600 { timeAgo = "\(Int(interval / 60))m ago" }
                else if interval < 86400 { timeAgo = "\(Int(interval / 3600))h ago" }
                else { timeAgo = "\(Int(interval / 86400))d ago" }
            } else { timeAgo = "recently" }
            parts.append("USER'S DECLARED #1 FOCUS: \"\(pinnedTitle)\" (pinned \(timeAgo)). This is their deliberate choice — reference it when relevant. If they seem distracted from it, gently redirect. If they've been ignoring it, ask why.")
        }

        // Calendar: lightweight event fetch (skip expensive meeting briefings)
        do {
            guard let orchestrator = alfredService.orchestrator else { throw ServiceError.notInitialized }
            let schedule = try await orchestrator.calendarServicePublic.fetchEventsFromAllCalendars(for: Date(), userSettings: config.user)
            let events = schedule.events
            let timedEvents = events.filter { !$0.isAllDay }
            let meetingCount = timedEvents.count
            let remaining = timedEvents.filter { $0.startTime > Date() }

            var calStr = "Today: \(meetingCount) meetings (\(remaining.count) remaining)."
            if let next = remaining.first {
                calStr += " Next: \(next.title) at \(timeFmt.string(from: next.startTime))."
            }
            // List today's meetings
            if !timedEvents.isEmpty {
                let eventList = timedEvents.prefix(10).map { event in
                    "\(timeFmt.string(from: event.startTime))-\(timeFmt.string(from: event.endTime)) — \(event.title)"
                }.joined(separator: "\n  ")
                calStr += "\n  \(eventList)"
            }

            // Calendar structural analysis (Day Lens)
            if !timedEvents.isEmpty {
                let sorted = timedEvents.sorted { $0.startTime < $1.startTime }

                // Total meeting hours
                var totalMinutes = 0
                for event in sorted {
                    totalMinutes += Int(event.endTime.timeIntervalSince(event.startTime) / 60)
                }
                let hours = totalMinutes / 60
                let mins = totalMinutes % 60
                calStr += "\n  Time in meetings: \(hours)h \(mins)m"

                // Back-to-back detection (< 15 min gap)
                var backToBackChains: [[String]] = []
                var currentChain: [String] = [sorted[0].title]
                for i in 1..<sorted.count {
                    let gap = sorted[i].startTime.timeIntervalSince(sorted[i-1].endTime)
                    if gap < 900 { // < 15 min
                        currentChain.append(sorted[i].title)
                    } else {
                        if currentChain.count > 1 { backToBackChains.append(currentChain) }
                        currentChain = [sorted[i].title]
                    }
                }
                if currentChain.count > 1 { backToBackChains.append(currentChain) }

                if !backToBackChains.isEmpty {
                    let longest = backToBackChains.max(by: { $0.count < $1.count })!
                    calStr += "\n  Back-to-back chains: \(backToBackChains.count) (longest: \(longest.count) meetings in a row)"
                }

                // Free blocks > 30 min
                let calendar = Calendar.current
                let workStart = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!
                let workEnd = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: Date())!
                var freeBlocks: [(start: Date, duration: Int)] = []
                var cursor = workStart
                for event in sorted {
                    if event.startTime > cursor {
                        let gap = Int(event.startTime.timeIntervalSince(cursor) / 60)
                        if gap >= 30 {
                            freeBlocks.append((start: cursor, duration: gap))
                        }
                    }
                    cursor = max(cursor, event.endTime)
                }
                if cursor < workEnd {
                    let gap = Int(workEnd.timeIntervalSince(cursor) / 60)
                    if gap >= 30 {
                        freeBlocks.append((start: cursor, duration: gap))
                    }
                }

                if freeBlocks.isEmpty {
                    calStr += "\n  ⚠️ No free blocks (30+ min) — zero deep work time today"
                } else {
                    let blockDescs = freeBlocks.map { "\(timeFmt.string(from: $0.start)) (\($0.duration)m)" }
                    calStr += "\n  Free blocks (30+ min): \(blockDescs.joined(separator: ", "))"
                }
            }

            parts.append(calStr)
        } catch {
            parts.append("Calendar: unavailable")
        }

        // Active tasks (top 8 by priority)
        var notionAvailable = true
        if let orchestrator = alfredService.orchestrator {
            do {
                let allTasks = try await orchestrator.notionServicePublic.queryActiveTasks()
                let topTasks = Array(allTasks.prefix(8))

                if !topTasks.isEmpty {
                    let dateFmt = DateFormatter()
                    dateFmt.dateFormat = "MMM d"

                    var taskStr = "Active tasks (\(allTasks.count) total):"
                    for task in topTasks {
                        var line = "  - \(task.title)"
                        if let priority = task.priority {
                            line += " [\(priority.rawValue)]"
                        }
                        if let due = task.dueDate {
                            let isOverdue = due < Date()
                            line += " due \(dateFmt.string(from: due))"
                            if isOverdue { line += " [OVERDUE]" }
                        }
                        taskStr += "\n\(line)"
                    }

                    // Stale tasks (avoidance signal)
                    let twoWeeksAgo = Calendar.current.date(byAdding: .day, value: -14, to: Date())!
                    let staleTasks = allTasks.filter { task in
                        task.status == .notStarted &&
                        (task.dueDate == nil || task.dueDate! < Date()) // no due date or overdue
                    }
                    if !staleTasks.isEmpty {
                        taskStr += "\n  ⚠️ Stale/avoided tasks (not started, >14 days or overdue):"
                        for task in staleTasks.prefix(5) {
                            taskStr += "\n  - \(task.title)"
                            if let p = task.priority { taskStr += " [\(p.rawValue)]" }
                        }
                    }

                    parts.append(taskStr)
                }
            } catch {
                notionAvailable = false
                parts.append("Tasks: unavailable (Notion sync failing — task data may be stale)")
            }
        }

        // Open commitments count
        let trackerStats = CommitmentScanTracker.shared.getStats()
        var commitmentLine = "Open commitments: \(trackerStats.openCommitments)"
        if !notionAvailable {
            commitmentLine += " (warning: Notion sync failing, commitment data may be stale)"
        }
        parts.append(commitmentLine)

        // Reliability score
        let lifecycleStats = TaskLifecycleTracker.shared.getStats()
        parts.append("Reliability score: \(lifecycleStats.completionRate)%")

        return parts.joined(separator: "\n")
    }

    /// Gather relationship data (counterparty stats + recent message interactions)
    private func gatherRelationshipData(config: AppConfig) -> String {
        // Check cache first (WhatsApp reads are expensive)
        if let cached = relationshipDataCache,
           Date().timeIntervalSince(cached.timestamp) < relationshipCacheTTL {
            return cached.data
        }

        var lines: [String] = []

        // Commitment stats by counterparty
        let counterpartyStats = TaskLifecycleTracker.shared.getStatsByCounterparty()
        if !counterpartyStats.isEmpty {
            lines.append("Commitment stats by person:")
            for stat in counterpartyStats.prefix(6) {
                let completionPct = Int(stat.completionRate * 100)
                let overduePct = Int(stat.overdueRate * 100)
                lines.append("  - \(stat.name): \(stat.totalTasks) tasks, \(completionPct)% completed, \(overduePct)% overdue")
            }
        }

        // Recent message interactions (WhatsApp) — so Coach doesn't nudge about recently-contacted people
        do {
            let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
            let reader = WhatsAppReader.shared(dbPath: config.messaging.whatsapp.dbPath)
            try reader.connect()
            let threads = try reader.fetchThreads(since: sevenDaysAgo)

            if !threads.isEmpty {
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .full
                lines.append("\nRecent message interactions (last 7 days):")
                for thread in threads.sorted(by: { $0.lastMessageDate > $1.lastMessageDate }).prefix(10) {
                    let name = thread.contactName ?? thread.contactIdentifier
                    let ago = formatter.localizedString(for: thread.lastMessageDate, relativeTo: Date())
                    lines.append("  - \(name): last message \(ago) (WhatsApp)")
                }
            }
        } catch {
            // Non-fatal — message data is supplementary
        }

        let result = lines.joined(separator: "\n")
        relationshipDataCache = (data: result, timestamp: Date())
        return result
    }

    // MARK: - Chat Context Enrichment (Highest-Context Chat)

    /// Gather ALL cached coaching card insights with reasoning data.
    /// Always-on: included in every chat message so Alfred is universally informed.
    /// Zero-cost: reads from CoachingEngine's 2h cache, no LLM calls.
    private func gatherAllCoachingInsights() -> String {
        guard let engine = coachingEngine,
              let cardsWithContext = engine.getCachedCardInsightsWithContext(),
              !cardsWithContext.isEmpty else { return "" }

        var lines = ["Today's coaching observations:"]
        for item in cardsWithContext {
            // Insight text (truncate at 200 chars to keep token budget manageable)
            let insight = item.card.insight.count > 200
                ? String(item.card.insight.prefix(200)) + "..."
                : item.card.insight
            lines.append("  [\(item.card.label)] \(insight)")

            // Reasoning: key context data points that drove this insight (max 3 lines)
            let reasoning = item.contextData
                .filter { !$0.hasPrefix("===") }  // skip section headers like "=== Tasks ==="
                .filter { !$0.isEmpty }
                .prefix(3)
                .map { "    → \($0.trimmingCharacters(in: .whitespaces))" }
            if !reasoning.isEmpty {
                lines.append(contentsOf: reasoning)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Gather detailed open commitments grouped by type (i_owe vs they_owe).
    /// On-demand: only called when ChatContextRouter detects commitment/person topic.
    /// If mentionedPerson is set, filters to that person's commitments only.
    private func gatherDetailedCommitments(mentionedPerson: String? = nil) -> String {
        let allOpen = CommitmentScanTracker.shared.getAllOpenCommitments()
        guard !allOpen.isEmpty else { return "No open commitments." }

        // If a person is mentioned, filter to their commitments
        let filtered: [(hash: String, title: String, type: String, counterparty: String, extractedAt: String)]
        if let person = mentionedPerson {
            let personLower = person.lowercased()
            filtered = allOpen.filter { $0.counterparty.lowercased().contains(personLower) }
        } else {
            filtered = allOpen
        }

        // Date formatter for extracted_at timestamps
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFormatterNoFrac = ISO8601DateFormatter()
        let relativeFmt = DateFormatter()
        relativeFmt.dateFormat = "MMM d"

        func formatExtractedDate(_ dateStr: String) -> String {
            let date = isoFormatter.date(from: dateStr)
                ?? isoFormatterNoFrac.date(from: dateStr)
                ?? Self.iso8601FractionalFormatter.date(from: dateStr)
            guard let d = date else { return "" }
            let daysAgo = Int(Date().timeIntervalSince(d) / 86400)
            if daysAgo == 0 { return " (detected today)" }
            if daysAgo == 1 { return " (detected yesterday)" }
            return " (detected \(relativeFmt.string(from: d)))"
        }

        // If filtering by person and no results, return explicit zero-data warning
        if let person = mentionedPerson, filtered.isEmpty {
            return """
            COMMITMENT DATA FOR \(person.uppercased()): NONE FOUND.
            You have \(allOpen.count) open commitments total, but ZERO involve \(person).
            CRITICAL: Do NOT fabricate or guess any task names, commitment titles, or details for \(person). You have NO data. Say "I don't have any tracked commitments with \(person)" if asked.
            """
        }

        var lines: [String] = []
        let header = mentionedPerson != nil
            ? "Open commitments (\(allOpen.count) total, showing \(filtered.count) for \(mentionedPerson!)):"
            : "Open commitments (\(allOpen.count) total):"
        lines.append(header)
        lines.append("  NOTE: These are auto-detected from messages. If the user says an item is done, trust them — the data may be stale.")

        let iOwe = filtered.filter { $0.type == "i_owe" }
        let theyOwe = filtered.filter { $0.type == "they_owe" }

        if !iOwe.isEmpty {
            lines.append("  I owe (\(iOwe.count)):")
            for c in iOwe.prefix(8) {
                let who = c.counterparty.isEmpty ? "" : " → \(c.counterparty)"
                let dateNote = formatExtractedDate(c.extractedAt)
                lines.append("    - \(c.title)\(who)\(dateNote)")
            }
            if iOwe.count > 8 { lines.append("    ... and \(iOwe.count - 8) more") }
        }

        if !theyOwe.isEmpty {
            lines.append("  They owe me (\(theyOwe.count)):")
            for c in theyOwe.prefix(8) {
                let who = c.counterparty.isEmpty ? "" : " ← \(c.counterparty)"
                let dateNote = formatExtractedDate(c.extractedAt)
                lines.append("    - \(c.title)\(who)\(dateNote)")
            }
            if theyOwe.count > 8 { lines.append("    ... and \(theyOwe.count - 8) more") }
        }

        // Pending closure confirmations
        let pending = CommitmentScanTracker.shared.getPendingClosureConfirmations()
        if !pending.isEmpty {
            lines.append("  Pending confirmations: \(pending.count) may be closed (awaiting review)")
        }

        return lines.joined(separator: "\n")
    }

    /// Gather recent messages with a specific person (last 48 hours).
    /// On-demand: only called when ChatContextRouter detects a person mention + message/commitment context.
    /// This gives Claude actual evidence to verify commitment status instead of relying on stale tracker data.
    private func gatherRecentMessages(for contactName: String, config: AppConfig) async -> String {
        guard let orchestrator = alfredService.orchestrator else { return "" }

        do {
            let since = Calendar.current.date(byAdding: .hour, value: -48, to: Date())!
            let allMessages = try await orchestrator.fetchMessagesForContact(contactName, since: since)

            guard !allMessages.isEmpty else {
                return "No messages with \(contactName) in the last 48 hours."
            }

            // Sort by timestamp, most recent last
            let sorted = allMessages.sorted { $0.message.timestamp < $1.message.timestamp }

            let timeFmt = DateFormatter()
            timeFmt.dateFormat = "MMM d, h:mm a"

            var lines: [String] = []
            lines.append("Recent messages with \(contactName) (last 48h, \(sorted.count) messages):")

            // Take the most recent 30 messages to stay within token budget
            for item in sorted.suffix(30) {
                let msg = item.message
                let direction = msg.direction == .outgoing ? "You" : (msg.senderName ?? contactName)
                let time = timeFmt.string(from: msg.timestamp)
                let platform = item.platform.rawValue
                // Truncate very long messages
                let content = msg.content.count > 200
                    ? String(msg.content.prefix(200)) + "..."
                    : msg.content
                lines.append("  [\(time)] [\(platform)] \(direction): \(content)")
            }

            if sorted.count > 30 {
                lines.append("  ... (\(sorted.count - 30) earlier messages omitted)")
            }

            return lines.joined(separator: "\n")
        } catch {
            return "Messages with \(contactName): unavailable (\(error.localizedDescription))"
        }
    }

    /// Gather unified follow-ups from coaching memory AND scheduled reminders.
    /// Always-on: follow-ups are always actionable regardless of topic.
    private func gatherUnifiedFollowups() -> String {
        var allFollowups: [String] = []

        // Source 1: Coaching memory follow-ups (from coaching_context.md)
        let coachingFollowups = CoachingMemoryService.shared.getOpenFollowups()
        for f in coachingFollowups {
            allFollowups.append(f)
        }

        // Source 2: Scheduled follow-up reminders (from ~/.alfred/followups.json)
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let followupsPath = homeDir.appendingPathComponent(".alfred/followups.json")
        if FileManager.default.fileExists(atPath: followupsPath.path) {
            if let data = try? Data(contentsOf: followupsPath),
               let followups = try? JSONDecoder().decode([FollowupReminder].self, from: data) {
                let threeDaysAgo = Calendar.current.date(byAdding: .day, value: -3, to: Date())!
                let relevant = followups.filter { $0.scheduledFor > threeDaysAgo }
                let dateFmt = DateFormatter()
                dateFmt.dateFormat = "MMM d"
                for f in relevant.prefix(5) {
                    let dateStr = dateFmt.string(from: f.scheduledFor)
                    let item = "[scheduled \(dateStr)] \(f.followupAction)"
                    // Avoid duplicates with coaching memory follow-ups
                    if !allFollowups.contains(where: { $0.lowercased().contains(f.followupAction.lowercased().prefix(30)) }) {
                        allFollowups.append(item)
                    }
                }
            }
        }

        guard !allFollowups.isEmpty else { return "" }

        // Cap at 8 items
        let items = Array(allFollowups.prefix(8))
        var lines = ["Open follow-ups (\(allFollowups.count) total):"]
        lines.append(contentsOf: items.map { "  - \($0)" })
        if allFollowups.count > 8 {
            lines.append("  ... and \(allFollowups.count - 8) more")
        }

        return lines.joined(separator: "\n")
    }

    /// Get known contact names from counterparty stats for person detection.
    private func getKnownContactNames() -> [String] {
        return TaskLifecycleTracker.shared.getStatsByCounterparty().map { $0.name }
    }

    /// Check if a chat exchange was coaching-worthy and update memory if so
    private func updateCoachingMemoryIfNeeded(
        userMessage: String,
        assistantResponse: String,
        config: AppConfig
    ) async {
        // Step 1: Quick keyword heuristic — skip non-coaching queries
        let coachingSignals = [
            "avoid", "delegate", "prioritiz", "focus", "relationship", "neglect",
            "should i", "what am i", "feedback", "hard truth", "procrastinat",
            "commit", "follow up", "follow-up", "drop", "say no", "leverage",
            "roast", "truth", "avoiding", "neglecting", "coaching", "reflect",
            "struggling", "overwhelm", "stressed", "behind on", "falling behind",
            "pattern", "habit", "always do", "keep doing", "afraid", "scared",
            "decision", "trade-off", "tradeoff", "what do you think",
            "wrong", "mistake", "failed", "hallucin", "incorrect", "stale",
            "already done", "already closed", "already sent", "already finished",
            "help me", "advice", "perspective", "honest", "direct"
        ]

        let combined = (userMessage + " " + assistantResponse).lowercased()
        let matchesHeuristic = coachingSignals.contains { combined.contains($0) }

        guard matchesHeuristic else {
            return // Not a coaching exchange, skip
        }

        // Step 2: Ask Claude (Haiku-tier) to extract a session summary
        let claudeService = ClaudeAIService(config: config.ai)
        let extractionPrompt = """
        Given this coaching exchange, extract a structured summary.

        User: \(userMessage)
        Coach: \(assistantResponse)

        Return ONLY valid JSON (no markdown fences):
        {
            "skip": false,
            "topic": "2-5 word topic description",
            "insight": "The key insight or realization from this exchange (1 sentence)",
            "action": "Any action the user committed to (1 sentence, or empty string if none)",
            "followUp": "What to check on next time (1 sentence, or empty string if none)",
            "patternCategory": "leverage|relationship|avoidance|general",
            "patternObserved": "Any behavioral pattern noticed (1 sentence, or empty string if none)"
        }

        If this was NOT a coaching conversation (just a factual data query like asking for calendar or commitments), return: {"skip": true}
        """

        do {
            let response = try await claudeService.generateText(
                prompt: extractionPrompt,
                system: "You are a coaching session analyzer. Extract structured summaries from coaching conversations. Be concise.",
                maxTokens: 300,
                useModel: "claude-haiku-4-5-20251001"
            )

            // Parse the JSON response
            guard let jsonData = response.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                return
            }

            // Check if we should skip
            if json["skip"] as? Bool == true {
                return
            }

            let topic = json["topic"] as? String ?? "General coaching"
            let insight = json["insight"] as? String ?? ""
            let action = json["action"] as? String ?? ""
            let followUp = json["followUp"] as? String ?? ""
            let patternCategory = json["patternCategory"] as? String
            let patternObserved = json["patternObserved"] as? String

            // Record the session
            CoachingMemoryService.shared.recordSession(
                topic: topic,
                insight: insight,
                action: action.isEmpty ? nil : action,
                followUp: followUp.isEmpty ? nil : followUp
            )

            // Update pattern if observed
            if let category = patternCategory, let pattern = patternObserved,
               !pattern.isEmpty, category != "general" {
                CoachingMemoryService.shared.updatePattern(
                    category: category.capitalized,
                    observation: pattern
                )
            }

            print("📝 [Coaching] Memory updated — topic: \(topic)")
        } catch {
            print("⚠️ [Coaching] Memory update failed: \(error)")
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
            "lastMessageDate": Self.iso8601Formatter.string(from: summary.thread.lastMessageDate),
            "actionItems": summary.actionItems,
            "sentiment": summary.sentiment,
            "suggestedResponse": summary.suggestedResponse as Any
        ]
    }

    /// Serialize tool execution data into a JSON-friendly dictionary for chat SSE events
    private func serializeToolResult(toolName: String, data: Any) -> [String: Any] {
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "h:mm a"
        let dateFmt = DateFormatter()
        dateFmt.dateStyle = .medium

        switch toolName {
        case "calendar":
            if let created = data as? CreatedEvent {
                return [
                    "type": "calendar_create",
                    "title": created.title,
                    "date": dateFmt.string(from: created.startTime),
                    "timeRange": "\(timeFmt.string(from: created.startTime)) – \(timeFmt.string(from: created.endTime))",
                    "location": created.location ?? "",
                    "shareableLink": created.shareableLink,
                    "htmlLink": created.htmlLink,
                    "success": true
                ]
            }
            if let cal = data as? CalendarBriefing {
                let events: [[String: Any]] = cal.schedule.events.map { event in
                    [
                        "title": event.title,
                        "start": timeFmt.string(from: event.startTime),
                        "end": timeFmt.string(from: event.endTime),
                        "location": event.location ?? "",
                        "isAllDay": event.isAllDay,
                        "attendeeCount": event.attendees.count
                    ]
                }
                return [
                    "type": "calendar",
                    "date": dateFmt.string(from: cal.schedule.date),
                    "eventCount": cal.schedule.events.count,
                    "focusTime": Int(cal.focusTime / 60),
                    "events": events
                ]
            }

        case "commitments":
            if let commitments = data as? [Commitment] {
                let items: [[String: Any]] = commitments.prefix(10).map { c in
                    [
                        "title": c.title,
                        "type": c.type.rawValue,
                        "status": c.status.rawValue,
                        "committedBy": c.committedBy,
                        "committedTo": c.committedTo,
                        "dueDate": c.dueDate.map { dateFmt.string(from: $0) } ?? "",
                        "priority": c.priority.rawValue
                    ]
                }
                return [
                    "type": "commitments",
                    "count": commitments.count,
                    "items": items
                ]
            }
            if let result = data as? CommitmentScanResult {
                return [
                    "type": "commitment_scan",
                    "totalFound": result.totalFound,
                    "saved": result.saved,
                    "duplicates": result.duplicates,
                    "autoClosed": result.autoClosed
                ]
            }

        case "messages":
            if let summaries = data as? [MessageSummary] {
                let items: [[String: Any]] = summaries.prefix(8).map { s in
                    [
                        "contact": s.thread.contactName ?? s.thread.contactIdentifier,
                        "platform": s.thread.platform.rawValue,
                        "summary": String(s.summary.prefix(120)),
                        "urgency": s.urgency.rawValue,
                        "unread": s.thread.unreadCount
                    ]
                }
                return [
                    "type": "messages",
                    "count": summaries.count,
                    "items": items
                ]
            }

        case "todos":
            if let result = data as? TodoScanResult {
                return [
                    "type": "todos",
                    "messagesScanned": result.messagesScanned,
                    "todosFound": result.todosFound,
                    "todosCreated": result.todosCreated,
                    "duplicatesSkipped": result.duplicatesSkipped,
                    "lookbackDays": result.lookbackDays
                ]
            }

        case "tasks":
            if let result = data as? TaskUpdateResult {
                return [
                    "type": "task_update",
                    "taskTitle": result.taskTitle,
                    "changes": result.changes,
                    "success": result.success
                ]
            }
            // Disambiguation case — data is already a dict
            if let dict = data as? [String: Any], let type = dict["type"] as? String, type == "disambiguation" {
                return dict
            }
            // Task list case — [TaskItem] from list/search/completed queries
            if let tasks = data as? [TaskItem] {
                let isCompleted = tasks.first?.status == .done
                let taskList: [[String: Any]] = tasks.prefix(15).map { task in
                    var item: [String: Any] = [
                        "title": task.title,
                        "status": task.status.rawValue
                    ]
                    if let p = task.priority { item["priority"] = p.rawValue }
                    if let due = task.dueDate {
                        let fmt = DateFormatter()
                        fmt.dateStyle = .short
                        item["dueDate"] = fmt.string(from: due)
                    }
                    if task.isOverdue { item["overdue"] = true }
                    return item
                }
                return [
                    "type": isCompleted ? "completed_tasks" : "tasks",
                    "tasks": taskList,
                    "count": tasks.count,
                    "rendered": false
                ]
            }

        case "attention":
            if let report = data as? AttentionDefenseReport {
                let mustDo: [[String: Any]] = report.mustDoToday.prefix(5).map { item in
                    [
                        "title": item.title,
                        "description": item.description,
                        "priority": item.priority.rawValue
                    ]
                }
                let critical: [[String: Any]] = report.criticalTasks.prefix(3).map { item in
                    [
                        "title": item.title,
                        "description": item.description,
                        "priority": item.priority.rawValue
                    ]
                }
                return [
                    "type": "attention",
                    "mustDoCount": report.mustDoToday.count,
                    "criticalCount": report.criticalTasks.count,
                    "recommendations": report.recommendations,
                    "mustDoToday": mustDo,
                    "criticalTasks": critical,
                    "timeAvailable": Int(report.timeAvailable / 60)
                ]
            }

        default:
            break
        }

        // Fallback: return just the type
        return ["type": toolName, "rendered": false]
    }

    // MARK: - Streaming Handlers (SSE)

    /// Stream daily briefing generation with progress updates
    private func handleStreamingBriefing(_ request: HTTPRequest, client: ClientSocket) async {
        client.beginSSE()

        let date = parseDate(from: request.queryParams["date"])
        let dateStr = Self.simpleDateFormatter.string(from: date)  // Must match non-streaming endpoint format

        // Check cache first for instant response (4 hour TTL for briefing)
        let cacheParams = ["date": dateStr]
        if let cached = cache.getCached(endpoint: "/api/briefing", params: cacheParams) {
            print("⚡ Returning cached streaming briefing for \(dateStr.prefix(10))")

            // Send quick progress animation
            client.sendSSEJSON(event: "progress", json: [
                "step": "cache",
                "message": "Loading cached briefing...",
                "icon": "⚡",
                "progress": 50
            ])

            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms for UI feedback

            client.sendSSEJSON(event: "progress", json: [
                "step": "complete",
                "message": "Ready!",
                "icon": "✅",
                "progress": 100
            ])

            // Parse cached response and send as result
            if let data = cached.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                client.sendSSEJSON(event: "result", json: json)
            }

            client.endSSE()
            return
        }

        // Send initial progress
        client.sendSSEJSON(event: "progress", json: [
            "step": "starting",
            "message": "Starting daily briefing generation...",
            "icon": "🚀",
            "progress": 0
        ])

        do {
            // Generate the briefing with real progress callbacks
            let briefing = try await alfredService.generateDailyBriefingWithProgress(for: date) { step, message, progress in
                let icon: String
                switch step {
                case "messages": icon = "💬"
                case "calendar": icon = "📅"
                case "notion": icon = "📓"
                case "analysis": icon = "🤖"
                case "complete": icon = "✅"
                default: icon = "⏳"
                }

                client.sendSSEJSON(event: "progress", json: [
                    "step": step,
                    "message": message,
                    "icon": icon,
                    "progress": progress
                ])
            }

            // Send the final result (include actionItems for "Add to Notion" UI)
            let formattedResponse = formatBriefingForAPI(briefing)
            let actionItemsData = briefing.actionItems.map { item in
                [
                    "id": item.id,
                    "title": item.title,
                    "description": item.description,
                    "source": item.source.rawValue,
                    "priority": item.priority.rawValue,
                    "dueDate": item.dueDate.map { Self.iso8601Formatter.string(from: $0) } as Any,
                    "category": item.category.rawValue
                ] as [String: Any]
            }

            client.sendSSEJSON(event: "result", json: [
                "response": formattedResponse,
                "date": Self.iso8601Formatter.string(from: briefing.date),
                "generatedAt": Self.iso8601Formatter.string(from: briefing.generatedAt),
                "stats": [
                    "meetings": briefing.calendarBriefing.schedule.events.count,
                    "messages": briefing.messagingSummary.stats.totalMessages,
                    "focusTimeSeconds": briefing.calendarBriefing.focusTime
                ],
                "actionItems": actionItemsData
            ])

        } catch {
            client.sendSSEJSON(event: "error", json: [
                "error": error.localizedDescription,
                "step": "failed"
            ])
        }

        client.endSSE()
    }

    /// Stream calendar briefing generation with progress updates
    private func handleStreamingCalendar(_ request: HTTPRequest, client: ClientSocket) async {
        client.beginSSE()

        let date = parseDate(from: request.queryParams["date"])
        let calendar = request.queryParams["calendar"] ?? "all"
        let dateStr = Self.iso8601Formatter.string(from: date)

        let calendarLabel = calendar == "all" ? "all calendars" : "\(calendar) calendar"

        // Check cache first for instant response (10 min TTL for calendar)
        let cacheParams = ["date": dateStr, "calendar": calendar]
        if let cached = cache.getCached(endpoint: "/api/calendar", params: cacheParams) {
            print("⚡ Returning cached streaming calendar for \(dateStr.prefix(10))")

            // Send quick progress animation
            client.sendSSEJSON(event: "progress", json: [
                "step": "cache",
                "message": "Loading cached calendar...",
                "icon": "⚡",
                "progress": 50
            ])

            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms for UI feedback

            client.sendSSEJSON(event: "progress", json: [
                "step": "complete",
                "message": "Ready!",
                "icon": "✅",
                "progress": 100
            ])

            // Parse cached response and send as result
            if let data = cached.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                client.sendSSEJSON(event: "result", json: json)
            }

            client.endSSE()
            return
        }

        client.sendSSEJSON(event: "progress", json: [
            "step": "starting",
            "message": "Loading \(calendarLabel)...",
            "icon": "📅",
            "progress": 0
        ])

        client.sendSSEJSON(event: "progress", json: [
            "step": "fetching",
            "message": "Connecting to Google Calendar...",
            "icon": "🔗",
            "progress": 25
        ])

        client.sendSSEJSON(event: "progress", json: [
            "step": "analyzing",
            "message": "Analyzing meetings...",
            "icon": "🔍",
            "progress": 50
        ])

        do {
            let briefing = try await alfredService.fetchCalendarBriefing(for: date, calendar: calendar)

            client.sendSSEJSON(event: "progress", json: [
                "step": "complete",
                "message": "Found \(briefing.schedule.events.count) events",
                "icon": "✅",
                "progress": 100
            ])

            // Send full result using the same format as non-streaming endpoint
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

            // Build full response body matching non-streaming endpoint
            let responseBody: [String: Any] = [
                "response": formattedResponse,
                "calendar": calendar,
                "schedule": [
                    "date": Self.iso8601Formatter.string(from: briefing.schedule.date),
                    "events": briefing.schedule.events.map { event in
                        [
                            "id": event.id,
                            "title": event.title,
                            "start": Self.iso8601Formatter.string(from: event.startTime),
                            "end": Self.iso8601Formatter.string(from: event.endTime),
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
                            "start": Self.iso8601Formatter.string(from: meeting.event.startTime),
                            "end": Self.iso8601Formatter.string(from: meeting.event.endTime)
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

            // Cache result (10 min TTL)
            if let jsonData = try? JSONSerialization.data(withJSONObject: responseBody),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                cache.cache(endpoint: "/api/calendar", params: cacheParams, response: jsonString, ttl: 600)
            }

            client.sendSSEJSON(event: "result", json: responseBody)

        } catch {
            client.sendSSEJSON(event: "error", json: [
                "error": error.localizedDescription
            ])
        }

        client.endSSE()
    }

    /// Stream messages summary with progress updates
    private func handleStreamingMessages(_ request: HTTPRequest, client: ClientSocket) async {
        client.beginSSE()

        let platform = request.queryParams["platform"] ?? "all"
        let timeframe = request.queryParams["timeframe"] ?? "24h"

        // Check cache first for instant response (10 min TTL for messages)
        let cacheParams = ["platform": platform, "timeframe": timeframe]
        if let cached = cache.getCached(endpoint: "/api/messages", params: cacheParams) {
            print("⚡ Returning cached streaming messages for \(platform)/\(timeframe)")

            // Send quick progress animation
            client.sendSSEJSON(event: "progress", json: [
                "step": "cache",
                "message": "Loading cached messages...",
                "icon": "⚡",
                "progress": 50
            ])

            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms for UI feedback

            client.sendSSEJSON(event: "progress", json: [
                "step": "complete",
                "message": "Ready!",
                "icon": "✅",
                "progress": 100
            ])

            // Parse cached response and send as result
            if let data = cached.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                client.sendSSEJSON(event: "result", json: json)
            }

            client.endSSE()
            return
        }

        // Send progress stages
        client.sendSSEJSON(event: "progress", json: [
            "step": "starting",
            "message": "Scanning messages...",
            "icon": "💬",
            "progress": 0
        ])

        if platform == "whatsapp" || platform == "all" {
            client.sendSSEJSON(event: "progress", json: [
                "step": "whatsapp",
                "message": "Reading WhatsApp messages...",
                "icon": "📱",
                "progress": 20
            ])
        }

        if platform == "imessage" || platform == "all" {
            client.sendSSEJSON(event: "progress", json: [
                "step": "imessage",
                "message": "Reading iMessage...",
                "icon": "💬",
                "progress": 40
            ])
        }

        client.sendSSEJSON(event: "progress", json: [
            "step": "analyzing",
            "message": "AI is analyzing conversations...",
            "icon": "🤖",
            "progress": 70
        ])

        do {
            let summaries = try await alfredService.fetchMessagesSummary(platform: platform, timeframe: timeframe)

            client.sendSSEJSON(event: "progress", json: [
                "step": "complete",
                "message": "Found \(summaries.count) conversation(s)",
                "icon": "✅",
                "progress": 100
            ])

            // Build response
            var formattedResponse = "💬 **Messages Summary** (\(timeframe))\n\n"
            if summaries.isEmpty {
                formattedResponse += "No messages found for this period."
            } else {
                formattedResponse += "**\(summaries.count) Conversations:**\n"
                for summary in summaries.prefix(10) {
                    let msgCount = summary.thread.messages.count
                    formattedResponse += "• **\(summary.thread.contactName ?? "Unknown")**: \(msgCount) messages\n"
                }
            }

            let responseBody: [String: Any] = [
                "response": formattedResponse,
                "summaries": summaries.map { serializeMessageSummary($0) },
                "count": summaries.count
            ]

            // Cache result (10 min TTL)
            if let jsonData = try? JSONSerialization.data(withJSONObject: responseBody),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                cache.cache(endpoint: "/api/messages", params: cacheParams, response: jsonString, ttl: 600)
            }

            client.sendSSEJSON(event: "result", json: responseBody)

        } catch {
            client.sendSSEJSON(event: "error", json: [
                "error": error.localizedDescription
            ])
        }

        client.endSSE()
    }

    /// Stream contact-specific message summary with progress updates
    private func handleStreamingMessagesSummary(_ request: HTTPRequest, client: ClientSocket) async {
        client.beginSSE()

        guard let contact = request.queryParams["contact"] else {
            client.sendSSEJSON(event: "error", json: ["error": "Missing 'contact' parameter"])
            client.endSSE()
            return
        }

        let platform = request.queryParams["platform"] ?? "whatsapp"
        let timeframe = request.queryParams["timeframe"] ?? "7d"

        // Send progress stages
        client.sendSSEJSON(event: "progress", json: [
            "step": "starting",
            "message": "Finding messages from \(contact)...",
            "icon": "🔍",
            "progress": 0
        ])

        client.sendSSEJSON(event: "progress", json: [
            "step": "reading",
            "message": "Reading \(platform) messages...",
            "icon": platform == "whatsapp" ? "📱" : "💬",
            "progress": 25
        ])

        client.sendSSEJSON(event: "progress", json: [
            "step": "analyzing",
            "message": "AI is analyzing the conversation...",
            "icon": "🤖",
            "progress": 50
        ])

        do {
            let summary = try await alfredService.getMessagesSummaryForContact(
                contact: contact,
                platform: platform,
                timeframe: timeframe
            )

            client.sendSSEJSON(event: "progress", json: [
                "step": "formatting",
                "message": "Preparing summary...",
                "icon": "📝",
                "progress": 85
            ])

            client.sendSSEJSON(event: "progress", json: [
                "step": "complete",
                "message": "Analysis complete!",
                "icon": "✅",
                "progress": 100
            ])

            // Format response (matching non-streaming handler)
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

            // Build response body matching non-streaming handler
            let responseBody: [String: Any] = [
                "response": formattedResponse,
                "contact": contact,
                "platform": platform,
                "timeframe": timeframe,
                "summary": summary.summary,
                "keyPoints": summary.keyPoints,
                "needsResponse": summary.needsResponse,
                "messageCount": summary.messageCount,
                "actionItems": summary.actionItems.map { item in
                    [
                        "id": UUID().uuidString,
                        "title": item.item,
                        "priority": item.priority,
                        "deadline": item.deadline as Any,
                        "source": "message",
                        "category": "task"
                    ] as [String: Any]
                }
            ]

            client.sendSSEJSON(event: "result", json: responseBody)

        } catch {
            client.sendSSEJSON(event: "error", json: [
                "error": error.localizedDescription
            ])
        }

        client.endSSE()
    }

    /// Stream attention check with progress updates
    private func handleStreamingAttentionCheck(_ request: HTTPRequest, client: ClientSocket) async {
        client.beginSSE()

        // Check cache first for instant response (1 hour TTL for attention check)
        if let cached = cache.getCached(endpoint: "/api/attention-check", params: [:]) {
            print("⚡ Returning cached streaming attention check")

            // Send quick progress animation
            client.sendSSEJSON(event: "progress", json: [
                "step": "cache",
                "message": "Loading cached attention check...",
                "icon": "⚡",
                "progress": 50
            ])

            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms for UI feedback

            client.sendSSEJSON(event: "progress", json: [
                "step": "complete",
                "message": "Ready!",
                "icon": "✅",
                "progress": 100
            ])

            // Parse cached response and send as result
            if let data = cached.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                client.sendSSEJSON(event: "result", json: json)
            }

            client.endSSE()
            return
        }

        // Send initial progress
        client.sendSSEJSON(event: "progress", json: [
            "step": "starting",
            "message": "Starting attention check...",
            "icon": "🎯",
            "progress": 0
        ])

        do {
            // Use the streaming version with real progress callbacks
            let report = try await alfredService.generateAttentionCheckWithProgress { step, message, progress in
                // Map step names to icons
                let icon: String
                switch step {
                case "calendar_today", "calendar_tomorrow":
                    icon = "📅"
                case "tasks":
                    icon = "📓"
                case "favorites":
                    icon = "⭐"
                case "analyzing":
                    icon = "🤖"
                case "notifications":
                    icon = "📧"
                case "complete":
                    icon = "✅"
                default:
                    icon = "⏳"
                }

                client.sendSSEJSON(event: "progress", json: [
                    "step": step,
                    "message": message,
                    "icon": icon,
                    "progress": progress
                ])
            }

            client.sendSSEJSON(event: "progress", json: [
                "step": "formatting",
                "message": "Preparing recommendations...",
                "icon": "📝",
                "progress": 85
            ])

            // Get favorites for highlighting
            let favorites = FavoritesService.shared.getFavorites()

            // Calculate time remaining for response
            let calendar = Calendar.current
            let endOfDay = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: report.currentTime)!
            let timeRemaining = max(0, endOfDay.timeIntervalSince(report.currentTime))

            // Use shared formatting helper (Notion-inspired layout)
            let formattedResponse = formatAttentionCheckReport(report, favorites: favorites)

            client.sendSSEJSON(event: "progress", json: [
                "step": "complete",
                "message": "Analysis complete!",
                "icon": "✅",
                "progress": 100
            ])

            // Send full result
            let responseBody: [String: Any] = [
                "response": formattedResponse,
                "currentTime": Self.iso8601Formatter.string(from: report.currentTime),
                "timeRemaining": timeRemaining,
                "mustDoToday": report.mustDoToday.map { item in
                    [
                        "id": item.id,
                        "title": item.title,
                        "description": item.description,
                        "priority": item.priority.rawValue,
                        "dueDate": item.dueDate.map { Self.iso8601Formatter.string(from: $0) } as Any,
                        "counterparty": item.counterparty as Any,
                        "isFavorite": item.counterparty.map { favorites.isFavorite($0) } ?? false
                    ] as [String: Any]
                },
                "canPushOff": report.canPushOff.map { suggestion in
                    [
                        "item": [
                            "id": suggestion.item.id,
                            "title": suggestion.item.title,
                            "description": suggestion.item.description
                        ],
                        "reason": suggestion.reason,
                        "suggestedNewDate": Self.iso8601Formatter.string(from: suggestion.suggestedNewDate),
                        "impact": suggestion.impact.rawValue
                    ] as [String: Any]
                },
                "recommendations": report.recommendations,
                "stats": [
                    "mustDoCount": report.mustDoToday.count,
                    "canPushCount": report.canPushOff.count,
                    "totalTasks": report.mustDoToday.count + report.canPushOff.count
                ]
            ]

            // Cache result (1 hour TTL - shorter than non-streaming's 4 hours for freshness)
            if let jsonData = try? JSONSerialization.data(withJSONObject: responseBody),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                cache.cache(endpoint: "/api/attention-check", params: [:], response: jsonString, ttl: 3600)
            }

            client.sendSSEJSON(event: "result", json: responseBody)

        } catch {
            client.sendSSEJSON(event: "error", json: [
                "error": error.localizedDescription
            ])
        }

        client.endSSE()
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
    /// Uses static formatters for performance.
    private func parseDate(from dateString: String?) -> Date {
        guard let dateString = dateString else {
            return Date()
        }

        // Try full ISO8601 format first (e.g., "2026-01-27T00:00:00Z")
        if let parsedDate = Self.iso8601Formatter.date(from: dateString) {
            return parsedDate
        }

        // Try date-only ISO8601 format (e.g., "2026-01-27")
        if let parsedDate = Self.iso8601DateOnlyFormatter.date(from: dateString) {
            return parsedDate
        }

        // Fallback: try DateFormatter for YYYY-MM-DD with local timezone
        return Self.simpleDateFormatter.date(from: dateString) ?? Date()
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
        guard Darwin.listen(socket, 128) >= 0 else {
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
                    // URL decode the parameter value (+ → space, then percent-decode)
                    let plusDecoded = keyValue[1].replacingOccurrences(of: "+", with: " ")
                    let decodedValue = plusDecoded.removingPercentEncoding ?? plusDecoded
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

    /// Send SSE headers to begin a streaming response
    func beginSSE() {
        let headers = """
        HTTP/1.1 200 OK\r
        Content-Type: text/event-stream; charset=utf-8\r
        Cache-Control: no-cache\r
        Connection: keep-alive\r
        Access-Control-Allow-Origin: *\r
        \r

        """
        if let data = headers.data(using: .utf8) {
            data.withUnsafeBytes { rawBuffer in
                if let ptr = rawBuffer.baseAddress {
                    _ = Darwin.send(socket, ptr, data.count, 0)
                }
            }
        }
    }

    /// Send an SSE event with optional event type
    func sendSSE(event: String? = nil, data: String) {
        var message = ""
        if let event = event {
            message += "event: \(event)\n"
        }
        // Handle multi-line data by prefixing each line with "data: "
        for line in data.components(separatedBy: "\n") {
            message += "data: \(line)\n"
        }
        message += "\n"

        // Use UTF-8 data directly to avoid issues with multi-byte characters
        if let data = message.data(using: .utf8) {
            data.withUnsafeBytes { rawBuffer in
                if let ptr = rawBuffer.baseAddress {
                    _ = Darwin.send(socket, ptr, data.count, 0)
                }
            }
        }
    }

    /// Send a JSON object as SSE data
    func sendSSEJSON(event: String? = nil, json: [String: Any]) {
        if let jsonData = try? JSONSerialization.data(withJSONObject: json),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            sendSSE(event: event, data: jsonString)
        }
    }

    /// Send SSE completion and close
    func endSSE() {
        sendSSE(event: "done", data: "{}")
    }

    private func statusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 302: return "Found"
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

    /// Format Attention Check report in Notion-inspired clean layout
    private func formatAttentionCheckReport(_ report: AttentionDefenseReport, favorites: Favorites) -> String {
        var output = ""

        // Header
        output += "🎯 **Attention Check** — \(report.currentTime.formatted(date: .abbreviated, time: .shortened))\n\n"

        // Time remaining
        let calendar = Calendar.current
        let endOfDay = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: report.currentTime)!
        let timeRemaining = max(0, endOfDay.timeIntervalSince(report.currentTime))
        let hoursRemaining = Int(timeRemaining / 3600)
        let minutesRemaining = Int((timeRemaining.truncatingRemainder(dividingBy: 3600)) / 60)
        output += "⏱️ **\(hoursRemaining)h \(minutesRemaining)m** remaining in your workday\n"

        // ═══════════════════════════════════════════════════════════════════
        // MUST DO TODAY - Card layout
        // ═══════════════════════════════════════════════════════════════════
        if !report.mustDoToday.isEmpty {
            output += "\n\n---\n\n"
            output += "## 🔴 Must Do Today\n"

            for (index, item) in report.mustDoToday.enumerated() {
                let isFavorite = item.counterparty.map { favorites.isFavorite($0) } ?? false

                output += "\n"

                // Title line
                output += "### \(item.title)"
                if isFavorite { output += " ⭐" }
                output += "\n\n"

                // Properties as inline tags
                var tags: [String] = []

                // Priority
                let priorityTag = item.priority == .critical ? "`🔴 Critical`" : item.priority == .high ? "`🟠 High`" : item.priority == .medium ? "`🟡 Medium`" : "`🟢 Low`"
                tags.append(priorityTag)

                // Due date
                if let dueDate = item.dueDate {
                    let isOverdue = dueDate < report.currentTime
                    let dueDateStr = dueDate.formatted(date: .abbreviated, time: .omitted)
                    if isOverdue {
                        tags.append("`⚠️ Overdue: \(dueDateStr)`")
                    } else {
                        tags.append("`📅 \(dueDateStr)`")
                    }
                }

                // Counterparty
                if let counterparty = item.counterparty, !counterparty.isEmpty {
                    tags.append("`👤 \(counterparty)`")
                }

                output += tags.joined(separator: "  ") + "\n"

                // Light separator between cards (not after last)
                if index < report.mustDoToday.count - 1 {
                    output += "\n"
                }
            }
        }

        // ═══════════════════════════════════════════════════════════════════
        // CAN PUSH - Compact list
        // ═══════════════════════════════════════════════════════════════════
        if !report.canPushOff.isEmpty {
            output += "\n\n---\n\n"
            output += "## 🟢 Can Push to Tomorrow\n"

            for (index, suggestion) in report.canPushOff.enumerated() {
                let item = suggestion.item
                let isFavorite = item.counterparty.map { favorites.isFavorite($0) } ?? false

                output += "\n"

                // Title
                output += "**\(item.title)**"
                if isFavorite { output += " ⭐" }
                output += "\n"

                // Reason in italics
                output += "_\(suggestion.reason)_"

                // Impact indicator
                if suggestion.impact == .high {
                    output += "  `⚡ High impact`"
                } else if suggestion.impact == .medium {
                    output += "  `⚡ Medium`"
                }
                output += "\n"

                if index < report.canPushOff.count - 1 {
                    output += "\n"
                }
            }
        }

        // ═══════════════════════════════════════════════════════════════════
        // RECOMMENDATIONS - Callout style
        // ═══════════════════════════════════════════════════════════════════
        if !report.recommendations.isEmpty {
            output += "\n\n---\n\n"
            output += "## 💡 Recommendations\n\n"

            for (index, rec) in report.recommendations.enumerated() {
                output += "**\(index + 1).** \(rec)\n\n"
            }
        }

        // ═══════════════════════════════════════════════════════════════════
        // EMPTY STATE
        // ═══════════════════════════════════════════════════════════════════
        if report.mustDoToday.isEmpty && report.canPushOff.isEmpty {
            output += "\n\n---\n\n"
            output += "## ✨ All Clear\n\n"
            output += "No urgent tasks requiring immediate attention.\n\n"
            output += "**Consider using this time for:**\n"
            output += "- Deep work on important projects\n"
            output += "- Planning for next week\n"
            output += "- Catching up on reading or learning\n"
        }

        return output
    }

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
            output += "**\(briefing.schedule.events.count) Events:**\n"
            for event in briefing.schedule.events {
                let startTime = event.startTime.formatted(date: .omitted, time: .shortened)
                output += "• \(startTime) - \(event.title)\n"
            }
        } else {
            output += "No events scheduled.\n"
        }

        // Include meeting briefings with context (this is the important part!)
        if !briefing.meetingBriefings.isEmpty {
            output += "\n---\n\n**📋 Meeting Insights:**\n\n"
            for meeting in briefing.meetingBriefings {
                output += "**\(meeting.event.title)**\n"

                if let context = meeting.context, !context.isEmpty {
                    output += "\(context)\n"
                }

                if !meeting.preparation.isEmpty {
                    output += "\n*Preparation:* \(meeting.preparation)\n"
                }

                if !meeting.attendeeBriefings.isEmpty {
                    output += "\n*Key Attendees:*\n"
                    for attendeeBriefing in meeting.attendeeBriefings.prefix(3) {
                        let name = attendeeBriefing.attendee.name ?? attendeeBriefing.attendee.email
                        output += "  • \(name)"
                        let domain = attendeeBriefing.attendee.email.components(separatedBy: "@").last ?? ""
                        if !domain.isEmpty && !domain.contains("gmail") && !domain.contains("yahoo") {
                            output += " (\(domain))"
                        }
                        output += "\n"
                        if !attendeeBriefing.bio.isEmpty {
                            output += "    \(attendeeBriefing.bio)\n"
                        }
                    }
                }

                if !meeting.suggestedTopics.isEmpty {
                    output += "\n*Suggested Topics:*\n"
                    for topic in meeting.suggestedTopics {
                        output += "  • \(topic)\n"
                    }
                }

                output += "\n"
            }
        }

        if !briefing.recommendations.isEmpty {
            output += "**💡 Recommendations:**\n"
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
                        "timestamp": Self.iso8601Formatter.string(from: correction.timestamp)
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

    // MARK: - Contact Learning Handlers

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
        // Invalidate the config cache so next request reads fresh from disk
        _cachedConfig = nil
        _configLoadTime = nil

        if HotReloadManager.shared.reloadConfig() != nil {
            return HTTPResponse(
                statusCode: 200,
                body: [
                    "success": true,
                    "message": "Configuration reloaded successfully",
                    "timestamp": Self.iso8601Formatter.string(from: Date())
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

    // MARK: - Task Lifecycle Handlers

    // Store last scan result for retrieval
    private static var lastScanResult: ScanResult?
    private static var lastScanError: String?

    private func handleTaskLifecycleScan() async -> HTTPResponse {
        // Check if scan is already in progress
        if TaskLifecycleTracker.shared.isScanInProgress() {
            if let progress = TaskLifecycleTracker.shared.getScanProgress() {
                return HTTPResponse(
                    statusCode: 202,  // Accepted - scan in progress
                    body: [
                        "inProgress": true,
                        "phase": progress.phase,
                        "tasksProcessed": progress.tasksProcessed,
                        "pagesLoaded": progress.pagesLoaded
                    ]
                )
            }
        }

        // Get NotionService from AlfredService orchestrator
        // Note: AlfredService is NOT @MainActor, so we can access it directly
        guard let orchestrator = alfredService.orchestrator else {
            return HTTPResponse(
                statusCode: 500,
                body: ["error": "Alfred not initialized"]
            )
        }

        let notionService = orchestrator.notionServicePublic

        // Mark scan as starting BEFORE spawning background task
        // This ensures progress polling shows something immediately
        TaskLifecycleTracker.shared.startScan()

        // Start scan in background task and return immediately
        let server = self
        Task.detached {
            do {
                let result = try await TaskLifecycleTracker.shared.scan(notionService: notionService)
                Self.lastScanResult = result
                Self.lastScanError = nil
                // Invalidate affected caches after scan completes
                server.invalidateMemoryCache("lifecycle_stats")
                server.invalidateMemoryCache("home_pulse")
                server.cache.deleteByEndpoint("/api/home/pulse")
                print("✓ Background scan complete: \(result.tasksScanned) tasks")
            } catch {
                Self.lastScanError = error.localizedDescription
                Self.lastScanResult = nil
                print("✗ Background scan failed: \(error.localizedDescription)")
            }
        }

        // Return 202 Accepted immediately - client should poll /progress
        return HTTPResponse(
            statusCode: 202,
            body: [
                "inProgress": true,
                "phase": "Starting scan...",
                "message": "Scan started in background. Poll /api/task-lifecycle/progress for updates."
            ]
        )
    }

    private func handleTaskLifecycleScanProgress() -> HTTPResponse {
        if let progress = TaskLifecycleTracker.shared.getScanProgress() {
            return HTTPResponse(
                statusCode: 200,
                body: [
                    "inProgress": true,
                    "phase": progress.phase,
                    "tasksProcessed": progress.tasksProcessed,
                    "totalEstimated": progress.totalEstimated as Any,
                    "pagesLoaded": progress.pagesLoaded
                ]
            )
        } else {
            // Scan not in progress - return last result if available
            var responseBody: [String: Any] = ["inProgress": false]

            if let result = Self.lastScanResult {
                responseBody["completed"] = true
                responseBody["tasksScanned"] = result.tasksScanned
                responseBody["newTasks"] = result.newTasks
                responseBody["changesDetected"] = result.changesDetected
            }

            if let error = Self.lastScanError {
                responseBody["error"] = error
            }

            return HTTPResponse(
                statusCode: 200,
                body: responseBody
            )
        }
    }

    private func handleTaskLifecycleStats() -> HTTPResponse {
        // Check memory cache (5min TTL)
        if let cached: [String: Any] = getFromMemoryCache("lifecycle_stats") {
            return HTTPResponse(statusCode: 200, body: cached)
        }

        let stats = TaskLifecycleTracker.shared.getStats()

        let body: [String: Any] = [
            "totalTasks": stats.totalTasks,
            "totalChanges": stats.totalChanges,
            "totalCompleted": stats.totalCompleted,
            "completionRate": Int(stats.completionRate * 100),
            "overdueRate": Int(stats.overdueRate * 100),
            "lastScanTime": stats.lastScanTime.map { Self.iso8601Formatter.string(from: $0) } as Any
        ]

        // Cache in memory (5min)
        setInMemoryCache("lifecycle_stats", value: body, ttl: 300)

        return HTTPResponse(statusCode: 200, body: body)
    }

    private func handleTaskLifecycleChanges(_ request: HTTPRequest) -> HTTPResponse {
        let limit = Int(request.queryParams["limit"] ?? "20") ?? 20
        let changes = TaskLifecycleTracker.shared.getRecentChanges(limit: limit)

        return HTTPResponse(
            statusCode: 200,
            body: [
                "changes": changes.map { change in
                    [
                        "notionId": change.notionId,
                        "title": change.title,
                        "oldStatus": change.oldStatus,
                        "newStatus": change.newStatus,
                        "taskType": change.taskType,
                        "priority": change.priority as Any,
                        "counterparty": change.counterparty as Any,
                        "wasOverdue": change.wasOverdue
                    ]
                },
                "count": changes.count
            ]
        )
    }

    private func handleTaskLifecycleCounterparties() -> HTTPResponse {
        let stats = TaskLifecycleTracker.shared.getStatsByCounterparty()

        return HTTPResponse(
            statusCode: 200,
            body: [
                "counterparties": stats.map { stat in
                    [
                        "name": stat.name,
                        "totalTasks": stat.totalTasks,
                        "completedTasks": stat.completedTasks,
                        "completionRate": Int(stat.completionRate * 100),
                        "overdueRate": Int(stat.overdueRate * 100)
                    ]
                },
                "count": stats.count
            ]
        )
    }

    // MARK: - Commitment Tracker Handlers

    private func handleGetCommitmentTrackerStats() async -> HTTPResponse {
        // Check memory cache (5min TTL)
        if let cached: [String: Any] = getFromMemoryCache("tracker_stats") {
            return HTTPResponse(statusCode: 200, body: cached)
        }

        let stats = CommitmentScanTracker.shared.getStats()

        // Also get actual counts from Notion
        var notionOpen = 0
        var notionClosed = 0
        var notionTotal = 0

        if let orchestrator = alfredService.orchestrator {
            do {
                let notionStats = try await orchestrator.notionServicePublic.getCommitmentStatsFromNotion()
                notionOpen = notionStats.open
                notionClosed = notionStats.closed
                notionTotal = notionStats.total
            } catch {
                print("⚠️ Failed to get Notion commitment stats: \(error)")
            }
        }

        let body: [String: Any] = [
            // Notion-based counts (source of truth for open/closed)
            "openCommitments": notionOpen,
            "closedCount": notionClosed,
            "totalCommitments": notionTotal,
            // Tracker stats
            "autoClosedCount": stats.autoClosedCount,
            "pendingClosures": stats.pendingClosures,
            "totalExtracted": stats.totalExtracted,
            "threadsTracked": stats.threadsTracked,
            "favoritesCount": stats.favoritesCount,
            "activeThreadsCount": stats.activeThreadsCount,
            "lastScanTime": stats.lastScanTime.map { Self.iso8601Formatter.string(from: $0) } as Any
        ]

        // Cache in memory (5min)
        setInMemoryCache("tracker_stats", value: body, ttl: 300)

        return HTTPResponse(statusCode: 200, body: body)
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

    private func handleGetRecentClosures() -> HTTPResponse {
        let recentClosures = CommitmentScanTracker.shared.getRecentAutoClosures(limit: 15)

        let response: [[String: Any]] = recentClosures.map { closure in
            [
                "hash": closure.hash,
                "title": closure.title,
                "signal": closure.signal,
                "confidence": closure.confidence,
                "closedAt": closure.closedAt,
                "method": closure.reason
            ]
        }

        return HTTPResponse(
            statusCode: 200,
            body: ["recentClosures": response, "count": recentClosures.count]
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

        // Get the pending closure info for learning before we process it
        let pendingClosures = CommitmentScanTracker.shared.getPendingClosureConfirmations()
        if let closure = pendingClosures.first(where: { $0.hash == hash }) {
            // Record the closure feedback for learning
            WorkflowLearningService.shared.recordClosureDetectionFeedback(
                commitmentHash: hash,
                commitmentTitle: closure.title,
                signal: closure.signal,
                aiConfidence: closure.confidence,
                userAccepted: true
            )
        }

        // Mark as closed in tracker (also records learning event)
        CommitmentScanTracker.shared.markCommitmentClosed(hash: hash, closureMethod: "user-confirmed")

        // Invalidate affected caches
        invalidateMemoryCache("tracker_stats")
        invalidateMemoryCache("home_pulse")
        cache.deleteByEndpoint("/api/home/pulse")

        // Also close in Notion via AlfredService
        do {
            try await alfredService.closeCommitmentByHash(hash: hash, reason: "User confirmed closure")
            return HTTPResponse(
                statusCode: 200,
                body: ["success": true, "message": "Commitment closed"]
            )
        } catch {
            // Still return success since the local tracker was updated
            return HTTPResponse(
                statusCode: 200,
                body: ["success": true, "message": "Commitment closed (Notion update may have failed)"]
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

        // Get the pending closure info for learning before we process it
        let pendingClosures = CommitmentScanTracker.shared.getPendingClosureConfirmations()
        if let closure = pendingClosures.first(where: { $0.hash == hash }) {
            // Record the rejection for learning
            WorkflowLearningService.shared.recordClosureDetectionFeedback(
                commitmentHash: hash,
                commitmentTitle: closure.title,
                signal: closure.signal,
                aiConfidence: closure.confidence,
                userAccepted: false
            )
        }

        // Mark the closure detection as rejected
        CommitmentScanTracker.shared.rejectClosureDetection(hash: hash)

        // Invalidate affected caches
        invalidateMemoryCache("tracker_stats")

        return HTTPResponse(
            statusCode: 200,
            body: ["success": true, "message": "Closure suggestion rejected"]
        )
    }

    // MARK: - Dedup Cleanup

    /// Deduplicate open commitments in Notion and reset local tracker DB
    private func handleDedupCleanup() async -> HTTPResponse {
        guard let orchestrator = alfredService.orchestrator else {
            return HTTPResponse(statusCode: 500, body: ["error": "Service not initialized"])
        }

        do {
            // Step 1: Archive duplicate Notion pages
            let (archived, groups) = try await orchestrator.notionServicePublic.deduplicateCommitments()

            // Step 2: Reset local commitment tracker DB so new hashes take effect
            let tracker = CommitmentScanTracker.shared
            tracker.resetExtractions()

            // Invalidate caches
            invalidateMemoryCache("tracker_stats")
            invalidateMemoryCache("home_pulse")
            cache.deleteByEndpoint("/api/home/pulse")

            return HTTPResponse(
                statusCode: 200,
                body: [
                    "success": true,
                    "archived": archived,
                    "groups_affected": groups,
                    "local_db_reset": true
                ]
            )
        } catch {
            return HTTPResponse(
                statusCode: 500,
                body: ["error": "Dedup cleanup failed: \(error.localizedDescription)"]
            )
        }
    }

    // MARK: - Orphan Cleanup

    private func handleCleanupOrphans() -> HTTPResponse {
        let result = CommitmentScanTracker.shared.cleanupOrphanedData()

        // Invalidate caches
        invalidateMemoryCache("tracker_stats")
        invalidateMemoryCache("home_pulse")
        cache.deleteByEndpoint("/api/home/pulse")

        return HTTPResponse(
            statusCode: 200,
            body: [
                "success": true,
                "orphaned_closures_removed": result.orphanedClosures,
                "stale_pending_rejected": result.stalePending
            ]
        )
    }

    // MARK: - Bidirectional Notion Sync

    private func handleSyncFromNotion() async -> HTTPResponse {
        do {
            let synced = try await alfredService.syncCommitmentsFromNotion()

            if synced > 0 {
                invalidateMemoryCache("tracker_stats")
                invalidateMemoryCache("home_pulse")
                cache.deleteByEndpoint("/api/home/pulse")
            }

            return HTTPResponse(
                statusCode: 200,
                body: [
                    "success": true,
                    "synced_from_notion": synced
                ]
            )
        } catch {
            return HTTPResponse(
                statusCode: 500,
                body: ["error": "Notion sync failed: \(error.localizedDescription)"]
            )
        }
    }

    // MARK: - Cadence Helpers

    /// Update keys in ~/.alfred/scheduler_state.json (used by cadence handlers to record last-run time)
    private func updateSchedulerState(_ updates: [String: String]) {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let statePath = "\(homeDir)/.alfred/scheduler_state.json"
        var stateJson: [String: Any] = [:]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            stateJson = json
        }
        for (key, value) in updates {
            stateJson[key] = value
        }
        if let stateData = try? JSONSerialization.data(withJSONObject: stateJson, options: [.prettyPrinted, .sortedKeys]) {
            try? stateData.write(to: URL(fileURLWithPath: statePath))
        }
    }

    /// Read scheduler state as raw dictionary (no struct decoding, preserves all keys)
    private func loadSchedulerStateRaw() -> [String: Any] {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let statePath = "\(homeDir)/.alfred/scheduler_state.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    // MARK: - JSON Response Helper

    private func jsonResponse(_ body: [String: Any], status: Int = 200) -> HTTPResponse {
        return HTTPResponse(statusCode: status, body: body)
    }

    // MARK: - Cadence CRUD Handlers

    private func handleGetCadences() -> HTTPResponse {
        let cadences = CadenceService.shared.getAll()
        let cadenceList = cadences.map { $0.toDictionary() }
        return jsonResponse(["cadences": cadenceList, "count": cadences.count])
    }

    private func handleGetToolCatalog() -> HTTPResponse {
        let catalog = CadenceActionType.catalog.map { $0.toDictionary() }
        return jsonResponse(["tools": catalog, "count": catalog.count])
    }

    private func handleCreateCadence(_ request: HTTPRequest) -> HTTPResponse {
        guard let body = request.body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return jsonResponse(["error": "Invalid JSON body"], status: 400)
        }

        guard let name = json["name"] as? String, !name.isEmpty else {
            return jsonResponse(["error": "Missing required field: name"], status: 400)
        }
        guard let actionTypeStr = json["action_type"] as? String,
              let actionType = CadenceActionType(rawValue: actionTypeStr) else {
            return jsonResponse(["error": "Missing or invalid action_type"], status: 400)
        }
        guard let scheduleDict = json["schedule"] as? [String: Any],
              let schedule = parseSchedule(scheduleDict) else {
            return jsonResponse(["error": "Missing or invalid schedule"], status: 400)
        }

        let icon = json["icon"] as? String ?? "⚙️"
        let enabled = json["enabled"] as? Bool ?? true
        let notifyOnSuccess = json["notify_on_success"] as? Bool ?? true
        let emailOnSuccess = json["email_on_success"] as? Bool ?? false
        let catchUpWindowHours = json["catch_up_window_hours"] as? Int ?? 3
        let params = parseJSONParams(json["params"] as? [String: Any] ?? [:])

        let cadence = Cadence(
            id: "user-\(UUID().uuidString.prefix(8).lowercased())",
            name: name,
            icon: icon,
            actionType: actionType,
            params: params,
            schedule: schedule,
            enabled: enabled,
            isBuiltIn: false,
            catchUpWindowHours: catchUpWindowHours,
            notifyOnSuccess: notifyOnSuccess,
            emailOnSuccess: emailOnSuccess
        )

        do {
            try CadenceService.shared.create(cadence)
            return jsonResponse(["success": true, "cadence": cadence.toDictionary()], status: 201)
        } catch {
            return jsonResponse(["error": error.localizedDescription], status: 400)
        }
    }

    private func handleUpdateCadence(_ request: HTTPRequest) -> HTTPResponse {
        guard let body = request.body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return jsonResponse(["error": "Invalid JSON body"], status: 400)
        }

        guard let id = json["id"] as? String else {
            return jsonResponse(["error": "Missing required field: id"], status: 400)
        }
        guard var cadence = CadenceService.shared.get(id: id) else {
            return jsonResponse(["error": "Cadence not found: \(id)"], status: 404)
        }

        // Apply updates
        if let name = json["name"] as? String { cadence.name = name }
        if let icon = json["icon"] as? String { cadence.icon = icon }
        if let enabled = json["enabled"] as? Bool { cadence.enabled = enabled }
        if let notifyOnSuccess = json["notify_on_success"] as? Bool { cadence.notifyOnSuccess = notifyOnSuccess }
        if let emailOnSuccess = json["email_on_success"] as? Bool { cadence.emailOnSuccess = emailOnSuccess }
        if let catchUpWindowHours = json["catch_up_window_hours"] as? Int { cadence.catchUpWindowHours = catchUpWindowHours }
        if let scheduleDict = json["schedule"] as? [String: Any], let schedule = parseSchedule(scheduleDict) {
            cadence.schedule = schedule
        }
        if let paramsDict = json["params"] as? [String: Any] {
            cadence.params = parseJSONParams(paramsDict)
        }
        if let actionTypeStr = json["action_type"] as? String,
           let actionType = CadenceActionType(rawValue: actionTypeStr) {
            cadence.actionType = actionType
        }

        do {
            try CadenceService.shared.update(cadence)
            return jsonResponse(["success": true, "cadence": cadence.toDictionary()])
        } catch {
            return jsonResponse(["error": error.localizedDescription], status: 400)
        }
    }

    private func handleDeleteCadence(_ request: HTTPRequest) -> HTTPResponse {
        guard let id = request.queryParams["id"] else {
            return jsonResponse(["error": "Missing query parameter: id"], status: 400)
        }
        do {
            try CadenceService.shared.delete(id: id)
            return jsonResponse(["success": true, "deleted": id])
        } catch let error as CadenceError where error.localizedDescription.contains("built-in") {
            return jsonResponse(["error": error.localizedDescription], status: 403)
        } catch {
            return jsonResponse(["error": error.localizedDescription], status: 404)
        }
    }

    private func handleRunCadence(_ request: HTTPRequest) -> HTTPResponse {
        guard let body = request.body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let id = json["id"] as? String else {
            return jsonResponse(["error": "Missing id in request body"], status: 400)
        }
        guard let cadence = CadenceService.shared.get(id: id) else {
            return jsonResponse(["error": "Cadence not found: \(id)"], status: 404)
        }
        guard let runner = cadenceRunner else {
            return jsonResponse(["error": "CadenceRunner not available"], status: 503)
        }

        // Run async — return immediately with accepted status, fire in background
        Task {
            do {
                let summary = try await runner.run(cadence)
                let timestamp = Self.iso8601Formatter.string(from: Date())
                // Manual runs update display timestamp only — don't suppress the scheduled run
                CadenceService.shared.markManualRunSuccess(id: cadence.id, timestamp: timestamp, summary: summary)
                print("✅ [API] Manual cadence run \(cadence.name): \(summary)")
            } catch {
                CadenceService.shared.markRunFailure(id: cadence.id, cooldownMinutes: 5, errorMessage: "\(error)")
                print("❌ [API] Manual cadence run \(cadence.name) failed: \(error)")
            }
        }

        return jsonResponse(["success": true, "message": "Cadence '\(cadence.name)' started", "id": id], status: 202)
    }

    // MARK: Cadence Parsing Helpers

    private func parseSchedule(_ dict: [String: Any]) -> CadenceSchedule? {
        guard let type = dict["type"] as? String else { return nil }
        switch type {
        case "daily":
            guard let time = dict["time"] as? String else { return nil }
            return .daily(time: time)
        case "weekly":
            guard let day = dict["day"] as? String, let time = dict["time"] as? String else { return nil }
            return .weekly(day: day, time: time)
        case "interval":
            guard let hours = dict["hours"] as? Int else { return nil }
            let activeStart = dict["active_start"] as? Int ?? 0
            let activeEnd = dict["active_end"] as? Int ?? 23
            return .interval(hours: hours, activeStart: activeStart, activeEnd: activeEnd)
        default:
            return nil
        }
    }

    private func parseJSONParams(_ dict: [String: Any]) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for (key, value) in dict {
            if let s = value as? String {
                result[key] = .string(s)
            } else if let i = value as? Int {
                result[key] = .int(i)
            } else if let b = value as? Bool {
                result[key] = .bool(b)
            } else if let arr = value as? [String] {
                result[key] = .stringArray(arr)
            } else {
                result[key] = .null
            }
        }
        return result
    }

    // MARK: - Legacy Cadence Handlers (backward compat)

    private func handleCadenceStatus() -> HTTPResponse {
        // Remap to CadenceService for backward compatibility with old UI
        let cadences = CadenceService.shared.getAll()
        var status: [String: Any] = [:]

        for c in cadences {
            let key: String
            switch c.actionType {
            case .todoScan: key = "todoScan"
            case .commitmentScan: key = "commitmentScan"
            case .patternLearning: key = "patternLearn"
            case .groupAnalysis: key = "groupAnalysis"
            case .autoSummary: key = "autoSummary"
            default: continue
            }

            var entry: [String: Any] = [
                "enabled": c.enabled,
                "lastRun": c.lastRunTimestamp ?? c.lastRunDate ?? NSNull()
            ]
            switch c.schedule {
            case .daily(let time):
                entry["time"] = time
            case .weekly(let day, let time):
                entry["day"] = day
                entry["time"] = time
            case .interval(let hours, _, _):
                entry["intervalHours"] = hours
            }
            if c.actionType == .autoSummary {
                entry["groups"] = c.params["groups"]?.stringArrayValue ?? []
            }
            status[key] = entry
        }

        return HTTPResponse(statusCode: 200, body: status)
    }

    private func handleGetGroupSuggestions() -> HTTPResponse {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let suggestionsPath = "\(homeDir)/.alfred/group_suggestions.json"

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: suggestionsPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return HTTPResponse(statusCode: 200, body: [
                "suggestions": [],
                "message": "No group analysis has run yet. It runs weekly on Monday mornings."
            ])
        }

        return HTTPResponse(statusCode: 200, body: json)
    }

    private func handleRunGroupAnalysis() async -> HTTPResponse {
        do {
            guard let config = getConfig() else {
                return HTTPResponse(statusCode: 500, body: ["error": "Config not available"])
            }

            // 1. Read WhatsApp threads from last 7 days
            let whatsappReader = WhatsAppReader.shared(dbPath: config.messaging.whatsapp.dbPath)
            try whatsappReader.connect()
            let since = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
            let threads = try whatsappReader.fetchThreads(since: since)
            whatsappReader.disconnect()

            // 2. Filter for groups and sort by message count
            let groupThreads = threads
                .filter { $0.contactIdentifier.contains("@g.us") }
                .sorted { $0.messages.count > $1.messages.count }

            // 3. Busy groups = 20+ messages/week
            let busyGroups = groupThreads.filter { $0.messages.count >= 20 }

            // 4. Exclude already-approved auto-summary groups
            let existingAutoGroups = config.cadence?.autoSummaryGroups ?? []
            let suggestions = busyGroups
                .filter { thread in
                    let name = thread.contactName ?? thread.contactIdentifier
                    return !existingAutoGroups.contains(where: { $0.lowercased() == name.lowercased() })
                }
                .prefix(10)
                .map { thread -> [String: Any] in
                    [
                        "name": thread.contactName ?? thread.contactIdentifier,
                        "messageCount": thread.messages.count,
                        "contactId": thread.contactIdentifier
                    ]
                }

            // 5. Save suggestions to ~/.alfred/group_suggestions.json
            let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
            let suggestionsPath = "\(homeDir)/.alfred/group_suggestions.json"
            let todayDate = {
                let fmt = DateFormatter()
                fmt.dateFormat = "yyyy-MM-dd"
                return fmt.string(from: Date())
            }()
            let suggestionsData: [String: Any] = [
                "generated_at": ISO8601DateFormatter().string(from: Date()),
                "week_analyzed": todayDate,
                "suggestions": suggestions,
                "total_groups_scanned": groupThreads.count,
                "busy_groups_found": busyGroups.count
            ]
            if let jsonData = try? JSONSerialization.data(withJSONObject: suggestionsData, options: [.prettyPrinted, .sortedKeys]) {
                try jsonData.write(to: URL(fileURLWithPath: suggestionsPath))
            }

            // 6. Update scheduler state: date key for scheduler, timestamp key for UI
            updateSchedulerState([
                "lastGroupAnalysisDate": todayDate,
                "lastGroupAnalysisTimestamp": ISO8601DateFormatter().string(from: Date())
            ])

            return HTTPResponse(statusCode: 200, body: [
                "success": true,
                "totalGroupsScanned": groupThreads.count,
                "busyGroupsFound": busyGroups.count,
                "newSuggestions": suggestions.count
            ])
        } catch {
            return HTTPResponse(statusCode: 500, body: ["error": "Group analysis failed: \(error.localizedDescription)"])
        }
    }

    private func handleApproveAutoSummary(_ request: HTTPRequest) -> HTTPResponse {
        guard let bodyData = request.body,
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let groups = json["groups"] as? [String], !groups.isEmpty else {
            return HTTPResponse(
                statusCode: 400,
                body: ["error": "Missing 'groups' array in request body"]
            )
        }

        // Update the auto-summary cadence's groups param via CadenceService
        guard var cadence = CadenceService.shared.get(id: "builtin-auto-summary") else {
            return HTTPResponse(statusCode: 500, body: ["error": "Auto-summary cadence not found"])
        }

        var existingGroups = cadence.params["groups"]?.stringArrayValue ?? []
        for group in groups {
            if !existingGroups.contains(where: { $0.lowercased() == group.lowercased() }) {
                existingGroups.append(group)
            }
        }

        cadence.params["groups"] = .stringArray(existingGroups)
        cadence.enabled = !existingGroups.isEmpty

        do {
            try CadenceService.shared.update(cadence)
            return HTTPResponse(statusCode: 200, body: [
                "success": true,
                "autoSummaryGroups": existingGroups,
                "message": "Added \(groups.count) group(s) to auto-summary list"
            ])
        } catch {
            return HTTPResponse(statusCode: 500, body: ["error": "Failed to update: \(error.localizedDescription)"])
        }
    }

    private func handleUpdateCadenceConfig(_ request: HTTPRequest) -> HTTPResponse {
        // Legacy endpoint: remap to CadenceService update
        guard let bodyData = request.body,
              let updates = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              !updates.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing JSON body. Use PUT /api/cadences for the new API."])
        }

        // Map old config keys to cadence IDs and fields
        var appliedCount = 0
        let keyMappings: [(configKey: String, cadenceId: String, field: String)] = [
            ("todo_scan_enabled", "builtin-todo-scan", "enabled"),
            ("commitment_scan_enabled", "builtin-commitment-scan", "enabled"),
            ("commitment_scan_time", "builtin-commitment-scan", "time"),
            ("pattern_learn_enabled", "builtin-pattern-learning", "enabled"),
            ("pattern_learn_day", "builtin-pattern-learning", "day"),
            ("pattern_learn_time", "builtin-pattern-learning", "time"),
            ("group_analysis_enabled", "builtin-group-analysis", "enabled"),
            ("group_analysis_day", "builtin-group-analysis", "day"),
            ("group_analysis_time", "builtin-group-analysis", "time"),
            ("auto_summary_time", "builtin-auto-summary", "time"),
        ]

        for mapping in keyMappings {
            guard let value = updates[mapping.configKey] else { continue }
            guard var cadence = CadenceService.shared.get(id: mapping.cadenceId) else { continue }

            switch mapping.field {
            case "enabled":
                if let enabled = value as? Bool { cadence.enabled = enabled; appliedCount += 1 }
            case "time":
                if let time = value as? String {
                    switch cadence.schedule {
                    case .daily: cadence.schedule = .daily(time: time)
                    case .weekly(let day, _): cadence.schedule = .weekly(day: day, time: time)
                    default: break
                    }
                    appliedCount += 1
                }
            case "day":
                if let day = value as? String {
                    if case .weekly(_, let time) = cadence.schedule {
                        cadence.schedule = .weekly(day: day, time: time)
                        appliedCount += 1
                    }
                }
            default: break
            }

            try? CadenceService.shared.update(cadence)
        }

        if appliedCount == 0 {
            return HTTPResponse(statusCode: 400, body: ["error": "No valid cadence config keys found. Use PUT /api/cadences for the new API."])
        }

        return HTTPResponse(statusCode: 200, body: [
            "success": true,
            "updated": appliedCount,
            "message": "Updated \(appliedCount) cadence setting(s) via CadenceService"
        ])
    }

    // MARK: - Past Conversations Handlers

    private func handleGetConversations(_ request: HTTPRequest) -> HTTPResponse {
        let limitStr = request.queryParams["limit"] ?? "7"
        let limit = Int(limitStr) ?? 7
        let conversations = ConversationHistoryService.shared.getConversations(limit: limit)
        return HTTPResponse(
            statusCode: 200,
            body: ["conversations": conversations, "count": conversations.count]
        )
    }

    private func handleGetConversationDetail(_ request: HTTPRequest) -> HTTPResponse {
        guard let id = request.queryParams["id"], !id.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'id' parameter"])
        }

        guard let conversation = ConversationHistoryService.shared.getConversation(id: id) else {
            return HTTPResponse(statusCode: 404, body: ["error": "Conversation not found"])
        }

        let turns: [[String: Any]] = conversation.turns.map { turn in
            [
                "role": turn.role,
                "content": turn.content,
                "timestamp": ISO8601DateFormatter().string(from: turn.timestamp)
            ]
        }

        return HTTPResponse(statusCode: 200, body: [
            "id": conversation.id,
            "title": conversation.title,
            "summary": conversation.summary,
            "createdAt": ISO8601DateFormatter().string(from: conversation.createdAt),
            "lastActiveAt": ISO8601DateFormatter().string(from: conversation.lastActiveAt),
            "turnCount": conversation.turnCount,
            "isClosed": conversation.isClosed,
            "turns": turns
        ])
    }

    private func handleCloseConversation(_ request: HTTPRequest) async -> HTTPResponse {
        guard let id = request.queryParams["id"], !id.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'id' parameter"])
        }

        let config = getConfig()
        await ConversationHistoryService.shared.closeConversation(id: id, aiConfig: config?.ai)

        return HTTPResponse(statusCode: 200, body: [
            "success": true,
            "message": "Conversation closed"
        ])
    }

    private func handleDeleteConversation(_ request: HTTPRequest) -> HTTPResponse {
        guard let id = request.queryParams["id"], !id.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'id' parameter"])
        }

        let success = ConversationHistoryService.shared.deleteConversation(id: id)
        if success {
            return HTTPResponse(statusCode: 200, body: [
                "success": true,
                "message": "Conversation deleted"
            ])
        } else {
            return HTTPResponse(statusCode: 404, body: ["error": "Conversation not found"])
        }
    }

    private func handleRestoreConversation(_ request: HTTPRequest) -> HTTPResponse {
        guard let id = request.queryParams["id"], !id.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'id' parameter"])
        }

        // Get persisted turns
        let turns = ConversationHistoryService.shared.getTurns(for: id)
        guard !turns.isEmpty else {
            return HTTPResponse(statusCode: 404, body: ["error": "Conversation not found or has no turns"])
        }

        // Restore into in-memory ConversationContext for Claude to use
        ConversationContext.shared.restoreSession(id: id, from: turns)

        // Return the full conversation for frontend rendering
        guard let conversation = ConversationHistoryService.shared.getConversation(id: id) else {
            return HTTPResponse(statusCode: 404, body: ["error": "Conversation not found"])
        }

        let turnData: [[String: Any]] = conversation.turns.map { turn in
            [
                "role": turn.role,
                "content": turn.content,
                "timestamp": ISO8601DateFormatter().string(from: turn.timestamp)
            ]
        }

        return HTTPResponse(statusCode: 200, body: [
            "id": conversation.id,
            "title": conversation.title,
            "summary": conversation.summary,
            "turnCount": conversation.turnCount,
            "turns": turnData
        ])
    }

    // MARK: - Simplified Learning Handlers

    private func handleTeachAlfred(_ request: HTTPRequest) -> HTTPResponse {
        guard let bodyData = request.body,
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let rule = json["rule"] as? String else {
            return HTTPResponse(
                statusCode: 400,
                body: ["error": "Missing 'rule' in request body"]
            )
        }

        // Store in a single Alfred memory file using the teach method
        let memoryService = AgentMemoryService.shared
        do {
            // Use task agent as the default for user-taught rules
            try memoryService.teach(agentType: .task, rule: rule)

            // Invalidate memory cache
            invalidateMemoryCache("memory_unified")

            return HTTPResponse(
                statusCode: 200,
                body: [
                    "success": true,
                    "message": "Rule learned: \(rule)"
                ]
            )
        } catch {
            return HTTPResponse(
                statusCode: 500,
                body: ["error": "Failed to save rule: \(error.localizedDescription)"]
            )
        }
    }

    private func handleGetLearnings() -> HTTPResponse {
        let memoryService = AgentMemoryService.shared

        // Collect all user-taught rules from all agents into a unified list
        var learnings: [[String: Any]] = []

        for agentType in [AgentType.communication, .task, .calendar, .followup] {
            let memory = memoryService.getMemory(for: agentType)

            if let rules = memory.sections["User-Taught Rules"] {
                let lines = rules.split(separator: "\n").map(String.init)
                for line in lines where line.hasPrefix("- ") {
                    // Parse format: - [2026-01-26T17:28:08Z] Rule text
                    if let match = line.range(of: #"- \[([^\]]+)\] (.+)"#, options: .regularExpression) {
                        let content = String(line[match])
                        let parts = content.dropFirst(3) // Remove "- ["
                        if let bracketEnd = parts.firstIndex(of: "]") {
                            let timestamp = String(parts[..<bracketEnd])
                            let ruleText = String(parts[parts.index(after: bracketEnd)...]).trimmingCharacters(in: .whitespaces)
                            learnings.append([
                                "rule": ruleText,
                                "timestamp": timestamp,
                                "category": agentType.displayName
                            ])
                        }
                    } else {
                        // Simple rule without timestamp
                        let ruleText = String(line.dropFirst(2)) // Remove "- "
                        learnings.append([
                            "rule": ruleText,
                            "timestamp": "",
                            "category": agentType.displayName
                        ])
                    }
                }
            }
        }

        // Get correction stats
        let correctionStats = CorrectionTracker.shared.getStats()

        return HTTPResponse(
            statusCode: 200,
            body: [
                "learnings": learnings,
                "corrections": [
                    "total": correctionStats.totalCorrections,
                    "falsePositives": correctionStats.falsePositives,
                    "edits": correctionStats.edits
                ]
            ]
        )
    }

    // MARK: - Learning System v2 Handlers

    private func handleGetLearningStatus() -> HTTPResponse {
        let learningService = WorkflowLearningService.shared
        let v2Stats = learningService.getLearningV2Stats()
        let v1Stats = learningService.getSummary()

        var combined: [String: Any] = [:]
        combined["v2"] = v2Stats
        combined["v1"] = v1Stats

        // Merge key metrics
        combined["totalEvents"] = v2Stats["totalEvents"] as? Int ?? 0
        combined["activePatterns"] = v2Stats["activePatterns"] as? Int ?? 0
        combined["pendingReviews"] = v2Stats["pendingReviews"] as? Int ?? 0
        combined["lastComputed"] = v2Stats["lastComputed"] as? String ?? "never"

        return HTTPResponse(statusCode: 200, body: combined)
    }

    private func handleComputeLearnedPatterns() async -> HTTPResponse {
        guard let config = getConfig() else {
            return HTTPResponse(statusCode: 500, body: ["error": "Configuration not loaded"])
        }

        let learningService = WorkflowLearningService.shared
        await learningService.computeLearnedPatterns(config: config)

        let stats = learningService.getLearningV2Stats()
        return HTTPResponse(statusCode: 200, body: [
            "status": "computed",
            "activePatterns": stats["activePatterns"] as Any,
            "pendingReviews": stats["pendingReviews"] as Any,
            "totalEvents": stats["totalEvents"] as Any
        ])
    }

    private func handleGetLearnedPatterns() -> HTTPResponse {
        let learningService = WorkflowLearningService.shared
        let patterns = learningService.getLearnedPatterns()

        let serialized: [[String: Any]] = patterns.map { p in
            [
                "id": p.id,
                "type": p.type,
                "description": p.description,
                "confidence": p.confidence,
                "isStale": p.isStale,
                "isDirect": p.isDirect,
                "reinforcements": p.reinforcements,
                "lastReinforced": p.lastReinforced
            ]
        }

        return HTTPResponse(statusCode: 200, body: [
            "patterns": serialized,
            "count": patterns.count
        ])
    }

    private func handlePatternReview(_ request: HTTPRequest) -> HTTPResponse {
        guard let reviewIdStr = request.queryParams["id"],
              let reviewId = Int(reviewIdStr),
              let action = request.queryParams["action"] else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'id' or 'action' parameter"])
        }

        let validActions = ["confirmed", "corrected", "dismissed"]
        guard validActions.contains(action) else {
            return HTTPResponse(statusCode: 400, body: ["error": "Action must be: confirmed, corrected, or dismissed"])
        }

        let userResponse = request.queryParams["response"]

        WorkflowLearningService.shared.resolvePatternReview(
            reviewId: reviewId,
            action: action,
            userResponse: userResponse
        )

        return HTTPResponse(statusCode: 200, body: [
            "status": "resolved",
            "action": action,
            "reviewId": reviewId
        ])
    }

    // MARK: - Workflow Patterns Handlers

    private func handleGetWorkflowPatterns() -> HTTPResponse {
        // Check memory cache (30min TTL)
        if let cached: [String: Any] = getFromMemoryCache("workflow_patterns") {
            return HTTPResponse(statusCode: 200, body: cached)
        }

        let learningService = WorkflowLearningService.shared
        let patterns = learningService.getComputedPatterns()
        let summary = learningService.getSummary()

        let body: [String: Any] = [
            "patterns": patterns,
            "summary": summary
        ]

        // Cache in memory (30min)
        setInMemoryCache("workflow_patterns", value: body, ttl: 1800)

        return HTTPResponse(statusCode: 200, body: body)
    }

    private func handleComputeWorkflowPatterns() -> HTTPResponse {
        let learningService = WorkflowLearningService.shared
        learningService.computePatterns()

        // Wait a moment for async computation to complete
        Thread.sleep(forTimeInterval: 0.5)

        // Invalidate cached patterns
        invalidateMemoryCache("workflow_patterns")

        let patterns = learningService.getComputedPatterns()
        let summary = learningService.getSummary()

        // Update scheduler state: date key for scheduler, timestamp key for UI
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let now = Date()
        updateSchedulerState([
            "lastPatternLearnDate": fmt.string(from: now),
            "lastPatternLearnTimestamp": ISO8601DateFormatter().string(from: now)
        ])

        return HTTPResponse(
            statusCode: 200,
            body: [
                "success": true,
                "message": "Patterns computed successfully",
                "patterns": patterns,
                "summary": summary
            ]
        )
    }

    private func handleGetLearningDigest() -> HTTPResponse {
        let learningService = WorkflowLearningService.shared

        guard let digest = learningService.generateLearningDigest() else {
            return HTTPResponse(
                statusCode: 200,
                body: [
                    "hasDigest": false,
                    "message": "Not enough data to generate a learning digest yet"
                ]
            )
        }

        return HTTPResponse(
            statusCode: 200,
            body: [
                "hasDigest": true,
                "subject": digest.subject,
                "body": digest.body
            ]
        )
    }

    private func handleSendLearningDigest() async -> HTTPResponse {
        let learningService = WorkflowLearningService.shared

        guard let digest = learningService.generateLearningDigest() else {
            return HTTPResponse(
                statusCode: 200,
                body: [
                    "success": false,
                    "error": "Not enough data to generate a learning digest yet"
                ]
            )
        }

        // Check if we have access to config
        guard let orchestrator = alfredService.orchestrator else {
            return HTTPResponse(
                statusCode: 500,
                body: [
                    "success": false,
                    "error": "Service not properly initialized"
                ]
            )
        }

        // Convert markdown to HTML for email
        let htmlBody = convertMarkdownToHtml(digest.body)

        // Send email using NotificationService
        do {
            let notificationService = NotificationService(config: orchestrator.config.notifications)
            try await notificationService.sendLearningDigest(subject: digest.subject, body: htmlBody)

            return HTTPResponse(
                statusCode: 200,
                body: [
                    "success": true,
                    "message": "Learning digest email sent successfully"
                ]
            )
        } catch {
            return HTTPResponse(
                statusCode: 500,
                body: [
                    "success": false,
                    "error": "Failed to send email: \(error.localizedDescription)"
                ]
            )
        }
    }

    private func convertMarkdownToHtml(_ markdown: String) -> String {
        let fontBody = "font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif;"
        let sectionStyle = "\(fontBody) font-size: 11px; font-weight: 600; color: #5c6370; text-transform: uppercase; letter-spacing: 0.06em; margin-top: 24px; padding-bottom: 6px; border-bottom: 1px solid #e4e2dc;"

        // Simple markdown to HTML conversion with inline styles
        var html = markdown

        // Headers — use inline styles matching the email design system
        let h1Regex = try? NSRegularExpression(pattern: "^# (.+)$", options: .anchorsMatchLines)
        html = h1Regex?.stringByReplacingMatches(in: html, range: NSRange(html.startIndex..., in: html), withTemplate: "<div style=\"font-family: 'Playfair Display', Georgia, serif; font-size: 22px; font-weight: 400; color: #1b2a4a; margin-bottom: 12px;\">$1</div>") ?? html

        let h2Regex = try? NSRegularExpression(pattern: "^## (.+)$", options: .anchorsMatchLines)
        html = h2Regex?.stringByReplacingMatches(in: html, range: NSRange(html.startIndex..., in: html), withTemplate: "<div style=\"\(sectionStyle)\">$1</div>") ?? html

        html = html.replacingOccurrences(of: "---", with: "<div style=\"height: 1px; background-color: #e4e2dc; margin: 20px 0;\"></div>")

        // Bold
        let boldRegex = try? NSRegularExpression(pattern: "\\*\\*(.+?)\\*\\*", options: [])
        html = boldRegex?.stringByReplacingMatches(in: html, range: NSRange(html.startIndex..., in: html), withTemplate: "<strong style=\"color: #1b2a4a;\">$1</strong>") ?? html

        // Line breaks
        html = html.replacingOccurrences(of: "\n\n", with: "<br><br>")
        html = html.replacingOccurrences(of: "\n- ", with: "<br>• ")
        html = html.replacingOccurrences(of: "\n", with: "<br>")

        // Wrap in shared email layout (table-based, inline styles)
        return NotificationService.emailHead()
            + "<div style=\"\(fontBody) font-size: 14px; line-height: 1.65; color: #1b2a4a;\">\(html)</div>"
            + NotificationService.emailFoot()
    }

    // MARK: - Unified Memory Handlers

    private func handleGetUnifiedMemory() -> HTTPResponse {
        // Check memory cache (10min TTL)
        if let cached: [String: Any] = getFromMemoryCache("memory_unified") {
            return HTTPResponse(statusCode: 200, body: cached)
        }

        let memoryService = AgentMemoryService.shared
        let dateFormatter = Self.iso8601Formatter

        var taughtRules: [[String: Any]] = []
        var observedPatterns: [[String: Any]] = []
        var peoplePatterns: [String: [[String: Any]]] = [:]
        var groupPatterns: [String: [[String: Any]]] = [:]

        for agentType in [AgentType.communication, .task, .calendar, .followup] {
            let memory = memoryService.getMemory(for: agentType)

            // Parse User-Taught Rules
            if let rules = memory.sections["User-Taught Rules"] {
                let lines = rules.components(separatedBy: "\n")
                for line in lines where line.hasPrefix("- [") {
                    // Parse format: - [2026-01-26T17:28:08Z] Rule text
                    if let match = line.range(of: #"- \[([^\]]+)\] (.+)"#, options: .regularExpression) {
                        let content = String(line[match])
                        let parts = content.dropFirst(3) // Remove "- ["
                        if let bracketEnd = parts.firstIndex(of: "]") {
                            let timestamp = String(parts[..<bracketEnd])
                            let ruleText = String(parts[parts.index(after: bracketEnd)...]).trimmingCharacters(in: .whitespaces)

                            // Format date for display
                            var displayDate = timestamp
                            if let date = dateFormatter.date(from: timestamp) {
                                let formatter = DateFormatter()
                                formatter.dateFormat = "MMM d"
                                displayDate = formatter.string(from: date)
                            }

                            taughtRules.append([
                                "id": "\(agentType.rawValue)_\(timestamp.hashValue)",
                                "text": ruleText,
                                "agent": agentType.rawValue,
                                "agentDisplay": agentType.displayName,
                                "timestamp": timestamp,
                                "displayDate": displayDate,
                                "type": "taught"
                            ])
                        }
                    }
                }
            }

            // Parse Learned Patterns
            if let patterns = memory.sections["Learned Patterns"] {
                let lines = patterns.components(separatedBy: "\n")
                for line in lines where line.hasPrefix("- [") {
                    // Parse format: - [2026-01-30T12:10:58Z] [source] Pattern text
                    if let match = line.range(of: #"- \[([^\]]+)\] (.+)"#, options: .regularExpression) {
                        let content = String(line[match])
                        let parts = content.dropFirst(3)
                        if let bracketEnd = parts.firstIndex(of: "]") {
                            let timestamp = String(parts[..<bracketEnd])
                            var patternText = String(parts[parts.index(after: bracketEnd)...]).trimmingCharacters(in: .whitespaces)

                            // Check for source tag
                            var source = "observed"
                            var confidence = "medium"
                            if patternText.hasPrefix("[") {
                                if let sourceEnd = patternText.range(of: "]") {
                                    source = String(patternText[patternText.index(after: patternText.startIndex)..<sourceEnd.lowerBound])
                                    patternText = String(patternText[sourceEnd.upperBound...]).trimmingCharacters(in: .whitespaces)
                                }
                            }

                            // Extract confidence from pattern text if present
                            if patternText.contains("confidence") {
                                if patternText.contains("90%") || patternText.contains("High") {
                                    confidence = "high"
                                } else if patternText.contains("50%") || patternText.contains("Low") {
                                    confidence = "low"
                                }
                            }

                            // Format date for display
                            var displayDate = timestamp
                            if let date = dateFormatter.date(from: timestamp) {
                                let formatter = DateFormatter()
                                formatter.dateFormat = "MMM d"
                                displayDate = formatter.string(from: date)
                            }

                            observedPatterns.append([
                                "id": "\(agentType.rawValue)_pattern_\(timestamp.hashValue)",
                                "text": patternText,
                                "agent": agentType.rawValue,
                                "agentDisplay": agentType.displayName,
                                "timestamp": timestamp,
                                "displayDate": displayDate,
                                "source": source,
                                "confidence": confidence,
                                "type": "observed"
                            ])
                        }
                    }
                }
            }

            // Parse Contact-Specific Patterns
            if let contactPatterns = memory.sections["Contact-Specific Patterns"] {
                let lines = contactPatterns.components(separatedBy: "\n")
                var currentContact: String?

                for line in lines {
                    if line.hasPrefix("### ") {
                        currentContact = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                    } else if line.hasPrefix("- "), let contact = currentContact {
                        let patternText = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)

                        // Determine if this is a person or a group (groups usually have keywords)
                        let isGroup = contact.lowercased().contains("group") ||
                                     contact.lowercased().contains("team") ||
                                     contact.lowercased().contains("leadership") ||
                                     contact.lowercased().contains("family")

                        let patternEntry: [String: Any] = [
                            "id": "\(agentType.rawValue)_contact_\(contact.hashValue)_\(patternText.hashValue)",
                            "text": patternText,
                            "agent": agentType.rawValue,
                            "agentDisplay": agentType.displayName,
                            "type": "contact"
                        ]

                        if isGroup {
                            if groupPatterns[contact] == nil {
                                groupPatterns[contact] = []
                            }
                            groupPatterns[contact]?.append(patternEntry)
                        } else {
                            if peoplePatterns[contact] == nil {
                                peoplePatterns[contact] = []
                            }
                            peoplePatterns[contact]?.append(patternEntry)
                        }
                    }
                }
            }
        }

        // Create summary
        let totalTaught = taughtRules.count
        let totalObserved = observedPatterns.count
        let totalPeople = peoplePatterns.keys.count
        let totalGroups = groupPatterns.keys.count
        let totalLearnings = totalTaught + totalObserved + peoplePatterns.values.reduce(0) { $0 + $1.count } + groupPatterns.values.reduce(0) { $0 + $1.count }

        let body: [String: Any] = [
            "summary": [
                "totalLearnings": totalLearnings,
                "taughtCount": totalTaught,
                "observedCount": totalObserved,
                "peopleCount": totalPeople,
                "groupsCount": totalGroups
            ],
            "taughtRules": taughtRules,
            "observedPatterns": observedPatterns,
            "peoplePatterns": peoplePatterns,
            "groupPatterns": groupPatterns
        ]

        // Cache in memory (10min)
        setInMemoryCache("memory_unified", value: body, ttl: 600)

        return HTTPResponse(statusCode: 200, body: body)
    }

    // MARK: - Unified Memory Management (Learning v3: Phase 5)

    private func handleGetAllMemory() -> HTTPResponse {
        let items = UnifiedMemoryIndex.shared.query(endpoint: "chat", maxItems: 100)

        let serialized: [[String: Any]] = items.map { item in
            [
                "id": item.id,
                "source": item.source.rawValue,
                "type": item.type.rawValue,
                "content": item.content,
                "confidence": item.confidence,
                "isStale": item.isStale
            ]
        }

        // Group by source for easier UI rendering
        var bySource: [String: [[String: Any]]] = [:]
        for item in serialized {
            let source = item["source"] as? String ?? "unknown"
            bySource[source, default: []].append(item)
        }

        return HTTPResponse(statusCode: 200, body: [
            "items": serialized,
            "bySource": bySource,
            "totalCount": items.count
        ])
    }

    private func handleDeleteLearnedPattern(_ request: HTTPRequest) -> HTTPResponse {
        guard let patternId = request.queryParams["id"] else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'id' parameter"])
        }

        let deleted = WorkflowLearningService.shared.deleteLearnedPattern(patternId: patternId)

        if deleted {
            // Record the deletion as a learning event
            WorkflowLearningService.shared.recordLearningEvent(
                eventType: "user_deleted_pattern",
                context: patternId,
                signalValue: "deleted",
                metadata: ["pattern_id": patternId]
            )

            return HTTPResponse(statusCode: 200, body: [
                "success": true,
                "deleted": patternId
            ])
        } else {
            return HTTPResponse(statusCode: 404, body: [
                "success": false,
                "error": "Pattern not found: \(patternId)"
            ])
        }
    }

    private func handleUpdateLearnedPattern(_ request: HTTPRequest) -> HTTPResponse {
        guard let patternId = request.queryParams["id"] else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'id' parameter"])
        }

        guard let bodyData = request.body,
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let newDescription = json["description"] as? String else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'description' in body"])
        }

        let updated = WorkflowLearningService.shared.updateLearnedPattern(
            patternId: patternId,
            newDescription: newDescription
        )

        if updated {
            return HTTPResponse(statusCode: 200, body: [
                "success": true,
                "updated": patternId,
                "newDescription": newDescription
            ])
        } else {
            return HTTPResponse(statusCode: 404, body: [
                "success": false,
                "error": "Pattern not found: \(patternId)"
            ])
        }
    }

    private func handleMemoryFeedback(_ request: HTTPRequest) -> HTTPResponse {
        guard let bodyData = request.body,
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let patternId = json["patternId"] as? String,
              let feedback = json["feedback"] as? String else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing patternId or feedback"])
        }

        print("📊 Memory feedback: \(patternId) -> \(feedback)")

        if feedback == "negative" {
            // Learning v3: Actually decay confidence instead of just logging
            let decayed = WorkflowLearningService.shared.decayPatternConfidence(patternId: patternId)
            return HTTPResponse(statusCode: 200, body: [
                "success": true,
                "action": "decayed",
                "message": decayed ? "Pattern confidence reduced." : "Pattern not found or is a direct instruction."
            ])
        } else if feedback == "positive" {
            // Reinforce the pattern
            WorkflowLearningService.shared.touchLastReinforced(patternIds: [patternId])
            return HTTPResponse(statusCode: 200, body: [
                "success": true,
                "action": "reinforced",
                "message": "Pattern reinforced."
            ])
        }

        return HTTPResponse(statusCode: 200, body: [
            "success": true,
            "message": "Feedback noted."
        ])
    }

    private func handleEditMemory(_ request: HTTPRequest) -> HTTPResponse {
        guard let bodyData = request.body,
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let agent = json["agent"] as? String,
              let oldText = json["oldText"] as? String,
              let newText = json["newText"] as? String else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing required fields"])
        }

        guard let agentType = parseAgentType(agent) else {
            return HTTPResponse(statusCode: 400, body: ["error": "Unknown agent: \(agent)"])
        }

        let memoryService = AgentMemoryService.shared

        // First, remove the old rule
        do {
            let _ = try memoryService.forget(agentType: agentType, pattern: oldText)

            // Then add the new rule
            try memoryService.teach(agentType: agentType, rule: newText)

            return HTTPResponse(statusCode: 200, body: [
                "success": true,
                "message": "Rule updated successfully"
            ])
        } catch {
            return HTTPResponse(statusCode: 500, body: [
                "error": "Failed to update rule: \(error.localizedDescription)"
            ])
        }
    }

    // MARK: - Memory Notion Sync Handlers

    private func handleGetMemoryNotionStatus() -> HTTPResponse {
        let status = MemoryNotionSyncService.shared.getStatus()
        return HTTPResponse(statusCode: 200, body: status)
    }

    private func handleMemoryNotionSync() async -> HTTPResponse {
        do {
            try await MemoryNotionSyncService.shared.syncToNotion(force: true)
            return HTTPResponse(statusCode: 200, body: [
                "success": true,
                "message": "Memory synced to Notion",
                "status": MemoryNotionSyncService.shared.getStatus()
            ])
        } catch {
            return HTTPResponse(statusCode: 500, body: [
                "error": "Sync failed: \(error.localizedDescription)"
            ])
        }
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
        guard let config = getConfig(),
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

    private func handleOpenSystemPreferences(_ request: HTTPRequest) async -> HTTPResponse {
        guard let bodyData = request.body,
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let panel = json["panel"] as? String else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing panel parameter"])
        }

        // Map panel names to System Preferences URLs
        let url: String
        switch panel {
        case "FullDiskAccess":
            url = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        case "Automation":
            url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        case "Notifications":
            url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Notifications"
        case "Accessibility":
            url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        default:
            url = "x-apple.systempreferences:com.apple.preference.security"
        }

        // Open System Preferences using NSWorkspace
        DispatchQueue.main.async {
            if let nsUrl = URL(string: url) {
                NSWorkspace.shared.open(nsUrl)
            }
        }

        return HTTPResponse(statusCode: 200, body: ["success": true, "panel": panel])
    }

    // MARK: - Permission Status Handlers

    private func handleGetPermissionStatus() async -> HTTPResponse {
        guard let config = alfredService.orchestrator?.config else {
            return HTTPResponse(statusCode: 503, body: ["error": "Service not initialized"])
        }

        // 1. Full Disk Access — test by opening iMessage DB
        var fdaStatus = "unknown"
        if config.messaging.imessage.enabled || config.messaging.whatsapp.enabled {
            let chatDbPath = config.messaging.imessage.enabled
                ? config.messaging.imessage.expandedPath
                : config.messaging.whatsapp.expandedPath
            if FileManager.default.fileExists(atPath: chatDbPath) {
                var testDb: OpaquePointer?
                let rc = sqlite3_open_v2(chatDbPath, &testDb, SQLITE_OPEN_READONLY, nil)
                if rc == SQLITE_OK {
                    var stmt: OpaquePointer?
                    let tableName = config.messaging.imessage.enabled ? "message" : "ZWAMESSAGE"
                    let queryRc = sqlite3_prepare_v2(testDb, "SELECT 1 FROM \(tableName) LIMIT 1", -1, &stmt, nil)
                    fdaStatus = queryRc == SQLITE_OK ? "granted" : "denied"
                    sqlite3_finalize(stmt)
                } else {
                    fdaStatus = "denied"
                }
                sqlite3_close(testDb)
            } else {
                fdaStatus = "not_found"
            }
        } else {
            fdaStatus = "not_needed"
        }

        // 2. Contacts — check CNContactStore authorization
        let contactsAuth = CNContactStore.authorizationStatus(for: .contacts)
        let contactsStatus: String
        switch contactsAuth {
        case .authorized:
            contactsStatus = "granted"
        case .denied, .restricted:
            contactsStatus = "denied"
        case .notDetermined:
            contactsStatus = "not_determined"
        @unknown default:
            contactsStatus = "unknown"
        }

        // 3. Notifications — check UNUserNotificationCenter
        let notifStatus: String = await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    continuation.resume(returning: "granted")
                case .denied:
                    continuation.resume(returning: "denied")
                case .notDetermined:
                    continuation.resume(returning: "not_determined")
                @unknown default:
                    continuation.resume(returning: "unknown")
                }
            }
        }

        let result: [String: Any] = [
            "fullDiskAccess": fdaStatus,
            "contacts": contactsStatus,
            "notifications": notifStatus,
            "imessageEnabled": config.messaging.imessage.enabled,
            "whatsappEnabled": config.messaging.whatsapp.enabled
        ]

        return HTTPResponse(statusCode: 200, body: result)
    }

    private func handleRequestContactsPermission() async -> HTTPResponse {
        let store = CNContactStore()
        let granted: Bool = await withCheckedContinuation { continuation in
            store.requestAccess(for: .contacts) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
        return HTTPResponse(statusCode: 200, body: [
            "granted": granted,
            "status": granted ? "granted" : "denied"
        ])
    }

    // MARK: - Commitment Management Handlers

    /// Update task/commitment status in Notion
    private func handleUpdateTaskStatus(_ request: HTTPRequest) async -> HTTPResponse {
        guard let bodyData = request.body,
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let notionId = json["notionId"] as? String,
              let statusString = json["status"] as? String else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing notionId or status"])
        }

        // Get additional context from request for learning
        let taskType = json["taskType"] as? String ?? "Unknown"
        let priority = json["priority"] as? String ?? "Medium"
        let counterparty = json["counterparty"] as? String
        let fromStatus = json["fromStatus"] as? String ?? "Not Started"

        // Map status string to TaskItem.TaskStatus
        let status: TaskItem.TaskStatus
        switch statusString {
        case "Done", "Completed":
            status = .done
        case "In Progress":
            status = .inProgress
        case "Blocked":
            status = .blocked
        case "Cancelled":
            status = .cancelled
        default:
            status = .notStarted
        }

        guard let orchestrator = alfredService.orchestrator else {
            return HTTPResponse(statusCode: 500, body: ["error": "Service not initialized"])
        }

        do {
            try await orchestrator.notionServicePublic.updateTaskStatus(notionId: notionId, status: status)

            // Record the status change for learning
            WorkflowLearningService.shared.recordTaskStatusChange(
                taskId: notionId,
                taskType: taskType,
                fromStatus: fromStatus,
                toStatus: status.rawValue,
                priority: priority,
                counterparty: counterparty,
                daysInPreviousStatus: nil  // Could be computed if we track timestamps
            )

            // Invalidate affected caches
            invalidateMemoryCache("home_pulse")
            invalidateMemoryCache("tracker_stats")
            invalidateMemoryCache("lifecycle_stats")
            invalidateMemoryCache("coaching_cards")
            cache.deleteByEndpoint("/api/home/pulse")
            cache.deleteByEndpoint("/api/coaching/cards")

            return HTTPResponse(statusCode: 200, body: ["success": true, "status": status.rawValue])
        } catch {
            return HTTPResponse(statusCode: 500, body: ["error": "Failed to update status: \(error.localizedDescription)"])
        }
    }

    /// Generate a nudge/follow-up message for a commitment
    private func handleGenerateNudge(_ request: HTTPRequest) async -> HTTPResponse {
        guard let bodyData = request.body,
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing request body"])
        }

        guard let orchestrator = alfredService.orchestrator else {
            return HTTPResponse(statusCode: 500, body: ["error": "Service not initialized"])
        }

        let title = json["title"] as? String ?? ""
        let committedBy = json["committedBy"] as? String ?? "them"
        let commitmentText = json["commitmentText"] as? String ?? title
        let dueDate = json["dueDate"] as? String
        let isOverdue = json["isOverdue"] as? Bool ?? false

        // Build a prompt for Claude to generate a friendly follow-up message
        let dueDateContext: String
        if let dueStr = dueDate {
            dueDateContext = isOverdue ? "This was due on \(dueStr) and is now overdue." : "This is due on \(dueStr)."
        } else {
            dueDateContext = "No specific due date was mentioned."
        }

        let prompt = """
        Generate a brief, friendly follow-up message to remind someone about a commitment they made.

        Details:
        - They committed to: \(commitmentText)
        - Person: \(committedBy)
        - \(dueDateContext)

        Write a casual, warm message (2-3 sentences max) that:
        - Is polite and not pushy
        - References what they promised
        - If overdue, gently notes this without being accusatory
        - Ends with an offer to help if needed

        Just return the message text, no quotes or formatting.
        """

        do {
            let fullPrompt = "You are a helpful assistant that generates friendly, professional follow-up messages. Keep messages concise and warm.\n\n" + prompt
            let response = try await orchestrator.aiServicePublic.generateText(prompt: fullPrompt, maxTokens: 200)

            return HTTPResponse(statusCode: 200, body: ["message": response, "success": true])
        } catch {
            // Fallback to a template message
            let fallbackMessage = isOverdue
                ? "Hey \(committedBy), just checking in on \(title) - I know things get busy. Let me know if you need any help with this!"
                : "Hi \(committedBy), hope you're doing well! Just wanted to touch base about \(title). No rush, just keeping it on the radar."

            return HTTPResponse(statusCode: 200, body: ["message": fallbackMessage, "success": true, "fallback": true])
        }
    }

    /// Detect potential commitment completions from recent messages
    private func handleDetectCompletions(_ request: HTTPRequest) async -> HTTPResponse {
        guard let bodyData = request.body,
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let contact = json["contact"] as? String else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing contact parameter"])
        }

        guard let orchestrator = alfredService.orchestrator else {
            return HTTPResponse(statusCode: 500, body: ["error": "Service not initialized"])
        }

        let timeframe = json["timeframe"] as? String ?? "24h"

        // Calculate lookback hours
        let lookbackHours: Int
        switch timeframe {
        case "48h":
            lookbackHours = 48
        case "7d":
            lookbackHours = 24 * 7
        default:
            lookbackHours = 24
        }

        do {
            // Get active commitments for this contact
            let allCommitments = try await alfredService.fetchCommitments()
            let contactCommitments = allCommitments.filter { commitment in
                let matchesContact = commitment.committedBy.localizedCaseInsensitiveContains(contact) ||
                                    commitment.committedTo.localizedCaseInsensitiveContains(contact) ||
                                    commitment.sourceThread.localizedCaseInsensitiveContains(contact)
                let isActive = commitment.status == .open || commitment.status == .inProgress
                return matchesContact && isActive
            }

            if contactCommitments.isEmpty {
                return HTTPResponse(statusCode: 200, body: [
                    "completions": [] as [Any],
                    "message": "No active commitments found for \(contact)"
                ])
            }

            // Get recent messages from this contact
            let lookbackDate = Calendar.current.date(byAdding: .hour, value: -lookbackHours, to: Date()) ?? Date()
            let threads = try orchestrator.whatsAppReaderPublic.fetchThreads(since: lookbackDate)

            // Find matching thread
            let matchingThread = threads.first { thread in
                (thread.contactName ?? "").localizedCaseInsensitiveContains(contact) ||
                thread.contactIdentifier.localizedCaseInsensitiveContains(contact)
            }

            guard let thread = matchingThread, !thread.messages.isEmpty else {
                return HTTPResponse(statusCode: 200, body: [
                    "completions": [] as [Any],
                    "message": "No recent messages from \(contact) in the last \(timeframe)"
                ])
            }

            // Build context for Claude to analyze
            let recentMessages = thread.messages
                .filter { $0.timestamp >= lookbackDate }
                .sorted { $0.timestamp < $1.timestamp }
                .prefix(20)
                .map { "\($0.direction == .outgoing ? "You" : contact): \($0.content)" }
                .joined(separator: "\n")

            let commitmentsList = contactCommitments.map { "- \($0.title): \($0.commitmentText)" }.joined(separator: "\n")

            let prompt = """
            Analyze these recent messages to detect if any of these commitments have been completed.

            Active commitments:
            \(commitmentsList)

            Recent messages:
            \(recentMessages)

            For each commitment, determine if there's evidence it was completed. Look for:
            - Direct statements like "done", "sent", "finished", "completed"
            - References to the task being handled
            - Acknowledgments of receiving something promised

            Return ONLY a JSON array with detected completions:
            [
              {
                "title": "commitment title",
                "confidence": 0.9,
                "evidence": "They said 'I've sent the report'"
              }
            ]

            Return empty array [] if no completions detected.
            """

            let fullPrompt = "You are analyzing messages to detect completed commitments. Only return JSON, no other text.\n\n" + prompt
            let response = try await orchestrator.aiServicePublic.generateText(prompt: fullPrompt, maxTokens: 500)

            // Parse Claude's response
            if let jsonData = response.data(using: String.Encoding.utf8),
               let completionsArray = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] {

                // Enhance with full commitment data
                let enrichedCompletions: [[String: Any]] = completionsArray.compactMap { detection -> [String: Any]? in
                    guard let title = detection["title"] as? String else { return nil }
                    if let matchingCommitment = contactCommitments.first(where: {
                        $0.title.localizedCaseInsensitiveContains(title) || title.localizedCaseInsensitiveContains($0.title)
                    }) {
                        return [
                            "title": matchingCommitment.title,
                            "notionId": matchingCommitment.notionId as Any,
                            "confidence": detection["confidence"] ?? 0.7,
                            "evidence": detection["evidence"] ?? "",
                            "type": matchingCommitment.type.rawValue,
                            "committedBy": matchingCommitment.committedBy
                        ]
                    }
                    return nil
                }

                return HTTPResponse(statusCode: 200, body: [
                    "completions": enrichedCompletions,
                    "contact": contact,
                    "timeframe": timeframe,
                    "messagesAnalyzed": recentMessages.count
                ])
            }

            return HTTPResponse(statusCode: 200, body: [
                "completions": [] as [Any],
                "message": "Could not parse completion analysis"
            ])

        } catch {
            return HTTPResponse(statusCode: 500, body: ["error": "Failed to detect completions: \(error.localizedDescription)"])
        }
    }

    // MARK: - Reflection Mode Handlers

    private func handleReflectIngest(_ request: HTTPRequest) async -> HTTPResponse {
        guard let config = AppConfig.load() else {
            return HTTPResponse(statusCode: 500, body: ["error": "Config not available"])
        }

        guard let bodyData = request.body,
              let body = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let content = body["content"] as? String,
              !content.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'content' in request body"])
        }

        let source = body["source"] as? String ?? "manual"
        let sourceId = body["source_id"] as? String ?? String(content.hashValue)

        let extractionService = ReflectionExtractionService(config: config.ai)
        let existingThemes = ReflectionStore.shared.getExistingThemes()

        do {
            let extraction = try await extractionService.extract(
                from: content,
                source: source,
                existingThemes: existingThemes
            )

            guard !extraction.themes.isEmpty else {
                return HTTPResponse(statusCode: 200, body: [
                    "message": "No meaningful themes extracted from content",
                    "themes": [] as [String]
                ])
            }

            ReflectionStore.shared.insertReflection(
                source: source,
                sourceId: sourceId,
                contentSummary: extraction.contentSummary,
                themes: extraction.themes,
                themeClassifications: extraction.themeClassifications,
                openQuestions: extraction.openQuestions,
                mentalModelShifts: extraction.mentalModelShifts,
                decisions: extraction.decisions
            )

            // Ensure theme state rows exist for each extracted theme
            for theme in extraction.themes {
                let classification = extraction.themeClassifications[theme] ?? "emerging"
                ReflectionStore.shared.ensureThemeState(theme: theme, classification: classification)
            }

            return HTTPResponse(statusCode: 200, body: [
                "message": "Reflection ingested successfully",
                "content_summary": extraction.contentSummary,
                "themes": extraction.themes,
                "theme_classifications": extraction.themeClassifications,
                "open_questions": extraction.openQuestions,
                "decisions": extraction.decisions
            ])
        } catch {
            return HTTPResponse(statusCode: 500, body: ["error": "Extraction failed: \(error.localizedDescription)"])
        }
    }

    private func handleReflectRecent(_ request: HTTPRequest) -> HTTPResponse {
        let days = Int(request.queryParams["days"] ?? "14") ?? 14
        let limit = Int(request.queryParams["limit"] ?? "20") ?? 20
        let source = request.queryParams["source"]

        let reflections = ReflectionStore.shared.getRecentReflections(limit: limit, days: days, source: source)

        return HTTPResponse(statusCode: 200, body: [
            "reflections": reflections,
            "count": reflections.count
        ])
    }

    private func handleReflectThemes(_ request: HTTPRequest) -> HTTPResponse {
        let days = Int(request.queryParams["days"] ?? "30") ?? 30
        let limit = Int(request.queryParams["limit"] ?? "10") ?? 10

        let themes = ReflectionStore.shared.getThemesWithState(days: days, limit: limit)
        let questions = ReflectionStore.shared.getOpenQuestions(limit: 5)
        let beliefShifts = ReflectionStore.shared.getRecentBeliefShifts(days: 60, limit: 5)
        let week = ReflectionStore.shared.getWeekInputSummary(days: 7)

        return HTTPResponse(statusCode: 200, body: [
            "themes": themes,
            "open_questions": questions,
            "total_themes": themes.count,
            "belief_shifts": beliefShifts,
            "week_input_count": week.count,
            "week_sources": week.sources
        ])
    }

    /// The "You" surface — Alfred's durable self-model. Read-only synthesis over
    /// existing stores, gated by the `features.self_model` config flag so the whole
    /// surface can be toggled on/off in the running app without a rebuild.
    private func handleSelfModel(_ request: HTTPRequest) -> HTTPResponse {
        guard getConfig()?.features?.selfModel ?? false else {
            return HTTPResponse(statusCode: 200, body: ["enabled": false])
        }
        return HTTPResponse(statusCode: 200, body: SelfModelService.synthesize())
    }

    /// Materialize the durable self-model (self_facet store) from live sources.
    /// Idempotent — safe to call repeatedly; re-runs upsert in place.
    private func handleSelfModelCompute(_ request: HTTPRequest) -> HTTPResponse {
        guard getConfig()?.features?.selfModel ?? false else {
            return HTTPResponse(statusCode: 200, body: ["enabled": false])
        }
        let counts = SelfModelSynthesizer.materialize()
        return HTTPResponse(statusCode: 200, body: [
            "enabled": true,
            "counts": counts,
            "total": counts.values.reduce(0, +)
        ])
    }

    /// Confirm / dismiss / clear a facet's verdict. Params: id, verdict (confirmed|dismissed|"" to clear).
    private func handleSelfModelVerdict(_ request: HTTPRequest) -> HTTPResponse {
        guard getConfig()?.features?.selfModel ?? false else {
            return HTTPResponse(statusCode: 200, body: ["enabled": false])
        }
        guard let id = request.queryParams["id"], !id.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'id'"])
        }
        let raw = request.queryParams["verdict"] ?? ""
        let verdict: String? = raw.isEmpty ? nil : raw
        let ok = SelfModelService.setVerdict(id: id, verdict: verdict)
        return HTTPResponse(statusCode: ok ? 200 : 404, body: ["ok": ok, "id": id, "verdict": raw])
    }

    /// The whole self-model for exploration — every theme and belief with both
    /// directions of linkage resolved. Backs the immersive "You" browser.
    private func handleSelfModelBrowse(_ request: HTTPRequest) -> HTTPResponse {
        guard getConfig()?.features?.selfModel ?? false else {
            return HTTPResponse(statusCode: 200, body: ["enabled": false])
        }
        return HTTPResponse(statusCode: 200, body: SelfModelService.browse())
    }

    /// Look for decisions that evidence each unbacked declared belief. Produces
    /// proposals only — never applies anything.
    private func handleGraduate(_ request: HTTPRequest) -> HTTPResponse {
        guard getConfig()?.features?.selfModel ?? false else {
            return HTTPResponse(statusCode: 200, body: ["enabled": false])
        }
        let sem = DispatchSemaphore(value: 0)
        var out: GraduationService.Result = .init()
        Task {
            out = await GraduationService.groundDeclaredBeliefs()
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 180)
        return HTTPResponse(statusCode: 200, body: [
            "ok": true,
            "beliefs_examined": out.beliefsExamined,
            "candidates_read": out.candidatesRead,
            "proposed": out.proposed,
            "notes": out.notes
        ])
    }

    /// Pending proposals, resolved against statements so they're readable.
    private func handleGraduationProposals(_ request: HTTPRequest) -> HTTPResponse {
        let store = SelfModelStore.shared
        let byId = Dictionary(
            (store.getFacets(kind: "belief") + store.getFacets(kind: "decision"))
                .map { (($0["id"] as? String ?? ""), ($0["statement"] as? String ?? "")) },
            uniquingKeysWith: { a, _ in a })
        let rows: [[String: Any]] = store.getProposals(status: "pending").map { p in
            [
                "id": p["id"] as? String ?? "",
                "belief": byId[p["belief_id"] as? String ?? ""] ?? "",
                "decision": byId[p["decision_id"] as? String ?? ""] ?? "",
                "rationale": p["rationale"] as? String ?? ""
            ]
        }
        return HTTPResponse(statusCode: 200, body: ["count": rows.count, "proposals": rows])
    }

    private func handleResolveProposal(_ request: HTTPRequest) -> HTTPResponse {
        guard let id = request.queryParams["id"], !id.isEmpty,
              let action = request.queryParams["action"] else {
            return HTTPResponse(statusCode: 400, body: ["error": "id and action required"])
        }
        let ok = action == "confirm" ? GraduationService.confirm(proposalId: id)
                                     : GraduationService.reject(proposalId: id)
        return HTTPResponse(statusCode: 200, body: ["ok": ok, "action": action])
    }

    /// Which threads would feed reflection extraction, and why. Makes the ingestion
    /// rule inspectable instead of implicit — you can see what Alfred is reading
    /// before it reads it, and what it's leaving out.
    private func handleThreadCandidates(_ request: HTTPRequest) -> HTTPResponse {
        guard let config = getConfig(), config.messaging.whatsapp.enabled else {
            return HTTPResponse(statusCode: 200, body: ["error": "WhatsApp not enabled"])
        }
        let days = Int(request.queryParams["days"] ?? "14") ?? 14
        let since = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()

        do {
            let reader = WhatsAppReader.shared(dbPath: config.messaging.whatsapp.dbPath)
            try reader.connect()
            let threads = try reader.fetchThreads(since: since)
            reader.disconnect()

            let rule = ThreadEligibility.fromConfig()
            let favorites = FavoritesService.shared
            let verdicts = threads.map { t in
                rule.evaluate(t, isFavorite: favorites.isFavorite(t.contactName ?? t.contactIdentifier))
            }
            let selected = Set(rule.select(verdicts).map { $0.identifier })

            let rows: [[String: Any]] = verdicts
                .sorted { $0.outboundChars > $1.outboundChars }
                .map { v in [
                    "name": v.name,
                    "group": v.isGroup,
                    "favorite": v.isFavorite,
                    "outbound": v.outbound,
                    "inbound": v.inbound,
                    "outbound_chars": v.outboundChars,
                    "your_share": Int(v.yourShare * 100),
                    "eligible": v.eligible,
                    "ingested": selected.contains(v.identifier),
                    "reason": v.reason
                ] }

            return HTTPResponse(statusCode: 200, body: [
                "days": days,
                "threads_seen": threads.count,
                "eligible": verdicts.filter { $0.eligible }.count,
                "ingested_this_run": selected.count,
                "thresholds": ["min_outbound": rule.minOutbound,
                               "min_outbound_chars": rule.minOutboundChars,
                               "max_per_run": rule.maxPerRun],
                "threads": rows
            ])
        } catch {
            return HTTPResponse(statusCode: 200, body: ["error": "\(error)"])
        }
    }

    /// Individual reflections — the raw material the whole model condenses from.
    /// They're normally digested into themes and disappear; this makes them addressable.
    private func handleSelfModelReflections(_ request: HTTPRequest) -> HTTPResponse {
        guard getConfig()?.features?.selfModel ?? false else {
            return HTTPResponse(statusCode: 200, body: ["enabled": false])
        }
        let limit = Int(request.queryParams["limit"] ?? "400") ?? 400
        let days = Int(request.queryParams["days"] ?? "400") ?? 400
        let rows = ReflectionStore.shared.getRecentReflections(limit: limit, days: days)

        let out: [[String: Any]] = rows.map { r in
            let created = (r["created_at"] as? String) ?? ""
            return [
                "id": r["id"] as? Int ?? 0,
                "source": (r["source"] as? String) ?? "",
                "date": created.count >= 10 ? String(created.prefix(10)) : created,
                "summary": (r["content_summary"] as? String) ?? "",
                "themes": (r["themes"] as? [String]) ?? [],
                "questions": (r["open_questions"] as? [String]) ?? [],
                "shifts": (r["mental_model_shifts"] as? [[String: String]]) ?? []
            ]
        }
        return HTTPResponse(statusCode: 200, body: [
            "enabled": true, "count": out.count, "reflections": out
        ])
    }

    /// Ingest a declared operating model. Either scans ~/.alfred/imports/ for an
    /// operating-model markdown drop, or takes the markdown directly in the body.
    private func handleSelfModelSeed(_ request: HTTPRequest) -> HTTPResponse {
        guard getConfig()?.features?.selfModel ?? false else {
            return HTTPResponse(statusCode: 200, body: ["enabled": false])
        }
        var result: SelfModelSeeder.SeedResult
        if let body = request.body, let markdown = String(data: body, encoding: .utf8),
           !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard SelfModelSeeder.looksLikeOperatingModel(markdown) else {
                return HTTPResponse(statusCode: 400, body: [
                    "error": "Body does not look like an operating model (expected ## Values / ## Beliefs / ## How I want to operate)"
                ])
            }
            result = SelfModelSeeder.seed(from: markdown, sourceLabel: "api")
        } else {
            result = SelfModelSeeder.scanImports()
        }
        return HTTPResponse(statusCode: 200, body: [
            "ok": true,
            "values": result.values,
            "beliefs": result.beliefs,
            "instructions": result.instructions,
            "total": result.total,
            "files": result.files
        ])
    }

    /// Attach / detach / move a lens (pattern) against a belief. Many-to-many.
    /// Params: lensId, beliefId, action = assign | unassign | move (move also needs toBeliefId).
    private func handleSelfModelLink(_ request: HTTPRequest) -> HTTPResponse {
        guard getConfig()?.features?.selfModel ?? false else {
            return HTTPResponse(statusCode: 200, body: ["enabled": false])
        }
        guard let lensId = request.queryParams["lensId"], !lensId.isEmpty,
              let beliefId = request.queryParams["beliefId"], !beliefId.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'lensId' or 'beliefId'"])
        }
        let action = request.queryParams["action"] ?? "assign"
        let store = SelfModelStore.shared
        var ok = false
        switch action {
        case "unassign":
            ok = store.unlinkLens(lensId: lensId, beliefId: beliefId)
        case "move":
            guard let to = request.queryParams["toBeliefId"], !to.isEmpty else {
                return HTTPResponse(statusCode: 400, body: ["error": "Missing 'toBeliefId' for move"])
            }
            ok = store.moveLens(lensId: lensId, fromBeliefId: beliefId, toBeliefId: to)
        default:
            ok = store.linkLens(lensId: lensId, beliefId: beliefId)
        }
        return HTTPResponse(statusCode: ok ? 200 : 500, body: [
            "ok": ok, "action": action, "lensId": lensId, "beliefId": beliefId
        ])
    }

    /// Resolve an open question into a durable belief. Params: id, resolution.
    private func handleSelfModelResolve(_ request: HTTPRequest) -> HTTPResponse {
        guard getConfig()?.features?.selfModel ?? false else {
            return HTTPResponse(statusCode: 200, body: ["enabled": false])
        }
        guard let id = request.queryParams["id"], !id.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'id'"])
        }
        let resolution = (request.queryParams["resolution"]?.removingPercentEncoding ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolution.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'resolution'"])
        }
        if let beliefId = SelfModelService.resolveQuestion(id: id, resolution: resolution) {
            return HTTPResponse(statusCode: 200, body: ["ok": true, "belief_id": beliefId, "belief": resolution])
        }
        return HTTPResponse(statusCode: 404, body: ["ok": false, "error": "Question not found"])
    }

    /// One belief to surface on the Now surface (the You→Now loop).
    private func handleSelfModelNowCard(_ request: HTTPRequest) -> HTTPResponse {
        guard getConfig()?.features?.selfModel ?? false else {
            return HTTPResponse(statusCode: 200, body: ["enabled": false])
        }
        if let card = SelfModelService.nowCard() {
            return HTTPResponse(statusCode: 200, body: ["enabled": true, "card": card])
        }
        return HTTPResponse(statusCode: 200, body: ["enabled": true, "card": NSNull()])
    }

    private func handleReflectThemeDetail(_ request: HTTPRequest) -> HTTPResponse {
        guard let name = request.queryParams["name"]?.removingPercentEncoding, !name.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'name' query parameter"])
        }
        let days = Int(request.queryParams["days"] ?? "90") ?? 90

        let detail = ReflectionStore.shared.getThemeDetail(theme: name, days: days)
        return HTTPResponse(statusCode: 200, body: detail)
    }

    private func handleReflectThemeAdvance(_ request: HTTPRequest) -> HTTPResponse {
        guard let bodyData = request.body,
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let theme = json["theme"] as? String,
              let newState = json["new_state"] as? String,
              let context = json["context"] as? String else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'theme', 'new_state', or 'context' in request body"])
        }

        let success = ReflectionStore.shared.advanceThemeState(theme: theme, newState: newState, context: context)
        if success {
            return HTTPResponse(statusCode: 200, body: ["message": "Theme state advanced", "theme": theme, "new_state": newState])
        } else {
            return HTTPResponse(statusCode: 500, body: ["error": "Failed to advance theme state"])
        }
    }

    private func handleReflectStats() -> HTTPResponse {
        let stats = ReflectionStore.shared.getStats()
        return HTTPResponse(statusCode: 200, body: stats)
    }

    private func handleReflectTidy() -> HTTPResponse {
        let candidates = ReflectionStore.shared.getTidyCandidates()
        return HTTPResponse(statusCode: 200, body: ["candidates": candidates, "count": candidates.count])
    }

    private func handleReflectTidyDismiss(_ request: HTTPRequest) -> HTTPResponse {
        guard let bodyData = request.body,
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let theme = (json["theme"] as? String)?.trimmingCharacters(in: .whitespaces),
              !theme.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'theme' in request body"])
        }
        let ok = ReflectionStore.shared.dismissTidy(theme: theme)
        return HTTPResponse(statusCode: ok ? 200 : 500, body: ok
            ? ["message": "Dismissed", "theme": theme]
            : ["error": "Dismiss failed"])
    }

    private func handleReflectThemesMerge(_ request: HTTPRequest) -> HTTPResponse {
        guard let bodyData = request.body,
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let source = (json["from"] as? String)?.trimmingCharacters(in: .whitespaces),
              let target = (json["into"] as? String)?.trimmingCharacters(in: .whitespaces),
              !source.isEmpty, !target.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing or empty 'from' / 'into' in request body"])
        }
        if source == target {
            return HTTPResponse(statusCode: 400, body: ["error": "'from' and 'into' must be different"])
        }
        guard let movedCount = ReflectionStore.shared.mergeThemes(source: source, target: target) else {
            return HTTPResponse(statusCode: 500, body: ["error": "Merge failed"])
        }
        return HTTPResponse(statusCode: 200, body: [
            "message": "Themes merged",
            "from": source,
            "into": target,
            "reflections_moved": movedCount
        ])
    }

    /// Hide a moment (belief shift / decision) from a theme, or move it to another theme.
    /// Body: { reflection_id, item_type ("shift"|"decision"), content, from (shift only),
    ///         from_theme, to_theme (omit/null → pure exclude) }
    private func handleReflectItemMove(_ request: HTTPRequest) -> HTTPResponse {
        guard let bodyData = request.body,
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let rid = (json["reflection_id"] as? Int) ?? (json["reflection_id"] as? NSNumber)?.intValue,
              let itemType = (json["item_type"] as? String)?.trimmingCharacters(in: .whitespaces),
              let content = json["content"] as? String,
              let fromTheme = (json["from_theme"] as? String)?.trimmingCharacters(in: .whitespaces),
              !itemType.isEmpty, !content.isEmpty, !fromTheme.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing reflection_id / item_type / content / from_theme"])
        }
        guard itemType == "shift" || itemType == "decision" else {
            return HTTPResponse(statusCode: 400, body: ["error": "item_type must be 'shift' or 'decision'"])
        }
        let aux = (json["from"] as? String)   // shift "from" belief; nil for decisions
        let toTheme = (json["to_theme"] as? String)?.trimmingCharacters(in: .whitespaces)
        let toThemeClean = (toTheme?.isEmpty ?? true) ? nil : toTheme
        if let t = toThemeClean, t == fromTheme {
            return HTTPResponse(statusCode: 400, body: ["error": "to_theme must differ from from_theme"])
        }

        let ok = ReflectionStore.shared.setItemOverride(
            reflectionId: rid, itemType: itemType, content: content,
            aux: aux, fromTheme: fromTheme, toTheme: toThemeClean
        )
        guard ok else {
            return HTTPResponse(statusCode: 500, body: ["error": "Failed to record override"])
        }
        return HTTPResponse(statusCode: 200, body: [
            "success": true,
            "action": toThemeClean == nil ? "excluded" : "moved",
            "from_theme": fromTheme,
            "to_theme": toThemeClean ?? ""
        ])
    }

    /// Undo a prior item override (restore the moment to its original theme).
    private func handleReflectItemRestore(_ request: HTTPRequest) -> HTTPResponse {
        guard let bodyData = request.body,
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let rid = (json["reflection_id"] as? Int) ?? (json["reflection_id"] as? NSNumber)?.intValue,
              let itemType = (json["item_type"] as? String)?.trimmingCharacters(in: .whitespaces),
              let content = json["content"] as? String,
              let fromTheme = (json["from_theme"] as? String)?.trimmingCharacters(in: .whitespaces),
              !itemType.isEmpty, !content.isEmpty, !fromTheme.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing reflection_id / item_type / content / from_theme"])
        }
        let aux = json["from"] as? String
        let ok = ReflectionStore.shared.clearItemOverride(
            reflectionId: rid, itemType: itemType, content: content, aux: aux, fromTheme: fromTheme
        )
        return HTTPResponse(statusCode: 200, body: ["success": ok])
    }

    private func handleReflectPull(_ request: HTTPRequest) -> HTTPResponse {
        // Trigger the reflection ingestion cadence in the background
        guard let runner = cadenceRunner else {
            return jsonResponse(["error": "CadenceRunner not available"], status: 503)
        }

        let sourceFilter: String?
        if let body = request.body,
           let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let source = json["source"] as? String, source != "all" {
            sourceFilter = source
        } else {
            sourceFilter = nil
        }

        // Look up the built-in reflection ingestion cadence
        guard let cadence = CadenceService.shared.get(id: "builtin-reflection-ingestion") else {
            return jsonResponse(["error": "Reflection ingestion cadence not found"], status: 404)
        }

        Task {
            do {
                let summary = try await runner.run(cadence)
                let timestamp = Self.iso8601Formatter.string(from: Date())
                CadenceService.shared.markManualRunSuccess(id: cadence.id, timestamp: timestamp, summary: summary)
                print("✅ [API] Reflection pull completed: \(summary)")
            } catch {
                CadenceService.shared.markRunFailure(id: cadence.id, cooldownMinutes: 5, errorMessage: "\(error)")
                print("❌ [API] Reflection pull failed: \(error)")
            }
        }

        let msg = sourceFilter != nil ? "Reflection pull started for \(sourceFilter!)" : "Reflection pull started (all sources)"
        return jsonResponse(["success": true, "message": msg], status: 202)
    }

    private func handleReflectReset() -> HTTPResponse {
        ReflectionStore.shared.clearAll()
        return jsonResponse(["success": true, "message": "All reflection data cleared"], status: 200)
    }
}
