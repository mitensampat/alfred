import Foundation
import SQLite3
import Contacts

class iMessageReader {
    private let dbPath: String
    private var db: OpaquePointer?
    private var contactNameCache: [String: String] = [:]

    init(dbPath: String) {
        self.dbPath = dbPath
    }

    func connect() throws {
        let path = (dbPath as NSString).expandingTildeInPath

        // Pre-flight check: verify file exists
        guard FileManager.default.fileExists(atPath: path) else {
            throw MessageReaderError.databaseNotFound(path)
        }

        // Open database directly — sqlite3_open_v2 properly goes through macOS TCC
        // (FileManager.isReadableFile falsely returns false for TCC-protected files even with Full Disk Access)
        var db: OpaquePointer?
        let result = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)
        if result == SQLITE_OK {
            // Verify we can actually read by running a simple query (TCC may defer rejection)
            var stmt: OpaquePointer?
            let testResult = sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM message LIMIT 1", -1, &stmt, nil)
            sqlite3_finalize(stmt)
            if testResult == SQLITE_OK {
                self.db = db
            } else {
                sqlite3_close(db)
                print("⚠️ iMessage: Full Disk Access not granted - cannot query \(path)")
                throw MessageReaderError.connectionFailed("iMessage - Full Disk Access required. Grant in System Settings → Privacy & Security → Full Disk Access")
            }
        } else {
            print("⚠️ iMessage: Failed to open database at \(path) (error: \(result))")
            throw MessageReaderError.connectionFailed("iMessage - Full Disk Access required. Grant in System Settings → Privacy & Security → Full Disk Access")
        }
    }

    func disconnect() {
        if let db = db {
            sqlite3_close(db)
            self.db = nil
        }
    }

    func fetchMessages(since: Date) throws -> [Message] {
        guard let db = db else {
            throw MessageReaderError.notConnected
        }

        var messages: [Message] = []

        // iMessage timestamps are in nanoseconds since 2001-01-01
        let referenceDate = Date(timeIntervalSinceReferenceDate: 0)
        let sinceTimestamp = Int64(since.timeIntervalSince(referenceDate) * 1_000_000_000)

        let query = """
        SELECT
            m.ROWID,
            m.guid,
            m.text,
            m.date,
            m.is_from_me,
            m.is_read,
            m.cache_has_attachments,
            h.id as handle_id,
            c.chat_identifier,
            c.display_name
        FROM message m
        JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
        JOIN chat c ON c.ROWID = cmj.chat_id
        LEFT JOIN handle h ON m.handle_id = h.ROWID
        WHERE m.date > ?
        ORDER BY m.date DESC
        LIMIT 5000
        """

        var statement: OpaquePointer?
        defer {
            sqlite3_finalize(statement)
        }

        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int64(statement, 1, sinceTimestamp)

            while sqlite3_step(statement) == SQLITE_ROW {
                let rowId = sqlite3_column_int64(statement, 0)
                let guid = String(cString: sqlite3_column_text(statement, 1))
                let text = sqlite3_column_text(statement, 2).flatMap { String(cString: $0) } ?? ""
                let date = sqlite3_column_int64(statement, 3)
                let isFromMe = sqlite3_column_int(statement, 4) == 1
                let isRead = sqlite3_column_int(statement, 5) == 1
                let hasAttachment = sqlite3_column_int(statement, 6) == 1
                let handleId = sqlite3_column_text(statement, 7).flatMap { String(cString: $0) } ?? "unknown"
                let chatId = String(cString: sqlite3_column_text(statement, 8))
                let displayName = sqlite3_column_text(statement, 9).flatMap { String(cString: $0) }

                let timestamp = referenceDate.addingTimeInterval(Double(date) / 1_000_000_000)

                let message = Message(
                    id: guid,
                    platform: .imessage,
                    sender: isFromMe ? "me" : handleId,
                    senderName: isFromMe ? nil : displayName,
                    recipient: isFromMe ? handleId : "me",
                    content: text,
                    timestamp: timestamp,
                    direction: isFromMe ? .outgoing : .incoming,
                    chatId: chatId,
                    isRead: isRead,
                    hasAttachment: hasAttachment
                )

                messages.append(message)
            }
        } else {
            throw MessageReaderError.queryFailed("iMessage")
        }

        return messages
    }

    func fetchThreads(since: Date) throws -> [MessageThread] {
        let messages = try fetchMessages(since: since)
        return groupMessagesIntoThreads(messages)
    }

    private func groupMessagesIntoThreads(_ messages: [Message]) -> [MessageThread] {
        let grouped = Dictionary(grouping: messages, by: { $0.chatId })

        // Resolve phone numbers/emails to contact names via macOS Contacts
        let identifiers = Set(grouped.keys)
        let nameMap = resolveContactNames(for: identifiers)

        return grouped.map { chatId, messages in
            let sortedMessages = messages.sorted { $0.timestamp > $1.timestamp }
            let unreadCount = messages.filter { $0.direction == .incoming && !$0.isRead }.count
            let lastMessage = sortedMessages.first!

            // Priority: resolved Contacts name → chat display_name → raw identifier
            let resolvedName = nameMap[chatId] ?? lastMessage.senderName

            return MessageThread(
                contactIdentifier: chatId,
                contactName: resolvedName,
                platform: .imessage,
                messages: sortedMessages,
                unreadCount: unreadCount,
                lastMessageDate: lastMessage.timestamp
            )
        }.sorted { $0.lastMessageDate > $1.lastMessageDate }
    }

    // MARK: - Contact Name Resolution

    /// Resolve iMessage chat identifiers (phone numbers, emails) to human-readable names
    /// using the macOS Contacts framework. Batch-loads all contacts once for efficiency.
    /// Results are cached for the session.
    private func resolveContactNames(for identifiers: Set<String>) -> [String: String] {
        var result: [String: String] = [:]

        // Check if all identifiers are already cached
        let uncachedIdentifiers = identifiers.filter { contactNameCache[$0] == nil }

        // Batch-load all contacts once (only if we have uncached identifiers)
        var phoneToName: [String: String] = [:]
        var emailToName: [String: String] = [:]

        if !uncachedIdentifiers.isEmpty {
            let store = CNContactStore()
            let keysToFetch: [CNKeyDescriptor] = [
                CNContactGivenNameKey as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor,
                CNContactEmailAddressesKey as CNKeyDescriptor,
                CNContactPhoneNumbersKey as CNKeyDescriptor
            ]

            let fetchRequest = CNContactFetchRequest(keysToFetch: keysToFetch)
            try? store.enumerateContacts(with: fetchRequest) { contact, _ in
                let fullName = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                guard !fullName.isEmpty else { return }
                for phone in contact.phoneNumbers {
                    let digits = phone.value.stringValue.filter { $0.isNumber }
                    phoneToName[digits] = fullName
                    // Also store last 10 digits for matching
                    if digits.count >= 10 {
                        phoneToName[String(digits.suffix(10))] = fullName
                    }
                }
                for email in contact.emailAddresses {
                    emailToName[email.value.lowercased as String] = fullName
                }
            }
        }

        for identifier in identifiers {
            // Check cache first
            if let cached = contactNameCache[identifier] {
                result[identifier] = cached
                continue
            }

            // Strip iMessage chat_identifier prefixes
            let cleaned = identifier
                .replacingOccurrences(of: "iMessage;-;", with: "")
                .replacingOccurrences(of: "iMessage;+;", with: "")
                .replacingOccurrences(of: "SMS;-;", with: "")
                .replacingOccurrences(of: "SMS;+;", with: "")

            // Skip group chat identifiers (they use display_name from the DB)
            if cleaned.hasPrefix("chat") { continue }

            // Try email lookup
            if cleaned.contains("@") {
                if let name = emailToName[cleaned.lowercased()] {
                    contactNameCache[identifier] = name
                    result[identifier] = name
                    continue
                }
            }

            // Try phone lookup
            let digits = cleaned.filter { $0.isNumber }
            if let name = phoneToName[digits] ?? phoneToName[String(digits.suffix(10))] {
                contactNameCache[identifier] = name
                result[identifier] = name
                continue
            }

            // Fallback: no match found, identifier stays as-is
            result[identifier] = identifier
        }

        let resolvedCount = result.values.filter { identifiers.contains($0) == false }.count
        if resolvedCount > 0 {
            print("  📇 Resolved \(resolvedCount)/\(identifiers.count) iMessage contacts to names")
        }

        return result
    }
}

enum MessageReaderError: Error, LocalizedError {
    case databaseNotFound(String)
    case connectionFailed(String)
    case notConnected
    case queryFailed(String)
    case invalidData
    case didYouMean(original: String, suggestions: [String])

    var errorDescription: String? {
        switch self {
        case .databaseNotFound(let path):
            return "Database not found at path: \(path)"
        case .connectionFailed(let platform):
            return "Failed to connect to \(platform) database"
        case .notConnected:
            return "Not connected to database"
        case .queryFailed(let platform):
            return "Query failed for \(platform)"
        case .invalidData:
            return "Invalid data format"
        case .didYouMean(let original, let suggestions):
            return "No exact match for '\(original)'. Did you mean: \(suggestions.joined(separator: ", "))?"
        }
    }
}
