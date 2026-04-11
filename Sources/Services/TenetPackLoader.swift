import Foundation

/// Loads and manages coaching tenet packs from Markdown files.
/// Two-tier directory structure:
///   ~/.alfred/tenets/user/       — user-created, fully editable
///   ~/.alfred/tenets/installed/  — coach-authored, read-only (toggle only)
/// State file: ~/.alfred/tenets_state.json
class TenetPackLoader {
    static let shared = TenetPackLoader()

    private let baseDirectory: String
    private let userDirectory: String
    private let installedDirectory: String
    private let statePath: String

    private init() {
        let alfredDir = NSString(string: "~/.alfred").expandingTildeInPath
        self.baseDirectory = alfredDir + "/tenets"
        self.userDirectory = alfredDir + "/tenets/user"
        self.installedDirectory = alfredDir + "/tenets/installed"
        self.statePath = alfredDir + "/tenets_state.json"

        // Ensure both directories exist
        let fm = FileManager.default
        try? fm.createDirectory(atPath: userDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: installedDirectory, withIntermediateDirectories: true)

        // Install default tenet packs (migrated from tenet-only skills)
        installDefaultTenetPacks()
    }

    // MARK: - Public API

    /// Load all tenet pack definitions from both user/ and installed/ directories
    func loadTenetPacks() -> [TenetPackDefinition] {
        let enabledState = loadEnabledState()
        var packs: [TenetPackDefinition] = []

        packs.append(contentsOf: loadPacksFromDirectory(userDirectory, origin: .user, enabledState: enabledState))
        packs.append(contentsOf: loadPacksFromDirectory(installedDirectory, origin: .installed, enabledState: enabledState))

        return packs.sorted { $0.name < $1.name }
    }

    /// Load only enabled tenet packs
    func getEnabledTenetPacks() -> [TenetPackDefinition] {
        return loadTenetPacks().filter { $0.enabled }
    }

    /// Get enabled tenets filtered by scope — returns packs that apply to a given capability
    func getTenetsForScope(_ capability: String) -> [TenetPackDefinition] {
        return getEnabledTenetPacks().filter { pack in
            pack.scope.contains("all") || pack.scope.contains(capability.lowercased())
        }
    }

    /// Get the combined principles text for a given scope
    func getPrinciplesForScope(_ capability: String) -> String {
        let packs = getTenetsForScope(capability)
        guard !packs.isEmpty else { return "" }

        return packs.map { pack in
            "### \(pack.name)\n\(pack.principles)"
        }.joined(separator: "\n\n")
    }

    /// Toggle a tenet pack's enabled/disabled state
    func toggleTenetPack(id: String) -> Bool {
        var state = loadEnabledState()
        let currentlyEnabled = state[id] ?? true
        state[id] = !currentlyEnabled
        saveEnabledState(state)
        return !currentlyEnabled
    }

    /// Set a tenet pack's enabled state explicitly
    func setTenetPackEnabled(id: String, enabled: Bool) {
        var state = loadEnabledState()
        state[id] = enabled
        saveEnabledState(state)
    }

    /// Get a single tenet pack by ID
    func getTenetPack(id: String) -> TenetPackDefinition? {
        return loadTenetPacks().first { $0.id == id }
    }

    // MARK: - CRUD Operations (user packs only)

    /// Create a new user tenet pack. Returns the created pack or nil on error.
    func createTenetPack(name: String, description: String, icon: String,
                         scope: [String], principles: String) -> TenetPackDefinition? {
        let id = MarkdownDefinitionParser.slugFromName(name)
        guard !id.isEmpty else { return nil }

        let pack = TenetPackDefinition(
            id: id, name: name, description: description, icon: icon,
            author: nil, version: nil, scope: scope, principles: principles,
            enabled: true, origin: .user
        )

        let filePath = (userDirectory as NSString).appendingPathComponent("\(id).md")

        guard !FileManager.default.fileExists(atPath: filePath) else {
            print("[TenetPackLoader] Tenet pack file already exists: \(id).md")
            return nil
        }

        let content = pack.toMarkdown()
        do {
            try content.write(toFile: filePath, atomically: true, encoding: .utf8)
            return pack
        } catch {
            print("[TenetPackLoader] Failed to write tenet pack file: \(error)")
            return nil
        }
    }

