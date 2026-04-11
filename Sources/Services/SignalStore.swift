import Foundation

/// Persists and queries analysis lens signals for temporal coaching.
/// Signals are stored as JSON files in `~/.alfred/signal_history/{lens-id}/YYYY-MM-DD.json`
/// This enables coaching like "this is the third week in a row you've avoided X".
class SignalStore {
    static let shared = SignalStore()

    private let baseDirectory: String

    private init() {
        let alfredDir = NSString(string: "~/.alfred").expandingTildeInPath
        self.baseDirectory = alfredDir + "/signal_history"
        try? FileManager.default.createDirectory(atPath: baseDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Signal Data Model

    /// A single signal emitted by an analysis lens
    struct Signal: Codable {
        let type: String            // e.g., "avoided_task", "blocking_others"
        let lensId: String          // which lens produced this
        let confidence: Double      // 0.0 - 1.0
        let subject: String?        // task name, person name, etc.
        let evidence: String?       // human-readable explanation
        let metadata: [String: String]? // additional key-value data
        let timestamp: String       // ISO 8601
    }

    /// A day's worth of signals from a specific lens
    struct DaySignals: Codable {
        let lensId: String
        let date: String            // YYYY-MM-DD
        let signals: [Signal]
        let generatedAt: String     // ISO 8601 timestamp
    }

    // MARK: - Write

    /// Store signals from a lens run for a given date
    func storeSignals(lensId: String, date: String, signals: [Signal]) {
        let lensDir = (baseDirectory as NSString).appendingPathComponent(lensId)
        try? FileManager.default.createDirectory(atPath: lensDir, withIntermediateDirectories: true)

        let daySignals = DaySignals(
            lensId: lensId,
            date: date,
            signals: signals,
            generatedAt: ISO8601DateFormatter().string(from: Date())
        )

        let filePath = (lensDir as NSString).appendingPathComponent("\(date).json")
        if let data = try? JSONEncoder().encode(daySignals) {
            try? data.write(to: URL(fileURLWithPath: filePath))
        }
    }

    // MARK: - Read

    /// Get signals from a specific lens for a specific date
    func getSignals(lensId: String, date: String) -> [Signal] {
        let filePath = signalPath(lensId: lensId, date: date)
        guard let data = FileManager.default.contents(atPath: filePath),
              let daySignals = try? JSONDecoder().decode(DaySignals.self, from: data) else {
            return []
        }
        return daySignals.signals
    }

    /// Get signal history for a lens over the past N days
    func getSignalHistory(lensId: String, days: Int = 7) -> [DaySignals] {
        let calendar = Calendar.current
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        var history: [DaySignals] = []

        for dayOffset in 0..<days {
            guard let date = calendar.date(byAdding: .day, value: -dayOffset, to: Date()) else { continue }
            let dateStr = dateFormatter.string(from: date)
            let filePath = signalPath(lensId: lensId, date: dateStr)

            if let data = FileManager.default.contents(atPath: filePath),
               let daySignals = try? JSONDecoder().decode(DaySignals.self, from: data) {
                history.append(daySignals)
            }
        }

        return history
    }

    /// Get ALL signals from ALL lenses for today
    func getTodaysSignals() -> [Signal] {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let today = dateFormatter.string(from: Date())

        let fm = FileManager.default
        guard let lensDirs = try? fm.contentsOfDirectory(atPath: baseDirectory) else { return [] }

        var allSignals: [Signal] = []
        for lensDir in lensDirs {
            let filePath = (baseDirectory as NSString)
                .appendingPathComponent(lensDir)
                .appending("/\(today).json")

            if let data = fm.contents(atPath: filePath),
               let daySignals = try? JSONDecoder().decode(DaySignals.self, from: data) {
                allSignals.append(contentsOf: daySignals.signals)
            }
        }

        return allSignals.sorted { $0.confidence > $1.confidence }
    }

    /// Get all signals from all lenses for a specific date
    func getSignalsForDate(_ date: String) -> [Signal] {
        let fm = FileManager.default
        guard let lensDirs = try? fm.contentsOfDirectory(atPath: baseDirectory) else { return [] }

        var allSignals: [Signal] = []
        for lensDir in lensDirs {
            let filePath = (baseDirectory as NSString)
                .appendingPathComponent(lensDir)
                .appending("/\(date).json")

            if let data = fm.contents(atPath: filePath),
               let daySignals = try? JSONDecoder().decode(DaySignals.self, from: data) {
                allSignals.append(contentsOf: daySignals.signals)
            }
        }

        return allSignals.sorted { $0.confidence > $1.confidence }
    }

    /// Check if signals exist for a lens on a date (avoids re-running)
    func hasSignals(lensId: String, date: String) -> Bool {
        return FileManager.default.fileExists(atPath: signalPath(lensId: lensId, date: date))
    }

    /// Get recurring signal patterns — signals of the same type appearing across multiple days
    func getRecurringPatterns(lensId: String, signalType: String, days: Int = 14) -> [(date: String, signal: Signal)] {
        let history = getSignalHistory(lensId: lensId, days: days)
        var occurrences: [(date: String, signal: Signal)] = []

        for day in history {
            for signal in day.signals where signal.type == signalType {
                occurrences.append((date: day.date, signal: signal))
            }
        }

        return occurrences
    }

    /// Get the streak count for a signal type (consecutive days it has appeared)
    func getStreak(lensId: String, signalType: String) -> Int {
        let calendar = Calendar.current
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        var streak = 0
        for dayOffset in 0..<30 {
            guard let date = calendar.date(byAdding: .day, value: -dayOffset, to: Date()) else { break }
            let dateStr = dateFormatter.string(from: date)
            let signals = getSignals(lensId: lensId, date: dateStr)

            if signals.contains(where: { $0.type == signalType }) {
                streak += 1
            } else {
                break
            }
        }

        return streak
    }

    // MARK: - Cleanup

    /// Remove signal files older than N days
    func cleanupOldSignals(olderThanDays: Int = 90) {
        let calendar = Calendar.current
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        guard let cutoffDate = calendar.date(byAdding: .day, value: -olderThanDays, to: Date()) else { return }
        let cutoffStr = dateFormatter.string(from: cutoffDate)

        let fm = FileManager.default
        guard let lensDirs = try? fm.contentsOfDirectory(atPath: baseDirectory) else { return }

        for lensDir in lensDirs {
            let lensDirPath = (baseDirectory as NSString).appendingPathComponent(lensDir)
            guard let files = try? fm.contentsOfDirectory(atPath: lensDirPath) else { continue }

            for file in files where file.hasSuffix(".json") {
                let dateStr = (file as NSString).deletingPathExtension
                if dateStr < cutoffStr {
                    try? fm.removeItem(atPath: (lensDirPath as NSString).appendingPathComponent(file))
                }
            }
        }
    }

    /// Get summary stats for the signal store
    func getStats() -> [String: Any] {
        let fm = FileManager.default
        guard let lensDirs = try? fm.contentsOfDirectory(atPath: baseDirectory) else {
            return ["lenses": 0, "totalFiles": 0]
        }

        var totalFiles = 0
        var lensStats: [[String: Any]] = []

        for lensDir in lensDirs {
            let lensDirPath = (baseDirectory as NSString).appendingPathComponent(lensDir)
            let files = (try? fm.contentsOfDirectory(atPath: lensDirPath))?.filter { $0.hasSuffix(".json") } ?? []
            totalFiles += files.count
            lensStats.append([
                "lensId": lensDir,
                "fileCount": files.count
            ])
        }

        return [
            "lenses": lensDirs.count,
            "totalFiles": totalFiles,
            "lensDetails": lensStats
        ]
    }

    // MARK: - Helpers

    private func signalPath(lensId: String, date: String) -> String {
        return (baseDirectory as NSString)
            .appendingPathComponent(lensId)
            .appending("/\(date).json")
    }

    /// Convert raw JSON signal output from LLM into Signal array
    static func parseSignalsFromJSON(_ jsonString: String, lensId: String) -> [Signal] {
        // Strip markdown code fences if present
        var cleaned = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```json") {
            cleaned = String(cleaned.dropFirst(7))
        } else if cleaned.hasPrefix("```") {
            cleaned = String(cleaned.dropFirst(3))
        }
        if cleaned.hasSuffix("```") {
            cleaned = String(cleaned.dropLast(3))
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let signalArray = json["signals"] as? [[String: Any]] else {
            print("[SignalStore] Failed to parse signals JSON from lens \(lensId)")
            return []
        }

        let timestamp = ISO8601DateFormatter().string(from: Date())

        return signalArray.compactMap { dict -> Signal? in
            guard let type = dict["type"] as? String else { return nil }
            let confidence = dict["confidence"] as? Double ?? 0.5

            // Extract common fields, handling various naming conventions
            let subject = dict["subject"] as? String
                ?? dict["task_name"] as? String
                ?? dict["person"] as? String
            let evidence = dict["evidence"] as? String

            // Collect remaining fields as metadata
            var metadata: [String: String] = [:]
            for (key, value) in dict where !["type", "confidence", "subject", "task_name", "person", "evidence"].contains(key) {
                if let strVal = value as? String {
                    metadata[key] = strVal
                } else if let numVal = value as? NSNumber {
                    metadata[key] = numVal.stringValue
                }
            }

            return Signal(
                type: type,
                lensId: lensId,
                confidence: confidence,
                subject: subject,
                evidence: evidence,
                metadata: metadata.isEmpty ? nil : metadata,
                timestamp: timestamp
            )
        }
    }
}
