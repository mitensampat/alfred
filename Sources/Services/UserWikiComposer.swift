import Foundation

/// The You-Wiki (Step 7): a living markdown portrait of the user — the fronts they're running, what
/// they believe and how it's shifted, the people in their world, and the patterns Alfred has noticed.
/// Written to ~/.alfred/user-wiki.md on a nightly cadence so it renders in any markdown/wiki viewer.
/// Deterministic — no new interface, no LLM; it just weaves together what the stores already hold.
enum UserWikiComposer {

    static func markdown() -> String {
        let config = AppConfig.load()
        let name = config?.user.name ?? "You"
        let df = DateFormatter(); df.dateFormat = "d MMM yyyy"
        var md = "# \(name) — a working portrait\n"
        md += "*Compiled by Alfred · \(df.string(from: Date()))*\n\n"
        md += "> A living compendium of what's most alive with you — the fronts you're running, what you believe, the people in your world, and the patterns Alfred has noticed. Regenerated nightly from your threads and self-model.\n\n"

        // What you're running (fronts).
        let fronts = DeskService.buildFronts()
        if !fronts.isEmpty {
            md += "## What you're running\n\n"
            for f in fronts.prefix(15) {
                let n = f["name"] as? String ?? ""
                let stage = (f["stage"] as? String ?? "").capitalized
                let dec = firstSentence(f["decision"] as? String ?? "", 120)
                md += "- **\(n)**" + (stage.isEmpty ? "" : " — \(stage)") + (dec.isEmpty ? "" : " · \(dec)") + "\n"
            }
            md += "\n"
        }

        let store = SelfModelStore.shared

        // What you believe.
        let beliefs = store.getFacets(kind: "belief")
            .filter { ($0["user_verdict"] as? String) != "dismissed" }
            .compactMap { ($0["statement"] as? String)?.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 8 }
        if !beliefs.isEmpty {
            md += "## What you believe\n\n"
            for b in beliefs.prefix(20) { md += "- \(b)\n" }
            md += "\n"
        }

        // Open questions.
        let questions = store.getFacets(kind: "question")
            .compactMap { ($0["statement"] as? String)?.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 8 }
        if !questions.isEmpty {
            md += "## Open questions you're holding\n\n"
            for q in questions.prefix(15) { md += "- \(q)\n" }
            md += "\n"
        }

        // The people in your world.
        let people = DeskService.buildPeople().prefix(12)
        if !people.isEmpty {
            md += "## The people in your world\n\n"
            for p in people {
                let who = p["name"] as? String ?? ""
                let owe = p["you_owe"] as? Int ?? 0, owed = p["they_owe"] as? Int ?? 0
                let ot = (p["on_time"] as? String ?? "")
                var bits: [String] = []
                if owe > 0 { bits.append("\(owe) you owe") }
                if owed > 0 { bits.append("\(owed) they owe") }
                if !ot.isEmpty { bits.append("\(ot) on time") }
                md += "- **\(who)**" + (bits.isEmpty ? "" : " — " + bits.joined(separator: ", ")) + "\n"
            }
            md += "\n"
        }

        // Patterns Alfred has noticed (coaching memory).
        let ctx = CoachingMemoryService.shared.getCoachingContext().trimmingCharacters(in: .whitespacesAndNewlines)
        if !ctx.isEmpty {
            md += "## Patterns Alfred has noticed\n\n\(ctx)\n"
        }

        return md
    }

    /// Write the wiki to ~/.alfred/user-wiki.md and return the path.
    @discardableResult
    static func write() -> String {
        let md = markdown()
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".alfred/user-wiki.md")
        try? md.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private static func firstSentence(_ s: String, _ cap: Int) -> String {
        var t = s.split(whereSeparator: { $0 == "." || $0 == "?" || $0 == "!" }).first.map(String.init) ?? s
        t = t.trimmingCharacters(in: .whitespaces)
        return t.count > cap ? String(t.prefix(cap - 1)) + "…" : t
    }
}
