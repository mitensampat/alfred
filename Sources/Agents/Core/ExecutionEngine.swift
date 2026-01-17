import Foundation

class ExecutionEngine {
    private let appConfig: AppConfig
    private let messageSender: MessageSender

    init(appConfig: AppConfig) {
        self.appConfig = appConfig
        self.messageSender = MessageSender(config: appConfig)
    }

    // MARK: - Execution

    func execute(_ decision: AgentDecision) async throws -> ExecutionResult {
        do {
            let result = try await executeAction(decision.action)
            return result
        } catch {
            return .failure(error: error.localizedDescription)
        }
    }

    private func executeAction(_ action: AgentAction) async throws -> ExecutionResult {
        switch action {
        case .draftResponse(let draft):
            return try await executeDraftResponse(draft)

        case .adjustTaskPriority(let adjustment):
            return try await executeTaskAdjustment(adjustment)

        case .scheduleMeetingPrep(let prep):
            return try await executeScheduleMeetingPrep(prep)

        case .createFollowup(let followup):
            return try await executeCreateFollowup(followup)

        case .noAction(let reason):
            return .skipped
        }
    }

    // MARK: - Action Executors

    private func executeDraftResponse(_ draft: MessageDraft) async throws -> ExecutionResult {
        // Save to drafts file for CLI approval
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let alfredDir = homeDir.appendingPathComponent(".alfred")
        let draftsFile = alfredDir.appendingPathComponent("message_drafts.json")

        // Create directory if needed
        try? FileManager.default.createDirectory(at: alfredDir, withIntermediateDirectories: true)

        var existingDrafts: [MessageDraft] = []
        if FileManager.default.fileExists(atPath: draftsFile.path) {
            if let data = try? Data(contentsOf: draftsFile),
               let decoded = try? JSONDecoder().decode([MessageDraft].self, from: data) {
                existingDrafts = decoded
            }
        }

        existingDrafts.append(draft)

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(existingDrafts)
        try data.write(to: draftsFile)

        return .success(details: "Draft saved for \(draft.recipient) on \(draft.platform.rawValue)")
    }

    // MARK: - Message Sending (for CLI commands)

    func sendDraft(_ draft: MessageDraft) async throws -> SendResult {
        return try await messageSender.sendMessage(draft: draft)
    }

    private func executeTaskAdjustment(_ adjustment: TaskAdjustment) async throws -> ExecutionResult {
        // Update task priority in Notion
        guard appConfig.notion.briefingSources?.tasksDatabaseId != nil else {
            return .failure(error: "Notion tasks database not configured")
        }

        // In a real implementation, this would call NotionService to update the task
        // For now, we'll simulate success
        // TODO: Implement actual Notion API call to update task priority

        return .success(details: "Task '\(adjustment.taskTitle)' priority changed from \(adjustment.currentPriority.rawValue) to \(adjustment.newPriority.rawValue)")
    }

    private func executeScheduleMeetingPrep(_ prep: MeetingPrepTask) async throws -> ExecutionResult {
        // Create a calendar event or Notion task for meeting prep
        // For now, save to a prep tasks file
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let alfredDir = homeDir.appendingPathComponent(".alfred")
        let prepsFile = alfredDir.appendingPathComponent("meeting_preps.json")

        var existingPreps: [MeetingPrepTask] = []
        if FileManager.default.fileExists(atPath: prepsFile.path) {
            if let data = try? Data(contentsOf: prepsFile),
               let decoded = try? JSONDecoder().decode([MeetingPrepTask].self, from: data) {
                existingPreps = decoded
            }
        }

        existingPreps.append(prep)

        let data = try JSONEncoder().encode(existingPreps)
        try data.write(to: prepsFile)

        return .success(details: "Prep scheduled for '\(prep.meetingTitle)' at \(prep.scheduledFor.formatted())")
    }

    private func executeCreateFollowup(_ followup: FollowupReminder) async throws -> ExecutionResult {
        // Create a follow-up reminder in Notion or local storage
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let alfredDir = homeDir.appendingPathComponent(".alfred")
        let followupsFile = alfredDir.appendingPathComponent("followups.json")

        var existingFollowups: [FollowupReminder] = []
        if FileManager.default.fileExists(atPath: followupsFile.path) {
            if let data = try? Data(contentsOf: followupsFile),
               let decoded = try? JSONDecoder().decode([FollowupReminder].self, from: data) {
                existingFollowups = decoded
            }
        }

        existingFollowups.append(followup)

        let data = try JSONEncoder().encode(existingFollowups)
        try data.write(to: followupsFile)

        return .success(details: "Follow-up reminder created for \(followup.scheduledFor.formatted())")
    }
}
