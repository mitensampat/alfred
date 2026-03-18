import Foundation

// MARK: - Unified Tasks Database Extension

extension NotionService {
    private static var tasksDatabaseIdStorage: String?

    var tasksDatabaseId: String? {
        get { NotionService.tasksDatabaseIdStorage }
        set { NotionService.tasksDatabaseIdStorage = newValue }
    }

    func setTasksDatabaseId(_ id: String) {
        NotionService.tasksDatabaseIdStorage = id
    }

    /// Create the unified Tasks database (simplified for easy manual use)
    func createTasksDatabase(parentPageId: String? = nil) async throws -> String {
        let url = URL(string: "https://api.notion.com/v1/databases")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let parent: [String: Any]
        if let pageId = parentPageId {
            parent = ["type": "page_id", "page_id": pageId]
        } else {
            parent = ["type": "workspace", "workspace": true]
        }

        // Simple schema - easy to use manually in Notion
        let properties: [String: Any] = [
            "Title": ["title": [String: Any]()],
            "Status": ["status": [String: Any]()],
            "Due Date": ["date": [String: Any]()],
            "Priority": ["select": ["options": [
                ["name": "Critical", "color": "red"],
                ["name": "High", "color": "orange"],
                ["name": "Medium", "color": "yellow"],
                ["name": "Low", "color": "gray"]
            ]]],
            "Type": ["select": ["options": [
                ["name": "Todo", "color": "blue"],
                ["name": "Commitment", "color": "purple"],
                ["name": "Follow-up", "color": "green"]
            ]]],
            "Description": ["rich_text": [String: Any]()],
            "Source": ["select": ["options": [
                ["name": "WhatsApp", "color": "green"],
                ["name": "iMessage", "color": "blue"],
                ["name": "Email", "color": "orange"],
                ["name": "Signal", "color": "purple"],
                ["name": "Manual", "color": "gray"]
            ]]],
            "Unique Hash": ["rich_text": [String: Any]()],
            "Created": ["created_time": [String: Any]()],
            "Updated": ["last_edited_time": [String: Any]()]
        ]

        let body: [String: Any] = [
            "parent": parent,
            "title": [
                [
                    "type": "text",
                    "text": ["content": "Tasks"]
                ]
            ],
            "properties": properties
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "NotionService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create Tasks database"])
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let databaseId = json?["id"] as? String else {
            throw NSError(domain: "NotionService", code: 1, userInfo: [NSLocalizedDescriptionKey: "No database ID in response"])
        }

