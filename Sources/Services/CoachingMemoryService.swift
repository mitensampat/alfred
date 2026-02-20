import Foundation

/// Service for managing persistent coaching memory
/// Follows the file-first Context.md pattern: human-readable markdown that compounds across sessions
class CoachingMemoryService {

    static let shared = CoachingMemoryService()

    private let filePath: String
    private let fileLock = NSLock()
    private let fileManager = FileManager.default

    // Section order for reconstruction
    private let sectionOrder = [
        "User Profile",
        "Coaching Themes",
        "Session Log",
        "Patterns Observed",
        "Personality Notes",
        "Open Follow-ups"
    ]

    // Caps
    private let maxSessions = 10
    private let maxPatterns = 20
    private let maxFollowups = 10

    init() {
        let homeDir = NSHomeDirectory()
        self.filePath = "\(homeDir)/.alfred/coaching_context.md"
        ensureFileExists()
    }

    // MARK: - Read Operations

    /// Get the full coaching context as a string for system prompt injection
    func getCoachingContext() -> String {
        fileLock.lock()
        defer { fileLock.unlock() }

        guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else {
            return ""
        }
        return content
    }

    /// Get open follow-ups as an array of strings
    func getOpenFollowups() -> [String] {
        fileLock.lock()
        defer { fileLock.unlock() }

        let sections = parseSections()
        guard let followupsContent = sections["Open Follow-ups"] else { return [] }

        return followupsContent
            .components(separatedBy: "\n")
            .filter { $0.starts(with: "- [ ] ") }
            .map { String($0.dropFirst(6)) }
    }

