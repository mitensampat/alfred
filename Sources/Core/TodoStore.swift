import Foundation
import SQLite3

/// The one to-do list (docs/rewire/SPEC.md, "to-dos tab and the to-do system").
///
/// Every to-do the user sees lives here, whatever produced it: a commitment extracted from a
/// thread, a note to self from the WhatsApp scan, a one-time import from the old Notion task
/// databases, a capture from the add box, or the open decision on a front. The sources keep
/// running exactly as before; this store sits on top of them, so the extraction pipelines and
/// their closure machinery need no changes.
///
/// Rules the store enforces:
///  - anything EXTRACTED arrives as `suggested` and joins the list only when the user accepts it
///    (decision 2026-11-05: "extracted to-dos always wait in a suggested tray");
///  - things others owe the user are `kind = waiting`; they never appear in the main list, only
///    inside the person or front they belong to;
///  - one promise seen in several places is one to-do (`todo_sources` links every origin);
///  - every change marks the row dirty so the Notion mirror can push it.
final class TodoStore {
    static let shared = TodoStore()

    enum Status: String { case suggested, open, done, dismissed }
    enum Kind: String { case mine, waiting }

    struct Todo {
        var id: String
        var title: String
        var status: Status
        var kind: Kind
        var due: String?            // yyyy-MM-dd
        var frontId: String?
        var frontName: String?
        var person: String?
        var source: String          // commitment | whatsapp_self | notion_import | capture | front_decision | notion_mirror
        var sourceRef: String?
        var sourceNote: String?
        var threadId: String?
        var confidence: Double
        var pinned: Bool
        var snoozedUntil: String?   // yyyy-MM-dd
        var skipCount: Int
        var createdAt: String
        var updatedAt: String
        var doneAt: String?
        var notionPageId: String?
        var dirty: Bool
        var draft: String?

        var dict: [String: Any] {
            var d: [String: Any] = [
                "id": id, "title": title, "status": status.rawValue, "kind": kind.rawValue,
                "source": source, "confidence": confidence, "pinned": pinned, "skip_count": skipCount,
                "created_at": createdAt, "updated_at": updatedAt
            ]
            d["due"] = due as Any? ?? NSNull()
            d["front_id"] = frontId as Any? ?? NSNull()
            d["front_name"] = frontName as Any? ?? NSNull()
            d["person"] = person as Any? ?? NSNull()
            d["source_ref"] = sourceRef as Any? ?? NSNull()
            d["source_note"] = sourceNote as Any? ?? NSNull()
            d["snoozed_until"] = snoozedUntil as Any? ?? NSNull()
            d["done_at"] = doneAt as Any? ?? NSNull()
            d["notion_page_id"] = notionPageId as Any? ?? NSNull()
            d["thread_id"] = threadId as Any? ?? NSNull()
            if let draft = draft { d["draft"] = draft }
            return d
        }
    }

    private var db: OpaquePointer?
    private let lock = NSLock()
    private static let iso = ISO8601DateFormatter()
    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()

    static func today() -> String { dayFormatter.string(from: Date()) }
    static func nowISO() -> String { iso.string(from: Date()) }

