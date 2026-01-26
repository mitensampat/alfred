import Foundation

/// Service for managing agent memory and skills files
/// Provides read/write access to markdown-based memory that persists across sessions
class AgentMemoryService {

    static let shared = AgentMemoryService()

    private let baseDirectory: String
    private let fileManager = FileManager.default

    init() {
        // Use ~/.alfred/agents/ as the base directory
        let homeDir = NSHomeDirectory()
        self.baseDirectory = "\(homeDir)/.alfred/agents"
        ensureDirectoryStructure()
    }

    // MARK: - Directory Setup

    private func ensureDirectoryStructure() {
        let agents = ["communication", "task", "calendar", "followup"]

        for agent in agents {
            let agentDir = "\(baseDirectory)/\(agent)"
            if !fileManager.fileExists(atPath: agentDir) {
                try? fileManager.createDirectory(atPath: agentDir, withIntermediateDirectories: true)

                // Create initial files
                createInitialMemory(for: agent)
                createInitialSkills(for: agent)
            }
        }
    }

    // MARK: - Memory Operations

    /// Get the memory content for an agent
    func getMemory(for agentType: AgentType) -> AgentMemory {
        let path = memoryPath(for: agentType)

        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            // Return empty memory if file doesn't exist
            return AgentMemory(agentType: agentType, content: "", sections: [:])
        }

