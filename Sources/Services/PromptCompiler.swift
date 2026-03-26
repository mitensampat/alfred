import Foundation

/// Compiles a user-written prompt into a DataPlan — a list of capabilities to execute at runtime.
/// The compilation happens ONCE when the user saves the prompt (not on every request).
/// The DataPlan is stored alongside the prompt and executed with dynamic params at runtime.
class PromptCompiler {
    static let shared = PromptCompiler()

    /// A compiled data plan — the output of prompt compilation
    struct DataPlan: Codable {
        let capabilities: [PlannedCapability]
        let compiledAt: Date
        let sourcePromptHash: String  // detect if prompt changed and needs recompilation

        struct PlannedCapability: Codable {
            let capabilityId: String           // e.g. "commitments_with_person"
            let runtimeParams: [String]        // e.g. ["$attendee_names"]
            let matchedPhrase: String          // what in the prompt triggered this
        }
    }

    /// Compile a user prompt into a DataPlan by matching against the capability registry
    func compile(prompt: String) -> DataPlan {
        let matched = CapabilityRegistry.shared.matchCapabilities(for: prompt)

        let planned = matched.map { cap in
            // Find which phrase actually matched (for debugging/transparency)
            let lower = prompt.lowercased()
            let matchedPhrase = cap.triggerPhrases.first { phrase in
                if phrase.contains(".*") {
                    return lower.range(of: phrase, options: .regularExpression) != nil
                }
                return lower.contains(phrase)
            } ?? cap.triggerPhrases[0]

            return DataPlan.PlannedCapability(
                capabilityId: cap.id,
                runtimeParams: cap.runtimeParams,
                matchedPhrase: matchedPhrase
            )
        }

        return DataPlan(
            capabilities: planned,
            compiledAt: Date(),
            sourcePromptHash: Self.hash(prompt)
        )
    }

    /// Check if a data plan needs recompilation (prompt changed)
    func needsRecompilation(plan: DataPlan, currentPrompt: String) -> Bool {
        return plan.sourcePromptHash != Self.hash(currentPrompt)
    }

    private static func hash(_ text: String) -> String {
        // Simple hash — doesn't need to be cryptographic
        var hash: UInt64 = 5381
        for char in text.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(char)
        }
        return String(hash, radix: 16)
    }
}