        setTasksDatabaseId(databaseId)
        return databaseId
    }

    /// Error for duplicate task detection
    enum TaskCreationError: Error {
        case duplicate(existingId: String)
    }

    /// Create a task in the unified Tasks database
    /// Returns the page ID if created
    /// Throws TaskCreationError.duplicate if task already exists
    func createTask(_ task: TaskItem) async throws -> String {
        guard let dbId = tasksDatabaseId else {
            throw NSError(domain: "NotionService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Tasks database ID not set"])
        }

        // Check for duplicate by hash before creating
        if let hash = task.uniqueHash, !hash.isEmpty {
            if let existingId = try await findTaskByHash(hash) {
                print("⚠️ Duplicate task found, skipping: \(task.title)")
                throw TaskCreationError.duplicate(existingId: existingId)
            }
        }

        let url = URL(string: "https://api.notion.com/v1/pages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Build simplified description for commitments using arrow format
        var enhancedDescription = task.description ?? ""
        var displayTitle = task.title

        if task.type == .commitment {
            var parts: [String] = []

            // Arrow format header: "→ John" or "← Sarah"
            if let direction = task.commitmentDirection {
                let arrow = direction == .iOwe ? "→" : "←"
                let counterparty = direction == .iOwe ? (task.committedTo ?? "them") : (task.committedBy ?? "them")
                parts.append("\(arrow) \(counterparty)")

                // Add arrow prefix to title: "→ John: Review proposal"
                displayTitle = "\(arrow) \(counterparty): \(task.title)"
            }

            // Add commitment text if different from title
            if let desc = task.description, !desc.isEmpty, desc != task.title {
                parts.append("")  // blank line
                parts.append(desc)
            }

            // Add truncated context if available
            if let context = task.originalContext, !context.isEmpty {
                let truncatedContext = context.count > 300 ? String(context.prefix(297)) + "..." : context
                parts.append("")
                parts.append("---")
                parts.append("Context: \(truncatedContext)")
            }

            enhancedDescription = parts.joined(separator: "\n")
        }

        // Build properties for simplified schema
        var properties: [String: Any] = [
            "Title": [
                "title": [[
                    "text": ["content": displayTitle]
                ]]
            ],
            "Status": [
                "status": ["name": task.status.rawValue]
            ],
            "Type": [
                "select": ["name": task.type.rawValue]
            ]
        ]

        if !enhancedDescription.isEmpty {
            properties["Description"] = [
                "rich_text": [[
                    "text": ["content": String(enhancedDescription.prefix(2000))] // Notion limit
                ]]
            ]
        }

        if let dueDate = task.dueDate {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            properties["Due Date"] = [
                "date": ["start": formatter.string(from: dueDate)]
            ]
        }

        if let priority = task.priority {
            properties["Priority"] = [
                "select": ["name": priority.rawValue]
            ]
        }

        if let platform = task.sourcePlatform {
            properties["Source"] = [
                "select": ["name": platform.rawValue]
            ]
        }

        if let hash = task.uniqueHash {
            properties["Unique Hash"] = [
                "rich_text": [[
                    "text": ["content": hash]
                ]]
            ]
        }

        let body: [String: Any] = [
            "parent": ["database_id": dbId],
            "properties": properties
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let responseStr = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "NotionService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create task: \(responseStr)"])
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let pageId = json?["id"] as? String else {
            throw NSError(domain: "NotionService", code: 1, userInfo: [NSLocalizedDescriptionKey: "No page ID in response"])
        }

        return pageId
    }

    /// Query active tasks
    func queryActiveTasks(type: TaskItem.TaskType? = nil) async throws -> [TaskItem] {
        guard let dbId = tasksDatabaseId else {
            throw NSError(domain: "NotionService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Tasks database ID not set"])
        }

        let url = URL(string: "https://api.notion.com/v1/databases/\(dbId)/query")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var filters: [[String: Any]] = [
            ["property": "Status", "status": ["does_not_equal": "Done"]],
            ["property": "Status", "status": ["does_not_equal": "Cancelled"]]
        ]

        if let type = type {
            filters.append(["property": "Type", "select": ["equals": type.rawValue]])
        }

        let body: [String: Any] = [
            "filter": [
                "and": filters
            ],
            "sorts": [
                ["property": "Due Date", "direction": "ascending"]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "NotionService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to query tasks"])
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let results = json?["results"] as? [[String: Any]] else {
            return []
        }

        return results.compactMap { parseTaskFromNotionPage($0) }
    }

    /// Query tasks completed in the last N days (for weekly review context)
    func queryRecentlyCompletedTasks(days: Int = 7) async throws -> [TaskItem] {
        guard let dbId = tasksDatabaseId else {
            throw NSError(domain: "NotionService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Tasks database ID not set"])
        }

        let url = URL(string: "https://api.notion.com/v1/databases/\(dbId)/query")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // ISO date for N days ago
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withFullDate]
        let cutoffStr = fmt.string(from: cutoff)

        let body: [String: Any] = [
            "filter": [
                "and": [
                    ["property": "Status", "status": ["equals": "Done"]],
                    ["timestamp": "last_edited_time", "last_edited_time": ["on_or_after": cutoffStr]]
                ]
            ],
            "sorts": [
                ["timestamp": "last_edited_time", "direction": "descending"]
            ],
            "page_size": 20
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "NotionService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to query completed tasks"])
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let results = json?["results"] as? [[String: Any]] else {
            return []
        }

        return results.compactMap { parseTaskFromNotionPage($0) }
    }

    /// Update task status
    func updateTaskStatus(notionId: String, status: TaskItem.TaskStatus) async throws {
        let url = URL(string: "https://api.notion.com/v1/pages/\(notionId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "properties": [
                "Status": [
                    "status": ["name": status.rawValue]
                ]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "NotionService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to update task status"])
        }
    }

    // MARK: - Task Property Updates (Coach Chat → Notion)

    /// Grouped property update request for a single PATCH call
    struct TaskPropertyUpdate {
        var status: TaskItem.TaskStatus?
        var priority: TaskItem.Priority?
        var dueDate: Date?
        var appendDescription: String?  // appended to existing description, not replaced
    }

    /// Update multiple task properties in a single Notion API call.
    /// For appendDescription, reads the current description first and appends.
    func updateTaskProperties(notionId: String, updates: TaskPropertyUpdate) async throws {
        var properties: [String: Any] = [:]

        if let status = updates.status {
            properties["Status"] = ["status": ["name": status.rawValue]]
        }
        if let priority = updates.priority {
            properties["Priority"] = ["select": ["name": priority.rawValue]]
        }
        if let dueDate = updates.dueDate {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            properties["Due Date"] = ["date": ["start": formatter.string(from: dueDate)]]
        }

        // Handle description append (read-modify-write)
        if let appendText = updates.appendDescription {
            // GET current page to read existing description
            let getUrl = URL(string: "https://api.notion.com/v1/pages/\(notionId)")!
            var getRequest = URLRequest(url: getUrl)
            getRequest.httpMethod = "GET"
            getRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            getRequest.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")

            var existingDescription = ""
            if let (getData, getResponse) = try? await URLSession.shared.data(for: getRequest),
               let getHttp = getResponse as? HTTPURLResponse,
               (200...299).contains(getHttp.statusCode),
               let json = try? JSONSerialization.jsonObject(with: getData) as? [String: Any],
               let props = json["properties"] as? [String: Any],
               let descProp = props["Description"] as? [String: Any],
               let richTextArray = descProp["rich_text"] as? [[String: Any]] {
                existingDescription = richTextArray.compactMap { $0["plain_text"] as? String }.joined()
            }

            let newDescription = existingDescription.isEmpty ? appendText : existingDescription + "\n\n" + appendText
            properties["Description"] = [
                "rich_text": [[
                    "text": ["content": String(newDescription.prefix(2000))]
                ]]
            ]
        }

        guard !properties.isEmpty else { return }

        let url = URL(string: "https://api.notion.com/v1/pages/\(notionId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["properties": properties]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "NotionService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to update task properties"])
        }
    }

    /// Search for active tasks by fuzzy title match (case-insensitive substring)
    func findTasksByFuzzyTitle(_ searchTerm: String) async throws -> [TaskItem] {
        guard let dbId = tasksDatabaseId else {
            throw NSError(domain: "NotionService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Tasks database ID not set"])
        }

        let url = URL(string: "https://api.notion.com/v1/databases/\(dbId)/query")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "filter": [
                "and": [
                    ["property": "Title", "title": ["contains": searchTerm]],
                    ["property": "Status", "status": ["does_not_equal": "Done"]],
                    ["property": "Status", "status": ["does_not_equal": "Cancelled"]]
                ]
            ],
            "sorts": [
                ["property": "Due Date", "direction": "ascending"]
            ],
            "page_size": 10
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "NotionService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to search tasks"])
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let results = json?["results"] as? [[String: Any]] else {
            return []
        }

        return results.compactMap { parseTaskFromNotionPage($0) }
    }

    /// Find task by hash
    func findTaskByHash(_ hash: String) async throws -> String? {
        guard let dbId = tasksDatabaseId else {
            throw NSError(domain: "NotionService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Tasks database ID not set"])
        }

        let url = URL(string: "https://api.notion.com/v1/databases/\(dbId)/query")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "filter": [
                "property": "Unique Hash",
                "rich_text": ["equals": hash]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            return nil
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let results = json?["results"] as? [[String: Any]],
              let firstResult = results.first,
              let id = firstResult["id"] as? String else {
            return nil
        }

        return id
    }

    /// Get the single highest-priority active task, for Focus Card display
    /// Priority order: Critical > High > Medium > Low > nil, then by due date ascending
    func getTopPriorityTask() async throws -> TaskItem? {
        guard let dbId = tasksDatabaseId else { return nil }

        let url = URL(string: "https://api.notion.com/v1/databases/\(dbId)/query")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Query active tasks with Critical or High priority first, sorted by due date
        let body: [String: Any] = [
            "filter": [
                "and": [
                    ["property": "Status", "status": ["does_not_equal": "Done"]],
                    ["property": "Status", "status": ["does_not_equal": "Cancelled"]]
                ]
            ],
            "sorts": [
                ["property": "Due Date", "direction": "ascending"]
            ],
            "page_size": 20
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            return nil
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let results = json?["results"] as? [[String: Any]] else {
            return nil
        }

        let tasks = results.compactMap { parseTaskFromNotionPage($0) }

        // Sort by priority weight (Critical=0, High=1, Medium=2, Low=3, nil=4), then due date
        let priorityOrder: [TaskItem.Priority: Int] = [
            .critical: 0, .high: 1, .medium: 2, .low: 3
        ]

        let sorted = tasks.sorted { a, b in
            let aPri = a.priority.map { priorityOrder[$0] ?? 4 } ?? 4
            let bPri = b.priority.map { priorityOrder[$0] ?? 4 } ?? 4
            if aPri != bPri { return aPri < bPri }
            // Same priority: earlier due date wins
            let aDate = a.dueDate ?? Date.distantFuture
            let bDate = b.dueDate ?? Date.distantFuture
            return aDate < bDate
        }

        return sorted.first
    }

    // MARK: - Fetch Single Task by ID

    /// Fetch a specific task by its Notion page ID
    func fetchTaskById(notionId: String) async throws -> TaskItem? {
        let url = URL(string: "https://api.notion.com/v1/pages/\(notionId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            return nil
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return parseTaskFromNotionPage(json)
    }

    // MARK: - Commitment Compatibility Methods (use unified Tasks database)

    /// Query active commitments from the unified Tasks database
    /// Returns Commitment objects for backward compatibility with existing code
    func queryActiveCommitmentsFromTasks(type: Commitment.CommitmentType? = nil) async throws -> [Commitment] {
        // Map Commitment type filter to TaskItem type filter
        let taskType: TaskItem.TaskType = .commitment

        // Query tasks filtered by commitment type
        let tasks = try await queryActiveTasks(type: taskType)

        // Convert TaskItems to Commitments and filter by direction if specified
        var commitments = tasks.compactMap { $0.toCommitment() }

        if let type = type {
            commitments = commitments.filter { $0.type == type }
        }

        return commitments
    }

    /// Query overdue commitments from the unified Tasks database
    func queryOverdueCommitmentsFromTasks() async throws -> [Commitment] {
        let commitments = try await queryActiveCommitmentsFromTasks()
        return commitments.filter { $0.isOverdue }
    }

    /// Query upcoming commitments (due within specified hours) from the unified Tasks database
    func queryUpcomingCommitmentsFromTasks(withinHours: Int) async throws -> [Commitment] {
        let commitments = try await queryActiveCommitmentsFromTasks()
        let now = Date()
        let future = Calendar.current.date(byAdding: .hour, value: withinHours, to: now) ?? now

        return commitments.filter { commitment in
            guard let dueDate = commitment.dueDate else { return false }
            return dueDate >= now && dueDate <= future
        }
    }

    /// Find commitment by hash in the unified Tasks database
    /// Wrapper around findTaskByHash for backward compatibility
    func findCommitmentByHashInTasks(_ hash: String) async throws -> String? {
        return try await findTaskByHash(hash)
    }

    /// Find commitment by hash and return both page ID and status
    /// Used for reverse sync: detecting when user manually marks Done in Notion
    func findCommitmentWithStatusByHash(_ hash: String) async throws -> (pageId: String, status: String)? {
        guard let dbId = tasksDatabaseId else { return nil }

        let url = URL(string: "https://api.notion.com/v1/databases/\(dbId)/query")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "filter": [
                "property": "Unique Hash",
                "rich_text": ["equals": hash]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            return nil
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let results = json?["results"] as? [[String: Any]],
              let firstResult = results.first,
              let id = firstResult["id"] as? String,
              let properties = firstResult["properties"] as? [String: Any],
              let statusProp = properties["Status"] as? [String: Any],
              let statusObj = statusProp["status"] as? [String: Any],
              let statusName = statusObj["name"] as? String else {
            return nil
        }

        return (pageId: id, status: statusName)
    }

    /// Create a commitment in the unified Tasks database
    /// Wrapper that converts Commitment to TaskItem
    func createCommitmentInTasks(_ commitment: Commitment) async throws -> String {
        let taskItem = TaskItem.fromCommitment(commitment)
        return try await createTask(taskItem)
    }

    /// Close a commitment by hash in the unified Tasks database
    /// Updates status to "Done" and adds closure reason to description
    func closeCommitmentInTasks(hash: String, reason: String) async throws {
        guard tasksDatabaseId != nil else {
            throw NSError(domain: "NotionService", code: 100, userInfo: [NSLocalizedDescriptionKey: "Tasks database not configured"])
        }

        // First find the page ID by hash
        guard let pageId = try await findTaskByHash(hash) else {
            print("⚠️ Commitment with hash \(hash.prefix(8))... not found in Notion")
            return
        }

        // Update the page
        let url = URL(string: "https://api.notion.com/v1/pages/\(pageId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "properties": [
                "Status": [
                    "status": [
                        "name": "Done"
                    ]
                ]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "NotionService", code: 101, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "NotionService", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Failed to close commitment: \(errorBody)"])
        }

        print("✅ Closed commitment in Notion: \(reason)")
    }

    /// Get commitment statistics from Notion (open, closed, total)
    func getCommitmentStatsFromNotion() async throws -> (open: Int, closed: Int, total: Int) {
        guard let databaseId = tasksDatabaseId else {
            return (0, 0, 0)
        }

        var openCount = 0
        var closedCount = 0
        var totalCount = 0
        var startCursor: String? = nil
        var hasMore = true

        // Paginate through all commitment pages in Notion
        while hasMore {
            let url = URL(string: "https://api.notion.com/v1/databases/\(databaseId)/query")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            // Filter for commitments only (Type = "Commitment")
            var body: [String: Any] = [
                "filter": [
                    "property": "Type",
                    "select": [
                        "equals": "Commitment"
                    ]
                ],
                "page_size": 100
            ]

            if let cursor = startCursor {
                body["start_cursor"] = cursor
            }

            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                break
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else {
                break
            }

            for page in results {
                if let properties = page["properties"] as? [String: Any],
                   let status = properties["Status"] as? [String: Any],
                   let statusObj = status["status"] as? [String: Any],
                   let statusName = statusObj["name"] as? String {
                    if statusName == "Done" || statusName == "Cancelled" {
                        closedCount += 1
                    } else {
                        openCount += 1
                    }
                }
            }

            totalCount += results.count

            // Check for more pages
            hasMore = (json["has_more"] as? Bool) ?? false
            startCursor = json["next_cursor"] as? String

            // Safety cap: don't paginate endlessly
            if totalCount >= 2000 { break }
        }

        return (openCount, closedCount, totalCount)
    }

    // MARK: - Deduplication Cleanup

    /// Fetch all open commitments from Notion, group by normalized title,
    /// and archive duplicates (keeping the oldest per group).
    /// Returns (archived count, groups affected).
    func deduplicateCommitments() async throws -> (archived: Int, groups: Int) {
        guard let dbId = tasksDatabaseId else {
            throw NSError(domain: "NotionService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Tasks database not configured"])
        }

        // Step 1: Fetch ALL open commitments with pagination
        var allPages: [(id: String, title: String, createdTime: String)] = []
        var startCursor: String? = nil
        var hasMore = true

        while hasMore {
            let url = URL(string: "https://api.notion.com/v1/databases/\(dbId)/query")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            var body: [String: Any] = [
                "filter": [
                    "and": [
                        [
                            "property": "Type",
                            "select": ["equals": "Commitment"]
                        ],
                        [
                            "property": "Status",
                            "status": ["does_not_equal": "Done"]
                        ],
                        [
                            "property": "Status",
                            "status": ["does_not_equal": "Cancelled"]
                        ]
                    ]
                ],
                "sorts": [
                    ["timestamp": "created_time", "direction": "ascending"]
                ],
                "page_size": 100
            ]

            if let cursor = startCursor {
                body["start_cursor"] = cursor
            }

            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { break }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else { break }

            for page in results {
                guard let pageId = page["id"] as? String,
                      let createdTime = page["created_time"] as? String,
                      let properties = page["properties"] as? [String: Any],
                      let titleProp = properties["Title"] as? [String: Any],
                      let titleArray = titleProp["title"] as? [[String: Any]],
                      let firstTitle = titleArray.first,
                      let title = firstTitle["plain_text"] as? String else { continue }
                allPages.append((id: pageId, title: title, createdTime: createdTime))
            }

            hasMore = (json["has_more"] as? Bool) ?? false
            startCursor = json["next_cursor"] as? String
            if allPages.count >= 2000 { break }
        }

        print("🔍 Dedup: found \(allPages.count) open commitments")

        // Step 2: Group by normalized title (same normalization as hash)
        var groups: [String: [(id: String, title: String, createdTime: String)]] = [:]
        for page in allPages {
            let key = Commitment.normalizeForHash(page.title)
            groups[key, default: []].append(page)
        }

        // Step 3: For each group with >1 entry, archive all but the oldest
        var archivedCount = 0
        var groupsAffected = 0

        for (normalizedTitle, pages) in groups {
            guard pages.count > 1 else { continue }
            groupsAffected += 1
            // Sorted ascending by created_time — keep first, archive rest
            let sorted = pages.sorted { $0.createdTime < $1.createdTime }
            let keeper = sorted.first!
            let dupes = sorted.dropFirst()

            print("🗑️  Dedup group '\(normalizedTitle)': keeping '\(keeper.title)' (\(keeper.id.prefix(8))), archiving \(dupes.count) duplicates")

            for dupe in dupes {
                do {
                    try await archiveNotionPage(pageId: dupe.id)
                    archivedCount += 1
                    // Rate-limit: Notion API has 3 req/sec limit
                    try await Task.sleep(nanoseconds: 350_000_000) // 350ms
                } catch {
                    print("⚠️  Failed to archive \(dupe.id.prefix(8)): \(error.localizedDescription)")
                }
            }
        }

        print("✅ Dedup complete: archived \(archivedCount) duplicates across \(groupsAffected) groups")
        return (archived: archivedCount, groups: groupsAffected)
    }

    /// Archive (soft-delete) a Notion page
    func archiveNotionPage(pageId: String) async throws {
        let url = URL(string: "https://api.notion.com/v1/pages/\(pageId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["archived": true]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown"
            throw NSError(domain: "NotionService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Archive failed: \(errorBody)"])
        }
    }

    // MARK: - Parsing

    /// Parse Task from Notion page JSON
    private func parseTaskFromNotionPage(_ result: [String: Any]) -> TaskItem? {
        guard let id = result["id"] as? String,
              let properties = result["properties"] as? [String: Any] else {
            return nil
        }

        // Extract title
        guard let titleProp = properties["Title"] as? [String: Any],
              let titleArray = titleProp["title"] as? [[String: Any]],
              let firstTitle = titleArray.first,
              let plainText = firstTitle["plain_text"] as? String else {
            return nil
        }

        // Extract type
        var typeString = "Todo"
        if let typeProp = properties["Type"] as? [String: Any],
           let selectData = typeProp["select"] as? [String: Any],
           let typeName = selectData["name"] as? String {
            typeString = typeName
        }
        let type = TaskItem.TaskType(rawValue: typeString) ?? .todo

        // Extract status
        var statusString = "Not Started"
        if let statusProp = properties["Status"] as? [String: Any],
           let statusData = statusProp["status"] as? [String: Any],
           let statusName = statusData["name"] as? String {
            statusString = statusName
        }
        let status = TaskItem.TaskStatus(rawValue: statusString) ?? .notStarted

        // Extract description
        var description: String?
        if let descProp = properties["Description"] as? [String: Any],
           let richTextArray = descProp["rich_text"] as? [[String: Any]],
           !richTextArray.isEmpty {
            description = richTextArray.compactMap { $0["plain_text"] as? String }.joined()
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

        // Extract priority
        var priority: TaskItem.Priority?
        if let priorityProp = properties["Priority"] as? [String: Any],
           let selectData = priorityProp["select"] as? [String: Any],
           let priorityName = selectData["name"] as? String {
            priority = TaskItem.Priority(rawValue: priorityName)
        }

        // Extract source platform
        var sourcePlatform: TaskItem.SourcePlatform?
        if let sourceProp = properties["Source"] as? [String: Any],
           let selectData = sourceProp["select"] as? [String: Any],
           let sourceName = selectData["name"] as? String {
            sourcePlatform = TaskItem.SourcePlatform(rawValue: sourceName)
        }

        // Extract unique hash
        var uniqueHash: String?
        if let hashProp = properties["Unique Hash"] as? [String: Any],
           let richTextArray = hashProp["rich_text"] as? [[String: Any]],
           let firstText = richTextArray.first,
           let text = firstText["plain_text"] as? String {
            uniqueHash = text
        }

        let createdDate = Date()
        let lastUpdated = Date()

        // Parse commitment/followup details from description
        var committedBy: String?
        var committedTo: String?
        var commitmentDirection: TaskItem.CommitmentDirection?
        var originalContext: String?
        var followUpDate: Date?

        if let desc = description {
            if type == .commitment {
                // Parse commitment details from description
                // New arrow format: "→ John" (I Owe to John) or "← Sarah" (Sarah owes me)
                // Legacy format: "Direction: I Owe\nCommitted by: X\nCommitted to: Y\n..."
                let lines = desc.components(separatedBy: "\n")

                // Check for new arrow format first (first line starts with → or ←)
                if let firstLine = lines.first?.trimmingCharacters(in: .whitespaces) {
                    if firstLine.hasPrefix("→ ") {
                        // I Owe direction: "→ John" means I owe to John
                        commitmentDirection = .iOwe
                        committedTo = String(firstLine.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                        // committedBy will be extracted from title or left as nil (the user)
                    } else if firstLine.hasPrefix("← ") {
                        // They Owe direction: "← Sarah" means Sarah owes me
                        commitmentDirection = .theyOweMe
                        committedBy = String(firstLine.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                        // committedTo will be the user
                    }
                }

                // Also try to extract from title (arrow format: "→ John: Task title")
                if commitmentDirection == nil {
                    if plainText.hasPrefix("→ ") {
                        commitmentDirection = .iOwe
                        if let colonIndex = plainText.firstIndex(of: ":") {
                            let counterparty = plainText[plainText.index(plainText.startIndex, offsetBy: 2)..<colonIndex]
                            committedTo = String(counterparty).trimmingCharacters(in: .whitespaces)
                        }
                    } else if plainText.hasPrefix("← ") {
                        commitmentDirection = .theyOweMe
                        if let colonIndex = plainText.firstIndex(of: ":") {
                            let counterparty = plainText[plainText.index(plainText.startIndex, offsetBy: 2)..<colonIndex]
                            committedBy = String(counterparty).trimmingCharacters(in: .whitespaces)
                        }
                    }
                }

                // Fall back to legacy format parsing
                if commitmentDirection == nil {
                    for line in lines {
                        if line.hasPrefix("Direction: ") {
                            let direction = line.replacingOccurrences(of: "Direction: ", with: "")
                            commitmentDirection = TaskItem.CommitmentDirection(rawValue: direction)
                        } else if line.hasPrefix("Committed by: ") {
                            committedBy = line.replacingOccurrences(of: "Committed by: ", with: "")
                        } else if line.hasPrefix("Committed to: ") {
                            committedTo = line.replacingOccurrences(of: "Committed to: ", with: "")
                        }
                    }
                }

                // Extract context (after "---" separator or "Context:" prefix)
                if let contextRange = desc.range(of: "---\nContext: ") {
                    originalContext = String(desc[contextRange.upperBound...])
                } else if let contextRange = desc.range(of: "Original context:\n") {
                    originalContext = String(desc[contextRange.upperBound...])
                }

            } else if type == .followup {
                // For follow-ups, the description is the original context
                originalContext = desc
                // Follow-up date is same as due date
                followUpDate = dueDate
            }
        }

        return TaskItem(
            notionId: id,
            title: plainText,
            type: type,
            status: status,
            description: description,
            dueDate: dueDate,
            priority: priority,
            assignee: nil,
            commitmentDirection: commitmentDirection,
            committedBy: committedBy,
            committedTo: committedTo,
            originalContext: originalContext,
            sourcePlatform: sourcePlatform,
            sourceThread: nil,
            sourceThreadId: nil,
            tags: type == .followup ? ["follow-up"] : nil,
            followUpDate: followUpDate,
            uniqueHash: uniqueHash,
            notes: nil,
            createdDate: createdDate,
            lastUpdated: lastUpdated
        )
    }
}
