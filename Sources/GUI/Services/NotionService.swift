import Foundation

class NotionService {
    private let apiKey: String
    private let databaseId: String

    init(config: NotionConfig) {
        self.apiKey = config.apiKey
        self.databaseId = config.databaseId
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
        request.setValue("2025-09-03", forHTTPHeaderField: "Notion-Version")
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
        request.setValue("2025-09-03", forHTTPHeaderField: "Notion-Version")
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

        // Use hardcoded "Due" property for due date
        // If no due date provided, default to tomorrow
        let dueDateToUse = dueDate ?? Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        properties["Due"] = [
            "date": [
                "start": formatter.string(from: dueDateToUse)
            ]
        ]
        print("✓ Writing to 'Due': '\(formatter.string(from: dueDateToUse))'" )

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
        request.setValue("2025-09-03", forHTTPHeaderField: "Notion-Version")
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
        request.setValue("2025-09-03", forHTTPHeaderField: "Notion-Version")

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
        request.setValue("2025-09-03", forHTTPHeaderField: "Notion-Version")
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
}

// MARK: - Models

struct NotionPage {
    let id: String
    let title: String
    let url: String?
}
