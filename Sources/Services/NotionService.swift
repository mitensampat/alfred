import Foundation

class NotionService {
    internal let apiKey: String  // Changed to internal for extension access
    private let databaseId: String
    private var commitmentsDatabaseId: String?

    init(config: NotionConfig) {
        self.apiKey = config.apiKey
        self.databaseId = config.databaseId

        // Initialize tasks database ID - check top-level first, then briefing_sources as fallback
        if let tasksDbId = config.tasksDatabaseId, tasksDbId != "YOUR_TASKS_DATABASE_ID" {
            self.setTasksDatabaseId(tasksDbId)
        } else if let tasksDbId = config.briefingSources?.tasksDatabaseId, tasksDbId != "YOUR_TASKS_DATABASE_ID" {
            self.setTasksDatabaseId(tasksDbId)
        }
    }

    // MARK: - Commitments Database Creation

    /// Create the Commitments Tracker database automatically
    func createCommitmentsDatabase(parentPageId: String? = nil) async throws -> String {
        let url = URL(string: "https://api.notion.com/v1/databases")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Use parent page if provided, otherwise create in workspace root
        let parent: [String: Any]
        if let pageId = parentPageId {
            parent = ["type": "page_id", "page_id": pageId]
        } else {
            parent = ["type": "workspace", "workspace": true]
        }

        let properties: [String: Any] = [
            "Title": [
                "title": [String: Any]()
            ],
            "Type": [
                "select": [
                    "options": [
                        ["name": "I Owe", "color": "red"],
                        ["name": "They Owe Me", "color": "blue"]
                    ]
                ]
            ],
            "Status": [
                "status": [String: Any]()
            ],
            "Commitment Text": [
                "rich_text": [String: Any]()
            ],
            "Committed By": [
                "rich_text": [String: Any]()
            ],
            "Committed To": [
                "rich_text": [String: Any]()
            ],
            "Source Platform": [
                "select": [
                    "options": [
                        ["name": "iMessage", "color": "green"],
                        ["name": "WhatsApp", "color": "green"],
                        ["name": "Meeting", "color": "blue"],
                        ["name": "Email", "color": "orange"],
                        ["name": "Signal", "color": "purple"]
                    ]
                ]
            ],
            "Source Thread": [
                "rich_text": [String: Any]()
            ],
            "Due Date": [
                "date": [String: Any]()
            ],
            "Priority": [
                "select": [
                    "options": [
                        ["name": "Critical", "color": "red"],
                        ["name": "High", "color": "orange"],
                        ["name": "Medium", "color": "yellow"],
                        ["name": "Low", "color": "gray"]
                    ]
                ]
            ],
            "Original Context": [
                "rich_text": [String: Any]()
            ],
            "Follow-up Scheduled": [
                "date": [String: Any]()
            ],
            "Unique Hash": [
                "rich_text": [String: Any]()
            ],
            "Created Date": [
                "created_time": [String: Any]()
            ],
            "Last Updated": [
                "last_edited_time": [String: Any]()
            ]
        ]

        let body: [String: Any] = [
            "parent": parent,
            "title": [
                [
                    "type": "text",
                    "text": ["content": "Commitments Tracker"]
                ]
            ],
            "properties": properties
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "NotionService", code: 10, userInfo: [NSLocalizedDescriptionKey: "Failed to create commitments database: \(errorBody)"])
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let databaseId = json?["id"] as? String else {
            throw NSError(domain: "NotionService", code: 11, userInfo: [NSLocalizedDescriptionKey: "No database ID returned"])
        }

        self.commitmentsDatabaseId = databaseId
        return databaseId
    }

    /// Check if commitments database exists and is accessible
    func validateCommitmentsDatabase(databaseId: String) async throws -> Bool {
        let url = URL(string: "https://api.notion.com/v1/databases/\(databaseId)")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            return false
        }

