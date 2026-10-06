import Foundation

/// Runs a decision definition over a batch of items with typed output.
///
/// The model sees each item under a short ref (`i1`, `i2`, …) and must echo that ref back; the
/// schema pins both the ref and the label to enums, so an answer can never land on the wrong
/// item or outside the menu. A dropped item simply comes back missing and the caller falls back.
enum DecisionEngine {
    struct Item {
        /// Caller's stable key — results are returned under it.
        let key: String
        /// What the model reads for this item.
        let text: String
    }

    static let chunkSize = 25

    /// Decide every item. Returns results keyed by `Item.key`; items the model skipped, and every
    /// item when the definition or the API is unavailable, are absent. Never throws — a decision
    /// failure must degrade to the caller's fallback, not break the pass that asked.
    static func decide(_ decisionId: String, items: [Item], ai: ClaudeAIService? = nil) async -> [String: DecisionResult] {
        guard !items.isEmpty, let def = DecisionLoader.shared.definition(id: decisionId) else { return [:] }
        guard let service = ai ?? AppConfig.load().map({ ClaudeAIService(config: $0.ai) }) else { return [:] }

        var seen = Set<String>()
        let unique = items.filter { seen.insert($0.key).inserted }

        var out: [String: DecisionResult] = [:]
        for start in stride(from: 0, to: unique.count, by: chunkSize) {
            let chunk = Array(unique[start..<min(start + chunkSize, unique.count)])
            for (k, v) in await decideChunk(def, chunk, service) { out[k] = v }
        }
        return out
    }

    private static func decideChunk(_ def: DecisionDefinition, _ chunk: [Item],
                                    _ service: ClaudeAIService) async -> [String: DecisionResult] {
        let refs = chunk.indices.map { "i\($0 + 1)" }
        let keyByRef = Dictionary(uniqueKeysWithValues: zip(refs, chunk.map { $0.key }))

        let listing = zip(refs, chunk).map { "[\($0)] \($1.text)" }.joined(separator: "\n")
        let prompt = """
        Items:
        \(listing)

        Return one decision per item, using its id in brackets. Set confidence to your probability \
        (0 to 1) that the label is correct — lower it when the item is ambiguous or thin.
        """

        do {
            let obj = try await service.generateStructured(
                prompt: prompt, system: def.prompt, schema: schema(refs: refs, options: def.options),
                maxTokens: 64 + 48 * chunk.count, useModel: def.model)
            var out: [String: DecisionResult] = [:]
            for row in (obj["decisions"] as? [[String: Any]]) ?? [] {
                guard let ref = row["id"] as? String, let key = keyByRef[ref],
                      let label = row["label"] as? String, def.options.contains(label) else { continue }
                let raw = (row["confidence"] as? Double) ?? (row["confidence"] as? NSNumber)?.doubleValue ?? 0
                let confidence = min(max(raw, 0), 1)   // schemas can't bound numbers; clamp here
                out[key] = DecisionResult(label: label, confidence: confidence, tier: def.tier(for: confidence))
            }
            return out
        } catch {
            print("[DecisionEngine] \(def.id) failed for \(chunk.count) items: \(error)")
            return [:]
        }
    }

    static func schema(refs: [String], options: [String]) -> [String: Any] {
        [
            "type": "object",
            "properties": [
                "decisions": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "id": ["type": "string", "enum": refs],
                            "label": ["type": "string", "enum": options],
                            "confidence": ["type": "number"],
                        ],
                        "required": ["id", "label", "confidence"],
                        "additionalProperties": false,
                    ],
                ],
            ],
            "required": ["decisions"],
            "additionalProperties": false,
        ]
    }
}
