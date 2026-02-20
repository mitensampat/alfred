import Foundation
import SQLite3

/// WorkflowLearningService - Captures learning from actual user workflows
/// Instead of learning from agent draft approvals, this learns from:
/// 1. Message/Commitment scans - what gets accepted/rejected
/// 2. Commitment lifecycle - completion patterns, counterparty reliability
/// 3. Task triage - status changes, priority accuracy
class WorkflowLearningService {
    static let shared = WorkflowLearningService()

    private let dbPath: String
    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "com.alfred.workflowlearning", qos: .utility)

    // MARK: - Initialization

    private init() {
        let homeDir = NSHomeDirectory()
        let alfredDir = "\(homeDir)/.alfred"

        // Ensure directory exists
        try? fileManager.createDirectory(atPath: alfredDir, withIntermediateDirectories: true)

        dbPath = "\(alfredDir)/workflow_learning.db"
        initializeDatabase()
    }

    private func initializeDatabase() {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            print("❌ WorkflowLearning: Failed to open database")
            return
        }
        defer { sqlite3_close(db) }

        // Scan feedback - tracks approval/rejection of extracted items
        let createScanFeedback = """
        CREATE TABLE IF NOT EXISTS scan_feedback (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            thread_id TEXT NOT NULL,
            thread_name TEXT,
            platform TEXT,
            item_type TEXT,
            accepted INTEGER NOT NULL,
            edited INTEGER DEFAULT 0,
            original_title TEXT,
            edited_title TEXT,
            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        CREATE INDEX IF NOT EXISTS idx_scan_thread ON scan_feedback(thread_id);
        CREATE INDEX IF NOT EXISTS idx_scan_timestamp ON scan_feedback(timestamp);
        """

        // Commitment lifecycle - tracks commitments from creation to completion
        let createCommitmentLifecycle = """
        CREATE TABLE IF NOT EXISTS commitment_lifecycle (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            commitment_hash TEXT NOT NULL,
            event_type TEXT NOT NULL,
            counterparty TEXT,
            commitment_type TEXT,
            priority TEXT,
            days_open INTEGER,
            was_overdue INTEGER DEFAULT 0,
            closure_method TEXT,
            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        CREATE INDEX IF NOT EXISTS idx_commitment_hash ON commitment_lifecycle(commitment_hash);
        CREATE INDEX IF NOT EXISTS idx_commitment_counterparty ON commitment_lifecycle(counterparty);
        """

        // Closure detection feedback - tracks AI closure detection accuracy
        let createClosureFeedback = """
        CREATE TABLE IF NOT EXISTS closure_detection_feedback (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            commitment_hash TEXT,
            commitment_title TEXT,
            signal TEXT,
            ai_confidence REAL,
            user_accepted INTEGER NOT NULL,
            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        """

        // Task triage events - tracks status changes and prioritization
        let createTaskTriage = """
        CREATE TABLE IF NOT EXISTS task_triage (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            task_id TEXT NOT NULL,
            task_type TEXT,
            from_status TEXT,
            to_status TEXT,
            priority TEXT,
            counterparty TEXT,
            days_in_previous_status INTEGER,
            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        CREATE INDEX IF NOT EXISTS idx_task_type ON task_triage(task_type);
        CREATE INDEX IF NOT EXISTS idx_task_timestamp ON task_triage(timestamp);
        """

        // Computed patterns - aggregated patterns for display and AI prompts
        let createComputedPatterns = """
        CREATE TABLE IF NOT EXISTS computed_patterns (
            pattern_id TEXT PRIMARY KEY,
            pattern_type TEXT NOT NULL,
            pattern_category TEXT NOT NULL,
            title TEXT NOT NULL,
            description TEXT,
            metric_value REAL,
            metric_label TEXT,
            sample_count INTEGER DEFAULT 0,
            confidence TEXT DEFAULT 'low',
            icon TEXT,
            last_computed DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        """

        // Execute all create statements
        for sql in [createScanFeedback, createCommitmentLifecycle, createClosureFeedback, createTaskTriage, createComputedPatterns] {
            var errMsg: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
                if let err = errMsg {
                    print("❌ WorkflowLearning: SQL error: \(String(cString: err))")
                    sqlite3_free(errMsg)
                }
            }
        }

        print("✅ WorkflowLearningService database initialized")
    }

    // MARK: - Scan Feedback Recording

    /// Record when user approves/rejects an extracted item from a scan
    func recordScanFeedback(
        threadId: String,
        threadName: String,
        platform: String,
        itemType: String,
        accepted: Bool,
        edited: Bool = false,
        originalTitle: String? = nil,
        editedTitle: String? = nil
    ) {
        queue.async { [weak self] in
            guard let self = self else { return }

            var db: OpaquePointer?
            guard sqlite3_open(self.dbPath, &db) == SQLITE_OK else { return }
            defer { sqlite3_close(db) }

            let sql = """
            INSERT INTO scan_feedback (thread_id, thread_name, platform, item_type, accepted, edited, original_title, edited_title)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, threadId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 2, threadName, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 3, platform, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 4, itemType, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_int(stmt, 5, accepted ? 1 : 0)
            sqlite3_bind_int(stmt, 6, edited ? 1 : 0)

            if let original = originalTitle {
                sqlite3_bind_text(stmt, 7, original, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            } else {
                sqlite3_bind_null(stmt, 7)
            }

            if let edited = editedTitle {
                sqlite3_bind_text(stmt, 8, edited, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            } else {
                sqlite3_bind_null(stmt, 8)
            }

            if sqlite3_step(stmt) == SQLITE_DONE {
                print("📊 WorkflowLearning: Recorded scan feedback - \(threadName) \(accepted ? "✓" : "✗") \(itemType)")
            }
        }
    }

    // MARK: - Commitment Lifecycle Recording

    /// Record when a commitment is created
    func recordCommitmentCreated(
        hash: String,
        counterparty: String,
        commitmentType: String,
        priority: String
    ) {
        queue.async { [weak self] in
            self?.insertCommitmentEvent(
                hash: hash,
                eventType: "created",
                counterparty: counterparty,
                commitmentType: commitmentType,
                priority: priority,
                daysOpen: nil,
                wasOverdue: false,
                closureMethod: nil
            )
        }
    }

    /// Record when a commitment is completed
    func recordCommitmentCompleted(
        hash: String,
        counterparty: String,
        commitmentType: String,
        daysOpen: Int,
        wasOverdue: Bool,
        closureMethod: String
    ) {
        queue.async { [weak self] in
            self?.insertCommitmentEvent(
                hash: hash,
                eventType: "completed",
                counterparty: counterparty,
                commitmentType: commitmentType,
                priority: nil,
                daysOpen: daysOpen,
                wasOverdue: wasOverdue,
                closureMethod: closureMethod
            )
        }
    }

    /// Record when a commitment is cancelled
    func recordCommitmentCancelled(
        hash: String,
        counterparty: String,
        commitmentType: String
    ) {
        queue.async { [weak self] in
            self?.insertCommitmentEvent(
                hash: hash,
                eventType: "cancelled",
                counterparty: counterparty,
                commitmentType: commitmentType,
                priority: nil,
                daysOpen: nil,
                wasOverdue: false,
                closureMethod: "manual"
            )
        }
    }

    private func insertCommitmentEvent(
        hash: String,
        eventType: String,
        counterparty: String,
        commitmentType: String,
        priority: String?,
        daysOpen: Int?,
        wasOverdue: Bool,
        closureMethod: String?
    ) {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }

        let sql = """
        INSERT INTO commitment_lifecycle (commitment_hash, event_type, counterparty, commitment_type, priority, days_open, was_overdue, closure_method)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, hash, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, eventType, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 3, counterparty, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 4, commitmentType, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        if let p = priority {
            sqlite3_bind_text(stmt, 5, p, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } else {
            sqlite3_bind_null(stmt, 5)
        }

        if let days = daysOpen {
            sqlite3_bind_int(stmt, 6, Int32(days))
        } else {
            sqlite3_bind_null(stmt, 6)
        }

        sqlite3_bind_int(stmt, 7, wasOverdue ? 1 : 0)

        if let method = closureMethod {
            sqlite3_bind_text(stmt, 8, method, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } else {
            sqlite3_bind_null(stmt, 8)
        }

        if sqlite3_step(stmt) == SQLITE_DONE {
            print("📊 WorkflowLearning: Recorded commitment \(eventType) - \(counterparty)")
        }
    }

    // MARK: - Closure Detection Feedback

    /// Record when user confirms/rejects an AI-detected closure
    func recordClosureDetectionFeedback(
        commitmentHash: String,
        commitmentTitle: String,
        signal: String,
        aiConfidence: Double,
        userAccepted: Bool
    ) {
        queue.async { [weak self] in
            guard let self = self else { return }

            var db: OpaquePointer?
            guard sqlite3_open(self.dbPath, &db) == SQLITE_OK else { return }
            defer { sqlite3_close(db) }

            let sql = """
            INSERT INTO closure_detection_feedback (commitment_hash, commitment_title, signal, ai_confidence, user_accepted)
            VALUES (?, ?, ?, ?, ?)
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, commitmentHash, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 2, commitmentTitle, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 3, signal, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_double(stmt, 4, aiConfidence)
            sqlite3_bind_int(stmt, 5, userAccepted ? 1 : 0)

            if sqlite3_step(stmt) == SQLITE_DONE {
                print("📊 WorkflowLearning: Recorded closure feedback - \(userAccepted ? "confirmed" : "rejected")")
            }
        }
    }

    // MARK: - Task Triage Recording

    /// Record when a task status changes
    func recordTaskStatusChange(
        taskId: String,
        taskType: String,
        fromStatus: String,
        toStatus: String,
        priority: String,
        counterparty: String?,
        daysInPreviousStatus: Int?
    ) {
        queue.async { [weak self] in
            guard let self = self else { return }

            var db: OpaquePointer?
            guard sqlite3_open(self.dbPath, &db) == SQLITE_OK else { return }
            defer { sqlite3_close(db) }

            let sql = """
            INSERT INTO task_triage (task_id, task_type, from_status, to_status, priority, counterparty, days_in_previous_status)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, taskId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 2, taskType, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 3, fromStatus, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 4, toStatus, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 5, priority, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            if let cp = counterparty {
                sqlite3_bind_text(stmt, 6, cp, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            } else {
                sqlite3_bind_null(stmt, 6)
            }

            if let days = daysInPreviousStatus {
                sqlite3_bind_int(stmt, 7, Int32(days))
            } else {
                sqlite3_bind_null(stmt, 7)
            }

            if sqlite3_step(stmt) == SQLITE_DONE {
                print("📊 WorkflowLearning: Recorded task status change - \(fromStatus) → \(toStatus)")
            }
        }
    }

    // MARK: - Pattern Computation

    /// Compute and store aggregated patterns from raw data
    func computePatterns() {
        queue.async { [weak self] in
            guard let self = self else { return }

            var db: OpaquePointer?
            guard sqlite3_open(self.dbPath, &db) == SQLITE_OK else { return }
            defer { sqlite3_close(db) }

            print("🧠 WorkflowLearning: Computing patterns...")

            // Clear old computed patterns
            sqlite3_exec(db, "DELETE FROM computed_patterns", nil, nil, nil)

            // 1. Thread relevance patterns
            self.computeThreadRelevancePatterns(db: db)

            // 2. Counterparty reliability patterns
            self.computeCounterpartyPatterns(db: db)

            // 3. Closure signal accuracy patterns
            self.computeClosureSignalPatterns(db: db)

            // 4. Task completion patterns
            self.computeTaskCompletionPatterns(db: db)

            // 5. Time-based patterns
            self.computeTimePatterns(db: db)

            print("✅ WorkflowLearning: Pattern computation complete")
        }
    }

    private func computeThreadRelevancePatterns(db: OpaquePointer?) {
        // Calculate acceptance rate per thread
        let sql = """
        SELECT thread_name, platform,
               COUNT(*) as total,
               SUM(CASE WHEN accepted = 1 THEN 1 ELSE 0 END) as accepted_count,
               ROUND(100.0 * SUM(CASE WHEN accepted = 1 THEN 1 ELSE 0 END) / COUNT(*), 1) as acceptance_rate
        FROM scan_feedback
        WHERE timestamp > datetime('now', '-30 days')
        GROUP BY thread_name
        HAVING COUNT(*) >= 3
        ORDER BY acceptance_rate DESC
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let threadName = String(cString: sqlite3_column_text(stmt, 0))
            let platform = String(cString: sqlite3_column_text(stmt, 1))
            let total = sqlite3_column_int(stmt, 2)
            let acceptanceRate = sqlite3_column_double(stmt, 4)

            let confidence = total >= 10 ? "high" : (total >= 5 ? "medium" : "low")
            let icon = acceptanceRate >= 80 ? "⭐" : (acceptanceRate >= 50 ? "📊" : "⚠️")

            let description = acceptanceRate >= 80 ?
                "High-quality source for actionable items" :
                (acceptanceRate >= 50 ? "Moderate quality - some useful extractions" : "Low yield - consider adjusting scan settings")

            insertComputedPattern(
                db: db,
                patternId: "thread_relevance_\(threadName.hashValue)",
                patternType: "thread_relevance",
                patternCategory: "Scan Quality",
                title: "\"\(threadName)\" yields \(Int(acceptanceRate))% useful items",
                description: description,
                metricValue: acceptanceRate,
                metricLabel: "\(total) scanned",
                sampleCount: Int(total),
                confidence: confidence,
                icon: icon
            )
        }
    }

    private func computeCounterpartyPatterns(db: OpaquePointer?) {
        // Get the user's own name so we can exclude self-referencing patterns
        let userName = AppConfig.load()?.user.name ?? ""

        // Calculate completion rate per counterparty
        let sql = """
        SELECT counterparty, commitment_type,
               COUNT(*) as total,
               SUM(CASE WHEN event_type = 'completed' THEN 1 ELSE 0 END) as completed,
               AVG(CASE WHEN event_type = 'completed' THEN days_open ELSE NULL END) as avg_days,
               ROUND(100.0 * SUM(CASE WHEN was_overdue = 1 THEN 1 ELSE 0 END) / NULLIF(SUM(CASE WHEN event_type = 'completed' THEN 1 ELSE 0 END), 0), 1) as overdue_rate
        FROM commitment_lifecycle
        WHERE timestamp > datetime('now', '-90 days')
          AND counterparty != ''
          AND counterparty IS NOT NULL
          AND LOWER(counterparty) != LOWER(?)
        GROUP BY counterparty, commitment_type
        HAVING COUNT(*) >= 2
        ORDER BY completed DESC
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        // Bind the user's name to exclude self-referencing patterns
        if let cString = userName.cString(using: .utf8) {
            sqlite3_bind_text(stmt, 1, cString, -1, nil)
        } else {
            sqlite3_bind_text(stmt, 1, "", -1, nil)
        }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let counterparty = String(cString: sqlite3_column_text(stmt, 0))
            let commitmentType = String(cString: sqlite3_column_text(stmt, 1))
            let total = sqlite3_column_int(stmt, 2)
            let completed = sqlite3_column_int(stmt, 3)
            let avgDays = sqlite3_column_double(stmt, 4)
            let overdueRate = sqlite3_column_double(stmt, 5)

            // Skip empty counterparties
            guard !counterparty.isEmpty else { continue }

            let completionRate = total > 0 ? Double(completed) / Double(total) * 100 : 0
            let confidence = total >= 5 ? "high" : "medium"

            let typeLabel = commitmentType == "I Owe" ? "Your commitments to" : "Commitments from"
            let icon = completionRate >= 80 ? "✅" : (completionRate >= 50 ? "⏳" : "⚠️")

            var description = ""
            if avgDays > 0 {
                description = "Average \(Int(avgDays)) days to completion"
                if overdueRate > 0 {
                    description += ", \(Int(overdueRate))% went overdue"
                }
            }

            insertComputedPattern(
                db: db,
                patternId: "counterparty_\(counterparty.hashValue)_\(commitmentType.hashValue)",
                patternType: "counterparty_reliability",
                patternCategory: "People Patterns",
                title: "\(typeLabel) \(counterparty): \(Int(completionRate))% completion",
                description: description,
                metricValue: completionRate,
                metricLabel: "\(completed)/\(total) completed",
                sampleCount: Int(total),
                confidence: confidence,
                icon: icon
            )
        }
    }

    private func computeClosureSignalPatterns(db: OpaquePointer?) {
        // Calculate accuracy per closure signal
        let sql = """
        SELECT signal,
               COUNT(*) as total,
               SUM(CASE WHEN user_accepted = 1 THEN 1 ELSE 0 END) as accepted,
               ROUND(100.0 * SUM(CASE WHEN user_accepted = 1 THEN 1 ELSE 0 END) / COUNT(*), 1) as accuracy,
               AVG(ai_confidence) as avg_confidence
        FROM closure_detection_feedback
        WHERE timestamp > datetime('now', '-60 days')
        GROUP BY signal
        HAVING COUNT(*) >= 2
        ORDER BY accuracy DESC
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let signal = String(cString: sqlite3_column_text(stmt, 0))
            let total = sqlite3_column_int(stmt, 1)
            let accuracy = sqlite3_column_double(stmt, 3)

            let confidence = total >= 5 ? "high" : "medium"
            let icon = accuracy >= 80 ? "🎯" : (accuracy >= 50 ? "📊" : "❌")

            let truncatedSignal = signal.count > 30 ? String(signal.prefix(30)) + "..." : signal

            insertComputedPattern(
                db: db,
                patternId: "closure_signal_\(signal.hashValue)",
                patternType: "closure_accuracy",
                patternCategory: "AI Accuracy",
                title: "\"\(truncatedSignal)\" closure signal: \(Int(accuracy))% accurate",
                description: accuracy >= 80 ? "Reliable closure indicator" : "Needs verification",
                metricValue: accuracy,
                metricLabel: "\(total) detections",
                sampleCount: Int(total),
                confidence: confidence,
                icon: icon
            )
        }
    }

    private func computeTaskCompletionPatterns(db: OpaquePointer?) {
        // Calculate completion patterns by task type
        let sql = """
        SELECT task_type,
               COUNT(*) as total,
               SUM(CASE WHEN to_status = 'Done' THEN 1 ELSE 0 END) as completed,
               AVG(CASE WHEN to_status = 'Done' THEN days_in_previous_status ELSE NULL END) as avg_days
        FROM task_triage
        WHERE timestamp > datetime('now', '-30 days')
        GROUP BY task_type
        HAVING COUNT(*) >= 3
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let taskType = String(cString: sqlite3_column_text(stmt, 0))
            let total = sqlite3_column_int(stmt, 1)
            let completed = sqlite3_column_int(stmt, 2)
            let avgDays = sqlite3_column_double(stmt, 3)

            let completionRate = total > 0 ? Double(completed) / Double(total) * 100 : 0
            let confidence = total >= 10 ? "high" : "medium"
            let icon = completionRate >= 80 ? "🚀" : (completionRate >= 50 ? "📈" : "📉")

            var description = ""
            if avgDays > 0 {
                description = "Average \(Int(avgDays)) days to completion"
            }

            insertComputedPattern(
                db: db,
                patternId: "task_completion_\(taskType.hashValue)",
                patternType: "task_completion",
                patternCategory: "Task Patterns",
                title: "\(taskType) tasks: \(Int(completionRate))% completion rate",
                description: description,
                metricValue: completionRate,
                metricLabel: "\(completed)/\(total) completed",
                sampleCount: Int(total),
                confidence: confidence,
                icon: icon
            )
        }
    }

    private func computeTimePatterns(db: OpaquePointer?) {
        // Day of week productivity patterns
        let sql = """
        SELECT
            CASE CAST(strftime('%w', timestamp) AS INTEGER)
                WHEN 0 THEN 'Sunday'
                WHEN 1 THEN 'Monday'
                WHEN 2 THEN 'Tuesday'
                WHEN 3 THEN 'Wednesday'
                WHEN 4 THEN 'Thursday'
                WHEN 5 THEN 'Friday'
                WHEN 6 THEN 'Saturday'
            END as day_name,
            CAST(strftime('%w', timestamp) AS INTEGER) as day_num,
            COUNT(*) as completions
        FROM task_triage
        WHERE to_status = 'Done'
          AND timestamp > datetime('now', '-30 days')
        GROUP BY day_num
        ORDER BY completions DESC
        LIMIT 3
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        var totalCompletions = 0
        var topDays: [(String, Int)] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let dayName = String(cString: sqlite3_column_text(stmt, 0))
            let completions = Int(sqlite3_column_int(stmt, 2))
            topDays.append((dayName, completions))
            totalCompletions += completions
        }

        if let topDay = topDays.first, totalCompletions >= 5 {
            let percentage = Double(topDay.1) / Double(totalCompletions) * 100

            insertComputedPattern(
                db: db,
                patternId: "productivity_day",
                patternType: "time_pattern",
                patternCategory: "Time Patterns",
                title: "Most productive on \(topDay.0)s",
                description: "\(Int(percentage))% of your task completions happen on \(topDay.0)s",
                metricValue: percentage,
                metricLabel: "\(topDay.1) completions",
                sampleCount: totalCompletions,
                confidence: totalCompletions >= 20 ? "high" : "medium",
                icon: "📅"
            )
        }
    }

    private func insertComputedPattern(
        db: OpaquePointer?,
        patternId: String,
        patternType: String,
        patternCategory: String,
        title: String,
        description: String,
        metricValue: Double,
        metricLabel: String,
        sampleCount: Int,
        confidence: String,
        icon: String
    ) {
        let sql = """
        INSERT OR REPLACE INTO computed_patterns
        (pattern_id, pattern_type, pattern_category, title, description, metric_value, metric_label, sample_count, confidence, icon, last_computed)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, patternId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, patternType, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 3, patternCategory, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 4, title, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 5, description, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_double(stmt, 6, metricValue)
        sqlite3_bind_text(stmt, 7, metricLabel, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int(stmt, 8, Int32(sampleCount))
        sqlite3_bind_text(stmt, 9, confidence, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 10, icon, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        sqlite3_step(stmt)
    }

    // MARK: - Pattern Retrieval

    /// Get all computed patterns grouped by category
    func getComputedPatterns() -> [String: [[String: Any]]] {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else { return [:] }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT pattern_id, pattern_type, pattern_category, title, description,
               metric_value, metric_label, sample_count, confidence, icon, last_computed
        FROM computed_patterns
        ORDER BY pattern_category, metric_value DESC
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }

        var patternsByCategory: [String: [[String: Any]]] = [:]

        while sqlite3_step(stmt) == SQLITE_ROW {
            let category = String(cString: sqlite3_column_text(stmt, 2))

            let pattern: [String: Any] = [
                "id": String(cString: sqlite3_column_text(stmt, 0)),
                "type": String(cString: sqlite3_column_text(stmt, 1)),
                "category": category,
                "title": String(cString: sqlite3_column_text(stmt, 3)),
                "description": String(cString: sqlite3_column_text(stmt, 4)),
                "metricValue": sqlite3_column_double(stmt, 5),
                "metricLabel": String(cString: sqlite3_column_text(stmt, 6)),
                "sampleCount": Int(sqlite3_column_int(stmt, 7)),
                "confidence": String(cString: sqlite3_column_text(stmt, 8)),
                "icon": String(cString: sqlite3_column_text(stmt, 9)),
                "lastComputed": String(cString: sqlite3_column_text(stmt, 10))
            ]

            if patternsByCategory[category] == nil {
                patternsByCategory[category] = []
            }
            patternsByCategory[category]?.append(pattern)
        }

        return patternsByCategory
    }

    /// Get patterns formatted for AI prompt context
    func getPatternContextForAI() -> String {
        let patterns = getComputedPatterns()
        guard !patterns.isEmpty else { return "" }

        var context = "## Learned User Patterns\n\n"

        // Thread relevance for scan context
        if let scanPatterns = patterns["Scan Quality"] {
            context += "### Thread Quality:\n"
            for pattern in scanPatterns.prefix(5) {
                let title = pattern["title"] as? String ?? ""
                context += "- \(title)\n"
            }
            context += "\n"
        }

        // Counterparty reliability for commitment context
        if let peoplePatterns = patterns["People Patterns"] {
            context += "### Counterparty Reliability:\n"
            for pattern in peoplePatterns.prefix(5) {
                let title = pattern["title"] as? String ?? ""
                context += "- \(title)\n"
            }
            context += "\n"
        }

        // Closure signal accuracy
        if let closurePatterns = patterns["AI Accuracy"] {
            context += "### Closure Signal Accuracy:\n"
            for pattern in closurePatterns.prefix(3) {
                let title = pattern["title"] as? String ?? ""
                context += "- \(title)\n"
            }
            context += "\n"
        }

        return context
    }

    // MARK: - Statistics

    /// Get summary statistics for the learning system
    func getSummary() -> [String: Any] {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else { return [:] }
        defer { sqlite3_close(db) }

        var summary: [String: Any] = [:]

        // Scan feedback stats
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT COUNT(*), SUM(accepted) FROM scan_feedback WHERE timestamp > datetime('now', '-30 days')", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                let total = sqlite3_column_int(stmt, 0)
                let accepted = sqlite3_column_int(stmt, 1)
                summary["scanFeedbackCount"] = Int(total)
                summary["scanAcceptanceRate"] = total > 0 ? Double(accepted) / Double(total) * 100 : 0
            }
            sqlite3_finalize(stmt)
        }

        // Commitment lifecycle stats
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM commitment_lifecycle WHERE timestamp > datetime('now', '-30 days')", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                summary["commitmentEventsCount"] = Int(sqlite3_column_int(stmt, 0))
            }
            sqlite3_finalize(stmt)
        }

        // Closure feedback stats
        if sqlite3_prepare_v2(db, "SELECT COUNT(*), AVG(CASE WHEN user_accepted = 1 THEN 100.0 ELSE 0 END) FROM closure_detection_feedback WHERE timestamp > datetime('now', '-30 days')", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                summary["closureFeedbackCount"] = Int(sqlite3_column_int(stmt, 0))
                summary["closureAccuracyRate"] = sqlite3_column_double(stmt, 1)
            }
            sqlite3_finalize(stmt)
        }

        // Task triage stats
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM task_triage WHERE timestamp > datetime('now', '-30 days')", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                summary["taskTriageCount"] = Int(sqlite3_column_int(stmt, 0))
            }
            sqlite3_finalize(stmt)
        }

        // Computed patterns count
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM computed_patterns", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                summary["computedPatternsCount"] = Int(sqlite3_column_int(stmt, 0))
            }
            sqlite3_finalize(stmt)
        }

        return summary
    }

    // MARK: - Email Digest

    /// Generate a learning digest suitable for email
    func generateLearningDigest() -> (subject: String, body: String)? {
        let patterns = getComputedPatterns()
        let summary = getSummary()

        let totalPatterns = summary["computedPatternsCount"] as? Int ?? 0
        guard totalPatterns > 0 else { return nil }

        let subject = "🧠 Alfred Learning Digest - \(totalPatterns) patterns observed"

        var body = """
        # Alfred Learning Digest

        Here's what I've learned from observing your workflows over the past 30 days.

        ---

        """

        // Summary stats
        let scanCount = summary["scanFeedbackCount"] as? Int ?? 0
        let commitmentCount = summary["commitmentEventsCount"] as? Int ?? 0
        let taskCount = summary["taskTriageCount"] as? Int ?? 0

        body += "## Activity Summary\n\n"
        body += "- 📊 \(scanCount) scan decisions analyzed\n"
        body += "- 🤝 \(commitmentCount) commitment lifecycle events tracked\n"
        body += "- ✅ \(taskCount) task status changes observed\n\n"

        // Patterns by category
        for (category, categoryPatterns) in patterns.sorted(by: { $0.key < $1.key }) {
            body += "## \(category)\n\n"

            for pattern in categoryPatterns.prefix(5) {
                let icon = pattern["icon"] as? String ?? "📊"
                let title = pattern["title"] as? String ?? ""
                let description = pattern["description"] as? String ?? ""
                let metricLabel = pattern["metricLabel"] as? String ?? ""

                body += "\(icon) **\(title)**\n"
                if !description.isEmpty {
                    body += "   \(description)"
                }
                if !metricLabel.isEmpty {
                    body += " (\(metricLabel))"
                }
                body += "\n\n"
            }
        }

        body += """
        ---

        These patterns help me provide better suggestions and prioritization for your commitments and tasks.

        — Alfred 🎩
        """

        return (subject, body)
    }
}
