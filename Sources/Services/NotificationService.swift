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
                subject: "Daily Briefing - \(briefing.date.formatted(date: .abbreviated, time: .omitted))",
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

        if config.email.enabled {
            try await sendEmail(
                subject: "Attention Defense - End of Day Planning",
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
        var markdown = """
        # Daily Briefing - \(briefing.date.formatted(date: .long, time: .omitted))

        ## Messages Summary
        - **Total Messages**: \(briefing.messagingSummary.stats.totalMessages)
        - **Unread**: \(briefing.messagingSummary.stats.unreadMessages)
        - **Need Response**: \(briefing.messagingSummary.stats.threadsNeedingResponse)

        ### Critical Messages
        """

        for summary in briefing.messagingSummary.criticalMessages.prefix(5) {
            markdown += """

            **\(summary.thread.contactName ?? "Unknown")** (\(summary.thread.platform.rawValue))
            - \(summary.summary)
            - Urgency: \(summary.urgency.rawValue)
            """
        }

        markdown += """


        ## Today's Schedule
        - **Total Meeting Time**: \(Int(briefing.calendarBriefing.schedule.totalMeetingTime / 3600))h \(Int((briefing.calendarBriefing.schedule.totalMeetingTime.truncatingRemainder(dividingBy: 3600)) / 60))m
        - **Focus Time**: \(Int(briefing.calendarBriefing.focusTime / 3600))h \(Int((briefing.calendarBriefing.focusTime.truncatingRemainder(dividingBy: 3600)) / 60))m
        - **External Meetings**: \(briefing.calendarBriefing.schedule.externalMeetings.count)

        """

        for meeting in briefing.calendarBriefing.meetingBriefings {
            markdown += """

            ### \(meeting.event.title)
            **Time**: \(meeting.event.startTime.formatted(date: .omitted, time: .shortened)) - \(meeting.event.endTime.formatted(date: .omitted, time: .shortened))
            **Attendees**: \(meeting.attendeeBriefings.map { $0.attendee.name ?? $0.attendee.email }.joined(separator: ", "))

            **Context**: \(meeting.context ?? "No context available")

            **Preparation**:
            \(meeting.preparation)

            **Key Topics**:
            \(meeting.suggestedTopics.map { "- \($0)" }.joined(separator: "\n"))

            """
        }

        markdown += """


        ## Action Items (\(briefing.actionItems.count))
        """

        for item in briefing.actionItems.prefix(10) {
            let dueStr = item.dueDate?.formatted(date: .omitted, time: .shortened) ?? "No deadline"
            markdown += """

            - [\(item.priority.rawValue)] **\(item.title)**
              \(item.description)
              Due: \(dueStr) | Est: \(item.estimatedDuration.map { "\(Int($0/60))min" } ?? "unknown")
            """
        }

        // Convert markdown to HTML (simplified)
        let html = markdownToHTML(markdown)

        return (markdown, html)
    }

    private func formatAttentionReport(_ report: AttentionDefenseReport) -> (markdown: String, html: String) {
        var markdown = """
        # Attention Defense Report - \(report.currentTime.formatted(date: .omitted, time: .shortened))

        ## Must Complete Before EOD (\(report.mustDoToday.count))
        """

        for item in report.mustDoToday {
            markdown += """

            - **\(item.title)**
              \(item.description)
              Priority: \(item.priority.rawValue) | Est: \(item.estimatedDuration.map { "\(Int($0/60))min" } ?? "unknown")
            """
        }

        markdown += """


        ## Can Push to Tomorrow (\(report.canPushOff.count))
        """

        for suggestion in report.canPushOff {
            markdown += """

            - **\(suggestion.item.title)**
              Reason: \(suggestion.reason)
              Impact: \(suggestion.impact.rawValue)
            """
        }

        markdown += """


        ## Recommendations
        \(report.recommendations.map { "- \($0)" }.joined(separator: "\n"))
        """

        let html = markdownToHTML(markdown)

        return (markdown, html)
    }

    private func formatAgentDigest(_ digest: AgentDigest) -> (markdown: String, html: String) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEEE, MMMM d, yyyy"

        var markdown = """
        # Alfred Agent Digest - \(dateFormatter.string(from: digest.date))

        ## Summary
        - **Total Decisions**: \(digest.summary.totalDecisions)
        - **Executed**: \(digest.summary.decisionsExecuted)
        - **Pending Review**: \(digest.summary.decisionsPending)
        - **New Learnings**: \(digest.summary.newLearningsCount)
        - **Follow-ups Created**: \(digest.summary.followupsCreated)
        - **Commitments Closed**: \(digest.summary.commitmentsClosed)

        ## Agent Activity
        """

        for activity in digest.agentActivity {
            let successPct = Int(activity.successRate * 100)
            markdown += """

            ### \(activity.agentType.displayName) Agent
            - **Decisions**: \(activity.decisionsCount)
            - **Success Rate**: \(successPct)%
            """
            if let topAction = activity.topAction {
                markdown += "\n- **Top Action**: \(topAction)"
            }
            if let insight = activity.keyInsight {
                markdown += "\n- **Key Insight**: \(insight)"
            }
        }

        if !digest.newLearnings.isEmpty {
            markdown += """


            ## New Learnings (\(digest.newLearnings.count))
            """
            for learning in digest.newLearnings {
                markdown += """

                - **[\(learning.agentType.displayName)]** \(learning.description)
                """
            }
        }

        if !digest.decisionsRequiringReview.isEmpty {
            markdown += """


            ## Decisions Requiring Review (\(digest.decisionsRequiringReview.count))
            """
            for decision in digest.decisionsRequiringReview {
                markdown += """

                - **[\(decision.agentType.displayName)]** \(decision.action.description)
                  Reasoning: \(decision.reasoning)
                """
            }
        }

        // Commitment status
        markdown += """


        ## Commitment Status
        - **I Owe (Active)**: \(digest.commitmentStatus.activeIOwe)
        - **They Owe Me (Active)**: \(digest.commitmentStatus.activeTheyOwe)
        - **Completed Today**: \(digest.commitmentStatus.completedToday)
        - **Overdue**: \(digest.commitmentStatus.overdueCount)
        - **Due This Week**: \(digest.commitmentStatus.upcomingThisWeek)
        """

        if !digest.upcomingFollowups.isEmpty {
            markdown += """


            ## Upcoming Follow-ups (\(digest.upcomingFollowups.count))
            """
            let timeFormatter = DateFormatter()
            timeFormatter.dateStyle = .short
            timeFormatter.timeStyle = .short

            for followup in digest.upcomingFollowups.prefix(5) {
                let overdueTag = followup.isOverdue ? " ⚠️ OVERDUE" : ""
                markdown += """

                - **\(followup.title)**\(overdueTag)
                  Due: \(timeFormatter.string(from: followup.scheduledFor))
                  Context: \(followup.context.prefix(50))\(followup.context.count > 50 ? "..." : "")
                """
            }
        }

        if !digest.recommendations.isEmpty {
            markdown += """


            ## Recommendations
            """
            for rec in digest.recommendations {
                markdown += "\n- \(rec)"
            }
        }

        let html = markdownToHTML(markdown)
        return (markdown, html)
    }

    private func markdownToHTML(_ markdown: String) -> String {
        // Simplified markdown to HTML conversion
        // In production, use a proper markdown library
        var html = markdown
            .replacingOccurrences(of: "# ", with: "<h1>")
            .replacingOccurrences(of: "\n\n", with: "</p><p>")
            .replacingOccurrences(of: "## ", with: "<h2>")
            .replacingOccurrences(of: "### ", with: "<h3>")
            .replacingOccurrences(of: "**", with: "<strong>")
            .replacingOccurrences(of: "**", with: "</strong>")

        return "<html><body style='font-family: -apple-system, sans-serif;'><p>\(html)</p></body></html>"
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
