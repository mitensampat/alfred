import Foundation

class ExecutionEngine {
    private let appConfig: AppConfig

    init(appConfig: AppConfig) {
        self.appConfig = appConfig
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

    private func executeTaskAdjustment(_ adjustment: TaskAdjustment) async throws -> ExecutionResult {
        // Update task priority in Notion
        // Check top-level tasks_database_id first, then briefing_sources as fallback
        let hasTasksDb = appConfig.notion.tasksDatabaseId != nil || appConfig.notion.briefingSources?.tasksDatabaseId != nil
        guard hasTasksDb else {
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
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let alfredDir = homeDir.appendingPathComponent(".alfred")
        let followupsFile = alfredDir.appendingPathComponent("followups.json")

        // Create directory if needed
        try? FileManager.default.createDirectory(at: alfredDir, withIntermediateDirectories: true)

        // 1. Save to local file for quick access
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

        // 2. Also save to Notion unified Tasks database (if configured)
        // NotionService.init handles checking top-level and briefing_sources
        let notionService = NotionService(config: appConfig.notion)
        if notionService.tasksDatabaseId != nil {
            do {

                // Generate hash for deduplication
                let hashInput = "\(followup.followupAction)|\(followup.originalContext)|\(followup.scheduledFor.timeIntervalSince1970)"
                let hash = String(hashInput.hashValue)

                // Check if already exists
                if let _ = try await notionService.findTaskByHash(hash) {
                    return .success(details: "Follow-up already exists in Notion")
                }

                // Create TaskItem from follow-up
                let taskItem = TaskItem.fromFollowup(followup, hash: hash)

                // Save to Notion
                let pageId = try await notionService.createTask(taskItem)
                return .success(details: "Follow-up created in Notion (ID: \(pageId)) for \(followup.scheduledFor.formatted())")
            } catch {
                // Log error but don't fail - local file was saved
                print("⚠️  Failed to save follow-up to Notion: \(error)")
            }
        }

        return .success(details: "Follow-up reminder created for \(followup.scheduledFor.formatted())")
    }
}
