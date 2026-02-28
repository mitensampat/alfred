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
    private var lastBriefingRun: String = ""
    private var lastAttentionRun: String = ""

    // Cadence loop tracking
    private var lastTodoScanRun: String = ""
    private var lastCommitmentScanRun: String = ""
    private var lastPatternLearnRun: String = ""
    private var lastGroupAnalysisRun: String = ""
    private var lastAutoSummaryRun: String = ""
    private var lastWeeklyReviewRun: String = ""

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
            alfredService: alfredService
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
        logToFile("Scheduler started", path: logPath)
        logToFile("Morning briefing time: \(config.app.briefingTime)", path: logPath)
        logToFile("Attention check time: \(config.app.attentionAlertTime)", path: logPath)

        if let scheduled = config.scheduled {
            logToFile("Email to: \(scheduled.emailTo)", path: logPath)
            logToFile("Briefing enabled: \(scheduled.briefingEnabled)", path: logPath)
            logToFile("Attention enabled: \(scheduled.attentionEnabled)", path: logPath)
        }

        print("📅 Scheduler started")
        print("   Briefing: \(config.app.briefingTime)")
        print("   Attention: \(config.app.attentionAlertTime)")

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

    private struct SchedulerState: Codable {
        var lastBriefingDate: String?  // Format: "yyyy-MM-dd"
        var lastAttentionDate: String?  // Format: "yyyy-MM-dd"
        // Cadence loop state
        var lastTodoScanTime: String?        // ISO timestamp (interval-based)
        var lastCommitmentScanDate: String?  // date string (daily)
        var lastCommitmentScanTimestamp: String?  // ISO timestamp for UI display
        var lastPatternLearnDate: String?    // date string (weekly)
        var lastPatternLearnTimestamp: String? // ISO timestamp for UI display
        var lastGroupAnalysisDate: String?   // date string (weekly)
        var lastGroupAnalysisTimestamp: String? // ISO timestamp for UI display
        var lastAutoSummaryDate: String?     // date string (daily)
        var lastAutoSummaryTimestamp: String? // ISO timestamp for UI display
        var lastWeeklyReviewDate: String?    // date string (weekly)
        var lastWeeklyReviewTimestamp: String? // ISO timestamp for UI display
        // Pin It: user's declared #1 focus goal
        var pinnedGoalNotionId: String?
        var pinnedGoalAt: String?             // ISO timestamp when pinned
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
        // Re-read config for hot-reload
        let config = AppConfig.load() ?? self.config
        guard let config = config else { return }

        let scheduled = config.scheduled
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let currentTime = formatter.string(from: now)
        let todayDate = todayDateString()

        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let logPath = "\(homeDir)/.alfred/scheduler.log"

        let emailTo = scheduled?.emailTo.isEmpty == false ? scheduled?.emailTo : nil

        // Load persistent state to track which days we've run tasks
        var state = loadSchedulerState()

        // Morning Briefing
        let briefingEnabled = scheduled?.briefingEnabled ?? true
        let briefingTime = config.app.briefingTime  // e.g. "08:15"

        // Check if we should run briefing:
        // 1. At the exact scheduled time, OR
        // 2. If we missed today's briefing (current time is after scheduled time, but we haven't run today)
        let shouldRunBriefing: Bool = {
            guard briefingEnabled && state.lastBriefingDate != todayDate else { return false }

            // At the exact scheduled time
            if currentTime == briefingTime && lastBriefingRun != currentTime {
                return true
            }

            // Catch-up: We're past the scheduled time but haven't run today
            if currentTime > briefingTime {
                logToFile("Catch-up: Missed briefing time (\(briefingTime)), running now at \(currentTime)", path: logPath)
                return true
            }

            return false
        }()

        if shouldRunBriefing {
            lastBriefingRun = currentTime
            state.lastBriefingDate = todayDate
            saveSchedulerState(state)
            logToFile("Running morning briefing at \(currentTime)", path: logPath)

            if let orchestrator = orchestrator {
                do {
                    let today = Date()
                    _ = try await orchestrator.generateBriefing(for: today, sendNotifications: true, toAddress: emailTo)
                    logToFile("Morning briefing sent successfully", path: logPath)
                    showNotification(title: "Morning Briefing Sent", body: "Check your email for today's briefing")
                } catch {
                    logToFile("Error generating briefing: \(error)", path: logPath)
                    // Reset state so we can retry
                    state.lastBriefingDate = nil
                    saveSchedulerState(state)
                }
            } else {
                logToFile("Orchestrator not available for briefing", path: logPath)
            }
        }

        // Attention Check
        let attentionEnabled = scheduled?.attentionEnabled ?? true
        let attentionTime = config.app.attentionAlertTime  // e.g. "15:00"

        // Check if we should run attention check (same logic as briefing)
        let shouldRunAttention: Bool = {
            guard attentionEnabled && state.lastAttentionDate != todayDate else { return false }

            // At the exact scheduled time
            if currentTime == attentionTime && lastAttentionRun != currentTime {
                return true
            }

            // Catch-up: We're past the scheduled time but haven't run today
            if currentTime > attentionTime {
                logToFile("Catch-up: Missed attention time (\(attentionTime)), running now at \(currentTime)", path: logPath)
                return true
            }

            return false
        }()

        if shouldRunAttention {
            lastAttentionRun = currentTime
            state.lastAttentionDate = todayDate
            saveSchedulerState(state)
            logToFile("Running attention check at \(currentTime)", path: logPath)

            if let orchestrator = orchestrator {
                do {
                    _ = try await orchestrator.generateAttentionDefenseAlert(sendNotifications: true, toAddress: emailTo)
                    logToFile("Attention check sent successfully", path: logPath)
                    showNotification(title: "Attention Check Sent", body: "Check your email for the attention report")
                } catch {
                    logToFile("Error generating attention check: \(error)", path: logPath)
                    // Reset state so we can retry
                    state.lastAttentionDate = nil
                    saveSchedulerState(state)
                }
            } else {
                logToFile("Orchestrator not available for attention check", path: logPath)
            }
        }

        // ===============================================
        // CADENCE LOOPS
        // ===============================================
        let cadence = config.cadence
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        let weekday = calendar.component(.weekday, from: now) // 1=Sun, 2=Mon, ..., 5=Thu, 7=Sat

        // 1. Todo Scan: every N hours during active hours (9am-9pm)
        let todoScanEnabled = cadence?.todoScanEnabled ?? true
        let todoScanInterval = cadence?.todoScanIntervalHours ?? 3
        if todoScanEnabled && hour >= 9 && hour <= 21 {
            let shouldRunTodoScan: Bool = {
                guard let lastScan = state.lastTodoScanTime else { return true }
                let isoFormatter = ISO8601DateFormatter()
                guard let lastDate = isoFormatter.date(from: lastScan) else { return true }
                return Date().timeIntervalSince(lastDate) >= Double(todoScanInterval * 3600)
            }()

            if shouldRunTodoScan && lastTodoScanRun != currentTime {
                lastTodoScanRun = currentTime
                await runCadenceTodoScan(state: &state, logPath: logPath)
            }
        }

        // 2. Commitment Scan: daily at configured time (default 17:00)
        let commitmentScanEnabled = cadence?.commitmentScanEnabled ?? true
        let commitmentScanTime = cadence?.commitmentScanTime ?? "17:00"
        if commitmentScanEnabled && currentTime == commitmentScanTime
            && state.lastCommitmentScanDate != todayDate
            && lastCommitmentScanRun != currentTime {
            lastCommitmentScanRun = currentTime
            await runCadenceCommitmentScan(state: &state, todayDate: todayDate, logPath: logPath)
        }

        // 3. Pattern Learning: weekly on configured day (default Thursday=5) at configured time (default 18:00)
        let patternLearnEnabled = cadence?.patternLearnEnabled ?? true
        let patternLearnDay = cadence?.patternLearnDay?.lowercased() ?? "thursday"
        let patternLearnTime = cadence?.patternLearnTime ?? "18:00"
        let targetWeekday = dayNameToWeekday(patternLearnDay)
        if patternLearnEnabled && weekday == targetWeekday && currentTime == patternLearnTime
            && state.lastPatternLearnDate != todayDate
            && lastPatternLearnRun != currentTime {
            lastPatternLearnRun = currentTime
            await runCadencePatternLearning(state: &state, todayDate: todayDate, logPath: logPath, config: config)
        }

        // 4. Group Analysis: weekly on configured day (default Monday=2) at configured time (default 09:00)
        let groupAnalysisEnabled = cadence?.groupAnalysisEnabled ?? true
        let groupAnalysisDay = cadence?.groupAnalysisDay?.lowercased() ?? "monday"
        let groupAnalysisTime = cadence?.groupAnalysisTime ?? "09:00"
        let targetGroupDay = dayNameToWeekday(groupAnalysisDay)
        if groupAnalysisEnabled && weekday == targetGroupDay && currentTime == groupAnalysisTime
            && state.lastGroupAnalysisDate != todayDate
            && lastGroupAnalysisRun != currentTime {
            lastGroupAnalysisRun = currentTime
            await runCadenceGroupAnalysis(state: &state, todayDate: todayDate, logPath: logPath)
        }

        // 5. Auto-summaries: daily at configured time for approved groups
        let autoSummaryGroups = cadence?.autoSummaryGroups ?? []
        let autoSummaryTime = cadence?.autoSummaryTime ?? "18:00"
        if !autoSummaryGroups.isEmpty && currentTime == autoSummaryTime
            && state.lastAutoSummaryDate != todayDate
            && lastAutoSummaryRun != currentTime {
            lastAutoSummaryRun = currentTime
            await runCadenceAutoSummaries(groups: autoSummaryGroups, state: &state, todayDate: todayDate, logPath: logPath, emailTo: emailTo)
        }

        // 6. Weekly Review: on configured day (default Friday=6) at configured time (default 17:00)
        let weeklyReviewEnabled = cadence?.weeklyReviewEnabled ?? true
        let weeklyReviewDay = cadence?.weeklyReviewDay?.lowercased() ?? "sunday"
        let weeklyReviewTime = cadence?.weeklyReviewTime ?? "08:00"
        let targetReviewDay = dayNameToWeekday(weeklyReviewDay)
        if weeklyReviewEnabled && weekday == targetReviewDay && currentTime == weeklyReviewTime
            && state.lastWeeklyReviewDate != todayDate
            && lastWeeklyReviewRun != currentTime {
            lastWeeklyReviewRun = currentTime
            await runCadenceWeeklyReview(state: &state, todayDate: todayDate, logPath: logPath, config: config, emailTo: emailTo)
        }
    }

    // MARK: - Cadence Runner Methods

    private func runCadenceTodoScan(state: inout SchedulerState, logPath: String) async {
        logToFile("📝 [Cadence] Running todo scan...", path: logPath)
        guard let orchestrator = orchestrator else {
            logToFile("⚠️ [Cadence] Orchestrator not available for todo scan", path: logPath)
            return
        }
        do {
            let result = try await orchestrator.processWhatsAppTodos()
            state.lastTodoScanTime = ISO8601DateFormatter().string(from: Date())
            saveSchedulerState(state)
            logToFile("✅ [Cadence] Todo scan: found \(result.todosFound), created \(result.todosCreated), dupes \(result.duplicatesSkipped)", path: logPath)
            if result.todosCreated > 0 {
                showNotification(title: "Alfred: \(result.todosCreated) New Todos", body: "Extracted from WhatsApp and saved to Notion")
            }
        } catch {
            logToFile("❌ [Cadence] Todo scan failed: \(error)", path: logPath)
        }
    }

    private func runCadenceCommitmentScan(state: inout SchedulerState, todayDate: String, logPath: String) async {
        logToFile("🤝 [Cadence] Running commitment scan (all contacts)...", path: logPath)
        guard let alfredService = alfredService else {
            logToFile("⚠️ [Cadence] AlfredService not available", path: logPath)
            return
        }
        do {
            let result = try await alfredService.scanCommitments(contactName: nil, lookbackDays: 1, scanMode: "all")
            state.lastCommitmentScanDate = todayDate
            state.lastCommitmentScanTimestamp = ISO8601DateFormatter().string(from: Date())
            saveSchedulerState(state)
            logToFile("✅ [Cadence] Commitment scan: \(result.totalFound) found, \(result.saved) saved", path: logPath)
            if result.totalFound > 0 {
                showNotification(title: "Alfred: \(result.totalFound) Commitments Found", body: "Open Alfred to review and confirm")
            }
        } catch {
            logToFile("❌ [Cadence] Commitment scan failed: \(error)", path: logPath)
        }
    }

    private func runCadencePatternLearning(state: inout SchedulerState, todayDate: String, logPath: String, config: AppConfig) async {
        logToFile("🧠 [Cadence] Running weekly pattern learning...", path: logPath)
        do {
            // 1. Recompute all patterns from feedback data
            WorkflowLearningService.shared.computePatterns()
            logToFile("  ✓ Patterns recomputed", path: logPath)

            // 2. Generate and email learning digest
            if let digest = WorkflowLearningService.shared.generateLearningDigest() {
                let notifService = NotificationService(config: config.notifications)
                try await notifService.sendLearningDigest(subject: digest.subject, body: digest.body)
                logToFile("  ✓ Learning digest emailed", path: logPath)
            }

            // 3. Sync patterns to Notion Playbook
            try await PlaybookService.shared.syncToNotion()
            logToFile("  ✓ Playbook synced to Notion", path: logPath)

            // 4. Sync coaching context to Notion
            try await CoachingNotionSyncService.shared.syncToNotion(force: true)
            logToFile("  ✓ Coaching context synced to Notion", path: logPath)

            state.lastPatternLearnDate = todayDate
            state.lastPatternLearnTimestamp = ISO8601DateFormatter().string(from: Date())
            saveSchedulerState(state)
            logToFile("✅ [Cadence] Pattern learning complete", path: logPath)
            showNotification(title: "Alfred: Patterns Updated", body: "Weekly learning digest generated and playbook synced")
        } catch {
            logToFile("❌ [Cadence] Pattern learning failed: \(error)", path: logPath)
        }
    }

    private func runCadenceGroupAnalysis(state: inout SchedulerState, todayDate: String, logPath: String) async {
        logToFile("📊 [Cadence] Running busy group analysis...", path: logPath)
        do {
            // 1. Fetch all WhatsApp threads from the last 7 days
            guard let config = AppConfig.load() ?? self.config else {
                logToFile("⚠️ [Cadence] Config not available for group analysis", path: logPath)
                return
            }
            let whatsappReader = WhatsAppReader(dbPath: config.messaging.whatsapp.dbPath)
            try whatsappReader.connect()
            let since = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
            let threads = try whatsappReader.fetchThreads(since: since)
            whatsappReader.disconnect()

            // 2. Filter for groups (JID contains @g.us) and sort by message count
            let groupThreads = threads
                .filter { $0.contactIdentifier.contains("@g.us") }
                .sorted { $0.messages.count > $1.messages.count }

            // 3. Take top groups with >= 20 messages/week
            let busyGroups = groupThreads.filter { $0.messages.count >= 20 }

            // 4. Get existing auto-summary groups from config
            let existingAutoGroups = config.cadence?.autoSummaryGroups ?? []

            // 5. Filter out groups already approved for auto-summary
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

            // 6. Save suggestions to ~/.alfred/group_suggestions.json
            let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
            let suggestionsPath = "\(homeDir)/.alfred/group_suggestions.json"
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

            state.lastGroupAnalysisDate = todayDate
            state.lastGroupAnalysisTimestamp = ISO8601DateFormatter().string(from: Date())
            saveSchedulerState(state)
            logToFile("✅ [Cadence] Group analysis: \(groupThreads.count) groups scanned, \(busyGroups.count) busy, \(suggestions.count) new suggestions", path: logPath)
            if !suggestions.isEmpty {
                showNotification(title: "Alfred: \(suggestions.count) Group Suggestions", body: "Open Alfred to review busy groups for auto-summaries")
            }
        } catch {
            logToFile("❌ [Cadence] Group analysis failed: \(error)", path: logPath)
        }
    }

    private func runCadenceAutoSummaries(groups: [String], state: inout SchedulerState, todayDate: String, logPath: String, emailTo: String?) async {
        logToFile("📨 [Cadence] Running auto-summaries for \(groups.count) groups...", path: logPath)
        guard let alfredService = alfredService else {
            logToFile("⚠️ [Cadence] AlfredService not available", path: logPath)
            return
        }

        var successCount = 0
        for groupName in groups {
            do {
                let result = try await alfredService.getMessagesSummaryForContact(
                    contact: groupName,
                    platform: "whatsapp",
                    timeframe: "24h"
                )
                if !result.summary.isEmpty {
                    let config = AppConfig.load() ?? self.config
                    if let config = config {
                        let notifService = NotificationService(config: config.notifications)
                        var body = result.summary
                        if !result.keyPoints.isEmpty {
                            body += "\n\nKey Points:\n" + result.keyPoints.map { "• \($0)" }.joined(separator: "\n")
                        }
                        try await notifService.sendLearningDigest(
                            subject: "Alfred: \(groupName) Daily Summary",
                            body: body
                        )
                    }
                }
                successCount += 1
                logToFile("  ✓ Summary for \(groupName) (\(result.messageCount) messages)", path: logPath)
            } catch {
                logToFile("  ✗ Failed summary for \(groupName): \(error)", path: logPath)
            }
        }

        state.lastAutoSummaryDate = todayDate
        state.lastAutoSummaryTimestamp = ISO8601DateFormatter().string(from: Date())
        saveSchedulerState(state)
        logToFile("✅ [Cadence] Auto-summaries: \(successCount)/\(groups.count) sent", path: logPath)
    }

    private func runCadenceWeeklyReview(state: inout SchedulerState, todayDate: String, logPath: String, config: AppConfig, emailTo: String?) async {
        logToFile("📋 [Cadence] Running weekly review...", path: logPath)
        guard let alfredService = alfredService else {
            logToFile("⚠️ [Cadence] AlfredService not available for weekly review", path: logPath)
            return
        }

        do {
            // Generate a detailed weekly review (longer than card version)
            var contextParts: [String] = []
            var metrics: [String: Any] = [:]
            let calendar = Calendar.current
            let today = Date()

            if let orchestrator = orchestrator {
                let allTasks = try await orchestrator.notionServicePublic.queryActiveTasks()
                let completed = allTasks.filter { $0.status == .done }
                let open = allTasks.filter { $0.status != .done }
                let overdue = open.filter { $0.isOverdue }
                let fourteenDaysAgo = calendar.date(byAdding: .day, value: -14, to: today)!
                let stale = open.filter { $0.status == .notStarted && $0.createdDate < fourteenDaysAgo }

                metrics["tasksCompleted"] = completed.count
                metrics["tasksOpen"] = open.count
                metrics["tasksOverdue"] = overdue.count

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
            }

            // Commitment stats
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

            // Lifecycle stats
            let lifecycleStats = TaskLifecycleTracker.shared.getStats()
            let completionRate = Int(lifecycleStats.completionRate * 100)
            metrics["completionRate"] = completionRate
            contextParts.append("\nOVERALL: \(completionRate)% completion rate, \(Int(lifecycleStats.overdueRate * 100))% overdue rate")

            // Messaging velocity
            do {
                let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: today)!
                let reader = WhatsAppReader(dbPath: config.messaging.whatsapp.dbPath)
                try reader.connect()
                let threads = try reader.fetchThreads(since: sevenDaysAgo)
                let totalIn = threads.flatMap { $0.messages }.filter { $0.direction == .incoming }.count
                let totalOut = threads.flatMap { $0.messages }.filter { $0.direction == .outgoing }.count
                let ratio = totalOut > 0 ? String(format: "%.1f", Double(totalIn) / Double(totalOut)) : "∞"
                metrics["messagesInbound"] = totalIn
                metrics["messagesOutbound"] = totalOut
                contextParts.append("\nMESSAGING: \(totalIn) inbound, \(totalOut) outbound (ratio: \(ratio):1)")
                reader.disconnect()
            } catch { }

            // Recent coaching themes
            let sessions = CoachingMemoryService.shared.getRecentSessions(limit: 5)
            if !sessions.isEmpty {
                contextParts.append("\nRECENT COACHING THEMES:")
                for session in sessions {
                    let firstLine = session.components(separatedBy: "\n").first ?? session
                    contextParts.append("- \(String(firstLine.prefix(150)))")
                }
            }

            let claudeService = ClaudeAIService(config: config.ai)
            let prompt = """
            You are Coach Alfred writing a comprehensive weekly reflection email. This is a Sunday morning review — the founder's chance to step back and see the week clearly before planning the next one.

            Context:
            \(contextParts.joined(separator: "\n"))

            Write a weekly reflection covering these dimensions:

            ## WINS
            What was accomplished this week? Name specific completed tasks. Acknowledge real progress — even small wins matter.

            ## ACCOUNTABILITY
            What was supposed to happen but didn't? Name specific overdue tasks. Don't be harsh, but be honest. Frame as curiosity, not judgment.

            ## PATTERNS
            Based on the data, what patterns are emerging? Are they operating in their Zone of Genius or grinding? Which relationships need investment? What keeps getting avoided? Reference messaging velocity if relevant.

            ## THIS WEEK
            ONE clear priority for the coming week. Be specific — name the task, the person, or the decision. End with a motivating challenge.

            Style:
            - Write in second person ("You completed...", "Your overdue rate...")
            - Be direct and warm. Like a friend who remembers everything.
            - Each section: 2-3 sentences, with specific names and numbers
            - Total: ~300 words
            - No emojis. Use ## headers for sections. Plain prose.

            Respond with ONLY the review text.
            """

            let reviewText = try await claudeService.generateText(
                prompt: prompt,
                maxTokens: 500
            )

            // Format as HTML email
            let formattedBody = reviewText.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "## WINS", with: "<h3 style='color: #6b4c9a; margin-top: 20px; font-size: 14px; letter-spacing: 1px;'>WINS</h3>")
                .replacingOccurrences(of: "## ACCOUNTABILITY", with: "<h3 style='color: #6b4c9a; margin-top: 20px; font-size: 14px; letter-spacing: 1px;'>ACCOUNTABILITY</h3>")
                .replacingOccurrences(of: "## PATTERNS", with: "<h3 style='color: #6b4c9a; margin-top: 20px; font-size: 14px; letter-spacing: 1px;'>PATTERNS</h3>")
                .replacingOccurrences(of: "## THIS WEEK", with: "<h3 style='color: #6b4c9a; margin-top: 20px; font-size: 14px; letter-spacing: 1px;'>THIS WEEK</h3>")
                .replacingOccurrences(of: "\n\n", with: "</p><p style='line-height: 1.6; margin: 8px 0;'>")

            let htmlBody = """
            <html>
            <body style="font-family: -apple-system, system-ui, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px; color: #333; background: #fafafa;">
            <div style="background: white; padding: 24px; border-radius: 8px;">
            <h2 style="color: #2c3e50; font-family: Georgia, serif; font-weight: 400; margin-bottom: 4px;">Weekly Reflection</h2>
            <p style="color: #999; font-size: 12px; margin-top: 0;">\(todayDate) · from Alfred</p>
            <div style="font-size: 14px;">
            <p style='line-height: 1.6; margin: 8px 0;'>\(formattedBody)</p>
            </div>
            </div>
            <p style="font-size: 11px; color: #bbb; text-align: center; margin-top: 16px;">Open Alfred to see your full dashboard →</p>
            </body>
            </html>
            """

            let notifService = NotificationService(config: config.notifications)
            try await notifService.sendLearningDigest(
                subject: "Alfred: Weekly Reflection — \(todayDate)",
                body: htmlBody
            )
            logToFile("  ✓ Weekly reflection email sent", path: logPath)

            // Save to Notion Reflections database
            if let reflectionsDbId = config.notion.reflectionsDatabaseId, !reflectionsDbId.isEmpty {
                await saveReflectionToNotion(
                    dbId: reflectionsDbId,
                    apiKey: config.notion.apiKey,
                    narrative: reviewText.trimmingCharacters(in: .whitespacesAndNewlines),
                    metrics: metrics,
                    date: today,
                    logPath: logPath
                )
            }

            state.lastWeeklyReviewDate = todayDate
            state.lastWeeklyReviewTimestamp = ISO8601DateFormatter().string(from: Date())
            saveSchedulerState(state)
            logToFile("✅ [Cadence] Weekly reflection complete", path: logPath)
            showNotification(title: "Alfred: Weekly Reflection", body: "Your Sunday reflection has been emailed")
        } catch {
            logToFile("❌ [Cadence] Weekly review failed: \(error)", path: logPath)
        }
    }

    private func saveReflectionToNotion(dbId: String, apiKey: String, narrative: String, metrics: [String: Any], date: Date, logPath: String) async {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateStr = dateFormatter.string(from: date)

        let weekFormatter = DateFormatter()
        weekFormatter.dateFormat = "MMM d, yyyy"
        let weekLabel = "Week of \(weekFormatter.string(from: date))"

        let overdue = (metrics["tasksOverdue"] as? Int) ?? 0
        let completionRate = (metrics["completionRate"] as? Int) ?? 0
        let mood: String
        if completionRate >= 85 && overdue <= 3 { mood = "Strong" }
        else if completionRate >= 70 && overdue <= 6 { mood = "Steady" }
        else if overdue > 8 || completionRate < 50 { mood = "Overwhelmed" }
        else { mood = "Struggling" }

        let inbound = (metrics["messagesInbound"] as? Int) ?? 0
        let outbound = (metrics["messagesOutbound"] as? Int) ?? 0
        let ratioStr = outbound > 0 ? String(format: "%.1f:1", Double(inbound) / Double(outbound)) : "N/A"

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
                        "heading_2": ["rich_text": [["type": "text", "text": ["content": String(trimmed.dropFirst(3))]]]]
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
                        "paragraph": ["rich_text": [["type": "text", "text": ["content": trimmed]]]]
                    ]
                }
            }
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                logToFile("  ✓ Weekly reflection saved to Notion", path: logPath)
            } else {
                logToFile("  ⚠️ Notion save failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)", path: logPath)
            }
        } catch {
            logToFile("  ⚠️ Notion save error: \(error)", path: logPath)
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
