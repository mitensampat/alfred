import Foundation

/// Loads and manages analysis lenses from Markdown files.
/// Two-tier directory structure:
///   ~/.alfred/analyses/user/       — user-created, fully editable
///   ~/.alfred/analyses/installed/  — coach-authored, read-only (toggle only)
/// State file: ~/.alfred/analyses_state.json
class AnalysisLensLoader {
    static let shared = AnalysisLensLoader()

    private let baseDirectory: String
    private let userDirectory: String
    private let installedDirectory: String
    private let statePath: String

    private init() {
        let alfredDir = NSString(string: "~/.alfred").expandingTildeInPath
        self.baseDirectory = alfredDir + "/analyses"
        self.userDirectory = alfredDir + "/analyses/user"
        self.installedDirectory = alfredDir + "/analyses/installed"
        self.statePath = alfredDir + "/analyses_state.json"

        let fm = FileManager.default
        try? fm.createDirectory(atPath: userDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: installedDirectory, withIntermediateDirectories: true)

        installDefaultLenses()
    }

    // MARK: - Public API

    /// Load all analysis lens definitions from both user/ and installed/ directories
    func loadLenses() -> [AnalysisLensDefinition] {
        let enabledState = loadEnabledState()
        var lenses: [AnalysisLensDefinition] = []

        lenses.append(contentsOf: loadLensesFromDirectory(userDirectory, origin: .user, enabledState: enabledState))
        lenses.append(contentsOf: loadLensesFromDirectory(installedDirectory, origin: .installed, enabledState: enabledState))

        return lenses.sorted { $0.name < $1.name }
    }

    /// Load only enabled lenses
    func getEnabledLenses() -> [AnalysisLensDefinition] {
        return loadLenses().filter { $0.enabled }
    }

    /// Toggle a lens's enabled/disabled state
    func toggleLens(id: String) -> Bool {
        var state = loadEnabledState()
        let currentlyEnabled = state[id] ?? true
        state[id] = !currentlyEnabled
        saveEnabledState(state)
        return !currentlyEnabled
    }

    /// Set a lens's enabled state explicitly
    func setLensEnabled(id: String, enabled: Bool) {
        var state = loadEnabledState()
        state[id] = enabled
        saveEnabledState(state)
    }

    /// Get a single lens by ID
    func getLens(id: String) -> AnalysisLensDefinition? {
        return loadLenses().first { $0.id == id }
    }

    // MARK: - CRUD Operations (user lenses only)

    /// Create a new user analysis lens. Returns the created lens or nil on error.
    func createLens(name: String, description: String, icon: String,
                    dataSources: [String], signals: String, prompt: String,
                    outputSchema: String? = nil) -> AnalysisLensDefinition? {
        let id = MarkdownDefinitionParser.slugFromName(name)
        guard !id.isEmpty else { return nil }

        let lens = AnalysisLensDefinition(
            id: id, name: name, description: description, icon: icon,
            author: nil, version: nil,
            dataSources: dataSources.filter { AnalysisLensDefinition.validDataSources.contains($0) },
            signals: signals, prompt: prompt, outputSchema: outputSchema,
            enabled: true, origin: .user
        )

        let filePath = (userDirectory as NSString).appendingPathComponent("\(id).md")

        guard !FileManager.default.fileExists(atPath: filePath) else {
            print("[AnalysisLensLoader] Lens file already exists: \(id).md")
            return nil
        }

        let content = lens.toMarkdown()
        do {
            try content.write(toFile: filePath, atomically: true, encoding: .utf8)
            return lens
        } catch {
            print("[AnalysisLensLoader] Failed to write lens file: \(error)")
            return nil
        }
    }

