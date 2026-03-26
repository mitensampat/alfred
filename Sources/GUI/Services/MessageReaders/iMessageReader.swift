import Foundation
import SQLite3

class iMessageReader {
    private static var _shared: iMessageReader?
    private static let sharedLock = NSLock()

    static func shared(dbPath: String) -> iMessageReader {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        if let existing = _shared { return existing }
        let reader = iMessageReader(dbPath: dbPath)
        _shared = reader
        return reader
    }

    private let dbPath: String
    private var db: OpaquePointer?

    init(dbPath: String) {
        self.dbPath = dbPath
    }

    func connect() throws {
        if db != nil { return }

        let path = (dbPath as NSString).expandingTildeInPath

        guard FileManager.default.fileExists(atPath: path) else {
            throw MessageReaderError.databaseNotFound(path)
        }

        var db: OpaquePointer?
        let result = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
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
        // No-op for singleton: the shared connection stays open for the app lifetime.
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

        return grouped.map { chatId, messages in
            let sortedMessages = messages.sorted { $0.timestamp > $1.timestamp }
            let unreadCount = messages.filter { $0.direction == .incoming && !$0.isRead }.count
            let lastMessage = sortedMessages.first!

            return MessageThread(
                contactIdentifier: chatId,
                contactName: lastMessage.senderName,
                platform: .imessage,
                messages: sortedMessages,
                unreadCount: unreadCount,
                lastMessageDate: lastMessage.timestamp
            )
        }.sorted { $0.lastMessageDate > $1.lastMessageDate }
    }
}

enum MessageReaderError: Error, LocalizedError {
    case databaseNotFound(String)
    case connectionFailed(String)
    case notConnected
    case queryFailed(String)
    case invalidData

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
        }
    }
}
