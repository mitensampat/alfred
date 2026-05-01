import Foundation

/// Loads and manages coaching skills from Markdown files.
/// Two-tier directory structure:
///   ~/.alfred/skills/user/       — user-created, fully editable
///   ~/.alfred/skills/installed/  — coach-authored, read-only (toggle only)
/// State file: ~/.alfred/skills_state.json
class SkillLoader {
    static let shared = SkillLoader()

    private let baseDirectory: String
    private let userDirectory: String
    private let installedDirectory: String
    private let statePath: String

    private init() {
        let alfredDir = NSString(string: "~/.alfred").expandingTildeInPath
        self.baseDirectory = alfredDir + "/skills"
        self.userDirectory = alfredDir + "/skills/user"
        self.installedDirectory = alfredDir + "/skills/installed"
        self.statePath = alfredDir + "/skills_state.json"

        // Ensure both directories exist
        let fm = FileManager.default
        try? fm.createDirectory(atPath: userDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: installedDirectory, withIntermediateDirectories: true)

        // Migration: move any .md files from old flat directory into user/
        migrateOldSkills()

        // Migration: rename old methodology-prefixed skill files to method-neutral names.
        // Must run BEFORE installDefaultSkills so user edits in old files are preserved
        // by being renamed (not overwritten by a fresh default).
        migrateSkillRenames()

        // Install default coaching skills (relational + direct methods)
        installDefaultSkills()
    }

    // MARK: - Public API

    /// Load all skill definitions from both user/ and installed/ directories
    func loadSkills() -> [SkillDefinition] {
        let enabledState = loadEnabledState()
        let skillStates = loadSkillStates()
        var skills: [SkillDefinition] = []

        // Load user-created skills
        skills.append(contentsOf: loadSkillsFromDirectory(userDirectory, origin: .user, enabledState: enabledState, skillStates: skillStates))

        // Load installed (coach-authored) skills
        skills.append(contentsOf: loadSkillsFromDirectory(installedDirectory, origin: .installed, enabledState: enabledState, skillStates: skillStates))

        return skills.sorted { $0.name < $1.name }
    }

    /// Load only enabled skills
    func getEnabledSkills() -> [SkillDefinition] {
        return loadSkills().filter { $0.enabled }
    }

    /// Toggle a skill's enabled/disabled state
    func toggleSkill(id: String) -> Bool {
        var state = loadEnabledState()
        let currentlyEnabled = state[id] ?? true
        state[id] = !currentlyEnabled
        saveEnabledState(state)
        return !currentlyEnabled
    }

    /// Set a skill's enabled state explicitly
    func setSkillEnabled(id: String, enabled: Bool) {
        var state = loadEnabledState()
        state[id] = enabled
        saveEnabledState(state)
    }

    // MARK: - CRUD Operations (user skills only)

