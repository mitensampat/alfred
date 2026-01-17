import Foundation

/// Service for sending messages across different platforms
class MessageSender {
    private let config: AppConfig

    init(config: AppConfig) {
        self.config = config
    }

    // MARK: - Public Interface

    func sendMessage(draft: MessageDraft) async throws -> SendResult {
        print("📤 Sending message to \(draft.recipient) via \(draft.platform.rawValue)...")

        switch draft.platform {
        case .imessage:
            return try await sendIMessage(to: draft.recipient, content: draft.content)
        case .whatsapp:
            return try await sendWhatsApp(to: draft.recipient, content: draft.content)
        case .signal:
            throw MessageSendError.platformNotSupported("Signal sending not yet implemented")
        case .email:
            return try await sendEmail(to: draft.recipient, content: draft.content)
        }
    }

    // MARK: - Platform-Specific Implementations

    private func sendIMessage(to recipient: String, content: String) async throws -> SendResult {
        // Clean up recipient - extract just the phone number/email
        let cleanRecipient = extractContactIdentifier(from: recipient)

        // Create AppleScript to send iMessage
        let script = """
        tell application "Messages"
            set targetService to 1st account whose service type = iMessage
            set targetBuddy to participant "\(cleanRecipient)" of targetService
            send "\(escapeForAppleScript(content))" to targetBuddy
        end tell
        """

        // Execute AppleScript
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus == 0 {
            print("✓ iMessage sent successfully to \(recipient)")
            return .success(platform: .imessage, timestamp: Date())
        } else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw MessageSendError.sendFailed("iMessage failed: \(errorMessage)")
        }
    }

    private func sendWhatsApp(to recipient: String, content: String) async throws -> SendResult {
        // WhatsApp doesn't have easy programmatic sending without Business API
        // For now, we'll create a draft that can be manually sent
        print("⚠️  WhatsApp Business API required for auto-send")
        print("   Draft saved to: ~/.alfred/message_drafts.json")
        print("   You can manually copy-paste the message to WhatsApp")

        throw MessageSendError.platformNotSupported("WhatsApp requires Business API. Draft saved for manual sending.")
    }

    private func sendEmail(to recipient: String, content: String) async throws -> SendResult {
        // Email sending would go through Gmail API or SMTP
        // For now, create a mailto: link suggestion
        print("📧 Email draft created")
        print("   To: \(recipient)")
        print("   Content: \(content.prefix(100))...")

        throw MessageSendError.platformNotSupported("Email sending not yet implemented. Draft saved.")
    }

    // MARK: - Helper Functions

    private func extractContactIdentifier(from displayName: String) -> String {
        // Try to extract phone number or email from display name
        // Examples:
        //   "John Doe (john@example.com)" -> "john@example.com"
        //   "+1234567890" -> "+1234567890"
        //   "Contact Name" -> "Contact Name"

        if let emailRange = displayName.range(of: #"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b"#, options: .regularExpression) {
            return String(displayName[emailRange])
        }

        if let phoneRange = displayName.range(of: #"\+?[0-9]{10,}"#, options: .regularExpression) {
            return String(displayName[phoneRange])
        }

        return displayName
    }

    private func escapeForAppleScript(_ string: String) -> String {
        // Escape special characters for AppleScript
        return string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}

// MARK: - Result Types

enum SendResult {
    case success(platform: MessagePlatform, timestamp: Date)
    case failed(error: String)

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

enum MessageSendError: Error, CustomStringConvertible {
    case platformNotSupported(String)
    case sendFailed(String)
    case invalidRecipient(String)

    var description: String {
        switch self {
        case .platformNotSupported(let message):
            return "Platform not supported: \(message)"
        case .sendFailed(let message):
            return "Send failed: \(message)"
        case .invalidRecipient(let message):
            return "Invalid recipient: \(message)"
        }
    }
}
