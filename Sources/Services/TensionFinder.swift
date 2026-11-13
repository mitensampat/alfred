import Foundation

/// Where the model disagrees with itself.
///
/// Every other pass reads the stream and concludes something about one subject at a time. That
/// is still only filing: a model that holds "move fast, decide on partial information" in one
/// workspace and "nothing ships until I would use it myself" in another has said something
/// genuinely interesting about the person, and until now nothing in Alfred ever put the two
/// sentences side by side.
///
/// This pass does exactly that and nothing else. It reads the active claims — beliefs Alfred
/// synthesized, values it proposed, values the user declared — and asks for the pairs that
/// actually pull against each other. Two kinds are worth having:
///
///   • **belief against belief** — two principles that cannot both be followed in the same
///     decision, which is where the real trade-off of a week lives.
///   • **declared against observed** — something the user says they value against what the
///     decisions show them doing. The synthesized claims *are* the decision record read back,
///     so the comparison needs no second trip through 1,776 decisions.
///
/// A tension is not a correction. It is stored as its own facet so it can be confirmed ("yes,
/// that is the trade-off I live with") or dismissed, and it is recomputed every run: one side
/// going away takes the tension with it.
enum TensionFinder {

    struct Outcome {
        var read = 0        // claims considered
        var found = 0       // tensions written
        var kept = 0        // tensions re-found, left as they are
        var retired = 0     // tensions this run no longer holds
        var failures = 0
        var model = ""
    }

    /// At most this many live at once. A page of twelve tensions is a page nobody reads, and a
    /// model asked for twelve will happily manufacture the back half.
    static let maxTensions = 6

