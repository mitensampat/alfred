import Foundation

/// Executes analysis lenses in parallel (Layer 1 of the generation pipeline).
/// Uses Haiku for fast, cheap signal extraction. Results are stored via SignalStore.
///
/// Usage:
///   let signals = try await LensExecutionEngine.shared.runAllLenses(dataContext: context)
///   // Signals are automatically persisted to ~/.alfred/signal_history/
class LensExecutionEngine {
    static let shared = LensExecutionEngine()

    private init() {}

    /// Result from running a single lens
    struct LensResult {
        let lensId: String
        let lensName: String
        let signals: [SignalStore.Signal]
        let duration: TimeInterval
        let error: String?
    }

    /// Run all enabled analysis lenses in parallel against the provided data context.
    /// Returns signals sorted by confidence. Also persists to SignalStore.
    func runAllLenses(dataContext: DataContext) async throws -> [LensResult] {
        let lenses = AnalysisLensLoader.shared.getEnabledLenses()
        guard !lenses.isEmpty else {
            print("[LensEngine] No enabled lenses to run")
            return []
        }

        guard let config = AppConfig.load() else {
            print("[LensEngine] No config available")
            return []
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let today = dateFormatter.string(from: Date())

        print("[LensEngine] Running \(lenses.count) lenses in parallel...")
        let startTime = Date()

        // Run lenses in parallel using TaskGroup
        let results = await withTaskGroup(of: LensResult.self) { group in
            for lens in lenses {
                // Skip if we already have signals for today (avoid re-running)
                if SignalStore.shared.hasSignals(lensId: lens.id, date: today) {
                    print("[LensEngine] Skipping \(lens.id) — already has signals for today")
                    continue
                }

                group.addTask {
                    await self.runSingleLens(lens, dataContext: dataContext, config: config.ai, date: today)
                }
            }

            var collected: [LensResult] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        let totalDuration = Date().timeIntervalSince(startTime)
        let totalSignals = results.reduce(0) { $0 + $1.signals.count }
        let errors = results.filter { $0.error != nil }

        print("[LensEngine] Completed \(results.count) lenses in \(String(format: "%.1f", totalDuration))s — \(totalSignals) signals, \(errors.count) errors")

        return results
    }

    /// Force re-run all lenses (ignores existing signals for today)
    func forceRunAllLenses(dataContext: DataContext) async throws -> [LensResult] {
        let lenses = AnalysisLensLoader.shared.getEnabledLenses()
        guard !lenses.isEmpty else { return [] }

        guard let config = AppConfig.load() else { return [] }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let today = dateFormatter.string(from: Date())

        print("[LensEngine] Force-running \(lenses.count) lenses...")

        let results = await withTaskGroup(of: LensResult.self) { group in
            for lens in lenses {
                group.addTask {
                    await self.runSingleLens(lens, dataContext: dataContext, config: config.ai, date: today)
                }
            }

            var collected: [LensResult] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        return results
    }

    /// Run a single lens and return result
    private func runSingleLens(_ lens: AnalysisLensDefinition, dataContext: DataContext, config: AIConfig, date: String) async -> LensResult {
        let startTime = Date()

        do {
            // Build the data payload for this lens based on its required data sources
            let dataPayload = buildDataPayload(for: lens, from: dataContext)

            guard !dataPayload.isEmpty else {
                return LensResult(
                    lensId: lens.id, lensName: lens.name,
                    signals: [], duration: 0, error: "No data available for required sources"
                )
            }

            // Build the prompt
            let fullPrompt = """
            \(lens.prompt)

            ## DATA
            \(dataPayload)
            """

            let systemPrompt = """
            You are a data analysis engine. Output ONLY valid JSON matching the specified schema.
            Do not include any explanation, preamble, or text outside the JSON object.
            If no signals are detected, return: {"signals": []}
            """

            // Use Haiku for fast extraction
            let claudeService = ClaudeAIService(config: config)
            let response = try await claudeService.generateText(
                prompt: fullPrompt,
                system: systemPrompt,
                maxTokens: 1024,
                useModel: config.effectiveMessageModel  // Haiku
            )

            // Parse the JSON response into Signal objects
            let signals = SignalStore.parseSignalsFromJSON(response, lensId: lens.id)

            // Persist to signal store
            if !signals.isEmpty {
                SignalStore.shared.storeSignals(lensId: lens.id, date: date, signals: signals)
            }

            let duration = Date().timeIntervalSince(startTime)
            print("[LensEngine] ✓ \(lens.id): \(signals.count) signals in \(String(format: "%.1f", duration))s")

            return LensResult(
                lensId: lens.id, lensName: lens.name,
                signals: signals, duration: duration, error: nil
            )

        } catch {
            let duration = Date().timeIntervalSince(startTime)
            print("[LensEngine] ✗ \(lens.id): \(error.localizedDescription)")
            return LensResult(
                lensId: lens.id, lensName: lens.name,
                signals: [], duration: duration, error: error.localizedDescription
            )
        }
    }

    // MARK: - Data Context

    /// Container for all available data that lenses can draw from.
    /// Populated once before lens execution and shared across all parallel runs.
    struct DataContext {
        var tasks: String = ""
        var tasksDetailed: String = ""
        var calendar: String = ""
        var messages: String = ""
        var messagesDetailed: String = ""
        var commitments: String = ""
        var commitmentsByPerson: String = ""
        var coachingMemory: String = ""
    }

    /// Build the data payload for a specific lens based on its data source requirements
    private func buildDataPayload(for lens: AnalysisLensDefinition, from context: DataContext) -> String {
        var sections: [String] = []

        for source in lens.dataSources {
            switch source {
            case "tasks":
                if !context.tasks.isEmpty { sections.append("### Tasks\n\(context.tasks)") }
            case "tasks_detailed":
                if !context.tasksDetailed.isEmpty { sections.append("### Tasks (Detailed)\n\(context.tasksDetailed)") }
            case "calendar":
                if !context.calendar.isEmpty { sections.append("### Calendar\n\(context.calendar)") }
            case "messages":
                if !context.messages.isEmpty { sections.append("### Messages\n\(context.messages)") }
            case "messages_detailed":
                if !context.messagesDetailed.isEmpty { sections.append("### Messages (Detailed)\n\(context.messagesDetailed)") }
            case "commitments":
                if !context.commitments.isEmpty { sections.append("### Commitments\n\(context.commitments)") }
            case "commitments_by_person":
                if !context.commitmentsByPerson.isEmpty { sections.append("### Commitments by Person\n\(context.commitmentsByPerson)") }
            case "coaching_memory":
                if !context.coachingMemory.isEmpty { sections.append("### Coaching Memory\n\(context.coachingMemory)") }
            default:
                break
            }
        }

        return sections.joined(separator: "\n\n")
    }

    // MARK: - Signal Summary for Coaching

    /// Build a signal summary suitable for injection into coaching prompts.
    /// Groups signals by lens and adds temporal context (streaks, recurrence).
    func buildSignalSummary(maxTokens: Int = 500) -> String {
        let todaysSignals = SignalStore.shared.getTodaysSignals()
        guard !todaysSignals.isEmpty else { return "" }

        // Group by lens
        var byLens: [String: [SignalStore.Signal]] = [:]
        for signal in todaysSignals {
            byLens[signal.lensId, default: []].append(signal)
        }

        var lines: [String] = []

        for (lensId, signals) in byLens.sorted(by: { $0.key < $1.key }) {
            let lensName = AnalysisLensLoader.shared.getLens(id: lensId)?.name ?? lensId

            for signal in signals.prefix(3) {  // Max 3 per lens
                var line = "[\(lensName)] \(signal.type)"
                if let subject = signal.subject { line += ": \(subject)" }
                line += " (confidence: \(String(format: "%.0f%%", signal.confidence * 100)))"

                // Add temporal context
                let streak = SignalStore.shared.getStreak(lensId: lensId, signalType: signal.type)
                if streak > 1 {
                    line += " — \(streak) days in a row"
                }

                if let evidence = signal.evidence {
                    line += "\n  → \(evidence)"
                }

                lines.append(line)
            }
        }

        let summary = lines.joined(separator: "\n")

        // Rough token estimate: ~4 chars per token
        if summary.count > maxTokens * 4 {
            return String(summary.prefix(maxTokens * 4)) + "\n..."
        }

        return summary
    }
}