    /// Update an existing user tenet pack. Returns updated pack or nil if not found.
    func updateTenetPack(id: String, name: String?, description: String?, icon: String?,
                         scope: [String]?, principles: String?) -> TenetPackDefinition? {
        let filePath = (userDirectory as NSString).appendingPathComponent("\(id).md")
        guard FileManager.default.fileExists(atPath: filePath) else {
            print("[TenetPackLoader] Cannot update: tenet pack '\(id)' not found in user directory")
            return nil
        }

        guard let current = parsePackFile(path: filePath, origin: .user) else { return nil }

        let updated = TenetPackDefinition(
            id: id,
            name: name ?? current.name,
            description: description ?? current.description,
            icon: icon ?? current.icon,
            author: nil,
            version: nil,
            scope: scope ?? current.scope,
            principles: principles ?? current.principles,
            enabled: current.enabled,
            origin: .user
        )

        let content = updated.toMarkdown()
        do {
            try content.write(toFile: filePath, atomically: true, encoding: .utf8)
            return updated
        } catch {
            print("[TenetPackLoader] Failed to update tenet pack file: \(error)")
            return nil
        }
    }

    /// Delete a user tenet pack. Returns true if deleted.
    func deleteTenetPack(id: String) -> Bool {
        let filePath = (userDirectory as NSString).appendingPathComponent("\(id).md")
        guard FileManager.default.fileExists(atPath: filePath) else {
            print("[TenetPackLoader] Cannot delete: tenet pack '\(id)' not found in user directory")
            return false
        }

        do {
            try FileManager.default.removeItem(atPath: filePath)
            var state = loadEnabledState()
            state.removeValue(forKey: id)
            saveEnabledState(state)
            return true
        } catch {
            print("[TenetPackLoader] Failed to delete tenet pack: \(error)")
            return false
        }
    }

    // MARK: - Markdown Parsing

