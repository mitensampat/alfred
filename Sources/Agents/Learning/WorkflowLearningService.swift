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
    private var db: OpaquePointer?
    private let dbLock = NSLock()
    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "com.alfred.workflowlearning", qos: .utility)

    // MARK: - Exchange Buffer for LLM Classification (Phase 1: Learning v3)
    private var exchangeBuffer: [(userMessage: String, assistantResponse: String, timestamp: Date)] = []
    private let exchangeBufferLock = NSLock()
    private let exchangeBufferThreshold = 3  // Classify every N exchanges
    private var classificationInProgress = false

    // MARK: - Initialization

    private init() {
        let homeDir = NSHomeDirectory()
        let alfredDir = "\(homeDir)/.alfred"

        // Ensure directory exists
        try? fileManager.createDirectory(atPath: alfredDir, withIntermediateDirectories: true)

        dbPath = "\(alfredDir)/workflow_learning.db"

        if sqlite3_open(dbPath, &db) == SQLITE_OK {
            sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA synchronous=NORMAL", nil, nil, nil)
            initializeDatabase()
        } else {
            print("❌ WorkflowLearning: Failed to open database")
        }
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    private func initializeDatabase() {
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

        // Learning events - unified signal collection (Learning System v2)
        let createLearningEvents = """
        CREATE TABLE IF NOT EXISTS learning_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            event_type TEXT NOT NULL,
            context TEXT,
            signal_value TEXT,
            metadata_json TEXT,
            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        CREATE INDEX IF NOT EXISTS idx_learning_event_type ON learning_events(event_type);
        CREATE INDEX IF NOT EXISTS idx_learning_timestamp ON learning_events(timestamp);
        """

        // Learned patterns v2 - with confidence, staleness, conflict tracking
        let createLearnedPatterns = """
        CREATE TABLE IF NOT EXISTS learned_patterns (
            pattern_id TEXT PRIMARY KEY,
            pattern_type TEXT NOT NULL,
            description TEXT NOT NULL,
            confidence REAL DEFAULT 0.5,
            reinforcement_count INTEGER DEFAULT 1,
            contradiction_count INTEGER DEFAULT 0,
            source_event_types TEXT,
            is_direct_instruction INTEGER DEFAULT 0,
            is_stale INTEGER DEFAULT 0,
            is_archived INTEGER DEFAULT 0,
            last_reinforced DATETIME DEFAULT CURRENT_TIMESTAMP,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            metadata_json TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_learned_type ON learned_patterns(pattern_type);
        CREATE INDEX IF NOT EXISTS idx_learned_active ON learned_patterns(is_archived, is_stale);
        """

        // Pending pattern reviews - queue for Coach to surface
        let createPendingReviews = """
        CREATE TABLE IF NOT EXISTS pending_pattern_reviews (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            pattern_id TEXT NOT NULL,
            review_type TEXT NOT NULL,
            question TEXT NOT NULL,
            status TEXT DEFAULT 'pending',
            user_response TEXT,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            reviewed_at DATETIME,
            FOREIGN KEY (pattern_id) REFERENCES learned_patterns(pattern_id)
        );
        CREATE INDEX IF NOT EXISTS idx_review_status ON pending_pattern_reviews(status);
        """

        // Execute all create statements
        for sql in [createScanFeedback, createCommitmentLifecycle, createClosureFeedback, createTaskTriage, createComputedPatterns, createLearningEvents, createLearnedPatterns, createPendingReviews] {
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

            self.dbLock.lock()
            defer { self.dbLock.unlock() }

            let sql = """
            INSERT INTO scan_feedback (thread_id, thread_name, platform, item_type, accepted, edited, original_title, edited_title)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
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
        dbLock.lock()
        defer { dbLock.unlock() }

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

            self.dbLock.lock()
            defer { self.dbLock.unlock() }

            let sql = """
            INSERT INTO closure_detection_feedback (commitment_hash, commitment_title, signal, ai_confidence, user_accepted)
            VALUES (?, ?, ?, ?, ?)
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
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

            self.dbLock.lock()
            defer { self.dbLock.unlock() }

            let sql = """
            INSERT INTO task_triage (task_id, task_type, from_status, to_status, priority, counterparty, days_in_previous_status)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
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

            self.dbLock.lock()
            defer { self.dbLock.unlock() }

            print("🧠 WorkflowLearning: Computing patterns...")

            // Clear old computed patterns
            sqlite3_exec(self.db, "DELETE FROM computed_patterns", nil, nil, nil)

            // 1. Thread relevance patterns
            self.computeThreadRelevancePatterns()

            // 2. Counterparty reliability patterns
            self.computeCounterpartyPatterns()

            // 3. Closure signal accuracy patterns
            self.computeClosureSignalPatterns()

            // 4. Task completion patterns
            self.computeTaskCompletionPatterns()

            // 5. Time-based patterns
            self.computeTimePatterns()

            print("✅ WorkflowLearning: Pattern computation complete")
        }
    }

    private func computeThreadRelevancePatterns() {
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

    private func computeCounterpartyPatterns() {
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

    private func computeClosureSignalPatterns() {
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

    private func computeTaskCompletionPatterns() {
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

    private func computeTimePatterns() {
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
        dbLock.lock()
        defer { dbLock.unlock() }

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
        dbLock.lock()
        defer { dbLock.unlock() }

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

    /// Generate a learning digest suitable for email (HTML formatted)
    func generateLearningDigest() -> (subject: String, body: String)? {
        let patterns = getComputedPatterns()
        let summary = getSummary()

        let totalPatterns = summary["computedPatternsCount"] as? Int ?? 0
        guard totalPatterns > 0 else { return nil }

        let subject = "🧠 Coach Alfred: Learning Digest - \(totalPatterns) patterns observed"

        // Summary stats
        let scanCount = summary["scanFeedbackCount"] as? Int ?? 0
        let commitmentCount = summary["commitmentEventsCount"] as? Int ?? 0
        let taskCount = summary["taskTriageCount"] as? Int ?? 0

        // v2 learned patterns
        let learnedPatterns = getLearnedPatterns()
        let directCount = learnedPatterns.filter { $0.isDirect }.count
        let commCount = learnedPatterns.filter { $0.type == "communication_style" }.count

        var patternRows = ""
        for (category, categoryPatterns) in patterns.sorted(by: { $0.key < $1.key }) {
            patternRows += "<tr><td colspan='3' style='padding:12px 0 6px;font-weight:600;font-size:15px;color:#1b2a4a;border-bottom:1px solid #e4e2dc;'>\(category)</td></tr>"

            for pattern in categoryPatterns.prefix(5) {
                let icon = pattern["icon"] as? String ?? "📊"
                let title = pattern["title"] as? String ?? ""
                let description = pattern["description"] as? String ?? ""
                let metricLabel = pattern["metricLabel"] as? String ?? ""

                patternRows += """
                <tr>
                    <td style='padding:6px 8px 6px 0;font-size:18px;vertical-align:top;width:28px;'>\(icon)</td>
                    <td style='padding:6px 0;'>
                        <div style='font-weight:500;color:#1b2a4a;'>\(title)</div>
                        \(!description.isEmpty ? "<div style='color:#5c6370;font-size:13px;'>\(description)</div>" : "")
                    </td>
                    <td style='padding:6px 0 6px 8px;color:#8890a0;font-size:12px;text-align:right;white-space:nowrap;vertical-align:top;'>\(metricLabel)</td>
                </tr>
                """
            }
        }

        // v2 learned patterns section
        var learnedRows = ""
        if !learnedPatterns.isEmpty {
            let displayPatterns = learnedPatterns.prefix(8)
            for p in displayPatterns {
                let badge = p.isDirect ? "⚡" : (p.type == "communication_style" ? "💬" : "🔍")
                let confPct = Int(p.confidence * 100)
                learnedRows += """
                <tr>
                    <td style='padding:4px 8px 4px 0;font-size:16px;vertical-align:top;width:24px;'>\(badge)</td>
                    <td style='padding:4px 0;color:#1b2a4a;font-size:13px;'>\(p.description)</td>
                    <td style='padding:4px 0 4px 8px;color:#8890a0;font-size:12px;text-align:right;white-space:nowrap;'>\(confPct)%</td>
                </tr>
                """
            }
        }

        let fontBody = "font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif;"
        let fontDisplay = "font-family: 'Playfair Display', Georgia, 'Times New Roman', serif;"

        let body = NotificationService.emailHead()
        + "<div style=\"\(fontDisplay) font-size: 22px; font-weight: 400; color: #1b2a4a; margin-bottom: 4px;\">Learning Digest</div>"
        + "<div style=\"\(fontBody) font-size: 12px; color: #8890a0; margin-bottom: 16px;\">What Alfred learned from observing your workflows (last 30 days)</div>"
        + """
            <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin-bottom: 16px; border-spacing: 8px; border-collapse: separate;">
            <tr>
                <td style="background-color: #f0eeea; border-radius: 6px; padding: 12px 8px; text-align: center; width: 33%;">
                    <div style="\(fontBody) font-size: 20px; font-weight: 600; color: #1b2a4a;">\(commitmentCount)</div>
                    <div style="\(fontBody) font-size: 11px; color: #5c6370; margin-top: 2px;">Commitment Events</div>
                </td>
                <td style="background-color: #f0eeea; border-radius: 6px; padding: 12px 8px; text-align: center; width: 33%;">
                    <div style="\(fontBody) font-size: 20px; font-weight: 600; color: #1b2a4a;">\(taskCount)</div>
                    <div style="\(fontBody) font-size: 11px; color: #5c6370; margin-top: 2px;">Task Changes</div>
                </td>
                <td style="background-color: #f0eeea; border-radius: 6px; padding: 12px 8px; text-align: center; width: 33%;">
                    <div style="\(fontBody) font-size: 20px; font-weight: 600; color: #1b2a4a;">\(scanCount)</div>
                    <div style="\(fontBody) font-size: 11px; color: #5c6370; margin-top: 2px;">Scan Decisions</div>
                </td>
            </tr>
            </table>

            <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin-top: 28px; margin-bottom: 14px;">
            <tr>
                <td style="\(fontBody) font-size: 11px; font-weight: 600; color: #5c6370; text-transform: uppercase; letter-spacing: 0.06em; white-space: nowrap; padding-right: 12px;">Workflow Patterns</td>
                <td style="width: 100%;"><div style="height: 1px; background-color: #e4e2dc;"></div></td>
            </tr>
            </table>
            <table style='width:100%;border-collapse:collapse;' role="presentation">
                \(patternRows)
            </table>
        """
        + (!learnedRows.isEmpty ? """
            <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin-top: 28px; margin-bottom: 14px;">
            <tr>
                <td style="\(fontBody) font-size: 11px; font-weight: 600; color: #5c6370; text-transform: uppercase; letter-spacing: 0.06em; white-space: nowrap; padding-right: 12px;">Learned Preferences · \(learnedPatterns.count) active</td>
                <td style="width: 100%;"><div style="height: 1px; background-color: #e4e2dc;"></div></td>
            </tr>
            </table>
            <div style="\(fontBody) margin: 0 0 8px; font-size: 11px; color: #8890a0;">⚡ = explicit instruction &nbsp; 💬 = communication style &nbsp; 🔍 = observed</div>
            <table style='width:100%;border-collapse:collapse;' role="presentation">
                \(learnedRows)
            </table>
        """ : "")
        + NotificationService.emailFoot()

        return (subject, body)
    }

    // MARK: - Learning System v2: Signal Collection (Phase 1)

    /// Record a learning event — the universal signal collector
    func recordLearningEvent(
        eventType: String,
        context: String? = nil,
        signalValue: String? = nil,
        metadata: [String: Any]? = nil
    ) {
        queue.async { [weak self] in
            guard let self = self else { return }

            self.dbLock.lock()
            defer { self.dbLock.unlock() }

            let sql = """
            INSERT INTO learning_events (event_type, context, signal_value, metadata_json)
            VALUES (?, ?, ?, ?)
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, eventType, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            if let ctx = context {
                sqlite3_bind_text(stmt, 2, ctx, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            } else {
                sqlite3_bind_null(stmt, 2)
            }

            if let val = signalValue {
                sqlite3_bind_text(stmt, 3, val, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            } else {
                sqlite3_bind_null(stmt, 3)
            }

            if let meta = metadata, let jsonData = try? JSONSerialization.data(withJSONObject: meta),
               let jsonStr = String(data: jsonData, encoding: .utf8) {
                sqlite3_bind_text(stmt, 4, jsonStr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            } else {
                sqlite3_bind_null(stmt, 4)
            }

            if sqlite3_step(stmt) == SQLITE_DONE {
                print("🧠 Learning: Recorded \(eventType) event")
            }
        }
    }

    /// Detect and record corrections from a chat exchange (Learning v3: Hybrid keyword + LLM)
    ///
    /// Fast-path: keyword detection for direct instructions and obvious corrections (synchronous, zero latency)
    /// Slow-path: LLM classification for subtle signals (async, batched every 3 exchanges)
    func detectAndRecordCorrections(userMessage: String, assistantResponse: String, config: AppConfig? = nil) {
        let lower = userMessage.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // ── Fast-path: Keyword detection for direct instructions & context facts ──
        // These are high-signal, zero-ambiguity — no LLM needed
        let preferencePatterns: [(pattern: String, type: String)] = [
            ("always ", "explicit_preference"),
            ("never ", "explicit_preference"),
            ("don't ever ", "explicit_preference"),
            ("stop ", "explicit_preference"),
            ("from now on", "explicit_preference"),
            ("going forward", "explicit_preference"),
            ("i prefer ", "explicit_preference"),
            ("i don't like ", "explicit_preference"),
            ("i want you to ", "explicit_preference"),
            ("remember that ", "explicit_preference"),
            ("keep in mind ", "explicit_preference"),
            // User context facts
            ("update your memory", "user_context"),
            ("update memory", "user_context"),
            ("remember this", "user_context"),
            ("note that ", "user_context"),
            ("know that i", "user_context"),
            ("i am the ", "user_context"),
            ("i lead ", "user_context"),
            ("my role is", "user_context"),
            ("my role ", "user_context")
        ]

        for pref in preferencePatterns {
            if lower.contains(pref.pattern) {
                let eventType = pref.type == "user_context" ? "user_context_fact" : "direct_instruction"
                recordLearningEvent(
                    eventType: eventType,
                    context: userMessage,
                    signalValue: pref.pattern.trimmingCharacters(in: .whitespaces),
                    metadata: [
                        "trigger_phrase": pref.pattern,
                        "full_message": userMessage,
                        "detected_by": "keyword_fast_path"
                    ]
                )

                // Learning v3: Check for contradictions with existing patterns
                if eventType == "direct_instruction" {
                    checkAndDecayContradictions(newInstruction: userMessage)
                }

                break // One event per message
            }
        }

        // ── Fast-path: Keyword detection for obvious corrections ──
        let falsePositives = [
            "no problem", "no worries", "no rush", "no need to", "no thanks",
            "no issue", "no doubt", "no way!", "no kidding", "actually good",
            "actually great", "actually perfect", "actually works", "actually like",
            "stop by", "stop in", "stop for", "never mind that", "i said yes",
            "i said sure", "i said ok", "i said thanks"
        ]

        let isFalsePositive = falsePositives.contains { lower.contains($0) }

        let startOfMessageCorrections = [
            "no, ", "no that's", "nope,", "wrong.", "wrong,", "incorrect"
        ]
        let anywhereCorrections = [
            "that's wrong", "that's not right", "that's not what i",
            "you got that wrong", "you misunderstood", "not what i meant",
            "not what i asked", "i didn't say that", "i didn't ask for",
            "don't do that", "stop doing that", "you're confusing",
            "wrong person", "wrong name", "wrong contact", "wrong thread",
            "it was actually", "i meant "
        ]

        let startsWithCorrection = startOfMessageCorrections.contains { lower.hasPrefix($0) }
        let containsCorrection = anywhereCorrections.contains { lower.contains($0) }
        let isKeywordCorrection = !isFalsePositive && (startsWithCorrection || containsCorrection)

        if isKeywordCorrection {
            recordLearningEvent(
                eventType: "chat_correction",
                context: userMessage,
                signalValue: String(assistantResponse.prefix(500)),
                metadata: ["detected_by": "keyword_match"]
            )
        }

        // ── Slow-path: Buffer exchange for LLM classification ──
        bufferExchangeForClassification(
            userMessage: userMessage,
            assistantResponse: assistantResponse,
            config: config
        )
    }

    // MARK: - LLM-Based Signal Classification (Learning v3)

    /// Buffer a chat exchange and trigger LLM classification when threshold is reached
    private func bufferExchangeForClassification(userMessage: String, assistantResponse: String, config: AppConfig?) {
        exchangeBufferLock.lock()
        exchangeBuffer.append((
            userMessage: userMessage,
            assistantResponse: String(assistantResponse.prefix(300)),
            timestamp: Date()
        ))

        // Trim buffer to last 5 exchanges max
        if exchangeBuffer.count > 5 {
            exchangeBuffer = Array(exchangeBuffer.suffix(5))
        }

        let shouldClassify = exchangeBuffer.count >= exchangeBufferThreshold && !classificationInProgress
        let bufferedExchanges = shouldClassify ? exchangeBuffer : []
        if shouldClassify {
            classificationInProgress = true
        }
        exchangeBufferLock.unlock()

        guard shouldClassify, let config = config else {
            if shouldClassify && config == nil {
                print("⚠️ Learning v3: Classification skipped — config is nil")
                exchangeBufferLock.lock()
                classificationInProgress = false
                exchangeBufferLock.unlock()
            }
            return
        }

        print("🧠 Learning v3: Triggering LLM classification for \(bufferedExchanges.count) exchanges")

        // Run classification async — does not block the chat response
        Task {
            await classifyExchangeSignals(exchanges: bufferedExchanges, config: config)

            exchangeBufferLock.lock()
            classificationInProgress = false
            exchangeBuffer.removeAll()
            exchangeBufferLock.unlock()
        }
    }

    /// Use Haiku to classify a batch of chat exchanges for learning signals
    private func classifyExchangeSignals(exchanges: [(userMessage: String, assistantResponse: String, timestamp: Date)], config: AppConfig) async {
        print("🧠 Learning v3: classifyExchangeSignals called with \(exchanges.count) exchanges")
        let claudeService = ClaudeAIService(config: config.ai, userName: config.user.name)

        let exchangesList = exchanges.enumerated().map { i, ex in
            """
            Exchange \(i + 1):
            User: "\(ex.userMessage.prefix(200))"
            Assistant: "\(ex.assistantResponse.prefix(200))"
            """
        }.joined(separator: "\n\n")

        let prompt = """
        Analyze these chat exchanges between a user and their AI assistant. For each exchange, classify the user's message.

        \(exchangesList)

        Return ONLY valid JSON (no markdown fences):
        {
            "signals": [
                {
                    "exchange": 1,
                    "type": "correction|preference|reinforcement|fact|none",
                    "content": "A durable belief about the user phrased as a standing rule, NOT narration of what they said",
                    "confidence": 0.8
                }
            ]
        }

        Classification rules:
        - "correction": User is disagreeing, correcting, or expressing dissatisfaction (even subtly: "hmm not quite", "close but", "I actually meant", "that's not what I was looking for")
        - "preference": A durable, recurring preference about how the assistant should behave (tone, format, detail level). NOT a one-off ask for a specific task.
        - "reinforcement": User confirming the assistant did something well ("exactly", "perfect", "yes like that", "great")
        - "fact": User sharing durable biographical info (role, team, relationships) — NOT what they want done right now
        - "none": One-off request, transactional query, or anything that won't hold across future conversations

        CRITICAL: the "content" field MUST read as a durable belief, phrased like a standing instruction. NEVER narrate what the user just said.
        BAD examples (DO NOT produce these):
          ❌ "User is expressing a preference for high-impact summaries"
          ❌ "User wants WhatsApp messages from CRED filtered by today"
          ❌ "User is requesting summaries organized by thread"
        GOOD examples:
          ✅ "Prefers high-impact summaries over comprehensive tactical detail"
          ✅ "Leads growth at CRED"
          ✅ "Wants thread-grouped summaries when reviewing team messages"
        Rules for content:
        - Never start with "User is", "User wants", "User prefers", "User requested", "User expressed", "Indicates"
        - Write as a standing fact or rule, in the third person ("Prefers X", "Leads Y", "Avoids Z")
        - If you can't extract something that would still be true in future conversations, set type="none"
        - A single one-off task request is NOT a preference — it's "none". Only flag as "preference" if the user has signaled this as a recurring standard.

        Be sensitive to subtle signals on tone, but be conservative on what qualifies as a durable belief. When in doubt, use "none".
        """

        do {
            let response = try await claudeService.generateText(
                prompt: prompt,
                system: "You classify chat exchanges for behavioral learning signals. Be precise and sensitive to subtle cues.",
                maxTokens: 400,
                useModel: "claude-haiku-4-5-20251001"
            )

            // Strip markdown fences if present (Haiku sometimes wraps JSON in ```json...```)
            var cleanResponse = response.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleanResponse.contains("```") {
                cleanResponse = cleanResponse
                    .replacingOccurrences(of: "```json", with: "")
                    .replacingOccurrences(of: "```", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            guard let jsonData = cleanResponse.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let signals = json["signals"] as? [[String: Any]] else {
                print("⚠️ Learning v3: Could not parse classification response: \(cleanResponse.prefix(200))")
                return
            }

            var signalCount = 0
            for signal in signals {
                guard let type = signal["type"] as? String,
                      let content = signal["content"] as? String,
                      let confidence = signal["confidence"] as? Double,
                      let exchangeIdx = signal["exchange"] as? Int,
                      type != "none",
                      confidence >= 0.6 else { continue }

                let exchange = exchanges[min(exchangeIdx - 1, exchanges.count - 1)]

                switch type {
                case "correction":
                    // Only record if keyword detector didn't already catch it
                    let alreadyCaught = isKeywordCorrection(message: exchange.userMessage)
                    if !alreadyCaught {
                        recordLearningEvent(
                            eventType: "chat_correction",
                            context: exchange.userMessage,
                            signalValue: content,
                            metadata: [
                                "detected_by": "llm_classification",
                                "confidence": confidence,
                                "assistant_response": String(exchange.assistantResponse.prefix(300))
                            ]
                        )
                        signalCount += 1
                    }

                case "preference":
                    // Check if keyword fast-path already caught this as direct_instruction
                    let alreadyCaught = isKeywordPreference(message: exchange.userMessage)
                    if !alreadyCaught {
                        recordLearningEvent(
                            eventType: "chat_preference",
                            context: exchange.userMessage,
                            signalValue: content,
                            metadata: [
                                "detected_by": "llm_classification",
                                "confidence": confidence
                            ]
                        )
                        // Learning v3: Immediate pattern creation only when the signal is
                        // (a) phrased as a durable belief (not narration) AND
                        // (b) recurring — at least one prior similar preference event exists.
                        // Single-shot promotion produced shallow "User is expressing…" patterns.
                        if confidence >= 0.85
                            && !isShallowNarration(content)
                            && hasRecurringPreferenceSignal(content: content) {
                            createImmediatePattern(
                                description: content,
                                type: "communication_style",
                                confidence: 0.7,
                                sourceEvent: "chat_preference"
                            )
                        }
                        signalCount += 1
                    }

                case "reinforcement":
                    recordLearningEvent(
                        eventType: "reinforcement",
                        context: exchange.userMessage,
                        signalValue: content,
                        metadata: [
                            "detected_by": "llm_classification",
                            "confidence": confidence,
                            "assistant_response": String(exchange.assistantResponse.prefix(300))
                        ]
                    )
                    signalCount += 1

                case "fact":
                    // Check if keyword fast-path already caught this as user_context_fact
                    let alreadyCaught = isKeywordContextFact(message: exchange.userMessage)
                    if !alreadyCaught {
                        recordLearningEvent(
                            eventType: "user_context_fact",
                            context: exchange.userMessage,
                            signalValue: content,
                            metadata: [
                                "detected_by": "llm_classification",
                                "confidence": confidence
                            ]
                        )
                        signalCount += 1
                    }

                default:
                    break
                }
            }

            if signalCount > 0 {
                print("🧠 Learning v3: LLM classified \(signalCount) signals from \(exchanges.count) exchanges")
            }
        } catch {
            print("⚠️ Learning v3: Classification failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Contradiction Detection (Learning v3)

    /// Check existing patterns for contradictions with a new instruction and decay them
    private func checkAndDecayContradictions(newInstruction: String) {
        let newWords = Set(newInstruction.lowercased().split(separator: " ").filter { $0.count > 3 }.map(String.init))
        guard newWords.count >= 2 else { return }

        dbLock.lock()
        defer { dbLock.unlock() }

        // Get all active non-archived patterns
        let sql = "SELECT pattern_id, description, confidence FROM learned_patterns WHERE is_archived = 0"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }

        var contradictions: [(id: String, description: String, overlap: Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let desc = String(cString: sqlite3_column_text(stmt, 1))
            let descWords = Set(desc.lowercased().split(separator: " ").filter { $0.count > 3 }.map(String.init))

            // Check for significant word overlap (potential contradiction)
            let overlap = newWords.intersection(descWords).count
            let overlapRatio = Double(overlap) / Double(min(newWords.count, descWords.count))

            // If >30% word overlap, this is a potential contradiction
            if overlapRatio > 0.3 && overlap >= 2 {
                contradictions.append((id, desc, overlap))
            }
        }
        sqlite3_finalize(stmt)

        // Decay confidence of contradicting patterns
        for contradiction in contradictions {
            let decaySql = """
            UPDATE learned_patterns
            SET confidence = MAX(0.1, confidence * 0.7),
                contradiction_count = contradiction_count + 1,
                metadata_json = json_set(COALESCE(metadata_json, '{}'), '$.last_contradiction', ?)
            WHERE pattern_id = ? AND is_direct_instruction = 0
            """
            var decayStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, decaySql, -1, &decayStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(decayStmt, 1, newInstruction.prefix(200).description, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_text(decayStmt, 2, contradiction.id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                if sqlite3_step(decayStmt) == SQLITE_DONE {
                    print("🧠 Learning v3: Decayed contradicting pattern '\(contradiction.id)' — '\(contradiction.description.prefix(40))'")
                }
                sqlite3_finalize(decayStmt)
            }

            // Record the contradiction as a learning event
            recordLearningEvent(
                eventType: "pattern_contradiction",
                context: "New: \(newInstruction.prefix(100)) | Old: \(contradiction.description.prefix(100))",
                signalValue: contradiction.id,
                metadata: ["overlap_words": contradiction.overlap, "old_pattern_id": contradiction.id]
            )
        }
    }

    /// Create a learned pattern immediately from a high-confidence signal (Learning v3: fast feedback loop)
    /// The pattern is active right away (confidence 0.7) and still queued for review to boost to 1.0
    private func createImmediatePattern(description: String, type: String, confidence: Double, sourceEvent: String) {
        let patternId = "imm_\(abs(description.hashValue))"

        dbLock.lock()
        defer { dbLock.unlock() }

        // Check if a similar pattern already exists
        let checkSql = "SELECT pattern_id, confidence FROM learned_patterns WHERE pattern_id = ? OR (pattern_type = ? AND description = ?)"
        var checkStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, checkSql, -1, &checkStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(checkStmt, 1, patternId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(checkStmt, 2, type, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(checkStmt, 3, description, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            if sqlite3_step(checkStmt) == SQLITE_ROW {
                // Already exists — reinforce instead
                let existingId = String(cString: sqlite3_column_text(checkStmt, 0))
                sqlite3_finalize(checkStmt)

                let updateSql = "UPDATE learned_patterns SET confidence = MIN(1.0, confidence + 0.1), reinforcement_count = reinforcement_count + 1, last_reinforced = datetime('now'), is_stale = 0 WHERE pattern_id = ?"
                var updateStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, updateSql, -1, &updateStmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(updateStmt, 1, existingId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    sqlite3_step(updateStmt)
                    sqlite3_finalize(updateStmt)
                }
                print("🧠 Learning v3: Reinforced existing pattern '\(existingId)'")
                return
            }
            sqlite3_finalize(checkStmt)
        }

        // Insert new immediate pattern
        let insertSql = """
        INSERT INTO learned_patterns
        (pattern_id, pattern_type, description, confidence, reinforcement_count,
         source_event_types, last_reinforced, is_direct_instruction)
        VALUES (?, ?, ?, ?, 1, ?, datetime('now'), 0)
        """
        var insertStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, insertSql, -1, &insertStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(insertStmt, 1, patternId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(insertStmt, 2, type, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(insertStmt, 3, description, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_double(insertStmt, 4, confidence)
            sqlite3_bind_text(insertStmt, 5, sourceEvent, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_step(insertStmt)
            sqlite3_finalize(insertStmt)

            print("🧠 Learning v3: Immediate pattern created — '\(description.prefix(60))' (confidence \(confidence))")
        }
    }

    /// Check if the keyword detector would have caught this as a correction
    private func isKeywordCorrection(message: String) -> Bool {
        let lower = message.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let falsePositives = [
            "no problem", "no worries", "no rush", "no need to", "no thanks",
            "no issue", "no doubt", "no way!", "no kidding", "actually good",
            "actually great", "actually perfect", "actually works", "actually like",
            "stop by", "stop in", "stop for", "never mind that"
        ]
        if falsePositives.contains(where: { lower.contains($0) }) { return false }

        let starts = ["no, ", "no that's", "nope,", "wrong.", "wrong,", "incorrect"]
        let anywhere = [
            "that's wrong", "that's not right", "that's not what i",
            "you got that wrong", "you misunderstood", "not what i meant",
            "not what i asked", "i didn't say that", "i didn't ask for",
            "don't do that", "stop doing that", "you're confusing",
            "wrong person", "wrong name", "wrong contact", "wrong thread",
            "it was actually", "i meant "
        ]
        return starts.contains(where: { lower.hasPrefix($0) }) || anywhere.contains(where: { lower.contains($0) })
    }

    /// Check if the keyword detector would have caught this as a preference/instruction
    private func isKeywordPreference(message: String) -> Bool {
        let lower = message.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let keywords = ["always ", "never ", "don't ever ", "stop ", "from now on",
                        "going forward", "i prefer ", "i don't like ", "i want you to ",
                        "remember that ", "keep in mind "]
        return keywords.contains(where: { lower.contains($0) })
    }

    /// Reject procedural narration like "User is expressing…", "User wants…".
    /// A durable belief is phrased as a standing rule ("Prefers X"), not a description of what was said.
    private func isShallowNarration(_ text: String) -> Bool {
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let badPrefixes = [
            "user is ", "user was ", "user wants ", "user wanted ",
            "user prefers ", "user preferred ", "user requested ", "user requests ",
            "user asked ", "user said ", "user expressed ", "user indicates ",
            "user is expressing ", "user is requesting ", "user is asking ",
            "user is sharing ", "user is confirming ", "indicates that ",
            "the user "
        ]
        if badPrefixes.contains(where: { lower.hasPrefix($0) }) { return true }
        let badMarkers = ["is expressing a preference", "is requesting", "suggesting preference"]
        return badMarkers.contains(where: { lower.contains($0) })
    }

    /// Detect raw transactional user messages that were captured verbatim as user_context
    /// "beliefs" — questions, imperative commands, time-specific one-off requests.
    /// These aren't durable facts and shouldn't be stored as such.
    private func isTransactionalMessage(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        // Questions are not durable beliefs
        if trimmed.hasSuffix("?") { return true }

        // Imperative / interrogative openers — these are commands or questions, not facts
        let transactionalPrefixes = [
            "block ", "show ", "show me", "summarize", "summarise", "list ",
            "add a ", "add task", "create ", "delete ", "remove ", "update ",
            "can you ", "could you ", "please ", "would you ", "will you ",
            "how am i", "how do i", "how is ", "how are ", "how was ",
            "what ", "when ", "where ", "why ", "who ", "which ",
            "do you ", "did you ", "are you ", "is there ", "is it ",
            "give me ", "tell me ", "find ", "look up ", "schedule ",
            "send ", "draft ", "write ", "remind me",
            "1)", "2)", "3)", "- "
        ]
        if transactionalPrefixes.contains(where: { lower.hasPrefix($0) }) { return true }

        // Contains specific date/time references suggesting a one-off task
        // (durable beliefs don't reference "tomorrow at 3pm" or "next Monday")
        let temporalMarkers = [
            "tomorrow at", "today at", "yesterday at",
            "next monday", "next tuesday", "next wednesday", "next thursday",
            "next friday", "next saturday", "next sunday",
            " at 9am", " at 10am", " at 11am", " at 12pm", " at 1pm", " at 2pm",
            " at 3pm", " at 4pm", " at 5pm", " at 6pm", " at 7pm", " at 8pm",
            " 9.30pm", " 10.30am", " 11.30am", " 5:45 pm", " 10:30",
            "due date", "this week", "by friday", "by monday"
        ]
        if temporalMarkers.contains(where: { lower.contains($0) }) { return true }

        return false
    }

    /// Check whether a similar preference signal has already been recorded — used to gate
    /// immediate-pattern promotion so single one-off asks don't become durable patterns.
    private func hasRecurringPreferenceSignal(content: String) -> Bool {
        let words = Set(content.lowercased().split(separator: " ").filter { $0.count > 3 }.map(String.init))
        guard words.count >= 2 else { return false }

        dbLock.lock()
        defer { dbLock.unlock() }

        let sql = """
        SELECT signal_value FROM learning_events
        WHERE event_type = 'chat_preference'
          AND timestamp > datetime('now', '-30 days')
        ORDER BY timestamp DESC
        LIMIT 50
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }

        // We need at least one OTHER event with significant overlap (the just-recorded one
        // is in the table too — require ≥2 matches so this isn't the only occurrence).
        var matches = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            let signal = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let signalWords = Set(signal.lowercased().split(separator: " ").filter { $0.count > 3 }.map(String.init))
            let overlap = words.intersection(signalWords).count
            let ratio = Double(overlap) / Double(min(words.count, max(signalWords.count, 1)))
            if ratio >= 0.5 && overlap >= 2 {
                matches += 1
                if matches >= 2 { return true }
            }
        }
        return false
    }

    /// Check if the keyword detector would have caught this as a context fact
    private func isKeywordContextFact(message: String) -> Bool {
        let lower = message.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let keywords = ["update your memory", "update memory", "remember this", "note that ",
                        "know that i", "i am the ", "i lead ", "my role is", "my role "]
        return keywords.contains(where: { lower.contains($0) })
    }

    /// Record briefing engagement (which section user follows up on)
    func recordBriefingEngagement(section: String, action: String) {
        recordLearningEvent(
            eventType: "briefing_engagement",
            context: section,
            signalValue: action
        )
    }

    /// Record intent accuracy (did the recognized intent match what user wanted?)
    func recordIntentAccuracy(recognizedIntent: String, wasCorrect: Bool, userQuery: String) {
        recordLearningEvent(
            eventType: "intent_accuracy",
            context: recognizedIntent,
            signalValue: wasCorrect ? "correct" : "incorrect",
            metadata: ["query": userQuery]
        )
    }

    // MARK: - Learning System v2: Pattern Computation (Phase 2)

    /// Compute v2 learned patterns from raw learning events
    /// Called daily at midnight + on-demand
    func computeLearnedPatterns(config: AppConfig) async {
        print("🧠 Learning v2: Computing learned patterns...")

        // 1. Process direct instructions (immediate, no AI needed)
        processDirectInstructions()

        // 1b. Process user context facts (biographical info, role declarations)
        processUserContextFacts()

        // 2. Compute communication style patterns (needs Haiku)
        await computeCommunicationPatterns(config: config)

        // 3. Update existing workflow patterns (already working)
        computePatterns()

        // 4. Apply staleness rules
        applyPatternStaleness()

        // 5. Deduplicate patterns with overlapping descriptions
        deduplicatePatterns()

        // 6. Queue new/changed patterns for Coach review
        queuePatternsForReview()

        print("✅ Learning v2: Pattern computation complete")
    }

    /// Process direct instructions — skip graduation, become permanent immediately
    private func processDirectInstructions() {
        dbLock.lock()
        defer { dbLock.unlock() }

        // Get unprocessed direct instructions
        let sql = """
        SELECT id, context, signal_value, metadata_json
        FROM learning_events
        WHERE event_type = 'direct_instruction'
          AND id NOT IN (
            SELECT CAST(json_extract(metadata_json, '$.source_event_id') AS INTEGER)
            FROM learned_patterns
            WHERE json_extract(metadata_json, '$.source_event_id') IS NOT NULL
          )
        ORDER BY timestamp DESC
        LIMIT 20
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }

        var instructions: [(id: Int, context: String, signal: String, metadata: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = Int(sqlite3_column_int(stmt, 0))
            let context = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let signal = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let metadata = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "{}"
            instructions.append((id, context, signal, metadata))
        }
        sqlite3_finalize(stmt)

        for instruction in instructions {
            // Create a stable pattern ID from the instruction content
            let patternId = "direct_\(instruction.context.hashValue)"

            let insertSql = """
            INSERT OR REPLACE INTO learned_patterns
            (pattern_id, pattern_type, description, confidence, reinforcement_count,
             is_direct_instruction, source_event_types, last_reinforced, metadata_json)
            VALUES (?, 'explicit_preference', ?, 1.0, 1, 1, 'direct_instruction', datetime('now'), ?)
            """

            var insertStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, insertSql, -1, &insertStmt, nil) == SQLITE_OK else { continue }

            sqlite3_bind_text(insertStmt, 1, patternId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(insertStmt, 2, instruction.context, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            let meta = "{\"source_event_id\": \(instruction.id), \"trigger\": \"\(instruction.signal)\"}"
            sqlite3_bind_text(insertStmt, 3, meta, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            sqlite3_step(insertStmt)
            sqlite3_finalize(insertStmt)

            print("🧠 Learning: Direct instruction recorded as permanent pattern")
        }
    }

    /// Process user context facts — biographical info, role declarations; stored as user_context patterns
    private func processUserContextFacts() {
        // One-off cleanup: archive existing user_context / communication_style patterns whose
        // description is shallow procedural narration (e.g. "User is expressing a preference for…").
        // These slipped in before the LLM prompt was tightened.
        archiveShallowNarrationPatterns()

        dbLock.lock()
        defer { dbLock.unlock() }

        // Get unprocessed user context facts
        let sql = """
        SELECT id, context, signal_value, metadata_json
        FROM learning_events
        WHERE event_type = 'user_context_fact'
          AND id NOT IN (
            SELECT CAST(json_extract(metadata_json, '$.source_event_id') AS INTEGER)
            FROM learned_patterns
            WHERE json_extract(metadata_json, '$.source_event_id') IS NOT NULL
          )
        ORDER BY timestamp DESC
        LIMIT 20
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }

        var facts: [(id: Int, context: String, signal: String, metadata: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = Int(sqlite3_column_int(stmt, 0))
            let context = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let signal = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let metadata = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "{}"
            facts.append((id, context, signal, metadata))
        }
        sqlite3_finalize(stmt)

        for fact in facts {
            let fromLLM = fact.metadata.contains("\"llm_classification\"")

            // Description selection:
            // - Keyword fast-path: user literally said "I am the X" / "remember this" — the raw
            //   message IS the durable fact, use it directly.
            // - LLM-classified: signal_value is Haiku's rephrasing (tightened prompt forces
            //   durable-belief voice); raw context is the original user message which is often
            //   transactional. Prefer the rephrased signal.
            let description = fromLLM && !fact.signal.isEmpty ? fact.signal : fact.context

            // Reject procedural narration regardless of source — the new prompt should prevent
            // these but the filter is a hard backstop.
            if isShallowNarration(description) {
                print("🧠 Learning: Dropping shallow user_context fact — '\(description.prefix(80))'")
                continue
            }

            // Reject transactional one-off messages (questions, imperative commands, time-specific
            // asks). These were the largest source of bad userContext entries pre-fix.
            if isTransactionalMessage(description) {
                print("🧠 Learning: Dropping transactional user_context fact — '\(description.prefix(80))'")
                continue
            }

            // Recurrence guard: LLM-classified facts must recur (≥2 events with overlapping
            // signal) before promotion. Keyword fast-path is already an explicit user
            // instruction so single-shot is fine.
            if fromLLM && !hasRecurringContextFact(signal: fact.signal, excludingEventId: fact.id) {
                print("🧠 Learning: Holding LLM-classified context fact — needs second occurrence")
                continue
            }

            let patternId = "context_\(description.hashValue)"

            let insertSql = """
            INSERT OR REPLACE INTO learned_patterns
            (pattern_id, pattern_type, description, confidence, reinforcement_count,
             is_direct_instruction, source_event_types, last_reinforced, metadata_json)
            VALUES (?, 'user_context', ?, 1.0, 1, 1, 'user_context_fact', datetime('now'), ?)
            """

            var insertStmt: OpaquePointer?
            dbLock.lock()
            guard sqlite3_prepare_v2(db, insertSql, -1, &insertStmt, nil) == SQLITE_OK else {
                dbLock.unlock()
                continue
            }

            sqlite3_bind_text(insertStmt, 1, patternId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(insertStmt, 2, description, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            let meta = "{\"source_event_id\": \(fact.id), \"trigger\": \"\(fact.signal)\"}"
            sqlite3_bind_text(insertStmt, 3, meta, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            sqlite3_step(insertStmt)
            sqlite3_finalize(insertStmt)
            dbLock.unlock()

            print("🧠 Learning: User context fact recorded — '\(description.prefix(80))'")
        }
    }

    /// Archive learned_patterns whose description is procedural narration. One-off cleanup —
    /// no-op once the database is clean. Runs at the start of every pattern computation.
    private func archiveShallowNarrationPatterns() {
        dbLock.lock()
        defer { dbLock.unlock() }

        let sql = """
        SELECT pattern_id, description FROM learned_patterns
        WHERE is_archived = 0
          AND pattern_type IN ('user_context', 'communication_style', 'explicit_preference')
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }

        var toArchive: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let desc = String(cString: sqlite3_column_text(stmt, 1))
            // Archive shallow narration always; archive transactional messages only when
            // they leaked into user_context / communication_style (directInstruction stays —
            // those are genuine "remember this" instructions even if temporal).
            if isShallowNarration(desc) || (isTransactionalMessage(desc) && !id.hasPrefix("direct_")) {
                toArchive.append(id)
            }
        }
        sqlite3_finalize(stmt)

        for id in toArchive {
            let archiveSql = "UPDATE learned_patterns SET is_archived = 1 WHERE pattern_id = ?"
            var archiveStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, archiveSql, -1, &archiveStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(archiveStmt, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_step(archiveStmt)
                sqlite3_finalize(archiveStmt)
            }
        }
        if !toArchive.isEmpty {
            print("🧠 Learning: Archived \(toArchive.count) shallow narration pattern(s)")
        }
    }

    /// Check whether an LLM-classified user_context_fact has recurred — used to gate
    /// promotion so a single transactional ask doesn't become a durable belief.
    private func hasRecurringContextFact(signal: String, excludingEventId: Int) -> Bool {
        let words = Set(signal.lowercased().split(separator: " ").filter { $0.count > 3 }.map(String.init))
        guard words.count >= 2 else { return false }

        dbLock.lock()
        defer { dbLock.unlock() }

        let sql = """
        SELECT id, signal_value FROM learning_events
        WHERE event_type = 'user_context_fact'
          AND id != ?
          AND timestamp > datetime('now', '-60 days')
        ORDER BY timestamp DESC
        LIMIT 50
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(excludingEventId))

        while sqlite3_step(stmt) == SQLITE_ROW {
            let other = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let otherWords = Set(other.lowercased().split(separator: " ").filter { $0.count > 3 }.map(String.init))
            let overlap = words.intersection(otherWords).count
            let ratio = Double(overlap) / Double(min(words.count, max(otherWords.count, 1)))
            if ratio >= 0.5 && overlap >= 2 { return true }
        }
        return false
    }

    /// Compute communication style patterns from conversation history + corrections
    private func computeCommunicationPatterns(config: AppConfig) async {
        // Gather recent corrections and conversation signals
        dbLock.lock()
        var corrections: [(context: String, signal: String)] = []
        var stmt: OpaquePointer?
        let sql = """
        SELECT context, signal_value FROM learning_events
        WHERE event_type IN ('chat_correction', 'direct_instruction', 'chat_preference', 'reinforcement')
          AND timestamp > datetime('now', '-30 days')
        ORDER BY timestamp DESC
        LIMIT 30
        """
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let context = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                let signal = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                corrections.append((context, signal))
            }
            sqlite3_finalize(stmt)
        }
        dbLock.unlock()

        guard corrections.count >= 2 else {
            print("🧠 Learning: Not enough corrections for communication pattern extraction (\(corrections.count)/2)")
            return
        }

        // Use Haiku to extract communication patterns
        let claudeService = ClaudeAIService(config: config.ai, userName: config.user.name)
        let correctionsList = corrections.prefix(15).map { "- User said: \"\($0.context)\"" }.joined(separator: "\n")

        let prompt = """
        Analyze these user corrections and instructions to their AI assistant. Extract DURABLE communication/behavior preferences — beliefs that will hold across future conversations.

        \(correctionsList)

        Return ONLY valid JSON (no markdown fences):
        {
            "patterns": [
                {
                    "id": "short_snake_case_id",
                    "description": "A standing rule about the user, phrased as a durable belief",
                    "confidence": 0.7,
                    "type": "communication_style"
                }
            ]
        }

        CRITICAL: descriptions must read as standing rules, NOT narration of what the user said.
        BAD (DO NOT produce these):
          ❌ "User is expressing a preference for high-impact summaries"
          ❌ "User wants thread-grouped summaries when asked"
          ❌ "User requested concise output in this exchange"
        GOOD:
          ✅ "Prefers high-impact summaries over comprehensive tactical detail"
          ✅ "Appreciates directness — don't hedge or qualify"
          ✅ "Wants thematic grouping (by thread/topic) when reviewing team communications"

        Rules:
        - Extract 0-5 patterns. Returning zero is correct when nothing durable can be inferred.
        - Confidence ≥ 0.6 only. A single one-off ask is NOT a pattern — require recurrence or clear strength of signal.
        - Never start description with "User is", "User wants", "User prefers", "User requested", "User expressed", "Indicates"
        - Phrase as a standing rule in third person ("Prefers X", "Avoids Y", "Wants Z when …")
        - Skip trivial or transactional observations entirely
        """

        do {
            let response = try await claudeService.generateText(
                prompt: prompt,
                system: "You extract behavioral patterns from user corrections. Be concise and specific.",
                maxTokens: 500,
                useModel: "claude-haiku-4-5-20251001"
            )

            guard let jsonData = response.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let patterns = json["patterns"] as? [[String: Any]] else {
                return
            }

            dbLock.lock()
            defer { dbLock.unlock() }

            for pattern in patterns {
                guard let id = pattern["id"] as? String,
                      let description = pattern["description"] as? String,
                      let confidence = pattern["confidence"] as? Double else { continue }

                // Hard backstop: drop procedural narration even if the prompt slipped past.
                if isShallowNarration(description) {
                    print("🧠 Learning: Dropping shallow communication pattern — '\(description.prefix(80))'")
                    continue
                }

                let patternId = "comm_\(id)"

                // Check if pattern exists — if so, reinforce or handle contradiction
                let checkSql = "SELECT confidence, reinforcement_count, description FROM learned_patterns WHERE pattern_id = ?"
                var checkStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, checkSql, -1, &checkStmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(checkStmt, 1, patternId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    if sqlite3_step(checkStmt) == SQLITE_ROW {
                        // Pattern exists — reinforce
                        let existingConfidence = sqlite3_column_double(checkStmt, 0)
                        let count = sqlite3_column_int(checkStmt, 1)
                        sqlite3_finalize(checkStmt)

                        let newConfidence = min(1.0, existingConfidence + 0.1)
                        let updateSql = """
                        UPDATE learned_patterns SET confidence = ?, reinforcement_count = ?,
                               last_reinforced = datetime('now'), is_stale = 0
                        WHERE pattern_id = ?
                        """
                        var updateStmt: OpaquePointer?
                        if sqlite3_prepare_v2(db, updateSql, -1, &updateStmt, nil) == SQLITE_OK {
                            sqlite3_bind_double(updateStmt, 1, newConfidence)
                            sqlite3_bind_int(updateStmt, 2, count + 1)
                            sqlite3_bind_text(updateStmt, 3, patternId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                            sqlite3_step(updateStmt)
                            sqlite3_finalize(updateStmt)
                        }
                    } else {
                        sqlite3_finalize(checkStmt)

                        // New pattern — insert (Learning v3: auto-graduate at >= 0.75 confidence)
                        let effectiveConfidence = confidence >= 0.8 ? max(confidence, 0.75) : confidence
                        let insertSql = """
                        INSERT INTO learned_patterns
                        (pattern_id, pattern_type, description, confidence, reinforcement_count,
                         source_event_types, last_reinforced)
                        VALUES (?, 'communication_style', ?, ?, 1, 'chat_correction', datetime('now'))
                        """
                        var insertStmt: OpaquePointer?
                        if sqlite3_prepare_v2(db, insertSql, -1, &insertStmt, nil) == SQLITE_OK {
                            sqlite3_bind_text(insertStmt, 1, patternId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                            sqlite3_bind_text(insertStmt, 2, description, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                            sqlite3_bind_double(insertStmt, 3, effectiveConfidence)
                            sqlite3_step(insertStmt)
                            sqlite3_finalize(insertStmt)

                            if confidence >= 0.75 {
                                print("🧠 Learning v3: Auto-graduated pattern '\(patternId)' at confidence \(effectiveConfidence) (skipping review queue)")
                            }
                        }
                    }
                } else {
                    sqlite3_finalize(checkStmt)
                }
            }

            print("🧠 Learning: Computed \(patterns.count) communication style patterns")
        } catch {
            print("⚠️ Learning: Communication pattern extraction failed: \(error)")
        }
    }

    /// Apply staleness rules — Learning v3: type-specific thresholds
    /// Direct instructions + user context: NEVER stale
    /// Communication style: 90 days stale, 180 days archive
    /// Other patterns: 45 days stale, 120 days archive
    private func applyPatternStaleness() {
        dbLock.lock()
        defer { dbLock.unlock() }

        // Communication style: 90 days stale, 180 days archive
        sqlite3_exec(db, """
        UPDATE learned_patterns SET is_stale = 1
        WHERE last_reinforced < datetime('now', '-90 days')
          AND pattern_type = 'communication_style'
          AND is_direct_instruction = 0
          AND is_archived = 0
          AND is_stale = 0
        """, nil, nil, nil)

        sqlite3_exec(db, """
        UPDATE learned_patterns SET is_archived = 1
        WHERE last_reinforced < datetime('now', '-180 days')
          AND pattern_type = 'communication_style'
          AND is_direct_instruction = 0
          AND is_archived = 0
        """, nil, nil, nil)

        // Other non-permanent patterns: 45 days stale, 120 days archive
        sqlite3_exec(db, """
        UPDATE learned_patterns SET is_stale = 1
        WHERE last_reinforced < datetime('now', '-45 days')
          AND pattern_type NOT IN ('communication_style', 'explicit_preference', 'user_context')
          AND is_direct_instruction = 0
          AND is_archived = 0
          AND is_stale = 0
        """, nil, nil, nil)

        sqlite3_exec(db, """
        UPDATE learned_patterns SET is_archived = 1
        WHERE last_reinforced < datetime('now', '-120 days')
          AND pattern_type NOT IN ('communication_style', 'explicit_preference', 'user_context')
          AND is_direct_instruction = 0
          AND is_archived = 0
        """, nil, nil, nil)

        // explicit_preference and user_context: NEVER stale (even if not direct_instruction).
        // Only clear staleness — do NOT un-archive. Archived patterns were dropped intentionally
        // (e.g. shallow narration cleanup) and must stay archived.
        sqlite3_exec(db, """
        UPDATE learned_patterns SET is_stale = 0
        WHERE pattern_type IN ('explicit_preference', 'user_context')
          AND is_archived = 0
        """, nil, nil, nil)
    }

    /// Deduplicate learned patterns with overlapping descriptions
    private func deduplicatePatterns() {
        dbLock.lock()
        defer { dbLock.unlock() }

        // Get all active patterns grouped by type
        let query = "SELECT pattern_id, pattern_type, description, confidence FROM learned_patterns WHERE is_stale = 0 ORDER BY pattern_type, confidence DESC"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        struct PatternRow {
            let id: String
            let type: String
            let description: String
            let confidence: Double
        }

        var patterns: [PatternRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let type = String(cString: sqlite3_column_text(stmt, 1))
            let desc = String(cString: sqlite3_column_text(stmt, 2))
            let conf = sqlite3_column_double(stmt, 3)
            patterns.append(PatternRow(id: id, type: type, description: desc, confidence: conf))
        }

        // Group by type
        var byType: [String: [PatternRow]] = [:]
        for p in patterns {
            byType[p.type, default: []].append(p)
        }

        var toDelete: Set<String> = []

        for (_, group) in byType {
            // Compare each pair within the group
            for i in 0..<group.count {
                if toDelete.contains(group[i].id) { continue }
                for j in (i+1)..<group.count {
                    if toDelete.contains(group[j].id) { continue }

                    let words1 = Set(group[i].description.lowercased().split(separator: " ").map(String.init))
                    let words2 = Set(group[j].description.lowercased().split(separator: " ").map(String.init))

                    guard !words1.isEmpty && !words2.isEmpty else { continue }

                    let intersection = words1.intersection(words2).count
                    let union = words1.union(words2).count
                    let similarity = Double(intersection) / Double(union)

                    if similarity > 0.8 {
                        // Keep higher confidence (sorted DESC, so group[i] wins)
                        toDelete.insert(group[j].id)
                    }
                }
            }
        }

        if !toDelete.isEmpty {
            for id in toDelete {
                let deleteSql = "DELETE FROM learned_patterns WHERE pattern_id = ?"
                var delStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, deleteSql, -1, &delStmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(delStmt, 1, (id as NSString).utf8String, -1, nil)
                    sqlite3_step(delStmt)
                }
                sqlite3_finalize(delStmt)
            }
            print("🧹 Learning v2: Deduplicated \(toDelete.count) similar patterns")
        }
    }

    /// Queue new or significantly changed patterns for Coach review
    private func queuePatternsForReview() {
        dbLock.lock()
        defer { dbLock.unlock() }

        // Find patterns that haven't been reviewed yet
        let sql = """
        SELECT lp.pattern_id, lp.pattern_type, lp.description, lp.confidence
        FROM learned_patterns lp
        WHERE lp.is_archived = 0
          AND lp.is_direct_instruction = 0
          AND lp.confidence >= 0.6
          AND lp.pattern_id NOT IN (
            SELECT pattern_id FROM pending_pattern_reviews
          )
        ORDER BY lp.created_at DESC
        LIMIT 5
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }

        var newPatterns: [(id: String, type: String, desc: String, confidence: Double)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let type = String(cString: sqlite3_column_text(stmt, 1))
            let desc = String(cString: sqlite3_column_text(stmt, 2))
            let confidence = sqlite3_column_double(stmt, 3)
            newPatterns.append((id, type, desc, confidence))
        }
        sqlite3_finalize(stmt)

        for pattern in newPatterns {
            let question = "I've noticed a pattern: \"\(pattern.desc)\" — does that sound right to you?"

            let insertSql = """
            INSERT INTO pending_pattern_reviews (pattern_id, review_type, question)
            VALUES (?, 'new_pattern', ?)
            """
            var insertStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, insertSql, -1, &insertStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(insertStmt, 1, pattern.id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_text(insertStmt, 2, question, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_step(insertStmt)
                sqlite3_finalize(insertStmt)
            }
        }

        if !newPatterns.isEmpty {
            print("🧠 Learning: Queued \(newPatterns.count) patterns for Coach review")
        }
    }

    // MARK: - Learning System v2: Knowledge Application (Phase 3)

    /// Get learning context tailored for a specific endpoint
    func getContextForEndpoint(_ endpoint: String) -> String {
        let patterns = getLearnedPatterns()
        guard !patterns.isEmpty else { return "" }

        var context = "## What Alfred Has Learned About You\n\n"
        var tokenEstimate = 0
        let maxTokens = 500

        // Direct instructions first (always include, all endpoints)
        let directInstructions = patterns.filter { $0.type == "explicit_preference" && !$0.isArchived }
        if !directInstructions.isEmpty {
            context += "### Your Explicit Preferences\n"
            for p in directInstructions.prefix(10) {
                let line = "- \(p.description)\n"
                tokenEstimate += line.count / 4
                if tokenEstimate > maxTokens { break }
                context += line
            }
            context += "\n"
        }

        // User context facts (always include, all endpoints)
        let userContextFacts = patterns.filter { $0.type == "user_context" && !$0.isArchived }
        if !userContextFacts.isEmpty {
            context += "### What Alfred Knows About You\n"
            for p in userContextFacts.prefix(10) {
                let line = "- \(p.description)\n"
                tokenEstimate += line.count / 4
                if tokenEstimate > maxTokens { break }
                context += line
            }
            context += "\n"
        }

        // Endpoint-specific patterns
        switch endpoint {
        case "chat", "coaching":
            let commPatterns = patterns.filter { $0.type == "communication_style" && !$0.isArchived }
            if !commPatterns.isEmpty {
                context += "### Communication Style\n"
                for p in commPatterns.prefix(5) {
                    let staleMark = p.isStale ? " (older observation)" : ""
                    let line = "- \(p.description)\(staleMark)\n"
                    tokenEstimate += line.count / 4
                    if tokenEstimate > maxTokens { break }
                    context += line
                }
                context += "\n"
            }

        case "briefing":
            let briefingPatterns = patterns.filter { $0.type == "briefing_relevance" && !$0.isArchived }
            if !briefingPatterns.isEmpty {
                context += "### Briefing Preferences\n"
                for p in briefingPatterns.prefix(5) {
                    context += "- \(p.description)\n"
                }
                context += "\n"
            }
            // Also include contact intelligence
            let contactPatterns = patterns.filter { $0.type == "contact_intelligence" && !$0.isArchived }
            if !contactPatterns.isEmpty {
                context += "### Contact Preferences\n"
                for p in contactPatterns.prefix(5) {
                    context += "- \(p.description)\n"
                }
                context += "\n"
            }

        case "commitment_scan":
            // Include AI accuracy patterns (already from computePatterns)
            let existingAI = getPatternContextForAI()
            if !existingAI.isEmpty {
                context += existingAI
            }

        case "extraction":
            // Include correction history
            let corrPatterns = patterns.filter { $0.type == "extraction_accuracy" && !$0.isArchived }
            if !corrPatterns.isEmpty {
                context += "### Extraction Preferences\n"
                for p in corrPatterns.prefix(5) {
                    context += "- \(p.description)\n"
                }
                context += "\n"
            }

        default:
            break
        }

        return context
    }

    /// Get all active learned patterns
    func getLearnedPatterns() -> [(id: String, type: String, description: String, confidence: Double, isStale: Bool, isArchived: Bool, isDirect: Bool, reinforcements: Int, lastReinforced: String)] {
        dbLock.lock()
        defer { dbLock.unlock() }

        let sql = """
        SELECT pattern_id, pattern_type, description, confidence, is_stale, is_archived,
               is_direct_instruction, reinforcement_count, last_reinforced
        FROM learned_patterns
        WHERE is_archived = 0
        ORDER BY is_direct_instruction DESC, confidence DESC, last_reinforced DESC
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var patterns: [(id: String, type: String, description: String, confidence: Double, isStale: Bool, isArchived: Bool, isDirect: Bool, reinforcements: Int, lastReinforced: String)] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            patterns.append((
                id: String(cString: sqlite3_column_text(stmt, 0)),
                type: String(cString: sqlite3_column_text(stmt, 1)),
                description: String(cString: sqlite3_column_text(stmt, 2)),
                confidence: sqlite3_column_double(stmt, 3),
                isStale: sqlite3_column_int(stmt, 4) == 1,
                isArchived: sqlite3_column_int(stmt, 5) == 1,
                isDirect: sqlite3_column_int(stmt, 6) == 1,
                reinforcements: Int(sqlite3_column_int(stmt, 7)),
                lastReinforced: sqlite3_column_text(stmt, 8).map { String(cString: $0) } ?? ""
            ))
        }

        return patterns
    }

    // MARK: - User Memory Management (Learning v3: Phase 5)

    /// Delete a learned pattern by ID and record the deletion as a learning event
    func deleteLearnedPattern(patternId: String) -> Bool {
        dbLock.lock()
        defer { dbLock.unlock() }

        // Get the pattern description before deleting (for the learning event)
        var description = ""
        let selectSql = "SELECT description FROM learned_patterns WHERE pattern_id = ?"
        var selectStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, selectSql, -1, &selectStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(selectStmt, 1, patternId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            if sqlite3_step(selectStmt) == SQLITE_ROW {
                description = sqlite3_column_text(selectStmt, 0).map { String(cString: $0) } ?? ""
            }
            sqlite3_finalize(selectStmt)
        }

        let deleteSql = "DELETE FROM learned_patterns WHERE pattern_id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, deleteSql, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(stmt, 1, patternId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        let result = sqlite3_step(stmt)
        sqlite3_finalize(stmt)

        let deleted = result == SQLITE_DONE && sqlite3_changes(db) > 0

        if deleted {
            // Also remove from pending reviews
            let prSql = "DELETE FROM pending_pattern_reviews WHERE pattern_id = ?"
            var prStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, prSql, -1, &prStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(prStmt, 1, patternId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_step(prStmt)
                sqlite3_finalize(prStmt)
            }

            print("🧠 Learning v3: Deleted pattern '\(patternId)'")
        }

        return deleted
    }

    /// Update a learned pattern's description (user correction)
    func updateLearnedPattern(patternId: String, newDescription: String) -> Bool {
        dbLock.lock()
        defer { dbLock.unlock() }

        let sql = "UPDATE learned_patterns SET description = ?, confidence = MIN(1.0, confidence + 0.1), last_reinforced = datetime('now') WHERE pattern_id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(stmt, 1, newDescription, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, patternId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        let result = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        return result == SQLITE_DONE && sqlite3_changes(db) > 0
    }

    /// Decay a pattern's confidence (negative feedback)
    func decayPatternConfidence(patternId: String) -> Bool {
        dbLock.lock()
        defer { dbLock.unlock() }

        let sql = "UPDATE learned_patterns SET confidence = MAX(0.1, confidence * 0.7), contradiction_count = contradiction_count + 1 WHERE pattern_id = ? AND is_direct_instruction = 0"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(stmt, 1, patternId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        let result = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        return result == SQLITE_DONE
    }

    /// Update last_reinforced for patterns that were injected into a prompt (Learning v3: reinforcement through usage)
    func touchLastReinforced(patternIds: [String]) {
        guard !patternIds.isEmpty else { return }
        dbLock.lock()
        defer { dbLock.unlock() }

        for patternId in patternIds {
            let sql = "UPDATE learned_patterns SET last_reinforced = datetime('now'), is_stale = 0 WHERE pattern_id = ? AND is_archived = 0"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, patternId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        }
    }

    // MARK: - Learning System v2: Pattern Review (Phase 5)

    /// Get pending pattern reviews for Coach to surface
    func getPendingPatternReviews() -> [(id: Int, patternId: String, question: String, reviewType: String)] {
        dbLock.lock()
        defer { dbLock.unlock() }

        let sql = """
        SELECT pr.id, pr.pattern_id, pr.question, pr.review_type
        FROM pending_pattern_reviews pr
        WHERE pr.status = 'pending'
        ORDER BY pr.created_at ASC
        LIMIT 3
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var reviews: [(id: Int, patternId: String, question: String, reviewType: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            reviews.append((
                id: Int(sqlite3_column_int(stmt, 0)),
                patternId: String(cString: sqlite3_column_text(stmt, 1)),
                question: String(cString: sqlite3_column_text(stmt, 2)),
                reviewType: String(cString: sqlite3_column_text(stmt, 3))
            ))
        }
        return reviews
    }

    /// Handle user response to a pattern review
    func resolvePatternReview(reviewId: Int, action: String, userResponse: String? = nil) {
        dbLock.lock()
        defer { dbLock.unlock() }

        // Get the pattern_id for this review
        let getSql = "SELECT pattern_id FROM pending_pattern_reviews WHERE id = ?"
        var getStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, getSql, -1, &getStmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_int(getStmt, 1, Int32(reviewId))

        var patternId: String?
        if sqlite3_step(getStmt) == SQLITE_ROW {
            patternId = String(cString: sqlite3_column_text(getStmt, 0))
        }
        sqlite3_finalize(getStmt)

        guard let pid = patternId else { return }

        // Update review status
        let updateReviewSql = """
        UPDATE pending_pattern_reviews
        SET status = ?, user_response = ?, reviewed_at = datetime('now')
        WHERE id = ?
        """
        var updateStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, updateReviewSql, -1, &updateStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(updateStmt, 1, action, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            if let response = userResponse {
                sqlite3_bind_text(updateStmt, 2, response, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            } else {
                sqlite3_bind_null(updateStmt, 2)
            }
            sqlite3_bind_int(updateStmt, 3, Int32(reviewId))
            sqlite3_step(updateStmt)
            sqlite3_finalize(updateStmt)
        }

        // Update the pattern based on action
        switch action {
        case "confirmed":
            // Boost confidence
            let boostSql = """
            UPDATE learned_patterns
            SET confidence = MIN(1.0, confidence + 0.15),
                reinforcement_count = reinforcement_count + 1,
                last_reinforced = datetime('now')
            WHERE pattern_id = ?
            """
            var boostStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, boostSql, -1, &boostStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(boostStmt, 1, pid, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_step(boostStmt)
                sqlite3_finalize(boostStmt)
            }

        case "corrected":
            // Update description with user's words, reset confidence
            if let newDesc = userResponse {
                let correctSql = """
                UPDATE learned_patterns
                SET description = ?, confidence = 0.8,
                    reinforcement_count = reinforcement_count + 1,
                    last_reinforced = datetime('now')
                WHERE pattern_id = ?
                """
                var correctStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, correctSql, -1, &correctStmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(correctStmt, 1, newDesc, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    sqlite3_bind_text(correctStmt, 2, pid, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    sqlite3_step(correctStmt)
                    sqlite3_finalize(correctStmt)
                }
            }

        case "dismissed":
            // Archive the pattern
            let archiveSql = "UPDATE learned_patterns SET is_archived = 1 WHERE pattern_id = ?"
            var archiveStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, archiveSql, -1, &archiveStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(archiveStmt, 1, pid, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_step(archiveStmt)
                sqlite3_finalize(archiveStmt)
            }

        default:
            break
        }

        // Record as learning event for meta-learning
        recordLearningEvent(
            eventType: "pattern_review_\(action)",
            context: pid,
            signalValue: userResponse
        )

        print("🧠 Learning: Pattern review \(action) for \(pid)")
    }

    /// Decay confidence for a pattern (when a contradictory signal is detected)
    func decayPatternConfidence(patternId: String, reason: String) {
        dbLock.lock()
        defer { dbLock.unlock() }

        let sql = """
        UPDATE learned_patterns
        SET confidence = MAX(0.1, confidence * 0.7),
            contradiction_count = contradiction_count + 1,
            metadata_json = json_set(COALESCE(metadata_json, '{}'), '$.last_contradiction', ?)
        WHERE pattern_id = ? AND is_direct_instruction = 0
        """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, reason, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 2, patternId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    /// Get learning system v2 statistics
    func getLearningV2Stats() -> [String: Any] {
        dbLock.lock()
        defer { dbLock.unlock() }

        var stats: [String: Any] = [:]

        // Total learning events
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM learning_events", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW { stats["totalEvents"] = Int(sqlite3_column_int(stmt, 0)) }
            sqlite3_finalize(stmt)
        }

        // Events by type (last 30 days)
        if sqlite3_prepare_v2(db, """
            SELECT event_type, COUNT(*) FROM learning_events
            WHERE timestamp > datetime('now', '-30 days')
            GROUP BY event_type
        """, -1, &stmt, nil) == SQLITE_OK {
            var byType: [String: Int] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                let type = String(cString: sqlite3_column_text(stmt, 0))
                byType[type] = Int(sqlite3_column_int(stmt, 1))
            }
            stats["eventsByType"] = byType
            sqlite3_finalize(stmt)
        }

        // Active learned patterns
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM learned_patterns WHERE is_archived = 0", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW { stats["activePatterns"] = Int(sqlite3_column_int(stmt, 0)) }
            sqlite3_finalize(stmt)
        }

        // Stale patterns
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM learned_patterns WHERE is_stale = 1 AND is_archived = 0", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW { stats["stalePatterns"] = Int(sqlite3_column_int(stmt, 0)) }
            sqlite3_finalize(stmt)
        }

        // Direct instructions
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM learned_patterns WHERE is_direct_instruction = 1", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW { stats["directInstructions"] = Int(sqlite3_column_int(stmt, 0)) }
            sqlite3_finalize(stmt)
        }

        // Pending reviews
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM pending_pattern_reviews WHERE status = 'pending'", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW { stats["pendingReviews"] = Int(sqlite3_column_int(stmt, 0)) }
            sqlite3_finalize(stmt)
        }

        // Last computation time
        if sqlite3_prepare_v2(db, "SELECT MAX(last_reinforced) FROM learned_patterns", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) {
                stats["lastComputed"] = String(cString: text)
            }
            sqlite3_finalize(stmt)
        }

        return stats
    }
}
