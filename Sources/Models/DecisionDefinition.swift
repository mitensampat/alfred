import Foundation

/// A decision is a pick-from-a-fixed-menu judgement Alfred makes about an item: which durability
/// class a belief is, which category a meeting is. Each one is a Markdown file — like skills and
/// lenses — holding the menu, the confidence thresholds, the fallback, and the instructions, so
/// it can be read, tuned, and evaluated without touching the code that consumes it.
///
/// Every result carries a confidence, and one shared policy turns that confidence into a tier:
///   • act     — confident enough to apply on its own
///   • propose — plausible; surface it for the user to accept
///   • ask     — too unsure to use; the caller falls back
enum DecisionTier: String, Codable {
    case act, propose, ask
}

enum DecisionOrigin: String, Codable {
    case builtIn = "built_in"
    case installed
    case user
}

struct DecisionResult {
    let label: String
    let confidence: Double
    let tier: DecisionTier
}

struct DecisionDefinition {
    let id: String
    let name: String
    let description: String
    /// The menu. For built-in decisions the code maps these labels onto its own enums, so the
    /// loader keeps them fixed no matter what the file says.
    let options: [String]
    /// What the caller should use when the result is missing or lands in the `ask` tier.
    let fallback: String
    let actAt: Double
    let proposeAt: Double
    let model: String
    let prompt: String
    let origin: DecisionOrigin

    func tier(for confidence: Double) -> DecisionTier {
        if confidence >= actAt { return .act }
        if confidence >= proposeAt { return .propose }
        return .ask
    }

    func toMarkdown() -> String {
        """
        # \(name)

        **Description:** \(description)
        **Options:** \(options.joined(separator: ", "))
        **Fallback:** \(fallback)
        **Act At:** \(actAt)
        **Propose At:** \(proposeAt)
        **Model:** \(model)

        ## Prompt
        \(prompt)
        """
    }
}
