import Foundation

/// Learning from what the user does with to-dos (docs/rewire/ROADMAP.md, "learn from dismissed
/// suggestions and tag corrections").
///
/// Everything here is a small, explainable rule over the feedback log, so a decision can always be
/// shown with its reason ("hidden: you dismissed 3 like this from Rahul"). Nothing is deleted: a hidden
/// suggestion stays recoverable in the tray for 14 days.
///
///  1. Fronts: a title word the user tagged to a front (by correcting a tag, or by adding a to-do with a
///     front) votes for that front next time; a word they untagged votes against it.
///  2. People: a person name the user corrected ("KS" → "Kunal Shah") is rewritten on arrival.
///  3. Suggestions: one that closely matches something dismissed before, or that comes from a
///     person/source whose suggestions the user keeps dismissing, is hidden instead of shown.
///  4. Order: suggestions from sources and people the user usually accepts come first.
///  5. The extractors: dismissals and title edits go to CorrectionTracker, which already feeds the
///     commitment extraction prompt (and now the notes-to-self prompt too).
enum TodoLearning {

    // MARK: - Hooks (called by TodoService / the API)

    static func accepted(_ t: TodoStore.Todo) {
        TodoStore.shared.recordFeedback("accepted", todo: t)
    }

    static func dismissed(_ t: TodoStore.Todo) {
        TodoStore.shared.recordFeedback("dismissed", todo: t)
        // Tell the extractor: this was not a real to-do.
        CorrectionTracker.shared.recordFalsePositive(
            itemType: t.source == "commitment" ? "Commitment" : "Todo",
            title: t.title, description: t.sourceNote, reason: "Dismissed in Alfred", source: t.source)
    }

    /// The user changed a to-do. Records front / person / title corrections.
    static func edited(before: TodoStore.Todo, after: TodoStore.Todo) {
        if before.frontId != after.frontId {
            TodoStore.shared.recordFeedback("front_set", todo: after, from: before.frontId, to: after.frontId)
        }
        if (before.person ?? "") != (after.person ?? "") {
            TodoStore.shared.recordFeedback("person_set", todo: after, from: before.person, to: after.person)
        }
        if before.title != after.title, before.source != "capture" {
            CorrectionTracker.shared.recordEdit(itemType: before.source == "commitment" ? "Commitment" : "Todo",
                                                originalTitle: before.title, editedTitle: after.title,
                                                originalDescription: nil, editedDescription: nil, source: before.source)
        }
    }

    /// A to-do the user created with a front: its words teach the front tagger.
    static func createdWithFront(_ t: TodoStore.Todo) {
        guard t.frontId != nil else { return }
        TodoStore.shared.recordFeedback("front_set", todo: t, from: nil, to: t.frontId)
    }

    // MARK: - 1. Fronts

