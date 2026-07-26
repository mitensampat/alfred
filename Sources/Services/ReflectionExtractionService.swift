import Foundation

/// Extracts structured reflection data from raw content using Claude
/// Handles theme normalization against existing themes to prevent near-duplicates
struct ReflectionExtraction {
    let contentSummary: String
    let themes: [String]
    let themeClassifications: [String: String]  // topic → researching|deciding|creating|monitoring
    let openQuestions: [String]
    let mentalModelShifts: [[String: String]]   // [{"from": "...", "to": "..."}]
    let decisions: [String]
}

class ReflectionExtractionService {

    private let claudeService: ClaudeAIService

    init(config: AIConfig) {
        self.claudeService = ClaudeAIService(config: config)
    }

    /// Extract structured reflection data from raw content
    /// - Parameters:
    ///   - rawContent: The text to extract from (browsing clusters, note text, conversation, etc.)
    ///   - source: Where this content came from ("chrome", "youtube", "notion", "claude_export", "manual")
    ///   - existingThemes: Current themes in the store for normalization
    func extract(from rawContent: String, source: String, existingThemes: [String] = []) async throws -> ReflectionExtraction {
        // The established workspaces new activity should attach to — fetched here so every
        // ingestion path gets the anti-fragmentation guidance without threading a param.
        let workspaces = SelfModelService.canonicalWorkspaceNames()
        let systemPrompt = buildSystemPrompt(source: source, existingThemes: existingThemes, workspaces: workspaces)
        let userPrompt = buildUserPrompt(rawContent: rawContent, source: source)

        let response = try await claudeService.generateText(
            prompt: userPrompt,
            system: systemPrompt,
            maxTokens: 1024
        )

        return parseExtraction(response)
    }

    // MARK: - Prompt Construction

    private func buildSystemPrompt(source: String, existingThemes: [String], workspaces: [String] = []) -> String {
        var prompt = """
        You analyze a person's digital activity to understand what they're actively thinking about.
        Your job is to extract structured reflection data — not summarize content, but identify intellectual engagement patterns.

        RULES:
        - Extract only topics showing DELIBERATE ATTENTION — repeated engagement, deep reads, content creation, active research
        - Ignore routine activity (email checking, social scrolling, shopping, admin tasks)
        - Name themes SPECIFICALLY, derived FROM THE CONTENT YOU SEE.
          A theme name should make sense to someone who only read the actual material — not a generic label, not a plausible-sounding placeholder.
          Bad: "technology", "strategy", "finance"
          Better: a concrete noun phrase that names the specific concept being engaged with
            (e.g. if the content is about FY28 revenue trajectory and IPO readiness, name it "FY28 revenue trajectory" or "IPO readiness", NOT "Series A pricing models")
          IMPORTANT: do NOT borrow phrases from these rules. Generate the theme name fresh from the content itself.
        - Classify each theme as: researching (gathering info), deciding (weighing options), creating (producing something), or monitoring (tracking ongoing)
        - Open questions should be specific, not generic. Not "How to grow?" but a question phrased from the content's own vocabulary.
        - Mental model shifts are rare and valuable — only include if there's clear evidence of changed thinking
        """

        if !workspaces.isEmpty {
            prompt += """

            ESTABLISHED WORKSPACES (attach to these):
            These are ongoing subjects the person is actively working on. If the new content is about one of them — even a different metric, week, angle, or update of the SAME subject — reuse that workspace's EXACT name. A new metric or diagnostic angle of an existing workspace is NOT a new theme; it belongs to the workspace.
            Only create a new theme when the content is a genuinely NEW subject not represented below.
            Workspaces: \(workspaces.joined(separator: "; "))
            """
        }

        if !existingThemes.isEmpty {
            prompt += """

            THEME NORMALIZATION:
            Below is a list of themes already in the store. If — and ONLY if — the new content is genuinely about the SAME underlying topic as an existing theme, reuse that exact name to avoid near-duplicates (e.g. don't create "SaaS pricing" when "pricing strategy" already covers it).
            Do NOT force a match. If the content's actual subject doesn't fit any existing theme, create a new theme name derived from the content. A misleading reuse is worse than a new theme.
            Test: would someone reading only the new content agree this existing theme name describes it? If not, make a new theme.
            Existing themes: \(existingThemes.joined(separator: ", "))
            """
        }

        prompt += """

        Respond with ONLY valid JSON in this exact format:
        {
            "content_summary": "2-3 sentence summary of what this person was focused on",
            "themes": ["specific theme 1", "specific theme 2"],
            "theme_classifications": {"specific theme 1": "researching", "specific theme 2": "deciding"},
            "open_questions": ["Specific question they seem to be wrestling with"],
            "mental_model_shifts": [{"from": "previous belief", "to": "new understanding"}],
            "decisions": ["Any conclusions or decisions evident in the content"]
        }

        If there is no meaningful intellectual signal in the content, return:
        {"content_summary": "", "themes": [], "theme_classifications": {}, "open_questions": [], "mental_model_shifts": [], "decisions": []}
        """

        return prompt
    }

