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

    // MARK: - Shared Email Design System (Inline Styles — Email-Safe)
    //
    // Design tokens from home.html "The Walk" design system:
    //   Canvas:    #f8f7f4   Surface:  #ffffff   Sunken: #f0eeea
    //   Ink:       #1b2a4a   Ink-2:    #5c6370   Ink-3:  #8890a0
    //   Line:      #e4e2dc   Coach:    #1b2a4a   Growth: #2d5a3d
    //   Warning:   #c49a3c   Danger:   #8b2332   Info:   #3d6888
    //   Method:    #6b4c3b
    //   Display:   Playfair Display, Georgia, serif
    //   Body:      Inter, -apple-system, sans-serif

    // Shared inline style constants
    private static let fontBody = "font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif;"
    private static let fontDisplay = "font-family: 'Playfair Display', Georgia, 'Times New Roman', serif;"

    /// Wraps email content in a table-based layout matching home.html:
    /// cream canvas background → centered white card → content → footer
    static func emailHead() -> String {
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=Playfair+Display:wght@400;500;600;700&display=swap" rel="stylesheet">
        </head>
        <body style="margin: 0; padding: 0; background-color: #f8f7f4; \(fontBody) color: #1b2a4a;">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background-color: #f8f7f4;">
        <tr><td align="center" style="padding: 24px 16px;">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width: 600px;">
        <!-- Brand header -->
        <tr><td style="padding: 0 0 20px; text-align: left;">
            <span style="\(fontDisplay) font-size: 16px; font-weight: 400; color: #1b2a4a; letter-spacing: 0.02em;">alfred</span>
        </td></tr>
        <!-- Main content card -->
        <tr><td style="background-color: #ffffff; border-radius: 8px; border: 1px solid #e4e2dc; padding: 32px 28px;">
        """
    }

    /// Closes the white card, adds footer, closes tables
    static func emailFoot() -> String {
        return """
        </td></tr>
        <!-- Footer -->
        <tr><td style="padding: 20px 0 0; text-align: center;">
            <span style="\(fontBody) font-size: 11px; color: #8890a0;">Generated by <span style="\(fontDisplay) font-size: 12px; font-weight: 500; color: #5c6370;">alfred</span> v\(AlfredApp.version) · \(Date().formatted(date: .abbreviated, time: .shortened))</span>
        </td></tr>
        </table>
        </td></tr>
        </table>
        </body>
        </html>
        """
    }

    // MARK: - Inline Style Helpers

    /// Section header — matches home.html's time-marker style
    private static func sectionHeader(_ text: String) -> String {
        return """
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin-top: 28px; margin-bottom: 14px;">
        <tr>
            <td style="\(fontBody) font-size: 11px; font-weight: 600; color: #5c6370; text-transform: uppercase; letter-spacing: 0.06em; white-space: nowrap; padding-right: 12px;">\(text)</td>
            <td style="width: 100%;"><div style="height: 1px; background-color: #e4e2dc;"></div></td>
        </tr>
        </table>
        """
    }

    /// Stat pill — used for metrics (meetings, focus time, etc.)
    private static func statRow(_ stats: [(value: String, label: String)]) -> String {
        var cells = ""
        for stat in stats {
            cells += """
            <td style="background-color: #f0eeea; border-radius: 6px; padding: 12px 8px; text-align: center; width: \(100 / max(stats.count, 1))%;">
                <div style="\(fontBody) font-size: 20px; font-weight: 600; color: #1b2a4a;">\(stat.value)</div>
                <div style="\(fontBody) font-size: 11px; color: #5c6370; margin-top: 2px;">\(stat.label)</div>
            </td>
            """
        }
        return """
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin-bottom: 16px; border-spacing: 8px; border-collapse: separate;">
        <tr>\(cells)</tr>
        </table>
        """
    }

    /// Coaching card — white card with colored dot, matching home.html .coaching-card
    private static func coachingCard(emoji: String, label: String, insight: String, dotColor: String) -> String {
        return """
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin-bottom: 8px;">
        <tr><td style="background-color: #f8f7f4; border-radius: 6px; border: 1px solid #e4e2dc; padding: 14px 16px;">
            <table role="presentation" cellpadding="0" cellspacing="0"><tr>
                <td style="width: 8px; vertical-align: top; padding-top: 2px;"><div style="width: 7px; height: 7px; border-radius: 50%; background-color: \(dotColor);"></div></td>
                <td style="padding-left: 8px;">
                    <div style="\(fontBody) font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.04em; color: #5c6370; margin-bottom: 4px;">\(emoji) \(label)</div>
                    <div style="\(fontBody) font-size: 14px; line-height: 1.65; color: #1b2a4a;">\(insight)</div>
                </td>
            </tr></table>
        </td></tr>
        </table>
        """
    }

    /// Event card — clean timeline item
    private static func eventCard(time: String, title: String, location: String?, isExternal: Bool) -> String {
        var locationHtml = ""
        if let loc = location, !loc.isEmpty {
            locationHtml = "<div style=\"\(fontBody) font-size: 12px; color: #5c6370; margin-top: 3px;\">📍 \(loc)</div>"
        }
        let externalTag = isExternal ? " <span style=\"\(fontBody) display: inline-block; font-size: 10px; padding: 1px 6px; border-radius: 3px; background-color: #faf1dd; color: #92400e;\">External</span>" : ""

        return """
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin-bottom: 6px;">
        <tr><td style="background-color: #f8f7f4; border-radius: 6px; border-left: 3px solid #3d6888; padding: 10px 14px;">
            <div style="\(fontBody) font-size: 12px; color: #3d6888; font-weight: 500;">\(time)\(externalTag)</div>
            <div style="\(fontBody) font-size: 14px; font-weight: 600; color: #1b2a4a; margin-top: 2px;">\(title)</div>
            \(locationHtml)
        </td></tr>
        </table>
        """
    }

    /// Action/task item card with priority indicator
    private static func itemCard(title: String, description: String, meta: String, accentColor: String, emoji: String) -> String {
        return """
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin-bottom: 8px;">
        <tr><td style="background-color: #f8f7f4; border-radius: 6px; border-left: 3px solid \(accentColor); padding: 12px 16px;">
            <div style="\(fontBody) font-size: 14px; font-weight: 600; color: #1b2a4a;">\(emoji) \(title)</div>
            <div style="\(fontBody) font-size: 13px; line-height: 1.55; color: #1b2a4a; margin-top: 4px;">\(description)</div>
            <div style="\(fontBody) font-size: 12px; color: #8890a0; margin-top: 6px;">\(meta)</div>
        </td></tr>
        </table>
        """
    }

    /// Simple card (no accent border)
    private static func simpleCard(content: String) -> String {
        return """
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin-bottom: 6px;">
        <tr><td style="background-color: #f0eeea; border-radius: 6px; padding: 10px 14px;">
            <div style="\(fontBody) font-size: 13px; line-height: 1.55; color: #1b2a4a;">\(content)</div>
        </td></tr>
        </table>
        """
    }

    /// Recommendation card
    private static func recCard(_ text: String) -> String {
        return """
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin-bottom: 6px;">
        <tr><td style="background-color: #e4eef4; border-radius: 6px; padding: 10px 14px;">
            <div style="\(fontBody) font-size: 13px; line-height: 1.5; color: #3d6888;">\(text)</div>
        </td></tr>
        </table>
        """
    }

    // MARK: - Formatting

    private func formatBriefing(_ briefing: DailyBriefing) -> (markdown: String, html: String) {
        var markdown = "# Daily Briefing - \(briefing.date.formatted(date: .long, time: .omitted))\n\n"

        var html = Self.emailHead()

        // Title
        html += "<div style=\"\(Self.fontDisplay) font-size: 22px; font-weight: 400; color: #1b2a4a; margin-bottom: 4px;\">Daily Briefing</div>"
        html += "<div style=\"\(Self.fontBody) font-size: 12px; color: #8890a0; margin-bottom: 8px;\">\(briefing.date.formatted(date: .long, time: .omitted))</div>"

        // ── Section 1: Coach Says ──
        if let cards = briefing.coachingCards, !cards.isEmpty {
            markdown += "## Your Coach Says\n\n"
            html += Self.sectionHeader("Your Coach Says")

            for card in cards {
                let emoji: String
                let dotColor: String
                let cardType = card.type.lowercased()
                if cardType.contains("leverage") {
                    emoji = "🎯"; dotColor = "#1b2a4a"
                } else if cardType.contains("relationship") {
                    emoji = "👤"; dotColor = "#2d5a3d"
                } else if cardType.contains("avoidance") {
                    emoji = "🪞"; dotColor = "#c49a3c"
                } else if cardType.contains("attention") {
                    emoji = "📡"; dotColor = "#c49a3c"
                } else if cardType.contains("weekly") {
                    emoji = "📋"; dotColor = "#6b4c3b"
                } else {
                    emoji = "💡"; dotColor = "#3d6888"
                }

                markdown += "**\(emoji) \(card.label):** \(card.insight)\n\n"
                html += Self.coachingCard(emoji: emoji, label: card.label, insight: card.insight, dotColor: dotColor)
            }
        }

        // ── Section 2: Calendar ──
        let meetingHours = Int(briefing.calendarBriefing.schedule.totalMeetingTime / 3600)
        let meetingMins = Int((briefing.calendarBriefing.schedule.totalMeetingTime.truncatingRemainder(dividingBy: 3600)) / 60)
        let focusHours = Int(briefing.calendarBriefing.focusTime / 3600)
        let focusMins = Int((briefing.calendarBriefing.focusTime.truncatingRemainder(dividingBy: 3600)) / 60)

        markdown += "## Today's Schedule\n"
        markdown += "- Total Meeting Time: \(meetingHours)h \(meetingMins)m\n"
        markdown += "- Focus Time: \(focusHours)h \(focusMins)m\n"
        markdown += "- External Meetings: \(briefing.calendarBriefing.schedule.externalMeetings.count)\n\n"

        html += Self.sectionHeader("Today's Schedule")
        html += Self.statRow([
            (value: "\(meetingHours)h \(meetingMins)m", label: "Meeting Time"),
            (value: "\(focusHours)h \(focusMins)m", label: "Focus Time"),
            (value: "\(briefing.calendarBriefing.schedule.externalMeetings.count)", label: "External")
        ])

        // Events
        if !briefing.calendarBriefing.schedule.events.isEmpty {
            markdown += "### Events\n"

            for event in briefing.calendarBriefing.schedule.events {
                let startTime = event.startTime.formatted(date: .omitted, time: .shortened)
                let endTime = event.endTime.formatted(date: .omitted, time: .shortened)
                markdown += "- \(startTime) - \(endTime): \(event.title)\n"
                if let location = event.location, !location.isEmpty {
                    markdown += "  Location: \(location)\n"
                }

                html += Self.eventCard(
                    time: "\(startTime) – \(endTime)",
                    title: event.title,
                    location: event.location,
                    isExternal: event.hasExternalAttendees
                )
            }
            markdown += "\n"
        }

        // ── Section 3: Messages ──
        markdown += "## Messages Summary\n"
        markdown += "- Total Messages: \(briefing.messagingSummary.stats.totalMessages)\n"
        markdown += "- Unread: \(briefing.messagingSummary.stats.unreadMessages)\n"
        markdown += "- Need Response: \(briefing.messagingSummary.stats.threadsNeedingResponse)\n\n"

        html += Self.sectionHeader("Messages")
        html += Self.statRow([
            (value: "\(briefing.messagingSummary.stats.totalMessages)", label: "Total"),
            (value: "\(briefing.messagingSummary.stats.unreadMessages)", label: "Unread"),
            (value: "\(briefing.messagingSummary.stats.threadsNeedingResponse)", label: "Need Response")
        ])

        // Critical Messages
        if !briefing.messagingSummary.criticalMessages.isEmpty {
            markdown += "### Critical Messages\n"

            for summary in briefing.messagingSummary.criticalMessages.prefix(5) {
                let contactName = summary.thread.contactName ?? "Unknown"
                let platform = summary.thread.platform.rawValue
                markdown += "- \(contactName) (\(platform)): \(summary.summary)\n"

                html += Self.itemCard(
                    title: contactName,
                    description: summary.summary,
                    meta: platform,
                    accentColor: "#8b2332",
                    emoji: "🔴"
                )
            }
            markdown += "\n"
        }

        // ── Section 4: Action Items ──
        if !briefing.actionItems.isEmpty {
            markdown += "## Action Items (\(briefing.actionItems.count))\n"
            html += Self.sectionHeader("Action Items · \(briefing.actionItems.count)")

            for item in briefing.actionItems.prefix(10) {
                let dueStr = item.dueDate?.formatted(date: .abbreviated, time: .shortened) ?? "No deadline"
                let accentColor: String
                let priorityEmoji: String
                switch item.priority {
                case .critical:
                    accentColor = "#8b2332"; priorityEmoji = "🔴"
                case .high:
                    accentColor = "#8b2332"; priorityEmoji = "🟠"
                case .medium:
                    accentColor = "#c49a3c"; priorityEmoji = "🟡"
                default:
                    accentColor = "#2d5a3d"; priorityEmoji = "🟢"
                }

                markdown += "- [\(item.priority.rawValue)] \(item.title): \(item.description)\n"

                html += Self.itemCard(
                    title: item.title,
                    description: item.description,
                    meta: "Due: \(dueStr)",
                    accentColor: accentColor,
                    emoji: priorityEmoji
                )
            }
        }

        html += Self.emailFoot()
        return (markdown, html)
    }

    private func formatAttentionReport(_ report: AttentionDefenseReport) -> (markdown: String, html: String) {
        var markdown = "# Attention Defense Report - \(report.currentTime.formatted(date: .omitted, time: .shortened))\n\n"

        var html = Self.emailHead()
        html += "<div style=\"\(Self.fontDisplay) font-size: 22px; font-weight: 400; color: #1b2a4a; margin-bottom: 4px;\">Attention Defense</div>"
        html += "<div style=\"\(Self.fontBody) font-size: 12px; color: #8890a0; margin-bottom: 8px;\">Generated at \(report.currentTime.formatted(date: .omitted, time: .shortened))</div>"

        // Must Do Today
        markdown += "## Must Complete Before EOD (\(report.mustDoToday.count))\n"
        html += Self.sectionHeader("Must Complete Before EOD · \(report.mustDoToday.count)")

        for item in report.mustDoToday {
            let estTime = item.estimatedDuration.map { "\(Int($0/60))min" } ?? "unknown"
            markdown += "- \(item.title): \(item.description) (Priority: \(item.priority.rawValue), Est: \(estTime))\n"

            let accentColor = item.priority == .high ? "#8b2332" : "#c49a3c"
            html += Self.itemCard(
                title: item.title,
                description: item.description,
                meta: "Priority: \(item.priority.rawValue) · Est: \(estTime)",
                accentColor: accentColor,
                emoji: "⚡"
            )
        }
        markdown += "\n"

        // Can Push
        markdown += "## Can Push to Tomorrow (\(report.canPushOff.count))\n"
        html += Self.sectionHeader("Can Push to Tomorrow · \(report.canPushOff.count)")

        for suggestion in report.canPushOff {
            markdown += "- \(suggestion.item.title): \(suggestion.reason) (Impact: \(suggestion.impact.rawValue))\n"

            html += Self.itemCard(
                title: suggestion.item.title,
                description: suggestion.reason,
                meta: "Impact if delayed: \(suggestion.impact.rawValue)",
                accentColor: "#2d5a3d",
                emoji: "↗️"
            )
        }
        markdown += "\n"

        // Recommendations
        markdown += "## Recommendations\n"
        html += Self.sectionHeader("Recommendations")

        for rec in report.recommendations {
            markdown += "- \(rec)\n"
            html += Self.recCard(rec)
        }

        html += Self.emailFoot()
        return (markdown, html)
    }

    private func formatAgentDigest(_ digest: AgentDigest) -> (markdown: String, html: String) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEEE, MMMM d, yyyy"

        var markdown = "# Alfred Agent Digest - \(dateFormatter.string(from: digest.date))\n\n"

        var html = Self.emailHead()
        html += "<div style=\"\(Self.fontDisplay) font-size: 22px; font-weight: 400; color: #1b2a4a; margin-bottom: 4px;\">Agent Digest</div>"
        html += "<div style=\"\(Self.fontBody) font-size: 12px; color: #8890a0; margin-bottom: 8px;\">\(dateFormatter.string(from: digest.date))</div>"

        // Summary Stats
        markdown += "## Summary\n"
        markdown += "- Total Decisions: \(digest.summary.totalDecisions)\n"
        markdown += "- Executed: \(digest.summary.decisionsExecuted)\n"
        markdown += "- Pending Review: \(digest.summary.decisionsPending)\n"
        markdown += "- New Learnings: \(digest.summary.newLearningsCount)\n\n"

        html += Self.sectionHeader("Summary")
        html += Self.statRow([
            (value: "\(digest.summary.totalDecisions)", label: "Decisions"),
            (value: "\(digest.summary.decisionsExecuted)", label: "Executed"),
            (value: "\(digest.summary.decisionsPending)", label: "Pending"),
            (value: "\(digest.summary.newLearningsCount)", label: "Learnings")
        ])

        // Agent Activity
        markdown += "## Agent Activity\n"
        html += Self.sectionHeader("Agent Activity")

        for activity in digest.agentActivity {
            let successPct = Int(activity.successRate * 100)
            markdown += "### \(activity.agentType.displayName) Agent\n"
            markdown += "- Decisions: \(activity.decisionsCount), Success Rate: \(successPct)%\n"

            var insightHtml = ""
            if let insight = activity.keyInsight {
                insightHtml = "<div style=\"\(Self.fontBody) font-size: 13px; color: #1b2a4a; margin-top: 8px; padding: 8px 10px; background-color: #ffffff; border-radius: 4px;\">💡 \(insight)</div>"
            }

            html += """
            <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin-bottom: 8px;">
            <tr><td style="background-color: #f0eeea; border-radius: 6px; padding: 14px 16px;">
                <div style="\(Self.fontBody) font-size: 14px; font-weight: 600; color: #1b2a4a; margin-bottom: 6px;">\(activity.agentType.displayName) Agent</div>
                <div style="\(Self.fontBody) font-size: 12px; color: #5c6370;">\(activity.decisionsCount) decisions · \(successPct)% success</div>
                \(insightHtml)
            </td></tr>
            </table>
            """
        }
        markdown += "\n"

        // Commitment Status
        markdown += "## Commitment Status\n"
        markdown += "- I Owe (Active): \(digest.commitmentStatus.activeIOwe)\n"
        markdown += "- They Owe Me: \(digest.commitmentStatus.activeTheyOwe)\n"
        markdown += "- Overdue: \(digest.commitmentStatus.overdueCount)\n\n"

        html += Self.sectionHeader("Commitment Status")
        html += Self.statRow([
            (value: "\(digest.commitmentStatus.activeIOwe)", label: "I Owe"),
            (value: "\(digest.commitmentStatus.activeTheyOwe)", label: "They Owe"),
            (value: "\(digest.commitmentStatus.overdueCount)", label: "Overdue"),
            (value: "\(digest.commitmentStatus.upcomingThisWeek)", label: "Due This Week")
        ])

        // Upcoming Follow-ups
        if !digest.upcomingFollowups.isEmpty {
            let timeFormatter = DateFormatter()
            timeFormatter.dateStyle = .short
            timeFormatter.timeStyle = .short

            markdown += "## Upcoming Follow-ups (\(digest.upcomingFollowups.count))\n"
            html += Self.sectionHeader("Upcoming Follow-ups · \(digest.upcomingFollowups.count)")

            for followup in digest.upcomingFollowups.prefix(5) {
                let overdueTag = followup.isOverdue ? " ⚠️ OVERDUE" : ""
                markdown += "- \(followup.title)\(overdueTag) (Due: \(timeFormatter.string(from: followup.scheduledFor)))\n"

                let accentColor = followup.isOverdue ? "#8b2332" : "#e4e2dc"
                html += Self.itemCard(
                    title: "\(followup.title)\(overdueTag)",
                    description: "",
                    meta: "Due: \(timeFormatter.string(from: followup.scheduledFor))",
                    accentColor: accentColor,
                    emoji: "📌"
                )
            }
            markdown += "\n"
        }

        // Recommendations
        if !digest.recommendations.isEmpty {
            markdown += "## Recommendations\n"
            html += Self.sectionHeader("Recommendations")

            for rec in digest.recommendations {
                markdown += "- \(rec)\n"
                html += Self.recCard(rec)
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
