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

        CREATE TABLE IF NOT EXISTS facet_link (
            lens_id TEXT NOT NULL,
            belief_id TEXT NOT NULL,
            created_at TEXT,
            PRIMARY KEY (lens_id, belief_id)
        );
        CREATE INDEX IF NOT EXISTS idx_facet_link_lens ON facet_link(lens_id);
        CREATE INDEX IF NOT EXISTS idx_facet_link_belief ON facet_link(belief_id);

        CREATE TABLE IF NOT EXISTS belief_lineage (
            belief_id TEXT NOT NULL,
            theme_id TEXT NOT NULL,
            created_at TEXT,
            PRIMARY KEY (belief_id, theme_id)
        );
        CREATE INDEX IF NOT EXISTS idx_lineage_belief ON belief_lineage(belief_id);
        CREATE INDEX IF NOT EXISTS idx_lineage_theme ON belief_lineage(theme_id);

        -- Generalised lineage: any facet can crystallize out of a theme, not just beliefs.
        -- Decisions are conclusions reached inside a workspace, so they carry the same edge.
        CREATE TABLE IF NOT EXISTS facet_lineage (
            facet_id TEXT NOT NULL,
            theme_id TEXT NOT NULL,
            created_at TEXT,
            PRIMARY KEY (facet_id, theme_id)
        );
        CREATE INDEX IF NOT EXISTS idx_flineage_facet ON facet_lineage(facet_id);
        CREATE INDEX IF NOT EXISTS idx_flineage_theme ON facet_lineage(theme_id);

        -- Carry the belief edges over; belief_lineage is left in place, unused.
        INSERT OR IGNORE INTO facet_lineage (facet_id, theme_id, created_at)
            SELECT belief_id, theme_id, created_at FROM belief_lineage;

        -- Generalised support: what holds a belief up. Was lens-only (facet_link);
        -- decisions are stronger evidence than anything said to an assistant, so the
        -- edge has to accept both. `kind` records which, since only OBSERVED support
        -- can retire an aspiration.
        CREATE TABLE IF NOT EXISTS facet_support (
            support_id TEXT NOT NULL,
            belief_id TEXT NOT NULL,
            kind TEXT NOT NULL DEFAULT 'lens',
            rationale TEXT,
            created_at TEXT,
            PRIMARY KEY (support_id, belief_id)
        );
        CREATE INDEX IF NOT EXISTS idx_support_belief ON facet_support(belief_id);
        CREATE INDEX IF NOT EXISTS idx_support_src ON facet_support(support_id);

        INSERT OR IGNORE INTO facet_support (support_id, belief_id, kind, created_at)
            SELECT lens_id, belief_id, 'lens', created_at FROM facet_link;

        -- Graduation proposals: a model's guess that a decision evidences a belief.
        -- Never applied automatically — judgement can be wrong in ways counting can't.
        CREATE TABLE IF NOT EXISTS graduation_proposal (
            id TEXT PRIMARY KEY,
            belief_id TEXT NOT NULL,
            decision_id TEXT NOT NULL,
            rationale TEXT,
            status TEXT NOT NULL DEFAULT 'pending',
            created_at TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_gprop_status ON graduation_proposal(status);

        -- Now engagement: how you touch the Now surface. open/capture lift a workspace's
        -- score, snooze/dismiss bury it, both decayed. Makes the surfacing self-correcting
        -- — a bad auto-promotion gets buried by your own behaviour within a week.
        CREATE TABLE IF NOT EXISTS now_engagement (
            workspace_id TEXT NOT NULL,
            event TEXT NOT NULL,
            ts TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_now_eng_ws ON now_engagement(workspace_id);
        """

        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, createFacets, nil, nil, &errMsg) != SQLITE_OK {
            if let err = errMsg {
                print("❌ SelfModelStore: SQL error: \(String(cString: err))")
                sqlite3_free(errMsg)
            }
        }

        // Migration: `origin` distinguishes facets that condensed up from signal
        // ('emergent') from ones the user declared outright ('declared'). SQLite has no
        // ADD COLUMN IF NOT EXISTS, so probe the schema first.
        if !columnExists(table: "self_facet", column: "origin") {
            if sqlite3_exec(db, "ALTER TABLE self_facet ADD COLUMN origin TEXT NOT NULL DEFAULT 'emergent'", nil, nil, nil) == SQLITE_OK {
                print("✅ SelfModelStore: added `origin` column")
            }
        }
        // A user-supplied rename. Kept separate from `statement` because materialize()
        // rebuilds emergent facets from source on every run — an edit written into
        // `statement` would be silently reverted the next time it ran. Same reason
        // user_verdict is preserved rather than recomputed.
        if !columnExists(table: "self_facet", column: "user_statement") {
            if sqlite3_exec(db, "ALTER TABLE self_facet ADD COLUMN user_statement TEXT", nil, nil, nil) == SQLITE_OK {
                print("✅ SelfModelStore: added `user_statement` column")
            }
        }

        print("✅ SelfModelStore database initialized")
    }

    private func columnExists(table: String, column: String) -> Bool {
        guard let db = db else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK else { return false }
        var found = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = columnText(stmt, 1), name == column { found = true; break }
        }
        sqlite3_finalize(stmt)
        return found
    }

    // MARK: - User edits

    /// Rename a facet. Stored separately from `statement` so materialize() can keep
    /// rebuilding the synthesized text underneath without clobbering the edit.
    /// Passing nil clears the rename and the synthesized text shows through again.
    @discardableResult
    func setUserStatement(id: String, statement: String?) -> Bool {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE self_facet SET user_statement = ? WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else { return false }
        if let s = statement, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sqlite3_bind_text(stmt, 1, (s as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } else { sqlite3_bind_null(stmt, 1) }
        sqlite3_bind_text(stmt, 2, (id as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        let ok = sqlite3_step(stmt) == SQLITE_DONE
        sqlite3_finalize(stmt)
        return ok
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
        metadata: [String: String],
        origin: String = "emergent"
    ) -> Bool {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db else { return false }

        // Preserve verdict AND any user rename — REPLACE would otherwise erase both,
        // so every materialize() would silently undo the user's edits.
        var existingVerdict: String? = nil
        var existingUserStatement: String? = nil
        let verdictSql = "SELECT user_verdict, user_statement FROM self_facet WHERE id = ?"
        var vStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, verdictSql, -1, &vStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(vStmt, 1, (id as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            if sqlite3_step(vStmt) == SQLITE_ROW {
                existingVerdict = columnText(vStmt, 0)
                existingUserStatement = columnText(vStmt, 1)
            }
        }
        sqlite3_finalize(vStmt)

        let trajectoryJson = jsonEncode(trajectory)
        let evidenceJson = jsonEncode(evidence)
        let metadataJson = jsonEncode(metadata)

        let sql = """
        INSERT OR REPLACE INTO self_facet
            (id, kind, statement, confidence, status, first_seen, last_seen, trajectory_json, evidence_json, user_verdict, metadata_json, origin, user_statement)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
        sqlite3_bind_text(stmt, 12, (origin as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        if let us = existingUserStatement {
            sqlite3_bind_text(stmt, 13, (us as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } else { sqlite3_bind_null(stmt, 13) }

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
               trajectory_json, evidence_json, user_verdict, metadata_json, origin, user_statement
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
               trajectory_json, evidence_json, user_verdict, metadata_json, origin, user_statement
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

    // MARK: - Lens ↔ Belief links (many-to-many)
    //
    // A lens (pattern) is how a belief shows up in behaviour. Links live in their own
    // table so materialize() — which upserts facets — never disturbs them. Many-to-many:
    // a lens can support several beliefs, and a belief can hold several lenses.

    /// Attach a lens to a belief. Idempotent.
    func linkLens(lensId: String, beliefId: String) -> Bool {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db else { return false }

        let sql = "INSERT OR IGNORE INTO facet_link (lens_id, belief_id, created_at) VALUES (?, ?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(stmt, 1, (lensId as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, (beliefId as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 3, (isoNow() as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        let ok = sqlite3_step(stmt) == SQLITE_DONE
        sqlite3_finalize(stmt)
        return ok
    }

    /// Detach a lens from a belief.
    func unlinkLens(lensId: String, beliefId: String) -> Bool {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db else { return false }

        let sql = "DELETE FROM facet_link WHERE lens_id = ? AND belief_id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(stmt, 1, (lensId as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, (beliefId as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        let ok = sqlite3_step(stmt) == SQLITE_DONE
        sqlite3_finalize(stmt)
        return ok
    }

    /// Move a lens from one belief to another (unlink + link).
    func moveLens(lensId: String, fromBeliefId: String, toBeliefId: String) -> Bool {
        let removed = unlinkLens(lensId: lensId, beliefId: fromBeliefId)
        let added = linkLens(lensId: lensId, beliefId: toBeliefId)
        return removed || added
    }

    /// Ids of lenses attached to a belief.
    func getLensIds(forBelief beliefId: String) -> [String] {
        return linkedIds(sql: "SELECT lens_id FROM facet_link WHERE belief_id = ? ORDER BY created_at", key: beliefId)
    }

    /// Ids of beliefs a lens is attached to.
    func getBeliefIds(forLens lensId: String) -> [String] {
        return linkedIds(sql: "SELECT belief_id FROM facet_link WHERE lens_id = ? ORDER BY created_at", key: lensId)
    }

    /// All links as (lens_id, belief_id) pairs — lets callers build both directions in one read.
    func allLinks() -> [(lens: String, belief: String)] {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db else { return [] }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT lens_id, belief_id FROM facet_link", -1, &stmt, nil) == SQLITE_OK else { return [] }
        var out: [(lens: String, belief: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let l = columnText(stmt, 0) ?? ""
            let b = columnText(stmt, 1) ?? ""
            if !l.isEmpty && !b.isEmpty { out.append((lens: l, belief: b)) }
        }
        sqlite3_finalize(stmt)
        return out
    }

    private func linkedIds(sql: String, key: String) -> [String] {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db else { return [] }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let v = columnText(stmt, 0), !v.isEmpty { out.append(v) }
        }
        sqlite3_finalize(stmt)
        return out
    }

    // MARK: - Lineage (which theme did this facet crystallize out of?)
    //
    // Themes are the organic workstreams. Beliefs firm up around them and decisions are
    // reached inside them, so both carry the same ancestry edge — a facet can always
    // answer "where did I come from".

    /// Record that a facet crystallized from a theme. Idempotent.
    func linkFacetToTheme(facetId: String, themeId: String) -> Bool {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db else { return false }

        let sql = "INSERT OR IGNORE INTO facet_lineage (facet_id, theme_id, created_at) VALUES (?, ?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(stmt, 1, (facetId as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, (themeId as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 3, (isoNow() as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        let ok = sqlite3_step(stmt) == SQLITE_DONE
        sqlite3_finalize(stmt)
        return ok
    }

    /// Remove a facet↔theme lineage edge.
    func unlinkFacetFromTheme(facetId: String, themeId: String) -> Bool {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db else { return false }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM facet_lineage WHERE facet_id = ? AND theme_id = ?", -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(stmt, 1, (facetId as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, (themeId as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        let ok = sqlite3_step(stmt) == SQLITE_DONE
        sqlite3_finalize(stmt)
        return ok
    }

    /// All lineage edges as (facet_id, theme_id) pairs.
    func allLineage() -> [(facet: String, theme: String)] {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db else { return [] }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT facet_id, theme_id FROM facet_lineage", -1, &stmt, nil) == SQLITE_OK else { return [] }
        var out: [(facet: String, theme: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let f = columnText(stmt, 0) ?? ""
            let t = columnText(stmt, 1) ?? ""
            if !f.isEmpty && !t.isEmpty { out.append((facet: f, theme: t)) }
        }
        sqlite3_finalize(stmt)
        return out
    }

    // MARK: - Support (what holds a belief up)

    /// Attach a lens or a decision to a belief as supporting evidence.
    @discardableResult
    func addSupport(supportId: String, beliefId: String, kind: String, rationale: String? = nil) -> Bool {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO facet_support (support_id, belief_id, kind, rationale, created_at) VALUES (?, ?, ?, ?, ?)", -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(stmt, 1, (supportId as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, (beliefId as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 3, (kind as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        if let r = rationale {
            sqlite3_bind_text(stmt, 4, (r as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } else { sqlite3_bind_null(stmt, 4) }
        sqlite3_bind_text(stmt, 5, (isoNow() as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        let ok = sqlite3_step(stmt) == SQLITE_DONE
        sqlite3_finalize(stmt)
        return ok
    }

    /// All support edges: (support_id, belief_id, kind, rationale).
    func allSupport() -> [(support: String, belief: String, kind: String, rationale: String?)] {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT support_id, belief_id, kind, rationale FROM facet_support", -1, &stmt, nil) == SQLITE_OK else { return [] }
        var out: [(support: String, belief: String, kind: String, rationale: String?)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append((support: columnText(stmt, 0) ?? "", belief: columnText(stmt, 1) ?? "",
                        kind: columnText(stmt, 2) ?? "lens", rationale: columnText(stmt, 3)))
        }
        sqlite3_finalize(stmt)
        return out
    }

    // MARK: - Graduation proposals

    @discardableResult
    func addProposal(id: String, beliefId: String, decisionId: String, rationale: String) -> Bool {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO graduation_proposal (id, belief_id, decision_id, rationale, status, created_at) VALUES (?, ?, ?, ?, 'pending', ?)", -1, &stmt, nil) == SQLITE_OK else { return false }
        for (i, v) in [id, beliefId, decisionId, rationale, isoNow()].enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), (v as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        let ok = sqlite3_step(stmt) == SQLITE_DONE
        sqlite3_finalize(stmt)
        return ok
    }

    func getProposals(status: String = "pending") -> [[String: Any]] {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, belief_id, decision_id, rationale FROM graduation_proposal WHERE status = ? ORDER BY created_at DESC", -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, (status as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        var out: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(["id": columnText(stmt, 0) ?? "", "belief_id": columnText(stmt, 1) ?? "",
                        "decision_id": columnText(stmt, 2) ?? "", "rationale": columnText(stmt, 3) ?? ""])
        }
        sqlite3_finalize(stmt)
        return out
    }

    @discardableResult
    func setProposalStatus(id: String, status: String) -> Bool {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE graduation_proposal SET status = ? WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(stmt, 1, (status as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, (id as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        let ok = sqlite3_step(stmt) == SQLITE_DONE
        sqlite3_finalize(stmt)
        return ok
    }

    // MARK: - Now engagement

    /// Record a Now interaction (open / capture / snooze / dismiss) against a workspace.
    func logEngagement(workspaceId: String, event: String) {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO now_engagement (workspace_id, event, ts) VALUES (?, ?, ?)", -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, (workspaceId as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, (event as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 3, (isoNow() as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    /// All engagement events (workspace_id, event, ts) for computing weights.
    func engagementEvents() -> [(workspace: String, event: String, ts: String)] {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT workspace_id, event, ts FROM now_engagement", -1, &stmt, nil) == SQLITE_OK else { return [] }
        var out: [(workspace: String, event: String, ts: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append((workspace: columnText(stmt, 0) ?? "", event: columnText(stmt, 1) ?? "", ts: columnText(stmt, 2) ?? ""))
        }
        sqlite3_finalize(stmt)
        return out
    }

    /// Count of recent manual captures (note/task/decision) linked to each theme, for the
    /// "authored" signal — items *you* put into a workspace.
    func captureCountsByTheme(sinceDays: Int) -> [String: Int] {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db else { return [:] }
        let sql = """
        SELECT l.theme_id, COUNT(*) FROM facet_lineage l
        JOIN self_facet f ON f.id = l.facet_id
        WHERE f.origin = 'manual' AND f.metadata_json LIKE '%"captured_from":"now"%'
          AND f.first_seen >= datetime('now', '-\(sinceDays) days')
        GROUP BY l.theme_id
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        var out: [String: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let t = columnText(stmt, 0) { out[t] = Int(sqlite3_column_int64(stmt, 1)) }
        }
        sqlite3_finalize(stmt)
        return out
    }

    /// Wrap a bulk write in a transaction — materializing 1,000+ decisions one statement
    /// at a time is otherwise slow enough to be felt on the read path.
    func beginBulk() { dbLock.lock(); defer { dbLock.unlock() }
        if let db = db { sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) } }
    func endBulk() { dbLock.lock(); defer { dbLock.unlock() }
        if let db = db { sqlite3_exec(db, "COMMIT", nil, nil, nil) } }

    /// Remove every link touching a facet (used when a facet is deleted).
    func clearLinks(forFacet id: String) {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db else { return }

        let sql = "DELETE FROM facet_link WHERE lens_id = ? OR belief_id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, (id as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
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

    /// Permanently delete a facet and every edge touching it.
    ///
    /// Only meaningful for manual facets — an emergent one would be recreated by the
    /// next materialize(), so those are dismissed via user_verdict instead. Edges are
    /// cleared here too; deleting only the row left lineage and support pointing at
    /// something that no longer exists.
    func deleteFacet(id: String) -> Bool {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db else { return false }

        // (sql, number of ? placeholders)
        let statements: [(String, Int)] = [
            ("DELETE FROM self_facet WHERE id = ?", 1),
            ("DELETE FROM facet_lineage WHERE facet_id = ? OR theme_id = ?", 2),
            ("DELETE FROM facet_support WHERE support_id = ? OR belief_id = ?", 2),
            ("DELETE FROM facet_link WHERE lens_id = ? OR belief_id = ?", 2)
        ]
        var ok = false
        for (sql, binds) in statements {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            for i in 1...binds {
                sqlite3_bind_text(stmt, Int32(i), (id as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            let done = sqlite3_step(stmt) == SQLITE_DONE
            if sql.contains("self_facet") { ok = done }
            sqlite3_finalize(stmt)
        }
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
        row["origin"] = columnText(stmt, 11) ?? "emergent"
        // A user rename wins over the synthesized text everywhere it's read.
        if let us = columnText(stmt, 12), !us.isEmpty {
            row["statement"] = us
            row["renamed"] = true
        }
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
