import Foundation

/// Syncs "What Alfred Knows About You" to a read-only Notion page
/// One-directional: Alfred → Notion. Updated during daily pattern computation.
/// Pattern follows CoachingNotionSyncService (single page, delete+replace blocks).
class MemoryNotionSyncService {

    static let shared = MemoryNotionSyncService()

    private let notionApiKey: String
    private var userName: String
    private var pageId: String?
    private var lastSyncTimestamp: Date?
    private let cacheFilePath: URL

    // Debounce: once per 10 minutes (less frequent than coaching sync)
    private let syncDebounceInterval: TimeInterval = 600

    init() {
        let homeDir = NSHomeDirectory()
        self.cacheFilePath = URL(fileURLWithPath: "\(homeDir)/.alfred/memory_notion_cache.json")

        if let config = AppConfig.load() {
            self.notionApiKey = config.notion.apiKey
            self.userName = config.user.name.isEmpty ? "User" : config.user.name
        } else {
            self.notionApiKey = ""
            self.userName = "User"
        }

        loadCache()
    }

    // MARK: - Cache

    private struct SyncCache: Codable {
        var pageId: String?
        var lastSyncTimestamp: Date?
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheFilePath),
              let cache = try? JSONDecoder().decode(SyncCache.self, from: data) else {
            return
        }
        pageId = cache.pageId
        lastSyncTimestamp = cache.lastSyncTimestamp
    }

    private func saveCache() {
        let cache = SyncCache(pageId: pageId, lastSyncTimestamp: lastSyncTimestamp)
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: cacheFilePath)
        }
    }

    // MARK: - Setup

    func ensurePageExists(parentPageId: String? = nil) async throws -> String {
        if let cachedId = pageId {
            if try await validatePageExists(cachedId) {
                return cachedId
            }
        }

        var effectiveParentId = parentPageId
        if effectiveParentId == nil {
            effectiveParentId = try await getTasksDatabaseParent()
        }

        guard let parentId = effectiveParentId else {
            throw MemorySyncError.creationFailed("No parent page available. Configure Tasks database first.")
        }

        let newPageId = try await createPage(parentPageId: parentId)
        pageId = newPageId
        saveCache()
        return newPageId
    }

    // MARK: - Sync to Notion

    func syncToNotion(force: Bool = false) async throws {
        if !force, let lastSync = lastSyncTimestamp {
            if Date().timeIntervalSince(lastSync) < syncDebounceInterval {
                print("🧠 Memory Notion: Skipping sync (debounce)")
                return
            }
        }

        guard notionApiKey.count > 5 else {
            print("🧠 Memory Notion: No API key configured")
            return
        }

        let targetPageId: String
        do {
            targetPageId = try await ensurePageExists()
        } catch {
            print("⚠️ Memory Notion: Could not ensure page exists: \(error.localizedDescription)")
            return
        }

        // Build blocks from unified memory
        let blocks = buildMemoryBlocks()

        guard blocks.count > 2 else {
            print("🧠 Memory Notion: No memory to sync")
            return
        }

        try await updatePageContent(pageId: targetPageId, children: blocks)

        lastSyncTimestamp = Date()
        saveCache()
        print("✅ What Alfred Knows synced to Notion (\(blocks.count) blocks)")
    }

    // MARK: - Status

    func getPageId() -> String? { return pageId }
    func getLastSyncTimestamp() -> Date? { return lastSyncTimestamp }

    func getStatus() -> [String: Any] {
        return [
            "pageId": pageId ?? "not created",
            "lastSync": lastSyncTimestamp.map { ISO8601DateFormatter().string(from: $0) } ?? "never",
            "enabled": notionApiKey.count > 5
        ]
    }

    // MARK: - Build Memory Blocks

    private func buildMemoryBlocks() -> [[String: Any]] {
        var blocks: [[String: Any]] = []

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMMM d, yyyy 'at' h:mm a"
        let timestamp = dateFormatter.string(from: Date())

        // Header callout
        blocks.append(createCalloutBlock("🧠", "What Alfred Knows About \(userName)\nRead-only mirror — updated daily during pattern learning.\nLast synced: \(timestamp)"))
        blocks.append(createDividerBlock())

        // Fetch unified memory
        let memoryIndex = UnifiedMemoryIndex.shared
        let allItems = memoryIndex.query(endpoint: "memory_sync", maxItems: 200)

        // Group by type
        let groupOrder: [(String, String)] = [
            ("directInstruction", "Your Explicit Preferences"),
            ("userContext", "What Alfred Knows About You"),
            ("communicationStyle", "Communication Style"),
            ("personalityNote", "Personality Notes"),
            ("coachingTheme", "Coaching Themes"),
            ("followUp", "Open Follow-Ups"),
            ("correctionPattern", "Extraction Patterns"),
            ("agentPattern", "Observed Patterns"),
            ("contactIntelligence", "Contact Intelligence")
        ]

        var grouped: [String: [UnifiedMemoryIndex.MemoryItem]] = [:]
        for item in allItems {
            let key = item.type.rawValue
            grouped[key, default: []].append(item)
        }

        for (typeKey, label) in groupOrder {
            guard let items = grouped[typeKey], !items.isEmpty else { continue }

            blocks.append(createHeading2Block(label))

            // For contact intelligence, limit to active/notable contacts
            if typeKey == "contactIntelligence" {
                let notable = items.filter { $0.confidence >= 0.85 }.prefix(30)
                if notable.isEmpty {
                    blocks.append(createItalicParagraphBlock("No notable contact patterns yet."))
                } else {
                    for item in notable {
                        blocks.append(createBulletBlock(item.content))
                    }
                    if items.count > notable.count {
                        blocks.append(createItalicParagraphBlock("\(items.count - notable.count) more contacts with lower engagement tracked locally."))
                    }
                }
            } else {
                for item in items {
                    let confidence = Int(item.confidence * 100)
                    let staleMarker = item.isStale ? " (stale)" : ""
                    let prefix = confidence < 100 ? "[\(confidence)%] " : ""
                    blocks.append(createBulletBlock("\(prefix)\(item.content)\(staleMarker)"))
                }
            }

            blocks.append(createDividerBlock())
        }

        // Learning stats footer
        let stats = WorkflowLearningService.shared.getLearningV2Stats()
        let events = stats["totalEvents"] as? Int ?? 0
        let active = stats["activePatterns"] as? Int ?? 0
        let direct = stats["directInstructions"] as? Int ?? 0

        blocks.append(createHeading3Block("Learning Stats"))
        blocks.append(createBulletBlock("Total learning events: \(events)"))
        blocks.append(createBulletBlock("Active patterns: \(active)"))
        blocks.append(createBulletBlock("Direct instructions: \(direct)"))

        let contactStats = ContactLearner.shared.getStats()
        blocks.append(createBulletBlock("Tracked threads: \(contactStats.totalThreads) (active: \(contactStats.activeThreads), minimal: \(contactStats.minimalThreads), observe: \(contactStats.observeThreads))"))

        return blocks
    }

    // MARK: - Notion API Helpers

    private func validatePageExists(_ pageId: String) async throws -> Bool {
        let url = URL(string: "https://api.notion.com/v1/pages/\(pageId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(notionApiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")

        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    private func getTasksDatabaseParent() async throws -> String? {
        guard let config = AppConfig.load() else { return nil }

        let tasksDatabaseId = config.notion.tasksDatabaseId ?? config.notion.briefingSources?.tasksDatabaseId
        guard let dbId = tasksDatabaseId, !dbId.isEmpty, dbId != "YOUR_TASKS_DATABASE_ID" else {
            return nil
        }

        let url = URL(string: "https://api.notion.com/v1/databases/\(dbId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(notionApiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return nil
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let parent = json["parent"] as? [String: Any],
              let parentPageId = parent["page_id"] as? String else {
            return nil
        }

        return parentPageId
    }

    private func createPage(parentPageId: String) async throws -> String {
        let url = URL(string: "https://api.notion.com/v1/pages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(notionApiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "parent": ["type": "page_id", "page_id": parentPageId],
            "icon": ["type": "emoji", "emoji": "🧠"],
            "properties": [
                "title": [
                    "title": [
                        ["type": "text", "text": ["content": "What Alfred Knows About \(userName)"]]
                    ]
                ]
            ],
            "children": [
                createCalloutBlock("🧠", "This page is a read-only mirror of Alfred's memory. It syncs daily during pattern learning. Changes here will be overwritten."),
                createDividerBlock()
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw MemorySyncError.creationFailed("Failed to create page: \(errorBody)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newPageId = json["id"] as? String else {
            throw MemorySyncError.creationFailed("Failed to parse page response")
        }

        print("🧠 Created 'What Alfred Knows' page: \(newPageId)")
        return newPageId
    }

    private func getPageBlocks(pageId: String) async throws -> [[String: Any]] {
        var allBlocks: [[String: Any]] = []
        var cursor: String?

        repeat {
            var urlString = "https://api.notion.com/v1/blocks/\(pageId)/children?page_size=100"
            if let c = cursor { urlString += "&start_cursor=\(c)" }

            let url = URL(string: urlString)!
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Bearer \(notionApiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return allBlocks
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else {
                return allBlocks
            }

            allBlocks.append(contentsOf: results)
            cursor = (json["has_more"] as? Bool == true) ? json["next_cursor"] as? String : nil
        } while cursor != nil

        return allBlocks
    }

    private func updatePageContent(pageId: String, children: [[String: Any]]) async throws {
        // Delete existing blocks in parallel
        let existingBlocks = try await getPageBlocks(pageId: pageId)
        let blockIds = existingBlocks.compactMap { $0["id"] as? String }

        await withTaskGroup(of: Void.self) { group in
            for blockId in blockIds {
                group.addTask {
                    try? await self.deleteBlock(blockId: blockId)
                }
            }
        }

        // Add new content in chunks of 100 (Notion API limit)
        let chunkSize = 100
        for i in stride(from: 0, to: children.count, by: chunkSize) {
            let end = min(i + chunkSize, children.count)
            let chunk = Array(children[i..<end])

            let url = URL(string: "https://api.notion.com/v1/blocks/\(pageId)/children")!
            var request = URLRequest(url: url)
            request.httpMethod = "PATCH"
            request.setValue("Bearer \(notionApiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let body: [String: Any] = ["children": chunk]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw MemorySyncError.syncFailed("Failed to update page: \(errorBody)")
            }
        }
    }

    private func deleteBlock(blockId: String) async throws {
        let url = URL(string: "https://api.notion.com/v1/blocks/\(blockId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(notionApiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")

        _ = try await URLSession.shared.data(for: request)
    }

    // MARK: - Block Builders

    private func createHeading2Block(_ text: String) -> [String: Any] {
        return [
            "object": "block",
            "type": "heading_2",
            "heading_2": [
                "rich_text": [["type": "text", "text": ["content": text]]]
            ]
        ]
    }

    private func createHeading3Block(_ text: String) -> [String: Any] {
        return [
            "object": "block",
            "type": "heading_3",
            "heading_3": [
                "rich_text": [["type": "text", "text": ["content": text]]]
            ]
        ]
    }

    private func createParagraphBlock(_ text: String) -> [String: Any] {
        return [
            "object": "block",
            "type": "paragraph",
            "paragraph": [
                "rich_text": [["type": "text", "text": ["content": text]]]
            ]
        ]
    }

    private func createItalicParagraphBlock(_ text: String) -> [String: Any] {
        return [
            "object": "block",
            "type": "paragraph",
            "paragraph": [
                "rich_text": [[
                    "type": "text",
                    "text": ["content": text],
                    "annotations": ["italic": true]
                ]]
            ]
        ]
    }

    private func createBulletBlock(_ text: String) -> [String: Any] {
        return [
            "object": "block",
            "type": "bulleted_list_item",
            "bulleted_list_item": [
                "rich_text": [["type": "text", "text": ["content": text]]]
            ]
        ]
    }

    private func createCalloutBlock(_ emoji: String, _ text: String) -> [String: Any] {
        return [
            "object": "block",
            "type": "callout",
            "callout": [
                "icon": ["type": "emoji", "emoji": emoji],
                "rich_text": [["type": "text", "text": ["content": text]]]
            ]
        ]
    }

    private func createDividerBlock() -> [String: Any] {
        return [
            "object": "block",
            "type": "divider",
            "divider": [String: Any]()
        ]
    }
}

// MARK: - Errors

enum MemorySyncError: Error, LocalizedError {
    case creationFailed(String)
    case syncFailed(String)

    var errorDescription: String? {
        switch self {
        case .creationFailed(let message):
            return "Failed to create memory page: \(message)"
        case .syncFailed(let message):
            return "Failed to sync memory: \(message)"
        }
    }
}