    static func words(_ s: String) -> Set<String> {
        let stop: Set<String> = ["the", "and", "for", "with", "from", "that", "this", "send", "share", "review", "update",
                                 "call", "reply", "follow", "about", "need", "needs", "next", "week", "today", "tomorrow"]
        return Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !stop.contains($0) })
    }

    /// The front the user's past tagging points to for this title, if the evidence is clear:
    /// at least two votes, and ahead of the runner-up.
    static func learnedFront(title: String, active: [FrontService.ThemeRow]) -> FrontService.ThemeRow? {
        let activeIds = Set(active.map { $0.id })
        var votes: [String: Double] = [:]
        let w = words(title)
        guard !w.isEmpty else { return nil }
        for f in TodoStore.shared.feedback(events: ["front_set"], days: 180) {
            let fw = words(f.title ?? "")
            let shared = Double(w.intersection(fw).count)
            guard shared > 0 else { continue }
            if let to = f.to, activeIds.contains(to) { votes[to, default: 0] += shared }
            if let from = f.from, activeIds.contains(from), from != f.to { votes[from, default: 0] -= shared }
        }
        let ranked = votes.sorted { $0.value > $1.value }
        guard let best = ranked.first, best.value >= 2,
              ranked.count < 2 || best.value >= ranked[1].value + 1 else { return nil }
        return active.first { $0.id == best.key }
    }

    // MARK: - 2. People

    /// "KS" → "Kunal Shah" when the user corrected that name before (most recent correction wins).
    static func canonicalPerson(_ name: String?) -> String? {
        guard let n = name?.trimmingCharacters(in: .whitespaces), !n.isEmpty else { return name }
        let key = n.lowercased()
        for f in TodoStore.shared.feedback(events: ["person_set"], days: 365) {
            if let from = f.from?.lowercased(), from == key, let to = f.to, !to.isEmpty { return to }
        }
        return n
    }

    // MARK: - 3. Hiding suggestions

    /// Why a new suggestion should be hidden, or nil to show it.
    static func hideReason(title: String, person: String?, source: String) -> String? {
        let fb = TodoStore.shared.feedback(events: ["dismissed", "accepted"], days: 90)
        let w = words(title)
        // a) Close match to something dismissed before (and never accepted since).
        if w.count >= 2 {
            for f in fb where f.event == "dismissed" {
                let fw = words(f.title ?? "")
                guard !fw.isEmpty else { continue }
                let overlap = Double(w.intersection(fw).count) / Double(max(w.count, fw.count))
                if overlap >= 0.7 { return "Like one you dismissed: \"\(f.title ?? "")\"" }
            }
        }
        // b) A person whose suggestions you keep dismissing: 3+ dismissed, none accepted, in 90 days.
        if let p = person?.lowercased(), !p.isEmpty {
            let mine = fb.filter { ($0.person ?? "").lowercased() == p }
            let d = mine.filter { $0.event == "dismissed" }.count
            if d >= 3 && !mine.contains(where: { $0.event == "accepted" }) {
                return "You dismissed the last \(d) suggestions from \(p.split(separator: " ").first.map(String.init)?.capitalized ?? p)"
            }
        }
        // c) A source you almost never accept: 8+ decisions, under 15% accepted.
        let src = fb.filter { $0.source == source }
        if src.count >= 8 {
            let rate = Double(src.filter { $0.event == "accepted" }.count) / Double(src.count)
            if rate < 0.15 { return "You accept few suggestions from \(sourceLabel(source)) (\(Int(rate * 100))%)" }
        }
        return nil
    }

    // MARK: - 4. Order

    /// Predicted chance the user accepts this suggestion, from past decisions (Laplace-smoothed).
    static func acceptance(source: String, person: String?) -> Double {
        let fb = TodoStore.shared.feedback(events: ["dismissed", "accepted"], days: 120)
        func rate(_ rows: [TodoStore.Feedback]) -> Double {
            let a = Double(rows.filter { $0.event == "accepted" }.count)
            return (a + 1) / (Double(rows.count) + 2)
        }
        let bySource = rate(fb.filter { $0.source == source })
        guard let p = person?.lowercased(), !p.isEmpty else { return bySource }
        let byPerson = rate(fb.filter { ($0.person ?? "").lowercased() == p })
        return (bySource + byPerson) / 2
    }

    static func sourceLabel(_ s: String) -> String {
        ["commitment": "your threads", "whatsapp_self": "your notes to self", "meeting": "meeting notes"][s] ?? s
    }

    /// What Alfred has learned, in plain words (for the to-dos tab and settings).
    static func summary() -> [String: Any] {
        let fb = TodoStore.shared.feedback(events: ["dismissed", "accepted", "front_set", "person_set"], days: 120)
        let acc = fb.filter { $0.event == "accepted" }.count
        let dis = fb.filter { $0.event == "dismissed" }.count
        return ["accepted": acc, "dismissed": dis,
                "front_corrections": fb.filter { $0.event == "front_set" }.count,
                "person_corrections": fb.filter { $0.event == "person_set" }.count,
                "hidden_recently": TodoStore.shared.hidden().count]
    }
}
