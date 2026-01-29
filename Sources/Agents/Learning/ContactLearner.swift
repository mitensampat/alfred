import Foundation

/// Tracks behavioral patterns per thread/contact to automatically determine extraction relevance
/// Learns from participation history and extraction accuracy to classify threads
class ContactLearner {
    static let shared = ContactLearner()

    private let baseDirectory: URL
    private let contactsFile: URL
    private var store: ContactStore
    private let queue = DispatchQueue(label: "com.alfred.contactlearner")

    private init() {
        // Use ~/.config/alfred/memory/ for persistent storage
        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/alfred/memory")

        self.baseDirectory = configDir
        self.contactsFile = configDir.appendingPathComponent("contacts.json")
        self.store = ContactStore()

        // Create directory if needed
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)

        // Load existing data
        loadContacts()
    }

    // MARK: - Thread Key Generation

    /// Generate a unique key for a thread
    func threadKey(platform: String, threadId: String) -> String {
        return "\(platform.lowercased()):\(threadId)"
    }

    // MARK: - Recording Participation

    /// Record participation stats after scanning a thread
    func recordParticipation(
        platform: String,
        threadId: String,
        threadName: String,
        isGroup: Bool,
        userMessages: Int,
        totalMessages: Int
    ) {
        queue.async { [weak self] in
            guard let self = self else { return }

            let key = self.threadKey(platform: platform, threadId: threadId)
            let today = self.dateString(Date())

            // Get or create thread record
            var thread = self.store.threads[key] ?? ThreadRecord(
                platform: platform,
                threadId: threadId,
                threadName: threadName,
                isGroup: isGroup
            )

            // Update thread name if changed
            thread.threadName = threadName

            // Add participation entry (one per day max)
            if let lastEntry = thread.participationHistory.last, lastEntry.date == today {
                // Update today's entry
                thread.participationHistory[thread.participationHistory.count - 1] = ParticipationEntry(
                    date: today,
                    userMessages: userMessages,
                    totalMessages: totalMessages
                )
            } else {
                // Add new entry
                thread.participationHistory.append(ParticipationEntry(
                    date: today,
                    userMessages: userMessages,
                    totalMessages: totalMessages
                ))
            }

            // Keep last 30 entries
            if thread.participationHistory.count > 30 {
                thread.participationHistory = Array(thread.participationHistory.suffix(30))
            }

            // Recalculate average participation
            thread.avgParticipation = self.calculateAvgParticipation(thread.participationHistory)

            // Update classification
            thread.classification = self.classifyThread(thread)

            // Update last seen
            thread.lastSeen = today

            self.store.threads[key] = thread
            self.saveContacts()

            print("📊 Recorded participation for \(threadName): \(userMessages)/\(totalMessages) messages, classification: \(thread.classification.rawValue)")
        }
    }

    // MARK: - Recording Extraction Results

    /// Record extraction results after user approves/rejects items
    func recordExtractionResult(
        platform: String,
        threadId: String,
        itemsExtracted: Int,
        itemsRejected: Int
    ) {
        queue.async { [weak self] in
            guard let self = self else { return }

            let key = self.threadKey(platform: platform, threadId: threadId)

            guard var thread = self.store.threads[key] else {
                print("⚠️ No thread record found for \(key)")
                return
            }

            // Update extraction stats
            thread.extractionStats.itemsExtracted += itemsExtracted
            thread.extractionStats.itemsRejected += itemsRejected

            // Recalculate rejection rate
            let total = thread.extractionStats.itemsExtracted + thread.extractionStats.itemsRejected
            if total > 0 {
                thread.extractionStats.rejectionRate = Double(thread.extractionStats.itemsRejected) / Double(total)
            }

            // Reclassify based on new data
            thread.classification = self.classifyThread(thread)

            self.store.threads[key] = thread
            self.saveContacts()

            print("📊 Recorded extraction result for \(thread.threadName): +\(itemsExtracted) extracted, +\(itemsRejected) rejected (total rejection rate: \(Int(thread.extractionStats.rejectionRate * 100))%)")
        }
    }

    // MARK: - Getting Thread Context

    /// Get context for a specific thread
    func getThreadContext(platform: String, threadId: String) -> ThreadRecord? {
        let key = threadKey(platform: platform, threadId: threadId)
        return store.threads[key]
    }

    /// Get prompt context to inject into AI prompts
    func getPromptContext(platform: String, threadId: String) -> String {
        let key = threadKey(platform: platform, threadId: threadId)

        guard let thread = store.threads[key] else {
            return "" // No history for this thread
        }

        // Only provide context if we have meaningful data
        let totalScans = thread.participationHistory.count
        guard totalScans >= 2 else {
            return "" // Not enough history
        }

        var lines: [String] = []
        lines.append("## HISTORICAL CONTEXT FOR THIS THREAD")
        lines.append("Thread: \(thread.threadName)")
        lines.append("Classification: \(thread.classification.rawValue.uppercased())")
        lines.append("Historical participation: \(Int(thread.avgParticipation * 100))% average over \(totalScans) scans")

        let totalItems = thread.extractionStats.itemsExtracted + thread.extractionStats.itemsRejected
        if totalItems > 0 {
            let acceptanceRate = 100 - Int(thread.extractionStats.rejectionRate * 100)
            lines.append("Past extraction accuracy: \(acceptanceRate)% (\(thread.extractionStats.itemsExtracted) accepted, \(thread.extractionStats.itemsRejected) rejected)")
        }

        lines.append("")

        // Add guidance based on classification
        switch thread.classification {
        case .observe:
            lines.append("GUIDANCE: Be EXTREMELY conservative. This thread historically produces false positives or the user rarely participates.")
            lines.append("- Only extract items if the user is explicitly named and addressed")
            lines.append("- Prefer returning empty results over uncertain extractions")

        case .minimal:
            lines.append("GUIDANCE: Be conservative. The user has minimal engagement with this thread.")
            lines.append("- Only extract items directly involving the user")
            lines.append("- Skip general group discussions")

        case .active:
            lines.append("GUIDANCE: Normal extraction. The user actively engages with this thread.")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Classification Logic

    private func classifyThread(_ thread: ThreadRecord) -> ThreadClassification {
        let avgParticipation = thread.avgParticipation
        let rejectionRate = thread.extractionStats.rejectionRate
        let hasExtractionHistory = (thread.extractionStats.itemsExtracted + thread.extractionStats.itemsRejected) > 0

        // Rule 1: Zero participation = observe
        if avgParticipation == 0 {
            return .observe
        }

        // Rule 2: Low participation + high rejection = observe
        if avgParticipation < 0.10 && hasExtractionHistory && rejectionRate > 0.5 {
            return .observe
        }

        // Rule 3: Low participation = minimal
        if avgParticipation < 0.20 {
            return .minimal
        }

        // Rule 4: High rejection rate even with participation = minimal
        if hasExtractionHistory && rejectionRate > 0.7 {
            return .minimal
        }

        // Default: active
        return .active
    }

    private func calculateAvgParticipation(_ history: [ParticipationEntry]) -> Double {
        guard !history.isEmpty else { return 0 }

        var totalUserMessages = 0
        var totalMessages = 0

        for entry in history {
            totalUserMessages += entry.userMessages
            totalMessages += entry.totalMessages
        }

        guard totalMessages > 0 else { return 0 }
        return Double(totalUserMessages) / Double(totalMessages)
    }

    private func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    // MARK: - Persistence

    private func loadContacts() {
        guard FileManager.default.fileExists(atPath: contactsFile.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: contactsFile)
            store = try JSONDecoder().decode(ContactStore.self, from: data)
            print("✓ Loaded \(store.threads.count) thread records from memory")
        } catch {
            print("⚠️ Failed to load contacts: \(error)")
        }
    }

    private func saveContacts() {
        do {
            store.metadata.lastUpdated = Date()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(store)
            try data.write(to: contactsFile)
        } catch {
            print("⚠️ Failed to save contacts: \(error)")
        }
    }

    // MARK: - Utilities

    /// Get all thread records
    func getAllThreads() -> [ThreadRecord] {
        return Array(store.threads.values)
    }

    /// Get threads by classification
    func getThreads(classification: ThreadClassification) -> [ThreadRecord] {
        return store.threads.values.filter { $0.classification == classification }
    }

    /// Get stats summary
    func getStats() -> ContactStats {
        let threads = Array(store.threads.values)
        let observe = threads.filter { $0.classification == .observe }.count
        let minimal = threads.filter { $0.classification == .minimal }.count
        let active = threads.filter { $0.classification == .active }.count

        return ContactStats(
            totalThreads: threads.count,
            observeThreads: observe,
            minimalThreads: minimal,
            activeThreads: active
        )
    }

    /// Clear all data (for testing/reset)
    func clearAll() {
        store = ContactStore()
        saveContacts()
        print("🗑️ Cleared all contact learning data")
    }
}

