import Foundation

/// Autonomous research loop inspired by Karpathy's autoresearch pattern.
/// Takes an open question, searches the web, synthesizes findings into a wiki file,
/// and self-grades each cycle (keep/revert).
class ResearchLoop {

    private let wikiDir: URL
    private let logFile: URL
    private let apiKey: String
    private let model: String
    private let baseURL: String
    private let tavilyApiKey: String

    /// In-flight research tracking for status queries
    private static var activeRuns: [String: ResearchStatus] = [:]
    private static let statusLock = NSLock()

    struct ResearchStatus {
        var running: Bool
        var cyclesCompleted: Int
        var lastScore: Int
    }

    enum ResearchError: Error, LocalizedError {
        case missingTavilyKey
        case missingAIConfig
        case tavilyRequestFailed(String)
        case synthesisRequestFailed
        case gradeParseError(String)

        var errorDescription: String? {
            switch self {
            case .missingTavilyKey:
                return "Tavily API key not configured. Set research.tavily_api_key in ~/.config/alfred/config.json"
            case .missingAIConfig:
                return "AI config not found. Ensure ai section exists in config.json"
            case .tavilyRequestFailed(let msg):
                return "Tavily search failed: \(msg)"
            case .synthesisRequestFailed:
                return "Claude synthesis request failed"
            case .gradeParseError(let msg):
                return "Failed to parse grade response: \(msg)"
            }
        }
    }

    init(config: AppConfig) throws {
        guard let tavilyKey = config.research.tavilyApiKey, !tavilyKey.isEmpty,
              tavilyKey != "YOUR_TAVILY_API_KEY" else {
            throw ResearchError.missingTavilyKey
        }

        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/research-wiki")
        self.wikiDir = configDir
        self.logFile = configDir.appendingPathComponent("research-log.jsonl")
        self.apiKey = config.ai.anthropicApiKey
        self.model = config.ai.model
        self.baseURL = config.ai.effectiveBaseUrl
        self.tavilyApiKey = tavilyKey
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    }

    // MARK: - Public API

    /// Run the research loop for a given question.
    func run(question: String, themeSlug: String, themeName: String, maxCycles: Int = 5) async -> ResearchResult {
        let wikiFile = wikiDir.appendingPathComponent("\(themeSlug).md")

        // Initialize status tracking
        ResearchLoop.updateStatus(themeSlug: themeSlug, status: ResearchStatus(running: true, cyclesCompleted: 0, lastScore: 0))

        // Read or create wiki file
        var wikiContent = readOrCreateWiki(at: wikiFile, themeName: themeName, question: question)

        var cyclesRun = 0
        var cyclesKept = 0
        var consecutiveDiscards = 0
        var lastScore = 0

        for cycle in 1...maxCycles {
            print("[Research] Cycle \(cycle)/\(maxCycles) for '\(themeName)'")

            // a. Generate search queries
            let queries = await generateSearchQueries(question: question, currentWiki: wikiContent, cycle: cycle)
            if queries.isEmpty {
                logCycle(themeSlug: themeSlug, cycle: cycle, action: "skip", score: 0, reason: "Failed to generate search queries")
                consecutiveDiscards += 1
                if consecutiveDiscards >= 2 { break }
                continue
            }

            // b. Search via Tavily
            var allResults: [TavilyResult] = []
            for query in queries {
                if let results = await searchTavily(query: query) {
                    allResults.append(contentsOf: results)
                }
            }

            if allResults.isEmpty {
                logCycle(themeSlug: themeSlug, cycle: cycle, action: "skip", score: 0, reason: "No search results returned")
                consecutiveDiscards += 1
                if consecutiveDiscards >= 2 { break }
                continue
            }

            // Deduplicate by URL
            var seen = Set<String>()
            allResults = allResults.filter { r in
                guard !seen.contains(r.url) else { return false }
                seen.insert(r.url)
                return true
            }

            // c. Synthesize: ask Claude to update wiki
            let oldContent = wikiContent
            guard let newContent = await synthesize(question: question, currentWiki: wikiContent, searchResults: allResults) else {
                logCycle(themeSlug: themeSlug, cycle: cycle, action: "skip", score: 0, reason: "Synthesis failed")
                consecutiveDiscards += 1
                if consecutiveDiscards >= 2 { break }
                continue
            }

            // d. Self-grade
            let grade = await selfGrade(oldWiki: oldContent, newWiki: newContent, searchResults: allResults)

            cyclesRun += 1
            lastScore = grade.score

            // e. Score >= 3 -> keep. Score < 3 -> discard.
            if grade.score >= 3 {
                wikiContent = newContent
                try? wikiContent.write(to: wikiFile, atomically: true, encoding: .utf8)
                cyclesKept += 1
                consecutiveDiscards = 0
                logCycle(themeSlug: themeSlug, cycle: cycle, action: "keep", score: grade.score, reason: grade.reason)
                print("[Research]   KEEP (score \(grade.score)): \(grade.reason)")
            } else {
                consecutiveDiscards += 1
                logCycle(themeSlug: themeSlug, cycle: cycle, action: "discard", score: grade.score, reason: grade.reason)
                print("[Research]   DISCARD (score \(grade.score)): \(grade.reason)")
            }

            // Update status
            ResearchLoop.updateStatus(themeSlug: themeSlug, status: ResearchStatus(running: true, cyclesCompleted: cyclesRun, lastScore: lastScore))

            // f. Two consecutive discards -> stop (plateau)
            if consecutiveDiscards >= 2 {
                print("[Research] Plateau detected (2 consecutive discards). Stopping.")
                break
            }
        }

        // Mark as complete
        ResearchLoop.updateStatus(themeSlug: themeSlug, status: ResearchStatus(running: false, cyclesCompleted: cyclesRun, lastScore: lastScore))

        print("[Research] Complete: \(cyclesRun) cycles, \(cyclesKept) kept, final score \(lastScore)")

        return ResearchResult(
            themeSlug: themeSlug,
            themeName: themeName,
            question: question,
            cyclesRun: cyclesRun,
            cyclesKept: cyclesKept,
            finalScore: lastScore,
            wikiFilePath: wikiFile.path
        )
    }