        if httpResponse.statusCode == 200 {
            return true
        } else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown"
            print("⚠️  Database validation failed: \(errorBody)")
            return false
        }
    }

    // MARK: - Database Schema

    private func fetchDatabaseInfo() async throws -> [String: Any]? {
        let dbUrl = URL(string: "https://api.notion.com/v1/databases/\(databaseId)")!
        var dbRequest = URLRequest(url: dbUrl)
        dbRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        dbRequest.setValue("2025-09-03", forHTTPHeaderField: "Notion-Version")

        let (dbData, dbResponse) = try await URLSession.shared.data(for: dbRequest)

        guard let dbHttpResponse = dbResponse as? HTTPURLResponse, dbHttpResponse.statusCode == 200 else {
            return nil
        }

        return try JSONSerialization.jsonObject(with: dbData) as? [String: Any]
    }

    private func getDatabaseSchema() async throws -> [String: String] {
        // In API 2025-09-03, need to get the data source ID first
        let dbUrl = URL(string: "https://api.notion.com/v1/databases/\(databaseId)")!
        var dbRequest = URLRequest(url: dbUrl)
        dbRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        dbRequest.setValue("2025-09-03", forHTTPHeaderField: "Notion-Version")

        let (dbData, dbResponse) = try await URLSession.shared.data(for: dbRequest)

        guard let dbHttpResponse = dbResponse as? HTTPURLResponse, dbHttpResponse.statusCode == 200 else {
            let errorBody = String(data: dbData, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "NotionService", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to get database: \(errorBody)"])
        }

        let dbJson = try JSONSerialization.jsonObject(with: dbData) as? [String: Any]

        // Get the first data source ID
        guard let dataSources = dbJson?["data_sources"] as? [[String: Any]],
              let firstDataSource = dataSources.first,
              let dataSourceId = firstDataSource["id"] as? String else {
            print("⚠️ No data sources found in database")
            return [:]
        }

        print("📊 Using data source: \(dataSourceId)")

        // Now fetch the data source schema
        let dsUrl = URL(string: "https://api.notion.com/v1/data-sources/\(dataSourceId)")!
        var dsRequest = URLRequest(url: dsUrl)
        dsRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        dsRequest.setValue("2025-09-03", forHTTPHeaderField: "Notion-Version")

        let (dsData, dsResponse) = try await URLSession.shared.data(for: dsRequest)

        guard let dsHttpResponse = dsResponse as? HTTPURLResponse, dsHttpResponse.statusCode == 200 else {
            let errorBody = String(data: dsData, encoding: .utf8) ?? "Unknown error"
            print("⚠️ Failed to fetch data source schema: \(errorBody)")
            return [:]
        }

        let dsJson = try JSONSerialization.jsonObject(with: dsData) as? [String: Any]

        guard let properties = dsJson?["properties"] as? [String: [String: Any]] else {
            print("⚠️ Failed to parse properties from data source")
            return [:]
        }

        var schema: [String: String] = [:]
        for (name, propData) in properties {
            if let type = propData["type"] as? String {
                schema[name] = type
                print("  Property: '\(name)' = \(type)")
            }
        }
        return schema
    }

    // MARK: - Todo Management

    func searchExistingTodos(title: String) async throws -> [String] {
        // Use search API to find existing pages in the database
        let url = URL(string: "https://api.notion.com/v1/search")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "filter": [
                "property": "object",
                "value": "page"
            ],
            "page_size": 100
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            print("⚠️ Failed to search todos: \(errorBody)")
            return []
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let results = json?["results"] as? [[String: Any]] else {
            return []
        }

        var existingTitles: [String] = []
        for result in results {
            // Check if this page belongs to our database
            if let parent = result["parent"] as? [String: Any],
               let parentType = parent["type"] as? String,
               (parentType == "database_id" || parentType == "data_source_id") {

                if let properties = result["properties"] as? [String: Any],
                   let taskNameProp = properties["Task name"] as? [String: Any],
                   let titleArray = taskNameProp["title"] as? [[String: Any]],
                   let firstTitle = titleArray.first,
                   let text = firstTitle["text"] as? [String: Any],
                   let content = text["content"] as? String {
                    existingTitles.append(content)
                }
            }
        }

        return existingTitles
    }

    func createTodo(title: String, description: String? = nil, dueDate: Date? = nil, assignee: String? = nil) async throws -> String {
        // First, get the database schema to find the correct property names
        let schema = try await getDatabaseSchema()
        print("📋 Database schema: \(schema)")

        let url = URL(string: "https://api.notion.com/v1/pages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var properties: [String: Any] = [:]

        // Use hardcoded "Task name" property for now
        properties["Task name"] = [
            "title": [
                [
                    "text": [
                        "content": title
                    ]
                ]
            ]
        ]
        print("✓ Writing to 'Task name': '\(title)'")

        // Find and use description property (look for "description" or any rich_text)
        if let description = description,
           let descProp = schema.first(where: {
               $0.key.lowercased().contains("description") ||
               ($0.value == "rich_text" && $0.key.lowercased() != "title")
           })?.key {
            properties[descProp] = [
                "rich_text": [
                    [
                        "text": [
                            "content": description
                        ]
                    ]
                ]
            ]
        }

        // Use "Due Date" property for due date (matches unified Tasks database schema)
        // If no due date provided, default to tomorrow
        let dueDateToUse = dueDate ?? Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        properties["Due Date"] = [
            "date": [
                "start": formatter.string(from: dueDateToUse)
            ]
        ]
        print("✓ Writing to 'Due Date': '\(formatter.string(from: dueDateToUse))'" )

        // Note: "Assign" property requires people type with user IDs, not text
        // Skipping assignee for now - would need to fetch user IDs from Notion API
        if let assignee = assignee {
            print("  ℹ️  Assignee '\(assignee)' specified (requires people type - not implemented yet)")
        }

        // For 2025-09-03 API, we need to use data_source_id in the parent
        let dbJson = try? await fetchDatabaseInfo()
        let parentDict: [String: Any]
        if let dataSources = dbJson?["data_sources"] as? [[String: Any]],
           let firstDataSource = dataSources.first,
           let dataSourceId = firstDataSource["id"] as? String {
            parentDict = ["data_source_id": dataSourceId]
        } else {
            parentDict = ["database_id": databaseId]
        }

        let body: [String: Any] = [
            "parent": parentDict,
            "properties": properties
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "NotionService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create todo: \(errorBody)"])
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["id"] as? String ?? "unknown"
    }

    // MARK: - Search & Context

    func searchWorkspace(query: String) async throws -> [NotionPage] {
        let url = URL(string: "https://api.notion.com/v1/search")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "query": query,
            "filter": [
                "property": "object",
                "value": "page"
            ],
            "page_size": 10
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "NotionService", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to search: \(errorBody)"])
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let results = json?["results"] as? [[String: Any]] else {
            return []
        }

        return results.compactMap { result in
            guard let id = result["id"] as? String else { return nil }

            // Extract title from properties
            var title = "Untitled"
            if let properties = result["properties"] as? [String: Any] {
                for (_, value) in properties {
                    if let valueDict = value as? [String: Any],
                       let type = valueDict["type"] as? String,
                       type == "title",
                       let titleArray = valueDict["title"] as? [[String: Any]],
                       let firstTitle = titleArray.first,
                       let text = firstTitle["text"] as? [String: Any],
                       let content = text["content"] as? String {
                        title = content
                        break
                    }
                }
            }

            let url = result["url"] as? String
            return NotionPage(id: id, title: title, url: url)
        }
    }

    func getPageContent(pageId: String) async throws -> String {
        let url = URL(string: "https://api.notion.com/v1/blocks/\(pageId)/children")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return ""
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let results = json?["results"] as? [[String: Any]] else {
            return ""
        }

        var content = ""
        for block in results {
            if let type = block["type"] as? String,
               let blockContent = block[type] as? [String: Any],
               let richText = blockContent["rich_text"] as? [[String: Any]] {
                for text in richText {
                    if let textContent = text["text"] as? [String: Any],
                       let textValue = textContent["content"] as? String {
                        content += textValue + " "
                    }
                }
            }
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Briefing Storage

    func saveBriefing(_ briefing: DailyBriefing) async throws -> String {
        let url = URL(string: "https://api.notion.com/v1/pages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        let dateString = formatter.string(from: briefing.date)

        // Create rich text content for the briefing
        var children: [[String: Any]] = []

        // Add messaging summary section
        let allMessages = briefing.messagingSummary.keyInteractions + briefing.messagingSummary.needsResponse
        if !allMessages.isEmpty {
            children.append([
                "object": "block",
                "type": "heading_2",
                "heading_2": [
                    "rich_text": [["type": "text", "text": ["content": "Messages Summary"]]]
                ]
            ])

            for summary in allMessages {
                children.append([
                    "object": "block",
                    "type": "paragraph",
                    "paragraph": [
                        "rich_text": [["type": "text", "text": ["content": "**\(summary.thread.platform.rawValue.uppercased())**: \(summary.thread.contactName ?? "Unknown")\n\(summary.summary)"]]]
                    ]
                ])
            }
        }

        // Add calendar section
        children.append([
            "object": "block",
            "type": "heading_2",
            "heading_2": [
                "rich_text": [["type": "text", "text": ["content": "Today's Schedule"]]]
            ]
        ])

        for event in briefing.calendarBriefing.schedule.events {
            let timeFormatter = DateFormatter()
            timeFormatter.timeStyle = .short
            let timeString = "\(timeFormatter.string(from: event.startTime)) - \(timeFormatter.string(from: event.endTime))"

            children.append([
                "object": "block",
                "type": "paragraph",
                "paragraph": [
                    "rich_text": [["type": "text", "text": ["content": "\(timeString): \(event.title)"]]]
                ]
            ])
        }

        let body: [String: Any] = [
            "parent": [
                "database_id": databaseId
            ],
            "properties": [
                "Name": [
                    "title": [
                        [
                            "text": [
                                "content": "Briefing - \(dateString)"
                            ]
                        ]
                    ]
                ]
            ],
            "children": children
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "NotionService", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to save briefing: \(errorBody)"])
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["url"] as? String ?? ""
    }

    // MARK: - Briefing Sources

    /// Format Notion ID to include dashes in standard UUID format (8-4-4-4-12)
    private func formatNotionId(_ id: String) -> String {
        let cleaned = id.replacingOccurrences(of: "-", with: "")
        guard cleaned.count == 32 else { return id }

        let index8 = cleaned.index(cleaned.startIndex, offsetBy: 8)
        let index12 = cleaned.index(cleaned.startIndex, offsetBy: 12)
        let index16 = cleaned.index(cleaned.startIndex, offsetBy: 16)
        let index20 = cleaned.index(cleaned.startIndex, offsetBy: 20)

        return "\(cleaned[..<index8])-\(cleaned[index8..<index12])-\(cleaned[index12..<index16])-\(cleaned[index16..<index20])-\(cleaned[index20...])"
    }

    /// Query notes database for contextually relevant notes using smart keyword search
    func queryRelevantNotes(context: String, databaseId: String) async throws -> [NotionNote] {
        // Extract keywords from context for searching
        let keywords = extractSearchKeywords(from: context)

        if keywords.isEmpty {
            // Fallback to recent notes if no keywords
            return try await queryRecentNotes(databaseId: databaseId, limit: 10)
        }

        // Use Notion search API to find relevant notes
        var allNotes: [NotionNote] = []
        var seenIds = Set<String>()

        // Search for each keyword
        for keyword in keywords.prefix(5) { // Limit to top 5 keywords
            let notes = try await searchNotesWithKeyword(keyword, databaseId: databaseId)
            for note in notes where !seenIds.contains(note.id) {
                seenIds.insert(note.id)
                allNotes.append(note)
            }
        }

        // Fetch content for top notes (limit to 10 to avoid too many API calls)
        var notesWithContent: [NotionNote] = []
        for note in allNotes.prefix(10) {
            let content = try await fetchNoteContent(pageId: note.id)
            notesWithContent.append(NotionNote(
                id: note.id,
                title: note.title,
                content: content,
                lastEdited: note.lastEdited
            ))
        }

        // Rank notes by relevance to context
        let rankedNotes = rankNotesByRelevance(notes: notesWithContent, keywords: keywords)

        return Array(rankedNotes.prefix(5)) // Return top 5 most relevant
    }

    /// Extract search keywords from briefing context
    private func extractSearchKeywords(from context: String) -> [String] {
        var keywords: [String] = []

        // Extract names (look for capitalized words that could be names/companies)
        let namePattern = try? NSRegularExpression(pattern: "\\b[A-Z][a-z]+(?:\\s+[A-Z][a-z]+)*\\b", options: [])
        if let matches = namePattern?.matches(in: context, options: [], range: NSRange(context.startIndex..., in: context)) {
            for match in matches {
                if let range = Range(match.range, in: context) {
                    let name = String(context[range])
                    // Filter out common words
                    let commonWords = ["Meeting", "Calendar", "Meetings", "Today", "Tomorrow", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday", "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December", "External", "Internal", "Critical", "Messages", "Total", "Focus"]
                    if !commonWords.contains(name) && name.count >= 3 {
                        keywords.append(name)
                    }
                }
            }
        }

        // Extract email domains (companies)
        let emailPattern = try? NSRegularExpression(pattern: "@([a-zA-Z0-9-]+)\\.", options: [])
        if let matches = emailPattern?.matches(in: context, options: [], range: NSRange(context.startIndex..., in: context)) {
            for match in matches {
                if let range = Range(match.range(at: 1), in: context) {
                    let domain = String(context[range])
                    if domain.count >= 3 {
                        keywords.append(domain.capitalized)
                    }
                }
            }
        }

        // Remove duplicates and return
        return Array(Set(keywords))
    }

    /// Search notes using Notion search API
    private func searchNotesWithKeyword(_ keyword: String, databaseId: String) async throws -> [NotionNote] {
        let url = URL(string: "https://api.notion.com/v1/search")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "query": keyword,
            "filter": [
                "property": "object",
                "value": "page"
            ],
            "sort": [
                "direction": "descending",
                "timestamp": "last_edited_time"
            ],
            "page_size": 10
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return []
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let results = json?["results"] as? [[String: Any]] ?? []

        // Filter to only include pages from the notes database
        let formattedDbId = formatNotionId(databaseId).lowercased()

        return results.compactMap { result -> NotionNote? in
            guard let id = result["id"] as? String,
                  let parent = result["parent"] as? [String: Any],
                  let parentDbId = parent["database_id"] as? String,
                  parentDbId.lowercased().replacingOccurrences(of: "-", with: "") == formattedDbId.replacingOccurrences(of: "-", with: ""),
                  let properties = result["properties"] as? [String: Any] else {
                return nil
            }

            // Extract title from various possible property names
            var title = ""
            for propName in ["Name", "Title", "name", "title"] {
                if let titleProp = properties[propName] as? [String: Any],
                   let titleArray = titleProp["title"] as? [[String: Any]],
                   let firstTitle = titleArray.first,
                   let text = firstTitle["plain_text"] as? String {
                    title = text
                    break
                }
            }

            // Extract last edited time
            var lastEdited = Date()
            if let lastEditedStr = result["last_edited_time"] as? String {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                lastEdited = formatter.date(from: lastEditedStr) ?? Date()
            }

            return NotionNote(id: id, title: title, content: "", lastEdited: lastEdited)
        }
    }

    /// Fetch content blocks for a note page
    private func fetchNoteContent(pageId: String) async throws -> String {
        let formattedId = formatNotionId(pageId)
        let url = URL(string: "https://api.notion.com/v1/blocks/\(formattedId)/children?page_size=50")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return ""
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let results = json?["results"] as? [[String: Any]] ?? []

        var contentParts: [String] = []

        for block in results {
            guard let blockType = block["type"] as? String else { continue }

            // Extract text from various block types
            if let blockContent = block[blockType] as? [String: Any],
               let richText = blockContent["rich_text"] as? [[String: Any]] {
                let text = richText.compactMap { $0["plain_text"] as? String }.joined()
                if !text.isEmpty {
                    contentParts.append(text)
                }
            }
        }

        // Return first 1000 characters to keep context manageable
        let fullContent = contentParts.joined(separator: "\n")
        if fullContent.count > 1000 {
            return String(fullContent.prefix(1000)) + "..."
        }
        return fullContent
    }

    /// Query recent notes without keyword search (fallback)
    private func queryRecentNotes(databaseId: String, limit: Int) async throws -> [NotionNote] {
        let formattedId = formatNotionId(databaseId)
        let url = URL(string: "https://api.notion.com/v1/databases/\(formattedId)/query")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Just get recent pages sorted by last edited
        let body: [String: Any] = [
            "sorts": [
                [
                    "timestamp": "last_edited_time",
                    "direction": "descending"
                ]
            ],
            "page_size": limit
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return []
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let results = json?["results"] as? [[String: Any]] ?? []

        return results.compactMap { result -> NotionNote? in
            guard let id = result["id"] as? String,
                  let properties = result["properties"] as? [String: Any] else {
                return nil
            }

            var title = ""
            for propName in ["Name", "Title", "name", "title"] {
                if let titleProp = properties[propName] as? [String: Any],
                   let titleArray = titleProp["title"] as? [[String: Any]],
                   let firstTitle = titleArray.first,
                   let text = firstTitle["plain_text"] as? String {
                    title = text
                    break
                }
            }

            var lastEdited = Date()
            if let lastEditedStr = result["last_edited_time"] as? String {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                lastEdited = formatter.date(from: lastEditedStr) ?? Date()
            }

            return NotionNote(id: id, title: title, content: "", lastEdited: lastEdited)
        }
    }

    /// Rank notes by relevance to search keywords
    private func rankNotesByRelevance(notes: [NotionNote], keywords: [String]) -> [NotionNote] {
        let scoredNotes = notes.map { note -> (note: NotionNote, score: Int) in
            var score = 0
            let titleLower = note.title.lowercased()
            let contentLower = note.content.lowercased()

            for keyword in keywords {
                let keywordLower = keyword.lowercased()
                // Title match is worth more
                if titleLower.contains(keywordLower) {
                    score += 10
                }
                // Content match
                if contentLower.contains(keywordLower) {
                    score += 5
                }
            }

            // Boost recent notes
            let daysSinceEdit = Calendar.current.dateComponents([.day], from: note.lastEdited, to: Date()).day ?? 0
            if daysSinceEdit < 7 {
                score += 3
            } else if daysSinceEdit < 30 {
                score += 1
            }

            return (note, score)
        }

        // Sort by score descending, filter out zero-score notes
        return scoredNotes
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }
            .map { $0.note }
    }

    /// Query tasks database for active/upcoming tasks
    func queryActiveTasks(databaseId: String) async throws -> [NotionTask] {
        let formattedId = formatNotionId(databaseId)
        let urlString = "https://api.notion.com/v1/databases/\(formattedId)/query"
        let url = URL(string: urlString)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Query for incomplete tasks
        let body: [String: Any] = [
            "filter": [
                "or": [
                    [
                        "property": "Status",
                        "status": [
                            "does_not_equal": "Done"
                        ]
                    ],
                    [
                        "property": "Status",
                        "status": [
                            "does_not_equal": "✅ Done"
                        ]
                    ]
                ]
            ],
            "sorts": [
                [
                    "property": "Due Date",
                    "direction": "ascending"
                ]
            ],
            "page_size": 10
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "NotionService", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed to query tasks: \(errorBody)"])
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let results = json?["results"] as? [[String: Any]] ?? []

        return results.compactMap { result -> NotionTask? in
            guard let id = result["id"] as? String,
                  let properties = result["properties"] as? [String: Any] else {
                return nil
            }

            // Extract title
            var title = ""
            if let titleProp = properties["Name"] as? [String: Any] ?? properties["Title"] as? [String: Any],
               let titleArray = titleProp["title"] as? [[String: Any]],
               let firstTitle = titleArray.first,
               let text = firstTitle["plain_text"] as? String {
                title = text
            }

            // Extract status
            var status = "To Do"
            if let statusProp = properties["Status"] as? [String: Any],
               let statusData = statusProp["status"] as? [String: Any],
               let statusName = statusData["name"] as? String {
                status = statusName
            }

            // Extract due date
            var dueDate: Date?
            if let dateProp = properties["Due"] as? [String: Any] ?? properties["Due Date"] as? [String: Any],
               let dateData = dateProp["date"] as? [String: Any],
               let dateString = dateData["start"] as? String {
                let formatter = ISO8601DateFormatter()
                dueDate = formatter.date(from: dateString)
            }

            return NotionTask(id: id, title: title, status: status, dueDate: dueDate)
        }
    }

    // MARK: - Commitments Management

    /// Create a commitment in Notion (now uses unified Tasks database)
    func createCommitment(_ commitment: Commitment, databaseId: String) async throws -> String {
        // Convert Commitment to TaskItem and use unified Tasks database
        let taskItem = TaskItem.fromCommitment(commitment)
        return try await createTask(taskItem)
    }

    /// Legacy create commitment (deprecated - use createCommitment instead)
    func createCommitmentLegacy(_ commitment: Commitment, databaseId: String) async throws -> String {
        let formattedId = formatNotionId(databaseId)
        let url = URL(string: "https://api.notion.com/v1/pages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var properties: [String: Any] = [:]

        // Title
        properties["Title"] = [
            "title": [
                [
                    "text": [
                        "content": commitment.title
                    ]
                ]
            ]
        ]

        // Type
        properties["Type"] = [
            "select": ["name": commitment.type.rawValue]
        ]

        // Status
        properties["Status"] = [
            "status": ["name": commitment.status.rawValue]
        ]

        // Commitment Text
        properties["Commitment Text"] = [
            "rich_text": [
                [
                    "text": [
                        "content": commitment.commitmentText
                    ]
                ]
            ]
        ]

        // Committed By
        properties["Committed By"] = [
            "rich_text": [
                [
                    "text": [
                        "content": commitment.committedBy
                    ]
                ]
            ]
        ]

        // Committed To
        properties["Committed To"] = [
            "rich_text": [
                [
                    "text": [
                        "content": commitment.committedTo
                    ]
                ]
            ]
        ]

        // Source Platform
        properties["Source Platform"] = [
            "select": ["name": commitment.sourcePlatform.rawValue]
        ]

        // Source Thread
        properties["Source Thread"] = [
            "rich_text": [
                [
                    "text": [
                        "content": commitment.sourceThread
                    ]
                ]
            ]
        ]

        // Due Date
        if let dueDate = commitment.dueDate {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            properties["Due Date"] = [
                "date": [
                    "start": formatter.string(from: dueDate)
                ]
            ]
        }

        // Priority
        let priorityName = commitment.priority.rawValue.prefix(1).uppercased() + commitment.priority.rawValue.dropFirst()
        properties["Priority"] = [
            "select": ["name": priorityName]
        ]

        // Original Context
        properties["Original Context"] = [
            "rich_text": [
                [
                    "text": [
                        "content": String(commitment.originalContext.prefix(2000))  // Notion limit
                    ]
                ]
            ]
        ]

        // Follow-up Scheduled
        if let followupDate = commitment.followupScheduled {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate, .withTime, .withTimeZone]
            properties["Follow-up Scheduled"] = [
                "date": [
                    "start": formatter.string(from: followupDate)
                ]
            ]
        }

        // Unique Hash
        properties["Unique Hash"] = [
            "rich_text": [
                [
                    "text": [
                        "content": commitment.uniqueHash
                    ]
                ]
            ]
        ]

        let body: [String: Any] = [
            "parent": ["database_id": formattedId],
            "properties": properties
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "NotionService", code: 12, userInfo: [NSLocalizedDescriptionKey: "Failed to create commitment: \(errorBody)"])
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["id"] as? String ?? "unknown"
    }

    /// Find commitment by unique hash
    func findCommitmentByHash(_ hash: String, databaseId: String) async throws -> String? {
        let formattedId = formatNotionId(databaseId)
        let url = URL(string: "https://api.notion.com/v1/databases/\(formattedId)/query")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "filter": [
                "property": "Unique Hash",
                "rich_text": [
                    "equals": hash
                ]
            ],
            "page_size": 1
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
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

    /// Update commitment status
    func updateCommitmentStatus(notionId: String, status: Commitment.CommitmentStatus) async throws {
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

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "NotionService", code: 13, userInfo: [NSLocalizedDescriptionKey: "Failed to update commitment status: \(errorBody)"])
        }
    }

    /// Query active commitments
    func queryActiveCommitments(databaseId: String, type: Commitment.CommitmentType? = nil) async throws -> [Commitment] {
        let formattedId = formatNotionId(databaseId)
        let url = URL(string: "https://api.notion.com/v1/databases/\(formattedId)/query")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var filters: [[String: Any]] = [
            [
                "property": "Status",
                "status": ["does_not_equal": "Completed"]
            ],
            [
                "property": "Status",
                "status": ["does_not_equal": "Cancelled"]
            ]
        ]

        if let type = type {
            filters.append([
                "property": "Type",
                "select": ["equals": type.rawValue]
            ])
        }

        let body: [String: Any] = [
            "filter": [
                "and": filters
            ],
            "sorts": [
                [
                    "property": "Due Date",
                    "direction": "ascending"
                ]
            ],
            "page_size": 100
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "NotionService", code: 14, userInfo: [NSLocalizedDescriptionKey: "Failed to query commitments: \(errorBody)"])
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let results = json?["results"] as? [[String: Any]] ?? []

        return results.compactMap { parseCommitmentFromNotionPage($0) }
    }

    /// Query overdue commitments
    func queryOverdueCommitments(databaseId: String) async throws -> [Commitment] {
        let formattedId = formatNotionId(databaseId)
        let url = URL(string: "https://api.notion.com/v1/databases/\(formattedId)/query")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let today = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]

        let body: [String: Any] = [
            "filter": [
                "and": [
                    [
                        "property": "Status",
                        "status": ["does_not_equal": "Completed"]
                    ],
                    [
                        "property": "Status",
                        "status": ["does_not_equal": "Cancelled"]
                    ],
                    [
                        "property": "Due Date",
                        "date": ["before": formatter.string(from: today)]
                    ]
                ]
            ],
            "sorts": [
                [
                    "property": "Due Date",
                    "direction": "ascending"
                ]
            ],
            "page_size": 100
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "NotionService", code: 15, userInfo: [NSLocalizedDescriptionKey: "Failed to query overdue commitments: \(errorBody)"])
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let results = json?["results"] as? [[String: Any]] ?? []

        return results.compactMap { parseCommitmentFromNotionPage($0) }
    }

    /// Query commitments due within a specified number of hours
    func queryUpcomingCommitments(databaseId: String, withinHours: Int) async throws -> [Commitment] {
        let formattedId = formatNotionId(databaseId)
        let url = URL(string: "https://api.notion.com/v1/databases/\(formattedId)/query")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let now = Date()
        let deadline = Calendar.current.date(byAdding: .hour, value: withinHours, to: now)!
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]

        let body: [String: Any] = [
            "filter": [
                "and": [
                    [
                        "property": "Status",
                        "status": ["does_not_equal": "Completed"]
                    ],
                    [
                        "property": "Status",
                        "status": ["does_not_equal": "Cancelled"]
                    ],
                    [
                        "property": "Due Date",
                        "date": ["on_or_after": formatter.string(from: now)]
                    ],
                    [
                        "property": "Due Date",
                        "date": ["on_or_before": formatter.string(from: deadline)]
                    ]
                ]
            ],
            "sorts": [
                [
                    "property": "Due Date",
                    "direction": "ascending"
                ]
            ],
            "page_size": 50
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "NotionService", code: 16, userInfo: [NSLocalizedDescriptionKey: "Failed to query upcoming commitments: \(errorBody)"])
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let results = json?["results"] as? [[String: Any]] ?? []

        return results.compactMap { parseCommitmentFromNotionPage($0) }
    }

    /// Parse commitment from Notion page result
    private func parseCommitmentFromNotionPage(_ result: [String: Any]) -> Commitment? {
        guard let id = result["id"] as? String,
              let properties = result["properties"] as? [String: Any] else {
            return nil
        }

        // Extract title
        var title = ""
        if let titleProp = properties["Title"] as? [String: Any],
           let titleArray = titleProp["title"] as? [[String: Any]],
           let firstTitle = titleArray.first,
           let text = firstTitle["plain_text"] as? String {
            title = text
        }

        // Extract type
        var typeString = "I Owe"
        if let typeProp = properties["Type"] as? [String: Any],
           let selectData = typeProp["select"] as? [String: Any],
           let typeName = selectData["name"] as? String {
            typeString = typeName
        }
        guard let type = Commitment.CommitmentType(rawValue: typeString) else { return nil }

        // Extract status
        var statusString = "Open"
        if let statusProp = properties["Status"] as? [String: Any],
           let statusData = statusProp["status"] as? [String: Any],
           let statusName = statusData["name"] as? String {
            statusString = statusName
        }
        guard let status = Commitment.CommitmentStatus(rawValue: statusString) else { return nil }

        // Extract commitment text
        var commitmentText = ""
        if let textProp = properties["Commitment Text"] as? [String: Any],
           let richTextArray = textProp["rich_text"] as? [[String: Any]],
           let firstText = richTextArray.first,
           let plainText = firstText["plain_text"] as? String {
            commitmentText = plainText
        }

        // Extract committed by
        var committedBy = ""
        if let byProp = properties["Committed By"] as? [String: Any],
           let richTextArray = byProp["rich_text"] as? [[String: Any]],
           let firstText = richTextArray.first,
           let plainText = firstText["plain_text"] as? String {
            committedBy = plainText
        }

        // Extract committed to
        var committedTo = ""
        if let toProp = properties["Committed To"] as? [String: Any],
           let richTextArray = toProp["rich_text"] as? [[String: Any]],
           let firstText = richTextArray.first,
           let plainText = firstText["plain_text"] as? String {
            committedTo = plainText
        }

        // Extract source platform
        var platformString = "iMessage"
        if let platformProp = properties["Source Platform"] as? [String: Any],
           let selectData = platformProp["select"] as? [String: Any],
           let platformName = selectData["name"] as? String {
            platformString = platformName
        }
        guard let platform = MessagePlatform(rawValue: platformString.lowercased()) else { return nil }

        // Extract source thread
        var sourceThread = ""
        if let threadProp = properties["Source Thread"] as? [String: Any],
           let richTextArray = threadProp["rich_text"] as? [[String: Any]],
           let firstText = richTextArray.first,
           let plainText = firstText["plain_text"] as? String {
            sourceThread = plainText
        }

        // Extract due date
        var dueDate: Date?
        if let dateProp = properties["Due Date"] as? [String: Any],
           let dateData = dateProp["date"] as? [String: Any],
           let dateString = dateData["start"] as? String {
            let formatter = ISO8601DateFormatter()
            dueDate = formatter.date(from: dateString)
        }

        // Extract priority
        var priorityString = "Medium"
        if let priorityProp = properties["Priority"] as? [String: Any],
           let selectData = priorityProp["select"] as? [String: Any],
           let priorityName = selectData["name"] as? String {
            priorityString = priorityName
        }
        let priority = UrgencyLevel(rawValue: priorityString.lowercased()) ?? .medium

        // Extract original context
        var originalContext = ""
        if let contextProp = properties["Original Context"] as? [String: Any],
           let richTextArray = contextProp["rich_text"] as? [[String: Any]],
           let firstText = richTextArray.first,
           let plainText = firstText["plain_text"] as? String {
            originalContext = plainText
        }

        // Extract follow-up scheduled
        var followupScheduled: Date?
        if let followupProp = properties["Follow-up Scheduled"] as? [String: Any],
           let dateData = followupProp["date"] as? [String: Any],
           let dateString = dateData["start"] as? String {
            let formatter = ISO8601DateFormatter()
            followupScheduled = formatter.date(from: dateString)
        }

        // Extract unique hash
        var uniqueHash = ""
        if let hashProp = properties["Unique Hash"] as? [String: Any],
           let richTextArray = hashProp["rich_text"] as? [[String: Any]],
           let firstText = richTextArray.first,
           let plainText = firstText["plain_text"] as? String {
            uniqueHash = plainText
        }

        // Extract dates
        var createdAt = Date()
        if let createdTime = properties["Created Date"] as? [String: Any],
           let createdString = createdTime["created_time"] as? String {
            let formatter = ISO8601DateFormatter()
            createdAt = formatter.date(from: createdString) ?? Date()
        }

        var lastUpdated = Date()
        if let editedTime = properties["Last Updated"] as? [String: Any],
           let editedString = editedTime["last_edited_time"] as? String {
            let formatter = ISO8601DateFormatter()
            lastUpdated = formatter.date(from: editedString) ?? Date()
        }

        return Commitment(
            id: UUID(),
            type: type,
            status: status,
            title: title,
            commitmentText: commitmentText,
            committedBy: committedBy,
            committedTo: committedTo,
            sourcePlatform: platform,
            sourceThread: sourceThread,
            dueDate: dueDate,
            priority: priority,
            originalContext: originalContext,
            followupScheduled: followupScheduled,
            notionId: id,
            notionTaskId: nil,
            createdAt: createdAt,
            lastUpdated: lastUpdated
        )
    }
}

// MARK: - Models

struct NotionPage {
    let id: String
    let title: String
    let url: String?
}