// MARK: - Data Models

struct ContactStore: Codable {
    var threads: [String: ThreadRecord] = [:]
    var metadata: ContactMetadata = ContactMetadata()
    var version: Int = 1
}

struct ContactMetadata: Codable {
    var lastUpdated: Date = Date()
}

struct ThreadRecord: Codable {
    let platform: String
    let threadId: String
    var threadName: String
    var isGroup: Bool
    var participationHistory: [ParticipationEntry] = []
    var avgParticipation: Double = 0
    var classification: ThreadClassification = .active
    var lastSeen: String = ""
    var extractionStats: ExtractionStats = ExtractionStats()

    init(platform: String, threadId: String, threadName: String, isGroup: Bool) {
        self.platform = platform
        self.threadId = threadId
        self.threadName = threadName
        self.isGroup = isGroup
    }
}

struct ParticipationEntry: Codable {
    let date: String
    let userMessages: Int
    let totalMessages: Int
}

struct ExtractionStats: Codable {
    var itemsExtracted: Int = 0
    var itemsRejected: Int = 0
    var rejectionRate: Double = 0
}

enum ThreadClassification: String, Codable {
    case observe = "observe"
    case minimal = "minimal"
    case active = "active"
}

struct ContactStats {
    let totalThreads: Int
    let observeThreads: Int
    let minimalThreads: Int
    let activeThreads: Int
}