    // MARK: - Status tracking

    static func getStatus(themeSlug: String) -> ResearchStatus? {
        statusLock.lock()
        defer { statusLock.unlock() }
        return activeRuns[themeSlug]
    }

    private static func updateStatus(themeSlug: String, status: ResearchStatus) {
        statusLock.lock()
        activeRuns[themeSlug] = status
        statusLock.unlock()
    }

    // MARK: - Wiki file management

    private func readOrCreateWiki(at url: URL, themeName: String, question: String) -> String {
        if let existing = try? String(contentsOf: url, encoding: .utf8), !existing.isEmpty {
            return existing
        }
        let template = """
        # \(themeName)

        ## Open Question
        \(question)

        ## Findings
        (No findings yet)
        """
        try? template.write(to: url, atomically: true, encoding: .utf8)
        return template
    }

    // MARK: - Search query generation

    private func generateSearchQueries(question: String, currentWiki: String, cycle: Int) async -> [String] {
        let prompt = """
        You are a research assistant. Generate 2-3 focused web search queries to investigate this question.

        QUESTION: \(question)

        CURRENT KNOWLEDGE (cycle \(cycle)):
        \(currentWiki.prefix(2000))

        Generate queries that will find NEW information not already covered. If this is cycle > 1, try different angles.

        Respond with ONLY a JSON array of strings: ["query 1", "query 2", "query 3"]
        """

        guard let response = await callClaude(prompt: prompt, maxTokens: 256) else {
            return []
        }

        // Parse JSON array from response — Claude often wraps in ```json fences
        var cleaned = response.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip markdown code fences if present
        if cleaned.hasPrefix("```") {
            let lines = cleaned.components(separatedBy: "\n")
            let inner = lines.dropFirst().dropLast().joined(separator: "\n")
            cleaned = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = cleaned.data(using: .utf8),
              let queries = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            // Try extracting JSON array spanning multiple lines
            if let start = cleaned.firstIndex(of: "["),
               let end = cleaned.lastIndex(of: "]") {
                let jsonStr = String(cleaned[start...end])
                if let d = jsonStr.data(using: .utf8),
                   let q = try? JSONSerialization.jsonObject(with: d) as? [String] {
                    return q
                }
            }
            print("[Research] Failed to parse queries from: \(cleaned.prefix(200))")
            return []
        }
        return queries
    }

    // MARK: - Tavily search

    struct TavilyResult {
        let title: String
        let url: String
        let content: String
        let score: Double
    }

