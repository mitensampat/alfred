import Foundation

/// Turns what the user typed after a meeting into separate follow-ups for the suggested tray
/// (docs/rewire/ROADMAP.md, "post-meeting capture"). The model splits and tidies the notes; without a
/// model (or if it fails) each line or sentence becomes one follow-up, so nothing typed is lost.
enum MeetingCapture {
    struct Item { let title: String; let person: String?; let due: String? }

    static func followUps(from text: String, meetingTitle: String, attendees: [String], ai: ClaudeAIService?) async -> [Item] {
        if let ai = ai, let items = await viaModel(text, meetingTitle, attendees, ai), !items.isEmpty { return items }
        return byLines(text, attendees: attendees)
    }

    private static func viaModel(_ text: String, _ title: String, _ attendees: [String], _ ai: ClaudeAIService) async -> [Item]? {
        let today = TodoStore.today()
        let prompt = """
        Notes the user typed right after a meeting called "\(title)". People in the meeting: \(attendees.isEmpty ? "unknown" : attendees.joined(separator: ", ")).
        Today is \(today).

        Split the notes into separate follow-up actions for the user. Rules:
        - One action per item, written as a short imperative (3 to 10 words), using the user's own words.
        - person: the one person from the meeting the action is for or with, using the exact name above; null if none.
        - due: YYYY-MM-DD only if the notes give a date or a day ("Friday", "next week"); otherwise null.
        - Skip anything that is not an action (plain notes, observations).

        Notes:
        \"\"\"
        \(text.prefix(4000))
        \"\"\"

        Reply with JSON only: {"items":[{"title":"...","person":null,"due":null}]}
        """
        guard let raw = try? await ai.generateText(prompt: prompt, maxTokens: 800),
              let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"),
              let data = String(raw[start...end]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = obj["items"] as? [[String: Any]] else { return nil }
        return rows.compactMap { r in
            guard let t = (r["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), t.count >= 3 else { return nil }
            let due = (r["due"] as? String).flatMap { TodoStore.dayFormatter.date(from: $0) != nil ? $0 : nil }
            return Item(title: t, person: (r["person"] as? String)?.trimmedNonEmpty, due: due)
        }
    }

    /// No model: one follow-up per line (or sentence), with the attendee it names.
    static func byLines(_ text: String, attendees: [String]) -> [Item] {
        var parts = text.components(separatedBy: .newlines)
        if parts.filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }).count <= 1 {
            parts = text.components(separatedBy: ". ")
        }
        return parts.compactMap { raw in
            let t = raw.trimmingCharacters(in: CharacterSet(charactersIn: "-•*·0123456789.) ").union(.whitespaces))
            guard t.count >= 3 else { return nil }
            let lower = t.lowercased()
            let who = attendees.first { a in
                guard let first = a.split(separator: " ").first?.lowercased() else { return false }
                return lower.contains(first)
            }
            return Item(title: t.prefix(1).uppercased() + t.dropFirst(), person: who, due: nil)
        }
    }
}
