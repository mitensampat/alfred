import Foundation

/// UnifiedMemoryIndex — Read-through aggregation layer across all memory sources
/// Provides relevance-ranked memory retrieval for prompt injection.
///
/// Sources indexed:
/// 1. WorkflowLearningService (learned_patterns in workflow_learning.db)
/// 2. AgentMemoryService (per-agent taught rules + observed patterns)
/// 3. CoachingMemoryService (coaching_context.md — themes, sessions, follow-ups)
/// 4. ContactLearner (contacts.json — thread classification, extraction stats)
/// 5. CorrectionTracker (corrections.json — extraction false positives/edits)
class UnifiedMemoryIndex {
    static let shared = UnifiedMemoryIndex()

    // MARK: - Memory Item

    struct MemoryItem {
        let id: String
        let source: Source
        let type: ItemType
        let content: String
        let confidence: Double       // 0.0–1.0
        let tags: Set<String>        // Contact names, topics for relevance matching
        let createdAt: Date?
        let isStale: Bool

        enum Source: String {
            case workflow       // learned_patterns from WorkflowLearningService
            case agent          // AgentMemoryService rules/patterns
            case coaching       // CoachingMemoryService themes/personality
            case contact        // ContactLearner thread data
            case correction     // CorrectionTracker extraction feedback
        }

        enum ItemType: String {
            case directInstruction   // "always X", "never Y" — highest priority
            case userContext         // biographical facts
            case communicationStyle  // inferred tone/format preferences
            case coachingTheme       // active coaching topics
            case contactIntelligence // thread engagement, extraction accuracy
            case correctionPattern   // extraction false positive patterns
            case followUp            // open coaching follow-ups
            case personalityNote     // how to interact with user
            case agentRule           // user-taught agent rules
            case agentPattern        // agent-observed patterns
        }
    }

    // MARK: - Relevance-Ranked Query

    /// Query all memory sources and return the most relevant items for this context
    func query(
        endpoint: String,
        topic: String? = nil,
        mentionedContact: String? = nil,
        maxItems: Int = 25
    ) -> [MemoryItem] {
        var allItems: [MemoryItem] = []

        // Gather from all sources
        allItems.append(contentsOf: getWorkflowPatterns())
        allItems.append(contentsOf: getAgentMemory())
        allItems.append(contentsOf: getCoachingMemory())
        allItems.append(contentsOf: getContactIntelligence())
        allItems.append(contentsOf: getCorrectionPatterns())

        // Score and rank
        let scored = allItems.map { item -> (MemoryItem, Double) in
            let score = relevanceScore(
                item: item,
                endpoint: endpoint,
                topic: topic,
                mentionedContact: mentionedContact
            )
            return (item, score)
        }

        return scored
            .filter { $0.1 > 0.0 }
            .sorted { $0.1 > $1.1 }
            .prefix(maxItems)
            .map { $0.0 }
    }

    /// Format queried items into a prompt-ready string within a token budget
    func getFormattedContext(
        endpoint: String,
        topic: String? = nil,
        mentionedContact: String? = nil,
        maxChars: Int = 3200  // ~800 tokens
    ) -> String {
        let items = query(
            endpoint: endpoint,
            topic: topic,
            mentionedContact: mentionedContact
        )

        guard !items.isEmpty else { return "" }

        var sections: [String: [String]] = [:]
        for item in items {
            let sectionName = sectionHeader(for: item.type)
            sections[sectionName, default: []].append(formatItem(item))
        }

        // Build output in priority order
        let sectionOrder = [
            "Your Explicit Preferences",
            "What Alfred Knows About You",
            "Communication Style",
            "Active Coaching Themes",
            "Contact Intelligence",
            "Extraction Patterns",
            "Open Follow-ups",
            "Agent Memory"
        ]

        var output = "## What Alfred Has Learned About You\n\n"
        var charCount = output.count

        for section in sectionOrder {
            guard let items = sections[section], !items.isEmpty else { continue }
            let header = "### \(section)\n"
            let body = items.joined(separator: "\n")
            let sectionText = header + body + "\n\n"

            if charCount + sectionText.count > maxChars { break }
            output += sectionText
            charCount += sectionText.count
        }

        // Touch last_reinforced for patterns that were used
        reinforceUsedPatterns(items: items)

        return output
    }

    // MARK: - Source Aggregation

    private func getWorkflowPatterns() -> [MemoryItem] {
        let patterns = WorkflowLearningService.shared.getLearnedPatterns()
        return patterns.compactMap { p in
            guard !p.isArchived else { return nil }
            let type: MemoryItem.ItemType = {
                switch p.type {
                case "explicit_preference": return .directInstruction
                case "user_context": return .userContext
                case "communication_style": return .communicationStyle
                case "contact_intelligence": return .contactIntelligence
                default: return .communicationStyle
                }
            }()

            // Extract contact names and topic keywords as tags
            var tags = Set<String>()
            let words = p.description.lowercased().split(separator: " ")
            for word in words where word.count > 3 {
                tags.insert(String(word))
            }

            return MemoryItem(
                id: p.id,
                source: .workflow,
                type: type,
                content: p.description,
                confidence: p.confidence,
                tags: tags,
                createdAt: ISO8601DateFormatter().date(from: p.lastReinforced),
                isStale: p.isStale
            )
        }
    }