    /// Parse a single tenet pack Markdown file into a TenetPackDefinition
    func parsePackFile(path: String, origin: TenetPackOrigin, enabledState: [String: Bool]? = nil) -> TenetPackDefinition? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }

        let id = MarkdownDefinitionParser.idFromFilename(path)

        guard let name = MarkdownDefinitionParser.parseTitle(content: content) else {
            print("[TenetPackLoader] Skipping \((path as NSString).lastPathComponent): no title found")
            return nil
        }

        let description = MarkdownDefinitionParser.parseMetadataField(content: content, key: "Description") ?? ""
        let icon = MarkdownDefinitionParser.parseMetadataField(content: content, key: "Icon") ?? "📜"
        let author = MarkdownDefinitionParser.parseMetadataField(content: content, key: "Author")
        let version = MarkdownDefinitionParser.parseMetadataField(content: content, key: "Version")
        let scopeRaw = MarkdownDefinitionParser.parseMetadataField(content: content, key: "Scope") ?? "all"

        let scope = scopeRaw
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }

        let principles = MarkdownDefinitionParser.parseSection(content: content, header: "Principles") ?? ""

        guard !principles.isEmpty else {
            print("[TenetPackLoader] Skipping \((path as NSString).lastPathComponent): no ## Principles section found")
            return nil
        }

        let state = enabledState ?? loadEnabledState()
        let enabled = state[id] ?? true

        return TenetPackDefinition(
            id: id, name: name, description: description, icon: icon,
            author: author, version: version, scope: scope, principles: principles,
            enabled: enabled, origin: origin
        )
    }

    // MARK: - Private Helpers

    private func loadPacksFromDirectory(_ directory: String, origin: TenetPackOrigin,
                                         enabledState: [String: Bool]) -> [TenetPackDefinition] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: directory) else { return [] }

        return files
            .filter { $0.hasSuffix(".md") }
            .compactMap { filename -> TenetPackDefinition? in
                let path = (directory as NSString).appendingPathComponent(filename)
                return parsePackFile(path: path, origin: origin, enabledState: enabledState)
            }
    }

    private func loadEnabledState() -> [String: Bool] {
        guard let data = FileManager.default.contents(atPath: statePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Bool] else {
            return [:]
        }
        return json
    }

    private func saveEnabledState(_ state: [String: Bool]) {
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: URL(fileURLWithPath: statePath))
    }

    // MARK: - Default Tenet Packs

    /// Install default tenet packs if they don't already exist.
    /// These are migrated from the tenet-only skills that previously lived in SkillLoader.
    private func installDefaultTenetPacks() {
        let fm = FileManager.default

        let defaults: [(filename: String, content: String)] = [
            ("alfred-rules.md", Self.alfredRulesPack),
            ("alfred-voice.md", Self.alfredVoicePack),
            ("campbell-rules.md", Self.campbellRulesPack),
            ("mochary-rules.md", Self.mocharyRulesPack),
        ]

        for (filename, content) in defaults {
            let filePath = (installedDirectory as NSString).appendingPathComponent(filename)
            guard !fm.fileExists(atPath: filePath) else { continue }

            do {
                try content.write(toFile: filePath, atomically: true, encoding: .utf8)
                print("[TenetPackLoader] Installed default tenet pack: \(filename)")
            } catch {
                print("[TenetPackLoader] Failed to install default tenet pack \(filename): \(error)")
            }
        }
    }

    // MARK: - Default Tenet Pack Content

    private static let alfredRulesPack = """
    # Alfred Core Rules

    **Description:** Foundational coaching rules that apply to all Alfred interactions
    **Icon:** 🏛️
    **Author:** Alfred
    **Version:** 1.0
    **Scope:** all

    ## Principles
    - Be a coach, not an assistant. Ask questions that provoke insight rather than just executing tasks.
    - Never invent data. If no signal exists in the context, say "No clear signal today" rather than fabricating observations.
    - Reference specific tasks, people, and dates by name — only when they appear in the provided context data.
    - Maximum 2 sentences per coaching card. Density over length.
    - No emojis in coaching output. Clean, plain language.
    - Acknowledge wins before pushing on gaps. People need to see progress to stay motivated.
    - One concrete next step beats a list of aspirations. Always end with something actionable.
    - When the user teaches a rule or preference, it takes effect immediately and permanently.
    """

    private static let alfredVoicePack = """
    # Alfred Voice & Tone

    **Description:** How Alfred communicates — direct, warm, no fluff
    **Icon:** 🗣️
    **Author:** Alfred
    **Version:** 1.0
    **Scope:** all

    ## Principles
    - Speak like a trusted advisor over coffee, not a corporate consultant delivering a report.
    - Be direct. "You're avoiding X" is better than "It might be worth considering whether X deserves attention."
    - Use the person's actual task names and contact names. Specificity builds trust.
    - No bullet points in coaching cards. Flowing prose, 1-2 sentences.
    - Empathetic but honest. Don't soften the message to the point of losing it.
    - Match energy: if the data shows urgency (overdue, piling up), the tone should reflect that.
    - Never use corporate jargon: no "synergies", "leverage" as a verb, "circle back", or "touch base".
    """

    private static let campbellRulesPack = """
    # Bill Campbell Coaching Rules

    **Description:** Trillion Dollar Coach principles — people first, radical candor, operational excellence
    **Icon:** 🏈
    **Author:** Bill Campbell Method
    **Version:** 1.0
    **Scope:** relationship, leverage

    ## Principles
    - People come first. Before discussing tasks, consider who needs support or recognition.
    - Radical candor: care personally AND challenge directly. One without the other fails.
    - The highest-leverage action is almost always unblocking someone else, not doing more yourself.
    - Trust is built in small moments — following through on commitments, remembering details, being present.
    - When someone is waiting on you, that's almost always the highest priority. Responsiveness signals respect.
    - Brilliant jerks are not worth the cost. Culture eats strategy.
    - Coach the person, not the problem. Help them develop judgment, not just get the answer.
    """

    private static let mocharyRulesPack = """
    # Matt Mochary Coaching Rules

    **Description:** Mochary Method principles — energy audit, avoidance confrontation, Zone of Genius
    **Icon:** ⚡
    **Author:** Matt Mochary Method
    **Version:** 1.0
    **Scope:** avoidance, attention, weekly-review

    ## Principles
    - Zone of Genius: spend maximum time on work that energizes you. Delegate or drop everything else.
    - Avoidance is the root of most productivity problems. Name what you're avoiding and why.
    - Tasks untouched for 14+ days are being avoided. After 21 days, confront directly: do it or drop it.
    - Energy audit: track what gives energy vs. what drains it. The pattern reveals your Zone of Genius.
    - Fear and anger are the two emotions that drive avoidance. Name the emotion to break the pattern.
    - Weekly review: wins → energy → relationships → one carry-forward. In that order, every week.
    - A CEO's job is to make decisions quickly and remove blockers. Everything else can be delegated.
    - Inbox zero and calendar zero are prerequisites for clear thinking, not nice-to-haves.
    """
}
