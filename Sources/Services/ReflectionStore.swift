import Foundation
import SQLite3

/// ReflectionStore - Stores and queries reflection data from multiple sources
/// Sources: Chrome browsing history, YouTube transcripts, Notion notes, Claude exports, conversations, manual input
/// Provides formatted context injection for coaching prompts ("What's on your mind")
class ReflectionStore {
    static let shared = ReflectionStore()

    private let dbPath: String
    private var db: OpaquePointer?
    private let dbLock = NSLock()
    private let fileManager = FileManager.default

    // MARK: - Initialization

    private init() {
        let homeDir = NSHomeDirectory()
        let alfredDir = "\(homeDir)/.alfred"

        try? fileManager.createDirectory(atPath: alfredDir, withIntermediateDirectories: true)

        dbPath = "\(alfredDir)/reflection.db"

        if sqlite3_open(dbPath, &db) == SQLITE_OK {
            sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA synchronous=NORMAL", nil, nil, nil)
            initializeDatabase()
        } else {
            print("❌ ReflectionStore: Failed to open database")
        }
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    private func initializeDatabase() {
        let createReflections = """
        CREATE TABLE IF NOT EXISTS reflections (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            source TEXT NOT NULL,
            source_id TEXT,
            content_summary TEXT NOT NULL,
            themes_json TEXT,
            theme_classifications_json TEXT,
            open_questions_json TEXT,
            mental_model_shifts_json TEXT,
            decisions_json TEXT,
            relevance_score REAL DEFAULT 1.0,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            last_accessed DATETIME
        );
        CREATE INDEX IF NOT EXISTS idx_reflection_source ON reflections(source);
        CREATE INDEX IF NOT EXISTS idx_reflection_created ON reflections(created_at);
        CREATE UNIQUE INDEX IF NOT EXISTS idx_reflection_source_id ON reflections(source, source_id);
        """

        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, createReflections, nil, nil, &errMsg) != SQLITE_OK {
            if let err = errMsg {
                print("❌ ReflectionStore: SQL error: \(String(cString: err))")
                sqlite3_free(errMsg)
            }
        }

        let createThemeStates = """
        CREATE TABLE IF NOT EXISTS theme_states (
            theme TEXT PRIMARY KEY,
            state TEXT NOT NULL DEFAULT 'researching',
            state_history_json TEXT DEFAULT '[]',
            summary TEXT,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        """

        if sqlite3_exec(db, createThemeStates, nil, nil, &errMsg) != SQLITE_OK {
            if let err = errMsg {
                print("❌ ReflectionStore: SQL error creating theme_states: \(String(cString: err))")
                sqlite3_free(errMsg)
            }
        }

        print("✅ ReflectionStore database initialized")
    }

    // MARK: - Insert / Upsert

