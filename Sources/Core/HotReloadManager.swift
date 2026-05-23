import Foundation

/// Manages hot-reloadable resources (web UI, prompts, config)
/// Files are served from ~/.config/alfred/ and can be modified without server restart
class HotReloadManager {
    static let shared = HotReloadManager()

    // Base directories
    let configDir: URL
    let webDir: URL
    let promptsDir: URL

    // Source directories (for initial copy)
    let sourceWebDir: URL

    // Cached config (reloadable)
    private var _cachedConfig: AppConfig?
    private let configLock = NSLock()

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.configDir = home.appendingPathComponent(".config/alfred")
        self.webDir = configDir.appendingPathComponent("web")
        self.promptsDir = configDir.appendingPathComponent("prompts")

        // Source directory - where bundled files live during development
        // Resolves relative to the repo checkout; falls back to home dir convention
        #if DEBUG
        self.sourceWebDir = URL(fileURLWithPath: NSString(string: "~/Documents/Claude apps/Alfred/Sources/GUI/Resources").expandingTildeInPath)
        #else
        self.sourceWebDir = Bundle.main.resourceURL ?? home.appendingPathComponent("Documents/Alfred/Sources/GUI/Resources")
        #endif

        // Ensure directories exist
        ensureDirectories()

        // Copy default files if missing
        copyDefaultsIfNeeded()
    }

    // MARK: - Directory Setup

    private func ensureDirectories() {
        let fm = FileManager.default

        do {
            try fm.createDirectory(at: webDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: promptsDir, withIntermediateDirectories: true)
            print("✓ Hot-reload directories ready at ~/.config/alfred/")
        } catch {
            print("⚠️ Failed to create hot-reload directories: \(error)")
        }
    }

    private func copyDefaultsIfNeeded() {
        copyWebFilesIfNeeded()
        copyPromptFilesIfNeeded()
    }

    private func copyWebFilesIfNeeded() {
        let fm = FileManager.default
        let targetIndex = webDir.appendingPathComponent("home.html")

        // Only copy if target doesn't exist
        guard !fm.fileExists(atPath: targetIndex.path) else {
            print("✓ Web UI files already in place at ~/.config/alfred/web/")
            return
        }

        // Copy from source directory
        let webFiles = ["home.html"]

        for file in webFiles {
            let source = sourceWebDir.appendingPathComponent(file)
            let target = webDir.appendingPathComponent(file)

            if fm.fileExists(atPath: source.path) {
                do {
                    try fm.copyItem(at: source, to: target)
                    print("✓ Copied \(file) to ~/.config/alfred/web/")
                } catch {
                    print("⚠️ Failed to copy \(file): \(error)")
                }
            }
        }
    }

    private func copyPromptFilesIfNeeded() {
        let fm = FileManager.default

        // Create default prompt files if they don't exist
        let defaultPrompts: [(String, String)] = [
            ("commitment-extraction.prompt", defaultCommitmentExtractionPrompt),
            ("todo-extraction.prompt", defaultTodoExtractionPrompt),
            ("message-analysis.prompt", defaultMessageAnalysisPrompt)
        ]

        for (filename, content) in defaultPrompts {
            let target = promptsDir.appendingPathComponent(filename)

            if !fm.fileExists(atPath: target.path) {
                do {
                    try content.write(to: target, atomically: true, encoding: .utf8)
                    print("✓ Created default prompt: \(filename)")
                } catch {
                    print("⚠️ Failed to create \(filename): \(error)")
                }
            }
        }
    }

    // MARK: - Web File Serving

    /// Get web file content - reads fresh from disk each time (hot-reloadable)
    func getWebFile(_ filename: String) -> String? {
        let filePath = webDir.appendingPathComponent(filename)

        // First try hot-reload directory
        if let content = try? String(contentsOf: filePath, encoding: .utf8) {
            return content
        }

        // Fallback to source directory (development)
        let sourcePath = sourceWebDir.appendingPathComponent(filename)
        if let content = try? String(contentsOf: sourcePath, encoding: .utf8) {
            return content
        }

        return nil
    }

    /// Get the primary web UI (home.html)
    func getMainWebUI() -> String? {
        return getWebFile("home.html")
    }

    // MARK: - Prompt Loading

    /// Get prompt content - reads fresh from disk each time (hot-reloadable)
    func getPrompt(_ name: String) -> String? {
        let filename = name.hasSuffix(".prompt") ? name : "\(name).prompt"
        let filePath = promptsDir.appendingPathComponent(filename)

        if let content = try? String(contentsOf: filePath, encoding: .utf8) {
            return content
        }

        return nil
    }

    /// Get commitment extraction prompt with variable substitution
    func getCommitmentExtractionPrompt(
        userName: String,
        counterpartyName: String,
        participationLevel: String,
        participationGuidance: String,
        correctionContext: String,
        historicalContext: String,
        messagesText: String
    ) -> String {
        var prompt = getPrompt("commitment-extraction") ?? defaultCommitmentExtractionPrompt

        // Substitute variables
        prompt = prompt.replacingOccurrences(of: "{{USER_NAME}}", with: userName)
        prompt = prompt.replacingOccurrences(of: "{{COUNTERPARTY_NAME}}", with: counterpartyName)
        prompt = prompt.replacingOccurrences(of: "{{PARTICIPATION_LEVEL}}", with: participationLevel)
        prompt = prompt.replacingOccurrences(of: "{{PARTICIPATION_GUIDANCE}}", with: participationGuidance)
        prompt = prompt.replacingOccurrences(of: "{{CORRECTION_CONTEXT}}", with: correctionContext)
        prompt = prompt.replacingOccurrences(of: "{{HISTORICAL_CONTEXT}}", with: historicalContext)
        prompt = prompt.replacingOccurrences(of: "{{MESSAGES_TEXT}}", with: messagesText)

        return prompt
    }

    // MARK: - Config Reloading

    /// Reload configuration from disk
    func reloadConfig() -> AppConfig? {
        configLock.lock()
        defer { configLock.unlock() }

        _cachedConfig = AppConfig.load()
        print("🔄 Config reloaded from disk")
        return _cachedConfig
    }

    /// Get current config (cached, call reloadConfig to refresh)
    var config: AppConfig? {
        configLock.lock()
        defer { configLock.unlock() }

        if _cachedConfig == nil {
            _cachedConfig = AppConfig.load()
        }
        return _cachedConfig
    }

    // MARK: - Status

    /// Get hot-reload status info
    func getStatus() -> [String: Any] {
        let fm = FileManager.default

        var webFiles: [String] = []
        if let contents = try? fm.contentsOfDirectory(atPath: webDir.path) {
            webFiles = contents.filter { $0.hasSuffix(".html") }
        }

        var promptFiles: [String] = []
        if let contents = try? fm.contentsOfDirectory(atPath: promptsDir.path) {
            promptFiles = contents.filter { $0.hasSuffix(".prompt") }
        }

        return [
            "webDir": webDir.path,
            "promptsDir": promptsDir.path,
            "webFiles": webFiles,
            "promptFiles": promptFiles,
            "configPath": configDir.appendingPathComponent("config.json").path
        ]
    }
}

