import Foundation
import SQLite3

class DecisionLog {
    static let shared: DecisionLog = {
        do {
            return try DecisionLog()
        } catch {
            fatalError("Failed to initialize DecisionLog: \(error)")
        }
    }()

    private var db: OpaquePointer?
    private let dbPath: String

    private init() throws {
        // Store decision log in user's home directory
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let alfredDir = homeDir.appendingPathComponent(".alfred")

        // Create directory if it doesn't exist
        if !FileManager.default.fileExists(atPath: alfredDir.path) {
            try FileManager.default.createDirectory(at: alfredDir, withIntermediateDirectories: true)
        }

        dbPath = alfredDir.appendingPathComponent("decisions.db").path

        try openDatabase()
        try createTables()
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    // MARK: - Database Setup

    private func openDatabase() throws {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            throw DecisionLogError.databaseOpenFailed
        }
    }

    private func createTables() throws {
        let createDecisionsTable = """
        CREATE TABLE IF NOT EXISTS decisions (
            id TEXT PRIMARY KEY,
            agent_type TEXT NOT NULL,
            action_type TEXT NOT NULL,
            reasoning TEXT NOT NULL,
            confidence REAL NOT NULL,
            context TEXT NOT NULL,
            risks TEXT,
            alternatives TEXT,
            requires_approval INTEGER NOT NULL,
            timestamp TEXT NOT NULL
        );
        """

        let createExecutionsTable = """
        CREATE TABLE IF NOT EXISTS executions (
            id TEXT PRIMARY KEY,
            decision_id TEXT NOT NULL,
            execution_type TEXT NOT NULL,
            result TEXT NOT NULL,
            result_details TEXT,
            modifications TEXT,
            timestamp TEXT NOT NULL,
            FOREIGN KEY (decision_id) REFERENCES decisions(id)
        );
        """

        let createRejectionsTable = """
        CREATE TABLE IF NOT EXISTS rejections (
            id TEXT PRIMARY KEY,
            decision_id TEXT NOT NULL,
            reason TEXT NOT NULL,
            timestamp TEXT NOT NULL,
            FOREIGN KEY (decision_id) REFERENCES decisions(id)
        );
        """

        for query in [createDecisionsTable, createExecutionsTable, createRejectionsTable] {
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
                if sqlite3_step(statement) != SQLITE_DONE {
                    sqlite3_finalize(statement)
                    throw DecisionLogError.tableCreationFailed
                }
                sqlite3_finalize(statement)
            } else {
                throw DecisionLogError.tableCreationFailed
            }
        }
    }

    // MARK: - Recording Decisions

    func recordExecution(_ decision: AgentDecision, result: ExecutionResult) async throws {
        try saveDecision(decision)

        let query = """
        INSERT INTO executions (id, decision_id, execution_type, result, result_details, modifications, timestamp)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """

        let id = UUID().uuidString
        let resultType = resultTypeString(result)
        let resultDetails = resultDetailsString(result)

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, id, -1, nil)
            sqlite3_bind_text(statement, 2, decision.id.uuidString, -1, nil)
            sqlite3_bind_text(statement, 3, "manual_approval", -1, nil)
            sqlite3_bind_text(statement, 4, resultType, -1, nil)
            sqlite3_bind_text(statement, 5, resultDetails, -1, nil)
            sqlite3_bind_text(statement, 6, nil, -1, nil)
            sqlite3_bind_text(statement, 7, ISO8601DateFormatter().string(from: Date()), -1, nil)

            if sqlite3_step(statement) != SQLITE_DONE {
                throw DecisionLogError.recordingFailed
            }
        } else {
            throw DecisionLogError.recordingFailed
        }
    }

    func recordAutoExecution(_ decision: AgentDecision, result: ExecutionResult) async throws {
        try saveDecision(decision)

        let query = """
        INSERT INTO executions (id, decision_id, execution_type, result, result_details, modifications, timestamp)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """

        let id = UUID().uuidString
        let resultType = resultTypeString(result)
        let resultDetails = resultDetailsString(result)

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, id, -1, nil)
            sqlite3_bind_text(statement, 2, decision.id.uuidString, -1, nil)
            sqlite3_bind_text(statement, 3, "auto_execution", -1, nil)
            sqlite3_bind_text(statement, 4, resultType, -1, nil)
            sqlite3_bind_text(statement, 5, resultDetails, -1, nil)
            sqlite3_bind_text(statement, 6, nil, -1, nil)
            sqlite3_bind_text(statement, 7, ISO8601DateFormatter().string(from: Date()), -1, nil)

            if sqlite3_step(statement) != SQLITE_DONE {
                throw DecisionLogError.recordingFailed
            }
        } else {
            throw DecisionLogError.recordingFailed
        }
    }

    func recordModifiedExecution(_ decision: AgentDecision, modifications: DecisionModifications, result: ExecutionResult) async throws {
        try saveDecision(decision)

        let query = """
        INSERT INTO executions (id, decision_id, execution_type, result, result_details, modifications, timestamp)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """

        let id = UUID().uuidString
        let resultType = resultTypeString(result)
        let resultDetails = resultDetailsString(result)
        let modificationsJSON = try? JSONEncoder().encode(modifications)
        let modificationsString = modificationsJSON.flatMap { String(data: $0, encoding: .utf8) }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, id, -1, nil)
            sqlite3_bind_text(statement, 2, decision.id.uuidString, -1, nil)
            sqlite3_bind_text(statement, 3, "modified_approval", -1, nil)
            sqlite3_bind_text(statement, 4, resultType, -1, nil)
            sqlite3_bind_text(statement, 5, resultDetails, -1, nil)
            sqlite3_bind_text(statement, 6, modificationsString, -1, nil)
            sqlite3_bind_text(statement, 7, ISO8601DateFormatter().string(from: Date()), -1, nil)

            if sqlite3_step(statement) != SQLITE_DONE {
                throw DecisionLogError.recordingFailed
            }
        } else {
            throw DecisionLogError.recordingFailed
        }
    }

    func recordRejection(_ decision: AgentDecision, reason: String) async throws {
        try saveDecision(decision)

        let query = """
        INSERT INTO rejections (id, decision_id, reason, timestamp)
        VALUES (?, ?, ?, ?);
        """

        let id = UUID().uuidString

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, id, -1, nil)
            sqlite3_bind_text(statement, 2, decision.id.uuidString, -1, nil)
            sqlite3_bind_text(statement, 3, reason, -1, nil)
            sqlite3_bind_text(statement, 4, ISO8601DateFormatter().string(from: Date()), -1, nil)

            if sqlite3_step(statement) != SQLITE_DONE {
                throw DecisionLogError.recordingFailed
            }
        } else {
            throw DecisionLogError.recordingFailed
        }
    }

    private func saveDecision(_ decision: AgentDecision) throws {
        let query = """
        INSERT OR REPLACE INTO decisions (id, agent_type, action_type, reasoning, confidence, context, risks, alternatives, requires_approval, timestamp)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """

        let actionType = actionTypeString(decision.action)
        let risksJSON = try? JSONEncoder().encode(decision.risks)
        let alternativesJSON = try? JSONEncoder().encode(decision.alternatives)

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, decision.id.uuidString, -1, nil)
            sqlite3_bind_text(statement, 2, decision.agentType.rawValue, -1, nil)
            sqlite3_bind_text(statement, 3, actionType, -1, nil)
            sqlite3_bind_text(statement, 4, decision.reasoning, -1, nil)
            sqlite3_bind_double(statement, 5, decision.confidence)
            sqlite3_bind_text(statement, 6, decision.context, -1, nil)
            sqlite3_bind_text(statement, 7, risksJSON.flatMap { String(data: $0, encoding: .utf8) }, -1, nil)
            sqlite3_bind_text(statement, 8, alternativesJSON.flatMap { String(data: $0, encoding: .utf8) }, -1, nil)
            sqlite3_bind_int(statement, 9, decision.requiresApproval ? 1 : 0)
            sqlite3_bind_text(statement, 10, ISO8601DateFormatter().string(from: decision.timestamp), -1, nil)

            if sqlite3_step(statement) != SQLITE_DONE {
                throw DecisionLogError.recordingFailed
            }
        } else {
            throw DecisionLogError.recordingFailed
        }
    }

    // MARK: - Retrieving Audit Trail

    func getEntries(since: Date) async throws -> [AuditEntry] {
        let query = """
        SELECT d.*, e.result, e.result_details, e.execution_type
        FROM decisions d
        LEFT JOIN executions e ON d.id = e.decision_id
        WHERE d.timestamp >= ?
        ORDER BY d.timestamp DESC
        LIMIT 100;
        """

        var entries: [AuditEntry] = []
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, ISO8601DateFormatter().string(from: since), -1, nil)

            // This is a simplified version - in production you'd parse the full result set
            while sqlite3_step(statement) == SQLITE_ROW {
                // Parse decision and execution result
                // For now, return empty array - full implementation would parse all columns
            }
        }

        return entries
    }

    func getEntries(for agentType: AgentType, since: Date) async throws -> [AuditEntry] {
        // Similar to getEntries but filtered by agent_type
        return []
    }

    /// Get all decisions made today
    func getDecisionsForToday() throws -> [AgentDecision] {
        let today = Calendar.current.startOfDay(for: Date())
        let todayStr = ISO8601DateFormatter().string(from: today)

        let query = """
        SELECT id, agent_type, action_type, reasoning, confidence, context, risks, alternatives, requires_approval, timestamp
        FROM decisions
        WHERE timestamp >= ?
        ORDER BY timestamp DESC;
        """

        var decisions: [AgentDecision] = []
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, todayStr, -1, nil)

            while sqlite3_step(statement) == SQLITE_ROW {
                if let decision = parseDecisionFromRow(statement) {
                    decisions.append(decision)
                }
            }
        }

        return decisions
    }

    /// Get execution result for a specific decision
    func getExecutionResult(for decisionId: UUID) -> ExecutionResult? {
        let query = """
        SELECT result, result_details FROM executions WHERE decision_id = ? LIMIT 1;
        """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, decisionId.uuidString, -1, nil)

            if sqlite3_step(statement) == SQLITE_ROW {
                let resultType = String(cString: sqlite3_column_text(statement, 0))
                let resultDetails = sqlite3_column_text(statement, 1).map { String(cString: $0) }

                switch resultType {
                case "success":
                    return .success(details: resultDetails ?? "")
                case "failure":
                    return .failure(error: resultDetails ?? "Unknown error")
                case "skipped":
                    return .skipped
                default:
                    return nil
                }
            }
        }

        return nil
    }

    /// Parse a decision from a SQLite row
    private func parseDecisionFromRow(_ statement: OpaquePointer?) -> AgentDecision? {
        guard let statement = statement else { return nil }

        guard let idStr = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
              let id = UUID(uuidString: idStr),
              let agentTypeStr = sqlite3_column_text(statement, 1).map({ String(cString: $0) }),
              let agentType = AgentType(rawValue: agentTypeStr),
              let actionTypeStr = sqlite3_column_text(statement, 2).map({ String(cString: $0) }),
              let reasoning = sqlite3_column_text(statement, 3).map({ String(cString: $0) }),
              let context = sqlite3_column_text(statement, 5).map({ String(cString: $0) }),
              let timestampStr = sqlite3_column_text(statement, 9).map({ String(cString: $0) }) else {
            return nil
        }

        let confidence = sqlite3_column_double(statement, 4)
        let requiresApproval = sqlite3_column_int(statement, 8) == 1

        // Parse risks and alternatives from JSON
        let risks = sqlite3_column_text(statement, 6)
            .flatMap { String(cString: $0).data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []

        let alternatives = sqlite3_column_text(statement, 7)
            .flatMap { String(cString: $0).data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []

        // Parse action type back to AgentAction
        let action = parseActionFromType(actionTypeStr, reasoning: reasoning)

        let timestamp = ISO8601DateFormatter().date(from: timestampStr) ?? Date()

        return AgentDecision(
            id: id,
            agentType: agentType,
            action: action,
            reasoning: reasoning,
            confidence: confidence,
            context: context,
            risks: risks,
            alternatives: alternatives,
            requiresApproval: requiresApproval,
            timestamp: timestamp
        )
    }

    /// Parse action type string back to AgentAction (simplified - returns noAction for most)
    private func parseActionFromType(_ actionType: String, reasoning: String) -> AgentAction {
        // Note: This is a simplified version. In production, you'd store the full action data
        switch actionType {
        case "draft_response":
            return .noAction(reason: "Loaded from log: \(reasoning)")
        case "adjust_task_priority":
            return .noAction(reason: "Loaded from log: \(reasoning)")
        case "schedule_meeting_prep":
            return .noAction(reason: "Loaded from log: \(reasoning)")
        case "create_followup":
            return .noAction(reason: "Loaded from log: \(reasoning)")
        default:
            return .noAction(reason: reasoning)
        }
    }

    // MARK: - Helpers

    private func actionTypeString(_ action: AgentAction) -> String {
        switch action {
        case .draftResponse: return "draft_response"
        case .adjustTaskPriority: return "adjust_task_priority"
        case .scheduleMeetingPrep: return "schedule_meeting_prep"
        case .createFollowup: return "create_followup"
        case .noAction: return "no_action"
        }
    }

    private func resultTypeString(_ result: ExecutionResult) -> String {
        switch result {
        case .success: return "success"
        case .failure: return "failure"
        case .skipped: return "skipped"
        }
    }

    private func resultDetailsString(_ result: ExecutionResult) -> String? {
        switch result {
        case .success(let details): return details
        case .failure(let error): return error
        case .skipped: return nil
        }
    }
}

// MARK: - Errors

enum DecisionLogError: Error, LocalizedError {
    case databaseOpenFailed
    case tableCreationFailed
    case recordingFailed

    var errorDescription: String? {
        switch self {
        case .databaseOpenFailed:
            return "Failed to open decision log database"
        case .tableCreationFailed:
            return "Failed to create database tables"
        case .recordingFailed:
            return "Failed to record decision"
        }
    }
}
