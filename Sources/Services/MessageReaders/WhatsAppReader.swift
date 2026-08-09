import Foundation
import SQLite3

class WhatsAppReader: WhatsAppMessageSource {
    /// Shared singleton — ensures one SQLite connection, one serial queue, across the entire app.
    /// All callers MUST use `WhatsAppReader.shared(dbPath:)` instead of `WhatsAppReader(dbPath:)`.
    private static var _shared: WhatsAppReader?
    private static let sharedLock = NSLock()

    static func shared(dbPath: String) -> WhatsAppReader {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        if let existing = _shared {
            return existing
        }
        let reader = WhatsAppReader(dbPath: dbPath)
        _shared = reader
        return reader
    }

    private let dbPath: String
    /// Single persistent connection opened with SQLITE_OPEN_FULLMUTEX.
    /// FULLMUTEX serializes all SQLite operations internally using its own C-level mutex,
    /// which does NOT block Swift's cooperative thread pool (unlike DispatchQueue.sync
    /// or DispatchSemaphore which cause deadlocks under concurrent async load).
    private var db: OpaquePointer?
    /// Thread-safe storage for chat metadata built during fetchMessages.
    /// Uses NSLock to protect against concurrent dictionary mutation (crash #1 root cause).
    private var _chatNames: [String: String] = [:]
    private let chatNamesLock = NSLock()

    private func setChatName(_ name: String, forJid jid: String) {
        chatNamesLock.lock()
        _chatNames[jid] = name
        chatNamesLock.unlock()
    }

    private func getChatNames() -> [String: String] {
        chatNamesLock.lock()
        defer { chatNamesLock.unlock() }
        return _chatNames
    }

    private func resetChatNames() {
        chatNamesLock.lock()
        _chatNames = [:]
        chatNamesLock.unlock()
    }

    init(dbPath: String) {
        self.dbPath = dbPath
    }

    func connect() throws {
        // Idempotent — if already connected, skip
        if db != nil { return }

        let path = (dbPath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            throw MessageReaderError.databaseNotFound(path)
        }

        var localDb: OpaquePointer?
        // FULLMUTEX: SQLite serializes all operations internally using its own C-level mutex.
        // This is safe with Swift async because SQLite's mutex doesn't block the cooperative thread pool.
        if sqlite3_open_v2(path, &localDb, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK {
            self.db = localDb
        } else {
            throw MessageReaderError.connectionFailed("WhatsApp")
        }
    }

    func disconnect() {
        // No-op for singleton: the shared connection stays open for the app lifetime.
        // Closing a shared connection while other callers are reading causes
        // _os_unfair_lock_corruption_abort in sqlite3Close → SIGKILL.
        // Connection is cleaned up when the process exits.
    }

    func fetchMessages(since: Date) throws -> [Message] {
        return try _unsafeFetchMessages(since: since)
    }

    /// Internal implementation — each call opens its own short-lived read-only connection
    private func _unsafeFetchMessages(since: Date) throws -> [Message] {
        guard let db = db else { throw MessageReaderError.notConnected }

        var messages: [Message] = []
        resetChatNames() // Reset; will be rebuilt from query results
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
        LIMIT 5000
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
                // Build chat name metadata from query results (avoids separate fetchChatMetadata query)
                if let name = partnerName {
                    setChatName(name, forJid: contactJid)
                }
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
        return try _unsafeFetchThreads(since: since)
    }

    /// Internal implementation — SQLite serialization handled by SQLITE_OPEN_FULLMUTEX
    private func _unsafeFetchThreads(since: Date) throws -> [MessageThread] {
        let messages = try _unsafeFetchMessages(since: since)
        // Chat metadata (contactJid -> partnerName) is now built during fetchMessages
        // from the same JOIN query, eliminating the need for a separate fetchChatMetadata() call
        var threads = groupMessagesIntoThreads(messages, chatMetadata: getChatNames())

        // Update lastMessageDate to reflect ALL interaction types (calls, media, etc.)
        // fetchMessages only returns text messages, so calls/media are invisible.
        // This separate query gets the true last interaction date per chat.
        let trueLastDates = try fetchTrueLastInteractionDates(since: since)
        for i in threads.indices {
            if let trueDate = trueLastDates[threads[i].contactIdentifier],
               trueDate > threads[i].lastMessageDate {
                threads[i] = MessageThread(
                    contactIdentifier: threads[i].contactIdentifier,
                    contactName: threads[i].contactName,
                    platform: threads[i].platform,
                    messages: threads[i].messages,
                    unreadCount: threads[i].unreadCount,
                    lastMessageDate: trueDate
                )
            }
        }

        // Also add threads for contacts who ONLY had calls/media (no text at all)
        let existingJids = Set(threads.map { $0.contactIdentifier })
        for (jid, date) in trueLastDates where !existingJids.contains(jid) {
            if let name = getChatNames()[jid] ?? nil {
                threads.append(MessageThread(
                    contactIdentifier: jid,
                    contactName: name,
                    platform: .whatsapp,
                    messages: [],
                    unreadCount: 0,
                    lastMessageDate: date
                ))
            }
        }

        return threads.sorted { $0.lastMessageDate > $1.lastMessageDate }
    }

    /// Returns the true last interaction date per chat, including calls and media (not just text).
    private func fetchTrueLastInteractionDates(since: Date) throws -> [String: Date] {
        guard let db = db else { throw MessageReaderError.notConnected }

        let sinceTimestamp = since.timeIntervalSinceReferenceDate

        let query = """
        SELECT
            ZWACHATSESSION.ZCONTACTJID,
            MAX(ZWAMESSAGE.ZMESSAGEDATE) AS LAST_DATE,
            ZWACHATSESSION.ZPARTNERNAME
        FROM ZWAMESSAGE
        LEFT JOIN ZWACHATSESSION ON ZWAMESSAGE.ZCHATSESSION = ZWACHATSESSION.Z_PK
        WHERE ZWAMESSAGE.ZMESSAGEDATE > ?
            AND ZWACHATSESSION.ZSESSIONTYPE IN (0, 1)
        GROUP BY ZWACHATSESSION.ZCONTACTJID
        """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        var results: [String: Date] = [:]

        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_double(statement, 1, sinceTimestamp)

            while sqlite3_step(statement) == SQLITE_ROW {
                guard let jidPtr = sqlite3_column_text(statement, 0) else { continue }
                let jid = String(cString: jidPtr)
                let dateVal = sqlite3_column_double(statement, 1)
                let date = Date(timeIntervalSinceReferenceDate: dateVal)
                results[jid] = date

                // Also capture partner names for contacts with only non-text interactions
                if let namePtr = sqlite3_column_text(statement, 2) {
                    setChatName(String(cString: namePtr), forJid: jid)
                }
            }
        }

        return results
    }

