import Foundation
import SQLite3

/// SelfModelStore - Durable SQLite-backed store for the self-model's "facets"
/// A facet is a stable, evidence-backed observation about the user: a pattern,
/// a recurring theme, a durable belief, or an open question. Facets carry a
/// confidence, a status lifecycle (forming → active → fading → archived), a
/// trajectory (how the statement has shifted over time), and the evidence that
/// backs them. User verdicts (confirmed / corrected / dismissed) are preserved
/// across re-computation so a user's correction is never silently overwritten.
class SelfModelStore {
    static let shared = SelfModelStore()

    private let dbPath: String
    private var db: OpaquePointer?
    private let dbLock = NSLock()
    private let fileManager = FileManager.default

    // MARK: - Initialization

    private init() {
        let homeDir = NSHomeDirectory()
        let alfredDir = "\(homeDir)/.alfred"

        try? fileManager.createDirectory(atPath: alfredDir, withIntermediateDirectories: true)

        dbPath = "\(alfredDir)/self_model.db"

        if sqlite3_open(dbPath, &db) == SQLITE_OK {
            sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA synchronous=NORMAL", nil, nil, nil)
            initializeDatabase()
        } else {
            print("❌ SelfModelStore: Failed to open database")
        }
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    private func initializeDatabase() {
        let createFacets = """
        CREATE TABLE IF NOT EXISTS self_facet (
            id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            statement TEXT NOT NULL,
            confidence REAL NOT NULL DEFAULT 0.5,
            status TEXT NOT NULL DEFAULT 'active',
            first_seen TEXT,
            last_seen TEXT,
            trajectory_json TEXT NOT NULL DEFAULT '[]',
            evidence_json TEXT NOT NULL DEFAULT '[]',
            user_verdict TEXT,
            metadata_json TEXT NOT NULL DEFAULT '{}'
        );
        CREATE INDEX IF NOT EXISTS idx_self_facet_kind ON self_facet(kind);
        CREATE INDEX IF NOT EXISTS idx_self_facet_status ON self_facet(status);
        """

        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, createFacets, nil, nil, &errMsg) != SQLITE_OK {
            if let err = errMsg {
                print("❌ SelfModelStore: SQL error: \(String(cString: err))")
                sqlite3_free(errMsg)
            }
        }

        print("✅ SelfModelStore database initialized")
    }

    // MARK: - Clear / Reset

    /// Delete all facets (for reset/testing)
    func clearAll() {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db else { return }

        sqlite3_exec(db, "DELETE FROM self_facet", nil, nil, nil)
        print("🗑️ SelfModelStore: All data cleared")
    }

    // MARK: - Insert / Upsert