    /// Insert a reflection, or update if source+source_id already exists
    func insertReflection(
        source: String,
        sourceId: String,
        contentSummary: String,
        themes: [String],
        themeClassifications: [String: String],
        openQuestions: [String],
        mentalModelShifts: [[String: String]],
        decisions: [String]
    ) {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db else { return }

        let themesJson = jsonEncode(themes)
        let classificationsJson = jsonEncode(themeClassifications)
        let questionsJson = jsonEncode(openQuestions)
        let shiftsJson = jsonEncode(mentalModelShifts)
        let decisionsJson = jsonEncode(decisions)

        let sql = """
        INSERT INTO reflections (source, source_id, content_summary, themes_json, theme_classifications_json, open_questions_json, mental_model_shifts_json, decisions_json, relevance_score)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1.0)
        ON CONFLICT(source, source_id) DO UPDATE SET
            content_summary = excluded.content_summary,
            themes_json = excluded.themes_json,
            theme_classifications_json = excluded.theme_classifications_json,
            open_questions_json = excluded.open_questions_json,
            mental_model_shifts_json = excluded.mental_model_shifts_json,
            decisions_json = excluded.decisions_json,
            relevance_score = 1.0
        """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (source as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 2, (sourceId as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 3, (contentSummary as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 4, (themesJson as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 5, (classificationsJson as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 6, (questionsJson as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 7, (shiftsJson as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 8, (decisionsJson as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            if sqlite3_step(stmt) != SQLITE_DONE {
                print("❌ ReflectionStore: Failed to insert reflection")
            }
        }
        sqlite3_finalize(stmt)
    }

    // MARK: - Queries

    /// Get recent reflections, optionally filtered by source
    func getRecentReflections(limit: Int = 20, days: Int = 14, source: String? = nil) -> [[String: Any]] {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db else { return [] }

        var sql = """
        SELECT id, source, source_id, content_summary, themes_json, theme_classifications_json,
               open_questions_json, mental_model_shifts_json, decisions_json,
               relevance_score, created_at
        FROM reflections
        WHERE created_at >= datetime('now', '-\(days) days')
        """
        if source != nil {
            sql += " AND source = ?"
        }
        sql += " ORDER BY created_at DESC LIMIT \(limit)"

        var stmt: OpaquePointer?
        var results: [[String: Any]] = []

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            if let source = source {
                sqlite3_bind_text(stmt, 1, (source as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }

            while sqlite3_step(stmt) == SQLITE_ROW {
                var row: [String: Any] = [:]
                row["id"] = Int(sqlite3_column_int64(stmt, 0))
                row["source"] = columnText(stmt, 1)
                row["source_id"] = columnText(stmt, 2)
                row["content_summary"] = columnText(stmt, 3)
                row["themes"] = jsonDecode(columnText(stmt, 4)) ?? []
                row["theme_classifications"] = jsonDecode(columnText(stmt, 5)) ?? [:]
                row["open_questions"] = jsonDecode(columnText(stmt, 6)) ?? []
                row["mental_model_shifts"] = jsonDecode(columnText(stmt, 7)) ?? []
                row["decisions"] = jsonDecode(columnText(stmt, 8)) ?? []
                row["relevance_score"] = sqlite3_column_double(stmt, 9)
                row["created_at"] = columnText(stmt, 10)
                results.append(row)
            }
        }
        sqlite3_finalize(stmt)
        return results
    }

    /// Get all existing theme strings for normalization during extraction
    func getExistingThemes() -> [String] {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db else { return [] }

        let sql = """
        SELECT themes_json FROM reflections
        WHERE created_at >= datetime('now', '-30 days') AND relevance_score > 0.2
        ORDER BY relevance_score DESC
        """

        var stmt: OpaquePointer?
        var allThemes: Set<String> = []

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let json = columnText(stmt, 0),
                   let themes = jsonDecode(json) as? [String] {
                    for theme in themes {
                        allThemes.insert(theme)
                    }
                }
            }
        }
        sqlite3_finalize(stmt)
        return Array(allThemes).sorted()
    }

    /// Get top themes aggregated across all recent reflections, weighted by relevance
    func getTopThemes(days: Int = 14, limit: Int = 10) -> [(theme: String, count: Int, classification: String)] {
        let reflections = getRecentReflections(limit: 100, days: days)
        var themeCounts: [String: (count: Int, classification: String, totalRelevance: Double)] = [:]

        for ref in reflections {
            let themes = ref["themes"] as? [String] ?? []
            let classifications = ref["theme_classifications"] as? [String: String] ?? [:]
            let relevance = ref["relevance_score"] as? Double ?? 0.5

            for theme in themes {
                let classification = classifications[theme] ?? "monitoring"
                let existing = themeCounts[theme] ?? (count: 0, classification: classification, totalRelevance: 0)
                themeCounts[theme] = (
                    count: existing.count + 1,
                    classification: classification,
                    totalRelevance: existing.totalRelevance + relevance
                )
            }
        }

        return themeCounts
            .sorted { $0.value.totalRelevance > $1.value.totalRelevance }
            .prefix(limit)
            .map { (theme: $0.key, count: $0.value.count, classification: $0.value.classification) }
    }

    /// Get distinct open questions from recent reflections
    func getOpenQuestions(limit: Int = 5) -> [String] {
        let reflections = getRecentReflections(limit: 50, days: 14)
        var seen: Set<String> = []
        var questions: [String] = []

        for ref in reflections {
            let qs = ref["open_questions"] as? [String] ?? []
            for q in qs {
                let normalized = q.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                if !seen.contains(normalized) {
                    seen.insert(normalized)
                    questions.append(q)
                }
            }
        }
        return Array(questions.prefix(limit))
    }

    // MARK: - Relevance Decay

    /// Apply daily relevance decay. Themes that appeared today get reinforced back to 1.0.
    func applyRelevanceDecay(reinforcedThemes: Set<String> = []) {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db else { return }

        // Decay all by 5%, floor at 0.1
        let decaySql = """
        UPDATE reflections SET relevance_score = MAX(0.1, relevance_score * 0.95)
        WHERE relevance_score > 0.1
        """
        sqlite3_exec(db, decaySql, nil, nil, nil)

        // Reinforce reflections whose themes appeared in today's ingestion
        if !reinforcedThemes.isEmpty {
            for theme in reinforcedThemes {
                let reinforceSql = """
                UPDATE reflections SET relevance_score = 1.0
                WHERE themes_json LIKE ?
                AND created_at >= datetime('now', '-30 days')
                """
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, reinforceSql, -1, &stmt, nil) == SQLITE_OK {
                    let pattern = "%\"\(theme)\"%"
                    sqlite3_bind_text(stmt, 1, (pattern as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    sqlite3_step(stmt)
                }
                sqlite3_finalize(stmt)
            }
        }

        print("✅ ReflectionStore: Applied relevance decay, reinforced \(reinforcedThemes.count) themes")
    }

    // MARK: - Coaching Context Injection

    /// Format top themes and open questions for injection into coaching prompt
    /// Returns a prompt-ready string, max ~400 tokens
    func getFormattedContextForCoaching(maxChars: Int = 1200) -> String {
        let themes = getTopThemes(days: 14, limit: 7)
        let questions = getOpenQuestions(limit: 3)

        guard !themes.isEmpty else { return "" }

        var context = ""

        // Top themes with classifications
        let classificationEmoji: [String: String] = [
            "researching": "🔍",
            "deciding": "⚖️",
            "creating": "🛠",
            "monitoring": "📡"
        ]

        for t in themes {
            let emoji = classificationEmoji[t.classification] ?? "📡"
            context += "\(emoji) \(t.theme) (\(t.classification))\n"
            if context.count > maxChars - 200 { break }
        }

        // Open questions
        if !questions.isEmpty {
            context += "\nOpen questions:\n"
            for q in questions {
                context += "• \(q)\n"
                if context.count > maxChars - 50 { break }
            }
        }

        return String(context.prefix(maxChars))
    }

    /// Extended context for reflection posture (~800 tokens)
    func getExtendedContextForReflection(maxChars: Int = 2400) -> String {
        let themes = getTopThemes(days: 14, limit: 10)
        let questions = getOpenQuestions(limit: 5)
        let recentReflections = getRecentReflections(limit: 5, days: 7)

        guard !themes.isEmpty || !recentReflections.isEmpty else { return "" }

        var context = getFormattedContextForCoaching(maxChars: maxChars / 2)

        // Add recent reflection summaries
        if !recentReflections.isEmpty {
            context += "\nRecent reflections:\n"
            for ref in recentReflections {
                let source = ref["source"] as? String ?? "unknown"
                let summary = ref["content_summary"] as? String ?? ""
                let date = ref["created_at"] as? String ?? ""
                let dateShort = String(date.prefix(10))
                context += "[\(dateShort)/\(source)] \(summary)\n"
                if context.count > maxChars - 100 { break }
            }
        }

        // Mental model shifts
        for ref in recentReflections {
            if let shifts = ref["mental_model_shifts"] as? [[String: String]], !shifts.isEmpty {
                context += "\nEvolving thinking:\n"
                for shift in shifts {
                    if let from = shift["from"], let to = shift["to"] {
                        context += "• Was: \(from) → Now: \(to)\n"
                    }
                    if context.count > maxChars { break }
                }
                break // Only show shifts from most recent
            }
        }

        return String(context.prefix(maxChars))
    }

    // MARK: - Stats

    func getStats() -> [String: Any] {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db else { return [:] }

        var stats: [String: Any] = [:]

        // Total reflections
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM reflections", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                stats["total_reflections"] = Int(sqlite3_column_int64(stmt, 0))
            }
        }
        sqlite3_finalize(stmt)

        // By source
        if sqlite3_prepare_v2(db, "SELECT source, COUNT(*) FROM reflections GROUP BY source", -1, &stmt, nil) == SQLITE_OK {
            var bySource: [String: Int] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let source = columnText(stmt, 0) {
                    bySource[source] = Int(sqlite3_column_int64(stmt, 1))
                }
            }
            stats["by_source"] = bySource
        }
        sqlite3_finalize(stmt)

        // Active themes count (inline to avoid deadlock — getExistingThemes also locks)
        if sqlite3_prepare_v2(db, "SELECT themes_json FROM reflections WHERE created_at >= datetime('now', '-30 days') AND relevance_score > 0.2", -1, &stmt, nil) == SQLITE_OK {
            var allThemes: Set<String> = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let json = columnText(stmt, 0),
                   let themes = jsonDecode(json) as? [String] {
                    for theme in themes { allThemes.insert(theme) }
                }
            }
            stats["active_themes"] = allThemes.count
        }
        sqlite3_finalize(stmt)

        return stats
    }

    // MARK: - Theme Deep-Dive

    /// Valid theme states in progression order
    private static let validStates = ["researching", "deciding", "creating", "monitoring", "archived"]

    /// Get detailed timeline and stats for a single theme
    func getThemeDetail(theme: String, days: Int = 90) -> [String: Any] {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db else { return [:] }

        // Fetch reflections containing this theme
        let sql = """
        SELECT id, source, content_summary, themes_json, theme_classifications_json,
               open_questions_json, mental_model_shifts_json, decisions_json,
               created_at
        FROM reflections
        WHERE created_at >= datetime('now', '-\(days) days')
          AND themes_json LIKE ?
        ORDER BY created_at DESC
        """

        let pattern = "%\"\(theme)\"%"
        var stmt: OpaquePointer?
        var timelineItems: [[String: Any]] = []
        var questionCount = 0
        var decisionCount = 0
        var shiftCount = 0
        var reflectionCount = 0
        var latestClassification = "researching"

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (pattern as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            while sqlite3_step(stmt) == SQLITE_ROW {
                let source = columnText(stmt, 1) ?? "unknown"
                let summary = columnText(stmt, 2) ?? ""
                let createdAt = columnText(stmt, 8) ?? ""
                let dateStr = String(createdAt.prefix(10))

                // Extract classifications for fallback state
                if let classJson = columnText(stmt, 4),
                   let classifications = jsonDecode(classJson) as? [String: String],
                   let cls = classifications[theme] {
                    if reflectionCount == 0 { latestClassification = cls }
                }

                // Reflection item
                reflectionCount += 1
                timelineItems.append([
                    "type": "reflection",
                    "date": dateStr,
                    "content": summary,
                    "source": source
                ])

                // Open questions
                if let qJson = columnText(stmt, 5),
                   let questions = jsonDecode(qJson) as? [String] {
                    for q in questions {
                        questionCount += 1
                        timelineItems.append([
                            "type": "question",
                            "date": dateStr,
                            "content": q,
                            "source": source
                        ])
                    }
                }

                // Decisions
                if let dJson = columnText(stmt, 7),
                   let decisions = jsonDecode(dJson) as? [String] {
                    for d in decisions {
                        decisionCount += 1
                        timelineItems.append([
                            "type": "decision",
                            "date": dateStr,
                            "content": d,
                            "source": source
                        ])
                    }
                }

                // Mental model shifts
                if let sJson = columnText(stmt, 6),
                   let shifts = jsonDecode(sJson) as? [[String: String]] {
                    for shift in shifts {
                        shiftCount += 1
                        var content = ""
                        if let from = shift["from"], let to = shift["to"] {
                            content = "Was: \(from) -> Now: \(to)"
                        } else if let desc = shift["description"] {
                            content = desc
                        }
                        timelineItems.append([
                            "type": "shift",
                            "date": dateStr,
                            "content": content,
                            "source": source
                        ])
                    }
                }
            }
        }
        sqlite3_finalize(stmt)

        // Fetch theme state
        var state = latestClassification
        var stateHistory: Any = []
        var themeSummary: String? = nil

        let stateSql = "SELECT state, state_history_json, summary FROM theme_states WHERE theme = ?"
        if sqlite3_prepare_v2(db, stateSql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (theme as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            if sqlite3_step(stmt) == SQLITE_ROW {
                state = columnText(stmt, 0) ?? latestClassification
                if let histJson = columnText(stmt, 1) {
                    stateHistory = jsonDecode(histJson) ?? []
                }
                themeSummary = columnText(stmt, 2)
            }
        }
        sqlite3_finalize(stmt)

        var result: [String: Any] = [
            "theme": theme,
            "state": state,
            "state_history": stateHistory,
            "timeline": timelineItems,
            "stats": [
                "reflections": reflectionCount,
                "questions": questionCount,
                "decisions": decisionCount,
                "shifts": shiftCount
            ]
        ]
        if let s = themeSummary {
            result["summary"] = s
        }
        return result
    }

    /// Advance a theme's state with validation
    func advanceThemeState(theme: String, newState: String, context: String) -> Bool {
        guard ReflectionStore.validStates.contains(newState) else { return false }

        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db else { return false }

        // Read current state
        var currentState = "researching"
        let readSql = "SELECT state FROM theme_states WHERE theme = ?"
        var stmt: OpaquePointer?
        var rowExists = false

        if sqlite3_prepare_v2(db, readSql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (theme as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            if sqlite3_step(stmt) == SQLITE_ROW {
                currentState = columnText(stmt, 0) ?? "researching"
                rowExists = true
            }
        }
        sqlite3_finalize(stmt)

        // Validate transition: any state can go to archived, otherwise must follow progression
        if newState != "archived" {
            guard let currentIdx = ReflectionStore.validStates.firstIndex(of: currentState),
                  let newIdx = ReflectionStore.validStates.firstIndex(of: newState),
                  newIdx == currentIdx + 1 else {
                // Allow same-state (idempotent) or forward-one-step only
                if newState != currentState {
                    print("❌ ReflectionStore: Invalid state transition \(currentState) → \(newState)")
                    return false
                }
                return true // Same state, no-op success
            }
        }

        // Build history entry
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let timestamp = formatter.string(from: Date())
        let historyEntry: [String: String] = [
            "from": currentState,
            "to": newState,
            "context": context,
            "at": timestamp
        ]

        // Read existing history
        var history: [[String: String]] = []
        if rowExists {
            let histSql = "SELECT state_history_json FROM theme_states WHERE theme = ?"
            if sqlite3_prepare_v2(db, histSql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (theme as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                if sqlite3_step(stmt) == SQLITE_ROW {
                    if let json = columnText(stmt, 0),
                       let decoded = jsonDecode(json) as? [[String: String]] {
                        history = decoded
                    }
                }
            }
            sqlite3_finalize(stmt)
        }
        history.append(historyEntry)
        let historyJson = jsonEncode(history)

        // Upsert
        let upsertSql = """
        INSERT INTO theme_states (theme, state, state_history_json, updated_at)
        VALUES (?, ?, ?, CURRENT_TIMESTAMP)
        ON CONFLICT(theme) DO UPDATE SET
            state = excluded.state,
            state_history_json = ?,
            updated_at = CURRENT_TIMESTAMP
        """

        if sqlite3_prepare_v2(db, upsertSql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (theme as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 2, (newState as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 3, (historyJson as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 4, (historyJson as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            if sqlite3_step(stmt) == SQLITE_DONE {
                sqlite3_finalize(stmt)
                print("✅ ReflectionStore: Theme '\(theme)' state: \(currentState) → \(newState)")
                return true
            }
        }
        sqlite3_finalize(stmt)
        print("❌ ReflectionStore: Failed to advance theme state")
        return false
    }

    /// Ensure a theme_states row exists (does not override manual changes)
    func ensureThemeState(theme: String, classification: String) {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db else { return }

        let resolvedState = ReflectionStore.validStates.contains(classification) && !classification.isEmpty
            ? classification : "researching"

        let sql = """
        INSERT INTO theme_states (theme, state)
        VALUES (?, ?)
        ON CONFLICT(theme) DO NOTHING
        """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (theme as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 2, (resolvedState as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    /// Enhanced theme listing with state from theme_states table
    func getThemesWithState(days: Int = 30, limit: Int = 10) -> [[String: Any]] {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db else { return [] }

        // First, gather theme data from reflections (same approach as getTopThemes but with more detail)
        let sql = """
        SELECT content_summary, themes_json, theme_classifications_json,
               open_questions_json, relevance_score, created_at
        FROM reflections
        WHERE created_at >= datetime('now', '-\(days) days')
        ORDER BY created_at DESC
        """

        var stmt: OpaquePointer?

        struct ThemeAgg {
            var count: Int = 0
            var totalRelevance: Double = 0
            var latestClassification: String = "monitoring"
            var latestSummary: String = ""
            var openQuestionCount: Int = 0
        }

        var themeData: [String: ThemeAgg] = [:]

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let summary = columnText(stmt, 0) ?? ""
                let themesJson = columnText(stmt, 1)
                let classJson = columnText(stmt, 2)
                let questionsJson = columnText(stmt, 3)
                let relevance = sqlite3_column_double(stmt, 4)

                guard let themes = jsonDecode(themesJson) as? [String] else { continue }
                let classifications = jsonDecode(classJson) as? [String: String] ?? [:]
                let questions = jsonDecode(questionsJson) as? [String] ?? []

                for theme in themes {
                    var agg = themeData[theme] ?? ThemeAgg()
                    agg.count += 1
                    agg.totalRelevance += relevance
                    if agg.count == 1 {
                        // First (most recent) occurrence
                        agg.latestClassification = classifications[theme] ?? "monitoring"
                        agg.latestSummary = summary
                        agg.openQuestionCount = questions.count
                    }
                    themeData[theme] = agg
                }
            }
        }
        sqlite3_finalize(stmt)

        // Load theme_states for all themes
        var themeStates: [String: String] = [:]
        let statesSql = "SELECT theme, state FROM theme_states WHERE state != 'archived'"
        if sqlite3_prepare_v2(db, statesSql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let t = columnText(stmt, 0), let s = columnText(stmt, 1) {
                    themeStates[t] = s
                }
            }
        }
        sqlite3_finalize(stmt)

        // Also check for archived themes to filter them out
        var archivedThemes: Set<String> = []
        let archivedSql = "SELECT theme FROM theme_states WHERE state = 'archived'"
        if sqlite3_prepare_v2(db, archivedSql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let t = columnText(stmt, 0) {
                    archivedThemes.insert(t)
                }
            }
        }
        sqlite3_finalize(stmt)

        // Build results, filter archived, sort by count
        var results: [[String: Any]] = []
        let sorted = themeData
            .filter { !archivedThemes.contains($0.key) }
            .sorted { $0.value.totalRelevance > $1.value.totalRelevance }
            .prefix(limit)

        for (theme, agg) in sorted {
            let state = themeStates[theme] ?? agg.latestClassification
            results.append([
                "theme": theme,
                "state": state,
                "count": agg.count,
                "subtitle": agg.latestSummary,
                "open_questions_count": agg.openQuestionCount
            ])
        }

        return results
    }

    // MARK: - Helpers

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
