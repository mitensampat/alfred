import Foundation

class NotificationService {
    private let config: NotificationConfig

    init(config: NotificationConfig) {
        self.config = config
    }

    func sendBriefing(_ briefing: DailyBriefing, toAddress: String? = nil) async throws {
        print("  [DEBUG] sendBriefing called")
        let formatted = formatBriefing(briefing)
        print("  [DEBUG] Formatted briefing ready")

        if config.email.enabled {
            print("  → Sending email notification...")
            try await sendEmail(
                subject: "Coach Alfred: Daily Briefing - \(briefing.date.formatted(date: .abbreviated, time: .omitted))",
                body: formatted.html,
                toAddress: toAddress
            )
            print("  ✓ Email sent")
        }

        // Signal notification with smart body
        if let signal = config.signal, signal.enabled {
            let smartBody = buildSmartPushBody(for: briefing)
            sendSignalMessage("☕ \(smartBody)")
        }

    }

    /// Build a smart, data-driven push notification body from the briefing contents.
    /// Prioritises the most salient fact: back-to-backs > overdue tasks > light day.
    private func buildSmartPushBody(for briefing: DailyBriefing) -> String {
        let events = briefing.calendarBriefing.schedule.events.filter { !$0.isAllDay }
        let timedSorted = events.sorted { $0.startTime < $1.startTime }
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "h a"

        // Detect back-to-back chains (< 15 min gap)
        var backToBackCount = 0
        if timedSorted.count > 1 {
            for i in 1..<timedSorted.count {
                if timedSorted[i].startTime.timeIntervalSince(timedSorted[i-1].endTime) < 900 {
                    backToBackCount += 1
                }
            }
        }

        if backToBackCount > 1 {
            let first = timedSorted.first.map { timeFmt.string(from: $0.startTime) } ?? "morning"
            let last = timedSorted.last.map { timeFmt.string(from: $0.endTime) } ?? "afternoon"
            return "\(backToBackCount) back-to-backs from \(first)–\(last). Open Alfred."
        }

        // Check for overdue high-priority tasks
        let overdueHigh = briefing.actionItems.filter { item in
            guard let due = item.dueDate else { return false }
            return due < Date() && (item.priority == .critical || item.priority == .high)
        }
        if let topOverdue = overdueHigh.first {
            let daysLate: Int
            if let due = topOverdue.dueDate {
                daysLate = max(1, Calendar.current.dateComponents([.day], from: due, to: Date()).day ?? 1)
            } else {
                daysLate = 1
            }
            let truncated = String(topOverdue.title.prefix(35))
            return "\(truncated) is \(daysLate) day\(daysLate == 1 ? "" : "s") late. Open Alfred."
        }

        // Light day framing
        let meetingCount = events.count
        let focusHours = Int(briefing.calendarBriefing.focusTime / 3600)
        if meetingCount <= 3 && focusHours >= 3 {
            return "Light day — \(meetingCount) meeting\(meetingCount == 1 ? "" : "s"), \(focusHours)h open. Deep work window."
        }

        // Fallback
        return "\(meetingCount) meeting\(meetingCount == 1 ? "" : "s") today. Open Alfred."
    }

    func sendAttentionDefenseReport(_ report: AttentionDefenseReport, toAddress: String? = nil) async throws {
        let formatted = formatAttentionReport(report)
        let dateStr = report.currentTime.formatted(date: .abbreviated, time: .omitted)

        if config.email.enabled {
            try await sendEmail(
                subject: "Coach Alfred: Attention Defense - \(dateStr)",
                body: formatted.html,
                toAddress: toAddress
            )
        }

        // Signal attention alert
        if let signal = config.signal, signal.enabled {
            sendSignalMessage("🔴 \(report.mustDoToday.count) critical tasks before EOD. Open Alfred.")
        }

    }

