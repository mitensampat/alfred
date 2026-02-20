import Foundation

/// Service for syncing coaching_context.md to/from a Notion page
/// Pattern: Mirrors PlaybookService but simpler — single page, not sub-pages
class CoachingNotionSyncService {

    static let shared = CoachingNotionSyncService()

    private let notionApiKey: String
    private var userName: String
    private var pageId: String?
    private var lastSyncTimestamp: Date?
    private var lastLoadFromNotionTimestamp: Date?
    private let cacheFilePath: URL

    // Debounce: don't sync to Notion more than once every 5 minutes
    private let syncDebounceInterval: TimeInterval = 300

    init() {
        let homeDir = NSHomeDirectory()
        self.cacheFilePath = URL(fileURLWithPath: "\(homeDir)/.alfred/coaching_notion_cache.json")

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
        var lastLoadFromNotionTimestamp: Date?
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheFilePath),
              let cache = try? JSONDecoder().decode(SyncCache.self, from: data) else {
            return
        }

        pageId = cache.pageId
        lastSyncTimestamp = cache.lastSyncTimestamp
        lastLoadFromNotionTimestamp = cache.lastLoadFromNotionTimestamp
    }

    private func saveCache() {
        let cache = SyncCache(
            pageId: pageId,
            lastSyncTimestamp: lastSyncTimestamp,
            lastLoadFromNotionTimestamp: lastLoadFromNotionTimestamp
        )
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: cacheFilePath)
        }
    }

    // MARK: - Setup

    /// Ensure the coaching context page exists in Notion
    func ensurePageExists(parentPageId: String? = nil) async throws -> String {
        // If we have a cached ID, validate it
        if let cachedId = pageId {
            if try await validatePageExists(cachedId) {
                return cachedId
            }
        }

        // Get parent — same as Playbook (Tasks database parent)
        var effectiveParentId = parentPageId
        if effectiveParentId == nil {
            effectiveParentId = try await getTasksDatabaseParent()
        }

        guard let parentId = effectiveParentId else {
            throw CoachingSyncError.creationFailed("No parent page available. Configure Tasks database first.")
        }

        // Create the page
        let newPageId = try await createPage(parentPageId: parentId)
        pageId = newPageId
        saveCache()
        return newPageId
    }

    // MARK: - Sync to Notion (Write)

    /// Sync local coaching_context.md → Notion page
    func syncToNotion(force: Bool = false) async throws {
        // Debounce: skip if synced recently (unless forced)
        if !force, let lastSync = lastSyncTimestamp {
            if Date().timeIntervalSince(lastSync) < syncDebounceInterval {
                print("🧠 Coaching Notion: Skipping sync (debounce)")
                return
            }
        }

        guard notionApiKey.count > 5 else {
            print("🧠 Coaching Notion: No API key configured")
            return
        }

        // Ensure page exists (auto-create if needed)
        let targetPageId: String
        do {
            targetPageId = try await ensurePageExists()
        } catch {
            print("⚠️ Coaching Notion: Could not ensure page exists: \(error.localizedDescription)")
            return
        }

        // Read local context
        let context = CoachingMemoryService.shared.getCoachingContext()
        guard !context.isEmpty else {
            print("🧠 Coaching Notion: No coaching context to sync")
            return
        }

        // Convert to Notion blocks
        let blocks = markdownToBlocks(context)

        // Update page content
        try await updatePageContent(pageId: targetPageId, children: blocks)

        lastSyncTimestamp = Date()
        saveCache()
        print("✅ Coaching context synced to Notion")
    }

    // MARK: - Load from Notion (Read)

    /// Load coaching context from Notion → local file
    func loadFromNotion(force: Bool = false) async throws {
        // Rate limit: once per hour unless forced
        if !force, let lastLoad = lastLoadFromNotionTimestamp {
            if Date().timeIntervalSince(lastLoad) < 3600 {
                print("🧠 Coaching Notion: Skipping load (rate limited)")
                return
            }
        }

        guard let targetPageId = pageId else {
            print("🧠 Coaching Notion: No page configured, skipping load")
            return
        }

        guard notionApiKey.count > 5 else { return }

        // Validate page still exists
        guard try await validatePageExists(targetPageId) else {
            print("⚠️ Coaching Notion: Page no longer exists, clearing cache")
            pageId = nil
            saveCache()
            return
        }

        print("🧠 Loading coaching context from Notion...")

        // Fetch blocks
        let blocks = try await getPageBlocks(pageId: targetPageId)

        // Convert to markdown
        let markdown = blocksToMarkdown(blocks)

        guard !markdown.isEmpty else {
            print("🧠 Coaching Notion: Empty content from Notion, skipping")
            return
        }

        // Build full file content with header
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let fullContent = "# Coach Alfred Context\n\n_Last updated: \(timestamp)_\n\n\(markdown)\n"

        // Write to local file
        let homeDir = NSHomeDirectory()
        let filePath = "\(homeDir)/.alfred/coaching_context.md"
        try fullContent.write(toFile: filePath, atomically: true, encoding: .utf8)

        lastLoadFromNotionTimestamp = Date()
        saveCache()
        print("✅ Coaching context loaded from Notion")
    }

    // MARK: - Status

    func getPageId() -> String? { return pageId }
    func getLastSyncTimestamp() -> Date? { return lastSyncTimestamp }

    func getStatus() -> [String: Any] {
        var status: [String: Any] = [
            "configured": pageId != nil
        ]

        if let id = pageId {
            status["pageId"] = id
            status["notionUrl"] = "https://notion.so/\(id.replacingOccurrences(of: "-", with: ""))"
        }

        if let sync = lastSyncTimestamp {
            status["lastSync"] = ISO8601DateFormatter().string(from: sync)
        }

        if let load = lastLoadFromNotionTimestamp {
            status["lastLoad"] = ISO8601DateFormatter().string(from: load)
        }

        return status
    }

    // MARK: - Markdown → Notion Blocks

    private func markdownToBlocks(_ markdown: String) -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        let lines = markdown.components(separatedBy: "\n")

        // Add intro callout
        blocks.append(createCalloutBlock("🧠", "This is Coach Alfred's memory. Edit anything here — Alfred will pick up changes on next load."))
        blocks.append(createDividerBlock())

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip the top-level title and timestamp (we handle those separately)
            if trimmed.starts(with: "# Coach Alfred") { continue }
            if trimmed.starts(with: "_Last updated:") { continue }
            if trimmed.isEmpty { continue }

            // ## Section headers
            if trimmed.starts(with: "## ") {
                let headerText = String(trimmed.dropFirst(3))
                blocks.append(createHeading2Block(headerText))
            }
            // ### Sub-headers
            else if trimmed.starts(with: "### ") {
                let subHeaderText = String(trimmed.dropFirst(4))
                blocks.append(createHeading3Block(subHeaderText))
            }
            // - [ ] Unchecked todo
            else if trimmed.starts(with: "- [ ] ") {
                let todoText = String(trimmed.dropFirst(6))
                blocks.append(createTodoBlock(todoText, checked: false))
            }
            // - [x] Checked todo
            else if trimmed.starts(with: "- [x] ") {
                let todoText = String(trimmed.dropFirst(6))
                blocks.append(createTodoBlock(todoText, checked: true))
            }
            // - Bullet items
            else if trimmed.starts(with: "- ") {
                let bulletText = String(trimmed.dropFirst(2))
                blocks.append(createBulletBlock(bulletText))
            }
            // _Italic placeholder text_
            else if trimmed.starts(with: "_") && trimmed.hasSuffix("_") {
                let italicText = String(trimmed.dropFirst().dropLast())
                blocks.append(createItalicParagraphBlock(italicText))
            }
            // Regular text
            else {
                blocks.append(createParagraphBlock(trimmed))
            }
        }

        return blocks
    }

    // MARK: - Notion Blocks → Markdown

    private func blocksToMarkdown(_ blocks: [[String: Any]]) -> String {
        var lines: [String] = []

        for block in blocks {
            guard let type = block["type"] as? String else { continue }

            switch type {
            case "heading_2":
                if let text = extractPlainText(from: block, key: "heading_2") {
                    lines.append("## \(text)")
                    lines.append("")
                }

            case "heading_3":
                if let text = extractPlainText(from: block, key: "heading_3") {
                    lines.append("### \(text)")
                    lines.append("")
                }

            case "bulleted_list_item":
                if let text = extractPlainText(from: block, key: "bulleted_list_item") {
                    lines.append("- \(text)")
                }

            case "to_do":
                if let todoBlock = block["to_do"] as? [String: Any],
                   let richText = todoBlock["rich_text"] as? [[String: Any]],
                   let firstText = richText.first,
                   let text = firstText["plain_text"] as? String {
                    let checked = todoBlock["checked"] as? Bool ?? false
                    lines.append("- [\(checked ? "x" : " ")] \(text)")
                }

            case "paragraph":
                if let text = extractPlainText(from: block, key: "paragraph") {
                    if text.isEmpty {
                        lines.append("")
                    } else {
                        // Check if it was italic (annotations)
                        if let paragraphBlock = block["paragraph"] as? [String: Any],
                           let richText = paragraphBlock["rich_text"] as? [[String: Any]],
                           let first = richText.first,
                           let annotations = first["annotations"] as? [String: Any],
                           annotations["italic"] as? Bool == true {
                            lines.append("_\(text)_")
                        } else {
                            lines.append(text)
                        }
                    }
                }

            case "callout", "divider":
                // Skip callout (intro block) and dividers
                continue

            default:
                continue
            }
        }

        return lines.joined(separator: "\n")
    }

    private func extractPlainText(from block: [String: Any], key: String) -> String? {
        guard let blockContent = block[key] as? [String: Any],
              let richText = blockContent["rich_text"] as? [[String: Any]] else {
            return nil
        }

        // Concatenate all rich text segments
        return richText.compactMap { $0["plain_text"] as? String }.joined()
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
                        ["type": "text", "text": ["content": "Coach Alfred Context"]]
                    ]
                ]
            ],
            "children": [
                createCalloutBlock("🧠", "This is Coach Alfred's memory. Edit anything here — Alfred will pick up changes on next load."),
                createDividerBlock()
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw CoachingSyncError.creationFailed("Failed to create page: \(errorBody)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newPageId = json["id"] as? String else {
            throw CoachingSyncError.creationFailed("Failed to parse page response")
        }

        print("🧠 Created Coach Alfred Context page: \(newPageId)")
        return newPageId
    }

    private func getPageBlocks(pageId: String) async throws -> [[String: Any]] {
        var allBlocks: [[String: Any]] = []
        var cursor: String?

        repeat {
            var urlString = "https://api.notion.com/v1/blocks/\(pageId)/children?page_size=100"
            if let c = cursor {
                urlString += "&start_cursor=\(c)"
            }

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

        // Add new content (Notion API limit: 100 blocks per request)
        // Coaching context should be well under 100 blocks, but chunk just in case
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
                throw CoachingSyncError.syncFailed("Failed to update page: \(errorBody)")
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

    private func createTodoBlock(_ text: String, checked: Bool) -> [String: Any] {
        return [
            "object": "block",
            "type": "to_do",
            "to_do": [
                "rich_text": [["type": "text", "text": ["content": text]]],
                "checked": checked
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

enum CoachingSyncError: Error, LocalizedError {
    case creationFailed(String)
    case syncFailed(String)
    case loadFailed(String)

    var errorDescription: String? {
        switch self {
        case .creationFailed(let message):
            return "Failed to create coaching context page: \(message)"
        case .syncFailed(let message):
            return "Failed to sync coaching context: \(message)"
        case .loadFailed(let message):
            return "Failed to load coaching context: \(message)"
        }
    }
}