    /// Insert a facet, or replace it if the id already exists.
    /// Preserves an existing user_verdict: INSERT OR REPLACE would wipe the row,
    /// so we read the current verdict first and re-apply it.
    func upsertFacet(
        id: String,
        kind: String,
        statement: String,
        confidence: Double,
        status: String,
        firstSeen: String?,
        lastSeen: String?,
        trajectory: [[String: String]],
        evidence: [[String: String]],
        metadata: [String: String]
    ) -> Bool {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db else { return false }

        // Preserve any existing verdict — REPLACE would otherwise erase it.
        var existingVerdict: String? = nil
        let verdictSql = "SELECT user_verdict FROM self_facet WHERE id = ?"
        var vStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, verdictSql, -1, &vStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(vStmt, 1, (id as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            if sqlite3_step(vStmt) == SQLITE_ROW {
                existingVerdict = columnText(vStmt, 0)
            }
        }
        sqlite3_finalize(vStmt)

        let trajectoryJson = jsonEncode(trajectory)
        let evidenceJson = jsonEncode(evidence)
        let metadataJson = jsonEncode(metadata)

        let sql = """
        INSERT OR REPLACE INTO self_facet
            (id, kind, statement, confidence, status, first_seen, last_seen, trajectory_json, evidence_json, user_verdict, metadata_json)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("❌ SelfModelStore: Failed to prepare upsert")
            return false
        }
        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, (kind as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 3, (statement as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_double(stmt, 4, confidence)
        sqlite3_bind_text(stmt, 5, (status as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        if let firstSeen = firstSeen {
            sqlite3_bind_text(stmt, 6, (firstSeen as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        if let lastSeen = lastSeen {
            sqlite3_bind_text(stmt, 7, (lastSeen as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } else {
            sqlite3_bind_null(stmt, 7)
        }
        sqlite3_bind_text(stmt, 8, (trajectoryJson as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 9, (evidenceJson as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        if let existingVerdict = existingVerdict {
            sqlite3_bind_text(stmt, 10, (existingVerdict as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } else {
            sqlite3_bind_null(stmt, 10)
        }
        sqlite3_bind_text(stmt, 11, (metadataJson as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        let ok = sqlite3_step(stmt) == SQLITE_DONE
        sqlite3_finalize(stmt)
        if !ok {
            print("❌ SelfModelStore: Failed to upsert facet '\(id)'")
        }
        return ok
    }

    // MARK: - Queries

    /// Fetch facets, optionally filtered by kind. Archived facets are excluded
    /// unless includeArchived is true. Ordered by confidence DESC.
    func getFacets(kind: String? = nil, includeArchived: Bool = false) -> [[String: Any]] {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db else { return [] }

        var sql = """
        SELECT id, kind, statement, confidence, status, first_seen, last_seen,
               trajectory_json, evidence_json, user_verdict, metadata_json
        FROM self_facet
        WHERE 1 = 1
        """
        if !includeArchived {
            sql += " AND status <> 'archived'"
        }
        if kind != nil {
            sql += " AND kind = ?"
        }
        sql += " ORDER BY confidence DESC"

        var stmt: OpaquePointer?
        var results: [[String: Any]] = []

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            if let kind = kind {
                sqlite3_bind_text(stmt, 1, (kind as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(rowToDict(stmt))
            }
        }
        sqlite3_finalize(stmt)
        return results
    }

    /// Fetch a single facet by id, or nil if it doesn't exist.
    func getFacet(id: String) -> [String: Any]? {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db else { return nil }

        let sql = """
        SELECT id, kind, statement, confidence, status, first_seen, last_seen,
               trajectory_json, evidence_json, user_verdict, metadata_json
        FROM self_facet
        WHERE id = ?
        """

        var stmt: OpaquePointer?
        var result: [String: Any]? = nil
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            if sqlite3_step(stmt) == SQLITE_ROW {
                result = rowToDict(stmt)
            }
        }
        sqlite3_finalize(stmt)
        return result
    }

    // MARK: - Trajectory / Evidence

    /// Append a trajectory entry {from, to, date} and bump last_seen to now.
    func appendTrajectory(id: String, from: String, to: String, date: String) -> Bool {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db else { return false }

        // Read the existing trajectory array.
        var trajectory: [[String: String]] = []
        let readSql = "SELECT trajectory_json FROM self_facet WHERE id = ?"
        var readStmt: OpaquePointer?
        var rowExists = false
        if sqlite3_prepare_v2(db, readSql, -1, &readStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(readStmt, 1, (id as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            if sqlite3_step(readStmt) == SQLITE_ROW {
                rowExists = true
                if let json = columnText(readStmt, 0),
                   let decoded = jsonDecode(json) as? [[String: String]] {
                    trajectory = decoded
                }
            }
        }
        sqlite3_finalize(readStmt)
        guard rowExists else { return false }

        trajectory.append(["from": from, "to": to, "date": date])
        let trajectoryJson = jsonEncode(trajectory)
        let now = isoNow()

        let updateSql = "UPDATE self_facet SET trajectory_json = ?, last_seen = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, updateSql, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(stmt, 1, (trajectoryJson as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, (now as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 3, (id as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        let ok = sqlite3_step(stmt) == SQLITE_DONE
        sqlite3_finalize(stmt)
        return ok
    }

    /// Append an evidence entry {source_type, source_id, snippet, ts}.
    func addEvidence(id: String, sourceType: String, sourceId: String, snippet: String, ts: String) -> Bool {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db else { return false }

        // Read the existing evidence array.
        var evidence: [[String: String]] = []
        let readSql = "SELECT evidence_json FROM self_facet WHERE id = ?"
        var readStmt: OpaquePointer?
        var rowExists = false
        if sqlite3_prepare_v2(db, readSql, -1, &readStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(readStmt, 1, (id as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            if sqlite3_step(readStmt) == SQLITE_ROW {
                rowExists = true
                if let json = columnText(readStmt, 0),
                   let decoded = jsonDecode(json) as? [[String: String]] {
                    evidence = decoded
                }
            }
        }
        sqlite3_finalize(readStmt)
        guard rowExists else { return false }

        evidence.append([
            "source_type": sourceType,
            "source_id": sourceId,
            "snippet": snippet,
            "ts": ts
        ])
        let evidenceJson = jsonEncode(evidence)

        let updateSql = "UPDATE self_facet SET evidence_json = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, updateSql, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(stmt, 1, (evidenceJson as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, (id as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        let ok = sqlite3_step(stmt) == SQLITE_DONE
        sqlite3_finalize(stmt)
        return ok
    }

    // MARK: - Mutations

    /// Set (or clear, when verdict is nil) the user's verdict on a facet.
    func setVerdict(id: String, verdict: String?) -> Bool {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db else { return false }

        let sql = "UPDATE self_facet SET user_verdict = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        if let verdict = verdict {
            sqlite3_bind_text(stmt, 1, (verdict as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } else {
            sqlite3_bind_null(stmt, 1)
        }
        sqlite3_bind_text(stmt, 2, (id as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        let ok = sqlite3_step(stmt) == SQLITE_DONE
        sqlite3_finalize(stmt)
        return ok
    }

    /// Update a facet's confidence and last_seen.
    func updateConfidence(id: String, confidence: Double, lastSeen: String) -> Bool {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db else { return false }

        let sql = "UPDATE self_facet SET confidence = ?, last_seen = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_double(stmt, 1, confidence)
        sqlite3_bind_text(stmt, 2, (lastSeen as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 3, (id as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        let ok = sqlite3_step(stmt) == SQLITE_DONE
        sqlite3_finalize(stmt)
        return ok
    }

    /// Archive a facet (status = 'archived').
    func archiveFacet(id: String) -> Bool {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db else { return false }

        let sql = "UPDATE self_facet SET status = 'archived' WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        let ok = sqlite3_step(stmt) == SQLITE_DONE
        sqlite3_finalize(stmt)
        return ok
    }

    /// Permanently delete a facet.
    func deleteFacet(id: String) -> Bool {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db else { return false }

        let sql = "DELETE FROM self_facet WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        let ok = sqlite3_step(stmt) == SQLITE_DONE
        sqlite3_finalize(stmt)
        return ok
    }

    // MARK: - Stats

    /// Count of non-archived facets per kind, e.g. ["pattern": 3, "theme": 6].
    func counts() -> [String: Int] {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db else { return [:] }

        var counts: [String: Int] = [:]
        let sql = "SELECT kind, COUNT(*) FROM self_facet WHERE status <> 'archived' GROUP BY kind"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let kind = columnText(stmt, 0) {
                    counts[kind] = Int(sqlite3_column_int64(stmt, 1))
                }
            }
        }
        sqlite3_finalize(stmt)
        return counts
    }

    // MARK: - Row Mapping

    /// Map a fully-selected self_facet row (11 columns, in schema order) to a dict.
    /// Caller must hold dbLock.
    private func rowToDict(_ stmt: OpaquePointer?) -> [String: Any] {
        var row: [String: Any] = [:]
        row["id"] = columnText(stmt, 0) ?? ""
        row["kind"] = columnText(stmt, 1) ?? ""
        row["statement"] = columnText(stmt, 2) ?? ""
        row["confidence"] = sqlite3_column_double(stmt, 3)
        row["status"] = columnText(stmt, 4) ?? ""
        row["first_seen"] = columnText(stmt, 5)
        row["last_seen"] = columnText(stmt, 6)
        row["trajectory"] = (jsonDecode(columnText(stmt, 7)) as? [[String: String]]) ?? []
        row["evidence"] = (jsonDecode(columnText(stmt, 8)) as? [[String: String]]) ?? []
        if let verdict = columnText(stmt, 9) {
            row["user_verdict"] = verdict
        } else {
            row["user_verdict"] = NSNull()
        }
        row["metadata"] = (jsonDecode(columnText(stmt, 10)) as? [String: String]) ?? [:]
        return row
    }

    // MARK: - Helpers

    private func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let cStr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cStr)
    }

    private func jsonEncode(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let str = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return str
    }

    private func jsonDecode(_ str: String?) -> Any? {
        guard let str = str, let data = str.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}
