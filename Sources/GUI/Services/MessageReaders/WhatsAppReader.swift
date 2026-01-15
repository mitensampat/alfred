import Foundation
import SQLite3

class WhatsAppReader {
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
        } else {
            throw MessageReaderError.connectionFailed("WhatsApp")
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
        // WhatsApp uses Core Data reference date (Jan 1, 2001)
        let referenceDate = Date(timeIntervalSinceReferenceDate: 0)
        let sinceTimestamp = since.timeIntervalSince(referenceDate)

        // Updated query based on actual WhatsApp schema
        let query = """
        SELECT
            ZWAMESSAGE.Z_PK,
            ZWAMESSAGE.ZTEXT,
            ZWAMESSAGE.ZMESSAGEDATE,
            ZWAMESSAGE.ZISFROMME,
            ZWAMESSAGE.ZFROMJID,
            ZWAMESSAGE.ZTOJID,
            ZWACHATSESSION.ZCONTACTJID,
            ZWACHATSESSION.ZPARTNERNAME,
            ZWAMESSAGE.ZMESSAGETYPE,
            ZWAMESSAGE.ZPUSHNAME,
            ZWACHATSESSION.ZSESSIONTYPE
        FROM ZWAMESSAGE
        LEFT JOIN ZWACHATSESSION ON ZWAMESSAGE.ZCHATSESSION = ZWACHATSESSION.Z_PK
        WHERE ZWAMESSAGE.ZMESSAGEDATE > ?
            AND ZWACHATSESSION.ZSESSIONTYPE IN (0, 1)
            AND LENGTH(COALESCE(ZWAMESSAGE.ZTEXT, '')) > 0
        ORDER BY ZWAMESSAGE.ZMESSAGEDATE DESC
        """

        var statement: OpaquePointer?
        defer {
            sqlite3_finalize(statement)
        }

        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_double(statement, 1, sinceTimestamp)

            while sqlite3_step(statement) == SQLITE_ROW {
                let id = String(sqlite3_column_int64(statement, 0))
                let text = sqlite3_column_text(statement, 1).flatMap { String(cString: $0) } ?? ""
                let date = sqlite3_column_double(statement, 2)
                let isFromMe = sqlite3_column_int(statement, 3) == 1
                let fromJid = sqlite3_column_text(statement, 4).flatMap { String(cString: $0) }
                let toJid = sqlite3_column_text(statement, 5).flatMap { String(cString: $0) }
                let contactJid = sqlite3_column_text(statement, 6).flatMap { String(cString: $0) } ?? "unknown"
                let partnerName = sqlite3_column_text(statement, 7).flatMap { String(cString: $0) }
                let messageType = sqlite3_column_int(statement, 8)
                let pushName = sqlite3_column_text(statement, 9).flatMap { String(cString: $0) }
                let sessionType = sqlite3_column_int(statement, 10)

                // Convert from Core Data timestamp back to Date
                let timestamp = Date(timeIntervalSinceReferenceDate: date)

                // Message type: 0 = text, 1 = image, 2 = audio, 3 = video, etc.
                let hasAttachment = messageType != 0

                // Determine if this is a group chat
                let isGroup = sessionType == 1 || contactJid.contains("@g.us")

                // Determine sender name based on context
                let senderName: String?
                if isFromMe {
                    senderName = nil
                } else if isGroup {
                    // For groups, use push name (individual sender within group)
                    senderName = pushName
                } else {
                    // For 1-1 chats, use partner name (contact name)
                    senderName = partnerName
                }

                let message = Message(
                    id: "whatsapp_\(id)",
                    platform: .whatsapp,
                    sender: isFromMe ? "me" : (fromJid ?? contactJid),
                    senderName: senderName,
                    recipient: isFromMe ? (toJid ?? contactJid) : "me",
                    content: text,
                    timestamp: timestamp,
                    direction: isFromMe ? .outgoing : .incoming,
                    chatId: contactJid,
                    isRead: true, // WhatsApp doesn't expose read status reliably in desktop DB
                    hasAttachment: hasAttachment
                )

                messages.append(message)
            }
        } else {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            throw MessageReaderError.queryFailed("WhatsApp: \(errorMessage)")
        }

        return messages
    }

    func fetchThreads(since: Date) throws -> [MessageThread] {
        let messages = try fetchMessages(since: since)
        let chatMetadata = try fetchChatMetadata()
        return groupMessagesIntoThreads(messages, chatMetadata: chatMetadata)
    }

    func fetchThreadByName(_ searchName: String, since: Date) throws -> MessageThread? {
        guard let db = db else {
            throw MessageReaderError.notConnected
        }

        // First, find the chat session that matches the search name
        let sessionQuery = """
        SELECT ZCONTACTJID, ZPARTNERNAME
        FROM ZWACHATSESSION
        WHERE ZSESSIONTYPE IN (0, 1)
        AND ZPARTNERNAME LIKE ?
        LIMIT 1
        """

        var sessionStatement: OpaquePointer?
        defer {
            sqlite3_finalize(sessionStatement)
        }

        let searchPattern = "%\(searchName)%"
        var matchedContactJid: String?
        var matchedContactName: String?

        if sqlite3_prepare_v2(db, sessionQuery, -1, &sessionStatement, nil) == SQLITE_OK {
            sqlite3_bind_text(sessionStatement, 1, (searchPattern as NSString).utf8String, -1, nil)

            if sqlite3_step(sessionStatement) == SQLITE_ROW {
                matchedContactJid = sqlite3_column_text(sessionStatement, 0).flatMap { String(cString: $0) }
                matchedContactName = sqlite3_column_text(sessionStatement, 1).flatMap { String(cString: $0) }
            }
        }

        guard let contactJid = matchedContactJid else {
            return nil // No matching contact/group found
        }

        // Now fetch all messages for this specific chat
        let coreDataSince = since.timeIntervalSinceReferenceDate
        let messageQuery = """
        SELECT
            ZWAMESSAGE.Z_PK,
            ZWAMESSAGE.ZTEXT,
            ZWAMESSAGE.ZMESSAGEDATE,
            ZWAMESSAGE.ZISFROMME,
            ZWAMESSAGE.ZFROMJID,
            ZWAMESSAGE.ZTOJID,
            ZWACHATSESSION.ZCONTACTJID,
            ZWACHATSESSION.ZPARTNERNAME,
            ZWAMESSAGE.ZMESSAGETYPE,
            ZWAMESSAGE.ZPUSHNAME,
            ZWACHATSESSION.ZSESSIONTYPE
        FROM ZWAMESSAGE
        LEFT JOIN ZWACHATSESSION ON ZWAMESSAGE.ZCHATSESSION = ZWACHATSESSION.Z_PK
        WHERE ZWAMESSAGE.ZMESSAGEDATE > ?
        AND ZWACHATSESSION.ZCONTACTJID = ?
        ORDER BY ZWAMESSAGE.ZMESSAGEDATE DESC
        """

        var messageStatement: OpaquePointer?
        defer {
            sqlite3_finalize(messageStatement)
        }

        var messages: [Message] = []

        if sqlite3_prepare_v2(db, messageQuery, -1, &messageStatement, nil) == SQLITE_OK {
            sqlite3_bind_double(messageStatement, 1, coreDataSince)
            sqlite3_bind_text(messageStatement, 2, (contactJid as NSString).utf8String, -1, nil)

            while sqlite3_step(messageStatement) == SQLITE_ROW {
                let id = sqlite3_column_int64(messageStatement, 0)
                let text = sqlite3_column_text(messageStatement, 1).flatMap { String(cString: $0) } ?? ""
                let date = sqlite3_column_double(messageStatement, 2)
                let isFromMe = sqlite3_column_int(messageStatement, 3) != 0
                let fromJid = sqlite3_column_text(messageStatement, 4).flatMap { String(cString: $0) }
                let toJid = sqlite3_column_text(messageStatement, 5).flatMap { String(cString: $0) }
                let partnerName = sqlite3_column_text(messageStatement, 7).flatMap { String(cString: $0) }
                let messageType = sqlite3_column_int(messageStatement, 8)
                let pushName = sqlite3_column_text(messageStatement, 9).flatMap { String(cString: $0) }
                let sessionType = sqlite3_column_int(messageStatement, 10)

                let timestamp = Date(timeIntervalSinceReferenceDate: date)
                let hasAttachment = messageType != 0
                let isGroup = sessionType == 1 || contactJid.contains("@g.us")

                let senderName: String?
                if isFromMe {
                    senderName = nil
                } else if isGroup {
                    senderName = pushName
                } else {
                    senderName = partnerName
                }

                let message = Message(
                    id: "whatsapp_\(id)",
                    platform: .whatsapp,
                    sender: isFromMe ? "me" : (fromJid ?? contactJid),
                    senderName: senderName,
                    recipient: isFromMe ? (toJid ?? contactJid) : "me",
                    content: text,
                    timestamp: timestamp,
                    direction: isFromMe ? .outgoing : .incoming,
                    chatId: contactJid,
                    isRead: true,
                    hasAttachment: hasAttachment
                )

                messages.append(message)
            }
        } else {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            throw MessageReaderError.queryFailed("WhatsApp: \(errorMessage)")
        }

        guard !messages.isEmpty else {
            return nil // No messages found in timeframe
        }

        let sortedMessages = messages.sorted { $0.timestamp > $1.timestamp }
        return MessageThread(
            contactIdentifier: contactJid,
            contactName: matchedContactName,
            platform: .whatsapp,
            messages: sortedMessages,
            unreadCount: 0,
            lastMessageDate: sortedMessages.first!.timestamp
        )
    }

    private func fetchChatMetadata() throws -> [String: String] {
        guard let db = db else {
            throw MessageReaderError.notConnected
        }

        var metadata: [String: String] = [:]

        let query = """
        SELECT ZCONTACTJID, ZPARTNERNAME
        FROM ZWACHATSESSION
        WHERE ZSESSIONTYPE IN (0, 1)
        """

        var statement: OpaquePointer?
        defer {
            sqlite3_finalize(statement)
        }

        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let contactJid = sqlite3_column_text(statement, 0).flatMap { String(cString: $0) } ?? ""
                let partnerName = sqlite3_column_text(statement, 1).flatMap { String(cString: $0) }

                if let name = partnerName {
                    metadata[contactJid] = name
                }
            }
        }

        return metadata
    }

    private func groupMessagesIntoThreads(_ messages: [Message], chatMetadata: [String: String]) -> [MessageThread] {
        let grouped = Dictionary(grouping: messages, by: { $0.chatId })

        return grouped.map { chatId, messages in
            let sortedMessages = messages.sorted { $0.timestamp > $1.timestamp }
            let unreadCount = 0 // WhatsApp desktop DB doesn't track read status reliably

            // Get the contact/group name from metadata
            let contactName = chatMetadata[chatId]

            return MessageThread(
                contactIdentifier: chatId,
                contactName: contactName,
                platform: .whatsapp,
                messages: sortedMessages,
                unreadCount: unreadCount,
                lastMessageDate: sortedMessages.first!.timestamp
            )
        }.sorted { $0.lastMessageDate > $1.lastMessageDate }
    }
}
