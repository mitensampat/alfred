import Foundation

/// The message behind a to-do.
///
/// A to-do extracted from a conversation is a three-to-eight word title, and on its own that is
/// often not enough to act on ("Meet on Thursday for this"). The words it came from answer the
/// question the title raises, so every to-do that has a thread should carry them: one line on the
/// row, and the surrounding conversation in the detail sheet.
///
/// New commitments get their evidence at extraction (`CommitmentAnalyzer` records it under the
/// commitment hash). This file covers everything else: to-dos that existed before evidence was
/// kept, and the on-demand read of the conversation around a to-do.
///
/// Finding the source of an old to-do needs no model. The extraction prompt requires a title to
/// use only words that appear in the messages, so the source is the message that shares the most
/// of the title's words — and when no message clears the bar, the to-do simply shows no quote,
/// which is better than showing the wrong one.
enum TodoEvidence {

    struct Msg {
        let sender: String
        let fromMe: Bool
        let text: String
        let at: Date
    }

    private static let iso = ISO8601DateFormatter()

    // MARK: - Reading a thread

    /// A WhatsApp thread's messages since a date, oldest first. Empty when the bridge is not
    /// running or the thread is not a WhatsApp one.
    static func threadMessages(jid: String, since: Date, limit: Int = 3000) async -> [Msg] {
        guard jid.contains("@") else { return [] }
        let addr = ProcessInfo.processInfo.environment["WA_BRIDGE_ADDR"] ?? "127.0.0.1:8790"
        var c = URLComponents(string: "http://\(addr)/messages")
        c?.queryItems = [URLQueryItem(name: "chat", value: jid),
                         URLQueryItem(name: "since", value: String(Int(since.timeIntervalSince1970))),
                         URLQueryItem(name: "limit", value: String(limit))]
        guard let url = c?.url else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows.compactMap { r -> Msg? in
            guard let text = (r["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                  let ts = r["timestamp"] as? Double else { return nil }
            return Msg(sender: (r["sender_name"] as? String) ?? "", fromMe: (r["is_from_me"] as? Bool) ?? false,
                       text: text, at: Date(timeIntervalSince1970: ts))
        }.sorted { $0.at < $1.at }
    }

    // MARK: - Matching a title to its message

    private static let stop: Set<String> = ["the", "and", "for", "with", "that", "this", "from", "about", "have", "will",
                                            "your", "you", "them", "their", "her", "his", "him", "its", "are", "was",
                                            "when", "what", "over", "into", "next", "few", "all", "any", "but", "not"]

    static func words(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 && !stop.contains($0) }
    }

    /// Two words are the same word if they are equal or share a five-letter stem
    /// ("finalize" / "finalised", "update" / "updates").
    private static func same(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let n = min(a.count, b.count)
        return n >= 5 && a.prefix(5) == b.prefix(5)
    }

    /// The message a title most plausibly came from, or nil when nothing is close enough.
    /// A short title (three words or fewer) must appear whole; a longer one needs 60% of its words.
    /// Ties go to the most recent message, because a promise is usually restated closest to when
    /// it was extracted. The bar is set for precision: a wrong quote is worse than none.
    static func bestMatch(title: String, messages: [Msg]) -> Msg? {
        let want = Array(Set(words(title)))
        guard want.count >= 2 else { return nil }
        let need = want.count <= 3 ? want.count : Int((0.6 * Double(want.count)).rounded(.up))
        var best: (msg: Msg, score: Double)?
        for m in messages {
            let have = Set(words(m.text))
            guard !have.isEmpty else { continue }
            let hits = want.filter { w in have.contains { same(w, $0) } }.count
            guard hits >= need else { continue }
            let score = Double(hits) / Double(want.count)
            if score >= (best?.score ?? 0) { best = (m, score) }
        }
        return best?.msg
    }

    // MARK: - Backfill

    private static var lastBackfill: Date?
    private static var running = false
    private static let gate = NSLock()

    /// Run the backfill in the background, at most once every six hours per process.
    static func backfillIfDue() {
        gate.lock()
        let due = !running && (lastBackfill.map { Date().timeIntervalSince($0) > 6 * 3600 } ?? true)
        if due { running = true }
        gate.unlock()
        guard due else { return }
        Task.detached(priority: .utility) {
            let r = await backfill()
            if (r["found"] ?? 0) > 0 { print("🧾 To-do evidence: \(r["found"] ?? 0) of \(r["checked"] ?? 0) to-dos matched to their source message") }
            finished()
        }
    }

    private static func finished() { gate.lock(); running = false; lastBackfill = Date(); gate.unlock() }

    /// Give every live to-do that has a thread, and no evidence yet, the message it came from.
    @discardableResult
    static func backfill() async -> [String: Int] {
        let store = TodoStore.shared
        let todos = store.all(where: "status IN ('open', 'suggested') AND evidence IS NULL")
        var checked = 0, found = 0
        var threads: [String: [Msg]] = [:]
        for t in todos {
            // Evidence recorded at extraction wins: it is the model's own pointer, not a guess.
            let hashes = store.sources(of: t.id).filter { $0.source == "commitment" }.map { $0.ref }
            if let ev = hashes.lazy.compactMap({ CommitmentScanTracker.shared.evidence(hash: $0) }).first {
                var f: [String: Any?] = ["evidence": ev.quote, "evidence_by": ev.saidBy ?? NSNull(), "evidence_at": ev.saidAt ?? NSNull()]
                if t.because == nil, let b = ev.because { f["because"] = b }
                store.update(t.id, f, markDirty: false, touch: false)
                found += 1
                continue
            }
            guard let jid = t.threadId, jid.contains("@"), !jid.hasSuffix("@g.us") else { continue }
            checked += 1
            let created = iso.date(from: t.createdAt) ?? Date()
            if threads[jid] == nil {
                threads[jid] = await threadMessages(jid: jid, since: Date().addingTimeInterval(-90 * 86400))
            }
            // Only what had been said by the time the to-do existed (a day's slack for clock and
            // scan lag), and not older than three weeks before it.
            let window = (threads[jid] ?? []).filter {
                $0.at <= created.addingTimeInterval(86400) && $0.at >= created.addingTimeInterval(-21 * 86400)
            }
            guard let m = bestMatch(title: t.title, messages: window) else { continue }
            store.update(t.id, ["evidence": String(m.text.prefix(600)), "evidence_by": m.fromMe ? "You" : m.sender,
                                "evidence_at": iso.string(from: m.at)], markDirty: false, touch: false)
            found += 1
        }
        return ["checked": checked, "found": found, "without_evidence": todos.count]
    }

    // MARK: - The because line

    /// Whether every proper noun in a written line appears in the text it was written from.
    ///
    /// A model asked to summarise will sometimes supply a detail the messages never gave: a name
    /// spelled its own way, a month, a place. Those are the errors that matter in a line the user
    /// reads as fact, and they are checkable without a second model: a capitalised word that is
    /// not in the conversation did not come from the conversation. A line that fails is dropped,
    /// and the to-do shows where it came from instead.
    static func grounded(_ line: String, corpus: String) -> Bool {
        let hay = corpus.lowercased()
        let tokens = line.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
        for (i, w) in tokens.enumerated() where i > 0 {
            guard w.count >= 3, let f = w.first, f.isUppercase else { continue }
            var base = w.lowercased()
            if base.hasSuffix("s"), !hay.contains(base) { base.removeLast() }   // "Shreya's" splits to "Shreya", "s"; plurals
            if !hay.contains(base) { return false }
        }
        return true
    }

    /// The messages a because line is written from: around the source message when it is known,
    /// otherwise what was being said when the to-do was made.
    private static func window(for t: TodoStore.Todo, in all: [Msg]) -> [Msg] {
        if let at = t.evidenceAt.flatMap({ iso.date(from: $0) }),
           let i = all.firstIndex(where: { abs($0.at.timeIntervalSince(at)) < 1 }) {
            // The same sitting only: a day before the message and a few hours after it. Without the
            // time bound, a quiet thread hands the model next week's unrelated messages as "context".
            let near = all[max(0, i - 10)...min(all.count - 1, i + 3)]
            return near.filter { $0.at >= at.addingTimeInterval(-86400) && $0.at <= at.addingTimeInterval(6 * 3600) }
        }
        let created = iso.date(from: t.createdAt) ?? Date()
        return Array(all.filter { $0.at >= created.addingTimeInterval(-4 * 86400) && $0.at <= created.addingTimeInterval(86400) }.suffix(20))
    }

    private static var lastBecause: Date?
    private static var becauseRunning = false

    private static func claimBecauseRun() -> Bool {
        gate.lock(); defer { gate.unlock() }
        let due = !becauseRunning && (lastBecause.map { Date().timeIntervalSince($0) > 6 * 3600 } ?? true)
        if due { becauseRunning = true }
        return due
    }
    private static func releaseBecauseRun() { gate.lock(); becauseRunning = false; lastBecause = Date(); gate.unlock() }

    /// Write missing because lines in the background, at most once every six hours per process.
    /// New commitments get theirs at extraction; this catches whatever arrived another way.
    static func writeBecauseIfDue(ai: ClaudeAIService?, userName: String) {
        guard let ai = ai, claimBecauseRun() else { return }
        Task.detached(priority: .utility) {
            let r = await writeBecause(ai: ai, userName: userName)
            if (r["written"] ?? 0) > 0 { print("🧾 To-do context: wrote \(r["written"] ?? 0) because lines (\(r["unclear"] ?? 0) left unclear)") }
            releaseBecauseRun()
        }
    }

    /// Give each live to-do that has a conversation, and no because line yet, one sentence saying
    /// what it is about. One model call per conversation (six to-dos at most per call).
    ///
    /// The model is told to return an empty string when the messages do not make the subject
    /// clear, and that answer is kept (as "") so the to-do is not asked about again: it then shows
    /// the plain fact of where it came from, which is true, instead of a sentence that might not be.
    @discardableResult
    static func writeBecause(ai: ClaudeAIService, userName: String) async -> [String: Int] {
        let store = TodoStore.shared
        let todos = store.all(where: "status IN ('open', 'suggested') AND because IS NULL AND thread_id LIKE '%@%'")
            .filter { !($0.threadId ?? "").hasSuffix("@g.us") }
        var byThread: [String: [TodoStore.Todo]] = [:]
        for t in todos { byThread[t.threadId ?? "", default: []].append(t) }
        let me = userName.split(separator: " ").first.map(String.init) ?? "the user"
        let tf = DateFormatter(); tf.dateFormat = "d MMM HH:mm"; tf.locale = Locale(identifier: "en_US_POSIX")
        var written = 0, unclear = 0, calls = 0, rejected = 0
        let schema: [String: Any] = [
            "type": "object", "additionalProperties": false, "required": ["items"],
            "properties": ["items": ["type": "array", "items": [
                "type": "object", "additionalProperties": false, "required": ["n", "because"],
                "properties": ["n": ["type": "integer"], "because": ["type": "string"]]]]]]
        for (jid, rows) in byThread {
            let all = await threadMessages(jid: jid, since: Date().addingTimeInterval(-90 * 86400))
            guard !all.isEmpty else { continue }   // bridge down or history gone: try again another time
            var start = 0
            while start < rows.count {
                let chunk = Array(rows[start..<min(rows.count, start + 6)]); start += 6
                var body = ""
                var asked: [Int: TodoStore.Todo] = [:]
                var corpus: [Int: String] = [:]
                for (i, t) in chunk.enumerated() {
                    let w = window(for: t, in: all)
                    guard !w.isEmpty else { store.update(t.id, ["because": ""], markDirty: false, touch: false); unclear += 1; continue }
                    asked[i + 1] = t
                    corpus[i + 1] = ([t.title, t.person ?? "", me, userName, t.evidence ?? ""] + w.map { $0.sender + " " + $0.text }).joined(separator: " ")
                    let other = t.person ?? "the other person"
                    body += "\nTO-DO \(i + 1)\nTitle: \(t.title)\n"
                    body += "Who owes whom: " + (t.resolvedDirection == "they_owe" ? "\(other) owes \(me) this" : "\(me) owes \(other) this") + "\n"
                    if let q = t.evidence { body += "Source message: \(String(q.prefix(400)))\n" }
                    body += "Messages around it:\n" + w.map { "[\(tf.string(from: $0.at))] \($0.fromMe ? me : $0.sender): \(String($0.text.prefix(300)))" }.joined(separator: "\n") + "\n"
                }
                guard !asked.isEmpty else { continue }
                let prompt = """
                These to-dos were extracted from a WhatsApp conversation between \(me) and someone else. For each one, write ONE sentence (at most 25 words) that lets \(me) read the to-do cold, weeks from now: what it is about and what prompted it.

                Rules:
                - Address \(me) as "you". Use first names only for everyone else.
                - Say first what the to-do actually is (the action and what it concerns), then what prompted it if the messages show that. Background alone is not an answer.
                - The "Who owes whom" line says who has to act. If the messages plainly show it is the other way round, describe what the messages show.
                - Resolve "it", "this", "them", "her" from the messages when the conversation makes the referent clear.
                - Use only what the messages say. Never guess, and never add a fact that is not in them.
                - Copy names exactly as they are spelled in the messages. Do not add a date, weekday or place the messages do not state.
                - If the messages shown do not make clear what the to-do is about, return an empty string for it. An empty string is a good answer; a plausible guess is a bad one.
                - Do not restate the title: say what the title leaves out.
                - Plain sentence, no quotation marks, no preamble.
                \(body)
                Reply with one item per to-do: n is the to-do number.
                """
                calls += 1
                guard let obj = try? await ai.generateStructured(prompt: prompt, schema: schema, maxTokens: 900),
                      let items = obj["items"] as? [[String: Any]] else { continue }
                for it in items {
                    guard let n = it["n"] as? Int, let t = asked[n] else { continue }
                    var line = ((it["because"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !line.isEmpty, !grounded(line, corpus: corpus[n] ?? "") { line = ""; rejected += 1 }
                    store.update(t.id, ["because": String(line.prefix(300))], markDirty: false, touch: false)
                    if line.isEmpty { unclear += 1 } else { written += 1 }
                }
            }
        }
        return ["candidates": todos.count, "written": written, "unclear": unclear, "calls": calls, "rejected": rejected]
    }

    // MARK: - The conversation around a to-do

    /// The to-do with the messages around its source, for the detail sheet. With evidence, the
    /// window is centred on that message; without it, it is what was being said when the to-do
    /// was made.
    static func context(for t: TodoStore.Todo) async -> [String: Any] {
        var out: [String: Any] = ["todo": t.dict, "messages": [[String: Any]](), "thread": false]
        guard let jid = t.threadId, jid.contains("@") else { return out }
        let anchor = t.evidenceAt.flatMap { iso.date(from: $0) } ?? iso.date(from: t.createdAt) ?? Date()
        let all = await threadMessages(jid: jid, since: anchor.addingTimeInterval(-5 * 86400), limit: 1500)
        guard !all.isEmpty else { return out }
        var picked: [Msg]
        var sourceIndex: Int? = nil
        if t.evidenceAt != nil, let i = all.firstIndex(where: { abs($0.at.timeIntervalSince(anchor)) < 1 }) {
            // Neighbours in the same sitting, not whatever was said days later in a quiet thread.
            let src = all[i]
            let before = all[max(0, i - 5)..<i].filter { $0.at >= src.at.addingTimeInterval(-86400) }
            let after = all[(i + 1)..<min(all.count, i + 4)].filter { $0.at <= src.at.addingTimeInterval(6 * 3600) }
            picked = Array(before) + [src] + Array(after); sourceIndex = before.count
        } else {
            picked = Array(all.filter { $0.at <= anchor.addingTimeInterval(86400) }.suffix(8))
        }
        out["thread"] = true
        out["messages"] = picked.enumerated().map { i, m -> [String: Any] in
            ["from": m.fromMe ? "You" : m.sender, "me": m.fromMe, "text": String(m.text.prefix(700)),
             "at": iso.string(from: m.at), "source": i == sourceIndex]
        }
        // How the conversation has moved since: the newest message, if it is later than the window.
        if let last = all.last, let shown = picked.last, last.at > shown.at {
            out["latest"] = ["from": last.fromMe ? "You" : last.sender, "me": last.fromMe,
                             "text": String(last.text.prefix(300)), "at": iso.string(from: last.at)]
        }
        return out
    }
}