    func sendAgentDigest(_ digest: AgentDigest) async throws {
        print("  [DEBUG] sendAgentDigest called")
        let formatted = formatAgentDigest(digest)
        print("  [DEBUG] Formatted digest ready")

        if config.email.enabled {
            print("  → Sending agent digest email...")
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "EEEE, MMM d"
            try await sendEmail(
                subject: "Coach Alfred: Agent Digest - \(dateFormatter.string(from: digest.date))",
                body: formatted.html
            )
            print("  ✓ Agent digest email sent")
        }

        // Signal agent digest nudge
        if let signal = config.signal, signal.enabled {
            sendSignalMessage("📊 \(digest.summary.totalDecisions) decisions, \(digest.newLearnings.count) new learnings today. Open Alfred.")
        }

    }

    func sendLearningDigest(subject: String, body: String) async throws {
        if config.email.enabled {
            print("  → Sending learning digest email...")
            try await sendEmail(subject: subject, body: body)
            print("  ✓ Learning digest email sent")
        }

        // Signal learning digest nudge
        if let signal = config.signal, signal.enabled {
            sendSignalMessage("🧠 Weekly learning digest ready. Check your email.")
        }
    }

    // MARK: - Email

    private func sendEmail(subject: String, body: String, toAddress: String? = nil) async throws {
        guard config.email.enabled else {
            print("Email disabled in config")
            return
        }

        let recipient = toAddress ?? config.email.smtpUsername

        // Use Python smtplib to send email
        let pythonScript = """
        import smtplib
        from email.mime.text import MIMEText
        from email.mime.multipart import MIMEMultipart

        msg = MIMEMultipart('alternative')
        msg['Subject'] = '\(subject.replacingOccurrences(of: "'", with: "\\'"))'
        msg['From'] = 'Coach Alfred <\(config.email.smtpUsername)>'
        msg['To'] = '\(recipient)'

        html_part = MIMEText('''
        \(body.replacingOccurrences(of: "'", with: "\\'"))
        ''', 'html')
        msg.attach(html_part)

        try:
            server = smtplib.SMTP('\(config.email.smtpHost)', \(config.email.smtpPort))
            server.starttls()
            server.login('\(config.email.smtpUsername)', '\(config.email.smtpPassword)')
            server.send_message(msg)
            server.quit()
            print('Email sent successfully')
        except Exception as e:
            print(f'Email failed: {e}')
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", pythonScript]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8) {
            print("Email output:", output)
        }

        if process.terminationStatus != 0 {
            throw NotificationError.sendFailed
        }
    }

    // MARK: - Signal Messaging

    /// Send a message to the user via signal-cli. Fire-and-forget — logs errors but doesn't throw.
    private func sendSignalMessage(_ message: String) {
        guard let signal = config.signal, signal.enabled else { return }

        let cliPath = signal.cliPath ?? "/opt/homebrew/bin/signal-cli"
        guard FileManager.default.fileExists(atPath: cliPath) else {
            print("  ⊗ signal-cli not found at \(cliPath)")
            return
        }

        let phone = signal.phoneNumber
        print("  → Sending Signal message to \(phone)...")

        // Run in background to avoid blocking the caller
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cliPath)
            process.arguments = ["-a", phone, "send", "-m", message, phone]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    print("  ✓ Signal message sent")
                } else {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    print("  ⊗ Signal send failed (exit \(process.terminationStatus)): \(output)")
                }
            } catch {
                print("  ⊗ Signal send error: \(error)")
            }
        }
    }

    // MARK: - Shared Email Design System (Ralph Lauren Navy)

    /// Single source of truth for all email styling.
    /// Matches the app's Ralph Lauren Navy palette from home.html :root variables.
    static let emailCSS = """
        body {
            font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif;
            line-height: 1.6;
            color: #1b2a4a;
            max-width: 700px;
            margin: 0 auto;
            padding: 20px;
            background: #f8f7f4;
        }
        .brand { font-family: 'Playfair Display', Georgia, 'Times New Roman', serif; }
        h1 { font-family: 'Playfair Display', Georgia, 'Times New Roman', serif; font-size: 28px; font-weight: 600; margin-bottom: 24px; color: #1b2a4a; }
        h2 { font-size: 14px; font-weight: 600; color: #5c6370; text-transform: uppercase; letter-spacing: 0.5px; margin-top: 28px; margin-bottom: 12px; border-bottom: 1px solid #e4e2dc; padding-bottom: 8px; }
        h3 { font-size: 15px; font-weight: 600; color: #1b2a4a; margin-top: 16px; margin-bottom: 8px; }
        p { margin: 12px 0; font-size: 14px; }
        hr { border: none; border-top: 1px solid #e4e2dc; margin: 24px 0; }
        strong { color: #1b2a4a; }
        .stat { display: inline-block; margin-right: 24px; margin-bottom: 8px; }
        .stat-label { color: #5c6370; font-size: 13px; }
        .stat-value { font-size: 18px; font-weight: 600; color: #1b2a4a; }
        .stat-grid { display: flex; flex-wrap: wrap; gap: 16px; margin-bottom: 16px; }
        .stat-grid .stat { flex: 1; min-width: 100px; background: #f0eeea; border-radius: 6px; padding: 12px; text-align: center; margin-right: 0; }
        .stat-grid .stat-value { font-size: 24px; }
        .stat-grid .stat-label { font-size: 12px; margin-top: 4px; }
        .item { background: #f0eeea; border-radius: 6px; padding: 12px 16px; margin-bottom: 10px; }
        .item-title { font-weight: 600; color: #1b2a4a; margin-bottom: 4px; }
        .item-meta { font-size: 13px; color: #5c6370; }
        .item-desc { font-size: 14px; color: #1b2a4a; margin-top: 6px; }
        .priority-critical { border-left: 3px solid #8b2332; background: #f4e4e6; }
        .priority-high { border-left: 3px solid #8b2332; }
        .priority-medium { border-left: 3px solid #c49a3c; }
        .priority-low { border-left: 3px solid #2d5a3d; }
        .coaching-leverage { border-left: 3px solid #3d6888; background: #e4eef4; }
        .coaching-relationship { border-left: 3px solid #2d5a3d; background: #e4efe7; }
        .coaching-avoidance { border-left: 3px solid #c49a3c; background: #faf1dd; }
        .coaching-attention { border-left: 3px solid #c49a3c; background: #faf1dd; }
        .coaching-weekly { border-left: 3px solid #6b4c3b; background: #f4ece3; }
        .coaching-skill { border-left: 3px solid #3d6888; background: #e4eef4; }
        .coaching-label { font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.5px; margin-bottom: 4px; }
        .coaching-leverage .coaching-label { color: #3d6888; }
        .coaching-relationship .coaching-label { color: #2d5a3d; }
        .coaching-avoidance .coaching-label { color: #c49a3c; }
        .coaching-attention .coaching-label { color: #c49a3c; }
        .coaching-weekly .coaching-label { color: #6b4c3b; }
        .coaching-skill .coaching-label { color: #3d6888; }
        .event { padding: 10px 14px; border-left: 3px solid #3d6888; background: #e4eef4; border-radius: 4px; margin-bottom: 8px; }
        .event-time { font-size: 13px; color: #3d6888; font-weight: 500; }
        .event-title { font-weight: 600; color: #1b2a4a; }
        .event-location { font-size: 13px; color: #5c6370; margin-top: 2px; }
        .tag { display: inline-block; font-size: 11px; padding: 2px 8px; border-radius: 4px; margin-right: 6px; }
        .tag-external { background: #faf1dd; color: #92400e; }
        .can-push { border-left: 3px solid #2d5a3d; background: #e4efe7; }
        .overdue { border-left: 3px solid #8b2332; }
        .recommendation { padding: 8px 12px; background: #e4eef4; border-radius: 4px; margin-bottom: 6px; color: #3d6888; font-size: 14px; }
        .agent-card { background: #f0eeea; border-radius: 8px; padding: 14px; margin-bottom: 10px; }
        .agent-name { font-weight: 600; color: #1b2a4a; margin-bottom: 8px; }
        .agent-stats { display: flex; gap: 16px; font-size: 13px; color: #5c6370; }
        .agent-insight { font-size: 14px; color: #1b2a4a; margin-top: 8px; padding: 8px; background: #ffffff; border-radius: 4px; }
        .footer { margin-top: 32px; padding-top: 16px; border-top: 1px solid #e4e2dc; font-size: 12px; color: #8890a0; text-align: center; }
        .footer .brand { font-size: 14px; font-weight: 500; color: #1b2a4a; }
    """

    /// Standard HTML email preamble using the shared design system
    static func emailHead() -> String {
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=Playfair+Display:wght@400;500;600;700&display=swap" rel="stylesheet">
            <style>
                \(emailCSS)
            </style>
        </head>
        <body>
        """
    }

    /// Standard HTML email footer
    static func emailFoot() -> String {
        return """
            <div class="footer">
                Generated by <span class="brand">alfred</span> v\(AlfredApp.version) • \(Date().formatted(date: .abbreviated, time: .shortened))
            </div>
        </body>
        </html>
        """
    }

    // MARK: - Formatting

    private func formatBriefing(_ briefing: DailyBriefing) -> (markdown: String, html: String) {
        // Build both markdown and HTML simultaneously for consistency
        // Layout order: Coach Says → Calendar → Messages → Action Items
        var markdown = "# Daily Briefing - \(briefing.date.formatted(date: .long, time: .omitted))\n\n"

        // HTML using shared Ralph Lauren Navy design system
        var html = Self.emailHead()
        html += "<h1>📅 Daily Briefing for \(briefing.date.formatted(date: .long, time: .omitted))</h1>"

        // ── Section 1: Coach Says ──────────────────────────────────────
        if let cards = briefing.coachingCards, !cards.isEmpty {
            markdown += "## Your Coach Says\n\n"
            html += "<h2>🧭 Your Coach Says</h2>"

            for card in cards {
                let emoji: String
                let cssClass: String
                let cardType = card.type.lowercased()
                if cardType.contains("leverage") {
                    emoji = "🎯"
                    cssClass = "coaching-leverage"
                } else if cardType.contains("relationship") {
                    emoji = "👤"
                    cssClass = "coaching-relationship"
                } else if cardType.contains("avoidance") {
                    emoji = "🪞"
                    cssClass = "coaching-avoidance"
                } else if cardType.contains("attention") {
                    emoji = "📡"
                    cssClass = "coaching-attention"
                } else if cardType.contains("weekly") {
                    emoji = "📋"
                    cssClass = "coaching-weekly"
                } else {
                    emoji = "💡"
                    cssClass = "coaching-skill"
                }

                markdown += "**\(emoji) \(card.label):** \(card.insight)\n\n"

                html += """
                    <div class="item \(cssClass)" style="border-radius: 6px;">
                        <div class="coaching-label">\(emoji) \(card.label)</div>
                        <div class="item-desc">\(card.insight)</div>
                    </div>
                """
            }
        }

        // ── Section 2: Calendar ────────────────────────────────────────
        let meetingHours = Int(briefing.calendarBriefing.schedule.totalMeetingTime / 3600)
        let meetingMins = Int((briefing.calendarBriefing.schedule.totalMeetingTime.truncatingRemainder(dividingBy: 3600)) / 60)
        let focusHours = Int(briefing.calendarBriefing.focusTime / 3600)
        let focusMins = Int((briefing.calendarBriefing.focusTime.truncatingRemainder(dividingBy: 3600)) / 60)

        markdown += "## Today's Schedule\n"
        markdown += "- Total Meeting Time: \(meetingHours)h \(meetingMins)m\n"
        markdown += "- Focus Time: \(focusHours)h \(focusMins)m\n"
        markdown += "- External Meetings: \(briefing.calendarBriefing.schedule.externalMeetings.count)\n\n"

        html += """
            <h2>📅 Today's Schedule</h2>
            <div style="margin-bottom: 16px;">
                <span class="stat"><span class="stat-value">\(meetingHours)h \(meetingMins)m</span><br><span class="stat-label">Meeting Time</span></span>
                <span class="stat"><span class="stat-value">\(focusHours)h \(focusMins)m</span><br><span class="stat-label">Focus Time</span></span>
                <span class="stat"><span class="stat-value">\(briefing.calendarBriefing.schedule.externalMeetings.count)</span><br><span class="stat-label">External Meetings</span></span>
            </div>
        """

        // Events
        if !briefing.calendarBriefing.schedule.events.isEmpty {
            markdown += "### Events\n"
            html += "<h3>Events</h3>"

            for event in briefing.calendarBriefing.schedule.events {
                let startTime = event.startTime.formatted(date: .omitted, time: .shortened)
                let endTime = event.endTime.formatted(date: .omitted, time: .shortened)
                markdown += "- \(startTime) - \(endTime): \(event.title)\n"
                if let location = event.location, !location.isEmpty {
                    markdown += "  Location: \(location)\n"
                }

                var locationHtml = ""
                if let location = event.location, !location.isEmpty {
                    locationHtml = "<div class=\"event-location\">📍 \(location)</div>"
                }
                var externalTag = ""
                if event.hasExternalAttendees {
                    externalTag = "<span class=\"tag tag-external\">👥 External</span>"
                }

                html += """
                    <div class="event">
                        <div class="event-time">\(startTime) - \(endTime) \(externalTag)</div>
                        <div class="event-title">\(event.title)</div>
                        \(locationHtml)
                    </div>
                """
            }
            markdown += "\n"
        }

        // ── Section 3: Messages ────────────────────────────────────────
        markdown += "## Messages Summary\n"
        markdown += "- Total Messages: \(briefing.messagingSummary.stats.totalMessages)\n"
        markdown += "- Unread: \(briefing.messagingSummary.stats.unreadMessages)\n"
        markdown += "- Need Response: \(briefing.messagingSummary.stats.threadsNeedingResponse)\n\n"

        html += """
            <h2>💬 Messages Summary</h2>
            <div style="margin-bottom: 16px;">
                <span class="stat"><span class="stat-value">\(briefing.messagingSummary.stats.totalMessages)</span><br><span class="stat-label">Total Messages</span></span>
                <span class="stat"><span class="stat-value">\(briefing.messagingSummary.stats.unreadMessages)</span><br><span class="stat-label">Unread</span></span>
                <span class="stat"><span class="stat-value">\(briefing.messagingSummary.stats.threadsNeedingResponse)</span><br><span class="stat-label">Need Response</span></span>
            </div>
        """

        // Critical Messages
        if !briefing.messagingSummary.criticalMessages.isEmpty {
            markdown += "### Critical Messages\n"
            html += "<h3>🔴 Critical Messages</h3>"

            for summary in briefing.messagingSummary.criticalMessages.prefix(5) {
                let contactName = summary.thread.contactName ?? "Unknown"
                let platform = summary.thread.platform.rawValue
                markdown += "- \(contactName) (\(platform)): \(summary.summary)\n"

                html += """
                    <div class="item priority-critical">
                        <div class="item-title">\(contactName) <span class="item-meta">(\(platform))</span></div>
                        <div class="item-desc">\(summary.summary)</div>
                    </div>
                """
            }
            markdown += "\n"
        }

        // ── Section 4: Action Items ────────────────────────────────────
        if !briefing.actionItems.isEmpty {
            markdown += "## Action Items (\(briefing.actionItems.count))\n"
            html += "<h2>✅ Action Items (\(briefing.actionItems.count))</h2>"

            for item in briefing.actionItems.prefix(10) {
                let dueStr = item.dueDate?.formatted(date: .abbreviated, time: .shortened) ?? "No deadline"
                let priorityClass = item.priority == .critical ? "priority-critical" : item.priority == .high ? "priority-high" : item.priority == .medium ? "priority-medium" : "priority-low"
                let priorityEmoji = item.priority == .critical ? "🔴" : item.priority == .high ? "🟠" : item.priority == .medium ? "🟡" : "🟢"

                markdown += "- [\(item.priority.rawValue)] \(item.title): \(item.description)\n"

                html += """
                    <div class="item \(priorityClass)">
                        <div class="item-title">\(priorityEmoji) \(item.title)</div>
                        <div class="item-desc">\(item.description)</div>
                        <div class="item-meta">Due: \(dueStr)</div>
                    </div>
                """
            }
        }

        // Footer
        html += Self.emailFoot()

        return (markdown, html)
    }

    private func formatAttentionReport(_ report: AttentionDefenseReport) -> (markdown: String, html: String) {
        var markdown = "# Attention Defense Report - \(report.currentTime.formatted(date: .omitted, time: .shortened))\n\n"

        var html = Self.emailHead()
        html += """
            <h1>⚡ Attention Defense Report</h1>
            <p style="color: #5c6370; margin-top: -16px; margin-bottom: 24px;">Generated at \(report.currentTime.formatted(date: .omitted, time: .shortened))</p>
        """

        // Must Do Today
        markdown += "## Must Complete Before EOD (\(report.mustDoToday.count))\n"
        html += "<h2>🔴 Must Complete Before EOD (\(report.mustDoToday.count))</h2>"

        for item in report.mustDoToday {
            let estTime = item.estimatedDuration.map { "\(Int($0/60))min" } ?? "unknown"
            markdown += "- \(item.title): \(item.description) (Priority: \(item.priority.rawValue), Est: \(estTime))\n"

            let priorityClass = item.priority == .high ? "priority-high" : "priority-medium"
            html += """
                <div class="item \(priorityClass)">
                    <div class="item-title">\(item.title)</div>
                    <div class="item-desc">\(item.description)</div>
                    <div class="item-meta">Priority: \(item.priority.rawValue) • Est: \(estTime)</div>
                </div>
            """
        }
        markdown += "\n"

        // Can Push
        markdown += "## Can Push to Tomorrow (\(report.canPushOff.count))\n"
        html += "<h2>🟢 Can Push to Tomorrow (\(report.canPushOff.count))</h2>"

        for suggestion in report.canPushOff {
            markdown += "- \(suggestion.item.title): \(suggestion.reason) (Impact: \(suggestion.impact.rawValue))\n"

            html += """
                <div class="item can-push">
                    <div class="item-title">\(suggestion.item.title)</div>
                    <div class="item-desc">\(suggestion.reason)</div>
                    <div class="item-meta">Impact if delayed: \(suggestion.impact.rawValue)</div>
                </div>
            """
        }
        markdown += "\n"

        // Recommendations
        markdown += "## Recommendations\n"
        html += "<h2>💡 Recommendations</h2>"

        for rec in report.recommendations {
            markdown += "- \(rec)\n"
            html += "<div class=\"recommendation\">\(rec)</div>"
        }

        html += Self.emailFoot()

        return (markdown, html)
    }

    private func formatAgentDigest(_ digest: AgentDigest) -> (markdown: String, html: String) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEEE, MMMM d, yyyy"

        var markdown = "# Alfred Agent Digest - \(dateFormatter.string(from: digest.date))\n\n"

        var html = Self.emailHead()
        html += """
            <h1>🤖 <span class="brand">alfred</span> Agent Digest</h1>
            <p style="color: #5c6370; margin-top: -16px; margin-bottom: 24px;">\(dateFormatter.string(from: digest.date))</p>
        """

        // Summary Stats
        markdown += "## Summary\n"
        markdown += "- Total Decisions: \(digest.summary.totalDecisions)\n"
        markdown += "- Executed: \(digest.summary.decisionsExecuted)\n"
        markdown += "- Pending Review: \(digest.summary.decisionsPending)\n"
        markdown += "- New Learnings: \(digest.summary.newLearningsCount)\n\n"

        html += """
            <h2>📊 Summary</h2>
            <div class="stat-grid">
                <div class="stat"><div class="stat-value">\(digest.summary.totalDecisions)</div><div class="stat-label">Decisions</div></div>
                <div class="stat"><div class="stat-value">\(digest.summary.decisionsExecuted)</div><div class="stat-label">Executed</div></div>
                <div class="stat"><div class="stat-value">\(digest.summary.decisionsPending)</div><div class="stat-label">Pending</div></div>
                <div class="stat"><div class="stat-value">\(digest.summary.newLearningsCount)</div><div class="stat-label">Learnings</div></div>
            </div>
        """

        // Agent Activity
        markdown += "## Agent Activity\n"
        html += "<h2>🧠 Agent Activity</h2>"

        for activity in digest.agentActivity {
            let successPct = Int(activity.successRate * 100)
            markdown += "### \(activity.agentType.displayName) Agent\n"
            markdown += "- Decisions: \(activity.decisionsCount), Success Rate: \(successPct)%\n"

            var insightHtml = ""
            if let insight = activity.keyInsight {
                insightHtml = "<div class=\"agent-insight\">💡 \(insight)</div>"
            }

            html += """
                <div class="agent-card">
                    <div class="agent-name">\(activity.agentType.displayName) Agent</div>
                    <div class="agent-stats">
                        <span>\(activity.decisionsCount) decisions</span>
                        <span>\(successPct)% success</span>
                    </div>
                    \(insightHtml)
                </div>
            """
        }
        markdown += "\n"

        // Commitment Status
        markdown += "## Commitment Status\n"
        markdown += "- I Owe (Active): \(digest.commitmentStatus.activeIOwe)\n"
        markdown += "- They Owe Me: \(digest.commitmentStatus.activeTheyOwe)\n"
        markdown += "- Overdue: \(digest.commitmentStatus.overdueCount)\n\n"

        html += """
            <h2>✅ Commitment Status</h2>
            <div class="stat-grid">
                <div class="stat"><div class="stat-value">\(digest.commitmentStatus.activeIOwe)</div><div class="stat-label">I Owe</div></div>
                <div class="stat"><div class="stat-value">\(digest.commitmentStatus.activeTheyOwe)</div><div class="stat-label">They Owe Me</div></div>
                <div class="stat"><div class="stat-value">\(digest.commitmentStatus.overdueCount)</div><div class="stat-label">Overdue</div></div>
                <div class="stat"><div class="stat-value">\(digest.commitmentStatus.upcomingThisWeek)</div><div class="stat-label">Due This Week</div></div>
            </div>
        """

        // Upcoming Follow-ups
        if !digest.upcomingFollowups.isEmpty {
            let timeFormatter = DateFormatter()
            timeFormatter.dateStyle = .short
            timeFormatter.timeStyle = .short

            markdown += "## Upcoming Follow-ups (\(digest.upcomingFollowups.count))\n"
            html += "<h2>📌 Upcoming Follow-ups (\(digest.upcomingFollowups.count))</h2>"

            for followup in digest.upcomingFollowups.prefix(5) {
                let overdueTag = followup.isOverdue ? " ⚠️ OVERDUE" : ""
                let overdueClass = followup.isOverdue ? "overdue" : ""
                markdown += "- \(followup.title)\(overdueTag) (Due: \(timeFormatter.string(from: followup.scheduledFor)))\n"

                html += """
                    <div class="item \(overdueClass)">
                        <div class="item-title">\(followup.title)\(overdueTag)</div>
                        <div class="item-meta">Due: \(timeFormatter.string(from: followup.scheduledFor))</div>
                    </div>
                """
            }
            markdown += "\n"
        }

        // Recommendations
        if !digest.recommendations.isEmpty {
            markdown += "## Recommendations\n"
            html += "<h2>💡 Recommendations</h2>"

            for rec in digest.recommendations {
                markdown += "- \(rec)\n"
                html += "<div class=\"recommendation\">\(rec)</div>"
            }
        }

        html += Self.emailFoot()

        return (markdown, html)
    }
}

enum NotificationError: Error, LocalizedError {
    case invalidConfiguration
    case sendFailed

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "Invalid notification configuration"
        case .sendFailed:
            return "Failed to send notification"
        }
    }
}
