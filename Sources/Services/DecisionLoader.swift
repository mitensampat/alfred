import Foundation

/// Loads decision definitions from Markdown files, mirroring AnalysisLensLoader:
///   ~/.alfred/decisions/user/       — user overrides, fully editable
///   ~/.alfred/decisions/installed/  — Alfred's defaults, written on first run
/// Resolution order is user → installed → built-in, so a missing or malformed file never
/// leaves a caller without a definition.
class DecisionLoader {
    static let shared = DecisionLoader()

    private let userDirectory: String
    private let installedDirectory: String

    private init() {
        let alfredDir = NSString(string: "~/.alfred").expandingTildeInPath
        self.userDirectory = alfredDir + "/decisions/user"
        self.installedDirectory = alfredDir + "/decisions/installed"

        let fm = FileManager.default
        try? fm.createDirectory(atPath: userDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: installedDirectory, withIntermediateDirectories: true)

        installDefaults()
    }

    // MARK: - Public API

    func definition(id: String) -> DecisionDefinition? {
        let builtIn = Self.builtIns.first { $0.id == id }
        for (dir, origin) in [(userDirectory, DecisionOrigin.user), (installedDirectory, .installed)] {
            let path = (dir as NSString).appendingPathComponent("\(id).md")
            if let parsed = parseFile(path: path, origin: origin, builtIn: builtIn) { return parsed }
        }
        return builtIn
    }

    func allDefinitions() -> [DecisionDefinition] {
        var ids = Set(Self.builtIns.map { $0.id })
        let fm = FileManager.default
        for dir in [userDirectory, installedDirectory] {
            for file in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where file.hasSuffix(".md") {
                ids.insert(MarkdownDefinitionParser.idFromFilename(file))
            }
        }
        return ids.sorted().compactMap { definition(id: $0) }
    }

    // MARK: - Parsing

    /// Parse one decision file. For a built-in id the menu is locked to the built-in options
    /// (code maps those labels onto enums); the prompt, thresholds, fallback and model are tunable.
    func parseFile(path: String, origin: DecisionOrigin, builtIn: DecisionDefinition?) -> DecisionDefinition? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8),
              let name = MarkdownDefinitionParser.parseTitle(content: content),
              let prompt = MarkdownDefinitionParser.parseSection(content: content, header: "Prompt") else {
            return nil
        }
        let field = { (key: String) in MarkdownDefinitionParser.parseMetadataField(content: content, key: key) }

        let fileOptions = (field("Options") ?? "")
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let options = builtIn?.options ?? fileOptions
        guard options.count >= 2 else {
            print("[DecisionLoader] Skipping \((path as NSString).lastPathComponent): needs at least two options")
            return nil
        }

        var actAt = field("Act At").flatMap(Double.init) ?? builtIn?.actAt ?? 0.8
        var proposeAt = field("Propose At").flatMap(Double.init) ?? builtIn?.proposeAt ?? 0.5
        actAt = min(max(actAt, 0), 1)
        proposeAt = min(max(proposeAt, 0), actAt)

        return DecisionDefinition(
            id: MarkdownDefinitionParser.idFromFilename(path),
            name: name,
            description: field("Description") ?? builtIn?.description ?? "",
            options: options,
            fallback: field("Fallback") ?? builtIn?.fallback ?? options[0],
            actAt: actAt,
            proposeAt: proposeAt,
            model: field("Model") ?? builtIn?.model ?? Self.defaultModel,
            prompt: prompt,
            origin: origin
        )
    }

    private func installDefaults() {
        let fm = FileManager.default
        for def in Self.builtIns {
            let path = (installedDirectory as NSString).appendingPathComponent("\(def.id).md")
            guard !fm.fileExists(atPath: path) else { continue }
            do {
                try def.toMarkdown().write(toFile: path, atomically: true, encoding: .utf8)
                print("[DecisionLoader] Installed default decision: \(def.id).md")
            } catch {
                print("[DecisionLoader] Failed to install default decision \(def.id).md: \(error)")
            }
        }
    }

    // MARK: - Built-in Decisions

    static let defaultModel = "claude-haiku-4-5-20251001"

    static let builtIns: [DecisionDefinition] = [
        DecisionDefinition(
            id: "belief-durability",
            name: "Belief Durability",
            description: "Sorts self-model statements by how durable they are; fact and action are archived out of beliefs",
            options: ["durable", "tactical", "fact", "action"],
            fallback: "durable",
            actAt: 0.8,
            proposeAt: 0.5,
            model: defaultModel,
            prompt: """
            You are sorting statements from a CEO's self-model. Classify each by durability:

            - durable: a general principle about how they operate, decide, or lead — true across situations, people, and quarters (e.g. "CEO should command strategy and detail first, then let the team fill blanks").
            - tactical: a current thesis or read on a specific business, metric, or market — legitimate now but could flip next quarter (e.g. "Kuvera's right to win is pure distribution").
            - fact: a past event, status, or arrangement — something that happened or is in place, not a stance (e.g. "Secured 100% bank funding for Q2").
            - action: an instruction, todo, or nudge that tells someone to do something (e.g. "Mute the group and set read-only hours").
            """,
            origin: .builtIn
        ),
        DecisionDefinition(
            id: "meeting-category",
            name: "Meeting Category",
            description: "Sorts calendar events by the kind of attention they take",
            options: ["Strategic", "Tactical", "Collaborative", "Informational", "Ceremonial", "Waste"],
            fallback: "Uncategorized",
            actAt: 0.6,
            proposeAt: 0.4,
            model: defaultModel,
            prompt: """
            Categorize each meeting into exactly one category:

            - Strategic: high-value, long-term impact
            - Tactical: important for execution
            - Collaborative: team coordination
            - Informational: status updates, FYIs
            - Ceremonial: could be async
            - Waste: low value
            """,
            origin: .builtIn
        ),
    ]
}
