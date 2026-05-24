import Foundation

/// Lightweight service that runs every 60 seconds to check for coaching push opportunities.
/// Handles post-meeting capture prompts and morning coaching pushes.
/// Pre-meeting nudges are intentionally NOT pushed — the home page card handles that.
/// Designed to be called from the 60-second scheduler timer (not the cadence system).
class CoachingPushService {
    static let shared = CoachingPushService()

    // Track which meetings we've already sent pushes for (prevents duplicates)
    private var postMeetingPushed: Set<String> = []   // event IDs

    // Persisted to disk so restarts mid-window still deliver
    private var morningNudgeSentDate: String? = nil   // "YYYY-MM-DD"
    private let nudgeStatePath: String

    // Minimum interval between any two push notifications (prevents rapid-fire)
    private var lastPushSentAt: Date = .distantPast
    private let minPushIntervalSeconds: TimeInterval = 300  // 5 minutes

    // Pending capture: set when post-meeting push is sent, cleared when user opens capture or dismisses
    private(set) var pendingCapture: PendingCapture? = nil

    struct PendingCapture: Codable {
        let meetingId: String
        let meetingTitle: String
        let createdAt: Date
    }

    func clearPendingCapture() {
        pendingCapture = nil
    }

    func setPendingCapture(meetingId: String, meetingTitle: String) {
        pendingCapture = PendingCapture(meetingId: meetingId, meetingTitle: meetingTitle, createdAt: Date())
    }

    // Cached events (refreshed every 10 min)
    private var cachedEvents: [CalendarEvent] = []
    private var lastEventFetch: Date? = nil

    private init() {
        self.nudgeStatePath = NSString(string: "~/.alfred/morning_nudge_state.json").expandingTildeInPath
        loadNudgeState()
    }

    // MARK: - Main Tick (called every 60 seconds from scheduler timer)

    /// Check for coaching push opportunities. Lightweight — mostly in-memory checks.
    func tick(orchestrator: BriefingOrchestrator?) async {
        guard let config = AppConfig.load(),
              let publicKey = config.notifications.push.vapidPublicKey,
              let privateKey = config.notifications.push.vapidPrivateKey,
              let subject = config.notifications.push.vapidSubject else {
            return  // Push not configured
        }

        guard !WebPushService.shared.getSubscriptions().isEmpty else {
            return  // No subscribers
        }

        guard !PushBudgetService.shared.shouldSuppress() else {
            return  // Quiet hours, user active, or budget exhausted
        }

        let now = Date()

        // Refresh calendar events every 10 minutes
        if cachedEvents.isEmpty || lastEventFetch == nil || now.timeIntervalSince(lastEventFetch!) > 600 {
            if let orch = orchestrator {
                do {
                    let schedule = try await orch.calendarServicePublic.fetchEventsFromAllCalendars(
                        for: now,
                        userSettings: config.user
                    )
                    cachedEvents = schedule.events
                    lastEventFetch = now
                } catch {
                    print("📱 [CoachingPush] Calendar fetch failed: \(error)")
                }
            }
        }

        // Reset pushed sets at midnight
        let todayStr = String(ISO8601DateFormatter().string(from: now).prefix(10))
        if let lastDate = morningNudgeSentDate, !lastDate.hasPrefix(todayStr) {
            postMeetingPushed.removeAll()
        }

        // Morning nudge first (once per day, at briefing time) — gets priority over post-meeting
        if config.notifications.push.morningNudgeEnabled ?? true {
            await checkMorningNudge(
                now: now, config: config,
                publicKey: publicKey, privateKey: privateKey, subject: subject
            )
        }

        // Check for post-meeting capture (meeting ended 3-7 min ago)
        if config.notifications.push.postMeetingCaptureEnabled ?? true {
            await checkPostMeeting(
                events: cachedEvents, now: now,
                config: config, publicKey: publicKey, privateKey: privateKey, subject: subject
            )
        }
    }

    // MARK: - Post-Meeting Capture

    private func checkPostMeeting(
        events: [CalendarEvent], now: Date,
        config: AppConfig, publicKey: String, privateKey: String, subject: String
    ) async {
        // Enforce minimum interval between pushes
        guard now.timeIntervalSince(lastPushSentAt) >= minPushIntervalSeconds else {
            return
        }

        // Collect all meetings that ended in the capture window
        let candidateEvents = events.filter { event in
            guard !event.isAllDay else { return false }
            guard !postMeetingPushed.contains(event.id) else { return false }

            let minutesSinceEnd = now.timeIntervalSince(event.endTime) / 60
            // Fire in the 3-10 minute window after meeting ends (wider than before for batching)
            return minutesSinceEnd >= 3 && minutesSinceEnd <= 10
        }.filter { qualifiesForPush($0) }

        guard !candidateEvents.isEmpty else { return }
        guard PushBudgetService.shared.canPush() else { return }

        // If multiple meetings ended close together, batch them into one notification
        let event = candidateEvents.first!
        for e in candidateEvents { postMeetingPushed.insert(e.id) }

        // Store pending capture for the most recent meeting
        pendingCapture = PendingCapture(meetingId: event.id, meetingTitle: event.title, createdAt: Date())

        let captureUrl = "/home.html"

        let body: String
        if candidateEvents.count > 1 {
            body = "\(candidateEvents.count) meetings just ended. Any follow-ups to capture?"
        } else {
            body = "Any follow-ups or commitments to capture?"
        }

        let payload = WebPushService.PushPayload(
            title: candidateEvents.count > 1
                ? "\(candidateEvents.count) meetings wrapped up"
                : "Just left: \(String(event.title.prefix(40)))",
            body: body,
            tag: "post-meeting-\(String(event.id.prefix(12)))",
            url: captureUrl,
            type: "post-meeting",
            actions: [
                WebPushService.PushPayload.PushAction(action: "capture", title: "Capture"),
                WebPushService.PushPayload.PushAction(action: "dismiss", title: "Nothing")
            ]
        )

        print("📱 [CoachingPush] Post-meeting capture for '\(event.title)'" + (candidateEvents.count > 1 ? " (+\(candidateEvents.count - 1) more)" : ""))

        lastPushSentAt = Date()
        await WebPushService.shared.sendToAll(
            payload,
            vapidPublicKey: publicKey,
            vapidPrivateKey: privateKey,
            vapidSubject: subject
        )
        PushBudgetService.shared.recordPush()
    }