    /// Create a new user skill from provided fields. Returns the created skill or nil on error.
    func createSkill(name: String, description: String, icon: String, dataSources: [String],
                     frequency: String, tenets: String, prompt: String, fallback: String? = nil) -> SkillDefinition? {
        // Generate ID from name (lowercase, hyphenated)
        let id = name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).inverted)
            .joined()

        guard !id.isEmpty else { return nil }

        let skill = SkillDefinition(
            id: id, name: name, description: description, icon: icon,
            dataSources: dataSources.filter { SkillDefinition.validDataSources.contains($0) },
            frequency: frequency, tenets: tenets, prompt: prompt,
            fallback: fallback, enabled: true, displayName: nil,
            origin: .user, author: nil, version: nil,
            usesTenets: nil, usesAnalyses: nil
        )

        let filePath = (userDirectory as NSString).appendingPathComponent("\(id).md")

        // Don't overwrite existing files
        guard !FileManager.default.fileExists(atPath: filePath) else {
            print("[SkillLoader] Skill file already exists: \(id).md")
            return nil
        }

        let content = skill.toMarkdown()
        do {
            try content.write(toFile: filePath, atomically: true, encoding: .utf8)
            return skill
        } catch {
            print("[SkillLoader] Failed to write skill file: \(error)")
            return nil
        }
    }

    /// Update an existing user skill. Returns updated skill or nil if not editable/not found.
    func updateSkill(id: String, name: String?, description: String?, icon: String?,
                     dataSources: [String]?, frequency: String?, tenets: String?,
                     prompt: String?, fallback: String? = nil) -> SkillDefinition? {
        let filePath = (userDirectory as NSString).appendingPathComponent("\(id).md")
        guard FileManager.default.fileExists(atPath: filePath) else {
            print("[SkillLoader] Cannot update: skill '\(id)' not found in user directory")
            return nil
        }

        // Load current version
        guard let current = parseSkillFile(path: filePath, origin: .user) else { return nil }

        let updated = SkillDefinition(
            id: id,
            name: name ?? current.name,
            description: description ?? current.description,
            icon: icon ?? current.icon,
            dataSources: dataSources?.filter { SkillDefinition.validDataSources.contains($0) } ?? current.dataSources,
            frequency: frequency ?? current.frequency,
            tenets: tenets ?? current.tenets,
            prompt: prompt ?? current.prompt,
            fallback: fallback ?? current.fallback,
            enabled: current.enabled,
            displayName: current.displayName,
            origin: .user,
            author: nil,
            version: nil,
            usesTenets: current.usesTenets,
            usesAnalyses: current.usesAnalyses
        )

        let content = updated.toMarkdown()
        do {
            try content.write(toFile: filePath, atomically: true, encoding: .utf8)
            return updated
        } catch {
            print("[SkillLoader] Failed to update skill file: \(error)")
            return nil
        }
    }

    /// Update tenets for an installed tenet-only skill. Only updates the tenets field.
    func updateInstalledSkillTenets(id: String, tenets: String) -> SkillDefinition? {
        let filePath = (installedDirectory as NSString).appendingPathComponent("\(id).md")
        guard FileManager.default.fileExists(atPath: filePath) else {
            print("[SkillLoader] Cannot update installed skill: '\(id)' not found")
            return nil
        }

        guard let current = parseSkillFile(path: filePath, origin: .installed) else { return nil }
        guard current.isTenetOnly else {
            print("[SkillLoader] Refusing to update installed skill '\(id)' — not a tenet-only skill")
            return nil
        }

        let updated = SkillDefinition(
            id: id,
            name: current.name,
            description: current.description,
            icon: current.icon,
            dataSources: current.dataSources,
            frequency: current.frequency,
            tenets: tenets,
            prompt: current.prompt,
            fallback: current.fallback,
            enabled: current.enabled,
            displayName: current.displayName,
            origin: .installed,
            author: current.author,
            version: current.version,
            usesTenets: current.usesTenets,
            usesAnalyses: current.usesAnalyses
        )

        let content = updated.toMarkdown()
        do {
            try content.write(toFile: filePath, atomically: true, encoding: .utf8)
            return updated
        } catch {
            print("[SkillLoader] Failed to update installed skill file: \(error)")
            return nil
        }
    }

    /// Delete a user skill. Returns true if deleted. Refuses to delete installed skills.
    func deleteSkill(id: String) -> Bool {
        let filePath = (userDirectory as NSString).appendingPathComponent("\(id).md")
        guard FileManager.default.fileExists(atPath: filePath) else {
            print("[SkillLoader] Cannot delete: skill '\(id)' not found in user directory")
            return false
        }

        do {
            try FileManager.default.removeItem(atPath: filePath)
            // Clean up enabled state
            var state = loadEnabledState()
            state.removeValue(forKey: id)
            saveEnabledState(state)
            return true
        } catch {
            print("[SkillLoader] Failed to delete skill: \(error)")
            return false
        }
    }

    /// Get a single skill by ID
    func getSkill(id: String) -> SkillDefinition? {
        return loadSkills().first { $0.id == id }
    }

    // MARK: - Markdown Parsing

    /// Parse a single skill Markdown file into a SkillDefinition
    func parseSkillFile(path: String, origin: SkillOrigin, enabledState: [String: Bool]? = nil, skillStates: [String: SkillState]? = nil) -> SkillDefinition? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }

        let filename = (path as NSString).lastPathComponent
        let id = (filename as NSString).deletingPathExtension

        // Parse title from first `# ` line
        let lines = content.components(separatedBy: "\n")
        guard let titleLine = lines.first(where: { $0.hasPrefix("# ") }) else {
            print("[SkillLoader] Skipping \(filename): no title found")
            return nil
        }
        let name = String(titleLine.dropFirst(2)).trimmingCharacters(in: .whitespaces)

        // Parse metadata fields: **Key:** value
        let description = parseMetadataField(content: content, key: "Description") ?? ""
        let icon = parseMetadataField(content: content, key: "Icon") ?? "🔧"
        let author = parseMetadataField(content: content, key: "Author")
        let version = parseMetadataField(content: content, key: "Version")
        let dataSourcesRaw = parseMetadataField(content: content, key: "Data Sources") ?? "tasks"
        let frequency = parseMetadataField(content: content, key: "Frequency") ?? "daily"
        let fallback = parseMetadataField(content: content, key: "Fallback")
        let usesTenetsRaw = parseMetadataField(content: content, key: "Uses Tenets")
        let usesAnalysesRaw = parseMetadataField(content: content, key: "Uses Analyses")

        // Parse tenet/analysis references (comma-separated, trimmed)
        let usesTenets: [String]? = usesTenetsRaw?.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let usesAnalyses: [String]? = usesAnalysesRaw?.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Parse data sources (comma-separated, trimmed)
        let dataSources = dataSourcesRaw
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { SkillDefinition.validDataSources.contains($0) }

        // Parse sections
        let tenets = parseSection(content: content, header: "Tenets") ?? ""
        let prompt = parseSection(content: content, header: "Prompt") ?? ""

        guard !prompt.isEmpty else {
            print("[SkillLoader] Skipping \(filename): no ## Prompt section found")
            return nil
        }

        // Determine enabled state and display name (default: true for new skills)
        let state = enabledState ?? loadEnabledState()
        let enabled = state[id] ?? true
        let states = skillStates ?? loadSkillStates()
        let displayName = states[id]?.displayName

        return SkillDefinition(
            id: id, name: name, description: description, icon: icon,
            dataSources: dataSources, frequency: frequency, tenets: tenets, prompt: prompt,
            fallback: fallback, enabled: enabled, displayName: displayName,
            origin: origin, author: author, version: version,
            usesTenets: usesTenets, usesAnalyses: usesAnalyses
        )
    }

    // MARK: - Private Helpers

    /// Load .md files from a specific directory with a given origin
    private func loadSkillsFromDirectory(_ directory: String, origin: SkillOrigin,
                                          enabledState: [String: Bool], skillStates: [String: SkillState]) -> [SkillDefinition] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: directory) else { return [] }

        return files
            .filter { $0.hasSuffix(".md") }
            .compactMap { filename -> SkillDefinition? in
                let path = (directory as NSString).appendingPathComponent(filename)
                return parseSkillFile(path: path, origin: origin, enabledState: enabledState, skillStates: skillStates)
            }
    }

    /// Migrate old flat-directory skills into user/ subdirectory
    private func migrateOldSkills() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: baseDirectory) else { return }

        for filename in files where filename.hasSuffix(".md") {
            let oldPath = (baseDirectory as NSString).appendingPathComponent(filename)
            let newPath = (userDirectory as NSString).appendingPathComponent(filename)

            // Only migrate if it's a file (not in a subdirectory) and doesn't already exist
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: oldPath, isDirectory: &isDir), !isDir.boolValue,
               !fm.fileExists(atPath: newPath) {
                try? fm.moveItem(atPath: oldPath, toPath: newPath)
                print("[SkillLoader] Migrated \(filename) to user/ directory")
            }
        }
    }

    /// Migrate old methodology-prefixed skill IDs to method-neutral names.
    /// Renames files in installed/ and user/ directories, plus rewrites the
    /// skills_state.json keys. Idempotent — safe to run on every launch.
    private func migrateSkillRenames() {
        let renames: [String: String] = [
            "campbell-leverage": "leverage",
            "campbell-relationship": "relationships",
            "mochary-attention": "attention",
            "mochary-avoidance": "avoidance",
            "mochary-weekly-review": "weekly-review",
            "campbell-rules": "relational-rules",
            "mochary-rules": "direct-rules",
        ]

        let fm = FileManager.default

        // 1. Rename .md files in both installed/ and user/ directories
        for directory in [installedDirectory, userDirectory] {
            for (oldId, newId) in renames {
                let oldPath = (directory as NSString).appendingPathComponent("\(oldId).md")
                let newPath = (directory as NSString).appendingPathComponent("\(newId).md")
                if fm.fileExists(atPath: oldPath), !fm.fileExists(atPath: newPath) {
                    try? fm.moveItem(atPath: oldPath, toPath: newPath)
                    print("[SkillLoader] Renamed \(oldId).md → \(newId).md")
                } else if fm.fileExists(atPath: oldPath), fm.fileExists(atPath: newPath) {
                    // Both exist — keep the new one, remove the old to avoid duplicates
                    try? fm.removeItem(atPath: oldPath)
                    print("[SkillLoader] Removed duplicate \(oldId).md (kept \(newId).md)")
                }
            }
        }

        // 2. Rewrite stale author/title strings inside any of the renamed files
        //    (handles files that were renamed on disk but still hold old content).
        let contentReplacements: [(old: String, new: String)] = [
            // Author fields
            ("**Author:** Bill Campbell Method", "**Author:** Relational Method"),
            ("**Author:** Matt Mochary Method", "**Author:** Direct Method"),
            // Title headers (multiple variants seen in the wild)
            ("# Bill Campbell Coaching Rules", "# Relational Coaching Rules"),
            ("# Matt Mochary Coaching Rules", "# Direct Coaching Rules"),
            ("# Campbell Rules", "# Relational Rules"),
            ("# Mochary Rules", "# Direct Rules"),
            // Description prefixes
            ("Bill Campbell's coaching principles", "Relational coaching principles"),
            ("Matt Mochary's coaching principles", "Direct coaching principles"),
            ("Bill Campbell's", "the relational"),
            ("Matt Mochary's", "the direct"),
            // Catch-all (less safe but covers stray mentions)
            ("Bill Campbell", "Relational"),
            ("Matt Mochary", "Direct"),
            ("Campbell Method", "Relational Method"),
            ("Mochary Method", "Direct Method"),
        ]
        for directory in [installedDirectory, userDirectory] {
            guard let files = try? fm.contentsOfDirectory(atPath: directory) else { continue }
            for filename in files where filename.hasSuffix(".md") {
                let path = (directory as NSString).appendingPathComponent(filename)
                guard var content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
                var changed = false
                for (oldStr, newStr) in contentReplacements where content.contains(oldStr) {
                    content = content.replacingOccurrences(of: oldStr, with: newStr)
                    changed = true
                }
                if changed {
                    try? content.write(toFile: path, atomically: true, encoding: .utf8)
                    print("[SkillLoader] Rewrote stale attribution in \(filename)")
                }
            }
        }

        // 2b. Same rewrites for the user's coaching_tenets.md if it has stale labels
        let coachingTenetsPath = NSString(string: "~/.alfred/coaching_tenets.md").expandingTildeInPath
        if var tenetsContent = try? String(contentsOfFile: coachingTenetsPath, encoding: .utf8) {
            var changed = false
            let tenetsReplacements: [(old: String, new: String)] = [
                ("## Campbell Rules", "## Relational Rules"),
                ("## Mochary Rules", "## Direct Rules"),
                ("**Campbell Rules:**", "**Relational Rules:**"),
                ("**Mochary Rules:**", "**Direct Rules:**"),
            ]
            for (oldStr, newStr) in tenetsReplacements where tenetsContent.contains(oldStr) {
                tenetsContent = tenetsContent.replacingOccurrences(of: oldStr, with: newStr)
                changed = true
            }
            if changed {
                try? tenetsContent.write(toFile: coachingTenetsPath, atomically: true, encoding: .utf8)
                print("[SkillLoader] Migrated coaching_tenets.md labels")
            }
        }

        // 3. Rename keys in skills_state.json
        if let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
           var state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var changed = false
            for (oldId, newId) in renames where state[oldId] != nil {
                if state[newId] == nil {
                    state[newId] = state[oldId]
                }
                state.removeValue(forKey: oldId)
                changed = true
            }
            if changed,
               let outData = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
                try? outData.write(to: URL(fileURLWithPath: statePath))
                print("[SkillLoader] Migrated skills_state.json keys")
            }
        }
    }

    /// Install default coaching skills if they don't already exist in the installed/ directory.
    /// These are the 5 default coaching skills, grouped by method (relational + direct).
    /// Never overwrites existing files — preserves user toggles and any manual edits.
    private func installDefaultSkills() {
        let fm = FileManager.default

        let defaultSkills: [(filename: String, content: String)] = [
            ("leverage.md", Self.leverageSkill),
            ("relationships.md", Self.relationshipsSkill),
            ("avoidance.md", Self.avoidanceSkill),
            ("attention.md", Self.attentionSkill),
            ("weekly-review.md", Self.weeklyReviewSkill),
        ]

        for (filename, content) in defaultSkills {
            let filePath = (installedDirectory as NSString).appendingPathComponent(filename)
            guard !fm.fileExists(atPath: filePath) else { continue }

            do {
                try content.write(toFile: filePath, atomically: true, encoding: .utf8)
                print("[SkillLoader] Installed default skill: \(filename)")
            } catch {
                print("[SkillLoader] Failed to install default skill \(filename): \(error)")
            }
        }
    }

    // MARK: - Default Skill Content

    private static let leverageSkill = """
    # Leverage

    **Description:** What is the single highest-leverage action right now?
    **Icon:** 🎯
    **Author:** Relational Method
    **Version:** 1.0
    **Data Sources:** tasks, calendar
    **Frequency:** daily

    ## Tenets
    - There is always ONE thing that matters most right now
    - Overdue items where someone is waiting on you are almost always highest leverage
    - A specific action beats a vague intention every time
    - Ruthless prioritization means saying no to good things to do the great thing

    ## Prompt
    You are a ruthlessly practical executive coach. Given this person's current workload, identify the SINGLE highest-leverage action they should take right now.

    Rules:
    - Pick ONE specific action from the context data, not a list
    - Reference a specific task or person by name ONLY if they appear in the context above
    - Explain WHY it's the highest leverage in one sentence
    - If no single action clearly stands out from the data, say "No clear signal today" rather than forcing a pick
    - No emojis, no fluff, plain language
    - Maximum 2 sentences total
    - If someone is waiting on something overdue, that's usually highest leverage

    Respond with ONLY the coaching insight text. No JSON, no labels, no preamble.
    """

    private static let relationshipsSkill = """
    # Relationship

    **Description:** Who needs attention? Unusual silence, piling-up obligations.
    **Icon:** 👤
    **Author:** Relational Method
    **Version:** 1.0
    **Data Sources:** commitments_by_person, messages
    **Frequency:** daily

    ## Tenets
    - Relationships are maintained through consistent attention, not grand gestures
    - Piling obligations on one person signals an imbalanced relationship
    - Silence from a usually-active contact is a warning sign
    - Only flag relationships where there are BOTH commitment issues AND communication silence

    ## Prompt
    You are an executive coach focused on relationship health. Based on this commitment and communication data, identify the ONE relationship that needs attention most.

    Rules:
    - Name a specific person ONLY if they appear in the context data above with clear evidence of an issue
    - Explain what the data suggests (e.g., piling obligations, high overdue rate, one-sided commitment flow)
    - Suggest one concrete action
    - NEVER suggest reaching out to someone who has had message interaction in the last 7 days — they don't need a nudge
    - Only flag relationships where there are BOTH commitment issues AND communication silence (no messages in 7+ days)
    - If no relationship clearly needs attention based on the data, say "No clear signal today" rather than guessing
    - No emojis, no fluff
    - Maximum 2 sentences total

    Respond with ONLY the coaching insight text. No JSON, no labels, no preamble.
    """

    private static let avoidanceSkill = """
    # Avoidance

    **Description:** What are you avoiding? Tasks created >14 days ago still not started.
    **Icon:** 🪞
    **Author:** Direct Method
    **Version:** 1.0
    **Fallback:** No stale or avoided tasks detected. Your task hygiene looks clean.
    **Data Sources:** tasks_detailed
    **Frequency:** daily

    ## Tenets
    - Tasks untouched for 14+ days reveal what you're unconsciously avoiding
    - After 21 days untouched, avoidance becomes a pattern that needs direct confrontation
    - Low-priority overdue items are often the tasks you find emotionally uncomfortable
    - The antidote to avoidance is a tiny concrete next step or the decision to drop it entirely

    ## Prompt
    You are an executive coach helping someone recognize procrastination patterns. Based on this data, identify what they're most likely avoiding and why.

    Rules:
    - Name the specific task or pattern
    - Be empathetic but direct about the avoidance
    - Suggest one concrete next step to break the avoidance (e.g., "spend 15 minutes on X" or "decide to drop it")
    - If there are ESCALATED items (21+ days untouched), be more forceful: "This is the third week X has sat here. Either do it today or decide to drop it. Which is it?"
    - Escalated items take priority over regular avoidance signals
    - No emojis, no fluff
    - Maximum 2 sentences total

    Respond with ONLY the coaching insight text. No JSON, no labels, no preamble.
    """

    private static let attentionSkill = """
    # Attention

    **Description:** Where is your attention going? Messaging velocity and calendar load analysis.
    **Icon:** 📡
    **Author:** Direct Method
    **Version:** 1.0
    **Data Sources:** messages_detailed, calendar
    **Frequency:** daily

    ## Tenets
    - A high inbound/outbound ratio means you're absorbing rather than directing
    - Back-to-back meetings with no breaks signal unsustainable pace
    - No free blocks means no time to think — that's an emergency
    - The noisiest groups often contribute least to your actual priorities

    ## Prompt
    You are an executive coach analyzing where this person's attention is going. Based on messaging patterns and calendar data, provide ONE sharp observation about their attention allocation.

    Rules:
    - Focus on the PATTERN, not individual messages
    - A high inbound/outbound ratio (e.g., >10:1) means they're absorbing rather than directing
    - Name specific groups or people that are consuming disproportionate attention
    - If calendar is packed with meetings AND messaging is high, name the double-drain
    - If there are no free blocks, say so directly — "you have no time to think today"
    - Suggest one concrete change (e.g., "mute X group", "block 2 hours for deep work", "decline one meeting")
    - No emojis, no fluff
    - Maximum 2 sentences total

    Respond with ONLY the coaching insight text. No JSON, no labels, no preamble.
    """

    private static let weeklyReviewSkill = """
    # Weekly Review

    **Description:** direct-method weekly review: wins, energy, relationships, carry-forward.
    **Icon:** 📋
    **Author:** Direct Method
    **Version:** 1.0
    **Data Sources:** tasks_detailed, commitments, coaching_memory
    **Frequency:** weekly

    ## Tenets
    - Acknowledge wins before pushing on gaps — people need to see their progress
    - Zone of Genius work energizes; Zone 3 grinding depletes — watch the task mix
    - Commitment debt to specific people reveals relationship strain
    - One carry-forward focus beats a list of aspirations every time

    ## Prompt
    You are an executive coach running a weekly review (direct method). Assess this person's week across 4 dimensions:

    Dimensions to assess:
    1. WINS: What did they accomplish? Name specifics from the completed tasks.
    2. ENERGY: Based on the task mix and stale count, are they in their Zone of Genius or stuck grinding through Zone 3 work?
    3. RELATIONSHIPS: Any commitment debt? Who did they neglect?
    4. CARRY FORWARD: ONE thing to focus on next week.

    Rules:
    - Be specific — reference actual tasks and people by name
    - Be honest but encouraging. Acknowledge wins before pushing on gaps.
    - If completion rate is low or stale tasks are high, name the pattern directly
    - 3 sentences maximum. One per dimension is ideal, combine where natural.
    - No emojis, no fluff, no bullet points — flowing prose

    Respond with ONLY the coaching insight text. No JSON, no labels, no preamble.
    """

    /// Extract a **Key:** value metadata field from markdown content
    private func parseMetadataField(content: String, key: String) -> String? {
        let pattern = "\\*\\*\(NSRegularExpression.escapedPattern(for: key)):\\*\\*\\s*(.+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }

        let range = NSRange(content.startIndex..., in: content)
        guard let match = regex.firstMatch(in: content, range: range),
              let valueRange = Range(match.range(at: 1), in: content) else {
            return nil
        }

        return String(content[valueRange]).trimmingCharacters(in: .whitespaces)
    }

    /// Extract content under a ## Header section (up to next ## or end of file)
    private func parseSection(content: String, header: String) -> String? {
        let lines = content.components(separatedBy: "\n")
        var capturing = false
        var sectionLines: [String] = []

        for line in lines {
            if line.hasPrefix("## ") {
                if capturing {
                    break
                }
                let sectionName = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                if sectionName.lowercased() == header.lowercased() {
                    capturing = true
                    continue
                }
            } else if capturing {
                sectionLines.append(line)
            }
        }

        let result = sectionLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    // MARK: - Skill State (enabled + displayName)

    /// Per-skill state: enabled toggle + optional display name override
    struct SkillState {
        var enabled: Bool
        var displayName: String?

        init(enabled: Bool = true, displayName: String? = nil) {
            self.enabled = enabled
            self.displayName = displayName
        }
    }

    /// Load the enriched state map from disk.
    /// Backward-compatible: old `{ "id": true }` format auto-upgrades to `{ "id": { "enabled": true } }`.
    func loadSkillStates() -> [String: SkillState] {
        guard let data = FileManager.default.contents(atPath: statePath),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return [:]
        }

        guard let dict = json as? [String: Any] else { return [:] }

        var result: [String: SkillState] = [:]
        for (key, value) in dict {
            if let boolVal = value as? Bool {
                // Old format: { "id": true }
                result[key] = SkillState(enabled: boolVal)
            } else if let objVal = value as? [String: Any] {
                // New format: { "id": { "enabled": true, "displayName": "Custom" } }
                let enabled = objVal["enabled"] as? Bool ?? true
                let displayName = objVal["displayName"] as? String
                result[key] = SkillState(enabled: enabled, displayName: displayName)
            }
        }
        return result
    }

    /// Save the enriched state map to disk
    private func saveSkillStates(_ states: [String: SkillState]) {
        var dict: [String: Any] = [:]
        for (key, state) in states {
            var obj: [String: Any] = ["enabled": state.enabled]
            if let displayName = state.displayName {
                obj["displayName"] = displayName
            }
            dict[key] = obj
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: URL(fileURLWithPath: statePath))
    }

    // MARK: - Legacy Compatibility Wrappers

    /// Load enabled state as simple [String: Bool] — used internally by parsing code
    private func loadEnabledState() -> [String: Bool] {
        let states = loadSkillStates()
        return states.mapValues { $0.enabled }
    }

    /// Save enabled state from simple [String: Bool]
    private func saveEnabledState(_ state: [String: Bool]) {
        var states = loadSkillStates()
        for (key, enabled) in state {
            if var existing = states[key] {
                existing.enabled = enabled
                states[key] = existing
            } else {
                states[key] = SkillState(enabled: enabled)
            }
        }
        saveSkillStates(states)
    }

    /// Get the display name override for a skill
    func getDisplayName(id: String) -> String? {
        return loadSkillStates()[id]?.displayName
    }

    /// Set the display name override for a skill (both user and installed)
    func setDisplayName(id: String, displayName: String?) {
        var states = loadSkillStates()
        if var existing = states[id] {
            existing.displayName = displayName
            states[id] = existing
        } else {
            states[id] = SkillState(enabled: true, displayName: displayName)
        }
        saveSkillStates(states)
    }
}
