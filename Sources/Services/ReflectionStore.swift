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

        // Per-item theme overrides. Sub-items (belief shifts, decisions, questions) have no
        // independent theme tag — they inherit their parent reflection's themes_json. This table
        // layers non-destructive, user-driven corrections on top: hide an item from a theme, or
        // re-tag it to a different theme. Source reflections stay untouched (re-extraction safe,
        // other themes undisturbed); getThemeDetail applies these at read time.
        //   action is implicit: to_theme == NULL → pure exclude; to_theme set → move (exclude here + show there)
        //   item_content / item_aux identify the specific sub-item:
        //     decision → item_content = decision text, item_aux = NULL
        //     shift    → item_content = "to" (new belief), item_aux = "from" (old belief)
        let createItemOverrides = """
        CREATE TABLE IF NOT EXISTS reflection_item_overrides (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            reflection_id INTEGER NOT NULL,
            item_type TEXT NOT NULL,
            item_content TEXT NOT NULL,
            item_aux TEXT,
            from_theme TEXT NOT NULL,
            to_theme TEXT,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        CREATE INDEX IF NOT EXISTS idx_item_override_from ON reflection_item_overrides(from_theme);
        CREATE INDEX IF NOT EXISTS idx_item_override_to ON reflection_item_overrides(to_theme);
        """

        if sqlite3_exec(db, createItemOverrides, nil, nil, &errMsg) != SQLITE_OK {
            if let err = errMsg {
                print("❌ ReflectionStore: SQL error creating reflection_item_overrides: \(String(cString: err))")
                sqlite3_free(errMsg)
            }
        }

        print("✅ ReflectionStore database initialized")
    }

    // MARK: - Clear / Reset

    /// Delete all reflection data (both reflections and theme states)
    func clearAll() {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db else { return }

        sqlite3_exec(db, "DELETE FROM reflections", nil, nil, nil)
        sqlite3_exec(db, "DELETE FROM theme_states", nil, nil, nil)
        print("🗑️ ReflectionStore: All data cleared")
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
    /// Has this exact source already been ingested? Used to skip threads already done
    /// today so a per-run cap throttles work without starving the tail of the list.
    func hasReflection(source: String, sourceId: String) -> Bool {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM reflections WHERE source = ? AND source_id = ? LIMIT 1", -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(stmt, 1, (source as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, (sourceId as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        let found = sqlite3_step(stmt) == SQLITE_ROW
        sqlite3_finalize(stmt)
        return found
    }

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
    /// Generic words that appear across many workspace titles ("execution", "strategy")
    /// carry no discriminating signal, so they're excluded from the overlap score.
    private static let bestFitStop: Set<String> = [
        // generic across many workspace titles — no discriminating signal
        "execution","strategy","management","planning","program","framework",
        // function words
        "through","after","before","about","under","which","their","there","would",
        "could","should","these","those","being","during","across","around","between"
    ]

    private static func bestFitTokens(_ s: String) -> Set<String> {
        Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }
            .map(String.init).filter { $0.count > 3 && !bestFitStop.contains($0) })
    }

    /// Which theme (among a reflection's own themes) an artifact is most about.
    /// Scores by how many salient tokens the artifact shares with each theme title;
    /// the artifact belongs to the argmax. Ties / no-overlap fall back to the first
    /// theme, so every artifact lands in exactly one place, deterministically.
    static func bestFitTheme(_ text: String, among themes: [String]) -> String {
        guard let first = themes.first else { return "" }
        guard themes.count > 1 else { return first }
        let tt = bestFitTokens(text)
        if tt.isEmpty { return first }
        var best = first
        var bestScore = -1.0
        for theme in themes {
            let th = bestFitTokens(theme)
            let inter = Double(tt.intersection(th).count)
            // Overlap count, lightly normalized so a very long title can't win on bulk alone.
            let score = inter + inter / Double(max(th.count, 1))
            if score > bestScore { bestScore = score; best = theme }
        }
        return best
    }

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

        // L2 enrichment side-collections
        var lede = ""                                  // freshest reflection summary
        var edge = ""                                  // freshest open question
        var edgeSecondary = ""                         // next open question
        var firstSeen = ""                             // ends as oldest createdAt (DESC loop)
        var beliefShiftsTyped: [[String: String]] = [] // {from,to,date}
        var decisionsTyped: [[String: String]] = []    // {content,date}

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (pattern as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            while sqlite3_step(stmt) == SQLITE_ROW {
                let rid = Int(sqlite3_column_int64(stmt, 0))
                let source = columnText(stmt, 1) ?? "unknown"
                let summary = columnText(stmt, 2) ?? ""
                let createdAt = columnText(stmt, 8) ?? ""
                let dateStr = String(createdAt.prefix(10))

                // A reflection carries several themes, but each shift/decision/question
                // inside it is usually about only ONE of them. Best-fit attribution: an
                // artifact belongs to this theme only if this is the theme (among the
                // reflection's own themes) it's most about — otherwise it's bleeding in
                // from a co-tagged topic. Single-theme reflections keep everything.
                let rowThemes = (columnText(stmt, 3).flatMap { jsonDecode($0) as? [String] }) ?? [theme]
                func belongsHere(_ text: String) -> Bool {
                    rowThemes.count < 2 || Self.bestFitTheme(text, among: rowThemes) == theme
                }

                // Extract classifications for fallback state
                if let classJson = columnText(stmt, 4),
                   let classifications = jsonDecode(classJson) as? [String: String],
                   let cls = classifications[theme] {
                    if reflectionCount == 0 { latestClassification = cls }
                }

                // Reflection item
                reflectionCount += 1
                if lede.isEmpty && !summary.isEmpty { lede = summary }
                firstSeen = createdAt   // DESC loop → last assignment wins = oldest
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
                        guard belongsHere(q) else { continue }
                        questionCount += 1
                        if edge.isEmpty { edge = q }
                        else if edgeSecondary.isEmpty && q != edge { edgeSecondary = q }
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
                        guard belongsHere(d) else { continue }
                        decisionCount += 1
                        if decisionsTyped.count < 25 {
                            decisionsTyped.append(["content": d, "date": dateStr, "rid": String(rid)])
                        }
                        timelineItems.append([
                            "type": "decision",
                            "date": dateStr,
                            "content": d,
                            "source": source,
                            "rid": String(rid)
                        ])
                    }
                }

                // Mental model shifts
                if let sJson = columnText(stmt, 6),
                   let shifts = jsonDecode(sJson) as? [[String: String]] {
                    for shift in shifts {
                        let shiftText = [shift["from"], shift["to"], shift["description"]].compactMap { $0 }.joined(separator: " ")
                        guard belongsHere(shiftText) else { continue }
                        shiftCount += 1
                        var content = ""
                        var sFrom = ""
                        var sTo = ""
                        if let from = shift["from"], let to = shift["to"] {
                            content = "Was: \(from) -> Now: \(to)"
                            sFrom = from; sTo = to
                            if beliefShiftsTyped.count < 10 {
                                beliefShiftsTyped.append(["from": from, "to": to, "date": dateStr, "rid": String(rid)])
                            }
                        } else if let desc = shift["description"] {
                            content = desc
                            sTo = desc
                            if beliefShiftsTyped.count < 10 {
                                beliefShiftsTyped.append(["from": "", "to": desc, "date": dateStr, "rid": String(rid)])
                            }
                        }
                        timelineItems.append([
                            "type": "shift",
                            "date": dateStr,
                            "content": content,
                            "source": source,
                            "rid": String(rid),
                            "shift_from": sFrom,
                            "shift_to": sTo
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

        // ── Apply per-item theme overrides (non-destructive user corrections) ──
        // 1. Remove items the user excluded from / moved away from this theme.
        // 2. Pull in items the user re-tagged TO this theme from other reflections.
        let excludeKeys = loadOverrideKeys(fromTheme: theme)   // items to drop from this theme
        if !excludeKeys.isEmpty {
            let before = (decisionsTyped.count, beliefShiftsTyped.count)
            decisionsTyped = decisionsTyped.filter { !excludeKeys.contains(decisionKey($0)) }
            beliefShiftsTyped = beliefShiftsTyped.filter { !excludeKeys.contains(shiftKey($0)) }
            timelineItems = timelineItems.filter { item in
                guard let t = item["type"] as? String else { return true }
                if t == "decision" { return !excludeKeys.contains(decisionKey(item)) }
                if t == "shift" { return !excludeKeys.contains(shiftTimelineKey(item)) }
                return true
            }
            decisionCount -= (before.0 - decisionsTyped.count)
            shiftCount -= (before.1 - beliefShiftsTyped.count)
        }

        // Pull in items re-tagged to this theme from their source reflections.
        let movedIn = loadItemsRetagged(toTheme: theme)
        for item in movedIn {
            if item["type"] as? String == "decision" {
                decisionCount += 1
                decisionsTyped.append(["content": item["content"] ?? "", "date": item["date"] ?? "", "rid": item["rid"] ?? ""])
                timelineItems.append(["type": "decision", "date": item["date"] ?? "", "content": item["content"] ?? "", "source": item["source"] ?? "", "rid": item["rid"] ?? ""])
            } else if item["type"] as? String == "shift" {
                shiftCount += 1
                let from = item["from"] ?? ""
                let to = item["to"] ?? ""
                beliefShiftsTyped.append(["from": from, "to": to, "date": item["date"] ?? "", "rid": item["rid"] ?? ""])
                timelineItems.append(["type": "shift", "date": item["date"] ?? "", "content": "Was: \(from) -> Now: \(to)", "source": item["source"] ?? "", "rid": item["rid"] ?? "", "shift_from": from, "shift_to": to])
            }
        }
        if !movedIn.isEmpty {
            // Re-sort moments-relevant arrays by date desc so injected items slot correctly.
            decisionsTyped.sort { ($0["date"] ?? "") > ($1["date"] ?? "") }
            beliefShiftsTyped.sort { ($0["date"] ?? "") > ($1["date"] ?? "") }
            timelineItems.sort { (($0["date"] as? String) ?? "") > (($1["date"] as? String) ?? "") }
        }

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
            ],
            "lede": lede,
            "edge": edge,
            "edge_secondary": edgeSecondary,
            "first_seen": firstSeen,
            "belief_shifts": beliefShiftsTyped,
            "decisions_typed": decisionsTyped
        ]
        if let s = themeSummary {
            result["summary"] = s
        }
        return result
    }

    // MARK: - Per-item theme overrides

    /// Stable match key for an item: reflection_id ␟ type ␟ content ␟ aux
    private func itemKey(rid: String, type: String, content: String, aux: String) -> String {
        return "\(rid)\u{241F}\(type)\u{241F}\(content)\u{241F}\(aux)"
    }
    private func decisionKey(_ d: [String: String]) -> String {
        return itemKey(rid: d["rid"] ?? "", type: "decision", content: d["content"] ?? "", aux: "")
    }
    private func shiftKey(_ s: [String: String]) -> String {
        return itemKey(rid: s["rid"] ?? "", type: "shift", content: s["to"] ?? "", aux: s["from"] ?? "")
    }
    private func shiftTimelineKey(_ item: [String: Any]) -> String {
        return itemKey(rid: (item["rid"] as? String) ?? "", type: "shift",
                       content: (item["shift_to"] as? String) ?? "", aux: (item["shift_from"] as? String) ?? "")
    }
    private func decisionKey(_ item: [String: Any]) -> String {
        return itemKey(rid: (item["rid"] as? String) ?? "", type: "decision",
                       content: (item["content"] as? String) ?? "", aux: "")
    }

    /// Match keys for items the user excluded from (or moved away from) a given theme.
    /// Caller must hold dbLock.
    private func loadOverrideKeys(fromTheme: String) -> Set<String> {
        guard let db = db else { return [] }
        var keys = Set<String>()
        let sql = "SELECT reflection_id, item_type, item_content, item_aux FROM reflection_item_overrides WHERE from_theme = ?"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (fromTheme as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            while sqlite3_step(stmt) == SQLITE_ROW {
                let rid = String(Int(sqlite3_column_int64(stmt, 0)))
                let type = columnText(stmt, 1) ?? ""
                let content = columnText(stmt, 2) ?? ""
                let aux = columnText(stmt, 3) ?? ""
                keys.insert(itemKey(rid: rid, type: type, content: content, aux: aux))
            }
        }
        sqlite3_finalize(stmt)
        return keys
    }

    /// Items the user re-tagged INTO this theme. Fetches the specific sub-item content
    /// from its source reflection. Caller must hold dbLock.
    private func loadItemsRetagged(toTheme: String) -> [[String: String]] {
        guard let db = db else { return [] }
        var out: [[String: String]] = []
        let sql = "SELECT reflection_id, item_type, item_content, item_aux FROM reflection_item_overrides WHERE to_theme = ?"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (toTheme as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            while sqlite3_step(stmt) == SQLITE_ROW {
                let rid = Int(sqlite3_column_int64(stmt, 0))
                let type = columnText(stmt, 1) ?? ""
                let content = columnText(stmt, 2) ?? ""
                let aux = columnText(stmt, 3) ?? ""
                // Fetch date/source from the source reflection
                var date = ""
                var source = "unknown"
                let rSql = "SELECT created_at, source FROM reflections WHERE id = ?"
                var rStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, rSql, -1, &rStmt, nil) == SQLITE_OK {
                    sqlite3_bind_int64(rStmt, 1, Int64(rid))
                    if sqlite3_step(rStmt) == SQLITE_ROW {
                        date = String((columnText(rStmt, 0) ?? "").prefix(10))
                        source = columnText(rStmt, 1) ?? "unknown"
                    }
                }
                sqlite3_finalize(rStmt)
                if type == "decision" {
                    out.append(["type": "decision", "content": content, "date": date, "source": source, "rid": String(rid)])
                } else if type == "shift" {
                    out.append(["type": "shift", "from": aux, "to": content, "date": date, "source": source, "rid": String(rid)])
                }
            }
        }
        sqlite3_finalize(stmt)
        return out
    }

    /// Record an item override. toTheme == nil → pure exclude; toTheme set → move.
    /// Replaces any prior override for the same (item, fromTheme) pair.
    func setItemOverride(reflectionId: Int, itemType: String, content: String, aux: String?, fromTheme: String, toTheme: String?) -> Bool {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db else { return false }

        // Clear any existing override for this exact item + source theme first (idempotent).
        let delSql = "DELETE FROM reflection_item_overrides WHERE reflection_id = ? AND item_type = ? AND item_content = ? AND IFNULL(item_aux,'') = ? AND from_theme = ?"
        var delStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, delSql, -1, &delStmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(delStmt, 1, Int64(reflectionId))
            sqlite3_bind_text(delStmt, 2, (itemType as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(delStmt, 3, (content as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(delStmt, 4, ((aux ?? "") as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(delStmt, 5, (fromTheme as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_step(delStmt)
        }
        sqlite3_finalize(delStmt)

        let insSql = "INSERT INTO reflection_item_overrides (reflection_id, item_type, item_content, item_aux, from_theme, to_theme) VALUES (?, ?, ?, ?, ?, ?)"
        var insStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insSql, -1, &insStmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_int64(insStmt, 1, Int64(reflectionId))
        sqlite3_bind_text(insStmt, 2, (itemType as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(insStmt, 3, (content as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        if let aux = aux {
            sqlite3_bind_text(insStmt, 4, (aux as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } else {
            sqlite3_bind_null(insStmt, 4)
        }
        sqlite3_bind_text(insStmt, 5, (fromTheme as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        if let toTheme = toTheme {
            sqlite3_bind_text(insStmt, 6, (toTheme as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } else {
            sqlite3_bind_null(insStmt, 6)
        }
        let ok = sqlite3_step(insStmt) == SQLITE_DONE
        sqlite3_finalize(insStmt)
        return ok
    }

    /// Undo an override (restore the item to its original theme membership).
    func clearItemOverride(reflectionId: Int, itemType: String, content: String, aux: String?, fromTheme: String) -> Bool {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db else { return false }
        let sql = "DELETE FROM reflection_item_overrides WHERE reflection_id = ? AND item_type = ? AND item_content = ? AND IFNULL(item_aux,'') = ? AND from_theme = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_int64(stmt, 1, Int64(reflectionId))
        sqlite3_bind_text(stmt, 2, (itemType as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 3, (content as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 4, ((aux ?? "") as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 5, (fromTheme as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        let ok = sqlite3_step(stmt) == SQLITE_DONE
        sqlite3_finalize(stmt)
        return ok
    }

    /// Advance a theme's state with validation
    func advanceThemeState(theme: String, newState: String, context: String) -> Bool {
        guard ReflectionStore.validStates.contains(newState) else { return false }

        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db else { return false }

        // Read current state. If theme_states has no row yet, fall back to the LLM-derived
        // classification on the theme's most recent reflection — that's what the UI is
        // showing as the "current state," so the backend should agree before validating
        // the requested transition.
        var currentState = "researching"
        var stmt: OpaquePointer?
        var rowExists = false

        let readSql = "SELECT state FROM theme_states WHERE theme = ?"
        if sqlite3_prepare_v2(db, readSql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (theme as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            if sqlite3_step(stmt) == SQLITE_ROW {
                currentState = columnText(stmt, 0) ?? "researching"
                rowExists = true
            }
        }
        sqlite3_finalize(stmt)

        if !rowExists {
            // Look up the most recent reflection that references this theme and pull
            // its theme_classifications_json[theme] value. That's the implicit current state.
            let fallbackSql = """
            SELECT theme_classifications_json FROM reflections
            WHERE themes_json LIKE ?
            ORDER BY created_at DESC
            LIMIT 1
            """
            if sqlite3_prepare_v2(db, fallbackSql, -1, &stmt, nil) == SQLITE_OK {
                let likeNeedle = "%\"\(theme)\"%"
                sqlite3_bind_text(stmt, 1, (likeNeedle as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                if sqlite3_step(stmt) == SQLITE_ROW {
                    if let json = columnText(stmt, 0),
                       let classifications = jsonDecode(json) as? [String: String],
                       let llmState = classifications[theme],
                       ReflectionStore.validStates.contains(llmState) {
                        currentState = llmState
                        print("ℹ️ ReflectionStore.advanceThemeState: seeded current state from LLM classification ('\(theme)' → \(llmState))")
                    }
                }
            }
            sqlite3_finalize(stmt)
        }

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

    /// Merge two themes: reassign all reflections from `source` into `target`.
    /// - Updates `themes_json` and `theme_classifications_json` on every reflection that references `source`.
    /// - When a reflection already has both themes, the source is removed (themes_json is a set).
    /// - When both themes have classifications on the same reflection, the target's classification wins.
    /// - Appends a `merged_from` entry to the target's state_history.
    /// - Deletes the source's `theme_states` row.
    /// - This operation is irreversible. Caller is expected to confirm.
    /// Returns the number of reflections updated, or nil on failure.
    func mergeThemes(source: String, target: String) -> Int? {
        guard !source.isEmpty, !target.isEmpty, source != target else {
            print("❌ ReflectionStore.mergeThemes: invalid args (source='\(source)' target='\(target)')")
            return nil
        }

        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db else { return nil }

        // BEGIN transaction so all updates either land together or roll back.
        sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)

        // 1. Find every reflection that references the source theme.
        let selectSql = "SELECT id, themes_json, theme_classifications_json FROM reflections WHERE themes_json LIKE ?"
        var stmt: OpaquePointer?
        var rowsToUpdate: [(id: Int64, themes: [String], classifications: [String: String])] = []

        if sqlite3_prepare_v2(db, selectSql, -1, &stmt, nil) == SQLITE_OK {
            // Quoted JSON form so we don't match a theme whose name is a substring of another.
            let likeNeedle = "%\"\(source)\"%"
            sqlite3_bind_text(stmt, 1, (likeNeedle as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let themesJson = columnText(stmt, 1) ?? "[]"
                let classJson = columnText(stmt, 2) ?? "{}"

                let themes = (jsonDecode(themesJson) as? [String]) ?? []
                // Defensive: only act when the *exact* theme name is present (LIKE could over-match in edge cases)
                guard themes.contains(source) else { continue }
                let classifications = (jsonDecode(classJson) as? [String: String]) ?? [:]
                rowsToUpdate.append((id: id, themes: themes, classifications: classifications))
            }
        }
        sqlite3_finalize(stmt)

        // 2. Update each row in place.
        let updateSql = "UPDATE reflections SET themes_json = ?, theme_classifications_json = ? WHERE id = ?"
        var updated = 0

        for row in rowsToUpdate {
            // Rewrite themes set: replace source with target, dedupe, preserve order.
            var newThemes: [String] = []
            var seen = Set<String>()
            for t in row.themes {
                let mapped = (t == source) ? target : t
                if seen.insert(mapped).inserted { newThemes.append(mapped) }
            }

            // Rewrite classifications dict: if both source and target were keys, target wins.
            var newClass = row.classifications
            if let sourceClass = newClass.removeValue(forKey: source) {
                if newClass[target] == nil { newClass[target] = sourceClass }
            }

            let themesJson = jsonEncode(newThemes)
            let classJson = jsonEncode(newClass)

            if sqlite3_prepare_v2(db, updateSql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (themesJson as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_text(stmt, 2, (classJson as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_int64(stmt, 3, row.id)
                if sqlite3_step(stmt) == SQLITE_DONE { updated += 1 }
            }
            sqlite3_finalize(stmt)
        }

        // Early-exit: no reflections referenced the source, so don't write a misleading
        // history entry or create a phantom target row.
        if updated == 0 {
            sqlite3_exec(db, "COMMIT", nil, nil, nil)
            print("ℹ️ ReflectionStore.mergeThemes: no reflections referenced '\(source)' — no-op")
            return 0
        }

        // 3. Append a `merged_from` entry to the target's state_history (creates the row if missing).
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let timestamp = formatter.string(from: Date())
        let mergeEntry: [String: String] = [
            "event": "merged_from",
            "source": source,
            "reflections_moved": String(updated),
            "at": timestamp
        ]

        // Read target's current history, append, write back (and ensure the row exists).
        var targetHistory: [[String: String]] = []
        var targetState = "researching"
        var targetExists = false
        let readSql = "SELECT state, state_history_json FROM theme_states WHERE theme = ?"
        if sqlite3_prepare_v2(db, readSql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (target as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            if sqlite3_step(stmt) == SQLITE_ROW {
                targetState = columnText(stmt, 0) ?? "researching"
                if let json = columnText(stmt, 1),
                   let decoded = jsonDecode(json) as? [[String: String]] {
                    targetHistory = decoded
                }
                targetExists = true
            }
        }
        sqlite3_finalize(stmt)
        targetHistory.append(mergeEntry)
        let historyJson = jsonEncode(targetHistory)

        let upsertSql = """
        INSERT INTO theme_states (theme, state, state_history_json, updated_at)
        VALUES (?, ?, ?, CURRENT_TIMESTAMP)
        ON CONFLICT(theme) DO UPDATE SET
            state_history_json = excluded.state_history_json,
            updated_at = CURRENT_TIMESTAMP
        """
        if sqlite3_prepare_v2(db, upsertSql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (target as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 2, (targetState as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 3, (historyJson as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        _ = targetExists  // suppress unused warning; kept for future audit-log use

        // 4. Delete the source's theme_states row.
        let deleteSql = "DELETE FROM theme_states WHERE theme = ?"
        if sqlite3_prepare_v2(db, deleteSql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (source as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)

        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        print("✅ ReflectionStore: merged theme '\(source)' → '\(target)' (\(updated) reflections)")
        return updated
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
               open_questions_json, relevance_score, created_at, source
        FROM reflections
        WHERE created_at >= datetime('now', '-\(days) days')
        ORDER BY created_at DESC
        """

        var stmt: OpaquePointer?

        // Cutoff for "this week" activity (lexicographic compare works for SQLite's
        // "YYYY-MM-DD HH:MM:SS" UTC timestamp format)
        let weekCutoff: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            f.timeZone = TimeZone(identifier: "UTC")
            return f.string(from: Date().addingTimeInterval(-7 * 86400))
        }()

        struct ThemeAgg {
            var count: Int = 0
            var totalRelevance: Double = 0
            var latestClassification: String = "monitoring"
            var latestSummary: String = ""
            var openQuestionCount: Int = 0
            var lastActivity: String = ""        // most recent created_at for this theme
            var inputsThisWeek: Int = 0
            var sourcesThisWeek: [String: Int] = [:]
            var edge: String = ""                // freshest open question
        }

        var themeData: [String: ThemeAgg] = [:]

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let summary = columnText(stmt, 0) ?? ""
                let themesJson = columnText(stmt, 1)
                let classJson = columnText(stmt, 2)
                let questionsJson = columnText(stmt, 3)
                let relevance = sqlite3_column_double(stmt, 4)
                let createdAt = columnText(stmt, 5) ?? ""
                let source = columnText(stmt, 6) ?? "unknown"
                let isThisWeek = !createdAt.isEmpty && createdAt >= weekCutoff

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
                        agg.lastActivity = createdAt
                    }
                    // Freshest open question becomes the "live edge" (rows are DESC)
                    if agg.edge.isEmpty, let firstQ = questions.first, !firstQ.isEmpty {
                        agg.edge = firstQ
                    }
                    if isThisWeek {
                        agg.inputsThisWeek += 1
                        agg.sourcesThisWeek[source, default: 0] += 1
                    }
                    themeData[theme] = agg
                }
            }
        }
        sqlite3_finalize(stmt)

        // Load theme_states (state + recent transition) for all themes
        var themeStates: [String: String] = [:]
        var themeMoved: [String: String] = [:]   // theme -> "from → to" if transitioned this week
        let statesSql = "SELECT theme, state, state_history_json FROM theme_states WHERE state != 'archived'"
        if sqlite3_prepare_v2(db, statesSql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let t = columnText(stmt, 0), let s = columnText(stmt, 1) {
                    themeStates[t] = s
                    // Find the most recent transition within the last 7 days
                    if let histJson = columnText(stmt, 2),
                       let history = jsonDecode(histJson) as? [[String: String]] {
                        let weekAgo = Date().addingTimeInterval(-7 * 86400)
                        let iso = ISO8601DateFormatter()
                        for entry in history.reversed() {
                            if let at = entry["at"], let when = iso.date(from: at), when >= weekAgo,
                               let from = entry["from"], let to = entry["to"], from != to {
                                themeMoved[t] = "\(from) → \(to)"
                                break
                            }
                        }
                    }
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

        let iso = ISO8601DateFormatter()
        let sqlFmt = DateFormatter()
        sqlFmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        sqlFmt.timeZone = TimeZone(identifier: "UTC")

        for (theme, agg) in sorted {
            let state = themeStates[theme] ?? agg.latestClassification
            let moved = themeMoved[theme]

            // Days since last activity (created_at is "YYYY-MM-DD HH:MM:SS" UTC, sometimes ISO)
            let lastDate = sqlFmt.date(from: agg.lastActivity) ?? iso.date(from: agg.lastActivity)
            let daysSince = lastDate.map { Int(Date().timeIntervalSince($0) / 86400) } ?? 999

            // Temperature reflects this-week intensity so the dot maps to real momentum:
            //   hot = transitioned or repeated deliberate attention (3+ inputs)
            //   warming = touched this week (1-2 inputs)
            //   resolved = settled (monitoring/archived with no fresh activity)
            //   cooling = gone quiet
            let temperature: String
            if state == "archived" {
                temperature = "resolved"
            } else if moved != nil || agg.inputsThisWeek >= 3 {
                temperature = "hot"
            } else if agg.inputsThisWeek >= 1 {
                temperature = "warming"
            } else if state == "monitoring" {
                temperature = "resolved"
            } else {
                temperature = "cooling"
            }

            results.append([
                "theme": theme,
                "state": state,
                "count": agg.count,
                "subtitle": agg.latestSummary,
                "open_questions_count": agg.openQuestionCount,
                "edge": agg.edge,
                "moved": moved as Any,
                "temperature": temperature,
                "last_activity": agg.lastActivity,
                "days_since": daysSince,
                "inputs_this_week": agg.inputsThisWeek,
                "sources_this_week": agg.sourcesThisWeek
            ])
        }

        return results
    }

    /// Recent mental-model shifts ("beliefs you've updated"), most recent first, deduped by destination.
    func getRecentBeliefShifts(days: Int = 60, limit: Int = 5) -> [[String: String]] {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db else { return [] }

        let sql = """
        SELECT mental_model_shifts_json, created_at
        FROM reflections
        WHERE created_at >= datetime('now', '-\(days) days')
          AND mental_model_shifts_json IS NOT NULL
          AND mental_model_shifts_json != '[]'
        ORDER BY created_at DESC
        """

        var stmt: OpaquePointer?
        var results: [[String: String]] = []
        var seen: Set<String> = []

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let createdAt = columnText(stmt, 1) ?? ""
                let dateShort = String(createdAt.prefix(10))
                guard let shifts = jsonDecode(columnText(stmt, 0)) as? [[String: String]] else { continue }
                for shift in shifts {
                    let to = shift["to"] ?? shift["description"] ?? ""
                    let from = shift["from"] ?? ""
                    guard !to.isEmpty else { continue }
                    let key = to.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                    if seen.contains(key) { continue }
                    seen.insert(key)
                    results.append(["from": from, "to": to, "date": dateShort])
                    if results.count >= limit { return results }
                }
            }
        }
        sqlite3_finalize(stmt)
        return results
    }

    /// Count of reflections (inputs) in the last N days, plus distinct sources touched.
    func getWeekInputSummary(days: Int = 7) -> (count: Int, sources: [String]) {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db else { return (0, []) }

        var count = 0
        var sources: Set<String> = []
        let sql = "SELECT source FROM reflections WHERE created_at >= datetime('now', '-\(days) days')"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                count += 1
                if let s = columnText(stmt, 0) { sources.insert(s) }
            }
        }
        sqlite3_finalize(stmt)
        return (count, Array(sources))
    }

    // MARK: - Tidy ("weekly review" surface)

    /// Returns themes that look like they need attention — stale (long-quiet, not archived)
    /// or thin (few reflections, old). Skips themes the user dismissed within `dismissCooldownDays`.
    ///
    /// Each candidate is one of:
    ///   - `reason: "stale"`   → suggest Archive (no activity in `staleDays`+ days, not already archived)
    ///   - `reason: "thin"`    → suggest Merge / Archive (≤ thinMaxReflections reflections, oldest >= thinMinAgeDays days)
    func getTidyCandidates(
        staleDays: Int = 45,
        thinMaxReflections: Int = 2,
        thinMinAgeDays: Int = 14,
        dismissCooldownDays: Int = 30,
        limit: Int = 8
    ) -> [[String: Any]] {
        // Lean on getThemesWithState for the aggregated view, then post-filter.
        // Look back far enough that low-volume themes are included.
        let themes = getThemesWithState(days: 365, limit: 500)
        guard !themes.isEmpty else { return [] }

        // Read dismissals from theme_states.state_history_json
        dbLock.lock()
        let dismissals: [String: Date] = {
            var out: [String: Date] = [:]
            guard let db = db else { return out }
            let sql = "SELECT theme, state_history_json FROM theme_states WHERE state_history_json LIKE '%tidy_dismissed%'"
            var stmt: OpaquePointer?
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let theme = columnText(stmt, 0) ?? ""
                    let json = columnText(stmt, 1) ?? "[]"
                    guard !theme.isEmpty,
                          let history = jsonDecode(json) as? [[String: String]] else { continue }
                    // Find most-recent tidy_dismissed entry
                    let dismissed = history
                        .filter { ($0["event"] ?? "") == "tidy_dismissed" }
                        .compactMap { iso.date(from: $0["at"] ?? "") }
                        .max()
                    if let d = dismissed { out[theme] = d }
                }
            }
            sqlite3_finalize(stmt)
            return out
        }()
        dbLock.unlock()

        let cooldownInterval = TimeInterval(dismissCooldownDays * 86400)
        let now = Date()

        var candidates: [[String: Any]] = []

        for t in themes {
            guard let name = t["theme"] as? String else { continue }
            // Skip archived
            if let state = t["state"] as? String, state == "archived" { continue }
            // Skip if dismissed recently
            if let lastDismiss = dismissals[name],
               now.timeIntervalSince(lastDismiss) < cooldownInterval { continue }

            let count = (t["count"] as? Int) ?? 0
            let daysSince = (t["days_since"] as? Int) ?? 0
            let openQs = (t["open_questions_count"] as? Int) ?? 0
            let state = (t["state"] as? String) ?? "researching"
            let lastActivity = (t["last_activity"] as? String) ?? ""

            // Thin candidates: very few reflections, old enough that they're unlikely to grow
            if count <= thinMaxReflections && daysSince >= thinMinAgeDays {
                candidates.append([
                    "theme": name,
                    "reason": "thin",
                    "count": count,
                    "days_since": daysSince,
                    "open_questions_count": openQs,
                    "state": state,
                    "last_activity": lastActivity,
                    "summary": "\(count) reflection\(count == 1 ? "" : "s"), oldest from \(daysSince) days ago — likely worth merging into something bigger, or archiving."
                ])
                continue
            }

            // Stale candidates: gone quiet for a long time
            if daysSince >= staleDays {
                candidates.append([
                    "theme": name,
                    "reason": "stale",
                    "count": count,
                    "days_since": daysSince,
                    "open_questions_count": openQs,
                    "state": state,
                    "last_activity": lastActivity,
                    "summary": "\(daysSince) days since last activity. Probably done — archive it?"
                ])
            }
        }

        // Sort: thin first (cheap wins), then stale by days_since desc
        candidates.sort { lhs, rhs in
            let lr = lhs["reason"] as? String ?? ""
            let rr = rhs["reason"] as? String ?? ""
            if lr != rr { return lr == "thin" }
            return ((lhs["days_since"] as? Int) ?? 0) > ((rhs["days_since"] as? Int) ?? 0)
        }

        return Array(candidates.prefix(limit))
    }

    /// Records that the user dismissed a tidy suggestion for `theme`. Re-suggestion is
    /// suppressed for the cooldown window (default 30 days, enforced by getTidyCandidates).
    func dismissTidy(theme: String) -> Bool {
        guard !theme.isEmpty else { return false }
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db else { return false }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let timestamp = iso.string(from: Date())
        let entry: [String: String] = ["event": "tidy_dismissed", "at": timestamp]

        // Read existing history (if row exists), append, write back.
        var history: [[String: String]] = []
        var currentState = "researching"
        var stmt: OpaquePointer?
        let readSql = "SELECT state, state_history_json FROM theme_states WHERE theme = ?"
        if sqlite3_prepare_v2(db, readSql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (theme as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            if sqlite3_step(stmt) == SQLITE_ROW {
                currentState = columnText(stmt, 0) ?? "researching"
                if let json = columnText(stmt, 1),
                   let decoded = jsonDecode(json) as? [[String: String]] {
                    history = decoded
                }
            }
        }
        sqlite3_finalize(stmt)
        history.append(entry)
        let historyJson = jsonEncode(history)

        let upsertSql = """
        INSERT INTO theme_states (theme, state, state_history_json, updated_at)
        VALUES (?, ?, ?, CURRENT_TIMESTAMP)
        ON CONFLICT(theme) DO UPDATE SET
            state_history_json = excluded.state_history_json,
            updated_at = CURRENT_TIMESTAMP
        """
        if sqlite3_prepare_v2(db, upsertSql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (theme as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 2, (currentState as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 3, (historyJson as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            let ok = sqlite3_step(stmt) == SQLITE_DONE
            sqlite3_finalize(stmt)
            return ok
        }
        sqlite3_finalize(stmt)
        return false
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
