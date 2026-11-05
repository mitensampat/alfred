import Foundation

/// To-do commands typed into your own WhatsApp chat (docs/rewire/SPEC.md, "channels"), handled
/// alongside @schedule by ScheduleService's self-chat watcher:
///
///   todo <text>   add a to-do (you typed it, so it goes straight onto the list, not the tray)
///   done <text>   close the open to-do that best matches
///   now           the top 3, as the now tab ranks them
///
/// Returns the reply to send back, or nil when the line is not a to-do command.
enum TodoSelfChat {
    static func handle(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()

        if lower == "now" || lower == "@now" {
            let now = TodoService.now(schedules: [], userFirstName: "", coach: false)
            var items: [[String: Any]] = []
            if let p = now["pinned"] as? [String: Any] { items.append(p) }
            items += (now["top"] as? [[String: Any]]) ?? []
            guard !items.isEmpty else { return "Nothing is waiting on you. You are clear." }
            let lines = items.prefix(3).enumerated().map { i, t -> String in
                let who = (t["person"] as? String) ?? (t["front_name"] as? String)
                return "\(i + 1). \(t["title"] as? String ?? "")" + (who.map { " (\($0))" } ?? "")
            }
            return "Now:\n" + lines.joined(separator: "\n")
        }

        if let body = argument(text, after: ["todo", "to-do", "@todo"]) {
            guard body.count >= 2 else { return "What is the to-do? Send: todo <what to do>" }
            let r = TodoStore.shared.upsert(title: body, status: .open, source: "capture",
                                            sourceRef: "selfchat:" + UUID().uuidString, sourceNote: "Added from WhatsApp")
            return r.created ? "Added: \(body)" : "Already on your list: \(TodoStore.shared.get(r.id)?.title ?? body)"
        }

        if let body = argument(text, after: ["done", "@done"]) {
            guard let match = bestMatch(body) else { return "No open to-do matches \"\(body)\". Send: now, to see your list." }
            _ = TodoService.complete(match.id)
            return "Done: \(match.title)"
        }
        return nil
    }

    /// "todo buy x", "todo: buy x" → "buy x".
    private static func argument(_ text: String, after words: [String]) -> String? {
        let lower = text.lowercased()
        for w in words where lower == w || lower.hasPrefix(w + " ") || lower.hasPrefix(w + ":") {
            return String(text.dropFirst(w.count)).trimmingCharacters(in: CharacterSet(charactersIn: ": ").union(.whitespacesAndNewlines))
        }
        return nil
    }

    /// The open to-do sharing the most words with `query` (at least half of the query's words).
    static func bestMatch(_ query: String) -> TodoStore.Todo? {
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 })
        }
        let q = words(query)
        guard !q.isEmpty else { return nil }
        let scored = TodoStore.shared.openMine().map { t -> (TodoStore.Todo, Double) in
            let w = words(t.title + " " + (t.person ?? ""))
            return (t, Double(q.intersection(w).count) / Double(q.count))
        }.filter { $0.1 >= 0.5 }.sorted { $0.1 > $1.1 }
        guard let best = scored.first else { return nil }
        // Two equally good matches: do not guess.
        if scored.count > 1 && scored[1].1 == best.1 { return nil }
        return best.0
    }
}
