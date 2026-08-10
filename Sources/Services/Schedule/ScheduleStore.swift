import Foundation
import SQLite3

/// Persistence for scheduling sessions — the Swift analogue of Commit's store/schedule.go.
/// The full `ScheduleSession` serializes to a JSON `data` column; the hot fields (contact, state,
/// intent, timestamps) are columns for lookup. One open session per contact.
final class ScheduleStore {
    static let shared = ScheduleStore()

    private let dbPath: String
    private var db: OpaquePointer?
    private let lock = NSLock()
    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private lazy var encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }()
    private lazy var decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    init(path: String? = nil) {
        let dir = ProcessInfo.processInfo.environment["ALFRED_DIR"] ?? (NSHomeDirectory() + "/.alfred")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        self.dbPath = path ?? (dir + "/schedule.db")
        if sqlite3_open(dbPath, &db) == SQLITE_OK {
            sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA synchronous=NORMAL", nil, nil, nil)
            createTable()
        } else {
            print("❌ ScheduleStore: failed to open \(dbPath)")
        }
    }

    private func createTable() {
        let sql = """
        CREATE TABLE IF NOT EXISTS schedule_sessions (
            id TEXT PRIMARY KEY,
            contact_jid TEXT NOT NULL,
            contact_name TEXT NOT NULL DEFAULT '',
            state TEXT NOT NULL,
            intent TEXT NOT NULL,
            data TEXT NOT NULL,
            created_at TEXT,
            updated_at TEXT,
            closed_at TEXT,
            close_reason TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_schedule_sessions_contact
            ON schedule_sessions(contact_jid) WHERE state != 'closed';
        """
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    /// A fresh session id.
    static func newID() -> String { "sch_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16) }

    private func text(_ stmt: OpaquePointer?, _ i: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: c)
    }
    private func bindText(_ stmt: OpaquePointer?, _ i: Int32, _ v: String?) {
        if let v = v { sqlite3_bind_text(stmt, i, v, -1, Self.SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, i) }
    }

    /// Insert or replace a session, keeping the columns in sync with the serialized blob.
    @discardableResult
    func save(_ s: ScheduleSession) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let db = db, let data = try? encoder.encode(s), let json = String(data: data, encoding: .utf8) else { return false }
        let iso = ISO8601DateFormatter()
        let sql = """
        INSERT OR REPLACE INTO schedule_sessions
            (id, contact_jid, contact_name, state, intent, data, created_at, updated_at, closed_at, close_reason)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, s.id)
        bindText(stmt, 2, s.contactJID)
        bindText(stmt, 3, s.contactName)
        bindText(stmt, 4, s.state.rawValue)
        bindText(stmt, 5, s.intent.rawValue)
        bindText(stmt, 6, json)
        bindText(stmt, 7, s.createdAt.map { iso.string(from: $0) })
        bindText(stmt, 8, s.updatedAt.map { iso.string(from: $0) } ?? iso.string(from: Date()))
        bindText(stmt, 9, s.state == .closed ? iso.string(from: Date()) : nil)
        bindText(stmt, 10, nil)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private func decodeRow(_ stmt: OpaquePointer?) -> ScheduleSession? {
        guard let json = text(stmt, 0), let data = json.data(using: .utf8) else { return nil }
        return try? decoder.decode(ScheduleSession.self, from: data)
    }

    /// The open (non-closed) session for a contact, if any.
    func openSession(contactJID: String) -> ScheduleSession? {
        lock.lock(); defer { lock.unlock() }
        guard let db = db else { return nil }
        var stmt: OpaquePointer?
        let sql = "SELECT data FROM schedule_sessions WHERE contact_jid = ? AND state != 'closed' ORDER BY created_at DESC LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, contactJID)
        return sqlite3_step(stmt) == SQLITE_ROW ? decodeRow(stmt) : nil
    }

    /// A session by id (open or closed).
    func session(id: String) -> ScheduleSession? {
        lock.lock(); defer { lock.unlock() }
        guard let db = db else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT data FROM schedule_sessions WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, id)
        return sqlite3_step(stmt) == SQLITE_ROW ? decodeRow(stmt) : nil
    }

    /// All open sessions — the watcher iterates these each tick.
    func allOpenSessions() -> [ScheduleSession] {
        lock.lock(); defer { lock.unlock() }
        guard let db = db else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT data FROM schedule_sessions WHERE state != 'closed' ORDER BY created_at DESC", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [ScheduleSession] = []
        while sqlite3_step(stmt) == SQLITE_ROW { if let s = decodeRow(stmt) { out.append(s) } }
        return out
    }
}