    /// Get the last N session summaries
    func getRecentSessions(limit: Int = 5) -> [String] {
        fileLock.lock()
        defer { fileLock.unlock() }

        let sections = parseSections()
        guard let sessionLog = sections["Session Log"] else { return [] }

        // Parse session blocks (delimited by ### headers)
        var sessions: [String] = []
        var currentSession = ""

        for line in sessionLog.components(separatedBy: "\n") {
            if line.starts(with: "### ") {
                if !currentSession.isEmpty {
                    sessions.append(currentSession.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                currentSession = line + "\n"
            } else {
                currentSession += line + "\n"
            }
        }
        if !currentSession.isEmpty {
            sessions.append(currentSession.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return Array(sessions.suffix(limit))
    }

    // MARK: - Write Operations

    /// Record a new coaching session summary
    func recordSession(topic: String, insight: String, action: String?, followUp: String?) {
        fileLock.lock()
        defer { fileLock.unlock() }

        var sections = parseSections()

        // Build session entry
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        let dateStr = dateFormatter.string(from: Date())

        var sessionEntry = "### \(dateStr)\n"
        sessionEntry += "- Topic: \(topic)\n"
        sessionEntry += "- Insight: \(insight)\n"
        if let action = action, !action.isEmpty {
            sessionEntry += "- Action: \(action)\n"
        }
        if let followUp = followUp, !followUp.isEmpty {
            sessionEntry += "- Follow-up: \(followUp)"
        }

        // Append to session log
        var sessionLog = sections["Session Log"] ?? "_No sessions yet._"

        // Remove placeholder text if present
        if sessionLog.contains("_No sessions yet._") {
            sessionLog = ""
        }

        // Count existing sessions and trim if over cap
        let existingSessions = sessionLog.components(separatedBy: "\n### ")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        if existingSessions.count >= maxSessions {
            // Remove oldest session (first block), keep the rest
            let lines = sessionLog.components(separatedBy: "\n")
            var foundFirst = false
            var foundSecond = false
            var trimmedLines: [String] = []

            for line in lines {
                if line.starts(with: "### ") {
                    if !foundFirst {
                        foundFirst = true
                        continue // skip first session header
                    } else {
                        foundSecond = true
                    }
                }
                if foundSecond || (!foundFirst && !line.starts(with: "### ")) {
                    // Before first session header or after second
                } else if foundFirst && !foundSecond {
                    continue // skip first session content
                }
                if foundSecond {
                    trimmedLines.append(line)
                }
            }
            sessionLog = trimmedLines.joined(separator: "\n")
        }

        // Append new session
        if !sessionLog.isEmpty && !sessionLog.hasSuffix("\n") {
            sessionLog += "\n"
        }
        sessionLog += sessionEntry

        sections["Session Log"] = sessionLog

        // Add follow-up to Open Follow-ups if provided
        if let followUp = followUp, !followUp.isEmpty {
            let shortDate = {
                let fmt = DateFormatter()
                fmt.dateFormat = "MMM d"
                return fmt.string(from: Date())
            }()
            var followups = sections["Open Follow-ups"] ?? ""
            if followups.contains("_None right now._") {
                followups = ""
            }

            // Cap follow-ups
            let existingFollowups = followups.components(separatedBy: "\n")
                .filter { $0.starts(with: "- [ ] ") || $0.starts(with: "- [x] ") }
            if existingFollowups.count >= maxFollowups {
                // Remove oldest unchecked follow-up
                var lines = followups.components(separatedBy: "\n")
                if let firstIdx = lines.firstIndex(where: { $0.starts(with: "- [ ] ") }) {
                    lines.remove(at: firstIdx)
                }
                followups = lines.joined(separator: "\n")
            }

            if !followups.isEmpty && !followups.hasSuffix("\n") {
                followups += "\n"
            }
            followups += "- [ ] \(followUp) (\(shortDate))"
            sections["Open Follow-ups"] = followups
        }

        saveSections(sections)
        print("📝 [Coaching] Recorded session: \(topic)")
    }

    /// Update or add a coaching theme
    func updateTheme(theme: String, resolved: Bool = false) {
        fileLock.lock()
        defer { fileLock.unlock() }

        var sections = parseSections()
        var themes = sections["Coaching Themes"] ?? "### Active\n\n### Resolved"

        let dateStr = {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            return fmt.string(from: Date())
        }()

        let entry = "- [\(dateStr)] \(theme)"

        if resolved {
            // Move from Active to Resolved (or just add to Resolved)
            if themes.contains("### Resolved") {
                themes = themes.replacingOccurrences(of: "### Resolved", with: "### Resolved\n\(entry)")
            } else {
                themes += "\n### Resolved\n\(entry)"
            }
        } else {
            // Add to Active
            if themes.contains("### Active") {
                let lines = themes.components(separatedBy: "\n")
                var newLines: [String] = []
                var inserted = false
                for line in lines {
                    newLines.append(line)
                    if line == "### Active" && !inserted {
                        newLines.append(entry)
                        inserted = true
                    }
                }
                if !inserted {
                    newLines.append(entry)
                }
                themes = newLines.joined(separator: "\n")
            } else {
                themes = "### Active\n\(entry)\n\(themes)"
            }
        }

        sections["Coaching Themes"] = themes
        saveSections(sections)
    }

    /// Update or add a pattern observation
    func updatePattern(category: String, observation: String) {
        fileLock.lock()
        defer { fileLock.unlock() }

        var sections = parseSections()
        var patterns = sections["Patterns Observed"] ?? ""

        if patterns.contains("_None yet") {
            patterns = ""
        }

        // Check if this category already exists and update it
        let lines = patterns.components(separatedBy: "\n")
        var found = false
        var newLines: [String] = []

        for line in lines {
            if line.lowercased().starts(with: "- \(category.lowercased()):") {
                newLines.append("- \(category): \(observation)")
                found = true
            } else {
                newLines.append(line)
            }
        }

        if !found {
            newLines.append("- \(category): \(observation)")
        }

        // Cap patterns
        let patternLines = newLines.filter { $0.starts(with: "- ") }
        if patternLines.count > maxPatterns {
            let excess = patternLines.count - maxPatterns
            var removed = 0
            newLines = newLines.filter { line in
                if line.starts(with: "- ") && removed < excess {
                    removed += 1
                    return false
                }
                return true
            }
        }

        sections["Patterns Observed"] = newLines.joined(separator: "\n")
        saveSections(sections)
    }

    /// Resolve (check off) a follow-up matching the given text
    func resolveFollowup(matching: String) {
        fileLock.lock()
        defer { fileLock.unlock() }

        var sections = parseSections()
        guard var followups = sections["Open Follow-ups"] else { return }

        let lines = followups.components(separatedBy: "\n")
        let newLines = lines.map { line -> String in
            if line.starts(with: "- [ ] ") && line.lowercased().contains(matching.lowercased()) {
                return line.replacingOccurrences(of: "- [ ] ", with: "- [x] ")
            }
            return line
        }

        sections["Open Follow-ups"] = newLines.joined(separator: "\n")
        saveSections(sections)
    }

    /// Update personality notes
    func updatePersonalityNote(note: String) {
        fileLock.lock()
        defer { fileLock.unlock() }

        var sections = parseSections()
        var notes = sections["Personality Notes"] ?? ""

        if notes.contains("_Learning") {
            notes = ""
        }

        // Don't add duplicate notes
        if notes.lowercased().contains(note.lowercased()) {
            return
        }

        if !notes.isEmpty && !notes.hasSuffix("\n") {
            notes += "\n"
        }
        notes += "- \(note)"
        sections["Personality Notes"] = notes
        saveSections(sections)
    }

    // MARK: - Private Helpers

    private func parseSections() -> [String: String] {
        guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else {
            return [:]
        }

        var sections: [String: String] = [:]
        let lines = content.components(separatedBy: "\n")
        var currentSection: String?
        var currentContent: [String] = []

        for line in lines {
            if line.starts(with: "## ") {
                if let section = currentSection {
                    sections[section] = currentContent.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                }
                currentSection = String(line.dropFirst(3))
                currentContent = []
            } else if currentSection != nil {
                currentContent.append(line)
            }
        }

        if let section = currentSection {
            sections[section] = currentContent.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return sections
    }

    private func saveSections(_ sections: [String: String]) {
        let timestamp = ISO8601DateFormatter().string(from: Date())

        var content = "# Coach Alfred Context\n\n"
        content += "_Last updated: \(timestamp)_\n\n"

        for sectionName in sectionOrder {
            if let sectionContent = sections[sectionName] {
                content += "## \(sectionName)\n\n\(sectionContent)\n\n"
            }
        }

        // Include any extra sections not in standard order
        for (name, sectionContent) in sections {
            if !sectionOrder.contains(name) && !sectionContent.isEmpty {
                content += "## \(name)\n\n\(sectionContent)\n\n"
            }
        }

        try? content.write(toFile: filePath, atomically: true, encoding: .utf8)

        // Fire-and-forget: sync to Notion (debounced internally)
        Task {
            try? await CoachingNotionSyncService.shared.syncToNotion()
        }
    }

    /// Bootstrap the coaching context file from config if it doesn't exist
    private func ensureFileExists() {
        guard !fileManager.fileExists(atPath: filePath) else { return }

        // Ensure directory exists
        let dir = (filePath as NSString).deletingLastPathComponent
        try? fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Load user info from config
        var userName = "User"
        var company = ""
        var email = ""
        if let config = AppConfig.load() {
            userName = config.user.name.isEmpty ? "User" : config.user.name
            company = config.user.companyDomain
            email = config.user.email
        }

        // Load key rules from agent memory
        var knownPriorities: [String] = []
        let taskMemory = AgentMemoryService.shared.getMemory(for: .task)
        if let rules = taskMemory.sections["User-Taught Rules"] {
            let ruleLines = rules.components(separatedBy: "\n").filter { $0.starts(with: "- ") }
            for line in ruleLines.prefix(5) {
                // Strip timestamp
                if let bracketEnd = line.range(of: "] ") {
                    knownPriorities.append(String(line[bracketEnd.upperBound...]))
                }
            }
        }

        let prioritiesStr = knownPriorities.isEmpty
            ? "- _Learning your priorities..._"
            : knownPriorities.map { "- \($0)" }.joined(separator: "\n")

        let content = """
        # Coach Alfred Context

        _Last updated: \(ISO8601DateFormatter().string(from: Date()))_

        ## User Profile

        - Name: \(userName)
        - Company: \(company)
        - Email: \(email)
        - Style: Direct, concise, no AI-sounding fluff
        - Known priorities:
        \(prioritiesStr)

        ## Coaching Themes

        ### Active

        _None yet — themes will emerge from our conversations._

        ### Resolved

        ## Session Log

        _No sessions yet._

        ## Patterns Observed

        - Avoidance: stale tasks accumulate — potential Zone 3 trap or fear-based procrastination
        - Leverage: calendar density varies — watch for back-to-back meeting days with no maker time
        - Relationships: commitment data reveals who gets attention and who doesn't — track debt

        ## Personality Notes

        - Appreciates directness over softening — don't hedge, don't qualify
        - Prefers ONE recommendation, not lists — force a choice
        - Responds to challenge — push back when rationalizing
        - Enjoys dry humor and self-aware CEO jokes — roast the schedule, not the person
        - Style: concise, no AI-sounding fluff — write like a human who respects his time

        ## Open Follow-ups

        _None right now._

        """

        try? content.write(toFile: filePath, atomically: true, encoding: .utf8)
        print("📝 [Coaching] Created initial coaching context at \(filePath)")
    }
}
