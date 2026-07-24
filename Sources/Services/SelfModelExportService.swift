import Foundation

/// Exports the user's durable self-model as portable Markdown — a "CLAUDE.md for a
/// person": a briefing any future agent can read to work with them well from minute one.
///
/// Two documents, split by durability:
///  • operating-model.md — values, beliefs (with trajectory), how they decide, how to
///    communicate. Curated (high-signal only) and abstracted (principles over specifics),
///    every line tagged [declared]/[observed]/[emergent] so trust + freshness are legible.
///    Produced by a single curation+abstraction LLM pass over the structured facets.
///  • current.md — the volatile layer (active workspaces, open questions, recent decisions),
///    a deterministic snapshot stamped with the moment it was taken.
///
/// The .md files on disk are the canonical portable artifact; Notion is a readable mirror.
enum SelfModelExportService {

    struct Result {
        let durable: String
        let current: String
        let sounding: String
        let durablePath: String
        let currentPath: String
        let soundingPath: String
        let durableFilename: String
        let currentFilename: String
        let soundingFilename: String
        let notionUrl: String?
    }

    private static var exportsDir: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".alfred/exports")
    }

    /// Filename stem from the user's name: "Miten Sampat" → "Miten_Sampat".
    /// Spaces become underscores; anything not alphanumeric/underscore is dropped.
    private static func fileBase(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split { $0 == " " || $0 == "\t" }.map(String.init)
        let joined = words.isEmpty ? "user" : words.joined(separator: "_")
        let safe = String(joined.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) || $0 == "_" ? Character($0) : "_"
        })
        return safe.isEmpty ? "user" : safe
    }
    private static func durableFilename(_ name: String) -> String { "\(fileBase(name))_operating_model.md" }
    private static func currentFilename(_ name: String) -> String { "\(fileBase(name))_current.md" }
    private static func soundingFilename(_ name: String) -> String { "\(fileBase(name))_sounding_board.md" }
    private static func firstName(_ name: String) -> String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").first ?? "they")
    }
    private static var statePath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".alfred/self_model_export.json")
    }

    // MARK: - Public entry

    /// Generate both docs, write to disk, and (best-effort) mirror to Notion.
    static func export(pushToNotion: Bool) async -> Result {
        let rawName = AppConfig.load()?.user.name ?? ""
        let name = rawName.isEmpty ? "User" : rawName
        let durable = await generateDurable(name: name)
        let current = generateCurrent()
        let dName = durableFilename(name), cName = currentFilename(name), sName = soundingFilename(name)
        let sounding = generateSoundingBoard(name: name, operatingFilename: dName)

        let dDir = exportsDir
        try? FileManager.default.createDirectory(atPath: dDir, withIntermediateDirectories: true)
        let dPath = (dDir as NSString).appendingPathComponent(dName)
        let cPath = (dDir as NSString).appendingPathComponent(cName)
        let sPath = (dDir as NSString).appendingPathComponent(sName)
        try? durable.write(toFile: dPath, atomically: true, encoding: .utf8)
        try? current.write(toFile: cPath, atomically: true, encoding: .utf8)
        try? sounding.write(toFile: sPath, atomically: true, encoding: .utf8)

        var notionUrl: String? = nil
        if pushToNotion {
            notionUrl = await mirrorToNotion(title: "Operating Model — \(name)", markdown: durable + "\n\n" + sounding + "\n\n" + current)
        }
        return Result(durable: durable, current: current, sounding: sounding,
                      durablePath: dPath, currentPath: cPath, soundingPath: sPath,
                      durableFilename: dName, currentFilename: cName, soundingFilename: sName, notionUrl: notionUrl)
    }

    /// Return the last-saved docs + their filenames (or nil if never exported).
    static func lastSaved() -> (durable: String, current: String, sounding: String,
                                durableFilename: String, currentFilename: String, soundingFilename: String)? {
        let name = { let n = AppConfig.load()?.user.name ?? ""; return n.isEmpty ? "User" : n }()
        let dName = durableFilename(name), cName = currentFilename(name), sName = soundingFilename(name)
        let d = try? String(contentsOfFile: (exportsDir as NSString).appendingPathComponent(dName), encoding: .utf8)
        let c = try? String(contentsOfFile: (exportsDir as NSString).appendingPathComponent(cName), encoding: .utf8)
        let s = try? String(contentsOfFile: (exportsDir as NSString).appendingPathComponent(sName), encoding: .utf8)
        guard let d = d else { return nil }
        return (d, c ?? "", s ?? "", dName, cName, sName)
    }

    // MARK: - Sounding-board doc (persona wrapper + how-to — deterministic)

    /// The "What would <Name> think?" wrapper: a persona prompt + setup instructions that
    /// turn the operating model into a sounding board for someone preparing something for
    /// <Name>. Reusable across a Claude Project, a custom GPT, or any chat. Uses they/them —
    /// pronouns aren't inferred from a name.
    static func generateSoundingBoard(name: String, operatingFilename: String) -> String {
        let first = firstName(name)
        return """
        ---
        purpose: A "What would \(name) think?" sounding board — to prep or pressure-test something before it reaches them.
        pairs-with: \(operatingFilename)
        generated: \(String(ISO8601DateFormatter().string(from: Date()).prefix(10))) · Alfred
        ---

        # \(name) — Sounding Board

        Load this file **together with `\(operatingFilename)`** into the AI of your choice. The operating-model file is the knowledge; the instructions below are the persona. It helps you *anticipate* \(first) — it is not \(first), and not their authorization.

        ## How to set it up
        - **Claude Project** — create a Project, add `\(operatingFilename)` as project knowledge, and paste the *Instructions* section below into the Project's custom instructions.
        - **Custom GPT** — upload `\(operatingFilename)` as a knowledge file, and paste the *Instructions* into the GPT's instructions.
        - **Any chat** — paste the contents of `\(operatingFilename)`, then paste the *Instructions*, then ask your question.

        ## Instructions (use these as the system prompt)

        You are a sounding board that helps someone prepare for — or pressure-test — something before it reaches \(name). You are grounded in \(first)'s operating model (the attached file). Your job is to *anticipate* \(first), not to be them.

        - Speak in the third person: "\(first) would likely push on…", never "I think" as if you were them.
        - Be the skeptic \(first) would be. Stress-test the argument, surface the weak assumption, ask the question they'll ask. Do not flatter or rubber-stamp.
        - When you make a call, cite the principle you're reasoning from (e.g. "they weigh durability over short-term wins, so…"). It grounds you and shows your work.
        - Weight by provenance tags in the model: `[declared]` = firm, they own it; `[observed]`/`[emergent]` = inferred from behaviour — treat as a strong hypothesis, not doctrine, and say so when you lean on one.
        - Stay in prep mode. You help the person get ready. You do not decide *for* \(first), authorize anything in their name, or speak for them to others.
        - If the model doesn't cover something, say so plainly rather than inventing a view.

        ## Good questions to ask it
        - "How will \(first) react to this proposal — and what will they push on first?"
        - "What's the one objection to this deck I'm not ready for?"
        - "How should I frame this ask so it lands with \(first)?"
        - "Where does this plan run against how \(first) thinks?"

        ## What this is not
        - Not \(first), and not their sign-off. It reflects how they *think*, which is context — not a mandate to act.
        - Not always current — it's a snapshot. For anything time-sensitive or high-stakes, check with them directly.
        """
    }

    // MARK: - Durable doc (curated + abstracted, LLM pass)

    static func generateDurable(name: String) async -> String {
        let facts = collectFacts()
        let header = frontMatter(name: name)

        guard let config = AppConfig.load() else { return header + deterministicBody(facts) }
        let svc = ClaudeAIService(config: config.ai, userName: name)
        let prompt = buildPrompt(facts)
        // Never let a slow/failed model block the export — fall back to the raw curated facts.
        if let md = try? await svc.generateText(prompt: prompt, system: systemPrompt, maxTokens: 2200),
           !md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return header + stripFences(md).trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        }
        return header + deterministicBody(facts)
    }

    private static let systemPrompt = """
    You convert a person's structured self-model into a portable "operating manual" — a briefing an incoming AI agent reads to work with this person well from minute one. Output GitHub-flavored Markdown only. No preamble, no closing remarks, no code fences.

    RULES:
    1. CURATE. Include only durable, high-signal traits. DROP anything that is an instruction to an assistant/tool rather than a fact about the person — e.g. "mute this group", "stop reminding me", "review my last 7 days", "flag overdue tasks from X", "extract lessons about me / remember this / retain for coaching". Those describe how they use a tool, not who they are. Drop duplicates. When in doubt, leave it out.
    2. ABSTRACT — this is the most important rule. Prefer transferable principles over specifics. If two or more beliefs are about the same domain or express one underlying insight, COLLAPSE them into a SINGLE principle stated in general, transferable terms. Strip domain-specific detail — product names, specific numbers, named institutions, industry jargon — from the durable manual; those specifics live in the volatile log, not here. Keep a specific ONLY when the specific itself is the transferable point.
       Worked example: given "Insurance value is communicated through sum-insured amount → now scenario-based stress testing" AND "Insurance is sold through marketing → now bought reactively in crisis", output ONE line: "Reason from how things are actually bought and used, not how they're sold or marketed. [emergent]" — the insurance detail is dropped, the principle remains.
    3. PRESERVE PROVENANCE. Every value / belief / principle keeps a tag exactly as given: [declared] (they stated it), [observed] (inferred from their behaviour), [emergent] (crystallised across their reflections). Never invent a tag. When collapsing several items, keep the strongest-signal tag among them.
    4. SHOW EVOLUTION. When a SINGLE belief has a was→now trajectory worth preserving, render it as two lines: "was: …" then "→ now: …". But if the trajectory is really domain detail, prefer collapsing it to a principle per rule 2.
    5. VOICE. A first-person operating manual, written by the person for an agent. Concise, direct, high-density. Never flatter, never editorialise, never invent a trait that isn't in the input.

    Use exactly these sections, in order, omitting any that would be empty:
    # How to work with me
    ## Values
    ## What I believe now
    ## How I decide
    ## How to communicate with me
    """

    /// Structured, pre-filtered facts handed to the curation pass.
    private struct Facts {
        var values: [(text: String, origin: String)] = []
        var trajectories: [(from: String, to: String, origin: String)] = []   // was → now
        var principles: [(text: String, origin: String)] = []                 // declared/observed beliefs, no trajectory
        var style: [(text: String, origin: String)] = []                      // communication / working preferences
    }

    private static func collectFacts() -> Facts {
        var f = Facts()
        let model = SelfModelService.synthesize()

        for v in (model["values"] as? [[String: Any]] ?? []) {
            if let s = v["statement"] as? String, !s.isEmpty {
                f.values.append((s, (v["origin"] as? String) ?? "declared"))
            }
        }

        let lenses = model["lenses"] as? [String: Any] ?? [:]
        for b in (lenses["belief_shifts"] as? [[String: Any]] ?? []) {
            let from = (b["from"] as? String) ?? ""
            let to = (b["to"] as? String) ?? ""
            let origin = (b["origin"] as? String) ?? "emergent"
            guard !to.isEmpty else { continue }
            if !from.isEmpty { f.trajectories.append((from, to, origin)) }
            else { f.principles.append((to, origin)) }
        }

        // Patterns → communication/working style, minus obvious tool-operational noise.
        for p in (lenses["patterns"] as? [[String: Any]] ?? []) {
            guard let desc = p["description"] as? String, !desc.isEmpty else { continue }
            if isToolNoise(desc) { continue }
            f.style.append((desc, (p["origin"] as? String) ?? "observed"))
        }
        return f
    }

    /// Belt-and-suspenders pre-filter for app-instruction noise (the LLM also curates).
    private static func isToolNoise(_ s: String) -> Bool {
        let l = s.lowercased()
        let markers = ["remind", "muted", "mute ", "whatsapp group", "last 7 days", "last seven days",
                       "got done", "overdue tasks from", "stop ", "please don't", "please dont", "flag ",
                       "lessons about", "summary lessons", "retain them", "for coaching", "for future coaching"]
        return markers.contains { l.contains($0) }
    }

    private static func buildPrompt(_ f: Facts) -> String {
        func block(_ title: String, _ items: [String]) -> String {
            items.isEmpty ? "" : "\n\(title):\n" + items.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        var out = "Here is the person's structured self-model. Convert it into their operating manual per the rules.\n"
        out += block("VALUES [declared unless noted]", f.values.map { "\($0.text)  [\($0.origin)]" })
        out += block("BELIEFS WITH TRAJECTORY (render was → now)", f.trajectories.map { "was: \($0.from) | now: \($0.to)  [\($0.origin)]" })
        out += block("PRINCIPLES / STANDING BELIEFS", f.principles.map { "\($0.text)  [\($0.origin)]" })
        out += block("STYLE / PREFERENCES (for 'How to communicate with me')", f.style.map { "\($0.text)  [\($0.origin)]" })
        return out
    }

    /// Deterministic assembly used when the LLM is unavailable — raw but faithful, so
    /// export never hard-fails. No abstraction (that needs the model), but curated + tagged.
    private static func deterministicBody(_ f: Facts) -> String {
        var s = "# How to work with me\n"
        if !f.values.isEmpty {
            s += "\n## Values\n" + f.values.map { "- \($0.text)  [\($0.origin)]" }.joined(separator: "\n") + "\n"
        }
        if !f.trajectories.isEmpty {
            s += "\n## What I believe now\n" + f.trajectories.map {
                "- was: \($0.from)\n  → now: \($0.to)  [\($0.origin)]"
            }.joined(separator: "\n") + "\n"
        }
        if !f.principles.isEmpty {
            s += "\n## How I decide\n" + f.principles.map { "- \($0.text)  [\($0.origin)]" }.joined(separator: "\n") + "\n"
        }
        if !f.style.isEmpty {
            s += "\n## How to communicate with me\n" + f.style.map { "- \($0.text)  [\($0.origin)]" }.joined(separator: "\n") + "\n"
        }
        return s
    }

    private static func frontMatter(name: String) -> String {
        let date = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        return """
        ---
        subject: \(name)
        generated: \(date) · Alfred self-model
        horizon: durable — how I operate and what I believe. Live priorities in current.md.
        ---

        """
    }

    // MARK: - Current doc (deterministic snapshot)

    static func generateCurrent() -> String {
        let model = SelfModelService.synthesize()
        let date = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        var s = "# Current state — as of \(date)\n"

        let workspaces = model["workspaces"] as? [[String: Any]] ?? []
        if !workspaces.isEmpty {
            s += "\n## What I'm working on\n"
            for w in workspaces {
                let theme = (w["theme"] as? String) ?? ""
                let state = (w["state"] as? String) ?? ""
                let temp = (w["temperature"] as? String) ?? ""
                let meta = [state, temp].filter { !$0.isEmpty }.joined(separator: " · ")
                s += "- \(theme)\(meta.isEmpty ? "" : "  (\(meta))")\n"
            }
        }

        let questions = model["questions"] as? [[String: Any]] ?? []
        let qTexts = questions.compactMap { $0["text"] as? String }.filter { !$0.isEmpty }
        if !qTexts.isEmpty {
            s += "\n## Open questions\n" + qTexts.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }

        // Recent decisions — the dated audit trail of judgement.
        let decisions = SelfModelStore.shared.getFacets(kind: "decision")
            .filter { ($0["user_verdict"] as? String) != "dismissed" }
            .sorted { (($0["last_seen"] as? String) ?? "") > (($1["last_seen"] as? String) ?? "") }
            .prefix(12)
        if !decisions.isEmpty {
            s += "\n## Recent decisions\n"
            for d in decisions {
                let text = (d["statement"] as? String) ?? ""
                let when = String(((d["last_seen"] as? String) ?? "").prefix(10))
                s += "- \(when.isEmpty ? "" : "\(when): ")\(text)\n"
            }
        }
        return s
    }

    // MARK: - Notion mirror (best-effort)

    /// Create a fresh Notion page with the exported content and archive the previous one
    /// (tracked in a small state file). Two API calls — deliberately light given Notion's
    /// rate limits. Returns the page URL, or nil on any failure (never throws into export).
    private static func mirrorToNotion(title: String, markdown: String) async -> String? {
        guard let config = AppConfig.load() else { return nil }
        let apiKey = config.notion.apiKey
        guard !apiKey.isEmpty, apiKey != "YOUR_NOTION_API_KEY" else { return nil }

        // Parent under a page the integration already writes to. A workspace-root parent
        // needs workspace-level access the integration usually lacks; a known page id works.
        let parent: [String: Any]
        if let pageId = config.notion.tenetsPageId ?? config.notion.playbookPageId, !pageId.isEmpty {
            parent = ["type": "page_id", "page_id": pageId]
        } else {
            parent = ["type": "workspace", "workspace": true]
        }
        let blocks = markdownToBlocks(markdown)
        let body: [String: Any] = [
            "parent": parent,
            "properties": ["title": ["title": [["text": ["content": title]]]]],
            "children": Array(blocks.prefix(100))
        ]
        guard let url = URL(string: "https://api.notion.com/v1/pages"),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data

        guard let (respData, resp) = try? await URLSession.shared.data(for: req) else {
            print("  ⚠️ Operating-model Notion push: request failed"); return nil
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let newId = json["id"] as? String else {
            print("  ⚠️ Operating-model Notion push: HTTP \(status) — \(String(data: respData, encoding: .utf8)?.prefix(200) ?? "")")
            return nil
        }
        let newUrl = (json["url"] as? String) ?? "https://notion.so/\(newId.replacingOccurrences(of: "-", with: ""))"

        // Archive the previous export page, then remember this one.
        if let prevId = loadState()?["notion_page_id"] as? String, prevId != newId {
            await archivePage(prevId, apiKey: apiKey)
        }
        saveState(["notion_page_id": newId, "notion_url": newUrl])
        return newUrl
    }

    private static func archivePage(_ id: String, apiKey: String) async {
        guard let url = URL(string: "https://api.notion.com/v1/pages/\(id)"),
              let data = try? JSONSerialization.data(withJSONObject: ["archived": true]) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        _ = try? await URLSession.shared.data(for: req)
    }

    /// Minimal Markdown → Notion blocks. Handles front-matter (as a callout-ish quote),
    /// headings, bullets, and paragraphs — enough for the operating manual's shape.
    private static func markdownToBlocks(_ md: String) -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        func rich(_ t: String) -> [[String: Any]] { [["type": "text", "text": ["content": String(t.prefix(1900))]]] }
        var inFrontMatter = false
        for raw in md.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "---" { inFrontMatter.toggle(); continue }
            if inFrontMatter {
                if !line.isEmpty { blocks.append(["object": "block", "type": "quote", "quote": ["rich_text": rich(line)]]) }
                continue
            }
            if line.isEmpty { continue }
            if line.hasPrefix("# ") {
                blocks.append(["object": "block", "type": "heading_1", "heading_1": ["rich_text": rich(String(line.dropFirst(2)))]])
            } else if line.hasPrefix("## ") {
                blocks.append(["object": "block", "type": "heading_2", "heading_2": ["rich_text": rich(String(line.dropFirst(3)))]])
            } else if line.hasPrefix("### ") {
                blocks.append(["object": "block", "type": "heading_3", "heading_3": ["rich_text": rich(String(line.dropFirst(4)))]])
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                blocks.append(["object": "block", "type": "bulleted_list_item", "bulleted_list_item": ["rich_text": rich(String(line.dropFirst(2)))]])
            } else if line.hasPrefix("→ ") || line.hasPrefix("  → ") {
                blocks.append(["object": "block", "type": "bulleted_list_item", "bulleted_list_item": ["rich_text": rich(line)]])
            } else {
                blocks.append(["object": "block", "type": "paragraph", "paragraph": ["rich_text": rich(line)]])
            }
        }
        return blocks
    }

    // MARK: - helpers

    private static func stripFences(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            if let nl = t.firstIndex(of: "\n") { t = String(t[t.index(after: nl)...]) }
            if let r = t.range(of: "```", options: .backwards) { t = String(t[..<r.lowerBound]) }
        }
        return t
    }

    private static func loadState() -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: statePath) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    private static func saveState(_ dict: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted) {
            try? data.write(to: URL(fileURLWithPath: statePath))
        }
    }
}
