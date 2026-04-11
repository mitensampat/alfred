import Foundation

/// Origin of a tenet pack — determines editability
typealias TenetPackOrigin = SkillOrigin  // Reuse: .user / .installed

/// Represents a coaching tenet pack loaded from a Markdown file.
/// Tenet packs define coaching philosophy — principles that guide HOW coaching is delivered.
/// They contain no prompts and generate no artifacts directly. Instead, skills reference them
/// to shape tone, priorities, and framing.
///
/// Stored as `.md` files in `~/.alfred/tenets/{user,installed}/`
struct TenetPackDefinition: Codable {
    let id: String              // filename without extension (e.g., "campbell-rules")
    let name: String            // from `# Title` line
    let description: String     // from **Description:** field
    let icon: String            // from **Icon:** field (emoji)
    let author: String?         // from **Author:** field
    let version: String?        // from **Version:** field
    let scope: [String]         // from **Scope:** field — which capabilities this applies to (e.g., ["all"], ["relationship", "leverage"])
    let principles: String      // content under ## Principles section — the actual tenets
    var enabled: Bool           // from tenets_state.json
    let origin: TenetPackOrigin // user-created vs installed

    /// Whether this tenet pack can be edited/deleted by the user
    var isEditable: Bool { origin == .user }

    /// Convert to API-friendly dictionary
    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "id": id,
            "name": name,
            "description": description,
            "icon": icon,
            "scope": scope,
            "enabled": enabled,
            "origin": origin.rawValue,
            "editable": isEditable
        ]
        if let author = author { dict["author"] = author }
        if let version = version { dict["version"] = version }
        return dict
    }

    /// Generate the Markdown file content for this tenet pack
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
        lines.append("**Scope:** \(scope.joined(separator: ", "))")
        lines.append("")
        lines.append("## Principles")
        lines.append(principles)
        lines.append("")
        return lines.joined(separator: "\n")
    }
}