    @discardableResult
    static func run() async -> Outcome {
        var out = Outcome()
        guard let config = AppConfig.load() else { return out }
        let store = SelfModelStore.shared
        let ai = ClaudeAIService(config: config.ai)
        let preferred = config.ai.effectiveSynthesisModel
        out.model = preferred

        // ---- The claims worth comparing ----
        // Synthesized beliefs and every live value. One-thread fragments are deliberately out:
        // a contradiction between two artifacts of single threads is usually a contradiction
        // between two threads, not inside the person.
        func live(_ kind: String) -> [[String: Any]] {
            store.getFacets(kind: kind).filter {
                let v = ($0["user_verdict"] as? String) ?? ""
                return v != "dismissed"
            }
        }
        let beliefs = live("belief")
            .filter { ($0["origin"] as? String) == "synthesized" || ($0["origin"] as? String) == "declared" }
            .sorted { (($0["confidence"] as? Double) ?? 0) > (($1["confidence"] as? Double) ?? 0) }
            .prefix(28)
        let values = live("value")
            .sorted { a, b in
                let da = (a["origin"] as? String) == "declared", db = (b["origin"] as? String) == "declared"
                if da != db { return da }
                return ((a["confidence"] as? Double) ?? 0) > ((b["confidence"] as? Double) ?? 0)
            }
            .prefix(14)
        guard beliefs.count + values.count >= 6 else { return out }
        out.read = beliefs.count + values.count

        var refs: [String: [String: Any]] = [:]
        var lines: [String] = []
        for (i, b) in beliefs.enumerated() {
            let ref = "b\(i + 1)"
            refs[ref] = b
            let meta = (b["metadata"] as? [String: String]) ?? [:]
            let ws = (meta["workspace"] ?? "").isEmpty ? "" : " — \(meta["workspace"]!)"
            lines.append("[\(ref)] (belief\(ws)) \((b["statement"] as? String) ?? "")")
        }
        for (i, v) in values.enumerated() {
            let ref = "v\(i + 1)"
            refs[ref] = v
            let declared = (v["origin"] as? String) == "declared"
            lines.append("[\(ref)] (value, \(declared ? "they stated this themselves" : "Alfred's read from their decisions")) "
                + ((v["statement"] as? String) ?? ""))
        }

        let prompt = """
        Claims Alfred currently holds about this person:
        \(lines.joined(separator: "\n"))
        """

        var parsed = await ask(ai, prompt: prompt, model: preferred)
        if parsed == nil, preferred != config.ai.model {
            parsed = await ask(ai, prompt: prompt, model: config.ai.model)
            if parsed != nil { out.model = config.ai.model }
        }
        guard let found = parsed else { out.failures += 1; return out }

        // ---- Write ----
        let standing = store.getFacets(kind: "tension")
        var writtenIds = Set<String>()
        var written = 0
        for t in found {
            guard written < maxTensions else { break }
            let statement = ((t["tension"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard statement.count >= 20 else { continue }
            guard let a = refs[normalize(t["left"] as? String)],
                  let b = refs[normalize(t["right"] as? String)],
                  let aid = a["id"] as? String, let bid = b["id"] as? String,
                  aid != bid else { continue }

            // Id from the pair, so the same tension keeps its row (and your verdict) across
            // runs however the sentence is phrased next week.
            let id = "tension_" + fnv1a([aid, bid].sorted().joined(separator: "|"))
            if standing.contains(where: { ($0["id"] as? String) == id }) { out.kept += 1 }
            let conf = min((a["confidence"] as? Double) ?? 0.6, (b["confidence"] as? Double) ?? 0.6)
            let sides = [a, b].map { f -> [String: String] in
                ["source_type": (f["kind"] as? String) ?? "claim",
                 "snippet": String(((f["statement"] as? String) ?? "").prefix(220)),
                 "ts": (f["last_seen"] as? String) ?? ""]
            }
            _ = store.upsertFacet(
                id: id, kind: "tension", statement: statement,
                confidence: conf, status: "active",
                firstSeen: nil, lastSeen: ISO8601DateFormatter().string(from: Date()),
                trajectory: [], evidence: sides,
                metadata: [
                    "left": aid, "right": bid,
                    "left_text": String(((a["statement"] as? String) ?? "").prefix(220)),
                    "right_text": String(((b["statement"] as? String) ?? "").prefix(220)),
                    "cost": String((((t["cost"] as? String) ?? "")).prefix(300))
                ],
                origin: "synthesized", preserveUserMeta: true)
            writtenIds.insert(id)
            written += 1
            out.found += 1
        }

        // A tension this run no longer holds — because a side was retired, or because the claims
        // moved — drops out. Anything the user confirmed or re-worded stays.
        for stored in standing {
            guard let id = stored["id"] as? String, !writtenIds.contains(id) else { continue }
            let v = (stored["user_verdict"] as? String) ?? ""
            guard v != "confirmed", v != "kept", (stored["renamed"] as? Bool) != true else { continue }
            if store.archiveFacet(id: id) { out.retired += 1 }
        }
        return out
    }

    // MARK: - The ask

    private static let system = """
    You are looking at the claims an assistant currently holds about one person — what they \
    believe, and what they protect when two good things conflict. Each has a reference like \
    [b3] or [v1].

    Find the places where these claims pull against each other. Return only pairs where \
    following one makes following the other harder in a real decision.

    What counts:
    - Two beliefs that cannot both be honoured at once ("decide fast on partial information" \
    against "nothing ships until it is right").
    - Something they stated they value against what their decisions show them doing. The values \
    marked "Alfred's read from their decisions" ARE the behavioural record — a clash between one \
    of those and a value they stated themselves is the most useful thing you can return.

    What does not count, and must not be returned:
    - Two claims that are merely about different subjects.
    - A claim being more specific than another, or restating it in other words.
    - Anything you have to strain to describe as a conflict. Three real tensions beat eight \
    manufactured ones, and returning none is a correct answer.

    For each one:
    - tension: one sentence naming the conflict, in plain second person, no preamble. Name both \
    sides in it: "You decide fast on thin information, and you also refuse to ship anything you \
    would not use yourself."
    - cost: one short sentence on what this actually costs them — what gets dropped, delayed or \
    done twice when both pull at once. Concrete, not a platitude.
    - left / right: the two refs.
    """

    private static func schema() -> [String: Any] {
        [
            "type": "object",
            "properties": [
                "tensions": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "tension": ["type": "string"],
                            "cost": ["type": "string"],
                            "left": ["type": "string"],
                            "right": ["type": "string"]
                        ],
                        "required": ["tension", "cost", "left", "right"],
                        "additionalProperties": false
                    ]
                ]
            ],
            "required": ["tensions"],
            "additionalProperties": false
        ]
    }

    private static func ask(_ ai: ClaudeAIService, prompt: String,
                            model: String) async -> [[String: Any]]? {
        do {
            let obj = try await ai.generateStructured(
                prompt: prompt, system: system, schema: schema(), maxTokens: 2000, useModel: model)
            return (obj["tensions"] as? [[String: Any]]) ?? []
        } catch {
            print("[TensionFinder] failed on \(model): \(error)")
            return nil
        }
    }

    /// "[b3]", "b3", "b3 (the launch one)" → "b3".
    private static func normalize(_ raw: String?) -> String {
        guard let raw = raw?.lowercased() else { return "" }
        return raw.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .first { !$0.isEmpty } ?? ""
    }

    private static func fnv1a(_ s: String) -> String {
        var h: UInt64 = 1469598103934665603
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return String(h, radix: 16)
    }
}