    private func getAgentMemory() -> [MemoryItem] {
        var items: [MemoryItem] = []
        let agentTypes: [(String, String)] = [
            ("communication", "communication"),
            ("task", "task"),
            ("calendar", "calendar"),
            ("followup", "followup")
        ]

        for (typeName, _) in agentTypes {
            let memory = AgentMemoryService.shared.getMemory(for: agentTypeFromString(typeName))
            for (section, content) in memory.sections {
                let lines = content.split(separator: "\n").map(String.init)
                for (i, line) in lines.enumerated() {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.count > 5, trimmed.hasPrefix("-") || trimmed.hasPrefix("•") else { continue }
                    let cleanLine = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                    let isRule = section.lowercased().contains("taught") || section.lowercased().contains("rule")

                    items.append(MemoryItem(
                        id: "agent_\(typeName)_\(i)",
                        source: .agent,
                        type: isRule ? .agentRule : .agentPattern,
                        content: cleanLine,
                        confidence: isRule ? 0.9 : 0.7,
                        tags: Set(cleanLine.lowercased().split(separator: " ").filter { $0.count > 3 }.map(String.init)),
                        createdAt: nil,
                        isStale: false
                    ))
                }
            }
        }
        return items
    }

    private func getCoachingMemory() -> [MemoryItem] {
        var items: [MemoryItem] = []

        // Follow-ups
        let followups = CoachingMemoryService.shared.getOpenFollowups()
        for (i, fu) in followups.enumerated() {
            items.append(MemoryItem(
                id: "coaching_followup_\(i)",
                source: .coaching,
                type: .followUp,
                content: fu,
                confidence: 0.85,
                tags: Set(fu.lowercased().split(separator: " ").filter { $0.count > 3 }.map(String.init)),
                createdAt: nil,
                isStale: false
            ))
        }

        // Extract themes and personality notes from coaching context
        let context = CoachingMemoryService.shared.getCoachingContext()
        let sections = parseCoachingContextSections(context)

        if let themes = sections["Coaching Themes"] {
            let lines = themes.split(separator: "\n").map(String.init)
            for (i, line) in lines.enumerated() where line.trimmingCharacters(in: .whitespaces).hasPrefix("-") {
                let clean = String(line.trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces)
                if !clean.isEmpty {
                    items.append(MemoryItem(
                        id: "coaching_theme_\(i)",
                        source: .coaching,
                        type: .coachingTheme,
                        content: clean,
                        confidence: 0.8,
                        tags: Set(clean.lowercased().split(separator: " ").filter { $0.count > 3 }.map(String.init)),
                        createdAt: nil,
                        isStale: false
                    ))
                }
            }
        }

        if let personality = sections["Personality Notes"] {
            let lines = personality.split(separator: "\n").map(String.init)
            for (i, line) in lines.enumerated() where line.trimmingCharacters(in: .whitespaces).hasPrefix("-") {
                let clean = String(line.trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces)
                if !clean.isEmpty {
                    items.append(MemoryItem(
                        id: "coaching_personality_\(i)",
                        source: .coaching,
                        type: .personalityNote,
                        content: clean,
                        confidence: 0.75,
                        tags: Set(clean.lowercased().split(separator: " ").filter { $0.count > 3 }.map(String.init)),
                        createdAt: nil,
                        isStale: false
                    ))
                }
            }
        }

        return items
    }

    private func getContactIntelligence() -> [MemoryItem] {
        var items: [MemoryItem] = []
        let allThreads = ContactLearner.shared.getAllThreads()

        for thread in allThreads {
            // Only include threads with meaningful data
            guard thread.participationHistory.count >= 3 else { continue }

            let engagement = thread.avgParticipation > 0.3 ? "active engagement" : "low engagement"
            let extractionQuality: String
            if thread.extractionStats.itemsExtracted > 5 {
                let rate = Int((1.0 - thread.extractionStats.rejectionRate) * 100)
                extractionQuality = ", \(rate)% extraction accuracy"
            } else {
                extractionQuality = ""
            }

            let summary = "\(thread.threadName) (\(thread.platform)\(thread.isGroup ? " group" : "")): \(engagement)\(extractionQuality)"

            var tags: Set<String> = [thread.threadName.lowercased()]
            // Add individual words from thread name as tags
            for word in thread.threadName.lowercased().split(separator: " ") where word.count > 2 {
                tags.insert(String(word))
            }

            items.append(MemoryItem(
                id: "contact_\(thread.platform)_\(thread.threadId.prefix(8))",
                source: .contact,
                type: .contactIntelligence,
                content: summary,
                confidence: min(0.9, 0.5 + Double(thread.participationHistory.count) * 0.02),
                tags: tags,
                createdAt: ISO8601DateFormatter().date(from: thread.lastSeen),
                isStale: false
            ))
        }
        return items
    }

