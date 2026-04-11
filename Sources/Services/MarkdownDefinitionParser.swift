import Foundation

/// Shared parsing utilities for Markdown-based coaching definitions.
/// Used by SkillLoader, TenetPackLoader, and AnalysisLensLoader to parse
/// the common `**Key:** value` metadata and `## Section` header format.
enum MarkdownDefinitionParser {

    /// Extract a `**Key:** value` metadata field from markdown content
    static func parseMetadataField(content: String, key: String) -> String? {
        let pattern = "\\*\\*\(NSRegularExpression.escapedPattern(for: key)):\\*\\*\\s*(.+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }

        let range = NSRange(content.startIndex..., in: content)
        guard let match = regex.firstMatch(in: content, range: range),
              let valueRange = Range(match.range(at: 1), in: content) else {
            return nil
        }

        return String(content[valueRange]).trimmingCharacters(in: .whitespaces)
    }

    /// Extract content under a `## Header` section (up to next `##` or end of file)
    static func parseSection(content: String, header: String) -> String? {
        let lines = content.components(separatedBy: "\n")
        var capturing = false
        var sectionLines: [String] = []

        for line in lines {
            if line.hasPrefix("## ") {
                if capturing {
                    break
                }
                let sectionName = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                if sectionName.lowercased() == header.lowercased() {
                    capturing = true
                    continue
                }
            } else if capturing {
                sectionLines.append(line)
            }
        }

        let result = sectionLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    /// Extract the title from the first `# Title` line
    static func parseTitle(content: String) -> String? {
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") && !trimmed.hasPrefix("## ") {
                return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Generate an ID from a filename (basename without extension, lowercased)
    static func idFromFilename(_ path: String) -> String {
        let filename = (path as NSString).lastPathComponent
        return (filename as NSString).deletingPathExtension.lowercased()
    }

    /// Generate a slug-style ID from a name (lowercase, spaces → hyphens, strip non-alphanum)
    static func slugFromName(_ name: String) -> String {
        return name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
    }
}
