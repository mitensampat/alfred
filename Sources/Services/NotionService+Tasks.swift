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

    /// Create a task in the unified Tasks database
    func createTask(_ task: TaskItem) async throws -> String {
        guard let dbId = tasksDatabaseId else {
            throw NSError(domain: "NotionService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Tasks database ID not set"])
        }

        let url = URL(string: "https://api.notion.com/v1/pages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Build enhanced description for commitments
        var enhancedDescription = task.description ?? ""
        if task.type == .commitment {
            var commitmentDetails: [String] = []

            if let direction = task.commitmentDirection {
                commitmentDetails.append("Direction: \(direction.rawValue)")
            }
            if let committedBy = task.committedBy {
                commitmentDetails.append("Committed by: \(committedBy)")
            }
            if let committedTo = task.committedTo {
                commitmentDetails.append("Committed to: \(committedTo)")
            }
            if let context = task.originalContext, !context.isEmpty {
                commitmentDetails.append("\nOriginal context:\n\(context)")
            }

            if !commitmentDetails.isEmpty {
                let details = commitmentDetails.joined(separator: "\n")
                enhancedDescription = enhancedDescription.isEmpty ? details : "\(enhancedDescription)\n\n---\n\(details)"
            }
        }

        // Build properties for simplified schema
        var properties: [String: Any] = [
            "Title": [
                "title": [[
                    "text": ["content": task.title]
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

    /// Create a commitment in the unified Tasks database
    /// Wrapper that converts Commitment to TaskItem
    func createCommitmentInTasks(_ commitment: Commitment) async throws -> String {
        let taskItem = TaskItem.fromCommitment(commitment)
        return try await createTask(taskItem)
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
                // Try to extract commitment details from description
                // Format: "Direction: I Owe\nCommitted by: X\nCommitted to: Y\n\nOriginal context:\n..."
                let lines = desc.components(separatedBy: "\n")
                for line in lines {
                    if line.hasPrefix("Direction: ") {
                        let direction = line.replacingOccurrences(of: "Direction: ", with: "")
                        commitmentDirection = TaskItem.CommitmentDirection(rawValue: direction)
                    } else if line.hasPrefix("Committed by: ") {
                        committedBy = line.replacingOccurrences(of: "Committed by: ", with: "")
                    } else if line.hasPrefix("Committed to: ") {
                        committedTo = line.replacingOccurrences(of: "Committed to: ", with: "")
                    } else if line.hasPrefix("Original context:") {
                        // Rest of the description is context
                        if let range = desc.range(of: "Original context:\n") {
                            originalContext = String(desc[range.upperBound...])
                        }
                        break
                    }
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
