import Foundation
import UserNotifications

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
                subject: "Alfred: Daily Briefing - \(briefing.date.formatted(date: .abbreviated, time: .omitted))",
                body: formatted.html,
                toAddress: toAddress
            )
            print("  ✓ Email sent")
        }

        if config.push.enabled {
            do {
                print("  → Sending push notification...")
                try await sendPushNotification(
                    title: "Morning Briefing Ready",
                    body: "Your briefing for \(briefing.date.formatted(date: .abbreviated, time: .omitted)) is ready"
                )
                print("  ✓ Push notification sent")
            } catch {
                print("  ⊗ Push notifications not available in command-line mode")
            }
        }

        if config.slack.enabled {
            print("  → Sending Slack notification...")
            try await sendSlackMessage(formatted.markdown)
            print("  ✓ Slack notification sent")
        }
    }

    func sendAttentionDefenseReport(_ report: AttentionDefenseReport, toAddress: String? = nil) async throws {
        let formatted = formatAttentionReport(report)
        let dateStr = report.currentTime.formatted(date: .abbreviated, time: .omitted)

        if config.email.enabled {
            try await sendEmail(
                subject: "Alfred: Attention Defense - \(dateStr)",
                body: formatted.html,
                toAddress: toAddress
            )
        }

        if config.push.enabled {
            do {
                try await sendPushNotification(
                    title: "Attention Defense Alert",
                    body: "\(report.mustDoToday.count) critical tasks before EOD"
                )
            } catch {
                print("Note: Push notifications not available in command-line mode")
            }
        }

        if config.slack.enabled {
            try await sendSlackMessage(formatted.markdown)
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
                subject: "Alfred Agent Digest - \(dateFormatter.string(from: digest.date))",
                body: formatted.html
            )
            print("  ✓ Agent digest email sent")
        }

        if config.push.enabled {
            do {
                print("  → Sending push notification...")
                try await sendPushNotification(
                    title: "Daily Agent Digest Ready",
                    body: "\(digest.summary.totalDecisions) decisions, \(digest.newLearnings.count) new learnings"
                )
                print("  ✓ Push notification sent")
            } catch {
                print("  ⊗ Push notifications not available in command-line mode")
            }
        }

        if config.slack.enabled {
            print("  → Sending Slack notification...")
            try await sendSlackMessage(formatted.markdown)
            print("  ✓ Slack notification sent")
        }
    }

    func sendLearningDigest(subject: String, body: String) async throws {
        if config.email.enabled {
            print("  → Sending learning digest email...")
            try await sendEmail(subject: subject, body: body)
            print("  ✓ Learning digest email sent")
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
        msg['From'] = '\(config.email.smtpUsername)'
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

    // MARK: - Push Notifications

    private func sendPushNotification(title: String, body: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        try await UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Slack

    private func sendSlackMessage(_ message: String) async throws {
        guard let url = URL(string: config.slack.webhookUrl) else {
            throw NotificationError.invalidConfiguration
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "text": message,
            "mrkdwn": true
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NotificationError.sendFailed
        }
    }

    // MARK: - Formatting

    private func formatBriefing(_ briefing: DailyBriefing) -> (markdown: String, html: String) {
        // Build both markdown and HTML simultaneously for consistency
        var markdown = "# Daily Briefing - \(briefing.date.formatted(date: .long, time: .omitted))\n\n"

        // HTML with clean, readable styling (matching web UI with Inter + Playfair Display fonts)
        var html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=Playfair+Display:wght@400;500;600;700&display=swap" rel="stylesheet">
            <style>
                body {
                    font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif;
                    line-height: 1.6;
                    color: #37352f;
                    max-width: 700px;
                    margin: 0 auto;
                    padding: 20px;
                    background: #ffffff;
                }
                .brand { font-family: 'Playfair Display', Georgia, 'Times New Roman', serif; }
                h1 { font-family: 'Playfair Display', Georgia, 'Times New Roman', serif; font-size: 28px; font-weight: 600; margin-bottom: 24px; color: #37352f; }
                h2 { font-size: 16px; font-weight: 600; color: #787774; text-transform: uppercase; letter-spacing: 0.5px; margin-top: 28px; margin-bottom: 12px; border-bottom: 1px solid #e9e9e7; padding-bottom: 8px; }
                h3 { font-size: 15px; font-weight: 600; color: #37352f; margin-top: 16px; margin-bottom: 8px; }
                .stat { display: inline-block; margin-right: 24px; margin-bottom: 8px; }
                .stat-label { color: #787774; font-size: 13px; }
                .stat-value { font-size: 18px; font-weight: 600; color: #37352f; }
                .item { background: #f7f6f3; border-radius: 6px; padding: 12px 16px; margin-bottom: 10px; }
                .item-title { font-weight: 600; color: #37352f; margin-bottom: 4px; }
                .item-meta { font-size: 13px; color: #787774; }
                .item-desc { font-size: 14px; color: #37352f; margin-top: 6px; }
                .priority-high { border-left: 3px solid #eb5757; }
                .priority-critical { border-left: 3px solid #eb5757; background: #fef2f2; }
                .priority-medium { border-left: 3px solid #f7b955; }
                .priority-low { border-left: 3px solid #6fcf97; }
                .event { padding: 10px 14px; border-left: 3px solid #2383e2; background: #f0f7ff; border-radius: 4px; margin-bottom: 8px; }
                .event-time { font-size: 13px; color: #2383e2; font-weight: 500; }
                .event-title { font-weight: 600; color: #37352f; }
                .event-location { font-size: 13px; color: #787774; margin-top: 2px; }
                .tag { display: inline-block; font-size: 11px; padding: 2px 8px; border-radius: 4px; margin-right: 6px; }
                .tag-external { background: #fef3c7; color: #92400e; }
                .footer { margin-top: 32px; padding-top: 16px; border-top: 1px solid #e9e9e7; font-size: 12px; color: #9b9a97; text-align: center; }
                .footer .brand { font-size: 14px; font-weight: 500; }
            </style>
        </head>
        <body>
            <h1>📅 Daily Briefing for \(briefing.date.formatted(date: .long, time: .omitted))</h1>
        """

        // Messages Summary
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

        // Calendar
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

        // Action Items
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
        html += """
            <div class="footer">
                Generated by <span class="brand">alfred</span> v1.6.3.2 • \(Date().formatted(date: .abbreviated, time: .shortened))
            </div>
        </body>
        </html>
        """

        return (markdown, html)
    }

    private func formatAttentionReport(_ report: AttentionDefenseReport) -> (markdown: String, html: String) {
        var markdown = "# Attention Defense Report - \(report.currentTime.formatted(date: .omitted, time: .shortened))\n\n"

        var html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=Playfair+Display:wght@400;500;600;700&display=swap" rel="stylesheet">
            <style>
                body { font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif; line-height: 1.6; color: #37352f; max-width: 700px; margin: 0 auto; padding: 20px; background: #ffffff; }
                .brand { font-family: 'Playfair Display', Georgia, 'Times New Roman', serif; }
                h1 { font-family: 'Playfair Display', Georgia, 'Times New Roman', serif; font-size: 28px; font-weight: 600; margin-bottom: 24px; color: #37352f; }
                h2 { font-size: 16px; font-weight: 600; color: #787774; text-transform: uppercase; letter-spacing: 0.5px; margin-top: 28px; margin-bottom: 12px; border-bottom: 1px solid #e9e9e7; padding-bottom: 8px; }
                .item { background: #f7f6f3; border-radius: 6px; padding: 12px 16px; margin-bottom: 10px; }
                .item-title { font-weight: 600; color: #37352f; margin-bottom: 4px; }
                .item-meta { font-size: 13px; color: #787774; }
                .item-desc { font-size: 14px; color: #37352f; margin-top: 6px; }
                .priority-high { border-left: 3px solid #eb5757; }
                .priority-medium { border-left: 3px solid #f7b955; }
                .can-push { border-left: 3px solid #6fcf97; background: #f0fdf4; }
                .recommendation { padding: 8px 12px; background: #eff6ff; border-radius: 4px; margin-bottom: 6px; color: #1e40af; }
                .footer { margin-top: 32px; padding-top: 16px; border-top: 1px solid #e9e9e7; font-size: 12px; color: #9b9a97; text-align: center; }
                .footer .brand { font-size: 14px; font-weight: 500; }
            </style>
        </head>
        <body>
            <h1>⚡ Attention Defense Report</h1>
            <p style="color: #787774; margin-top: -16px; margin-bottom: 24px;">Generated at \(report.currentTime.formatted(date: .omitted, time: .shortened))</p>
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

        html += """
            <div class="footer">
                Generated by <span class="brand">alfred</span> v1.6.3.2 • \(Date().formatted(date: .abbreviated, time: .shortened))
            </div>
        </body>
        </html>
        """

        return (markdown, html)
    }

    private func formatAgentDigest(_ digest: AgentDigest) -> (markdown: String, html: String) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEEE, MMMM d, yyyy"

        var markdown = "# Alfred Agent Digest - \(dateFormatter.string(from: digest.date))\n\n"

        var html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=Playfair+Display:wght@400;500;600;700&display=swap" rel="stylesheet">
            <style>
                body { font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif; line-height: 1.6; color: #37352f; max-width: 700px; margin: 0 auto; padding: 20px; background: #ffffff; }
                .brand { font-family: 'Playfair Display', Georgia, 'Times New Roman', serif; }
                h1 { font-family: 'Playfair Display', Georgia, 'Times New Roman', serif; font-size: 28px; font-weight: 600; margin-bottom: 24px; color: #37352f; }
                h2 { font-size: 16px; font-weight: 600; color: #787774; text-transform: uppercase; letter-spacing: 0.5px; margin-top: 28px; margin-bottom: 12px; border-bottom: 1px solid #e9e9e7; padding-bottom: 8px; }
                .stat-grid { display: flex; flex-wrap: wrap; gap: 16px; margin-bottom: 16px; }
                .stat { flex: 1; min-width: 100px; background: #f7f6f3; border-radius: 6px; padding: 12px; text-align: center; }
                .stat-value { font-size: 24px; font-weight: 600; color: #37352f; }
                .stat-label { font-size: 12px; color: #787774; margin-top: 4px; }
                .agent-card { background: #f7f6f3; border-radius: 8px; padding: 14px; margin-bottom: 10px; }
                .agent-name { font-weight: 600; color: #37352f; margin-bottom: 8px; }
                .agent-stats { display: flex; gap: 16px; font-size: 13px; color: #787774; }
                .agent-insight { font-size: 14px; color: #37352f; margin-top: 8px; padding: 8px; background: #ffffff; border-radius: 4px; }
                .item { padding: 10px 14px; background: #f7f6f3; border-radius: 6px; margin-bottom: 8px; }
                .item-title { font-weight: 600; color: #37352f; }
                .item-meta { font-size: 13px; color: #787774; margin-top: 4px; }
                .overdue { border-left: 3px solid #eb5757; }
                .recommendation { padding: 8px 12px; background: #eff6ff; border-radius: 4px; margin-bottom: 6px; color: #1e40af; }
                .footer { margin-top: 32px; padding-top: 16px; border-top: 1px solid #e9e9e7; font-size: 12px; color: #9b9a97; text-align: center; }
                .footer .brand { font-size: 14px; font-weight: 500; }
            </style>
        </head>
        <body>
            <h1>🤖 <span class="brand">alfred</span> Agent Digest</h1>
            <p style="color: #787774; margin-top: -16px; margin-bottom: 24px;">\(dateFormatter.string(from: digest.date))</p>
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

        html += """
            <div class="footer">
                Generated by <span class="brand">alfred</span> v1.6.3.2 • \(Date().formatted(date: .abbreviated, time: .shortened))
            </div>
        </body>
        </html>
        """

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
