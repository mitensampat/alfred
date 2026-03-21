import Foundation

/// Polls ~/.alfred/imports/ for dropped files (Claude exports, plain text)
/// Processes them through ReflectionExtractionService and moves to processed/
class ReflectionImportService {

    private let importsDir: String
    private let processedDir: String
    private let fileManager = FileManager.default

    init() {
        let homeDir = NSHomeDirectory()
        self.importsDir = "\(homeDir)/.alfred/imports"
        self.processedDir = "\(homeDir)/.alfred/imports/processed"

        // Ensure directories exist
        try? fileManager.createDirectory(atPath: importsDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(atPath: processedDir, withIntermediateDirectories: true)
    }

    /// Check for new files and return their contents with source type
    func checkForNewImports() -> [(content: String, source: String, fileHash: String)] {
        guard let files = try? fileManager.contentsOfDirectory(atPath: importsDir) else { return [] }

        var imports: [(content: String, source: String, fileHash: String)] = []

        for file in files {
            let filePath = "\(importsDir)/\(file)"

            // Skip directories (like processed/)
            var isDir: ObjCBool = false
            fileManager.fileExists(atPath: filePath, isDirectory: &isDir)
            if isDir.boolValue { continue }

            // Only process .json and .txt files
            let ext = (file as NSString).pathExtension.lowercased()
            guard ext == "json" || ext == "txt" || ext == "md" else { continue }

            guard let data = fileManager.contents(atPath: filePath),
                  let content = String(data: data, encoding: .utf8),
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            let fileHash = hashString(filePath + String(data.count))
            let source: String
            let parsedContent: String

            if ext == "json" {
                // Try to parse as Claude conversation export
                source = "claude_export"
                parsedContent = parseClaudeExport(content) ?? content
            } else {
                source = "manual"
                parsedContent = content
            }

            imports.append((content: parsedContent, source: source, fileHash: fileHash))

            // Move to processed
            let destPath = "\(processedDir)/\(file)"
            // If file already exists in processed, add timestamp
            let finalDest: String
            if fileManager.fileExists(atPath: destPath) {
                let timestamp = Int(Date().timeIntervalSince1970)
                let name = (file as NSString).deletingPathExtension
                finalDest = "\(processedDir)/\(name)_\(timestamp).\(ext)"
            } else {
                finalDest = destPath
            }

            do {
                try fileManager.moveItem(atPath: filePath, toPath: finalDest)
            } catch {
                print("⚠️ ReflectionImport: Failed to move \(file) to processed: \(error.localizedDescription)")
            }
        }

        return imports
    }

    // MARK: - Claude Export Parsing

    /// Parse a Claude.ai conversation export JSON into readable text
    private func parseClaudeExport(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        // Claude exports can vary in format — handle common structures
        if let conversation = parsed as? [String: Any] {
            return extractConversationText(from: conversation)
        } else if let conversations = parsed as? [[String: Any]] {
            // Multiple conversations in one file
            return conversations
                .compactMap { extractConversationText(from: $0) }
                .joined(separator: "\n\n---\n\n")
        }

        return nil
    }

    private func extractConversationText(from conversation: [String: Any]) -> String? {
        var lines: [String] = []

        // Try "chat_messages" key (common Claude export format)
        if let messages = conversation["chat_messages"] as? [[String: Any]] {
            for msg in messages {
                let sender = msg["sender"] as? String ?? "unknown"
                // Content may be nested
                let content: String
                if let textContent = msg["text"] as? String {
                    content = textContent
                } else if let contentArray = msg["content"] as? [[String: Any]] {
                    content = contentArray
                        .compactMap { $0["text"] as? String }
                        .joined(separator: "\n")
                } else {
                    continue
                }
                let role = sender == "human" ? "User" : "Assistant"
                lines.append("[\(role)] \(content)")
            }
        }
        // Try "messages" key
        else if let messages = conversation["messages"] as? [[String: Any]] {
            for msg in messages {
                let role = msg["role"] as? String ?? "unknown"
                let content: String
                if let text = msg["content"] as? String {
                    content = text
                } else if let contentArray = msg["content"] as? [[String: Any]] {
                    content = contentArray
                        .compactMap { $0["text"] as? String }
                        .joined(separator: "\n")
                } else {
                    continue
                }
                let label = role == "user" ? "User" : "Assistant"
                lines.append("[\(label)] \(content)")
            }
        }

        guard !lines.isEmpty else { return nil }

        let title = conversation["name"] as? String ?? conversation["title"] as? String ?? "Conversation"
        return "Conversation: \(title)\n\n" + lines.joined(separator: "\n\n")
    }

    // MARK: - Helpers

    private func hashString(_ input: String) -> String {
        var hash: UInt64 = 5381
        for byte in input.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return String(format: "%016llx", hash)
    }
}