    private func buildUserPrompt(rawContent: String, source: String) -> String {
        let sourceContext: String
        switch source {
        case "chrome":
            sourceContext = "This is a person's browsing history from the last 24 hours (filtered to remove noise). URLs are clustered by domain. Look for patterns of deliberate attention — topics visited multiple times, deep reads, active research."
        case "youtube":
            sourceContext = "This is a transcript from a YouTube video the person watched. Extract the key intellectual themes they were engaging with. Focus on ideas that would shape their thinking, not surface-level entertainment."
        case "notion":
            sourceContext = "This is content from the person's personal notes/journal (Notion Second Brain). This is their own writing — high signal. Extract what they're thinking about, deciding on, and questioning."
        case "claude_export":
            sourceContext = "This is a conversation the person had with Claude AI. This represents their deepest thinking — they chose to explore these topics deliberately. Extract key conclusions, open questions, and evolving mental models."
        case "conversation":
            sourceContext = "This is a reflection conversation the person had with their AI coaching assistant. Extract insights, conclusions, and open threads."
        default:
            sourceContext = "This is content the person explicitly shared for reflection. Treat it as high signal."
        }

        // Truncate to avoid massive prompts
        let truncated = String(rawContent.prefix(8000))

        return """
        \(sourceContext)

        ---
        \(truncated)
        ---

        Extract the structured reflection data from this content.
        """
    }

    // MARK: - Response Parsing

    private func parseExtraction(_ response: String) -> ReflectionExtraction {
        // Try to extract JSON from response (may have markdown wrapping)
        let jsonString = extractJSON(from: response) ?? response

        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("⚠️ ReflectionExtraction: Failed to parse response as JSON")
            return ReflectionExtraction(
                contentSummary: "",
                themes: [],
                themeClassifications: [:],
                openQuestions: [],
                mentalModelShifts: [],
                decisions: []
            )
        }

        let contentSummary = json["content_summary"] as? String ?? ""
        let themes = json["themes"] as? [String] ?? []
        let themeClassifications = json["theme_classifications"] as? [String: String] ?? [:]
        let openQuestions = json["open_questions"] as? [String] ?? []
        let mentalModelShifts = json["mental_model_shifts"] as? [[String: String]] ?? []
        let decisions = json["decisions"] as? [String] ?? []

        return ReflectionExtraction(
            contentSummary: contentSummary,
            themes: themes,
            themeClassifications: themeClassifications,
            openQuestions: openQuestions,
            mentalModelShifts: mentalModelShifts,
            decisions: decisions
        )
    }

    private func extractJSON(from text: String) -> String? {
        // Try to find JSON block in markdown code fence
        if let range = text.range(of: "```json\n"),
           let endRange = text.range(of: "\n```", range: range.upperBound..<text.endIndex) {
            return String(text[range.upperBound..<endRange.lowerBound])
        }
        if let range = text.range(of: "```\n"),
           let endRange = text.range(of: "\n```", range: range.upperBound..<text.endIndex) {
            return String(text[range.upperBound..<endRange.lowerBound])
        }
        // Try raw JSON (starts with {)
        if let start = text.firstIndex(of: "{"),
           let end = text.lastIndex(of: "}") {
            return String(text[start...end])
        }
        return nil
    }
}