        return parseMemory(content: content, agentType: agentType)
    }

    /// Get the skills content for an agent
    func getSkills(for agentType: AgentType) -> AgentSkills {
        let path = skillsPath(for: agentType)

        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return AgentSkills(agentType: agentType, content: "", capabilities: [])
        }

        return parseSkills(content: content, agentType: agentType)
    }

    /// Add a user-taught rule to an agent's memory
    func teach(agentType: AgentType, rule: String, category: String? = nil) throws {
        var memory = getMemory(for: agentType)

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let categoryLabel = category ?? "General"

        // Format the new rule entry
        let ruleEntry = "- [\(timestamp)] \(rule)"

        // Find or create the User-Taught Rules section
        if var taughtRules = memory.sections["User-Taught Rules"] {
            // Check if category subsection exists
            if taughtRules.contains("### \(categoryLabel)") {
                // Append to existing category
                let lines = taughtRules.components(separatedBy: "\n")
                var newLines: [String] = []
                var foundCategory = false
                var inserted = false

                for line in lines {
                    newLines.append(line)
                    if line == "### \(categoryLabel)" {
                        foundCategory = true
                    } else if foundCategory && !inserted && (line.starts(with: "### ") || line.isEmpty) {
                        // Insert before next section or empty line
                        newLines.insert(ruleEntry, at: newLines.count - 1)
                        inserted = true
                    }
                }

                if !inserted {
                    newLines.append(ruleEntry)
                }

                taughtRules = newLines.joined(separator: "\n")
            } else {
                // Add new category
                taughtRules += "\n\n### \(categoryLabel)\n\(ruleEntry)"
            }
            memory.sections["User-Taught Rules"] = taughtRules
        } else {
            // Create new section
            memory.sections["User-Taught Rules"] = "### \(categoryLabel)\n\(ruleEntry)"
        }

        // Save updated memory
        try saveMemory(memory)

        print("✓ Taught \(agentType.rawValue) agent: \"\(rule)\"")
    }

    /// Record a learning from implicit feedback (edit, approval, rejection)
    func recordLearning(agentType: AgentType, learning: String, source: LearningSource) throws {
        var memory = getMemory(for: agentType)

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let sourceLabel = source.rawValue

        let learningEntry = "- [\(timestamp)] [\(sourceLabel)] \(learning)"

        // Add to Learned Patterns section
        if var patterns = memory.sections["Learned Patterns"] {
            patterns += "\n\(learningEntry)"
            memory.sections["Learned Patterns"] = patterns
        } else {
            memory.sections["Learned Patterns"] = learningEntry
        }

        try saveMemory(memory)
    }

    /// Remove a specific learning or rule from memory
    func forget(agentType: AgentType, pattern: String) throws -> Bool {
        var memory = getMemory(for: agentType)
        var found = false

        // Search all sections for the pattern
        for (sectionName, sectionContent) in memory.sections {
            let lines = sectionContent.components(separatedBy: "\n")
            let filteredLines = lines.filter { line in
                if line.lowercased().contains(pattern.lowercased()) {
                    found = true
                    return false
                }
                return true
            }

            if filteredLines.count != lines.count {
                memory.sections[sectionName] = filteredLines.joined(separator: "\n")
            }
        }

        if found {
            try saveMemory(memory)
            print("✓ Removed pattern containing \"\(pattern)\" from \(agentType.rawValue) memory")
        }

        return found
    }

    /// Get a summary of what the agent knows (for display)
    func getMemorySummary(for agentType: AgentType) -> MemorySummary {
        let memory = getMemory(for: agentType)

        var taughtRulesCount = 0
        var learnedPatternsCount = 0
        var contactsKnown: [String] = []

        if let taughtRules = memory.sections["User-Taught Rules"] {
            taughtRulesCount = taughtRules.components(separatedBy: "\n").filter { $0.starts(with: "- ") }.count
        }

        if let patterns = memory.sections["Learned Patterns"] {
            learnedPatternsCount = patterns.components(separatedBy: "\n").filter { $0.starts(with: "- ") }.count
        }

        if let contacts = memory.sections["Contact-Specific Patterns"] {
            let lines = contacts.components(separatedBy: "\n")
            for line in lines {
                if line.starts(with: "### ") {
                    contactsKnown.append(String(line.dropFirst(4)))
                }
            }
        }

        return MemorySummary(
            agentType: agentType,
            taughtRulesCount: taughtRulesCount,
            learnedPatternsCount: learnedPatternsCount,
            contactsKnown: contactsKnown,
            lastUpdated: getLastModified(path: memoryPath(for: agentType))
        )
    }

    /// Get memory content formatted for inclusion in LLM prompts
    func getMemoryForPrompt(agentType: AgentType, context: PromptContext? = nil) -> String {
        let memory = getMemory(for: agentType)
        var promptContent = ""

        // Always include User-Taught Rules (highest priority)
        if let taughtRules = memory.sections["User-Taught Rules"], !taughtRules.isEmpty {
            promptContent += "## USER-TAUGHT RULES (ALWAYS FOLLOW)\n\(taughtRules)\n\n"
        }

        // Include style/preferences section
        if let style = memory.sections["Your Style"] ?? memory.sections["Style"] {
            promptContent += "## USER STYLE\n\(style)\n\n"
        }

        // Context-specific inclusion
        if let context = context {
            // If we have a specific contact, include their patterns
            if let contactName = context.contactName,
               let contactPatterns = memory.sections["Contact-Specific Patterns"] {
                // Extract just this contact's section
                if let contactSection = extractContactSection(contactPatterns, contactName: contactName) {
                    promptContent += "## PATTERNS FOR \(contactName.uppercased())\n\(contactSection)\n\n"
                }
            }
        }

        // Include recent learned patterns (last 10)
        if let patterns = memory.sections["Learned Patterns"] {
            let lines = patterns.components(separatedBy: "\n").filter { $0.starts(with: "- ") }
            let recentPatterns = lines.suffix(10).joined(separator: "\n")
            if !recentPatterns.isEmpty {
                promptContent += "## RECENT LEARNINGS\n\(recentPatterns)\n\n"
            }
        }

        return promptContent
    }

    // MARK: - Private Helpers

    private func memoryPath(for agentType: AgentType) -> String {
        return "\(baseDirectory)/\(agentType.rawValue)/memory.md"
    }

    private func skillsPath(for agentType: AgentType) -> String {
        return "\(baseDirectory)/\(agentType.rawValue)/skills.md"
    }

    private func parseMemory(content: String, agentType: AgentType) -> AgentMemory {
        var sections: [String: String] = [:]

        let lines = content.components(separatedBy: "\n")
        var currentSection: String?
        var currentContent: [String] = []

        for line in lines {
            if line.starts(with: "## ") {
                // Save previous section
                if let section = currentSection {
                    sections[section] = currentContent.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                }
                // Start new section
                currentSection = String(line.dropFirst(3))
                currentContent = []
            } else if currentSection != nil {
                currentContent.append(line)
            }
        }

        // Save last section
        if let section = currentSection {
            sections[section] = currentContent.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return AgentMemory(agentType: agentType, content: content, sections: sections)
    }

    private func parseSkills(content: String, agentType: AgentType) -> AgentSkills {
        var capabilities: [String] = []

        let lines = content.components(separatedBy: "\n")
        for line in lines {
            if line.starts(with: "1. ") || line.starts(with: "2. ") || line.starts(with: "3. ") ||
               line.starts(with: "4. ") || line.starts(with: "5. ") {
                // Extract capability name (text between ** **)
                if let start = line.range(of: "**"), let end = line.range(of: "**", range: start.upperBound..<line.endIndex) {
                    let capability = String(line[start.upperBound..<end.lowerBound])
                    capabilities.append(capability)
                }
            }
        }

        return AgentSkills(agentType: agentType, content: content, capabilities: capabilities)
    }

    private func saveMemory(_ memory: AgentMemory) throws {
        let path = memoryPath(for: memory.agentType)

        // Reconstruct markdown from sections
        var content = "# \(memory.agentType.displayName) Memory\n\n"
        content += "_What I've learned about your preferences and patterns._\n\n"

        // Order sections logically
        let sectionOrder = ["User-Taught Rules", "Your Style", "Contact-Specific Patterns", "Phrases You Use", "Phrases You Never Use", "Learned Patterns", "Learned Corrections"]

        for sectionName in sectionOrder {
            if let sectionContent = memory.sections[sectionName], !sectionContent.isEmpty {
                content += "## \(sectionName)\n\n\(sectionContent)\n\n"
            }
        }

        // Add any sections not in the standard order
        for (sectionName, sectionContent) in memory.sections {
            if !sectionOrder.contains(sectionName) && !sectionContent.isEmpty {
                content += "## \(sectionName)\n\n\(sectionContent)\n\n"
            }
        }

        try content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func extractContactSection(_ contactPatterns: String, contactName: String) -> String? {
        let lines = contactPatterns.components(separatedBy: "\n")
        var inContactSection = false
        var contactLines: [String] = []

        for line in lines {
            if line.starts(with: "### ") {
                if inContactSection {
                    break // End of this contact's section
                }
                if line.lowercased().contains(contactName.lowercased()) {
                    inContactSection = true
                }
            } else if inContactSection {
                contactLines.append(line)
            }
        }

        let content = contactLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return content.isEmpty ? nil : content
    }

    private func getLastModified(path: String) -> Date? {
        guard let attrs = try? fileManager.attributesOfItem(atPath: path),
              let modDate = attrs[.modificationDate] as? Date else {
            return nil
        }
        return modDate
    }

    // MARK: - Initial File Creation

    private func createInitialMemory(for agent: String) {
        let content: String

        switch agent {
        case "communication":
            content = """
            # Communication Memory

            _What I've learned about your communication style and preferences._

            ## User-Taught Rules

            _Rules you've explicitly taught me. These always take priority._

            ## Your Style

            - Default tone: Professional but warm
            - Response length: Concise
            - Emoji usage: Minimal

            ## Contact-Specific Patterns

            _How you communicate with specific people._

            ## Phrases You Use

            _Phrases I've noticed you prefer._

            ## Phrases You Never Use

            _Phrases to avoid in your communications._

            ## Learned Patterns

            _Patterns learned from your feedback and edits._

            ## Learned Corrections

            _Specific corrections from when you edited my drafts._

            """

        case "task":
            content = """
            # Task Memory

            _What I've learned about your work patterns and priorities._

            ## User-Taught Rules

            _Rules you've explicitly taught me. These always take priority._

            ## Priority Patterns

            - High priority: Deadlines within 24h, external stakeholders
            - Medium priority: Weekly goals, team commitments
            - Low priority: Nice-to-haves, future planning

            ## Work Schedule

            - Focus time: Mornings preferred
            - Meeting-heavy: Afternoons
            - Deep work blocks: To be learned

            ## Learned Patterns

            _Patterns learned from your task management behavior._

            """

        case "calendar":
            content = """
            # Calendar Memory

            _What I've learned about your meeting and scheduling preferences._

            ## User-Taught Rules

            _Rules you've explicitly taught me. These always take priority._

            ## Meeting Prep Preferences

            - External meetings: 15 min prep
            - Internal meetings: 5 min prep
            - Board/investor meetings: 30 min prep

            ## Important Contacts

            _People whose meetings should always be prioritized._

            ## Scheduling Preferences

            - Preferred meeting times: To be learned
            - Buffer between meetings: To be learned
            - No-meeting blocks: To be learned

            ## Learned Patterns

            _Patterns learned from your calendar behavior._

            """

        case "followup":
            content = """
            # Followup Memory

            _What I've learned about your commitment and followup patterns._

            ## User-Taught Rules

            _Rules you've explicitly taught me. These always take priority._

            ## Followup Patterns

            - Response time expectations: To be learned
            - Who you follow up with promptly: To be learned
            - Commitment tracking preferences: To be learned

            ## Important Relationships

            _People whose commitments are high priority._

            ## Learned Patterns

            _Patterns learned from your followup behavior._

            """

        default:
            content = "# \(agent.capitalized) Memory\n\n_Learning in progress._"
        }

        let path = "\(baseDirectory)/\(agent)/memory.md"
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func createInitialSkills(for agent: String) {
        let content: String

        switch agent {
        case "communication":
            content = """
            # Communication Agent Skills

            _What I can do to help with your communications._

            ## Core Capabilities

            1. **Draft Responses** - Generate message drafts matching your style
            2. **Tone Detection** - Identify appropriate formality level for each contact
            3. **Context Analysis** - Understand conversation history and relationships
            4. **Style Matching** - Learn and replicate your communication patterns

            ## Triggers

            I activate when:
            - Messages are marked as needing response
            - High-priority contacts have unread messages
            - Conversations have pending action items
            - You haven't responded within your typical timeframe

            ## Confidence Factors

            My confidence in drafts increases with:
            - Known contact patterns: +0.2
            - Similar past examples: +0.1 to +0.3
            - Clear context: +0.1

            My confidence decreases with:
            - Ambiguous requests: -0.2
            - Complex topics (legal, financial): -0.3
            - New contacts: -0.1

            ## How to Improve Me

            - **Edit my drafts** - I learn from every change you make
            - **Teach me rules** - Use `alfred teach communication "rule"`
            - **Add examples** - Add to Config/communication_training.json
            - **Give feedback** - Approve or reject my suggestions

            ## Current Limitations

            - Cannot send messages directly (drafts only)
            - May not capture nuanced relationship dynamics initially
            - Complex negotiations require human judgment

            """

        case "task":
            content = """
            # Task Agent Skills

            _What I can do to help with your task management._

            ## Core Capabilities

            1. **Priority Analysis** - Identify what needs attention first
            2. **Deadline Tracking** - Flag approaching deadlines
            3. **Context Awareness** - Consider meetings and commitments when prioritizing
            4. **Workload Balancing** - Suggest task distribution across time

            ## Triggers

            I activate when:
            - Generating daily briefings
            - Tasks have approaching deadlines
            - Calendar shows heavy meeting days
            - Multiple high-priority items compete for attention

            ## Confidence Factors

            My confidence increases with:
            - Clear deadlines: +0.2
            - Explicit priority labels: +0.2
            - Historical pattern match: +0.1 to +0.3

            My confidence decreases with:
            - Vague task descriptions: -0.2
            - Conflicting priorities: -0.1
            - Unknown task types: -0.1

            ## How to Improve Me

            - **Teach me patterns** - Use `alfred teach task "Friday afternoons are for deep work"`
            - **Correct my priorities** - When I get it wrong, tell me why
            - **Mark what's actually important** - Your actions teach me more than labels

            ## Current Limitations

            - Cannot create tasks directly in Notion yet
            - May not understand project dependencies
            - Learning your priorities takes time

            """

        case "calendar":
            content = """
            # Calendar Agent Skills

            _What I can do to help with your calendar and meeting prep._

            ## Core Capabilities

            1. **Meeting Prep Scheduling** - Allocate time for preparation
            2. **Attendee Analysis** - Identify key participants and relationships
            3. **Context Gathering** - Pull relevant notes and history for meetings
            4. **Time Protection** - Identify focus time blocks to protect

            ## Triggers

            I activate when:
            - External meetings are within 48 hours
            - Important contacts have meetings scheduled
            - Back-to-back meetings need buffer time
            - You have meetings with new contacts

            ## Confidence Factors

            My confidence increases with:
            - Known attendees: +0.2
            - Regular meeting patterns: +0.2
            - Clear meeting context: +0.1

            My confidence decreases with:
            - Unknown attendees: -0.1
            - Unusual meeting times: -0.1
            - Missing context: -0.2

            ## How to Improve Me

            - **Teach me preferences** - Use `alfred teach calendar "Board meetings need 30 min prep"`
            - **Mark important contacts** - Add them to memory
            - **Indicate prep needs** - Accept or reject my prep suggestions

            ## Current Limitations

            - Cannot create calendar events directly
            - Meeting context limited to available notes
            - Cannot reschedule meetings

            """

        case "followup":
            content = """
            # Followup Agent Skills

            _What I can do to help track commitments and followups._

            ## Core Capabilities

            1. **Commitment Detection** - Identify promises in messages and meetings
            2. **Deadline Tracking** - Monitor commitment due dates
            3. **Relationship Awareness** - Track who owes what to whom
            4. **Reminder Generation** - Suggest followup timing

            ## Triggers

            I activate when:
            - Messages contain commitment language ("I'll", "by Friday", etc.)
            - Deadlines are approaching
            - Commitments are overdue
            - Important contacts haven't responded

            ## Confidence Factors

            My confidence increases with:
            - Explicit deadlines: +0.3
            - Clear commitment language: +0.2
            - Known relationship patterns: +0.1

            My confidence decreases with:
            - Vague timeframes: -0.2
            - Ambiguous ownership: -0.2
            - Casual conversation context: -0.1

            ## How to Improve Me

            - **Teach me patterns** - Use `alfred teach followup "Always follow up with investors within 24h"`
            - **Correct my detection** - Tell me when I miss or falsely detect commitments
            - **Mark important relationships** - Add to memory

            ## Current Limitations

            - Cannot send followup messages directly
            - May miss implicit commitments
            - Context limited to analyzed messages

            """

        default:
            content = "# \(agent.capitalized) Agent Skills\n\n_Capabilities documentation._"
        }

        let path = "\(baseDirectory)/\(agent)/skills.md"
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

// MARK: - Supporting Types

struct AgentMemory {
    let agentType: AgentType
    let content: String
    var sections: [String: String]
}

struct AgentSkills {
    let agentType: AgentType
    let content: String
    let capabilities: [String]
}

struct MemorySummary {
    let agentType: AgentType
    let taughtRulesCount: Int
    let learnedPatternsCount: Int
    let contactsKnown: [String]
    let lastUpdated: Date?

    var formattedLastUpdated: String {
        guard let date = lastUpdated else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct PromptContext {
    let contactName: String?
    let platform: MessagePlatform?
    let urgency: UrgencyLevel?

    init(contactName: String? = nil, platform: MessagePlatform? = nil, urgency: UrgencyLevel? = nil) {
        self.contactName = contactName
        self.platform = platform
        self.urgency = urgency
    }
}

enum LearningSource: String {
    case draftEdit = "edit"
    case draftApproval = "approval"
    case draftRejection = "rejection"
    case implicitPattern = "pattern"
    case consolidation = "consolidated"
}

// MARK: - Learning Consolidation

import SQLite3

extension AgentMemoryService {

    /// Consolidate learnings from learning.db patterns into memory.md
    /// This should be run periodically (e.g., daily or weekly)
    func consolidateLearnings() throws {
        print("🧠 Starting learning consolidation...")

        let homeDir = NSHomeDirectory()
        let learningDbPath = "\(homeDir)/.alfred/learning.db"

        guard fileManager.fileExists(atPath: learningDbPath) else {
            print("  No learning database found at \(learningDbPath)")
            return
        }

        // Open learning database
        var db: OpaquePointer?
        guard sqlite3_open(learningDbPath, &db) == SQLITE_OK else {
            print("  Failed to open learning database")
            return
        }
        defer { sqlite3_close(db) }

        // Query high-confidence patterns that haven't been consolidated
        let patternsToConsolidate = queryPatternsForConsolidation(db: db)

        if patternsToConsolidate.isEmpty {
            print("  No new patterns to consolidate")
            return
        }

        print("  Found \(patternsToConsolidate.count) patterns to consolidate")

        // Group patterns by agent type
        var patternsByAgent: [AgentType: [ConsolidatedPattern]] = [:]
        for pattern in patternsToConsolidate {
            if let agentType = AgentType(rawValue: pattern.agentType) {
                if patternsByAgent[agentType] == nil {
                    patternsByAgent[agentType] = []
                }
                patternsByAgent[agentType]?.append(pattern)
            }
        }

        // Write consolidated patterns to memory files
        for (agentType, patterns) in patternsByAgent {
            try consolidatePatternsToMemory(agentType: agentType, patterns: patterns)
            print("  ✓ Consolidated \(patterns.count) patterns to \(agentType.rawValue) memory")
        }

        // Mark patterns as consolidated in database
        markPatternsAsConsolidated(db: db, patterns: patternsToConsolidate)

        print("✓ Learning consolidation complete")
    }

    private func queryPatternsForConsolidation(db: OpaquePointer?) -> [ConsolidatedPattern] {
        var patterns: [ConsolidatedPattern] = []

        // Query patterns with high confidence (>0.7) and enough data (>=5 total feedback)
        let query = """
        SELECT id, agent_type, action_type, context_hash, confidence,
               approval_count, rejection_count, success_count, failure_count, last_updated
        FROM patterns
        WHERE confidence >= 0.7
          AND (approval_count + rejection_count) >= 5
        ORDER BY confidence DESC, (approval_count + rejection_count) DESC
        LIMIT 20;
        """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(statement, 0))
                let agentType = String(cString: sqlite3_column_text(statement, 1))
                let actionType = String(cString: sqlite3_column_text(statement, 2))
                let contextHash = String(cString: sqlite3_column_text(statement, 3))
                let confidence = sqlite3_column_double(statement, 4)
                let approvalCount = Int(sqlite3_column_int(statement, 5))
                let rejectionCount = Int(sqlite3_column_int(statement, 6))
                let successCount = Int(sqlite3_column_int(statement, 7))
                let failureCount = Int(sqlite3_column_int(statement, 8))

                let pattern = ConsolidatedPattern(
                    id: id,
                    agentType: agentType,
                    actionType: actionType,
                    contextHash: contextHash,
                    confidence: confidence,
                    approvalCount: approvalCount,
                    rejectionCount: rejectionCount,
                    successCount: successCount,
                    failureCount: failureCount
                )
                patterns.append(pattern)
            }
        }

        return patterns
    }

    private func consolidatePatternsToMemory(agentType: AgentType, patterns: [ConsolidatedPattern]) throws {
        for pattern in patterns {
            // Create a human-readable learning summary
            let totalFeedback = pattern.approvalCount + pattern.rejectionCount
            let approvalRate = Double(pattern.approvalCount) / Double(totalFeedback) * 100

            var learningDescription = ""

            // Describe what was learned based on action type and approval rate
            switch pattern.actionType {
            case "draft_response":
                if approvalRate > 85 {
                    learningDescription = "High success rate for drafting responses in context: \(pattern.contextHash.prefix(30))... (\(Int(approvalRate))% approved)"
                } else {
                    learningDescription = "Learned response pattern for: \(pattern.contextHash.prefix(30))... (confidence: \(Int(pattern.confidence * 100))%)"
                }

            case "adjust_task_priority":
                learningDescription = "Priority adjustment pattern learned: \(pattern.contextHash.prefix(30))... (\(Int(approvalRate))% accurate)"

            case "schedule_meeting_prep":
                learningDescription = "Meeting prep pattern: \(pattern.contextHash.prefix(30))... (confidence: \(Int(pattern.confidence * 100))%)"

            case "create_followup":
                learningDescription = "Follow-up detection pattern: \(pattern.contextHash.prefix(30))... (\(Int(approvalRate))% useful)"

            default:
                learningDescription = "Learned pattern (\(pattern.actionType)): confidence \(Int(pattern.confidence * 100))% based on \(totalFeedback) interactions"
            }

            // Record the learning to memory
            try recordLearning(
                agentType: agentType,
                learning: learningDescription,
                source: .consolidation
            )
        }
    }

    private func markPatternsAsConsolidated(db: OpaquePointer?, patterns: [ConsolidatedPattern]) {
        // For now, we rely on the confidence and count thresholds
        // In a full implementation, you'd track consolidated patterns to avoid re-processing
        // Could add a 'consolidated_at' column to the patterns table
    }

    /// Get a summary of learnings that could be consolidated
    func getConsolidationSummary() -> ConsolidationSummary {
        let homeDir = NSHomeDirectory()
        let learningDbPath = "\(homeDir)/.alfred/learning.db"

        guard fileManager.fileExists(atPath: learningDbPath) else {
            return ConsolidationSummary(
                totalPatterns: 0,
                patternsReadyForConsolidation: 0,
                patternsByAgent: [:]
            )
        }

        var db: OpaquePointer?
        guard sqlite3_open(learningDbPath, &db) == SQLITE_OK else {
            return ConsolidationSummary(
                totalPatterns: 0,
                patternsReadyForConsolidation: 0,
                patternsByAgent: [:]
            )
        }
        defer { sqlite3_close(db) }

        // Count total patterns
        var totalPatterns = 0
        let countQuery = "SELECT COUNT(*) FROM patterns;"
        var countStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, countQuery, -1, &countStmt, nil) == SQLITE_OK {
            if sqlite3_step(countStmt) == SQLITE_ROW {
                totalPatterns = Int(sqlite3_column_int(countStmt, 0))
            }
        }
        sqlite3_finalize(countStmt)

        // Count ready for consolidation
        let patterns = queryPatternsForConsolidation(db: db)

        // Group by agent
        var patternsByAgent: [String: Int] = [:]
        for pattern in patterns {
            patternsByAgent[pattern.agentType, default: 0] += 1
        }

        return ConsolidationSummary(
            totalPatterns: totalPatterns,
            patternsReadyForConsolidation: patterns.count,
            patternsByAgent: patternsByAgent
        )
    }
}

// MARK: - Consolidation Types

struct ConsolidatedPattern {
    let id: String
    let agentType: String
    let actionType: String
    let contextHash: String
    let confidence: Double
    let approvalCount: Int
    let rejectionCount: Int
    let successCount: Int
    let failureCount: Int
}

struct ConsolidationSummary {
    let totalPatterns: Int
    let patternsReadyForConsolidation: Int
    let patternsByAgent: [String: Int]
}
