import Foundation
import SQLite3

/// Tracks task lifecycle changes from Notion
/// Polls periodically, detects status changes, computes patterns
class TaskLifecycleTracker {
    static let shared = TaskLifecycleTracker()

    private let dbPath: URL
    private var db: OpaquePointer?
    private let dbLock = NSLock()  // Thread safety for SQLite access

    // Cache of last known task states (task_id -> status)
    private var lastKnownStates: [String: String] = [:]
    private var lastScanTime: Date?

    private init() {
        let alfredDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".alfred")

        try? FileManager.default.createDirectory(at: alfredDir, withIntermediateDirectories: true)

        self.dbPath = alfredDir.appendingPathComponent("task_lifecycle.db")

        setupDatabase()
        loadLastKnownStates()
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Database Setup

    private func setupDatabase() {
        guard sqlite3_open(dbPath.path, &db) == SQLITE_OK else {
            print("⚠️ Failed to open task lifecycle database")
            return
        }

        // Task snapshots - current state of each task
        let createSnapshotsTable = """
        CREATE TABLE IF NOT EXISTS task_snapshots (
            notion_id TEXT PRIMARY KEY,
            title TEXT,
            status TEXT,
            task_type TEXT,
            priority TEXT,
            due_date TEXT,
            counterparty TEXT,
            source_platform TEXT,
            last_seen DATETIME DEFAULT CURRENT_TIMESTAMP
        )
        """

        // Status changes - every transition
        let createChangesTable = """
        CREATE TABLE IF NOT EXISTS status_changes (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            notion_id TEXT,
            title TEXT,
            old_status TEXT,
            new_status TEXT,
            changed_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            task_type TEXT,
            priority TEXT,
            counterparty TEXT,
            days_since_created INTEGER,
            was_overdue BOOLEAN
        )
        """

        // Aggregated stats - computed periodically
        let createStatsTable = """
        CREATE TABLE IF NOT EXISTS completion_stats (
            stat_key TEXT PRIMARY KEY,
            stat_value REAL,
            sample_count INTEGER,
            last_updated DATETIME DEFAULT CURRENT_TIMESTAMP
        )
        """

        // Scan history
        let createScanHistoryTable = """
        CREATE TABLE IF NOT EXISTS scan_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            scanned_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            tasks_found INTEGER,
            changes_detected INTEGER
        )
        """

        var errMsg: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, createSnapshotsTable, nil, nil, &errMsg)
        sqlite3_exec(db, createChangesTable, nil, nil, &errMsg)
        sqlite3_exec(db, createStatsTable, nil, nil, &errMsg)
        sqlite3_exec(db, createScanHistoryTable, nil, nil, &errMsg)