    private func getCorrectionPatterns() -> [MemoryItem] {
        let corrections = CorrectionTracker.shared.getCorrections(forType: nil)
        guard corrections.count >= 3 else { return [] }

        // Group corrections by item type and summarize
        var byType: [String: Int] = [:]
        for correction in corrections {
            byType[correction.itemType, default: 0] += 1
        }

        var items: [MemoryItem] = []
        for (itemType, count) in byType where count >= 2 {
            let falsePositiveCount = corrections.filter { $0.itemType == itemType && $0.type == .falsePositive }.count
            let editCount = corrections.filter { $0.itemType == itemType && $0.type == .edited }.count

            var summary = "\(itemType) extractions: "
            if falsePositiveCount > 0 { summary += "\(falsePositiveCount) false positives" }
            if editCount > 0 { summary += (falsePositiveCount > 0 ? ", " : "") + "\(editCount) title edits" }
            summary += " — be more conservative"

            items.append(MemoryItem(
                id: "correction_\(itemType.lowercased())",
                source: .correction,
                type: .correctionPattern,
                content: summary,
                confidence: 0.8,
                tags: Set([itemType.lowercased(), "extraction", "accuracy"]),
                createdAt: nil,
                isStale: false
            ))
        }
        return items
    }

    // MARK: - Relevance Scoring

    private func relevanceScore(
        item: MemoryItem,
        endpoint: String,
        topic: String?,
        mentionedContact: String?
    ) -> Double {
        var score = 0.0

        // Base score by type priority
        switch item.type {
        case .directInstruction: score += 1.0   // Always highest
        case .userContext:       score += 0.9
        case .agentRule:        score += 0.85
        case .followUp:         score += 0.8
        case .communicationStyle: score += 0.7
        case .coachingTheme:    score += 0.65
        case .personalityNote:  score += 0.6
        case .contactIntelligence: score += 0.5
        case .correctionPattern: score += 0.45
        case .agentPattern:     score += 0.4
        }

        // Confidence multiplier
        score *= item.confidence

        // Staleness penalty
        if item.isStale { score *= 0.6 }

        // Topic relevance boost
        if let topic = topic?.lowercased() {
            let topicWords = Set(topic.split(separator: " ").map(String.init))
            let overlap = item.tags.intersection(topicWords).count
            if overlap > 0 {
                score += Double(overlap) * 0.15
            }
        }

        // Contact mention boost
        if let contact = mentionedContact?.lowercased() {
            if item.tags.contains(contact) || item.content.lowercased().contains(contact) {
                score += 0.3
            }
        }

        // Endpoint-specific boosts
        switch endpoint {
        case "chat":
            if item.type == .communicationStyle { score += 0.15 }
            if item.type == .personalityNote { score += 0.1 }
        case "briefing":
            if item.type == .contactIntelligence { score += 0.2 }
            if item.type == .followUp { score += 0.15 }
        case "commitment_scan":
            if item.type == .correctionPattern { score += 0.2 }
            if item.type == .contactIntelligence { score += 0.15 }
        case "extraction":
            if item.type == .correctionPattern { score += 0.3 }
        default:
            break
        }

        return score
    }

    // MARK: - Reinforcement Through Usage

    private func reinforceUsedPatterns(items: [MemoryItem]) {
        let workflowIds = items.filter { $0.source == .workflow }.map { $0.id }
        guard !workflowIds.isEmpty else { return }

        // Fire-and-forget: update last_reinforced for patterns that were injected
        DispatchQueue.global(qos: .utility).async {
            WorkflowLearningService.shared.touchLastReinforced(patternIds: workflowIds)
        }
    }

    // MARK: - Helpers

    private func sectionHeader(for type: MemoryItem.ItemType) -> String {
        switch type {
        case .directInstruction: return "Your Explicit Preferences"
        case .userContext: return "What Alfred Knows About You"
        case .communicationStyle: return "Communication Style"
        case .coachingTheme: return "Active Coaching Themes"
        case .contactIntelligence: return "Contact Intelligence"
        case .correctionPattern: return "Extraction Patterns"
        case .followUp: return "Open Follow-ups"
        case .personalityNote: return "Communication Style"
        case .agentRule, .agentPattern: return "Agent Memory"
        }
    }

    private func formatItem(_ item: MemoryItem) -> String {
        let staleMarker = item.isStale ? " _(older observation)_" : ""
        return "- \(item.content)\(staleMarker)"
    }

    private func parseCoachingContextSections(_ context: String) -> [String: String] {
        var sections: [String: String] = [:]
        var currentSection = ""
        var currentContent = ""

        for line in context.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("## ") {
                if !currentSection.isEmpty {
                    sections[currentSection] = currentContent.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                currentSection = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                currentContent = ""
            } else {
                currentContent += line + "\n"
            }
        }
        if !currentSection.isEmpty {
            sections[currentSection] = currentContent.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return sections
    }

    private func agentTypeFromString(_ name: String) -> AgentType {
        switch name {
        case "communication": return .communication
        case "task": return .task
        case "calendar": return .calendar
        case "followup": return .followup
        default: return .communication
        }
    }
}
