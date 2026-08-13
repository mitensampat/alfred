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

        // Beliefs, split by durability. "What you believe" must hold durable operating principles —
        // not situational reads, past events, or coaching nudges (those silted it up before). We
        // read the durability tag the nightly pass stamps; when a belief hasn't been tagged yet we
        // fall back to the deterministic heuristic so nothing that reads as an action/fact slips in.
        let liveBeliefs = store.getFacets(kind: "belief")
            .filter { ($0["user_verdict"] as? String) != "dismissed" }
        var durable: [String] = [], tactical: [String] = []
        for f in liveBeliefs {
            guard let s = (f["statement"] as? String)?.trimmingCharacters(in: .whitespaces), s.count > 8 else { continue }
            let meta = (f["metadata"] as? [String: String]) ?? [:]
            let cls: BeliefDurability = meta["durability"].flatMap { BeliefDurability(rawValue: $0) }
                ?? BeliefDurability.heuristic(s) ?? .durable
            switch cls {
            case .durable:  durable.append(s)
            case .tactical: tactical.append(s)
            case .fact, .action: break   // not a belief — never surfaced here
            }
        }
        if !durable.isEmpty {
            md += "## What you believe\n\n"
            md += "> Durable principles — how you operate, decide, and lead.\n\n"
            for b in durable.prefix(18) { md += "- \(b)\n" }
            md += "\n"
        }
        if !tactical.isEmpty {
            md += "## Working theses — current\n\n"
            md += "> Live reads on the business. True for now; expected to move as things do.\n\n"
            for b in tactical.prefix(10) { md += "- \(b)\n" }
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

        // What Alfred's coaching has noticed — curated from the analysis lenses, not the raw
        // coaching-context blob (which mixed in the user profile, session log, and generic
        // scaffolding). We surface recurring, worth-sharing observations only.
        let observations = coachingObservations()
        if !observations.isEmpty {
            md += "## What Alfred's coaching has noticed\n\n"
            md += "> Recurring signals from the analysis lenses over the last two weeks.\n\n"
            for o in observations { md += "- \(o)\n" }
            md += "\n"
        }

        return md
    }

    /// Pull the worth-sharing coaching observations: recurring signals across the enabled analysis
    /// lenses over ~2 weeks. Group by (lens, type, subject), rank by how many distinct days each
    /// recurred, keep the freshest phrasing, and spread across lenses so one loud lens can't crowd
    /// out the rest. Deterministic — reads what the lenses already wrote.
    private static func coachingObservations() -> [String] {
        let lenses = AnalysisLensLoader.shared.getEnabledLenses()
        guard !lenses.isEmpty else { return [] }

        struct Group { var name: String; var icon: String; var desc: String; var days: Set<String>; var last: String }
        var groups: [String: Group] = [:]

        for lens in lenses {
            for day in SignalStore.shared.getSignalHistory(lensId: lens.id, days: 14) {
                for sig in day.signals {
                    let desc = sanitize((sig.metadata?["description"] ?? sig.evidence ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
                    guard desc.count > 12 else { continue }
                    let key = lens.id + "|" + sig.type + "|" + (sig.subject ?? "")
                    if groups[key] == nil {
                        groups[key] = Group(name: lens.name, icon: lens.icon, desc: desc, days: [day.date], last: day.date)
                    } else {
                        groups[key]!.days.insert(day.date)
                        if day.date >= groups[key]!.last { groups[key]!.last = day.date; groups[key]!.desc = desc }
                    }
                }
            }
        }
        guard !groups.isEmpty else { return [] }

        // Rank: recurrence first (a pattern that shows up repeatedly is the real signal), then recency.
        let ranked = groups.values.sorted {
            $0.days.count != $1.days.count ? $0.days.count > $1.days.count : $0.last > $1.last
        }

        // Spread across lenses — at most 2 from any one lens — and cap the section.
        var out: [String] = []
        var perLens: [String: Int] = [:]
        var seen = Set<String>()
        for g in ranked {
            if (perLens[g.name] ?? 0) >= 2 { continue }
            let dedup = String(g.desc.lowercased().prefix(48))
            if seen.contains(dedup) { continue }
            seen.insert(dedup)
            perLens[g.name, default: 0] += 1
            let recur = g.days.count >= 3 ? " _(recurring)_" : ""
            out.append("**\(g.name)** — \(g.desc)\(recur)")
            if out.count >= 8 { break }
        }
        return out
    }

    /// Write the wiki to ~/.alfred/user-wiki.md and return the path.
    @discardableResult
    static func write() -> String {
        let md = markdown()
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".alfred/user-wiki.md")
        try? md.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// Replace raw WhatsApp JIDs (e.g. '1203…@newsletter', '…@g.us') with a readable stand-in so
    /// coaching observations don't leak machine identifiers into the portrait.
    private static func sanitize(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(
            of: "'?[0-9]{6,}@newsletter'?",
            with: "a WhatsApp newsletter", options: .regularExpression)
        t = t.replacingOccurrences(
            of: "'?[0-9]{6,}(-[0-9]+)?@(g\\.us|s\\.whatsapp\\.net)'?",
            with: "a WhatsApp group", options: .regularExpression)
        return t
    }

    private static func firstSentence(_ s: String, _ cap: Int) -> String {
        var t = s.split(whereSeparator: { $0 == "." || $0 == "?" || $0 == "!" }).first.map(String.init) ?? s
        t = t.trimmingCharacters(in: .whitespaces)
        return t.count > cap ? String(t.prefix(cap - 1)) + "…" : t
    }
}