    /// Update an existing user lens. Returns updated lens or nil if not found.
    func updateLens(id: String, name: String?, description: String?, icon: String?,
                    dataSources: [String]?, signals: String?, prompt: String?,
                    outputSchema: String? = nil) -> AnalysisLensDefinition? {
        let filePath = (userDirectory as NSString).appendingPathComponent("\(id).md")
        guard FileManager.default.fileExists(atPath: filePath) else {
            print("[AnalysisLensLoader] Cannot update: lens '\(id)' not found in user directory")
            return nil
        }

        guard let current = parseLensFile(path: filePath, origin: .user) else { return nil }

        let updated = AnalysisLensDefinition(
            id: id,
            name: name ?? current.name,
            description: description ?? current.description,
            icon: icon ?? current.icon,
            author: nil,
            version: nil,
            dataSources: dataSources?.filter { AnalysisLensDefinition.validDataSources.contains($0) } ?? current.dataSources,
            signals: signals ?? current.signals,
            prompt: prompt ?? current.prompt,
            outputSchema: outputSchema ?? current.outputSchema,
            enabled: current.enabled,
            origin: .user
        )

        let content = updated.toMarkdown()
        do {
            try content.write(toFile: filePath, atomically: true, encoding: .utf8)
            return updated
        } catch {
            print("[AnalysisLensLoader] Failed to update lens file: \(error)")
            return nil
        }
    }

    /// Delete a user lens. Returns true if deleted.
    func deleteLens(id: String) -> Bool {
        let filePath = (userDirectory as NSString).appendingPathComponent("\(id).md")
        guard FileManager.default.fileExists(atPath: filePath) else {
            print("[AnalysisLensLoader] Cannot delete: lens '\(id)' not found in user directory")
            return false
        }

        do {
            try FileManager.default.removeItem(atPath: filePath)
            var state = loadEnabledState()
            state.removeValue(forKey: id)
            saveEnabledState(state)
            return true
        } catch {
            print("[AnalysisLensLoader] Failed to delete lens: \(error)")
            return false
        }
    }

    // MARK: - Markdown Parsing

