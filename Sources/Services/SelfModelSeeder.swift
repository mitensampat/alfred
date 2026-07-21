import Foundation

/// Ingests a user's *declared* operating model — the one permitted top-down entry
/// into the self-model.
///
/// Everything else in the system condenses upward (reflections → themes → questions →
/// beliefs → lenses). This lets someone state who they are and how they want to operate
/// directly, which solves cold-start and gives Reflect mode real material on day one.
///
/// Declared facets are stamped `origin: "declared"` and stay marked forever, because the
/// gap between what you *say* you believe and what your behaviour actually shows is the
/// most valuable signal the mirror can produce.
///
/// Expected markdown (see the onboarding prompt):
///
///     # My Operating Model
///     ## Values
///     - ...
///     ## Beliefs
///     - ...
///     ## How I want to operate
///     - ...
enum SelfModelSeeder {

    struct SeedResult {
        var values: Int = 0
        var beliefs: Int = 0
        var instructions: Int = 0
        var files: [String] = []
        var total: Int { values + beliefs + instructions }
    }

    /// Does this markdown look like an operating-model declaration?
    static func looksLikeOperatingModel(_ text: String) -> Bool {
        let t = text.lowercased()
        if t.contains("# my operating model") { return true }
        // Tolerate a renamed title as long as the section structure is there.
        let hasTwo = [t.contains("## values"), t.contains("## beliefs"), t.contains("## how i want to operate")]
            .filter { $0 }.count >= 2
        return hasTwo
    }

    /// Parse the three sections out of the markdown. Returns bullet lines per section.
    static func parse(_ text: String) -> (values: [String], beliefs: [String], instructions: [String]) {
        var values: [String] = [], beliefs: [String] = [], instructions: [String] = []
        var current = ""

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                let heading = line.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces).lowercased()
                if heading.contains("value") { current = "values" }
                else if heading.contains("belief") { current = "beliefs" }
                else if heading.contains("operate") || heading.contains("preference") || heading.contains("instruction") { current = "instructions" }
                else { current = "" }   // e.g. the title line
                continue
            }
            guard line.hasPrefix("- ") || line.hasPrefix("* ") else { continue }
            let item = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            // Skip un-filled template placeholders like "<what I hold as non-negotiable>"
            guard !item.isEmpty, !(item.hasPrefix("<") && item.hasSuffix(">")) else { continue }
            switch current {
            case "values": values.append(item)
            case "beliefs": beliefs.append(item)
            case "instructions": instructions.append(item)
            default: break
            }
        }
        return (values, beliefs, instructions)
    }

    /// Write parsed declarations into the facet store as declared facets.
    @discardableResult
    static func seed(from markdown: String, sourceLabel: String = "operating-model") -> SeedResult {
        let store = SelfModelStore.shared
        let now = ISO8601DateFormatter().string(from: Date())
        let (values, beliefs, instructions) = parse(markdown)
        var result = SeedResult()

        func put(_ kind: String, _ idPrefix: String, _ statement: String, _ confidence: Double) -> Bool {
            return store.upsertFacet(
                id: SelfModelSynthesizer.stableId(idPrefix, statement),
                kind: kind, statement: statement, confidence: confidence,
                status: "active", firstSeen: now, lastSeen: now,
                trajectory: [], evidence: [["source_type": "declaration", "source_id": sourceLabel, "snippet": statement, "ts": now]],
                metadata: ["declared_on": now, "source": sourceLabel],
                origin: "declared"
            )
        }

        // Values are the slowest-moving thing a person states — high confidence by default.
        for v in values where put("value", "value_declared", v, 0.9) { result.values += 1 }
        // A declared belief is an aspiration until a lens supports it — start mid-confidence.
        for b in beliefs where put("belief", "belief_declared", b, 0.6) { result.beliefs += 1 }
        // Standing instructions are explicit and unambiguous.
        for i in instructions where put("pattern", "pattern_declared", i, 1.0) { result.instructions += 1 }

        return result
    }

    /// Scan ~/.alfred/imports/ for operating-model markdown, seed it, and move the file
    /// to processed/. Returns what was ingested.
    @discardableResult
    static func scanImports() -> SeedResult {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let importsDir = "\(home)/.alfred/imports"
        let processedDir = "\(importsDir)/processed"
        try? fm.createDirectory(atPath: processedDir, withIntermediateDirectories: true)

        var combined = SeedResult()
        guard let files = try? fm.contentsOfDirectory(atPath: importsDir) else { return combined }

        for file in files {
            let ext = (file as NSString).pathExtension.lowercased()
            guard ext == "md" || ext == "markdown" || ext == "txt" else { continue }
            let path = "\(importsDir)/\(file)"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { continue }
            guard let content = try? String(contentsOfFile: path, encoding: .utf8),
                  looksLikeOperatingModel(content) else { continue }

            let r = seed(from: content, sourceLabel: file)
            combined.values += r.values
            combined.beliefs += r.beliefs
            combined.instructions += r.instructions
            combined.files.append(file)

            var dest = "\(processedDir)/\(file)"
            if fm.fileExists(atPath: dest) {
                let name = (file as NSString).deletingPathExtension
                dest = "\(processedDir)/\(name)_\(Int(Date().timeIntervalSince1970)).\(ext)"
            }
            try? fm.moveItem(atPath: path, toPath: dest)
            print("✅ SelfModelSeeder: seeded \(r.total) declared facets from \(file)")
        }
        return combined
    }
}