    private func searchTavily(query: String) async -> [TavilyResult]? {
        guard let url = URL(string: "https://api.tavily.com/search") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "api_key": tavilyApiKey,
            "query": query,
            "search_depth": "advanced",
            "include_raw_content": false,
            "max_results": 5
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
                print("[Research] Tavily error \(statusCode): \(errorBody)")
                return nil
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else {
                return nil
            }

            return results.compactMap { r in
                guard let title = r["title"] as? String,
                      let url = r["url"] as? String,
                      let content = r["content"] as? String else { return nil }
                let score = r["score"] as? Double ?? 0.0
                return TavilyResult(title: title, url: url, content: content, score: score)
            }
        } catch {
            print("[Research] Tavily request error: \(error)")
            return nil
        }
    }

    // MARK: - Synthesis

    private func synthesize(question: String, currentWiki: String, searchResults: [TavilyResult]) async -> String? {
        let sourcesText = searchResults.map { r in
            "[\(r.title)](\(r.url))\n\(r.content)"
        }.joined(separator: "\n\n---\n\n")

        let prompt = """
        You are a research synthesizer. Update the wiki page below with new findings from the search results.

        QUESTION BEING RESEARCHED: \(question)

        CURRENT WIKI PAGE:
        \(currentWiki)

        NEW SEARCH RESULTS:
        \(sourcesText)

        INSTRUCTIONS:
        - Integrate genuinely new facts, perspectives, or data into the wiki page
        - Preserve existing content that is still accurate
        - Add source citations as markdown links
        - Keep the same markdown structure (# heading, ## Open Question, ## Findings)
        - Write clearly and concisely — this is a reference document, not an essay
        - If the search results don't add anything new, return the wiki page unchanged

        Return ONLY the updated wiki page content (raw markdown, no code fences).
        """

        return await callClaude(prompt: prompt, maxTokens: 4096)
    }

    // MARK: - Self-grading

    struct Grade {
        let score: Int
        let reason: String
    }

    private func selfGrade(oldWiki: String, newWiki: String, searchResults: [TavilyResult]) async -> Grade {
        let sourcesText = searchResults.map { r in
            "[\(r.title)](\(r.url)) — \(r.content.prefix(200))"
        }.joined(separator: "\n")

        let prompt = """
        You are evaluating a research synthesis update. Rate 1-5:

        BEFORE:
        \(oldWiki)

        AFTER:
        \(newWiki)

        NEW SOURCES INTEGRATED:
        \(sourcesText)

        Score 1: Update added noise, redundancy, or inaccuracies
        Score 2: Update is a lateral move — different words, same insight
        Score 3: Update adds one genuinely new perspective or fact
        Score 4: Update meaningfully deepens understanding
        Score 5: Update is a breakthrough — reframes the question or resolves a tension

        Respond with ONLY a JSON object: {"score": N, "reason": "one sentence"}
        """

        guard let response = await callClaude(prompt: prompt, maxTokens: 256) else {
            return Grade(score: 0, reason: "Grade request failed")
        }

        // Parse {"score": N, "reason": "..."} from response
        let cleaned = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = extractJSONObject(from: cleaned),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let score = json["score"] as? Int,
           let reason = json["reason"] as? String {
            return Grade(score: max(1, min(5, score)), reason: reason)
        }

        return Grade(score: 2, reason: "Could not parse grade response, defaulting to 2")
    }

    // MARK: - Claude API calls (mirrors ClaudeAIService.sendRequest pattern)

    private func callClaude(prompt: String, maxTokens: Int = 4096) async -> String? {
        guard let url = URL(string: baseURL) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 120

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                if let errorBody = String(data: data, encoding: .utf8) {
                    print("[Research] Claude API error \(statusCode): \(errorBody)")
                }
                return nil
            }

            // Decode same ClaudeResponse structure
            struct APIContent: Codable {
                let text: String
            }
            struct APIResponse: Codable {
                let content: [APIContent]
            }

            let apiResponse = try JSONDecoder().decode(APIResponse.self, from: data)
            return apiResponse.content.first?.text
        } catch {
            print("[Research] Claude request error: \(error)")
            return nil
        }
    }

    // MARK: - Logging

    private func logCycle(themeSlug: String, cycle: Int, action: String, score: Int, reason: String) {
        let entry: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "theme_slug": themeSlug,
            "cycle": cycle,
            "action": action,
            "score": score,
            "reason": reason
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: entry),
              let line = String(data: data, encoding: .utf8) else { return }

        let lineWithNewline = line + "\n"
        if FileManager.default.fileExists(atPath: logFile.path) {
            if let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                handle.write(lineWithNewline.data(using: .utf8)!)
                handle.closeFile()
            }
        } else {
            try? lineWithNewline.write(to: logFile, atomically: true, encoding: .utf8)
        }
    }

    /// Read recent log entries.
    static func readLog(limit: Int = 20) -> [[String: Any]] {
        let logPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/research-wiki/research-log.jsonl")

        guard let content = try? String(contentsOf: logPath, encoding: .utf8) else { return [] }

        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        let recent = Array(lines.suffix(limit))

        return recent.compactMap { line in
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return json
        }
    }

    // MARK: - Helpers

    private func extractJSONObject(from text: String) -> Data? {
        // Try the whole string first
        if let data = text.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return data
        }
        // Try extracting from markdown code block or embedded JSON
        if let start = text.firstIndex(of: "{"),
           let end = text.lastIndex(of: "}") {
            let jsonStr = String(text[start...end])
            return jsonStr.data(using: .utf8)
        }
        return nil
    }
}

struct ResearchResult {
    let themeSlug: String
    let themeName: String
    let question: String
    let cyclesRun: Int
    let cyclesKept: Int
    let finalScore: Int
    let wikiFilePath: String

    var toDict: [String: Any] {
        return [
            "theme_slug": themeSlug,
            "theme_name": themeName,
            "question": question,
            "cycles_run": cyclesRun,
            "cycles_kept": cyclesKept,
            "final_score": finalScore,
            "wiki_file_path": wikiFilePath
        ]
    }
}
