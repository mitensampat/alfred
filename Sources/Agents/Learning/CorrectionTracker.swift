import Foundation

/// Tracks user corrections (deselections, edits) to improve AI extraction over time
/// Persists corrections to disk and provides them as context for future AI prompts
class CorrectionTracker {
    static let shared = CorrectionTracker()

    private let baseDirectory: URL
    private let correctionsFile: URL
    private var store: CorrectionStore

    private init() {
        // Use ~/.config/alfred/memory/ for persistent storage
        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/alfred/memory")

        self.baseDirectory = configDir
        self.correctionsFile = configDir.appendingPathComponent("corrections.json")
        self.store = CorrectionStore()

        // Create directory if needed
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)

        // Load existing corrections
        loadCorrections()
    }

    // MARK: - Recording Corrections

    /// Record when user deselects an item (false positive)
    func recordFalsePositive(
        itemType: String,
        title: String,
        description: String?,
        reason: String? = nil,
        source: String? = nil
    ) {
        let correction = Correction(
            id: UUID().uuidString,
            type: .falsePositive,
            itemType: itemType,
            title: title,
            description: description,
            reason: reason,
            source: source,
            timestamp: Date()
        )

        store.corrections.append(correction)

        // Keep only last 100 corrections per type
        trimCorrections()

        saveCorrections()

        print("📝 Recorded false positive: \(title)")
    }

    /// Record when user edits an item's title or description
    func recordEdit(
        itemType: String,
        originalTitle: String,
        editedTitle: String?,
        originalDescription: String?,
        editedDescription: String?,
        source: String? = nil
    ) {
        let correction = Correction(
            id: UUID().uuidString,
            type: .edited,
            itemType: itemType,
            title: originalTitle,
            description: originalDescription,
            editedTitle: editedTitle,
            editedDescription: editedDescription,
            source: source,
            timestamp: Date()
        )

        store.corrections.append(correction)
        trimCorrections()
        saveCorrections()

        print("📝 Recorded edit: \(originalTitle) → \(editedTitle ?? originalTitle)")
    }

    // MARK: - Getting Corrections for Prompts

    /// Get correction context to inject into AI prompts
    /// - Parameters:
    ///   - itemType: Filter by item type (e.g., "Commitment", "Todo") or nil for all
    ///   - limit: Maximum number of corrections to return
    /// - Returns: Formatted string for prompt injection
    func getCorrectionsForPrompt(itemType: String? = nil, limit: Int = 5) -> String {
        let filtered = store.corrections.filter { correction in
            if let type = itemType {
                return correction.itemType == type
            }
            return true
        }

        // Get most recent corrections
        let recent = filtered.suffix(limit)

        guard !recent.isEmpty else {
            return ""
        }

        var lines: [String] = []
        lines.append("LEARNING FROM PAST CORRECTIONS:")
        lines.append("The user has previously rejected or corrected the following extractions:")
        lines.append("")

        for correction in recent {
            switch correction.type {
            case .falsePositive:
                lines.append("❌ REJECTED: \"\(correction.title)\"")
                if let desc = correction.description {
                    lines.append("   Description: \(desc.prefix(100))...")
                }
                if let reason = correction.reason {
                    lines.append("   Reason: \(reason)")
                }

            case .edited:
                if let editedTitle = correction.editedTitle, editedTitle != correction.title {
                    lines.append("✏️ TITLE CORRECTED: \"\(correction.title)\" → \"\(editedTitle)\"")
                }
                if let originalDesc = correction.description,
                   let editedDesc = correction.editedDescription,
                   editedDesc != originalDesc {
                    lines.append("✏️ DESCRIPTION CORRECTED for \"\(correction.title)\"")
                }
            }
            lines.append("")
        }

        lines.append("Please avoid similar extractions that the user has rejected.")
        lines.append("Learn from the corrections to improve extraction quality.")

        return lines.joined(separator: "\n")
    }

    /// Get all corrections for a specific item type
    func getCorrections(forType itemType: String? = nil) -> [Correction] {
        if let type = itemType {
            return store.corrections.filter { $0.itemType == type }
        }
        return store.corrections
    }

    /// Get statistics about corrections
    func getStats() -> CorrectionStats {
        let falsePositives = store.corrections.filter { $0.type == .falsePositive }.count
        let edits = store.corrections.filter { $0.type == .edited }.count

        let byType = Dictionary(grouping: store.corrections, by: { $0.itemType })
            .mapValues { $0.count }

        return CorrectionStats(
            totalCorrections: store.corrections.count,
            falsePositives: falsePositives,
            edits: edits,
            byItemType: byType
        )
    }

    // MARK: - Persistence

    private func loadCorrections() {
        guard FileManager.default.fileExists(atPath: correctionsFile.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: correctionsFile)
            store = try JSONDecoder().decode(CorrectionStore.self, from: data)
            print("✓ Loaded \(store.corrections.count) corrections from memory")
        } catch {
            print("⚠️ Failed to load corrections: \(error)")
        }
    }

    private func saveCorrections() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(store)
            try data.write(to: correctionsFile)
        } catch {
            print("⚠️ Failed to save corrections: \(error)")
        }
    }

    private func trimCorrections() {
        // Keep only last 100 corrections
        if store.corrections.count > 100 {
            store.corrections = Array(store.corrections.suffix(100))
        }
    }

    /// Clear all corrections (for testing/reset)
    func clearAll() {
        store = CorrectionStore()
        saveCorrections()
        print("🗑️ Cleared all corrections")
    }
}

// MARK: - Data Models

struct CorrectionStore: Codable {
    var corrections: [Correction] = []
    var version: Int = 1
}

struct Correction: Codable, Identifiable {
    let id: String
    let type: CorrectionType
    let itemType: String  // "Commitment", "Todo", "Follow-up"
    let title: String
    let description: String?
    let editedTitle: String?
    let editedDescription: String?
    let reason: String?
    let source: String?
    let timestamp: Date

    init(
        id: String,
        type: CorrectionType,
        itemType: String,
        title: String,
        description: String? = nil,
        editedTitle: String? = nil,
        editedDescription: String? = nil,
        reason: String? = nil,
        source: String? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.type = type
        self.itemType = itemType
        self.title = title
        self.description = description
        self.editedTitle = editedTitle
        self.editedDescription = editedDescription
        self.reason = reason
        self.source = source
        self.timestamp = timestamp
    }

    enum CorrectionType: String, Codable {
        case falsePositive = "false_positive"
        case edited = "edited"
    }
}

struct CorrectionStats {
    let totalCorrections: Int
    let falsePositives: Int
    let edits: Int
    let byItemType: [String: Int]
}
