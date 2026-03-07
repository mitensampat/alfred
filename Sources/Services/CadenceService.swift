import Foundation

/// Manages cadence CRUD, persistence, and migration from legacy config
class CadenceService {
    static let shared = CadenceService()

    private let filePath: String
    private var cadences: [Cadence]
    private let lock = NSLock()

    init() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        filePath = "\(homeDir)/.alfred/cadences.json"

        // Try loading existing cadences
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
           let loaded = try? decoder.decode([Cadence].self, from: data) {
            cadences = loaded
            print("✓ Loaded \(cadences.count) cadences from cadences.json")
        } else {
            // First run: migrate from old config
            cadences = CadenceService.migrateFromOldConfig()
            print("📦 Migrated \(cadences.count) built-in cadences from legacy config")
            try? save()
        }
    }

    // MARK: - CRUD

    func getAll() -> [Cadence] {
        lock.lock()
        defer { lock.unlock() }
        return cadences
    }

    func getEnabled() -> [Cadence] {
        lock.lock()
        defer { lock.unlock() }
        return cadences.filter { $0.enabled }
    }

    func get(id: String) -> Cadence? {
        lock.lock()
        defer { lock.unlock() }
        return cadences.first { $0.id == id }
    }

    func create(_ cadence: Cadence) throws {
        lock.lock()
        defer { lock.unlock() }

        // Check for duplicate names
        if cadences.contains(where: { $0.name.lowercased() == cadence.name.lowercased() }) {
            throw CadenceError.executionFailed("A cadence with that name already exists")
        }
        cadences.append(cadence)
        try save()
    }

    func update(_ cadence: Cadence) throws {
        lock.lock()
        defer { lock.unlock() }

        guard let index = cadences.firstIndex(where: { $0.id == cadence.id }) else {
            throw CadenceError.notFound(cadence.id)
        }
        cadences[index] = cadence
        try save()
    }

    func delete(id: String) throws {
        lock.lock()
        defer { lock.unlock() }

        guard let cadence = cadences.first(where: { $0.id == id }) else {
            throw CadenceError.notFound(id)
        }
        if cadence.isBuiltIn {
            throw CadenceError.cannotDeleteBuiltIn
        }
        cadences.removeAll { $0.id == id }
        try save()
    }

    // MARK: - State Updates (called by scheduler after execution)

    func markRunSuccess(id: String, date: String, timestamp: String) {
        lock.lock()
        defer { lock.unlock() }

        if let index = cadences.firstIndex(where: { $0.id == id }) {
            cadences[index].lastRunDate = date
            cadences[index].lastRunTimestamp = timestamp
            cadences[index].failureCooldownUntil = nil
            try? save()
        }
    }

    func markRunFailure(id: String, cooldownMinutes: Int) {
        lock.lock()
        defer { lock.unlock() }

        if let index = cadences.firstIndex(where: { $0.id == id }) {
            cadences[index].failureCooldownUntil = Date().addingTimeInterval(Double(cooldownMinutes * 60))
            try? save()
        }
    }

    func clearCooldown(id: String) {
        lock.lock()
        defer { lock.unlock() }

        if let index = cadences.firstIndex(where: { $0.id == id }) {
            cadences[index].failureCooldownUntil = nil
            try? save()
        }
    }

    // MARK: - Persistence

    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(cadences)
        try data.write(to: URL(fileURLWithPath: filePath))
    }

    // MARK: - Migration from Legacy Config

    /// Reads old config.json cadence section + scheduler_state.json → creates built-in Cadence objects
    static func migrateFromOldConfig() -> [Cadence] {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path

        // Load old config
        let config = AppConfig.load()
        let cadenceConfig = config?.cadence
        let appSettings = config?.app
        let scheduled = config?.scheduled

        // Load old scheduler state for last-run dates
        var lastRuns: [String: String] = [:]       // key → date
        var lastTimestamps: [String: String] = [:]  // key → ISO timestamp
        let statePath = "\(homeDir)/.alfred/scheduler_state.json"
        if let stateData = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
           let stateDict = try? JSONSerialization.jsonObject(with: stateData) as? [String: Any] {
            lastRuns["briefing"] = stateDict["lastBriefingDate"] as? String
            lastRuns["attention"] = stateDict["lastAttentionDate"] as? String
            lastRuns["todoScan"] = nil // interval-based, use timestamp
            lastTimestamps["todoScan"] = stateDict["lastTodoScanTime"] as? String
            lastRuns["commitmentScan"] = stateDict["lastCommitmentScanDate"] as? String
            lastTimestamps["commitmentScan"] = stateDict["lastCommitmentScanTimestamp"] as? String
            lastRuns["patternLearn"] = stateDict["lastPatternLearnDate"] as? String
            lastTimestamps["patternLearn"] = stateDict["lastPatternLearnTimestamp"] as? String
            lastRuns["groupAnalysis"] = stateDict["lastGroupAnalysisDate"] as? String
            lastTimestamps["groupAnalysis"] = stateDict["lastGroupAnalysisTimestamp"] as? String
            lastRuns["autoSummary"] = stateDict["lastAutoSummaryDate"] as? String
            lastTimestamps["autoSummary"] = stateDict["lastAutoSummaryTimestamp"] as? String
            lastRuns["weeklyReview"] = stateDict["lastWeeklyReviewDate"] as? String
            lastTimestamps["weeklyReview"] = stateDict["lastWeeklyReviewTimestamp"] as? String
        }

        let now = Date()

        return [
            Cadence(
                id: "builtin-morning-briefing",
                name: "Morning Briefing",
                icon: "☀️",
                actionType: .morningBriefing,
                params: [:],
                schedule: .daily(time: appSettings?.briefingTime ?? "08:15"),
                enabled: scheduled?.briefingEnabled ?? true,
                isBuiltIn: true,
                createdAt: now,
                lastRunDate: lastRuns["briefing"],
                lastRunTimestamp: lastRuns["briefing"],  // no precise timestamp in old state
                catchUpWindowHours: 3,
                notifyOnSuccess: true,
                emailOnSuccess: true
            ),
            Cadence(
                id: "builtin-attention-check",
                name: "Attention Check",
                icon: "🎯",
                actionType: .attentionCheck,
                params: [:],
                schedule: .daily(time: appSettings?.attentionAlertTime ?? "15:00"),
                enabled: scheduled?.attentionEnabled ?? true,
                isBuiltIn: true,
                createdAt: now,
                lastRunDate: lastRuns["attention"],
                lastRunTimestamp: lastRuns["attention"],
                catchUpWindowHours: 3,
                notifyOnSuccess: true,
                emailOnSuccess: true
            ),
            Cadence(
                id: "builtin-todo-scan",
                name: "Todo Scan",
                icon: "📝",
                actionType: .todoScan,
                params: ["lookback_days": .int(7)],
                schedule: .interval(
                    hours: cadenceConfig?.todoScanIntervalHours ?? 3,
                    activeStart: 9,
                    activeEnd: 21
                ),
                enabled: cadenceConfig?.todoScanEnabled ?? true,
                isBuiltIn: true,
                createdAt: now,
                lastRunDate: nil,
                lastRunTimestamp: lastTimestamps["todoScan"],
                catchUpWindowHours: 3,
                notifyOnSuccess: true,
                emailOnSuccess: false
            ),
            Cadence(
                id: "builtin-commitment-scan",
                name: "Commitment Scan",
                icon: "🤝",
                actionType: .commitmentScan,
                params: ["scan_mode": .string("all")],
                schedule: .daily(time: cadenceConfig?.commitmentScanTime ?? "17:00"),
                enabled: cadenceConfig?.commitmentScanEnabled ?? true,
                isBuiltIn: true,
                createdAt: now,
                lastRunDate: lastRuns["commitmentScan"],
                lastRunTimestamp: lastTimestamps["commitmentScan"],
                catchUpWindowHours: 3,
                notifyOnSuccess: true,
                emailOnSuccess: false
            ),
            Cadence(
                id: "builtin-pattern-learning",
                name: "Pattern Learning",
                icon: "🧠",
                actionType: .patternLearning,
                params: [:],
                schedule: .weekly(
                    day: cadenceConfig?.patternLearnDay ?? "thursday",
                    time: cadenceConfig?.patternLearnTime ?? "18:00"
                ),
                enabled: cadenceConfig?.patternLearnEnabled ?? true,
                isBuiltIn: true,
                createdAt: now,
                lastRunDate: lastRuns["patternLearn"],
                lastRunTimestamp: lastTimestamps["patternLearn"],
                catchUpWindowHours: 3,
                notifyOnSuccess: true,
                emailOnSuccess: true
            ),
            Cadence(
                id: "builtin-group-analysis",
                name: "Group Analysis",
                icon: "📊",
                actionType: .groupAnalysis,
                params: [:],
                schedule: .weekly(
                    day: cadenceConfig?.groupAnalysisDay ?? "sunday",
                    time: cadenceConfig?.groupAnalysisTime ?? "09:00"
                ),
                enabled: cadenceConfig?.groupAnalysisEnabled ?? true,
                isBuiltIn: true,
                createdAt: now,
                lastRunDate: lastRuns["groupAnalysis"],
                lastRunTimestamp: lastTimestamps["groupAnalysis"],
                catchUpWindowHours: 3,
                notifyOnSuccess: true,
                emailOnSuccess: false
            ),
            Cadence(
                id: "builtin-auto-summary",
                name: "Auto Summary",
                icon: "📨",
                actionType: .autoSummary,
                params: ["groups": .stringArray(cadenceConfig?.autoSummaryGroups ?? [])],
                schedule: .daily(time: cadenceConfig?.autoSummaryTime ?? "18:00"),
                enabled: !(cadenceConfig?.autoSummaryGroups ?? []).isEmpty,
                isBuiltIn: true,
                createdAt: now,
                lastRunDate: lastRuns["autoSummary"],
                lastRunTimestamp: lastTimestamps["autoSummary"],
                catchUpWindowHours: 3,
                notifyOnSuccess: true,
                emailOnSuccess: true
            ),
            Cadence(
                id: "builtin-weekly-review",
                name: "Weekly Review",
                icon: "📋",
                actionType: .weeklyReview,
                params: [:],
                schedule: .weekly(
                    day: cadenceConfig?.weeklyReviewDay ?? "sunday",
                    time: cadenceConfig?.weeklyReviewTime ?? "08:00"
                ),
                enabled: cadenceConfig?.weeklyReviewEnabled ?? true,
                isBuiltIn: true,
                createdAt: now,
                lastRunDate: lastRuns["weeklyReview"],
                lastRunTimestamp: lastTimestamps["weeklyReview"],
                catchUpWindowHours: 3,
                notifyOnSuccess: true,
                emailOnSuccess: true
            )
        ]
    }
}