    /// Fuzzy search for thread names when exact LIKE match fails.
    /// Splits search into words, scores each thread by how many words match, and returns top candidates.
    func fuzzySearchThreadNames(_ searchName: String, limit: Int = 5) throws -> [(name: String, score: Double)] {
        guard let db = db else { throw MessageReaderError.notConnected }

        let query = "SELECT ZPARTNERNAME FROM ZWACHATSESSION WHERE ZSESSIONTYPE IN (0, 1) AND ZPARTNERNAME IS NOT NULL"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return [] }

        let searchWords = searchName.lowercased().split(separator: " ").map(String.init)
        var candidates: [(name: String, score: Double)] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let namePtr = sqlite3_column_text(stmt, 0) else { continue }
            let name = String(cString: namePtr)
            let nameLower = name.lowercased()

            // Score: fraction of search words found in the name
            var matched = 0
            for word in searchWords {
                if nameLower.contains(word) { matched += 1 }
            }

            guard matched > 0 else { continue }

            let wordScore = Double(matched) / Double(searchWords.count)

            // Bonus for edit distance on full string (catches typos like Techcruch vs Techcrunch)
            let editBonus: Double
            if searchWords.count == 1 {
                editBonus = 0
            } else {
                // Check if the name is close to search (Levenshtein-like: shared prefix ratio)
                let shorter = min(searchName.count, name.count)
                let longer = max(searchName.count, name.count)
                let commonPrefix = zip(searchName.lowercased(), nameLower).prefix(while: { $0 == $1 }).count
                editBonus = shorter > 0 ? Double(commonPrefix) / Double(longer) * 0.3 : 0
            }

            let finalScore = wordScore + editBonus

            // Require at least half the words to match
            if wordScore >= 0.5 {
                candidates.append((name: name, score: finalScore))
            }
        }

        // Sort by score descending, then by name length ascending (prefer shorter/simpler names)
        candidates.sort { a, b in
            if abs(a.score - b.score) > 0.01 { return a.score > b.score }
            return a.name.count < b.name.count
        }

        return Array(candidates.prefix(limit))
    }

    func fetchThreadByName(_ searchName: String, since: Date) throws -> MessageThread? {
        guard let db = db else { throw MessageReaderError.notConnected }

        // First, find the chat session that matches the search name
        // Prefer exact matches, then 1-on-1 chats, then shorter names
        let sessionQuery = """
        SELECT ZCONTACTJID, ZPARTNERNAME
        FROM ZWACHATSESSION
        WHERE ZSESSIONTYPE IN (0, 1)
        AND ZPARTNERNAME LIKE ?
        ORDER BY
            CASE WHEN ZPARTNERNAME = ? THEN 0 ELSE 1 END,
            ZSESSIONTYPE ASC,
            LENGTH(ZPARTNERNAME) ASC
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
            sqlite3_bind_text(sessionStatement, 2, (searchName as NSString).utf8String, -1, nil)

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
