import Foundation

/// Service for syncing Alfred's learnings to/from a Notion Playbook page
/// Structure: "[User's Name]'s Playbook" with sub-pages for Rules, Patterns, People, Groups
class PlaybookService {

    static let shared = PlaybookService()

    private let notionApiKey: String
    private let memoryService: AgentMemoryService
    private let favoritesService: FavoritesService
    private var userName: String

    // Cache
    private var playbookPageId: String?
    private var subPageIds: [String: String] = [:] // ["rules": "...", "patterns": "...", "people": "...", "groups": "..."]
    private var lastSyncTimestamp: Date?
    private let cacheFilePath: URL

    // Sub-page names
    private let subPages = [
        "rules": "Rules I've Taught Alfred",
        "patterns": "Patterns Alfred Has Observed",
        "people": "People",
        "groups": "Groups"
    ]

    init() {
        let homeDir = NSHomeDirectory()
        self.cacheFilePath = URL(fileURLWithPath: "\(homeDir)/.alfred/playbook_cache.json")

        // Load config
        if let config = AppConfig.load() {
            self.notionApiKey = config.notion.apiKey
            self.userName = config.user.name
            self.playbookPageId = config.notion.playbookPageId
        } else {
            self.notionApiKey = ""
            self.userName = "User"
        }

        self.memoryService = AgentMemoryService.shared
        self.favoritesService = FavoritesService.shared

        // Load cache
        loadCache()
    }

    // MARK: - Cache Management

    private struct PlaybookCache: Codable {
        var playbookPageId: String?
        var subPageIds: [String: String]
        var lastSyncTimestamp: Date?
        var lastLoadFromNotionTimestamp: Date?
    }

