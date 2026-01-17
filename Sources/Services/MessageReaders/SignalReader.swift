import Foundation
import SQLite3
import Security

class SignalReader {
    private let dbPath: String
    private var db: OpaquePointer?

    init(dbPath: String) {
        self.dbPath = dbPath
    }

    func connect() throws {
        let path = (dbPath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            throw MessageReaderError.databaseNotFound(path)
        }

        var db: OpaquePointer?
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            self.db = db

            // Signal uses SQLCipher encryption - retrieve key from Keychain
            if let encryptionKey = getSignalEncryptionKey() {
                // Set the encryption key using PRAGMA key
                let keyStatement = "PRAGMA key = \"x'\(encryptionKey)'\";"
                var errorMsg: UnsafeMutablePointer<Int8>?
                if sqlite3_exec(db, keyStatement, nil, nil, &errorMsg) != SQLITE_OK {
                    if let error = errorMsg {
                        let errorString = String(cString: error)
                        sqlite3_free(errorMsg)
                        throw MessageReaderError.connectionFailed("Signal (encryption key): \(errorString)")
                    }
                    throw MessageReaderError.connectionFailed("Signal (encryption key)")
                }
            }
        } else {
            throw MessageReaderError.connectionFailed("Signal")
        }
    }

    private func getSignalEncryptionKey() -> String? {
        // Retrieve Signal's encryption key from macOS Keychain
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Signal Safe Storage",
            kSecAttrAccount as String: "Signal",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let base64Key = String(data: data, encoding: .utf8) else {
            return nil
        }

        // Decode base64 to hex for SQLCipher
        guard let keyData = Data(base64Encoded: base64Key) else {
            return nil
        }

        return keyData.map { String(format: "%02x", $0) }.joined()
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
        let sinceTimestamp = Int64(since.timeIntervalSince1970 * 1000)

        let query = """
        SELECT
            messages.id,
            messages.body,
            messages.sent_at,
            messages.type,
            messages.conversationId,
            conversations.name,
            conversations.e164,
            messages.hasAttachments,
            messages.readStatus
        FROM messages
        LEFT JOIN conversations ON messages.conversationId = conversations.id
        WHERE messages.sent_at > ?
        ORDER BY messages.sent_at DESC
        """

        var statement: OpaquePointer?
        defer {
            sqlite3_finalize(statement)
        }

        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int64(statement, 1, sinceTimestamp)

            while sqlite3_step(statement) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(statement, 0))
                let body = sqlite3_column_text(statement, 1).flatMap { String(cString: $0) } ?? ""
                let sentAt = sqlite3_column_int64(statement, 2)
                let type = sqlite3_column_text(statement, 3).flatMap { String(cString: $0) } ?? "incoming"
                let conversationId = String(cString: sqlite3_column_text(statement, 4))
                let name = sqlite3_column_text(statement, 5).flatMap { String(cString: $0) }
                let e164 = sqlite3_column_text(statement, 6).flatMap { String(cString: $0) } ?? "unknown"
                let hasAttachments = sqlite3_column_int(statement, 7) == 1
                let readStatus = sqlite3_column_int(statement, 8)

                let timestamp = Date(timeIntervalSince1970: Double(sentAt) / 1000)
                let isFromMe = type == "outgoing"
                let isRead = readStatus > 0

                let message = Message(
                    id: "signal_\(id)",
                    platform: .signal,
                    sender: isFromMe ? "me" : e164,
                    senderName: isFromMe ? nil : name,
                    recipient: isFromMe ? e164 : "me",
                    content: body,
                    timestamp: timestamp,
                    direction: isFromMe ? .outgoing : .incoming,
                    chatId: conversationId,
                    isRead: isRead,
                    hasAttachment: hasAttachments
                )

                messages.append(message)
            }
        } else {
            throw MessageReaderError.queryFailed("Signal")
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
                platform: .signal,
                messages: sortedMessages,
                unreadCount: unreadCount,
                lastMessageDate: lastMessage.timestamp
            )
        }.sorted { $0.lastMessageDate > $1.lastMessageDate }
    }
}