        print("✓ Task lifecycle database ready")
    }

    private func loadLastKnownStates() {
        dbLock.lock()
        defer { dbLock.unlock() }

        let query = "SELECT notion_id, status FROM task_snapshots"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            if let idPtr = sqlite3_column_text(stmt, 0),
               let statusPtr = sqlite3_column_text(stmt, 1) {
                let notionId = String(cString: idPtr)
                let status = String(cString: statusPtr)
                lastKnownStates[notionId] = status
            }
        }

        print("✓ Loaded \(lastKnownStates.count) task states from lifecycle DB")
    }

    // MARK: - Scanning

    // Background scan state
    private var isScanning = false
    private var scanProgress: ScanProgress?
    private let scanLock = NSLock()  // Thread safety for scan state

    struct ScanProgress {
        var phase: String
        var tasksProcessed: Int
        var totalEstimated: Int?
        var pagesLoaded: Int
    }

    /// Pre-initialize scan state before spawning background task
    /// This allows the HTTP handler to return immediately with progress visible
    func startScan() {
        scanLock.lock()
        defer { scanLock.unlock() }

        isScanning = true
        scanProgress = ScanProgress(phase: "Connecting to Notion...", tasksProcessed: 0, totalEstimated: nil, pagesLoaded: 0)
    }

    /// Scan Notion for task changes
    /// Returns number of changes detected
    func scan(notionService: NotionService) async throws -> ScanResult {
        scanLock.lock()
        // If startScan() was already called, we're ready to go
        // If not called, set up the state now
        if !isScanning {
            isScanning = true
            scanProgress = ScanProgress(phase: "Connecting to Notion...", tasksProcessed: 0, totalEstimated: nil, pagesLoaded: 0)
        }
        scanLock.unlock()

        defer {
            scanLock.lock()
            isScanning = false
            scanProgress = nil
            scanLock.unlock()
        }

        print("🔍 Scanning Notion for task changes...")

        // Query all tasks with pagination (including done/cancelled)
        scanProgress?.phase = "Fetching tasks..."
        let tasks = try await queryAllTasksPaginated(notionService: notionService)

        var changesDetected = 0
        var newTasks = 0
        var statusChanges: [StatusChange] = []

        scanProgress?.phase = "Analyzing changes..."
        scanProgress?.totalEstimated = tasks.count

        for (index, task) in tasks.enumerated() {
            let notionId = task.notionId
            guard !notionId.isEmpty else { continue }

            let currentStatus = task.status.rawValue

            if let lastStatus = lastKnownStates[notionId] {
                // Existing task - check for status change
                if lastStatus != currentStatus {
                    let change = StatusChange(
                        notionId: notionId,
                        title: task.title,
                        oldStatus: lastStatus,
                        newStatus: currentStatus,
                        taskType: task.type.rawValue,
                        priority: task.priority?.rawValue,
                        counterparty: task.committedTo ?? task.committedBy,
                        wasOverdue: task.isOverdue
                    )

                    recordStatusChange(change)
                    statusChanges.append(change)
                    changesDetected += 1

                    print("  📝 \(task.title): \(lastStatus) → \(currentStatus)")
                }
            } else {
                // New task
                newTasks += 1
            }

            // Update snapshot
            updateSnapshot(task)
            lastKnownStates[notionId] = currentStatus

            // Update progress every 10 tasks
            if index % 10 == 0 {
                scanProgress?.tasksProcessed = index
            }
        }

        // Record scan
        recordScan(tasksFound: tasks.count, changesDetected: changesDetected)
        lastScanTime = Date()

        // Recompute stats if we had changes, new tasks, or no stats exist yet
        scanProgress?.phase = "Computing patterns..."
        let hasStats = hasExistingStats()
        if changesDetected > 0 || newTasks > 0 || !hasStats {
            recomputeStats()
            computeCurrentStateStats(tasks: tasks)
        }

        let result = ScanResult(
            tasksScanned: tasks.count,
            newTasks: newTasks,
            changesDetected: changesDetected,
            changes: statusChanges,
            fromCache: false
        )

        print("✓ Scan complete: \(tasks.count) tasks, \(changesDetected) changes")

        return result
    }

    /// Get current scan progress (for UI updates)
    func getScanProgress() -> ScanProgress? {
        scanLock.lock()
        defer { scanLock.unlock() }
        return scanProgress
    }

    /// Check if a scan is currently running
    func isScanInProgress() -> Bool {
        scanLock.lock()
        defer { scanLock.unlock() }
        return isScanning
    }

    /// Query ALL tasks from Notion with pagination (including completed/cancelled)
    private func queryAllTasksPaginated(notionService: NotionService) async throws -> [TaskItem] {
        guard let dbId = notionService.tasksDatabaseId else {
            throw NSError(domain: "TaskLifecycleTracker", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Tasks database ID not set"])
        }

        var allTasks: [TaskItem] = []
        var startCursor: String? = nil
        var hasMore = true
        var pageCount = 0
        let maxPages = 10  // Safety limit: 10 pages × 100 tasks = 1000 tasks max

        while hasMore && pageCount < maxPages {
            // Update progress BEFORE making the request
            scanProgress?.phase = pageCount == 0 ? "Fetching page 1..." : "Fetching page \(pageCount + 1)..."

            let url = URL(string: "https://api.notion.com/v1/databases/\(dbId)/query")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(notionService.apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 20  // 20 second timeout per request (reduced from 30)

            // Query tasks, sorted by last edited
            var body: [String: Any] = [
                "sorts": [
                    ["timestamp": "last_edited_time", "direction": "descending"]
                ],
                "page_size": 100
            ]

            // Add cursor for pagination
            if let cursor = startCursor {
                body["start_cursor"] = cursor
            }

            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            // Use a task with timeout for the network request
            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch {
                print("  ⚠️ Page \(pageCount + 1) failed: \(error.localizedDescription)")
                // If first page fails, throw. Otherwise, return what we have
                if pageCount == 0 {
                    throw error
                }
                break
            }

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                print("  ⚠️ Notion returned status \(statusCode)")
                if pageCount == 0 {
                    throw NSError(domain: "TaskLifecycleTracker", code: 2,
                                 userInfo: [NSLocalizedDescriptionKey: "Notion returned status \(statusCode)"])
                }
                break
            }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

            // Parse results
            if let results = json?["results"] as? [[String: Any]] {
                let tasks = results.compactMap { parseTask($0) }
                allTasks.append(contentsOf: tasks)
            }

            // Check for more pages
            hasMore = (json?["has_more"] as? Bool) ?? false
            startCursor = json?["next_cursor"] as? String

            pageCount += 1
            scanProgress?.pagesLoaded = pageCount
            scanProgress?.phase = "Loaded \(allTasks.count) tasks..."

            print("  📄 Page \(pageCount): fetched \(allTasks.count) tasks total")

            // Small delay between pages to avoid rate limiting
            if hasMore {
                try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
            }
        }

        if hasMore {
            print("  ⚠️ Reached page limit (\(maxPages) pages), some tasks may not be included")
        }

        return allTasks
    }

    /// Quick scan - only fetch recently modified tasks (for incremental updates)
    func quickScan(notionService: NotionService, since: Date? = nil) async throws -> ScanResult {
        guard !isScanning else {
            return ScanResult(tasksScanned: 0, newTasks: 0, changesDetected: 0, changes: [], fromCache: true)
        }

        isScanning = true
        scanProgress = ScanProgress(phase: "Quick scan...", tasksProcessed: 0, totalEstimated: nil, pagesLoaded: 0)
        defer {
            isScanning = false
            scanProgress = nil
        }

        // Use last scan time or 24 hours ago
        let sinceDate = since ?? lastScanTime ?? Date().addingTimeInterval(-86400)

        guard let dbId = notionService.tasksDatabaseId else {
            throw NSError(domain: "TaskLifecycleTracker", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Tasks database ID not set"])
        }

        let url = URL(string: "https://api.notion.com/v1/databases/\(dbId)/query")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(notionService.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15  // Shorter timeout for quick scan

        let formatter = ISO8601DateFormatter()
        let body: [String: Any] = [
            "filter": [
                "timestamp": "last_edited_time",
                "last_edited_time": [
                    "after": formatter.string(from: sinceDate)
                ]
            ],
            "sorts": [
                ["timestamp": "last_edited_time", "direction": "descending"]
            ],
            "page_size": 100
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "TaskLifecycleTracker", code: 2,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to query Notion"])
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let results = json?["results"] as? [[String: Any]] else {
            return ScanResult(tasksScanned: 0, newTasks: 0, changesDetected: 0, changes: [], fromCache: false)
        }

        let tasks = results.compactMap { parseTask($0) }

        var changesDetected = 0
        var newTasks = 0
        var statusChanges: [StatusChange] = []

        for task in tasks {
            let notionId = task.notionId
            guard !notionId.isEmpty else { continue }

            let currentStatus = task.status.rawValue

            if let lastStatus = lastKnownStates[notionId] {
                if lastStatus != currentStatus {
                    let change = StatusChange(
                        notionId: notionId,
                        title: task.title,
                        oldStatus: lastStatus,
                        newStatus: currentStatus,
                        taskType: task.type.rawValue,
                        priority: task.priority?.rawValue,
                        counterparty: task.committedTo ?? task.committedBy,
                        wasOverdue: task.isOverdue
                    )
                    recordStatusChange(change)
                    statusChanges.append(change)
                    changesDetected += 1
                }
            } else {
                newTasks += 1
            }

            updateSnapshot(task)
            lastKnownStates[notionId] = currentStatus
        }

        lastScanTime = Date()

        print("✓ Quick scan: \(tasks.count) recently modified, \(changesDetected) changes")

        return ScanResult(
            tasksScanned: tasks.count,
            newTasks: newTasks,
            changesDetected: changesDetected,
            changes: statusChanges,
            fromCache: false
        )
    }

    /// Parse task from Notion API response
    private func parseTask(_ result: [String: Any]) -> TaskItem? {
        guard let id = result["id"] as? String,
              let properties = result["properties"] as? [String: Any] else {
            return nil
        }

        // Extract title
        guard let titleProp = properties["Title"] as? [String: Any],
              let titleArray = titleProp["title"] as? [[String: Any]],
              let firstTitle = titleArray.first,
              let title = firstTitle["plain_text"] as? String else {
            return nil
        }

        // Extract status
        var statusString = "Not Started"
        if let statusProp = properties["Status"] as? [String: Any],
           let statusData = statusProp["status"] as? [String: Any],
           let statusName = statusData["name"] as? String {
            statusString = statusName
        }
        let status = TaskItem.TaskStatus(rawValue: statusString) ?? .notStarted

        // Extract type
        var typeString = "Todo"
        if let typeProp = properties["Type"] as? [String: Any],
           let selectData = typeProp["select"] as? [String: Any],
           let typeName = selectData["name"] as? String {
            typeString = typeName
        }
        let type = TaskItem.TaskType(rawValue: typeString) ?? .todo

        // Extract priority
        var priority: TaskItem.Priority?
        if let priorityProp = properties["Priority"] as? [String: Any],
           let selectData = priorityProp["select"] as? [String: Any],
           let priorityName = selectData["name"] as? String {
            priority = TaskItem.Priority(rawValue: priorityName)
        }

        // Extract due date
        var dueDate: Date?
        if let dateProp = properties["Due Date"] as? [String: Any],
           let dateData = dateProp["date"] as? [String: Any],
           let startDate = dateData["start"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            dueDate = formatter.date(from: startDate)
        }

        // Extract source platform
        var sourcePlatform: TaskItem.SourcePlatform?
        if let sourceProp = properties["Source"] as? [String: Any],
           let selectData = sourceProp["select"] as? [String: Any],
           let sourceName = selectData["name"] as? String {
            sourcePlatform = TaskItem.SourcePlatform(rawValue: sourceName)
        }

        // Extract description to find counterparty
        var committedBy: String?
        var committedTo: String?
        if let descProp = properties["Description"] as? [String: Any],
           let richTextArray = descProp["rich_text"] as? [[String: Any]] {
            let description = richTextArray.compactMap { $0["plain_text"] as? String }.joined()

            // Parse arrow format: "→ John" or "← Sarah"
            if description.hasPrefix("→ ") {
                let parts = description.dropFirst(2).split(separator: "\n").first
                committedTo = parts.map(String.init)
            } else if description.hasPrefix("← ") {
                let parts = description.dropFirst(2).split(separator: "\n").first
                committedBy = parts.map(String.init)
            }
        }

        return TaskItem(
            notionId: id,
            title: title,
            type: type,
            status: status,
            description: nil,
            dueDate: dueDate,
            priority: priority,
            assignee: nil,
            commitmentDirection: nil,
            committedBy: committedBy,
            committedTo: committedTo,
            originalContext: nil,
            sourcePlatform: sourcePlatform,
            sourceThread: nil,
            sourceThreadId: nil,
            tags: nil,
            followUpDate: nil,
            uniqueHash: nil,
            notes: nil,
            createdDate: Date(),
            lastUpdated: Date()
        )
    }

    // MARK: - Recording

    private func recordStatusChange(_ change: StatusChange) {
        dbLock.lock()
        defer { dbLock.unlock() }

        let sql = """
        INSERT INTO status_changes
        (notion_id, title, old_status, new_status, task_type, priority, counterparty, was_overdue)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, 1, change.notionId)
        bindText(stmt, 2, change.title)
        bindText(stmt, 3, change.oldStatus)
        bindText(stmt, 4, change.newStatus)
        bindText(stmt, 5, change.taskType)
        bindText(stmt, 6, change.priority ?? "")
        bindText(stmt, 7, change.counterparty ?? "")
        sqlite3_bind_int(stmt, 8, change.wasOverdue ? 1 : 0)

        sqlite3_step(stmt)
    }

    private func updateSnapshot(_ task: TaskItem) {
        let notionId = task.notionId
        guard !notionId.isEmpty else { return }

        dbLock.lock()
        defer { dbLock.unlock() }

        let sql = """
        INSERT OR REPLACE INTO task_snapshots
        (notion_id, title, status, task_type, priority, due_date, counterparty, source_platform, last_seen)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]

        bindText(stmt, 1, notionId)
        bindText(stmt, 2, task.title)
        bindText(stmt, 3, task.status.rawValue)
        bindText(stmt, 4, task.type.rawValue)
        bindText(stmt, 5, task.priority?.rawValue ?? "")
        bindText(stmt, 6, task.dueDate.map { formatter.string(from: $0) } ?? "")
        bindText(stmt, 7, task.committedTo ?? task.committedBy ?? "")
        bindText(stmt, 8, task.sourcePlatform?.rawValue ?? "")

        sqlite3_step(stmt)
    }

    // Helper to safely bind text to SQLite statement
    // Uses SQLITE_TRANSIENT to make SQLite copy the string immediately
    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        value.withCString { cString in
            _ = sqlite3_bind_text(stmt, index, cString, -1, SQLITE_TRANSIENT)
        }
    }

    private func recordScan(tasksFound: Int, changesDetected: Int) {
        dbLock.lock()
        defer { dbLock.unlock() }

        let sql = "INSERT INTO scan_history (tasks_found, changes_detected) VALUES (?, ?)"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(tasksFound))
        sqlite3_bind_int(stmt, 2, Int32(changesDetected))

        sqlite3_step(stmt)
    }

    // MARK: - Stats Computation

    private func hasExistingStats() -> Bool {
        dbLock.lock()
        defer { dbLock.unlock() }

        let query = "SELECT COUNT(*) FROM completion_stats"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }

        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_int(stmt, 0) > 0
        }
        return false
    }

    private func recomputeStats() {
        // Completion rate
        let completionRate = computeCompletionRate()
        saveStat(key: "completion_rate", value: completionRate.rate, count: completionRate.count)

        // Overdue rate
        let overdueRate = computeOverdueRate()
        saveStat(key: "overdue_rate", value: overdueRate.rate, count: overdueRate.count)

        // Average days to complete
        // (would need created_at tracking - TODO for future)

        print("✓ Stats recomputed: completion=\(Int(completionRate.rate * 100))%, overdue=\(Int(overdueRate.rate * 100))%")
    }

    private func computeCompletionRate() -> (rate: Double, count: Int) {
        dbLock.lock()
        defer { dbLock.unlock() }

        // Count tasks that went to Done vs Cancelled
        let sql = """
        SELECT new_status, COUNT(*) as cnt
        FROM status_changes
        WHERE new_status IN ('Done', 'Cancelled')
        GROUP BY new_status
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return (0, 0) }
        defer { sqlite3_finalize(stmt) }

        var doneCount = 0
        var cancelledCount = 0

        while sqlite3_step(stmt) == SQLITE_ROW {
            if let statusPtr = sqlite3_column_text(stmt, 0) {
                let status = String(cString: statusPtr)
                let count = Int(sqlite3_column_int(stmt, 1))

                if status == "Done" { doneCount = count }
                else if status == "Cancelled" { cancelledCount = count }
            }
        }

        let total = doneCount + cancelledCount
        guard total > 0 else { return (0, 0) }

        return (Double(doneCount) / Double(total), total)
    }

    private func computeOverdueRate() -> (rate: Double, count: Int) {
        dbLock.lock()
        defer { dbLock.unlock() }

        let sql = """
        SELECT was_overdue, COUNT(*) as cnt
        FROM status_changes
        WHERE new_status = 'Done'
        GROUP BY was_overdue
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return (0, 0) }
        defer { sqlite3_finalize(stmt) }

        var overdueCount = 0
        var onTimeCount = 0

        while sqlite3_step(stmt) == SQLITE_ROW {
            let wasOverdue = sqlite3_column_int(stmt, 0) == 1
            let count = Int(sqlite3_column_int(stmt, 1))

            if wasOverdue { overdueCount = count }
            else { onTimeCount = count }
        }

        let total = overdueCount + onTimeCount
        guard total > 0 else { return (0, 0) }

        return (Double(overdueCount) / Double(total), total)
    }

    /// Compute stats from current task snapshot (not just from changes)
    private func computeCurrentStateStats(tasks: [TaskItem]) {
        // Count by status
        var statusCounts: [String: Int] = [:]
        var totalTasks = 0
        var overdueCount = 0
        var priorityCounts: [String: Int] = [:]
        var typeCounts: [String: Int] = [:]

        for task in tasks {
            totalTasks += 1
            let status = task.status.rawValue
            statusCounts[status, default: 0] += 1

            if task.isOverdue {
                overdueCount += 1
            }

            if let priority = task.priority?.rawValue {
                priorityCounts[priority, default: 0] += 1
            }

            typeCounts[task.type.rawValue, default: 0] += 1
        }

        // Save total tasks
        saveStat(key: "total_tasks", value: Double(totalTasks), count: totalTasks)

        // Completion rate from current state (Done / (Done + Cancelled + other terminal states))
        let doneCount = statusCounts["Done"] ?? 0
        let cancelledCount = statusCounts["Cancelled"] ?? 0
        let activeCount = totalTasks - doneCount - cancelledCount

        if totalTasks > 0 {
            // Completion rate = done out of all tasks
            let completionRate = Double(doneCount) / Double(totalTasks)
            saveStat(key: "completion_rate", value: completionRate, count: totalTasks)

            // Overdue rate = overdue out of active (non-done, non-cancelled) tasks
            if activeCount > 0 {
                let overdueRate = Double(overdueCount) / Double(activeCount)
                saveStat(key: "overdue_rate", value: overdueRate, count: activeCount)
            }
        }

        // Save status breakdown
        for (status, count) in statusCounts {
            saveStat(key: "status_\(status.lowercased().replacingOccurrences(of: " ", with: "_"))", value: Double(count), count: count)
        }

        // Save type breakdown
        for (type, count) in typeCounts {
            saveStat(key: "type_\(type.lowercased())", value: Double(count), count: count)
        }

        print("✓ Current state stats: \(totalTasks) tasks, \(doneCount) done, \(overdueCount) overdue")
    }

    private func saveStat(key: String, value: Double, count: Int) {
        dbLock.lock()
        defer { dbLock.unlock() }

        let sql = """
        INSERT OR REPLACE INTO completion_stats (stat_key, stat_value, sample_count, last_updated)
        VALUES (?, ?, ?, CURRENT_TIMESTAMP)
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, 1, key)
        sqlite3_bind_double(stmt, 2, value)
        sqlite3_bind_int(stmt, 3, Int32(count))

        sqlite3_step(stmt)
    }

    // MARK: - Public Stats API

    /// Get all computed stats
    func getStats() -> LifecycleStats {
        dbLock.lock()
        defer { dbLock.unlock() }

        var stats = LifecycleStats()

        // Get completed tasks count from status_done stat
        let doneStatQuery = "SELECT stat_value FROM completion_stats WHERE stat_key = 'status_done'"
        var stmt: OpaquePointer?

        if sqlite3_prepare_v2(db, doneStatQuery, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                stats.totalCompleted = Int(sqlite3_column_double(stmt, 0))
            }
            sqlite3_finalize(stmt)
            stmt = nil
        }

        // Get computed stats (completion rate and overdue rate)
        let query = "SELECT stat_key, stat_value FROM completion_stats WHERE stat_key IN ('completion_rate', 'overdue_rate')"

        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let keyPtr = sqlite3_column_text(stmt, 0) {
                    let key = String(cString: keyPtr)
                    let value = sqlite3_column_double(stmt, 1)

                    switch key {
                    case "completion_rate":
                        stats.completionRate = value
                    case "overdue_rate":
                        stats.overdueRate = value
                    default:
                        break
                    }
                }
            }
            sqlite3_finalize(stmt)
            stmt = nil
        }

        // Get total tasks tracked
        let countQuery = "SELECT COUNT(*) FROM task_snapshots"
        if sqlite3_prepare_v2(db, countQuery, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                stats.totalTasks = Int(sqlite3_column_int(stmt, 0))
            }
            sqlite3_finalize(stmt)
            stmt = nil
        }

        // If totalCompleted wasn't set from stats, count Done tasks directly
        if stats.totalCompleted == 0 {
            let doneQuery = "SELECT COUNT(*) FROM task_snapshots WHERE status = 'Done'"
            if sqlite3_prepare_v2(db, doneQuery, -1, &stmt, nil) == SQLITE_OK {
                if sqlite3_step(stmt) == SQLITE_ROW {
                    stats.totalCompleted = Int(sqlite3_column_int(stmt, 0))
                }
                sqlite3_finalize(stmt)
                stmt = nil
            }
        }

        // Get total changes recorded
        let changesQuery = "SELECT COUNT(*) FROM status_changes"
        if sqlite3_prepare_v2(db, changesQuery, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                stats.totalChanges = Int(sqlite3_column_int(stmt, 0))
            }
            sqlite3_finalize(stmt)
            stmt = nil
        }

        // Get last scan time
        let scanQuery = "SELECT MAX(scanned_at) FROM scan_history"
        if sqlite3_prepare_v2(db, scanQuery, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                if let datePtr = sqlite3_column_text(stmt, 0) {
                    let dateStr = String(cString: datePtr)
                    // SQLite datetime format: "2026-01-31 09:47:17"
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                    formatter.timeZone = TimeZone(identifier: "UTC")
                    stats.lastScanTime = formatter.date(from: dateStr)
                }
            }
            sqlite3_finalize(stmt)
            stmt = nil
        }

        return stats
    }

    /// Get recent status changes
    func getRecentChanges(limit: Int = 20) -> [StatusChange] {
        dbLock.lock()
        defer { dbLock.unlock() }

        var changes: [StatusChange] = []

        let query = """
        SELECT notion_id, title, old_status, new_status, task_type, priority, counterparty, was_overdue, changed_at
        FROM status_changes
        ORDER BY changed_at DESC
        LIMIT ?
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(limit))

        while sqlite3_step(stmt) == SQLITE_ROW {
            let change = StatusChange(
                notionId: String(cString: sqlite3_column_text(stmt, 0)),
                title: String(cString: sqlite3_column_text(stmt, 1)),
                oldStatus: String(cString: sqlite3_column_text(stmt, 2)),
                newStatus: String(cString: sqlite3_column_text(stmt, 3)),
                taskType: String(cString: sqlite3_column_text(stmt, 4)),
                priority: sqlite3_column_text(stmt, 5).map { String(cString: $0) },
                counterparty: sqlite3_column_text(stmt, 6).map { String(cString: $0) },
                wasOverdue: sqlite3_column_int(stmt, 7) == 1
            )
            changes.append(change)
        }

        return changes
    }

    /// Get stats by counterparty (who you work with most effectively)
    func getStatsByCounterparty() -> [CounterpartyStats] {
        dbLock.lock()
        defer { dbLock.unlock() }

        var stats: [CounterpartyStats] = []

        let query = """
        SELECT counterparty,
               COUNT(*) as total,
               SUM(CASE WHEN new_status = 'Done' THEN 1 ELSE 0 END) as completed,
               SUM(CASE WHEN was_overdue = 1 THEN 1 ELSE 0 END) as overdue
        FROM status_changes
        WHERE counterparty != '' AND new_status IN ('Done', 'Cancelled')
        GROUP BY counterparty
        ORDER BY total DESC
        LIMIT 10
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let counterparty = String(cString: sqlite3_column_text(stmt, 0))
            let total = Int(sqlite3_column_int(stmt, 1))
            let completed = Int(sqlite3_column_int(stmt, 2))
            let overdue = Int(sqlite3_column_int(stmt, 3))

            stats.append(CounterpartyStats(
                name: counterparty,
                totalTasks: total,
                completedTasks: completed,
                completionRate: total > 0 ? Double(completed) / Double(total) : 0,
                overdueRate: completed > 0 ? Double(overdue) / Double(completed) : 0
            ))
        }

        return stats
    }
}

// MARK: - Data Models

struct ScanResult {
    let tasksScanned: Int
    let newTasks: Int
    let changesDetected: Int
    let changes: [StatusChange]
    let fromCache: Bool  // True if scan was skipped (already in progress)
}

struct StatusChange {
    let notionId: String
    let title: String
    let oldStatus: String
    let newStatus: String
    let taskType: String
    let priority: String?
    let counterparty: String?
    let wasOverdue: Bool
}

struct LifecycleStats {
    var totalTasks: Int = 0
    var totalChanges: Int = 0
    var totalCompleted: Int = 0
    var completionRate: Double = 0
    var overdueRate: Double = 0
    var lastScanTime: Date?
}

struct CounterpartyStats {
    let name: String
    let totalTasks: Int
    let completedTasks: Int
    let completionRate: Double
    let overdueRate: Double
}