    private var lastLoadFromNotionTimestamp: Date?

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheFilePath),
              let cache = try? JSONDecoder().decode(PlaybookCache.self, from: data) else {
            return
        }

        if playbookPageId == nil {
            playbookPageId = cache.playbookPageId
        }
        subPageIds = cache.subPageIds
        lastSyncTimestamp = cache.lastSyncTimestamp
        lastLoadFromNotionTimestamp = cache.lastLoadFromNotionTimestamp
    }

    private func saveCache() {
        let cache = PlaybookCache(
            playbookPageId: playbookPageId,
            subPageIds: subPageIds,
            lastSyncTimestamp: lastSyncTimestamp,
            lastLoadFromNotionTimestamp: lastLoadFromNotionTimestamp
        )

        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: cacheFilePath)
        }
    }

    // MARK: - Playbook Setup

    /// Ensure the Playbook page and sub-pages exist in Notion
    /// Returns the main playbook page ID
    func ensurePlaybookExists(parentPageId: String? = nil) async throws -> String {
        // If we have a cached ID, validate it still exists
        if let cachedId = playbookPageId {
            if try await validatePageExists(cachedId) {
                // Ensure sub-pages exist
                try await ensureSubPagesExist()
                return cachedId
            }
        }

        // Get parent page ID - either provided, or from Tasks database
        var effectiveParentId = parentPageId
        if effectiveParentId == nil {
            effectiveParentId = try await getTasksDatabaseParent()
        }

        guard let parentId = effectiveParentId else {
            throw PlaybookError.creationFailed("No parent page available. Please configure Tasks database first.")
        }

        // Create new playbook
        let pageId = try await createPlaybookPage(parentPageId: parentId)
        playbookPageId = pageId

        // Create sub-pages
        try await createSubPages()

        saveCache()
        return pageId
    }

    /// Get the parent page ID of the Tasks database
    private func getTasksDatabaseParent() async throws -> String? {
        guard let config = AppConfig.load() else { return nil }

        // Try to get tasks database ID
        let tasksDatabaseId = config.notion.tasksDatabaseId ?? config.notion.briefingSources?.tasksDatabaseId

        guard let dbId = tasksDatabaseId, !dbId.isEmpty, dbId != "YOUR_TASKS_DATABASE_ID" else {
            return nil
        }

        // Fetch the database to get its parent
        let url = URL(string: "https://api.notion.com/v1/databases/\(dbId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(notionApiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            print("⚠️ Could not fetch Tasks database to get parent: \(String(data: data, encoding: .utf8) ?? "unknown error")")
            return nil
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let parent = json["parent"] as? [String: Any] else {
            return nil
        }

        // Check for page_id parent
        if let pageId = parent["page_id"] as? String {
            return pageId
        }

        // Check for workspace parent (can't use this)
        if parent["type"] as? String == "workspace" {
            print("⚠️ Tasks database is at workspace root, cannot create Playbook there")
            return nil
        }

        return nil
    }

    private func validatePageExists(_ pageId: String) async throws -> Bool {
        let url = URL(string: "https://api.notion.com/v1/pages/\(pageId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(notionApiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            return false
        }

        return httpResponse.statusCode == 200
    }

    private func createPlaybookPage(parentPageId: String?) async throws -> String {
        let url = URL(string: "https://api.notion.com/v1/pages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(notionApiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let parent: [String: Any]
        if let pageId = parentPageId {
            parent = ["type": "page_id", "page_id": pageId]
        } else {
            parent = ["type": "workspace", "workspace": true]
        }

        let body: [String: Any] = [
            "parent": parent,
            "icon": ["type": "emoji", "emoji": "📖"],
            "properties": [
                "title": [
                    "title": [
                        ["type": "text", "text": ["content": "\(userName)'s Playbook"]]
                    ]
                ]
            ],
            "children": [
                [
                    "object": "block",
                    "type": "callout",
                    "callout": [
                        "icon": ["type": "emoji", "emoji": "🤖"],
                        "rich_text": [
                            ["type": "text", "text": ["content": "This is Alfred's knowledge base about your preferences and working style. Edit anything here and Alfred will pick up the changes."]]
                        ]
                    ]
                ],
                [
                    "object": "block",
                    "type": "divider",
                    "divider": [String: Any]()
                ]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw PlaybookError.creationFailed("Failed to create Playbook page: \(errorBody)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pageId = json["id"] as? String else {
            throw PlaybookError.creationFailed("Failed to parse Playbook page response")
        }

        print("📖 Created Playbook page: \(pageId)")
        return pageId
    }

    private func createSubPages() async throws {
        guard let parentId = playbookPageId else {
            throw PlaybookError.notInitialized
        }

        for (key, title) in subPages {
            let pageId = try await createSubPage(parentId: parentId, title: title, key: key)
            subPageIds[key] = pageId
        }

        saveCache()
    }

    private func ensureSubPagesExist() async throws {
        guard let parentId = playbookPageId else { return }

        for (key, title) in subPages {
            if let existingId = subPageIds[key] {
                if try await validatePageExists(existingId) {
                    continue
                }
            }

            // Create missing sub-page
            let pageId = try await createSubPage(parentId: parentId, title: title, key: key)
            subPageIds[key] = pageId
        }

        saveCache()
    }

    private func createSubPage(parentId: String, title: String, key: String) async throws -> String {
        let url = URL(string: "https://api.notion.com/v1/pages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(notionApiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let icon: String
        switch key {
        case "rules": icon = "📚"
        case "patterns": icon = "💡"
        case "people": icon = "👤"
        case "groups": icon = "👥"
        default: icon = "📄"
        }

        let body: [String: Any] = [
            "parent": ["type": "page_id", "page_id": parentId],
            "icon": ["type": "emoji", "emoji": icon],
            "properties": [
                "title": [
                    "title": [
                        ["type": "text", "text": ["content": title]]
                    ]
                ]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw PlaybookError.creationFailed("Failed to create sub-page '\(title)': \(errorBody)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pageId = json["id"] as? String else {
            throw PlaybookError.creationFailed("Failed to parse sub-page response")
        }

        print("  📄 Created sub-page: \(title)")
        return pageId
    }

    // MARK: - Sync to Notion

    /// Sync all local learnings to Notion
    /// Call this on-demand or daily
    func syncToNotion() async throws {
        print("📖 Syncing Playbook to Notion...")

        // Ensure playbook exists
        _ = try await ensurePlaybookExists()

        // Sync each section
        try await syncRulesToNotion()
        try await syncPatternsToNotion()
        try await syncPeopleToNotion()
        try await syncGroupsToNotion()

        lastSyncTimestamp = Date()
        saveCache()

        print("✅ Playbook sync complete!")
    }

    private func syncRulesToNotion() async throws {
        guard let pageId = subPageIds["rules"] else { return }

        var allRules: [(String, AgentType, Date?)] = [] // (rule, agent, timestamp)

        for agentType in AgentType.allCases {
            let memory = memoryService.getMemory(for: agentType)
            if let rulesSection = memory.sections["User-Taught Rules"] {
                let rules = parseRulesFromSection(rulesSection, agentType: agentType)
                allRules.append(contentsOf: rules)
            }
        }

        // Sort by timestamp (newest first)
        allRules.sort { ($0.2 ?? .distantPast) > ($1.2 ?? .distantPast) }

        // Build content blocks
        var children: [[String: Any]] = []

        if allRules.isEmpty {
            children.append(createParagraphBlock("No rules taught yet. Teach Alfred something by saying \"Remember that...\" or \"Always...\""))
        } else {
            // Group by agent
            let grouped = Dictionary(grouping: allRules, by: { $0.1 })

            for agentType in AgentType.allCases {
                guard let rules = grouped[agentType], !rules.isEmpty else { continue }

                children.append(createHeading3Block(agentType.displayName))

                for (rule, _, timestamp) in rules {
                    let dateStr = timestamp.map { formatDate($0) } ?? ""
                    let bulletText = dateStr.isEmpty ? rule : "\(rule) (\(dateStr))"
                    children.append(createBulletBlock(bulletText))
                }

                children.append(createDividerBlock())
            }
        }

        try await updatePageContent(pageId: pageId, children: children)
    }

    private func syncPatternsToNotion() async throws {
        guard let pageId = subPageIds["patterns"] else { return }

        var allPatterns: [(String, AgentType, String, Date?)] = [] // (pattern, agent, source, timestamp)

        for agentType in AgentType.allCases {
            let memory = memoryService.getMemory(for: agentType)
            if let patternsSection = memory.sections["Learned Patterns"] {
                let patterns = parsePatternsFromSection(patternsSection, agentType: agentType)
                allPatterns.append(contentsOf: patterns)
            }
        }

        // Sort by timestamp (newest first)
        allPatterns.sort { ($0.3 ?? .distantPast) > ($1.3 ?? .distantPast) }

        var children: [[String: Any]] = []

        children.append(createCalloutBlock("💡", "These are patterns I've observed from your behavior. Edit or delete any that aren't accurate."))

        if allPatterns.isEmpty {
            children.append(createParagraphBlock("No patterns observed yet. As you use Alfred, I'll learn your preferences."))
        } else {
            // Group by agent
            let grouped = Dictionary(grouping: allPatterns, by: { $0.1 })

            for agentType in AgentType.allCases {
                guard let patterns = grouped[agentType], !patterns.isEmpty else { continue }

                children.append(createHeading3Block(agentType.displayName))

                for (pattern, _, source, timestamp) in patterns {
                    let meta = [source, timestamp.map { formatDate($0) }].compactMap { $0 }.joined(separator: " · ")
                    let bulletText = meta.isEmpty ? pattern : "\(pattern) [\(meta)]"
                    children.append(createBulletBlock(bulletText))
                }

                children.append(createDividerBlock())
            }
        }

        try await updatePageContent(pageId: pageId, children: children)
    }

    private func syncPeopleToNotion() async throws {
        guard let pageId = subPageIds["people"] else { return }

        // Get favorites
        let favorites = favoritesService.getFavorites()

        // Get contact-specific patterns from memory
        var contactPatterns: [String: [(String, AgentType)]] = [:]

        for agentType in AgentType.allCases {
            let memory = memoryService.getMemory(for: agentType)
            if let contactSection = memory.sections["Contact-Specific Patterns"] {
                let patterns = parseContactPatternsFromSection(contactSection, agentType: agentType)
                for (name, pattern) in patterns {
                    if contactPatterns[name] == nil {
                        contactPatterns[name] = []
                    }
                    contactPatterns[name]?.append((pattern, agentType))
                }
            }
        }

        // Merge favorites with patterns
        var allPeople = Set(favorites.contacts.map { $0.name })
        allPeople.formUnion(contactPatterns.keys)

        var children: [[String: Any]] = []

        children.append(createCalloutBlock("👤", "Priority contacts that Alfred pays special attention to."))

        if allPeople.isEmpty {
            children.append(createParagraphBlock("No priority contacts yet. Add someone to Favorites to prioritize them."))
        } else {
            for name in allPeople.sorted() {
                children.append(createHeading3Block(name))

                // Add favorite info if exists
                if let favorite = favorites.contacts.first(where: { $0.name == name }) {
                    let platforms = favorite.platforms.joined(separator: ", ")
                    if !platforms.isEmpty {
                        children.append(createParagraphBlock("Platforms: \(platforms)"))
                    }
                    if let notes = favorite.notes, !notes.isEmpty {
                        children.append(createParagraphBlock("Notes: \(notes)"))
                    }
                }

                // Add patterns if any
                if let patterns = contactPatterns[name], !patterns.isEmpty {
                    children.append(createParagraphBlock("Patterns:"))
                    for (pattern, _) in patterns {
                        children.append(createBulletBlock(pattern))
                    }
                }

                children.append(createDividerBlock())
            }
        }

        try await updatePageContent(pageId: pageId, children: children)
    }

    private func syncGroupsToNotion() async throws {
        guard let pageId = subPageIds["groups"] else { return }

        // Get favorites
        let favorites = favoritesService.getFavorites()

        var children: [[String: Any]] = []

        children.append(createCalloutBlock("👥", "Priority groups that Alfred monitors for important messages."))

        if favorites.groups.isEmpty {
            children.append(createParagraphBlock("No priority groups yet. Add a group chat to Favorites to prioritize it."))
        } else {
            for group in favorites.groups.sorted(by: { $0.name < $1.name }) {
                children.append(createHeading3Block(group.name))
                children.append(createParagraphBlock("Platform: \(group.platform)"))
                if let notes = group.notes, !notes.isEmpty {
                    children.append(createParagraphBlock("Notes: \(notes)"))
                }
                children.append(createDividerBlock())
            }
        }

        try await updatePageContent(pageId: pageId, children: children)
    }

    // MARK: - Load from Notion

    /// Load learnings from Notion and merge with local memory
    /// Call this on app launch (with rate limiting)
    func loadFromNotion(force: Bool = false) async throws {
        // Rate limit: only load once per hour unless forced
        if !force, let lastLoad = lastLoadFromNotionTimestamp {
            let hourAgo = Date().addingTimeInterval(-3600)
            if lastLoad > hourAgo {
                print("📖 Playbook: Skipping load (loaded \(Int(-lastLoad.timeIntervalSinceNow / 60)) minutes ago)")
                return
            }
        }

        guard playbookPageId != nil else {
            print("📖 Playbook: No playbook configured, skipping load")
            return
        }

        print("📖 Loading Playbook from Notion...")

        // Load rules and update local memory
        if let rulesPageId = subPageIds["rules"] {
            try await loadRulesFromNotion(pageId: rulesPageId)
        }

        // For patterns, we don't overwrite - Notion is just for visibility
        // Local patterns are the source of truth (from actual behavior)

        // For people/groups, sync favorites
        if let peoplePageId = subPageIds["people"] {
            try await loadPeopleFromNotion(pageId: peoplePageId)
        }

        lastLoadFromNotionTimestamp = Date()
        saveCache()

        print("✅ Playbook load complete!")
    }

    private func loadRulesFromNotion(pageId: String) async throws {
        let blocks = try await getPageBlocks(pageId: pageId)

        var currentAgent: AgentType?
        var rulesFromNotion: [(String, AgentType)] = []

        for block in blocks {
            guard let type = block["type"] as? String else { continue }

            if type == "heading_3" {
                // Parse agent type from heading
                if let heading3 = block["heading_3"] as? [String: Any],
                   let richText = heading3["rich_text"] as? [[String: Any]],
                   let firstText = richText.first,
                   let textContent = firstText["plain_text"] as? String {
                    currentAgent = AgentType.allCases.first { $0.displayName.lowercased() == textContent.lowercased() }
                }
            } else if type == "bulleted_list_item", let agent = currentAgent {
                if let bulletItem = block["bulleted_list_item"] as? [String: Any],
                   let richText = bulletItem["rich_text"] as? [[String: Any]],
                   let firstText = richText.first,
                   let textContent = firstText["plain_text"] as? String {
                    // Clean up the rule (remove date suffix if present)
                    let rule = textContent.replacingOccurrences(of: #"\s*\([^)]+\)$"#, with: "", options: .regularExpression)
                    rulesFromNotion.append((rule, agent))
                }
            }
        }

        // Compare with local and add any new rules from Notion
        for (rule, agentType) in rulesFromNotion {
            let memory = memoryService.getMemory(for: agentType)
            let existingRules = memory.sections["User-Taught Rules"] ?? ""

            // Only add if not already present
            if !existingRules.contains(rule) {
                try? memoryService.teach(agentType: agentType, rule: rule, category: "From Notion")
                print("  ➕ Added rule from Notion: \(rule)")
            }
        }
    }

    private func loadPeopleFromNotion(pageId: String) async throws {
        // For now, just log - full two-way sync for favorites would need more work
        // The primary flow is Alfred → Notion, not Notion → Alfred for contacts
        print("  ℹ️ People sync: Notion → Alfred not yet implemented (use app to manage favorites)")
    }

    // MARK: - Notion API Helpers

    private func getPageBlocks(pageId: String) async throws -> [[String: Any]] {
        let url = URL(string: "https://api.notion.com/v1/blocks/\(pageId)/children?page_size=100")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(notionApiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return []
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            return []
        }

        return results
    }

    private func updatePageContent(pageId: String, children: [[String: Any]]) async throws {
        // First, delete existing content
        let existingBlocks = try await getPageBlocks(pageId: pageId)
        for block in existingBlocks {
            if let blockId = block["id"] as? String {
                try await deleteBlock(blockId: blockId)
            }
        }

        // Then add new content
        let url = URL(string: "https://api.notion.com/v1/blocks/\(pageId)/children")!
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(notionApiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["children": children]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw PlaybookError.syncFailed("Failed to update page content: \(errorBody)")
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

    // MARK: - Parsing Helpers

    private func parseRulesFromSection(_ section: String, agentType: AgentType) -> [(String, AgentType, Date?)] {
        var rules: [(String, AgentType, Date?)] = []
        let lines = section.components(separatedBy: "\n").filter { $0.starts(with: "- ") }
        let dateFormatter = ISO8601DateFormatter()

        for line in lines {
            // Parse format: "- [timestamp] rule text" or "- rule text"
            var ruleText = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            var timestamp: Date?

            if ruleText.starts(with: "[") {
                if let endIndex = ruleText.range(of: "]")?.upperBound {
                    let timestampStr = String(ruleText[ruleText.index(after: ruleText.startIndex)..<ruleText.index(before: endIndex)])
                    timestamp = dateFormatter.date(from: timestampStr)
                    ruleText = String(ruleText[endIndex...]).trimmingCharacters(in: .whitespaces)
                }
            }

            if !ruleText.isEmpty {
                rules.append((ruleText, agentType, timestamp))
            }
        }

        return rules
    }

    private func parsePatternsFromSection(_ section: String, agentType: AgentType) -> [(String, AgentType, String, Date?)] {
        var patterns: [(String, AgentType, String, Date?)] = []
        let lines = section.components(separatedBy: "\n").filter { $0.starts(with: "- ") }
        let dateFormatter = ISO8601DateFormatter()

        for line in lines {
            // Parse format: "- [timestamp] [source] pattern text"
            var text = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            var timestamp: Date?
            var source = "observed"

            // Parse timestamp
            if text.starts(with: "[") {
                if let endIndex = text.range(of: "]")?.upperBound {
                    let timestampStr = String(text[text.index(after: text.startIndex)..<text.index(before: endIndex)])
                    timestamp = dateFormatter.date(from: timestampStr)
                    text = String(text[endIndex...]).trimmingCharacters(in: .whitespaces)
                }
            }

            // Parse source
            if text.starts(with: "[") {
                if let endIndex = text.range(of: "]")?.upperBound {
                    source = String(text[text.index(after: text.startIndex)..<text.index(before: endIndex)])
                    text = String(text[endIndex...]).trimmingCharacters(in: .whitespaces)
                }
            }

            if !text.isEmpty {
                patterns.append((text, agentType, source, timestamp))
            }
        }

        return patterns
    }

    private func parseContactPatternsFromSection(_ section: String, agentType: AgentType) -> [(String, String)] {
        var contactPatterns: [(String, String)] = [] // (contactName, pattern)
        let lines = section.components(separatedBy: "\n")
        var currentContact: String?

        for line in lines {
            if line.starts(with: "### ") {
                currentContact = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            } else if line.starts(with: "- "), let contact = currentContact {
                let pattern = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                // Clean timestamp if present
                let cleanPattern = pattern.replacingOccurrences(of: #"^\[[^\]]+\]\s*"#, with: "", options: .regularExpression)
                if !cleanPattern.isEmpty {
                    contactPatterns.append((contact, cleanPattern))
                }
            }
        }

        return contactPatterns
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    // MARK: - Public Getters

    func getPlaybookPageId() -> String? {
        return playbookPageId
    }

    func getLastSyncTimestamp() -> Date? {
        return lastSyncTimestamp
    }

    func setPlaybookPageId(_ id: String) {
        playbookPageId = id
        saveCache()
    }
}

// MARK: - Errors

enum PlaybookError: Error, LocalizedError {
    case notInitialized
    case creationFailed(String)
    case syncFailed(String)
    case loadFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "Playbook not initialized. Call ensurePlaybookExists first."
        case .creationFailed(let message):
            return "Failed to create Playbook: \(message)"
        case .syncFailed(let message):
            return "Failed to sync Playbook: \(message)"
        case .loadFailed(let message):
            return "Failed to load Playbook: \(message)"
        }
    }
}
