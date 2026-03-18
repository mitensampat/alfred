import Foundation

/// Origin of a coaching skill — determines editability
enum SkillOrigin: String, Codable {
    case user       // Created by the user, fully editable
    case installed  // Authored by a coach/expert, read-only (user can only toggle on/off)
}

/// Represents a coaching skill loaded from a Markdown file.
/// Skills are stored as `.md` files in `~/.alfred/skills/{user,installed}/` and generate
/// custom coaching cards alongside the built-in Leverage/Relationship/Avoidance/Attention cards.
struct SkillDefinition: Codable {
    let id: String              // filename without extension (e.g., "deep-work-guard")
    let name: String            // from `# Title` line
    let description: String     // from **Description:** field
    let icon: String            // from **Icon:** field (emoji)
    let dataSources: [String]   // from **Data Sources:** field (comma-separated)
    let frequency: String       // "daily" | "weekly"
    let tenets: String          // content under ## Tenets section
    let prompt: String          // content under ## Prompt section
    let fallback: String?       // from **Fallback:** field — static card text when no signals exist
    var enabled: Bool           // from skills_state.json
    var displayName: String?    // user-override display name (from skills_state.json)
    let origin: SkillOrigin     // user-created vs installed (coach-authored)
    let author: String?         // from **Author:** field (for installed skills)
    let version: String?        // from **Version:** field (for installed skills)

    /// The name to show in the UI and on cards (displayName override or original name)
    var effectiveName: String { displayName ?? name }

    /// Available data source types that skills can request
    static let validDataSources = Set([
        "calendar", "tasks", "messages", "commitments", "coaching_memory",
        "tasks_detailed", "messages_detailed", "commitments_by_person"
    ])

    /// Whether this skill can be edited/deleted by the user.
    /// User skills are fully editable. Tenet-only installed skills (frequency "none")
    /// allow editing tenets only — they're configuration, not authored coaching cards.
    var isEditable: Bool { origin == .user || isTenetOnly }

    /// Whether this is a tenet-only skill (no coaching card, just tenets injected into overlays)
    var isTenetOnly: Bool { frequency == "none" && dataSources.isEmpty }

    /// Convert to API-friendly dictionary
    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "id": id,
            "name": name,
            "effectiveName": effectiveName,
            "description": description,
            "icon": icon,
            "dataSources": dataSources,
            "frequency": frequency,
            "enabled": enabled,
            "origin": origin.rawValue,
            "editable": isEditable
        ]
        if let author = author { dict["author"] = author }
        if let version = version { dict["version"] = version }
        if let fallback = fallback { dict["fallback"] = fallback }
        if let displayName = displayName { dict["displayName"] = displayName }
        return dict
    }

    /// Generate the Markdown file content for this skill
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
        if let fallback = fallback {
            lines.append("**Fallback:** \(fallback)")
        }
        lines.append("**Data Sources:** \(dataSources.joined(separator: ", "))")
        lines.append("**Frequency:** \(frequency)")
        lines.append("")
        lines.append("## Tenets")
        lines.append(tenets)
        lines.append("")
        lines.append("## Prompt")
        lines.append(prompt)
        lines.append("")
        return lines.joined(separator: "\n")
    }
}
