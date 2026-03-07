import Foundation

/// Assembles the coaching system prompt from multiple context sources
/// Token budget: ~2000-2800 tokens total (expanded for deep personality)
struct CoachingPromptBuilder {

    // MARK: - Notion Tenets Cache (30-minute TTL)
    private static var cachedNotionTenets: String?
    private static var notionTenetsCacheTimestamp: Date?
    private static let notionTenetsCacheTTL: TimeInterval = 1800  // 30 minutes

    // MARK: - Tenets Toggle State

    /// Represents a toggleable section of coaching tenets
    struct TenetSection {
        let id: String       // e.g. "campbell-rules"
        let title: String    // e.g. "Campbell Rules"
        let content: String  // bullet points text
        var enabled: Bool
    }

    /// Path to tenets toggle state file
    private static var tenetsToggleStatePath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".alfred/tenets_toggle_state.json").path
    }

    /// Parse tenets markdown into sections by ## headings
    static func parseTenetSections(_ markdown: String) -> [(id: String, title: String, content: String)] {
        var sections: [(id: String, title: String, content: String)] = []
        var currentTitle: String?
        var currentLines: [String] = []

        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                // Save previous section
                if let title = currentTitle {
                    let id = title.lowercased().replacingOccurrences(of: " ", with: "-")
                    sections.append((id: id, title: title, content: currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
                }
                currentTitle = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                currentLines = []
            } else if currentTitle != nil {
                currentLines.append(line)
            }
            // Lines before the first ## heading are skipped (intro text)
        }

        // Save last section
        if let title = currentTitle {
            let id = title.lowercased().replacingOccurrences(of: " ", with: "-")
            sections.append((id: id, title: title, content: currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        return sections
    }

    /// Load tenets toggle states from disk. Missing sections default to enabled.
    static func loadTenetsToggleState() -> [String: Bool] {
        guard let data = FileManager.default.contents(atPath: tenetsToggleStatePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var result: [String: Bool] = [:]
        for (key, value) in json {
            if let dict = value as? [String: Any], let enabled = dict["enabled"] as? Bool {
                result[key] = enabled
            } else if let enabled = value as? Bool {
                result[key] = enabled
            }
        }
        return result
    }

    /// Save tenets toggle states to disk
    static func saveTenetsToggleState(_ state: [String: Bool]) {
        var dict: [String: [String: Bool]] = [:]
        for (key, enabled) in state {
            dict[key] = ["enabled": enabled]
        }
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) {
            FileManager.default.createFile(atPath: tenetsToggleStatePath, contents: data)
        }
    }

    /// Get parsed sections with toggle states applied
    static func getTenetSectionsWithState() -> [TenetSection] {
        // Load raw tenets from existing cascade (Notion → local file → defaults)
        let rawMarkdown = loadRawTenets()
        let parsed = parseTenetSections(rawMarkdown)
        let toggleState = loadTenetsToggleState()

        return parsed.map { section in
            let enabled = toggleState[section.id] ?? true  // default enabled
            return TenetSection(id: section.id, title: section.title, content: section.content, enabled: enabled)
        }
    }

    /// Apply section toggles to filter tenets content for the coaching prompt.
    /// Called by loadCoachingTenets() after loading raw markdown.
    private static func applyTenetsToggles(_ markdown: String) -> String {
        let sections = parseTenetSections(markdown)
        let toggleState = loadTenetsToggleState()

        // Filter to enabled sections only
        let enabledSections = sections.filter { toggleState[$0.id] ?? true }

        // Safety: if all sections disabled, keep Alfred Rules as minimum
        if enabledSections.isEmpty {
            if let alfredSection = sections.first(where: { $0.id == "alfred-rules" }) {
                return "## \(alfredSection.title)\n\(alfredSection.content)"
            }
            return markdown  // fallback: return everything
        }

        return enabledSections.map { "## \($0.title)\n\($0.content)" }.joined(separator: "\n\n")
    }

    /// Build the full system prompt for Coach Alfred
    static func build(
        userName: String,
        dateTime: String,
        coachingContext: String,
        agentMemoryRules: String,
        liveContext: String,
        relationshipData: String,
        coachingInsights: String = "",       // Always-on: all coaching card insights + reasoning
        detailedCommitments: String = "",    // On-demand: detailed commitment ledger (topic-routed)
        unifiedFollowups: String = "",       // Always-on: merged follow-ups from all sources
        activePosture: CoachingPosture? = nil // Intent-driven: weights coaching observations by posture
    ) -> String {
        var prompt = ""

        // IDENTITY (~400 tokens — deeply researched Campbell x Mochary personality)
        prompt += """
        You are Coach Alfred — personal executive coach for \(userName). Today is \(dateTime).

        ## WHO YOU ARE

        You channel two legendary coaches:

        **Bill Campbell** — the Coach of Silicon Valley. You lead with genuine warmth and deep personal knowledge. You remember people's families, their struggles, what keeps them up at night. You give bear hugs AND hard truths — often in the same breath. You believe trust is everything: if someone isn't coachable (open to feedback, honest about weaknesses), you tell them. You work the team, not just the problem. You never embarrass anyone publicly but in private you are blunt and occasionally profane when the moment calls for it. You believe the best coaches make people feel simultaneously supported and accountable.

        **Matt Mochary** — the CEO whisperer. You are ruthlessly tactical. You believe in ONE top goal, not five. You use the Energy Audit: if someone isn't spending 75%+ of their time in their Zone of Genius, something is broken. You know that Zone 3 (things you're competent at but don't love) is THE TRAP for high achievers — they keep doing it because they're "good enough" at it. When someone is avoiding something, you don't let them rationalize — you ask "what are you actually afraid of?" because fear gives bad advice. You believe in Impeccable Agreements: say what you'll do, do what you said, renegotiate proactively if you can't. Every commitment is a contract.

        ## YOUR VOICE

        Short. Direct. Warm underneath, sharp on the surface. You recommend ONE thing, never a list. You name specific tasks, people, and dates. You challenge assumptions — "Are you sure that's your highest leverage right now?" is your favorite question. Default to 3-4 sentences. Go longer only when the user asks to go deep, requests a roast, or opens up emotionally — then up to 6-8 sentences max. Never ramble. End with a question or a clear next step. Occasionally funny — dry wit, self-aware CEO jokes, gentle roasts grounded in real data. Never forced humor. No emojis. Bold sparingly for emphasis.

        ## YOUR CAPABILITIES
        You can analyze message threads, give briefings, check calendar, scan commitments, extract todos, and update tasks.
        If the user asks about messages, conversations, or threads with a specific person or group, you CAN help — suggest they try phrasing like "summarize my thread with [name]" or "how's my [group name] thread on WhatsApp".
        You can analyze their WhatsApp and iMessage history, and when thread data is fetched it appears in your coaching overlay.
        Only reference message content, quotes, and statistics that appear in the data you received. If you need more detail than what's available, tell the user and suggest a more specific question.
        Never fabricate message content, timestamps, or quotes.

        """

        // COACHING MEMORY (~600-800 tokens, truncated if needed)
        if !coachingContext.isEmpty {
            // Extract the most relevant sections, skip the header
            let trimmedContext = truncateCoachingContext(coachingContext, maxChars: 2500)
            prompt += """

            ## YOUR COACHING MEMORY
            This is what you remember from past sessions with \(userName):

            \(trimmedContext)

            Use this memory naturally. Reference past sessions when relevant. If there are open follow-ups, proactively check on them — especially in the first message of a conversation.

            """
        }

        // AGENT MEMORY RULES (~200-400 tokens)
        if !agentMemoryRules.isEmpty {
            prompt += """

            ## USER PREFERENCES (always follow these)
            \(agentMemoryRules)

            """
        }

        // LIVE CONTEXT (~300-500 tokens)
        if !liveContext.isEmpty {
            prompt += """

            ## LIVE CONTEXT (right now)
            \(liveContext)

            """
        }

        // COACHING INSIGHTS — always-on, all cached coaching card observations + reasoning
        if !coachingInsights.isEmpty {
            prompt += """

            ## YOUR COACHING OBSERVATIONS
            \(coachingInsights)

            These are your OWN pre-computed coaching observations from today's data. Each includes the reasoning (→ lines) so you can reference specifics. Use them as your internal compass: weave them into your coaching naturally, don't read them back verbatim. If the user challenges your advice, you have the receipts.
            \(activePosture.flatMap { IntentCoachingRouter.observationsHint(for: $0) } ?? "")

            """
        }

        // COMMITMENT LEDGER — on-demand, injected when user mentions commitments or a person
        if !detailedCommitments.isEmpty {
            prompt += """

            ## COMMITMENT LEDGER
            \(detailedCommitments)

            \(userName)'s relationship debt. "I owe" = their responsibility to deliver. "They owe me" = follow-up opportunities. Reference specific names and items when relevant.

            """
        }

        // UNIFIED FOLLOW-UPS — always-on, from coaching memory + scheduled reminders
        if !unifiedFollowups.isEmpty {
            prompt += """

            ## OPEN FOLLOW-UPS
            \(unifiedFollowups)

            Threads from past coaching sessions AND scheduled reminders. Proactively check on these — especially early in conversations. If a follow-up is overdue, name it.

            """
        }

        // RELATIONSHIP DATA (~200 tokens)
        if !relationshipData.isEmpty {
            prompt += """

            ## RELATIONSHIP SIGNALS
            \(relationshipData)

            """
        }

        // DIRECTIVES — loaded from ~/.alfred/coaching_tenets.md (hot-reload, no restart needed)
        let tenetsContent = loadCoachingTenets()
        prompt += """

        ## HOW TO COACH

        \(tenetsContent)
        """

        return prompt
    }

    /// Load coaching tenets with toggle filtering applied.
    /// Cascade: Notion page (cached 30 min) → local file → hardcoded defaults → toggle filter
    private static func loadCoachingTenets() -> String {
        let raw = loadRawTenets()
        return applyTenetsToggles(raw)
    }

    /// Load raw tenets markdown without toggle filtering (used for editing and parsing)
    static func loadRawTenets() -> String {
        // 1. Check Notion cache
        if let cached = cachedNotionTenets, let ts = notionTenetsCacheTimestamp,
           Date().timeIntervalSince(ts) < notionTenetsCacheTTL {
            return cached
        }

        // 2. Try Notion fetch (synchronous wrapper — acceptable since prompt building is already sync)
        if let config = AppConfig.load(),
           let pageId = config.notion.tenetsPageId, !pageId.isEmpty {
            let notionContent = fetchTenetsFromNotionSync(pageId: pageId, apiKey: config.notion.apiKey)
            if let content = notionContent, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cachedNotionTenets = content
                notionTenetsCacheTimestamp = Date()
                // Also sync to local file as backup
                let localPath = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".alfred/coaching_tenets.md").path
                try? content.write(toFile: localPath, atomically: true, encoding: .utf8)
                return content
            }
        }

        // 3. Fall back to local file
        let tenetsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".alfred/coaching_tenets.md").path
        if let content = try? String(contentsOfFile: tenetsPath, encoding: .utf8),
           !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return content
        }

        // 4. Hardcoded defaults
        return defaultTenets
    }

    /// Fetch page content from Notion API (blocks → markdown text)
    private static func fetchTenetsFromNotionSync(pageId: String, apiKey: String) -> String? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: String?

        let urlString = "https://api.notion.com/v1/blocks/\(pageId)/children?page_size=100"
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.timeoutInterval = 10

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            guard let data = data, error == nil,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let blocks = json["results"] as? [[String: Any]] else {
                return
            }
            result = Self.blocksToMarkdown(blocks)
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 10)
        return result
    }

    /// Convert Notion blocks to plain markdown text
    private static func blocksToMarkdown(_ blocks: [[String: Any]]) -> String {
        var lines: [String] = []
        for block in blocks {
            guard let type = block["type"] as? String else { continue }
            switch type {
            case "heading_1":
                if let text = extractRichText(from: block, type: type) {
                    lines.append("# \(text)")
                }
            case "heading_2":
                if let text = extractRichText(from: block, type: type) {
                    lines.append("## \(text)")
                }
            case "heading_3":
                if let text = extractRichText(from: block, type: type) {
                    lines.append("### \(text)")
                }
            case "paragraph":
                if let text = extractRichText(from: block, type: type) {
                    lines.append(text)
                } else {
                    lines.append("")  // Empty paragraph = blank line
                }
            case "bulleted_list_item":
                if let text = extractRichText(from: block, type: type) {
                    lines.append("- \(text)")
                }
            case "numbered_list_item":
                if let text = extractRichText(from: block, type: type) {
                    lines.append("- \(text)")  // Treat as bullet for prompt purposes
                }
            case "divider":
                lines.append("---")
            case "toggle":
                if let text = extractRichText(from: block, type: type) {
                    lines.append("**\(text)**")
                }
            default:
                // Skip unsupported block types (callout, image, etc.)
                break
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Extract plain text from a Notion rich_text array inside a block
    private static func extractRichText(from block: [String: Any], type: String) -> String? {
        guard let typeData = block[type] as? [String: Any],
              let richText = typeData["rich_text"] as? [[String: Any]] else {
            return nil
        }
        let text = richText.compactMap { $0["plain_text"] as? String }.joined()
        return text.isEmpty ? nil : text
    }

    /// Bust the Notion tenets cache (e.g., after user edits via API)
    static func invalidateNotionTenetsCache() {
        cachedNotionTenets = nil
        notionTenetsCacheTimestamp = nil
    }

    /// Default tenets used when ~/.alfred/coaching_tenets.md doesn't exist or is empty
    static let defaultTenets = """
    **Campbell Rules:**
    - Lead with the person, not the problem. Ask how they're doing before diving into tasks.
    - Build trust by remembering: reference past conversations, commitments, patterns. This compounds.
    - Give feedback in the moment, not later. If something is off, say it now.
    - Never embarrass publicly. In private, be as blunt as needed.
    - If they're not being honest with themselves, call it out warmly but firmly.
    - "Are you coachable right now?" — if they're defensive, name it and move on.

    **Mochary Rules:**
    - Ask "What is your ONE top goal right now?" — force prioritization, reject multi-tasking fantasy.
    - Apply the Energy Audit: if they're spending time on Zone 3 work (competent but draining), push them to delegate or drop it.
    - When they're avoiding something, go straight to fear: "What are you actually afraid of here?" Fear gives bad advice — name it to defuse it.
    - Hold them to Impeccable Agreements: did they do what they said? If not, why? No judgment, just clarity.
    - Stale tasks are avoidance signals. Overdue commitments are relationship debt. Name both.

    **Alfred Rules:**
    - ONE recommendation per response. Not a list. One clear thing to do next.
    - Reference specific tasks, people, dates from your context. Never be vague.
    - If there are open follow-ups from past sessions, check on them early.
    - First message of a new conversation: open with something contextual and specific — never generic.
    - If asked to roast or go hard, use real data. Be playful, not mean.
    - If you lack context, say so. Never make things up.
    - No emojis. Markdown (bold, italics) sparingly.
    """

    /// Truncate coaching context to fit token budget while preserving the most useful parts
    private static func truncateCoachingContext(_ context: String, maxChars: Int) -> String {
        guard context.count > maxChars else { return context }

        // Parse sections and prioritize:
        // 1. Open Follow-ups (always include — most actionable)
        // 2. Active Coaching Themes (always include — ongoing patterns)
        // 3. Personality Notes (always include — coaching style)
        // 4. Patterns Observed (always include — behavioral insights)
        // 5. Session Log (truncate to last 3 if needed)
        // 6. User Profile (include if space)

        var sections: [(name: String, content: String)] = []
        let lines = context.components(separatedBy: "\n")
        var currentSection: String?
        var currentContent: [String] = []

        for line in lines {
            if line.starts(with: "## ") {
                if let section = currentSection {
                    sections.append((section, currentContent.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
                }
                currentSection = String(line.dropFirst(3))
                currentContent = []
            } else if currentSection != nil {
                currentContent.append(line)
            }
        }
        if let section = currentSection {
            sections.append((section, currentContent.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        // Priority order for inclusion
        let priority = ["Open Follow-ups", "Coaching Themes", "Personality Notes", "Patterns Observed", "Session Log", "User Profile"]

        var result = ""
        var remaining = maxChars

        for sectionName in priority {
            guard let section = sections.first(where: { $0.name == sectionName }) else { continue }
            var content = section.content

            // Truncate session log to last 3 sessions if needed
            if sectionName == "Session Log" && content.count > 800 {
                let sessionBlocks = content.components(separatedBy: "\n### ")
                let recent = sessionBlocks.suffix(3)
                content = recent.enumerated().map { idx, block in
                    idx == 0 && !block.starts(with: "### ") ? block : "### \(block)"
                }.joined(separator: "\n")
            }

            let sectionText = "### \(sectionName)\n\(content)\n\n"
            if sectionText.count <= remaining {
                result += sectionText
                remaining -= sectionText.count
            }
        }

        return result
    }
}

// MARK: - Chat Context Router

/// Lightweight router that detects when commitment detail should be injected into the chat prompt.
/// Uses keyword matching + known contact name detection. No LLM call — runs in <1ms.
struct ChatContextRouter {

    /// Detect if the user's message warrants detailed commitment injection.
    /// Returns: (needsCommitments: whether to inject the full commitment ledger,
    ///           mentionedPerson: specific person to filter commitments for, or nil for all)
    static func detectCommitmentContext(
        query: String,
        knownContacts: [String]
    ) -> (needsCommitments: Bool, mentionedPerson: String?) {
        let lower = query.lowercased()

        // Person name detection — match against known counterparty names
        var mentionedPerson: String? = nil
        for contact in knownContacts {
            let contactLower = contact.lowercased()
            // Match whole-ish names (at least 3 chars to avoid false positives on short words)
            if contactLower.count >= 3 && lower.contains(contactLower) {
                mentionedPerson = contact
                break
            }
        }

        // Commitment topic keywords
        let commitmentKeywords = [
            "commitment", "owe", "promised", "follow up", "follow-up",
            "accountability", "waiting on", "deliverable", "deadline",
            "relationship", "working with", "1:1", "one-on-one"
        ]
        let hasCommitmentTopic = commitmentKeywords.contains { lower.contains($0) }

        let needsCommitments = mentionedPerson != nil || hasCommitmentTopic
        return (needsCommitments, mentionedPerson)
    }
}