// MARK: - Default Prompts

extension HotReloadManager {

    var defaultCommitmentExtractionPrompt: String {
        """
        You are analyzing a conversation to extract commitments. A commitment is a promise or agreement to do something.

        ## USER PARTICIPATION ANALYSIS
        User name: {{USER_NAME}}
        Participation level: {{PARTICIPATION_LEVEL}}

        {{PARTICIPATION_GUIDANCE}}

        {{HISTORICAL_CONTEXT}}

        ## COMMITMENT TYPES

        1. **I Owe** (commitments made BY the user {{USER_NAME}}):
           - ONLY from messages actually sent by {{USER_NAME}}
           - Look for: "I'll send", "I will share", "Let me get back", "I'll have it ready"

        2. **They Owe Me** (commitments made TO the user by others):
           - Must be explicitly directed at {{USER_NAME}}
           - The other person must commit to delivering something TO the user
           - Commitments between other people (not involving {{USER_NAME}}) should be IGNORED

        For each valid commitment found, extract:
        - type: "i_owe" or "they_owe"
        - title: A brief 3-8 word description
        - commitmentText: The exact phrase containing the commitment
        - committedBy: Name of person making the commitment
        - committedTo: Name of person receiving the commitment
        - dueDate: ISO8601 date if mentioned (e.g., "tomorrow", "Friday", "next week")
        - priority: "critical", "high", "medium", or "low" based on urgency indicators
        - context: Surrounding context from the message
        - confidence: 0.0 to 1.0 score of how confident you are this is a real commitment

        Only extract commitments with confidence >= 0.6.

        {{CORRECTION_CONTEXT}}

        ## COUNTERPARTY
        The other person/group in this conversation is: {{COUNTERPARTY_NAME}}
        Use "{{COUNTERPARTY_NAME}}" (not raw IDs) for committedBy/committedTo fields.

        Conversation:
        {{MESSAGES_TEXT}}

        Return ONLY valid JSON in this exact format:
        {
          "commitments": [
            {
              "type": "i_owe",
              "title": "Send Q4 metrics deck",
              "commitmentText": "I'll send you the Q4 metrics by EOW",
              "committedBy": "{{USER_NAME}}",
              "committedTo": "{{COUNTERPARTY_NAME}}",
              "dueDate": "2026-01-24T23:59:59Z",
              "priority": "high",
              "context": "Discussion about quarterly review",
              "confidence": 0.9
            }
          ]
        }

        If the user is a passive observer with no valid commitments involving them, return: {"commitments": []}
        """
    }

    var defaultTodoExtractionPrompt: String {
        """
        You are analyzing messages to extract actionable todo items.

        Look for:
        - Direct requests or asks
        - Action items mentioned in discussions
        - Follow-up items
        - Deadlines or time-sensitive tasks

        For each todo found, extract:
        - title: A brief 3-8 word description
        - description: More detail about what needs to be done
        - dueDate: ISO8601 date if mentioned
        - priority: "critical", "high", "medium", or "low"
        - source: Where this came from

        Messages:
        {{MESSAGES_TEXT}}

        Return ONLY valid JSON:
        {
          "todos": [
            {
              "title": "Review proposal",
              "description": "Review the Q1 proposal and provide feedback",
              "dueDate": "2026-01-25T17:00:00Z",
              "priority": "high"
            }
          ]
        }
        """
    }

    var defaultMessageAnalysisPrompt: String {
        """
        Analyze the following messages and provide:
        1. A brief summary (2-3 sentences)
        2. Key action items
        3. Urgency level (critical, high, medium, low)
        4. Suggested response if needed

        Messages:
        {{MESSAGES_TEXT}}

        Respond in JSON format:
        {
          "summary": "...",
          "actionItems": ["..."],
          "urgency": "medium",
          "suggestedResponse": "..."
        }
        """
    }
}
