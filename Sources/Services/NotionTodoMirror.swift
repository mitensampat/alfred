import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Two-way mirror between TodoStore and ONE new Notion database (decision 2026-11-05: a new
/// database; the old task databases are imported once and then left alone).
///
///  - Alfred → Notion: every dirty to-do is pushed within a minute (create, edit, done, dropped).
///  - Notion → Alfred: pages edited since the last pull are read every 5 minutes. The most recent
///    edit wins; the losing value is kept in the to-do's history. A page created in Notion becomes
///    an open to-do in Alfred.
///
/// Only the user's own, accepted to-dos are mirrored: suggestions and "waiting on" items stay in Alfred.
enum NotionTodoMirror {
    static let version = "2022-06-28"
    static let pushEvery: UInt64 = 60
    static let pullEvery: UInt64 = 300

    struct Page { let id: String; let title: String; let due: String?; let status: String?; let lastEdited: String; let alfredId: String? }

    enum MirrorError: Error, CustomStringConvertible {
        case noParent, http(Int, String), noDatabase, partial(Int, String)
        var description: String {
            switch self {
            case .noParent: return "Notion needs a parent page for the to-do mirror. Share a page with the integration and set it in Connections."
            case .http(let c, let b): return "Notion returned \(c): \(b.prefix(200))"
            case .noDatabase: return "The Notion to-do mirror is not set up yet."
            case .partial(let n, let first): return "\(n) to-do\(n == 1 ? "" : "s") did not reach Notion. First: \(first)"
            }
        }
    }

    // MARK: - Loop

    private static var started = false

    /// Start the background push/pull loop. Safe to call more than once.
    static func start(notion: @escaping () async -> NotionService?, importFrom: @escaping () -> [String]) {
        guard !started else { return }
        started = true
        Task {
            try? await Task.sleep(nanoseconds: 20 * 1_000_000_000)
            var sincePull: UInt64 = pullEvery
            while true {
                if let n = await notion() {
                    do {
                        _ = try await ensureDatabase(notion: n)
                        if TodoStore.shared.meta("notion_imported") == nil {
                            let added = await TodoService.importNotionTasks(notion: n, databaseIds: importFrom())
                            if added > 0 { print("📥 Imported \(added) open task(s) from the old Notion databases") }
                        }
                        try await push(notion: n)
                        if sincePull >= pullEvery { try await pull(notion: n); sincePull = 0 }
                        TodoStore.shared.setMeta("notion_mirror_error", "")
                    } catch {
                        TodoStore.shared.setMeta("notion_mirror_error", "\(error)")
                    }
                }
                try? await Task.sleep(nanoseconds: pushEvery * 1_000_000_000)
                sincePull += pushEvery
            }
        }
    }

    static func status() -> [String: Any] {
        let s = TodoStore.shared
        let err = s.meta("notion_mirror_error") ?? ""
        return ["database_id": s.meta("notion_mirror_db") as Any? ?? NSNull(),
                "last_push": s.meta("notion_last_push") as Any? ?? NSNull(),
                "last_pull": s.meta("notion_last_pull") as Any? ?? NSNull(),
                "error": err.isEmpty ? NSNull() : err as Any,
                "pending": s.dirtyCount(),
                "ok": err.isEmpty && s.meta("notion_mirror_db") != nil]
    }

    // MARK: - Database

    /// The mirror database id, creating it under `parentPageId` (or the parent of the old tasks
    /// database) the first time.
    @discardableResult
    static func ensureDatabase(notion: NotionService, parentPageId: String? = nil) async throws -> String {
        if let id = TodoStore.shared.meta("notion_mirror_db"), !id.isEmpty { return id }
        var parent = parentPageId ?? TodoStore.shared.meta("notion_mirror_parent")
        if parent == nil, let tasksDb = notion.tasksDatabaseId {
            let info = try await request(notion: notion, "GET", "databases/\(tasksDb)")
            if let p = info["parent"] as? [String: Any], (p["type"] as? String) == "page_id" {
                parent = p["page_id"] as? String
            }
        }
        guard let parentId = parent, !parentId.isEmpty else { throw MirrorError.noParent }
        let body: [String: Any] = [
            "parent": ["type": "page_id", "page_id": parentId],
            "title": [["type": "text", "text": ["content": "Alfred to-dos"]]],
            "properties": [
                "Name": ["title": [String: Any]()],
                "Status": ["select": ["options": [
                    ["name": "Open", "color": "green"], ["name": "Done", "color": "gray"], ["name": "Dropped", "color": "brown"]]]],
                "Due": ["date": [String: Any]()],
                "Front": ["rich_text": [String: Any]()],
                "Person": ["rich_text": [String: Any]()],
                "Source": ["rich_text": [String: Any]()],
                "Alfred ID": ["rich_text": [String: Any]()]
            ]
        ]
        let created = try await request(notion: notion, "POST", "databases", body)
        guard let id = created["id"] as? String else { throw MirrorError.noDatabase }
        TodoStore.shared.setMeta("notion_mirror_db", id)
        TodoStore.shared.setMeta("notion_mirror_parent", parentId)
        print("🗂️ Created the Notion to-do mirror database \(id)")
        return id
    }

    // MARK: - Push

    /// Push every dirty to-do. One row that Notion rejects must never stop the others: `dirty()` is
    /// ordered oldest-first, so a single to-do whose page was deleted in Notion would otherwise throw
    /// on every cycle and block the whole queue for ever.
    static func push(notion: NotionService) async throws {
        guard let dbId = TodoStore.shared.meta("notion_mirror_db") else { throw MirrorError.noDatabase }
        let store = TodoStore.shared
        var failures: [String] = []
        for t in store.dirty() {
            do {
                try await pushOne(t, dbId: dbId, notion: notion)
            } catch {
                var code: Int? = nil
                if let m = error as? MirrorError, case .http(let c, _) = m { code = c }
                // Rate limits, Notion outages and network errors must stay dirty and retry.
                let transient = code.map { $0 == 429 || (500..<600).contains($0) } ?? true
                if (code == 404 || code == 410), t.notionPageId != nil {
                    // The page is gone in Notion: forget it, and the next cycle re-creates it.
                    store.update(t.id, ["notion_page_id": NSNull()], markDirty: false, touch: false)
                } else if !transient {
                    // A request Notion will never accept. Stop retrying it once a minute for ever.
                    store.update(t.id, ["dirty": 0], markDirty: false, touch: false)
                    store.appendHistory(t.id, ["at": TodoStore.nowISO(), "event": "Notion refused this to-do",
                                               "error": String("\(error)".prefix(200))])
                }
                failures.append(String(t.title.prefix(40)) + ": " + String("\(error)".prefix(120)))
            }
        }
        store.setMeta("notion_last_push", TodoStore.nowISO())
        if !failures.isEmpty { throw MirrorError.partial(failures.count, failures[0]) }
    }

    private static func pushOne(_ t: TodoStore.Todo, dbId: String, notion: NotionService) async throws {
        let store = TodoStore.shared
        let props = properties(for: t)
        if let pageId = t.notionPageId {
            settle(t.id, try await request(notion: notion, "PATCH", "pages/\(pageId)", ["properties": props]))
        } else if t.status == .open {
            let res = try await request(notion: notion, "POST", "pages", ["parent": ["database_id": dbId], "properties": props])
            if let pid = res["id"] as? String { store.update(t.id, ["notion_page_id": pid], markDirty: false, touch: false) }
            settle(t.id, res)
        } else {
            // Done or dropped before it ever reached Notion: nothing to mirror.
            store.update(t.id, ["dirty": 0], markDirty: false, touch: false)
        }
    }

    /// After a write, adopt Notion's own edit time so the next pull does not see our write as theirs.
    private static func settle(_ id: String, _ res: [String: Any]) {
        var f: [String: Any?] = ["dirty": 0]
        if let edited = res["last_edited_time"] as? String { f["updated_at"] = normalize(edited) }
        TodoStore.shared.update(id, f, markDirty: false, touch: false)
    }

    static func properties(for t: TodoStore.Todo) -> [String: Any] {
        func text(_ s: String?) -> [String: Any] { ["rich_text": s.map { [["type": "text", "text": ["content": String($0.prefix(1900))]]] } ?? []] }
        let status: String = t.status == .done ? "Done" : (t.status == .dismissed ? "Dropped" : "Open")
        var p: [String: Any] = [
            "Name": ["title": [["type": "text", "text": ["content": String(t.title.prefix(1900))]]]],
            "Status": ["select": ["name": status]],
            "Front": text(t.frontName),
            "Person": text(t.person),
            "Source": text(t.sourceNote ?? t.source),
            "Alfred ID": text(t.id)
        ]
        p["Due"] = t.due.map { ["date": ["start": $0]] } ?? ["date": NSNull()]
        return p
    }

    // MARK: - Pull

    static func pull(notion: NotionService) async throws {
        guard let dbId = TodoStore.shared.meta("notion_mirror_db") else { throw MirrorError.noDatabase }
        let store = TodoStore.shared
        let since = store.meta("notion_last_pull") ?? "2000-01-01T00:00:00Z"
        let started = TodoStore.nowISO()
        var cursor: String? = nil
        repeat {
            var body: [String: Any] = [
                "filter": ["timestamp": "last_edited_time", "last_edited_time": ["on_or_after": since]],
                "page_size": 100
            ]
            if let c = cursor { body["start_cursor"] = c }
            let res = try await request(notion: notion, "POST", "databases/\(dbId)/query", body)
            for raw in (res["results"] as? [[String: Any]]) ?? [] { apply(page(from: raw)) }
            cursor = (res["has_more"] as? Bool) == true ? res["next_cursor"] as? String : nil
        } while cursor != nil
        store.setMeta("notion_last_pull", started)
    }

    /// Apply one Notion page. Most recent edit wins; the losing value goes into history.
    static func apply(_ p: Page) {
        let store = TodoStore.shared
        let todo = store.byNotionPage(p.id) ?? p.alfredId.flatMap { store.get($0) }
        let status: TodoStore.Status = p.status == "Done" ? .done : (p.status == "Dropped" ? .dismissed : .open)
        guard let t = todo else {
            guard status == .open, !p.title.isEmpty else { return }
            let r = store.upsert(title: p.title, status: .open, due: p.due, source: "notion_mirror", sourceRef: p.id,
                                 sourceNote: "Added in Notion")
            store.update(r.id, ["notion_page_id": p.id, "dirty": 0, "updated_at": normalize(p.lastEdited)], markDirty: false, touch: false)
            return
        }
        let notionNewer = normalize(p.lastEdited) > t.updatedAt
        let differs = p.title != t.title || p.due != t.due || status != t.status
        guard differs else { return }
        if notionNewer && !t.dirty {
            store.appendHistory(t.id, ["at": TodoStore.nowISO(), "event": "Notion edit won",
                                       "was": "\(t.title) | \(t.due ?? "-") | \(t.status.rawValue)"])
            var f: [String: Any?] = ["title": p.title, "due": p.due ?? NSNull(), "status": status.rawValue,
                                     "updated_at": normalize(p.lastEdited), "dirty": 0]
            if status == .done && t.status != .done { f["done_at"] = TodoStore.nowISO() }
            store.update(t.id, f, markDirty: false, touch: false)
            if status == .done {
                for s in store.sources(of: t.id) where s.source == "commitment" {
                    CommitmentScanTracker.shared.markCommitmentClosed(hash: s.ref, closureMethod: "done_in_notion")
                }
            }
        } else {
            store.appendHistory(t.id, ["at": TodoStore.nowISO(), "event": "Alfred edit won over Notion",
                                       "was": "\(p.title) | \(p.due ?? "-") | \(p.status ?? "-")"])
            store.update(t.id, ["dirty": 1], markDirty: false, touch: false)
        }
    }

    static func page(from raw: [String: Any]) -> Page {
        let props = (raw["properties"] as? [String: Any]) ?? [:]
        var title = "", due: String? = nil, status: String? = nil, alfredId: String? = nil
        var otherDate: String? = nil
        for (name, value) in props {
            guard let v = value as? [String: Any], let type = v["type"] as? String else { continue }
            switch type {
            case "title":
                title = ((v["title"] as? [[String: Any]]) ?? []).compactMap { $0["plain_text"] as? String }.joined()
            case "date":
                // Prefer the property actually named "Due". Dictionary order is arbitrary, so an old
                // task database with several date fields ("Created", "Reviewed", …) could otherwise
                // import whichever one happened to come out first.
                if let d = v["date"] as? [String: Any], let s = d["start"] as? String {
                    if name.lowercased() == "due" { due = String(s.prefix(10)) }
                    else if otherDate == nil { otherDate = String(s.prefix(10)) }
                }
            case "select":
                if name == "Status" { status = (v["select"] as? [String: Any])?["name"] as? String }
            case "status":
                if status == nil { status = (v["status"] as? [String: Any])?["name"] as? String }
            case "rich_text":
                if name == "Alfred ID" {
                    alfredId = ((v["rich_text"] as? [[String: Any]]) ?? []).compactMap { $0["plain_text"] as? String }.joined().trimmedNonEmpty
                }
            default: break
            }
        }
        return Page(id: raw["id"] as? String ?? "", title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                    due: due ?? otherDate, status: status,
                    lastEdited: raw["last_edited_time"] as? String ?? "", alfredId: alfredId)
    }

    /// Open pages from one of the OLD task databases (the one-time import).
    static func queryOpenPages(notion: NotionService, databaseId: String) async throws -> [Page] {
        let filters = await notion.notFinishedStatusFilters(databaseId: databaseId)
        var out: [Page] = []
        var cursor: String? = nil
        repeat {
            var body: [String: Any] = ["page_size": 100]
            if !filters.isEmpty { body["filter"] = ["and": filters] }
            if let c = cursor { body["start_cursor"] = c }
            let res = try await request(notion: notion, "POST", "databases/\(databaseId)/query", body)
            out += ((res["results"] as? [[String: Any]]) ?? []).map { page(from: $0) }.filter { !$0.title.isEmpty }
            cursor = (res["has_more"] as? Bool) == true ? res["next_cursor"] as? String : nil
        } while cursor != nil && out.count < 500
        return out
    }

    // MARK: - HTTP

    static func request(notion: NotionService, _ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://api.notion.com/v1/\(path)")!)
        req.httpMethod = method
        req.setValue("Bearer \(notion.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue(version, forHTTPHeaderField: "Notion-Version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let b = body { req.httpBody = try JSONSerialization.data(withJSONObject: b) }
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw MirrorError.http(code, String(data: data, encoding: .utf8) ?? "") }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Notion times carry milliseconds ("2026-11-05T09:12:00.000Z"); TodoStore keeps whole seconds.
    static func normalize(_ s: String) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return ISO8601DateFormatter().string(from: d) }
        return s
    }
}
