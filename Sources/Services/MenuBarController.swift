import Foundation
import AppKit
import UserNotifications

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

        // Create a hat icon using NSImage drawing
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            // Black hat
            NSColor.black.setFill()

            // Draw a simple bowler/top hat shape
            // Hat brim (wide part at bottom)
            let brimRect = NSRect(x: 1, y: 3, width: 16, height: 3)
            let brim = NSBezierPath(roundedRect: brimRect, xRadius: 1.5, yRadius: 1.5)
            brim.fill()

            // Hat crown (top part)
            let crownRect = NSRect(x: 4, y: 5, width: 10, height: 9)
            let crown = NSBezierPath(roundedRect: crownRect, xRadius: 2, yRadius: 2)
            crown.fill()

            // Golden sash/band
            let goldColor = running
                ? NSColor(red: 1.0, green: 0.84, blue: 0.0, alpha: 1.0)  // Bright gold when running
                : NSColor(red: 0.72, green: 0.53, blue: 0.04, alpha: 1.0)  // Darker gold when stopped
            goldColor.setFill()
            let bandRect = NSRect(x: 4, y: 6, width: 10, height: 2)
            NSBezierPath(rect: bandRect).fill()

            return true
        }

        image.isTemplate = false  // Use actual colors, not template
        button.image = image
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

    private func checkAndRunScheduledTasks() async {
        // Re-read config for hot-reload
        let config = AppConfig.load() ?? self.config
        guard let config = config else { return }

        let scheduled = config.scheduled
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let currentTime = formatter.string(from: now)

        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let logPath = "\(homeDir)/.alfred/scheduler.log"

        let emailTo = scheduled?.emailTo.isEmpty == false ? scheduled?.emailTo : nil

        // Morning Briefing
        let briefingEnabled = scheduled?.briefingEnabled ?? true
        if briefingEnabled && currentTime == config.app.briefingTime && lastBriefingRun != currentTime {
            lastBriefingRun = currentTime
            logToFile("Running morning briefing at \(currentTime)", path: logPath)

            if let orchestrator = orchestrator {
                do {
                    let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
                    _ = try await orchestrator.generateBriefing(for: tomorrow, sendNotifications: true, toAddress: emailTo)
                    logToFile("Morning briefing sent successfully", path: logPath)
                    showNotification(title: "Morning Briefing Sent", body: "Check your email for tomorrow's briefing")
                } catch {
                    logToFile("Error generating briefing: \(error)", path: logPath)
                }
            } else {
                logToFile("Orchestrator not available for briefing", path: logPath)
            }
        }

        // Attention Check
        let attentionEnabled = scheduled?.attentionEnabled ?? true
        if attentionEnabled && currentTime == config.app.attentionAlertTime && lastAttentionRun != currentTime {
            lastAttentionRun = currentTime
            logToFile("Running attention check at \(currentTime)", path: logPath)

            if let orchestrator = orchestrator {
                do {
                    _ = try await orchestrator.generateAttentionDefenseAlert(sendNotifications: true, toAddress: emailTo)
                    logToFile("Attention check sent successfully", path: logPath)
                    showNotification(title: "Attention Check Sent", body: "Check your email for the attention report")
                } catch {
                    logToFile("Error generating attention check: \(error)", path: logPath)
                }
            } else {
                logToFile("Orchestrator not available for attention check", path: logPath)
            }
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