    /// Parse a single analysis lens Markdown file into an AnalysisLensDefinition
    func parseLensFile(path: String, origin: AnalysisLensOrigin, enabledState: [String: Bool]? = nil) -> AnalysisLensDefinition? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }

        let id = MarkdownDefinitionParser.idFromFilename(path)

        guard let name = MarkdownDefinitionParser.parseTitle(content: content) else {
            print("[AnalysisLensLoader] Skipping \((path as NSString).lastPathComponent): no title found")
            return nil
        }

        let description = MarkdownDefinitionParser.parseMetadataField(content: content, key: "Description") ?? ""
        let icon = MarkdownDefinitionParser.parseMetadataField(content: content, key: "Icon") ?? "🔍"
        let author = MarkdownDefinitionParser.parseMetadataField(content: content, key: "Author")
        let version = MarkdownDefinitionParser.parseMetadataField(content: content, key: "Version")
        let signals = MarkdownDefinitionParser.parseMetadataField(content: content, key: "Signals") ?? ""
        let dataSourcesRaw = MarkdownDefinitionParser.parseMetadataField(content: content, key: "Data Sources") ?? ""

        let dataSources = dataSourcesRaw
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { AnalysisLensDefinition.validDataSources.contains($0) }

        let prompt = MarkdownDefinitionParser.parseSection(content: content, header: "Prompt") ?? ""
        let outputSchema = MarkdownDefinitionParser.parseSection(content: content, header: "Output Schema")

        guard !prompt.isEmpty else {
            print("[AnalysisLensLoader] Skipping \((path as NSString).lastPathComponent): no ## Prompt section found")
            return nil
        }

        let state = enabledState ?? loadEnabledState()
        let enabled = state[id] ?? true

        return AnalysisLensDefinition(
            id: id, name: name, description: description, icon: icon,
            author: author, version: version, dataSources: dataSources,
            signals: signals, prompt: prompt, outputSchema: outputSchema,
            enabled: enabled, origin: origin
        )
    }

    // MARK: - Private Helpers

    private func loadLensesFromDirectory(_ directory: String, origin: AnalysisLensOrigin,
                                          enabledState: [String: Bool]) -> [AnalysisLensDefinition] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: directory) else { return [] }

        return files
            .filter { $0.hasSuffix(".md") }
            .compactMap { filename -> AnalysisLensDefinition? in
                let path = (directory as NSString).appendingPathComponent(filename)
                return parseLensFile(path: path, origin: origin, enabledState: enabledState)
            }
    }

    private func loadEnabledState() -> [String: Bool] {
        guard let data = FileManager.default.contents(atPath: statePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Bool] else {
            return [:]
        }
        return json
    }

    private func saveEnabledState(_ state: [String: Bool]) {
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: URL(fileURLWithPath: statePath))
    }

    // MARK: - Default Analysis Lenses

    /// Install default analysis lenses if they don't already exist.
    /// These are the 7 pattern detectors that replace the monolithic skill prompts.
    private func installDefaultLenses() {
        let fm = FileManager.default

        let defaults: [(filename: String, content: String)] = [
            ("avoidance-detector.md", Self.avoidanceDetectorLens),
            ("leverage-finder.md", Self.leverageFinderLens),
            ("relationship-health.md", Self.relationshipHealthLens),
            ("attention-drain.md", Self.attentionDrainLens),
            ("commitment-tracker.md", Self.commitmentTrackerLens),
            ("calendar-pressure.md", Self.calendarPressureLens),
            ("energy-pattern.md", Self.energyPatternLens),
        ]

        for (filename, content) in defaults {
            let filePath = (installedDirectory as NSString).appendingPathComponent(filename)
            guard !fm.fileExists(atPath: filePath) else { continue }

            do {
                try content.write(toFile: filePath, atomically: true, encoding: .utf8)
                print("[AnalysisLensLoader] Installed default lens: \(filename)")
            } catch {
                print("[AnalysisLensLoader] Failed to install default lens \(filename): \(error)")
            }
        }
    }

    // MARK: - Default Lens Content

    private static let avoidanceDetectorLens = """
    # Avoidance Detector

    **Description:** Identifies tasks being avoided — untouched for 14+ days, postponed repeatedly, or created but never started
    **Icon:** 🪞
    **Author:** Alfred
    **Version:** 1.0
    **Signals:** avoided_task, escalated_avoidance, postponement_pattern
    **Data Sources:** tasks_detailed

    ## Output Schema
    ```json
    {
      "signals": [
        {
          "type": "avoided_task | escalated_avoidance | postponement_pattern",
          "task_name": "string",
          "days_untouched": "number",
          "confidence": "0.0-1.0",
          "evidence": "string"
        }
      ]
    }
    ```

    ## Prompt
    You are an avoidance pattern detector. Analyze the task data and identify signs of procrastination or avoidance.

    Detection rules:
    - **avoided_task**: Any task created 14+ days ago with no status change or progress. Confidence scales with age: 14d=0.6, 21d=0.8, 30d+=0.95
    - **escalated_avoidance**: Task untouched for 21+ days. This is a stronger signal requiring direct confrontation.
    - **postponement_pattern**: Task whose due date has been moved 2+ times. Evidence should note how many times.

    Output ONLY valid JSON matching the Output Schema above. If no signals are detected, return: {"signals": []}

    Few-shot example:
    Input: Task "Write Q2 board deck" created 18 days ago, status "Not Started", due date moved once.
    Output: {"signals": [{"type": "avoided_task", "task_name": "Write Q2 board deck", "days_untouched": 18, "confidence": 0.7, "evidence": "Created 18 days ago, still Not Started. Due date already moved once."}]}
    """

    private static let leverageFinderLens = """
    # Leverage Finder

    **Description:** Identifies the single highest-leverage action — blocking others, overdue commitments, strategic opportunities
    **Icon:** 🎯
    **Author:** Alfred
    **Version:** 1.0
    **Signals:** blocking_others, overdue_commitment, strategic_opportunity
    **Data Sources:** tasks, calendar, commitments

    ## Output Schema
    ```json
    {
      "signals": [
        {
          "type": "blocking_others | overdue_commitment | strategic_opportunity",
          "subject": "string",
          "urgency": "high | medium | low",
          "confidence": "0.0-1.0",
          "evidence": "string"
        }
      ]
    }
    ```

    ## Prompt
    You are a leverage detector. Analyze tasks, calendar, and commitments to find the highest-impact action.

    Detection rules:
    - **blocking_others**: A task or commitment where someone is waiting on you. Confidence: 0.9 if overdue, 0.7 if due today, 0.5 if due this week.
    - **overdue_commitment**: A commitment you made to someone that is past its deadline. Urgency scales with how overdue.
    - **strategic_opportunity**: A calendar event or task that represents a disproportionate opportunity (e.g., investor meeting, key hire interview, product launch). Confidence based on how clearly strategic it is.

    Rank signals by urgency. Maximum 3 signals. Output ONLY valid JSON matching the Output Schema.

    Few-shot example:
    Input: Commitment "Send proposal to Sarah" due 3 days ago, status open. Task "Prepare board deck" due tomorrow.
    Output: {"signals": [{"type": "overdue_commitment", "subject": "Send proposal to Sarah", "urgency": "high", "confidence": 0.9, "evidence": "3 days overdue. Sarah is waiting."}, {"type": "blocking_others", "subject": "Prepare board deck", "urgency": "medium", "confidence": 0.7, "evidence": "Due tomorrow, likely needed by others for board meeting."}]}
    """

    private static let relationshipHealthLens = """
    # Relationship Health

    **Description:** Monitors relationship signals — communication gaps, commitment imbalances, one-sided interactions
    **Icon:** 👤
    **Author:** Alfred
    **Version:** 1.0
    **Signals:** communication_gap, commitment_imbalance, relationship_drift
    **Data Sources:** commitments_by_person, messages

    ## Output Schema
    ```json
    {
      "signals": [
        {
          "type": "communication_gap | commitment_imbalance | relationship_drift",
          "person": "string",
          "days_since_contact": "number | null",
          "confidence": "0.0-1.0",
          "evidence": "string"
        }
      ]
    }
    ```

    ## Prompt
    You are a relationship health monitor. Analyze communication and commitment patterns to identify relationships that need attention.

    Detection rules:
    - **communication_gap**: No messages exchanged with a key contact for 7+ days when they're usually active. Confidence: 0.6 at 7d, 0.8 at 14d, 0.95 at 21d+.
    - **commitment_imbalance**: Disproportionate commitment flow — you owe them 3+ things while they owe you 0-1. Or vice versa.
    - **relationship_drift**: Combination of communication gap AND commitment issues. Higher confidence than either alone.

    Only flag people who appear in the data. Maximum 3 signals. Output ONLY valid JSON.

    Few-shot example:
    Input: Contact "Alex" — last message 12 days ago, 3 open commitments to them, 0 from them.
    Output: {"signals": [{"type": "relationship_drift", "person": "Alex", "days_since_contact": 12, "confidence": 0.85, "evidence": "No contact in 12 days + 3 unresolved commitments to them. Relationship needs attention."}]}
    """

    private static let attentionDrainLens = """
    # Attention Drain

    **Description:** Detects where attention is being consumed — messaging overload, meeting density, context switching
    **Icon:** 📡
    **Author:** Alfred
    **Version:** 1.0
    **Signals:** messaging_overload, meeting_density, no_focus_time
    **Data Sources:** messages_detailed, calendar

    ## Output Schema
    ```json
    {
      "signals": [
        {
          "type": "messaging_overload | meeting_density | no_focus_time",
          "subject": "string",
          "metric": "string",
          "confidence": "0.0-1.0",
          "evidence": "string"
        }
      ]
    }
    ```

    ## Prompt
    You are an attention allocation analyzer. Examine messaging velocity and calendar density to find attention drains.

    Detection rules:
    - **messaging_overload**: A group or person with inbound/outbound ratio >10:1, or >50 messages in 24h from one source. Name the source.
    - **meeting_density**: 3+ back-to-back meetings with no breaks, or >6 meetings in a day. Note the window.
    - **no_focus_time**: Less than 2 hours of unscheduled time in the workday (9am-6pm). This is always high confidence when true.

    Maximum 3 signals. Output ONLY valid JSON.
    """

    private static let commitmentTrackerLens = """
    # Commitment Tracker

    **Description:** Tracks commitment lifecycle — new commitments made, approaching deadlines, completion patterns
    **Icon:** 🤝
    **Author:** Alfred
    **Version:** 1.0
    **Signals:** new_commitment, approaching_deadline, completion_streak, commitment_overload
    **Data Sources:** commitments, commitments_by_person

    ## Output Schema
    ```json
    {
      "signals": [
        {
          "type": "new_commitment | approaching_deadline | completion_streak | commitment_overload",
          "subject": "string",
          "deadline": "string | null",
          "confidence": "0.0-1.0",
          "evidence": "string"
        }
      ]
    }
    ```

    ## Prompt
    You are a commitment lifecycle tracker. Analyze commitment data to surface what needs attention.

    Detection rules:
    - **new_commitment**: Commitment created in the last 24h. Low urgency, informational.
    - **approaching_deadline**: Commitment due within 48h that isn't marked complete. Confidence increases as deadline approaches.
    - **completion_streak**: 3+ commitments completed in the past week. Positive signal, worth acknowledging.
    - **commitment_overload**: More than 10 open commitments total, or 3+ to the same person. Flag the pattern.

    Maximum 4 signals. Output ONLY valid JSON.
    """

    private static let calendarPressureLens = """
    # Calendar Pressure

    **Description:** Analyzes calendar for preparation gaps, double-bookings, and meeting prep opportunities
    **Icon:** 📅
    **Author:** Alfred
    **Version:** 1.0
    **Signals:** prep_gap, double_booking, high_stakes_meeting, meeting_free_day
    **Data Sources:** calendar

    ## Output Schema
    ```json
    {
      "signals": [
        {
          "type": "prep_gap | double_booking | high_stakes_meeting | meeting_free_day",
          "subject": "string",
          "time": "string | null",
          "confidence": "0.0-1.0",
          "evidence": "string"
        }
      ]
    }
    ```

    ## Prompt
    You are a calendar pressure analyzer. Examine today's and tomorrow's calendar to surface preparation needs and scheduling issues.

    Detection rules:
    - **prep_gap**: A meeting with an external participant or high-stakes topic that has no prep time blocked before it. Confidence higher for external meetings.
    - **double_booking**: Two events overlapping in time. Always high confidence.
    - **high_stakes_meeting**: Board meetings, investor calls, performance reviews, key client meetings. Flag for preparation.
    - **meeting_free_day**: No meetings today or tomorrow. Positive signal — opportunity for deep work.

    Maximum 3 signals. Output ONLY valid JSON.
    """

    private static let energyPatternLens = """
    # Energy Pattern

    **Description:** Detects energy patterns — task completion velocity, Zone of Genius vs Zone 3 work distribution
    **Icon:** ⚡
    **Author:** Alfred
    **Version:** 1.0
    **Signals:** completion_velocity, zone_of_genius, zone_3_grinding, energy_drop
    **Data Sources:** tasks_detailed, calendar

    ## Output Schema
    ```json
    {
      "signals": [
        {
          "type": "completion_velocity | zone_of_genius | zone_3_grinding | energy_drop",
          "subject": "string",
          "metric": "string | null",
          "confidence": "0.0-1.0",
          "evidence": "string"
        }
      ]
    }
    ```

    ## Prompt
    You are an energy pattern detector using a Zone of Genius framework. Analyze task and calendar data to assess energy allocation.

    Detection rules:
    - **completion_velocity**: Compare tasks completed this week vs last week. Notable increase or decrease (>30% change).
    - **zone_of_genius**: Tasks being completed quickly and consistently, especially creative or strategic work. The person is in flow.
    - **zone_3_grinding**: Repetitive, administrative, or operational tasks dominating the completed work. These drain energy.
    - **energy_drop**: Combination of low completion velocity + high meeting load + stale tasks accumulating. Signals burnout risk.

    Maximum 3 signals. Output ONLY valid JSON.
    """
}