    private init() {
        let dir = AlfredPaths.dataURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("todos.db").path
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            print("⚠️ TodoStore: failed to open \(path)")
            return
        }
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
        exec("""
        CREATE TABLE IF NOT EXISTS todos (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            status TEXT NOT NULL,
            kind TEXT NOT NULL DEFAULT 'mine',
            due TEXT,
            front_id TEXT,
            front_name TEXT,
            person TEXT,
            source TEXT NOT NULL,
            source_ref TEXT,
            source_note TEXT,
            thread_id TEXT,
            confidence REAL DEFAULT 1.0,
            pinned INTEGER DEFAULT 0,
            snoozed_until TEXT,
            skip_count INTEGER DEFAULT 0,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            done_at TEXT,
            notion_page_id TEXT,
            dirty INTEGER DEFAULT 1,
            dedupe_key TEXT,
            draft TEXT,
            history TEXT
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS todo_sources (
            todo_id TEXT NOT NULL,
            source TEXT NOT NULL,
            source_ref TEXT NOT NULL,
            linked_at TEXT NOT NULL,
            UNIQUE(source, source_ref)
        )
        """)
        exec("CREATE TABLE IF NOT EXISTS todo_meta (key TEXT PRIMARY KEY, value TEXT)")
        // What the user did with each item: the raw material TodoLearning learns from.
        exec("""
        CREATE TABLE IF NOT EXISTS todo_feedback (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            at TEXT NOT NULL,
            event TEXT NOT NULL,
            todo_id TEXT,
            source TEXT,
            person TEXT,
            title TEXT,
            from_value TEXT,
            to_value TEXT
        )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_feedback_event ON todo_feedback(event, at)")
        // Suggestions Alfred hid on its own (learned from dismissals), with the reason it gives.
        exec("ALTER TABLE todos ADD COLUMN hidden_reason TEXT")
        exec("CREATE INDEX IF NOT EXISTS idx_todos_status ON todos(status, kind)")
        exec("CREATE INDEX IF NOT EXISTS idx_todos_dedupe ON todos(dedupe_key)")
        exec("CREATE INDEX IF NOT EXISTS idx_todos_dirty ON todos(dirty)")
        exec("CREATE INDEX IF NOT EXISTS idx_todos_notion ON todos(notion_page_id)")
    }

    // MARK: - Meta

    func meta(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT value FROM todo_meta WHERE key = ?", -1, &stmt, nil) == SQLITE_OK else { return nil }
        bind(stmt, 1, key)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return col(stmt, 0)
    }

    func setMeta(_ key: String, _ value: String) {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "INSERT INTO todo_meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", -1, &stmt, nil) == SQLITE_OK else { return }
        bind(stmt, 1, key); bind(stmt, 2, value)
        sqlite3_step(stmt)
    }

    // MARK: - Reads

    private static let columns = "id, title, status, kind, due, front_id, front_name, person, source, source_ref, source_note, thread_id, confidence, pinned, snoozed_until, skip_count, created_at, updated_at, done_at, notion_page_id, dirty, draft"

    func all(where clause: String = "1=1", args: [String] = [], order: String = "created_at DESC", limit: Int = 2000) -> [Todo] {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT \(Self.columns) FROM todos WHERE \(clause) ORDER BY \(order) LIMIT \(limit)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        for (i, a) in args.enumerated() { bind(stmt, Int32(i + 1), a) }
        var out: [Todo] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(row(stmt)) }
        return out
    }

    func get(_ id: String) -> Todo? { all(where: "id = ?", args: [id], limit: 1).first }

    func byNotionPage(_ pageId: String) -> Todo? { all(where: "notion_page_id = ?", args: [pageId], limit: 1).first }

    /// The id of the to-do a source item was linked to, if any.
    func linkedTodoId(source: String, ref: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT todo_id FROM todo_sources WHERE source = ? AND source_ref = ?", -1, &stmt, nil) == SQLITE_OK else { return nil }
        bind(stmt, 1, source); bind(stmt, 2, ref)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return col(stmt, 0)
    }

    func sources(of todoId: String) -> [(source: String, ref: String)] {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT source, source_ref FROM todo_sources WHERE todo_id = ?", -1, &stmt, nil) == SQLITE_OK else { return [] }
        bind(stmt, 1, todoId)
        var out: [(String, String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append((col(stmt, 0) ?? "", col(stmt, 1) ?? "")) }
        return out
    }

    /// Open to-dos the user owns (the main list), not snoozed past today.
    func openMine() -> [Todo] {
        all(where: "status = 'open' AND kind = 'mine'", order: "pinned DESC, COALESCE(due, '9999') ASC, created_at ASC")
    }

    func suggestions() -> [Todo] {
        all(where: "status = 'suggested'", order: "created_at DESC", limit: 50)
    }

    func waiting() -> [Todo] {
        all(where: "status = 'open' AND kind = 'waiting'", order: "created_at ASC")
    }

    func dirty() -> [Todo] {
        all(where: "dirty = 1 AND status IN ('open', 'done', 'dismissed') AND kind = 'mine'", order: "updated_at ASC", limit: 50)
    }

    /// How many to-dos are waiting to reach Notion (uncapped, unlike `dirty()`).
    func dirtyCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT COUNT(*) FROM todos WHERE dirty = 1 AND status IN ('open', 'done', 'dismissed') AND kind = 'mine'"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    // MARK: - Writes

    /// Normalised key used to recognise the same promise from several sources.
    static func dedupeKey(title: String, person: String?) -> String {
        let stop: Set<String> = ["the", "a", "an", "to", "for", "on", "of", "and", "with", "my", "your", "re"]
        let words = title.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !stop.contains($0) }
        let p = (person ?? "").lowercased().split(separator: " ").first.map(String.init) ?? ""
        return p + "|" + words.prefix(8).joined(separator: " ")
    }

    /// Insert a to-do, or link this source to an existing one with the same dedupe key.
    /// Returns the to-do id and whether it was newly created.
    @discardableResult
    func upsert(title rawTitle: String, status: Status, kind: Kind = .mine, due: String? = nil,
                frontId: String? = nil, frontName: String? = nil, person: String? = nil,
                source: String, sourceRef: String?, sourceNote: String? = nil,
                threadId: String? = nil, confidence: Double = 1.0, draft: String? = nil) -> (id: String, created: Bool) {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if let ref = sourceRef, let existing = linkedTodoId(source: source, ref: ref) {
            return (existing, false)
        }
        let key = Self.dedupeKey(title: title, person: person)
        // Same promise from another source: link it, do not duplicate. Only live rows count —
        // a done promise that comes back from a new thread is a new to-do.
        if let twin = all(where: "dedupe_key = ? AND status IN ('suggested', 'open') AND kind = ?", args: [key, kind.rawValue], limit: 1).first {
            if let ref = sourceRef { link(todoId: twin.id, source: source, ref: ref) }
            // A user-accepted copy outranks a suggestion: an accepted twin stays accepted.
            return (twin.id, false)
        }
        let id = UUID().uuidString.lowercased()
        let now = Self.nowISO()
        lock.lock()
        var stmt: OpaquePointer?
        let sql = """
        INSERT INTO todos (id, title, status, kind, due, front_id, front_name, person, source, source_ref, source_note,
                           thread_id, confidence, created_at, updated_at, dirty, dedupe_key, draft)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
        """
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            bind(stmt, 1, id); bind(stmt, 2, title); bind(stmt, 3, status.rawValue); bind(stmt, 4, kind.rawValue)
            bindOpt(stmt, 5, due); bindOpt(stmt, 6, frontId); bindOpt(stmt, 7, frontName); bindOpt(stmt, 8, person)
            bind(stmt, 9, source); bindOpt(stmt, 10, sourceRef); bindOpt(stmt, 11, sourceNote); bindOpt(stmt, 12, threadId)
            sqlite3_bind_double(stmt, 13, confidence)
            bind(stmt, 14, now); bind(stmt, 15, now); bind(stmt, 16, key); bindOpt(stmt, 17, draft)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        lock.unlock()
        if let ref = sourceRef { link(todoId: id, source: source, ref: ref) }
        return (id, true)
    }

    func link(todoId: String, source: String, ref: String) {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO todo_sources(todo_id, source, source_ref, linked_at) VALUES(?, ?, ?, ?)", -1, &stmt, nil) == SQLITE_OK else { return }
        bind(stmt, 1, todoId); bind(stmt, 2, source); bind(stmt, 3, ref); bind(stmt, 4, Self.nowISO())
        sqlite3_step(stmt)
    }

    /// Update named fields. `nil` in `fields` clears a column (pass NSNull()).
    /// Every user-visible change marks the row dirty for the Notion mirror unless `markDirty` is false
    /// (used when the change itself came FROM Notion).
    @discardableResult
    func update(_ id: String, _ fields: [String: Any?], markDirty: Bool = true, touch: Bool = true) -> Bool {
        let allowed: Set<String> = ["title", "status", "kind", "due", "front_id", "front_name", "person", "pinned",
                                    "snoozed_until", "skip_count", "done_at", "notion_page_id", "dirty", "draft",
                                    "source_note", "updated_at", "hidden_reason"]
        var sets: [String] = []
        var vals: [Any?] = []
        for (k, v) in fields where allowed.contains(k) {
            sets.append("\(k) = ?"); vals.append(v)
        }
        if touch && fields["updated_at"] == nil { sets.append("updated_at = ?"); vals.append(Self.nowISO()) }
        if markDirty && fields["dirty"] == nil { sets.append("dirty = 1") }
        if fields["title"] != nil || fields["person"] != nil {
            let current = get(id)
            let t = (fields["title"] as? String) ?? current?.title ?? ""
            let p = (fields["person"] as? String) ?? current?.person
            sets.append("dedupe_key = ?"); vals.append(Self.dedupeKey(title: t, person: p))
        }
        guard !sets.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "UPDATE todos SET \(sets.joined(separator: ", ")) WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else { return false }
        var i: Int32 = 1
        for v in vals {
            switch v {
            case let s as String: bind(stmt, i, s)
            case let n as Int: sqlite3_bind_int64(stmt, i, Int64(n))
            case let b as Bool: sqlite3_bind_int64(stmt, i, b ? 1 : 0)
            case let d as Double: sqlite3_bind_double(stmt, i, d)
            default: sqlite3_bind_null(stmt, i)
            }
            i += 1
        }
        bind(stmt, i, id)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    func appendHistory(_ id: String, _ entry: [String: String]) {
        guard let t = all(where: "id = ?", args: [id], limit: 1).first else { return }
        _ = t
        lock.lock(); defer { lock.unlock() }
        var read: OpaquePointer?
        var history: [[String: String]] = []
        if sqlite3_prepare_v2(db, "SELECT history FROM todos WHERE id = ?", -1, &read, nil) == SQLITE_OK {
            bind(read, 1, id)
            if sqlite3_step(read) == SQLITE_ROW, let raw = col(read, 0), let data = raw.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
                history = arr
            }
        }
        sqlite3_finalize(read)
        history.append(entry)
        let json = (try? JSONSerialization.data(withJSONObject: Array(history.suffix(50)))).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "UPDATE todos SET history = ? WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else { return }
        bind(stmt, 1, json); bind(stmt, 2, id)
        sqlite3_step(stmt)
    }

    /// Only one to-do is pinned at a time: it takes the "up next" slot on now.
    func pin(_ id: String?) {
        exec("UPDATE todos SET pinned = 0 WHERE pinned = 1")
        if let id = id { update(id, ["pinned": true], markDirty: false) }
    }

    // MARK: - Feedback

    struct Feedback { let at: String; let event: String; let todoId: String?; let source: String?; let person: String?; let title: String?; let from: String?; let to: String? }

    func recordFeedback(_ event: String, todo: Todo?, from: String? = nil, to: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "INSERT INTO todo_feedback (at, event, todo_id, source, person, title, from_value, to_value) VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        bind(stmt, 1, Self.nowISO()); bind(stmt, 2, event)
        bindOpt(stmt, 3, todo?.id); bindOpt(stmt, 4, todo?.source); bindOpt(stmt, 5, todo?.person); bindOpt(stmt, 6, todo?.title)
        bindOpt(stmt, 7, from); bindOpt(stmt, 8, to)
        sqlite3_step(stmt)
    }

    /// Feedback of the given events within the last `days`, newest first.
    func feedback(events: [String], days: Int = 120, limit: Int = 2000) -> [Feedback] {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let since = Self.iso.string(from: Date().addingTimeInterval(-Double(days) * 86400))
        let marks = events.map { _ in "?" }.joined(separator: ",")
        let sql = "SELECT at, event, todo_id, source, person, title, from_value, to_value FROM todo_feedback WHERE event IN (\(marks)) AND at >= ? ORDER BY at DESC LIMIT \(limit)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        var i: Int32 = 1
        for e in events { bind(stmt, i, e); i += 1 }
        bind(stmt, i, since)
        var out: [Feedback] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(Feedback(at: col(stmt, 0) ?? "", event: col(stmt, 1) ?? "", todoId: col(stmt, 2), source: col(stmt, 3),
                                person: col(stmt, 4), title: col(stmt, 5), from: col(stmt, 6), to: col(stmt, 7)))
        }
        return out
    }

    /// Suggestions Alfred hid on its own in the last `days`.
    func hidden(days: Int = 14) -> [Todo] {
        let since = Self.iso.string(from: Date().addingTimeInterval(-Double(days) * 86400))
        return all(where: "status = 'dismissed' AND hidden_reason IS NOT NULL AND updated_at >= ?", args: [since], order: "updated_at DESC", limit: 50)
    }

    func hiddenReason(_ id: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT hidden_reason FROM todos WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else { return nil }
        bind(stmt, 1, id)
        return sqlite3_step(stmt) == SQLITE_ROW ? col(stmt, 0) : nil
    }

    // MARK: - SQLite helpers

    private func exec(_ sql: String) {
        lock.lock(); defer { lock.unlock() }
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bind(_ stmt: OpaquePointer?, _ i: Int32, _ v: String) {
        sqlite3_bind_text(stmt, i, (v as NSString).utf8String, -1, transient)
    }

    private func bindOpt(_ stmt: OpaquePointer?, _ i: Int32, _ v: String?) {
        if let v = v { bind(stmt, i, v) } else { sqlite3_bind_null(stmt, i) }
    }

    private func col(_ stmt: OpaquePointer?, _ i: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: c)
    }

    private func row(_ s: OpaquePointer?) -> Todo {
        Todo(
            id: col(s, 0) ?? "",
            title: col(s, 1) ?? "",
            status: Status(rawValue: col(s, 2) ?? "") ?? .open,
            kind: Kind(rawValue: col(s, 3) ?? "") ?? .mine,
            due: col(s, 4), frontId: col(s, 5), frontName: col(s, 6), person: col(s, 7),
            source: col(s, 8) ?? "", sourceRef: col(s, 9), sourceNote: col(s, 10), threadId: col(s, 11),
            confidence: sqlite3_column_double(s, 12),
            pinned: sqlite3_column_int64(s, 13) == 1,
            snoozedUntil: col(s, 14),
            skipCount: Int(sqlite3_column_int64(s, 15)),
            createdAt: col(s, 16) ?? "", updatedAt: col(s, 17) ?? "", doneAt: col(s, 18),
            notionPageId: col(s, 19), dirty: sqlite3_column_int64(s, 20) == 1, draft: col(s, 21))
    }
}
