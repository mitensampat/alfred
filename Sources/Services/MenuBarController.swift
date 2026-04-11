import Foundation
import AppKit
import UserNotifications
import SQLite3

/// Menu bar controller for Alfred - shows server status and provides quick controls
class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var httpServer: HTTPServer?
    private var isServerRunning = false
    private var serverPort: Int = 8080
    private var config: AppConfig?
    private var alfredService: AlfredService?
    private var orchestrator: BriefingOrchestrator?
    private var schedulerTimer: Timer?

    // In-memory dedup for cadence loop (keyed by cadence ID → "YYYY-MM-DD_HH:mm")
    private var lastCadenceRunKeys: [String: String] = [:]

    // In-flight guard: cadence IDs currently executing (prevents duplicate spawns while async work is running)
    private var inFlightCadenceIds: Set<String> = []

    // CadenceRunner dispatches actions to service methods
    private var cadenceRunner: CadenceRunner?

    // Persistent storage for last run dates (to support catch-up after app restart)
    private var schedulerStatePath: String {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(homeDir)/.alfred/scheduler_state.json"
    }

    init(config: AppConfig, alfredService: AlfredService, orchestrator: BriefingOrchestrator? = nil) {
        self.config = config
        self.alfredService = alfredService
        self.orchestrator = orchestrator
        self.serverPort = config.api?.port ?? 8080
        super.init()
        self.cadenceRunner = CadenceRunner(alfredService: alfredService, orchestrator: orchestrator, menuBarController: self)
    }

    func setup() {
        setupMenuBar()
        startServer()
        startScheduler()
        setupLearningNotifications()

        // Check permissions on startup and alert if missing
        checkPermissionsOnStartup()
    }

    // MARK: - Permissions Check

    private func checkPermissionsOnStartup() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.performPermissionsCheck()
        }
    }

    private func performPermissionsCheck() {
        var missingPermissions: [String] = []

        // Check Full Disk Access by trying to open iMessage database via SQLite
        // (FileManager.isReadableFile falsely returns false for TCC-protected files even with Full Disk Access)
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let imessageDBPath = "\(homeDir)/Library/Messages/chat.db"
        var testDB: OpaquePointer?
        if sqlite3_open_v2(imessageDBPath, &testDB, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            var stmt: OpaquePointer?
            let testResult = sqlite3_prepare_v2(testDB, "SELECT 1 FROM message LIMIT 1", -1, &stmt, nil)
            sqlite3_finalize(stmt)
            sqlite3_close(testDB)
            if testResult != SQLITE_OK {
                missingPermissions.append("Full Disk Access (for iMessage)")
            }
        } else {
            sqlite3_close(testDB)
            missingPermissions.append("Full Disk Access (for iMessage)")
        }

        // Check Contacts access (for name resolution)
        // Note: CNContactStore requires actual access attempt which might prompt
        // So we'll just check if we've logged any permission issues

        // Check WhatsApp database access
        let whatsappPaths = [
            "\(homeDir)/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite",
            "\(homeDir)/Library/Group Containers/group.net.whatsapp.family.shared/ChatStorage.sqlite"
        ]
        let hasWhatsAppAccess = whatsappPaths.contains { FileManager.default.isReadableFile(atPath: $0) }
        if !hasWhatsAppAccess {
            // Not a critical error - user might not have WhatsApp
        }

        if !missingPermissions.isEmpty {
            let title = "⚠️ Alfred Needs Permissions"
            let body = "Missing: \(missingPermissions.joined(separator: ", ")). Grant in System Settings → Privacy & Security"
            showNotification(title: title, body: body)

            // Log to scheduler log
            let logPath = "\(homeDir)/.alfred/scheduler.log"
            logToFile("PERMISSION WARNING: \(missingPermissions.joined(separator: ", "))", path: logPath)

            print("⚠️ PERMISSION WARNING: \(missingPermissions.joined(separator: ", "))")
            print("   Go to System Settings → Privacy & Security → Full Disk Access")
            print("   Add Alfred.app to the list and enable it")
        } else {
            print("✅ Permissions check passed")
        }
    }

    // MARK: - Learning Notifications

    private func setupLearningNotifications() {
        // Subscribe to agent learning events
        AgentMemoryService.shared.onLearningRecorded = { [weak self] agentType, learning, source in
            let title = source == "user-taught" ? "Alfred Learned a Rule" : "Alfred Learned Something"
            let body = "\(agentType.displayName): \(learning.prefix(100))\(learning.count > 100 ? "..." : "")"
            self?.showNotification(title: title, body: body)
        }
    }

    // MARK: - Menu Bar Setup

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            updateStatusIcon(running: false)
            button.toolTip = "Alfred - judgement from noise"
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem?.menu = menu
        updateMenu()
    }

    // Rebuild menu every time it opens to reflect current state
    func menuWillOpen(_ menu: NSMenu) {
        updateMenu()
    }

    private func updateStatusIcon(running: Bool) {
        guard let button = statusItem?.button else { return }

        // Use simple text title - more reliable than custom drawing
        button.title = running ? "🎩" : "🎩"
        button.image = nil
    }

    private func updateMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()

        // Status header
        let statusTitle = isServerRunning ? "● Server Running" : "○ Server Stopped"
        let statusMenuItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        if isServerRunning {
            statusMenuItem.attributedTitle = NSAttributedString(
                string: statusTitle,
                attributes: [.foregroundColor: NSColor.systemGreen]
            )
        }
        menu.addItem(statusMenuItem)

        if isServerRunning {
            let portItem = NSMenuItem(title: "   Port: \(serverPort)", action: nil, keyEquivalent: "")
            portItem.isEnabled = false
            menu.addItem(portItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Toggle server
        if isServerRunning {
            let stopItem = NSMenuItem(title: "Stop Server", action: #selector(toggleServer), keyEquivalent: "s")
            stopItem.target = self
            menu.addItem(stopItem)
        } else {
            let startItem = NSMenuItem(title: "Start Server", action: #selector(toggleServer), keyEquivalent: "s")
            startItem.target = self
            menu.addItem(startItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Open Web UI
        let webUIItem = NSMenuItem(title: "Open Web UI", action: #selector(openWebUI), keyEquivalent: "o")
        webUIItem.target = self
        webUIItem.isEnabled = isServerRunning
        menu.addItem(webUIItem)

        // Copy URL
        let copyURLItem = NSMenuItem(title: "Copy URL", action: #selector(copyURL), keyEquivalent: "c")
        copyURLItem.target = self
        copyURLItem.isEnabled = isServerRunning
        menu.addItem(copyURLItem)

        menu.addItem(NSMenuItem.separator())

        // Open Config Folder
        let configItem = NSMenuItem(title: "Open Config Folder", action: #selector(openConfigFolder), keyEquivalent: ",")
        configItem.target = self
        menu.addItem(configItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit Alfred", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.addItem(NSMenuItem.separator())

        // Version
        let versionItem = NSMenuItem(title: "v\(AlfredApp.version)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        versionItem.attributedTitle = NSAttributedString(
            string: "v\(AlfredApp.version)",
            attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 11)]
        )
        menu.addItem(versionItem)
    }

    // MARK: - Server Management

    private func startServer() {
        guard !isServerRunning else { return }
        guard let config = config, let apiConfig = config.api, apiConfig.enabled else {
            print("ℹ️  HTTP API disabled in config")
            return
        }
        guard let alfredService = alfredService else {
            print("❌ AlfredService not initialized")
            return
        }

        serverPort = apiConfig.port

        let server = HTTPServer(
            port: apiConfig.port,
            passcode: apiConfig.passcode,
            alfredService: alfredService,
            cadenceRunner: cadenceRunner
        )

        self.httpServer = server

        do {
            try server.start()
            self.isServerRunning = true
            DispatchQueue.main.async {
                self.updateStatusIcon(running: true)
                self.updateMenu()
            }
            print("✅ HTTP server started on port \(apiConfig.port)")
        } catch {
            print("❌ Failed to start HTTP server: \(error)")
        }
    }

    private func stopServer() {
        httpServer?.stop()
        httpServer = nil
        isServerRunning = false
        DispatchQueue.main.async {
            self.updateStatusIcon(running: false)
            self.updateMenu()
        }
        print("🛑 HTTP server stopped")
    }

    // MARK: - Actions

    @objc func toggleServer() {
        print("🔄 Toggle server called. Currently running: \(isServerRunning)")
        if isServerRunning {
            stopServer()
        } else {
            startServer()
        }
    }

    @objc func openWebUI() {
        guard isServerRunning else { return }
        if let url = URL(string: "http://localhost:\(serverPort)") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func copyURL() {
        guard isServerRunning else { return }
        let url = "http://localhost:\(serverPort)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    @objc func openConfigFolder() {
        let configPath = (NSString(string: "~/.config/alfred").expandingTildeInPath)
        NSWorkspace.shared.open(URL(fileURLWithPath: configPath))
    }

    @objc func quitApp() {
        stopServer()
        stopScheduler()
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Scheduler

    private func startScheduler() {
        guard let config = config else { return }

        // Log scheduler start
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let logPath = "\(homeDir)/.alfred/scheduler.log"
        logToFile("Scheduler started (unified cadence loop)", path: logPath)

        let enabledCadences = CadenceService.shared.getEnabled()
        for cadence in enabledCadences {
            logToFile("  \(cadence.icon) \(cadence.name): \(cadence.schedule.displayText)", path: logPath)
        }

        print("📅 Scheduler started (unified cadence loop, \(enabledCadences.count) cadences)")

        // Check every 60 seconds
        schedulerTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task {
                await self?.checkAndRunScheduledTasks()
            }
        }

        // Also run immediately to catch any missed tasks
        Task {
            await checkAndRunScheduledTasks()
        }
    }

    private func stopScheduler() {
        schedulerTimer?.invalidate()
        schedulerTimer = nil
    }

    // MARK: - Scheduler State Persistence

    // SchedulerState: only used for pinned goal persistence now.
    // All cadence scheduling state is managed by CadenceService.
    private struct SchedulerState: Codable {
        // Legacy cadence fields kept for backward-compatible JSON decoding
        var lastBriefingDate: String?
        var lastAttentionDate: String?
        var lastTodoScanTime: String?
        var lastCommitmentScanDate: String?
        var lastCommitmentScanTimestamp: String?
        var lastPatternLearnDate: String?
        var lastPatternLearnTimestamp: String?
        var lastGroupAnalysisDate: String?
        var lastGroupAnalysisTimestamp: String?
        var lastAutoSummaryDate: String?
        var lastAutoSummaryTimestamp: String?
        var lastWeeklyReviewDate: String?
        var lastWeeklyReviewTimestamp: String?
        // Pin It: user's declared #1 focus goal (actively used by HTTPServer)
        var pinnedGoalNotionId: String?
        var pinnedGoalAt: String?
    }

    private func loadSchedulerState() -> SchedulerState {
        guard let data = FileManager.default.contents(atPath: schedulerStatePath),
              let state = try? JSONDecoder().decode(SchedulerState.self, from: data) else {
            return SchedulerState()
        }
        return state
    }

    private func saveSchedulerState(_ state: SchedulerState) {
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: URL(fileURLWithPath: schedulerStatePath))
        }
    }

    private func todayDateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private func checkAndRunScheduledTasks() async {
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let currentTime = formatter.string(from: now)
        let todayDate = todayDateString()

        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let logPath = "\(homeDir)/.alfred/scheduler.log"

        // ===============================================
        // UNIFIED CADENCE LOOP (single scheduling system)
        // All action types — including morning briefing and attention check —
        // are driven by CadenceService. No hardcoded scheduler blocks.
        // ===============================================
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        let weekday = calendar.component(.weekday, from: now) // 1=Sun, 2=Mon, ..., 5=Thu, 7=Sat

        guard let runner = cadenceRunner else { return }

        for cadence in CadenceService.shared.getEnabled() {
            let runKey = "\(todayDate)_\(currentTime)"
            // In-memory dedup: don't re-evaluate the same cadence at the same minute
            if lastCadenceRunKeys[cadence.id] == runKey { continue }

            // In-flight guard: skip if this cadence is already running (prevents duplicate
            // spawns while async work takes longer than the 60-second tick interval)
            if inFlightCadenceIds.contains(cadence.id) { continue }

            let shouldRun = shouldRunCadence(cadence, currentTime: currentTime, todayDate: todayDate, hour: hour, weekday: weekday, now: now, logPath: logPath)
            guard shouldRun else { continue }

            // Mark in-memory dedup + in-flight guard
            lastCadenceRunKeys[cadence.id] = runKey
            inFlightCadenceIds.insert(cadence.id)

            logToFile("\(cadence.icon) [Cadence] Running \(cadence.name)...", path: logPath)
            do {
                let summary = try await runner.run(cadence)
                let timestamp = ISO8601DateFormatter().string(from: Date())
                CadenceService.shared.markRunSuccess(id: cadence.id, date: todayDate, timestamp: timestamp, summary: summary)
                logToFile("✅ [Cadence] \(cadence.name): \(summary)", path: logPath)
                if cadence.notifyOnSuccess {
                    showNotification(title: "Alfred: \(cadence.name)", body: summary)
                }
            } catch {
                logToFile("❌ [Cadence] \(cadence.name) failed: \(error)", path: logPath)
                CadenceService.shared.markRunFailure(id: cadence.id, cooldownMinutes: 30, errorMessage: "\(error)")
            }
            // Release in-flight guard after completion (success or failure)
            inFlightCadenceIds.remove(cadence.id)
        }

        // ===============================================
        // COACHING PUSH CHECK (runs every 60s, outside cadence loop)
        // Lightweight in-memory checks for pre-meeting, post-meeting, morning nudge
        // ===============================================
        await CoachingPushService.shared.tick(orchestrator: alfredService?.orchestrator)
    }

    /// Evaluates whether a cadence should run right now based on its schedule type.
    ///
    /// Key design decisions:
    /// - Daily cadences: run any time after the scheduled time on the same day (rest-of-day catch-up).
    ///   A laptop may be asleep at the exact time — when it wakes, the cadence fires.
    /// - Weekly cadences: run on the scheduled day OR within `weeklyCatchUpDays` after.
    ///   If Sunday is missed, Monday/Tuesday still catch up.
    /// - Manual API runs do NOT suppress scheduled runs (tracked separately).
    private func shouldRunCadence(_ cadence: Cadence, currentTime: String, todayDate: String, hour: Int, weekday: Int, now: Date, logPath: String) -> Bool {
        // Check failure cooldown
        if let cooldownUntil = cadence.failureCooldownUntil, now < cooldownUntil {
            return false
        }

        switch cadence.schedule {
        case .daily(let time):
            // Already ran today (via scheduler)?
            guard cadence.lastRunDate != todayDate else { return false }
            // Must be at or past the scheduled time — rest-of-day catch-up
            guard currentTime >= time else { return false }
            if currentTime != time {
                logToFile("⏰ [Cadence] Catch-up: Missed \(cadence.name) time (\(time)), running at \(currentTime)", path: logPath)
            }
            return true

        case .weekly(let day, let time):
            let targetWeekday = dayNameToWeekday(day)

            // Check if we're on the scheduled day or within the catch-up window
            let daysElapsed = (weekday - targetWeekday + 7) % 7  // 0 = same day, 1 = next day, etc.
            guard daysElapsed <= cadence.weeklyCatchUpDays else { return false }

            // Already ran this week? Check if lastRunDate falls within recent days
            if let lastRunDate = cadence.lastRunDate {
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd"
                if let lastDate = dateFormatter.date(from: lastRunDate) {
                    let daysSinceLastRun = Calendar.current.dateComponents([.day], from: lastDate, to: now).day ?? 0
                    // If it ran within the last 6 days, it already ran this week
                    if daysSinceLastRun < 7 && daysSinceLastRun >= 0 {
                        return false
                    }
                }
            }

            // On the scheduled day: must be at or past the scheduled time
            if daysElapsed == 0 {
                guard currentTime >= time else { return false }
                if currentTime != time {
                    logToFile("⏰ [Cadence] Catch-up: Missed \(cadence.name) time (\(time)), running at \(currentTime)", path: logPath)
                }
            } else {
                // Catch-up day: run immediately (any time of day)
                logToFile("⏰ [Cadence] Weekly catch-up: \(cadence.name) missed \(day) @ \(time), running \(daysElapsed) day(s) late", path: logPath)
            }
            return true

        case .interval(let hours, let activeStart, let activeEnd):
            // Must be within active hours
            guard hour >= activeStart && hour <= activeEnd else { return false }
            // Check elapsed time since last run
            if let lastTimestamp = cadence.lastRunTimestamp {
                let isoFormatter = ISO8601DateFormatter()
                if let lastDate = isoFormatter.date(from: lastTimestamp) {
                    let elapsed = now.timeIntervalSince(lastDate)
                    return elapsed >= Double(hours * 3600)
                }
            }
            // Never run before → run now
            return true
        }
    }

    private func dayNameToWeekday(_ name: String) -> Int {
        switch name.lowercased() {
        case "sunday": return 1
        case "monday": return 2
        case "tuesday": return 3
        case "wednesday": return 4
        case "thursday": return 5
        case "friday": return 6
        case "saturday": return 7
        default: return 5  // Default to Thursday
        }
    }

    private func logToFile(_ message: String, path: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logMessage = "[\(timestamp)] \(message)\n"

        if FileManager.default.fileExists(atPath: path) {
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                if let data = logMessage.data(using: .utf8) {
                    handle.write(data)
                }
                handle.closeFile()
            }
        } else {
            try? logMessage.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private func showNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil  // Deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Failed to show notification: \(error)")
            }
        }
    }
}
