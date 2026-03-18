import Foundation
import SQLite3

/// Tracks commitment scanning history for incremental updates
/// Remembers what threads we've scanned and when, enabling efficient delta scans
class CommitmentScanTracker {
    static let shared = CommitmentScanTracker()

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        return f
    }()

    private let dbPath: URL
    private var db: OpaquePointer?
    private let dbLock = NSLock()

    private init() {
        let alfredDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".alfred")

        try? FileManager.default.createDirectory(at: alfredDir, withIntermediateDirectories: true)

        self.dbPath = alfredDir.appendingPathComponent("commitment_scan.db")

        setupDatabase()
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Database Setup

    private func setupDatabase() {
        guard sqlite3_open(dbPath.path, &db) == SQLITE_OK else {
            print("⚠️ Failed to open commitment scan database")
            return
        }

        sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA synchronous=NORMAL", nil, nil, nil)

        // Thread scan history - tracks when each thread was last scanned
        let createThreadHistoryTable = """
        CREATE TABLE IF NOT EXISTS thread_scan_history (
            thread_id TEXT PRIMARY KEY,
            thread_name TEXT,
            platform TEXT,
            last_scanned_at DATETIME,
            last_message_timestamp DATETIME,
            messages_scanned INTEGER DEFAULT 0,
            commitments_found INTEGER DEFAULT 0
        )
        """

        // Commitment extraction log - tracks what we've extracted
        let createExtractionLogTable = """
        CREATE TABLE IF NOT EXISTS commitment_extractions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            commitment_hash TEXT UNIQUE,
            thread_id TEXT,
            extracted_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            commitment_type TEXT,
            title TEXT,
            counterparty TEXT,
            confidence REAL,
            was_closed BOOLEAN DEFAULT 0,
            closed_at DATETIME
        )
        """

        // Closure detection log - tracks closure signals we've detected
        let createClosureLogTable = """
        CREATE TABLE IF NOT EXISTS closure_detections (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            commitment_hash TEXT,
            detected_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            closure_signal TEXT,
            confidence REAL,
            auto_closed BOOLEAN DEFAULT 0,
            user_confirmed BOOLEAN
        )
        """

        var errMsg: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, createThreadHistoryTable, nil, nil, &errMsg)
        sqlite3_exec(db, createExtractionLogTable, nil, nil, &errMsg)
        sqlite3_exec(db, createClosureLogTable, nil, nil, &errMsg)

        // Performance indexes
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_ce_thread_open ON commitment_extractions(thread_id, was_closed)", nil, nil, nil)
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_ce_was_closed ON commitment_extractions(was_closed)", nil, nil, nil)
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_cd_commitment_hash ON closure_detections(commitment_hash)", nil, nil, nil)
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_cd_pending ON closure_detections(auto_closed, user_confirmed)", nil, nil, nil)
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_tsh_last_scanned ON thread_scan_history(last_scanned_at)", nil, nil, nil)

        print("✓ Commitment scan database ready")
    }

    // MARK: - Thread Scan History

    /// Get the last scan time for a thread (returns nil if never scanned)
    func getLastScanTime(threadId: String) -> Date? {
        dbLock.lock()
        defer { dbLock.unlock() }

        let query = "SELECT last_scanned_at FROM thread_scan_history WHERE thread_id = ?"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, 1, threadId)

        if sqlite3_step(stmt) == SQLITE_ROW {
            if let datePtr = sqlite3_column_text(stmt, 0) {
                let dateStr = String(cString: datePtr)
                let formatter = Self.isoFormatter
                return formatter.date(from: dateStr)
            }
        }

        return nil
    }

    /// Get the last message timestamp we processed for a thread
    func getLastMessageTimestamp(threadId: String) -> Date? {
        dbLock.lock()
        defer { dbLock.unlock() }

        let query = "SELECT last_message_timestamp FROM thread_scan_history WHERE thread_id = ?"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, 1, threadId)

        if sqlite3_step(stmt) == SQLITE_ROW {
            if let datePtr = sqlite3_column_text(stmt, 0) {
                let dateStr = String(cString: datePtr)
                let formatter = Self.isoFormatter
                return formatter.date(from: dateStr)
            }
        }

        return nil
    }

    /// Record that we scanned a thread
    func recordThreadScan(
        threadId: String,
        threadName: String,
        platform: String,
        lastMessageTimestamp: Date,
        messagesScanned: Int,
        commitmentsFound: Int
    ) {
        dbLock.lock()
        defer { dbLock.unlock() }

        let formatter = Self.isoFormatter
        let now = formatter.string(from: Date())
        let lastMsgTime = formatter.string(from: lastMessageTimestamp)

        let sql = """
        INSERT OR REPLACE INTO thread_scan_history
        (thread_id, thread_name, platform, last_scanned_at, last_message_timestamp, messages_scanned, commitments_found)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, 1, threadId)
        bindText(stmt, 2, threadName)
        bindText(stmt, 3, platform)
        bindText(stmt, 4, now)
        bindText(stmt, 5, lastMsgTime)
        sqlite3_bind_int(stmt, 6, Int32(messagesScanned))
        sqlite3_bind_int(stmt, 7, Int32(commitmentsFound))

        sqlite3_step(stmt)
    }

    /// Get all threads that need scanning (not scanned recently or never scanned)
    func getThreadsNeedingScan(maxAge: TimeInterval = 3600) -> [String] {
        dbLock.lock()
        defer { dbLock.unlock() }

        let cutoff = Date().addingTimeInterval(-maxAge)
        let formatter = Self.isoFormatter
        let cutoffStr = formatter.string(from: cutoff)

        let query = """
        SELECT thread_id FROM thread_scan_history
        WHERE last_scanned_at < ? OR last_scanned_at IS NULL
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, 1, cutoffStr)

        var threads: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let idPtr = sqlite3_column_text(stmt, 0) {
                threads.append(String(cString: idPtr))
            }
        }

        return threads
    }

    // MARK: - Commitment Extraction Tracking

    /// Check if we've already extracted a commitment (by hash)
    func hasExtractedCommitment(hash: String) -> Bool {
        dbLock.lock()
        defer { dbLock.unlock() }

        let query = "SELECT 1 FROM commitment_extractions WHERE commitment_hash = ?"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, 1, hash)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// Record a commitment extraction
    func recordExtraction(
        hash: String,
        threadId: String,
        type: String,
        title: String,
        counterparty: String,
        confidence: Double
    ) {
        dbLock.lock()
        defer { dbLock.unlock() }

        let sql = """
        INSERT OR IGNORE INTO commitment_extractions
        (commitment_hash, thread_id, commitment_type, title, counterparty, confidence)
        VALUES (?, ?, ?, ?, ?, ?)
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, 1, hash)
        bindText(stmt, 2, threadId)
        bindText(stmt, 3, type)
        bindText(stmt, 4, title)
        bindText(stmt, 5, counterparty)
        sqlite3_bind_double(stmt, 6, confidence)

        sqlite3_step(stmt)
    }

    /// Reset all commitment extractions (used after hash algorithm changes)
    func resetExtractions() {
        dbLock.lock()
        defer { dbLock.unlock() }

        let sql = "DELETE FROM commitment_extractions"
        sqlite3_exec(db, sql, nil, nil, nil)
        print("🗑️  Local commitment_extractions table cleared for re-hashing")
    }

    /// Get open commitments for a thread (not yet closed)
    func getOpenCommitmentsForThread(threadId: String) -> [(hash: String, title: String, type: String, counterparty: String)] {
        dbLock.lock()
        defer { dbLock.unlock() }

        let query = """
        SELECT commitment_hash, title, commitment_type, counterparty
        FROM commitment_extractions
        WHERE thread_id = ? AND was_closed = 0
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, 1, threadId)

        var results: [(String, String, String, String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let hash = String(cString: sqlite3_column_text(stmt, 0))
            let title = String(cString: sqlite3_column_text(stmt, 1))
            let type = String(cString: sqlite3_column_text(stmt, 2))
            let counterparty = String(cString: sqlite3_column_text(stmt, 3))
            results.append((hash, title, type, counterparty))
        }

        return results
    }

    /// Get all open commitments across all threads (not yet closed)
    func getAllOpenCommitments() -> [(hash: String, title: String, type: String, counterparty: String, extractedAt: String)] {
        dbLock.lock()
        defer { dbLock.unlock() }

        let query = """
        SELECT commitment_hash, title, commitment_type, counterparty, extracted_at
        FROM commitment_extractions
        WHERE was_closed = 0
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var results: [(String, String, String, String, String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let hash = String(cString: sqlite3_column_text(stmt, 0))
            let title = String(cString: sqlite3_column_text(stmt, 1))
            let type = String(cString: sqlite3_column_text(stmt, 2))
            let counterparty = String(cString: sqlite3_column_text(stmt, 3))
            let extractedAt = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "unknown"
            results.append((hash, title, type, counterparty, extractedAt))
        }

        return results
    }

    // MARK: - Closure Detection

    /// Record a closure detection
    func recordClosureDetection(
        commitmentHash: String,
        closureSignal: String,
        confidence: Double,
        autoClosed: Bool
    ) {
        dbLock.lock()
        defer { dbLock.unlock() }

        let sql = """
        INSERT INTO closure_detections
        (commitment_hash, closure_signal, confidence, auto_closed)
        VALUES (?, ?, ?, ?)
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, 1, commitmentHash)
        bindText(stmt, 2, closureSignal)
        sqlite3_bind_double(stmt, 3, confidence)
        sqlite3_bind_int(stmt, 4, autoClosed ? 1 : 0)

        sqlite3_step(stmt)
    }

    /// Mark a commitment as closed and record completion in learning system
    func markCommitmentClosed(hash: String, closureMethod: String = "unknown") {
        // First, look up commitment details before closing (need counterparty, type, extracted_at)
        var counterparty = ""
        var commitmentType = ""
        var daysOpen = 0
        var wasOverdue = false

        dbLock.lock()
        let lookupSql = "SELECT counterparty, commitment_type, extracted_at FROM commitment_extractions WHERE commitment_hash = ?"
        var lookupStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, lookupSql, -1, &lookupStmt, nil) == SQLITE_OK {
            bindText(lookupStmt, 1, hash)
            if sqlite3_step(lookupStmt) == SQLITE_ROW {
                if let cp = sqlite3_column_text(lookupStmt, 0) {
                    counterparty = String(cString: cp)
                }
                if let ct = sqlite3_column_text(lookupStmt, 1) {
                    commitmentType = String(cString: ct)
                }
                if let ea = sqlite3_column_text(lookupStmt, 2) {
                    let extractedStr = String(cString: ea)
                    let formatter = Self.isoFormatter
                    if let extractedDate = formatter.date(from: extractedStr) {
                        daysOpen = max(0, Calendar.current.dateComponents([.day], from: extractedDate, to: Date()).day ?? 0)
                        // Consider overdue if open more than 14 days
                        wasOverdue = daysOpen > 14
                    }
                }
            }
        }
        sqlite3_finalize(lookupStmt)

        // Now mark as closed
        let formatter = Self.isoFormatter
        let now = formatter.string(from: Date())

        let sql = "UPDATE commitment_extractions SET was_closed = 1, closed_at = ? WHERE commitment_hash = ?"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            dbLock.unlock()
            return
        }

        bindText(stmt, 1, now)
        bindText(stmt, 2, hash)

        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        dbLock.unlock()

        // Record in learning system (outside lock to avoid deadlock)
        if !counterparty.isEmpty {
            WorkflowLearningService.shared.recordCommitmentCompleted(
                hash: hash,
                counterparty: counterparty,
                commitmentType: commitmentType,
                daysOpen: daysOpen,
                wasOverdue: wasOverdue,
                closureMethod: closureMethod
            )
        }
    }

    /// Reject a closure detection (user says it's not actually closed)
    func rejectClosureDetection(hash: String) {
        dbLock.lock()
        defer { dbLock.unlock() }

        let sql = "UPDATE closure_detections SET user_confirmed = 0 WHERE commitment_hash = ? AND user_confirmed IS NULL"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, 1, hash)
        sqlite3_step(stmt)

        print("❌ User rejected closure for commitment: \(hash.prefix(8))...")
    }

    /// Get pending closure detections that need user confirmation
    func getPendingClosureConfirmations() -> [(hash: String, title: String, signal: String, confidence: Double)] {
        dbLock.lock()
        defer { dbLock.unlock() }

        let query = """
        SELECT cd.commitment_hash, ce.title, cd.closure_signal, cd.confidence
        FROM closure_detections cd
        JOIN commitment_extractions ce ON cd.commitment_hash = ce.commitment_hash
        WHERE cd.auto_closed = 0 AND cd.user_confirmed IS NULL AND ce.was_closed = 0
        ORDER BY cd.detected_at DESC
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var results: [(String, String, String, Double)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let hash = String(cString: sqlite3_column_text(stmt, 0))
            let title = String(cString: sqlite3_column_text(stmt, 1))
            let signal = String(cString: sqlite3_column_text(stmt, 2))
            let confidence = sqlite3_column_double(stmt, 3)
            results.append((hash, title, signal, confidence))
        }

        return results
    }

    /// Get recent auto-closures (for UI transparency — shows what Alfred auto-closed)
    func getRecentAutoClosures(limit: Int = 10) -> [(hash: String, title: String, signal: String, confidence: Double, closedAt: String, reason: String)] {
        dbLock.lock()
        defer { dbLock.unlock() }

        let query = """
        SELECT cd.commitment_hash, ce.title, cd.closure_signal, cd.confidence, ce.closed_at,
               COALESCE(
                   CASE WHEN cd.user_confirmed = 1 THEN 'user_confirmed'
                        WHEN cd.auto_closed = 1 THEN 'auto_closed'
                        ELSE 'unknown' END,
                   'unknown'
               ) as closure_method
        FROM closure_detections cd
        JOIN commitment_extractions ce ON cd.commitment_hash = ce.commitment_hash
        WHERE ce.was_closed = 1
          AND (cd.auto_closed = 1 OR cd.user_confirmed = 1)
        ORDER BY ce.closed_at DESC
        LIMIT ?
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(limit))

        var results: [(String, String, String, Double, String, String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let hash = String(cString: sqlite3_column_text(stmt, 0))
            let title = String(cString: sqlite3_column_text(stmt, 1))
            let signal = String(cString: sqlite3_column_text(stmt, 2))
            let confidence = sqlite3_column_double(stmt, 3)
            let closedAt = sqlite3_column_text(stmt, 4).flatMap { String(cString: $0) } ?? ""
            let reason = String(cString: sqlite3_column_text(stmt, 5))
            results.append((hash, title, signal, confidence, closedAt, reason))
        }

        return results
    }

    // MARK: - Stats

    /// Get scan statistics
    func getStats() -> CommitmentScanStats {
        var stats = CommitmentScanStats()

        // Single compound query for all DB stats
        dbLock.lock()

        let compoundQuery = """
        SELECT
            (SELECT COUNT(*) FROM thread_scan_history) as threads_tracked,
            (SELECT COUNT(*) FROM commitment_extractions) as total_extracted,
            (SELECT COUNT(*) FROM commitment_extractions WHERE was_closed = 0) as open_count,
            (SELECT COUNT(*) FROM commitment_extractions WHERE was_closed = 1) as closed_count,
            (SELECT COUNT(DISTINCT cd.commitment_hash) FROM closure_detections cd JOIN commitment_extractions ce ON cd.commitment_hash = ce.commitment_hash WHERE cd.auto_closed = 1) as auto_closed,
            (SELECT COUNT(DISTINCT cd.commitment_hash) FROM closure_detections cd JOIN commitment_extractions ce ON cd.commitment_hash = ce.commitment_hash WHERE cd.auto_closed = 0 AND cd.user_confirmed IS NULL AND ce.was_closed = 0) as pending,
            (SELECT MAX(last_scanned_at) FROM thread_scan_history) as last_scan
        """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, compoundQuery, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                stats.threadsTracked = Int(sqlite3_column_int(stmt, 0))
                stats.totalExtracted = Int(sqlite3_column_int(stmt, 1))
                stats.openCommitments = Int(sqlite3_column_int(stmt, 2))
                stats.closedCount = Int(sqlite3_column_int(stmt, 3))
                stats.autoClosedCount = Int(sqlite3_column_int(stmt, 4))
                stats.pendingClosures = Int(sqlite3_column_int(stmt, 5))
                if let datePtr = sqlite3_column_text(stmt, 6) {
                    let dateStr = String(cString: datePtr)
                    let formatter = Self.isoFormatter
                    stats.lastScanTime = formatter.date(from: dateStr)
                }
            }
            sqlite3_finalize(stmt)
        }

        dbLock.unlock()

        // Get scan coverage from FavoritesService and ContactLearner (outside DB lock)
        let favorites = FavoritesService.shared.getFavorites()
        stats.favoritesCount = favorites.contacts.count + favorites.groups.count

        let allThreads = ContactLearner.shared.getAllThreads()
        let activeThreads = allThreads.filter { thread in
            let totalMessages = thread.participationHistory.reduce(0) { $0 + $1.totalMessages }
            return totalMessages >= 5 && thread.avgParticipation > 0
        }
        stats.activeThreadsCount = activeThreads.count

        return stats
    }

    // MARK: - Helpers

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        value.withCString { cString in
            _ = sqlite3_bind_text(stmt, index, cString, -1, SQLITE_TRANSIENT)
        }
    }
}

// MARK: - Data Models

struct CommitmentScanStats: Codable {
    var threadsTracked: Int = 0
    var totalExtracted: Int = 0
    var openCommitments: Int = 0
    var closedCount: Int = 0
    var autoClosedCount: Int = 0
    var pendingClosures: Int = 0
    var lastScanTime: Date?
    var favoritesCount: Int = 0
    var activeThreadsCount: Int = 0
}