    // MARK: - Morning Nudge

    private func checkMorningNudge(
        now: Date, config: AppConfig,
        publicKey: String, privateKey: String, subject: String
    ) async {
        let todayStr = String(ISO8601DateFormatter().string(from: now).prefix(10))
        guard morningNudgeSentDate != todayStr else { return }

        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)

        let briefingTime = config.app.briefingTime ?? "08:15"
        let parts = briefingTime.split(separator: ":").compactMap { Int($0) }
        let targetHour = parts.count >= 1 ? parts[0] : 8
        let targetMinute = parts.count >= 2 ? parts[1] : 15

        // Fire within a 20-minute window of briefing time (resilient to restarts/timer drift)
        let currentMinutes = hour * 60 + minute
        let targetMinutes = targetHour * 60 + targetMinute
        guard currentMinutes >= targetMinutes && currentMinutes <= targetMinutes + 20 else { return }
        guard PushBudgetService.shared.canPush() else { return }

        morningNudgeSentDate = todayStr
        saveNudgeState()

        // Count today's meetings
        let meetingCount = cachedEvents.filter { !$0.isAllDay }.count

        let body: String
        if meetingCount == 0 {
            body = "Clear calendar today. Good day for deep work."
        } else {
            let nextMeeting = cachedEvents
                .filter { !$0.isAllDay && $0.startTime > now }
                .sorted { $0.startTime < $1.startTime }
                .first

            if let next = nextMeeting {
                let timeFmt = DateFormatter()
                timeFmt.dateFormat = "h:mm a"
                body = "\(meetingCount) meetings today. First up: \(String(next.title.prefix(30))) at \(timeFmt.string(from: next.startTime))."
            } else {
                body = "\(meetingCount) meetings today. Your briefing is ready."
            }
        }

        let payload = WebPushService.PushPayload(
            title: "Good morning",
            body: body,
            tag: "morning-nudge",
            url: "/home.html",
            type: "morning",
            actions: [
                WebPushService.PushPayload.PushAction(action: "open", title: "Open Alfred"),
                WebPushService.PushPayload.PushAction(action: "dismiss", title: "Got it")
            ]
        )

        print("📱 [CoachingPush] Morning nudge sent")

        lastPushSentAt = Date()
        await WebPushService.shared.sendToAll(
            payload,
            vapidPublicKey: publicKey,
            vapidPrivateKey: privateKey,
            vapidSubject: subject
        )
        PushBudgetService.shared.recordPush()

        // Pre-warm home page caches so the UI loads instantly when user taps the notification
        await prewarmHomeCache(config: config)
    }

    // MARK: - Cache Pre-Warming

    /// Fires off parallel requests to warm the home page caches after sending a push notification.
    /// By the time the user taps through (~5-30s later), all data is cached and renders instantly.
    private func prewarmHomeCache(config: AppConfig) async {
        let port = config.api?.port ?? 8080
        let pc = config.api?.passcode ?? "changeme"
        let base = "http://localhost:\(port)"

        print("🔥 [CoachingPush] Pre-warming home caches...")

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                if let url = URL(string: "\(base)/api/home/pulse?passcode=\(pc)") {
                    _ = try? await URLSession.shared.data(from: url)
                }
            }
            group.addTask {
                if let url = URL(string: "\(base)/api/coaching/cards?passcode=\(pc)") {
                    _ = try? await URLSession.shared.data(from: url)
                }
            }
            group.addTask {
                if let url = URL(string: "\(base)/api/coaching/opener?passcode=\(pc)") {
                    _ = try? await URLSession.shared.data(from: url)
                }
            }
            group.addTask {
                if let url = URL(string: "\(base)/api/home/next-meeting-brief?passcode=\(pc)") {
                    _ = try? await URLSession.shared.data(from: url)
                }
            }
        }

        print("✅ [CoachingPush] Home caches warm")
    }

    // MARK: - Smart Meeting Filter

    /// Determines if a meeting qualifies for push notifications.
    private func qualifiesForPush(_ event: CalendarEvent) -> Bool {
        if event.isAllDay { return false }
        if event.duration < 900 { return false }  // Skip < 15 min
        if event.attendees.isEmpty { return false }  // Skip solo blocks
        return true
    }

    // MARK: - Nudge State Persistence

    private struct NudgeState: Codable {
        let morningNudgeSentDate: String?
    }

    private func loadNudgeState() {
        guard FileManager.default.fileExists(atPath: nudgeStatePath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: nudgeStatePath)),
              let state = try? JSONDecoder().decode(NudgeState.self, from: data) else {
            return
        }
        morningNudgeSentDate = state.morningNudgeSentDate
    }

    private func saveNudgeState() {
        let state = NudgeState(morningNudgeSentDate: morningNudgeSentDate)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: URL(fileURLWithPath: nudgeStatePath))
        }
    }
}
