import Foundation

/// Origin of an analysis lens — determines editability
typealias AnalysisLensOrigin = SkillOrigin  // Reuse: .user / .installed

/// Represents an analysis lens loaded from a Markdown file.
/// Analysis lenses detect patterns in data and emit structured signals.
/// They run in parallel (Layer 1) using Haiku for fast, cheap extraction.
/// Signals are persisted to `~/.alfred/signal_history/{lens-id}/YYYY-MM-DD.json`
/// for temporal coaching ("this is the third week in a row...").
///
/// Stored as `.md` files in `~/.alfred/analyses/{user,installed}/`
struct AnalysisLensDefinition: Codable {
    let id: String              // filename without extension (e.g., "avoidance-detector")
    let name: String            // from `# Title` line
    let description: String     // from **Description:** field
    let icon: String            // from **Icon:** field (emoji)
    let author: String?         // from **Author:** field
    let version: String?        // from **Version:** field
    let dataSources: [String]   // from **Data Sources:** field (comma-separated)
    let signals: String         // from **Signals:** field — human-readable description of what this lens emits
    let prompt: String          // content under ## Prompt section — extraction prompt with few-shot examples
    let outputSchema: String?   // content under ## Output Schema section — JSON schema for structured output
    var enabled: Bool           // from analyses_state.json
    let origin: AnalysisLensOrigin // user-created vs installed

    /// Available data source types that lenses can request
    static let validDataSources = Set([
        "calendar", "tasks", "messages", "commitments", "coaching_memory",
        "tasks_detailed", "messages_detailed", "commitments_by_person"
    ])

    /// Whether this lens can be edited/deleted by the user
    var isEditable: Bool { origin == .user }

    /// Convert to API-friendly dictionary
    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "id": id,
            "name": name,
            "description": description,
            "icon": icon,
            "dataSources": dataSources,
            "signals": signals,
            "enabled": enabled,
            "origin": origin.rawValue,
            "editable": isEditable
        ]
        if let author = author { dict["author"] = author }
        if let version = version { dict["version"] = version }
        if let outputSchema = outputSchema { dict["outputSchema"] = outputSchema }
        return dict
    }

    /// Generate the Markdown file content for this lens
    func toMarkdown() -> String {
        var lines: [String] = []
        lines.append("# \(name)")
        lines.append("")
        lines.append("**Description:** \(description)")
        lines.append("**Icon:** \(icon)")
        if let author = author {
            lines.append("**Author:** \(author)")
        }
        if let version = version {
            lines.append("**Version:** \(version)")
        }
        lines.append("**Signals:** \(signals)")
        lines.append("**Data Sources:** \(dataSources.joined(separator: ", "))")
        lines.append("")
        if let schema = outputSchema {
            lines.append("## Output Schema")
            lines.append(schema)
            lines.append("")
        }
        lines.append("## Prompt")
        lines.append(prompt)
        lines.append("")
        return lines.joined(separator: "\n")
    }
}
