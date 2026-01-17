import Foundation
import SQLite3

class LearningEngine {
    private var db: OpaquePointer?
    private let dbPath: String
    private let config: AgentConfig

    init(config: AgentConfig) throws {
        self.config = config

        // Store learning data in user's home directory
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let alfredDir = homeDir.appendingPathComponent(".alfred")

        // Create directory if it doesn't exist
        if !FileManager.default.fileExists(atPath: alfredDir.path) {
            try FileManager.default.createDirectory(at: alfredDir, withIntermediateDirectories: true)
        }

        dbPath = alfredDir.appendingPathComponent("learning.db").path

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
            throw LearningError.databaseOpenFailed
        }
    }

    private func createTables() throws {
        let createFeedbackTable = """
        CREATE TABLE IF NOT EXISTS feedback (
            id TEXT PRIMARY KEY,
            decision_id TEXT NOT NULL,
            feedback_type TEXT NOT NULL,
            was_approved INTEGER NOT NULL,
            was_successful INTEGER NOT NULL,
            user_comment TEXT,
            context TEXT NOT NULL,
            timestamp TEXT NOT NULL
        );
        """

        let createPatternsTable = """
        CREATE TABLE IF NOT EXISTS patterns (
            id TEXT PRIMARY KEY,
            agent_type TEXT NOT NULL,
            action_type TEXT NOT NULL,
            context_hash TEXT NOT NULL,
            confidence REAL NOT NULL,
            approval_count INTEGER NOT NULL,
            rejection_count INTEGER NOT NULL,
            success_count INTEGER NOT NULL,
            failure_count INTEGER NOT NULL,
            last_updated TEXT NOT NULL
        );
        """

        let createContextSignalsTable = """
        CREATE TABLE IF NOT EXISTS context_signals (
            id TEXT PRIMARY KEY,
            pattern_id TEXT NOT NULL,
            signal_type TEXT NOT NULL,
            signal_value TEXT NOT NULL,
            weight REAL NOT NULL,
            FOREIGN KEY (pattern_id) REFERENCES patterns(id)
        );
        """

        for query in [createFeedbackTable, createPatternsTable, createContextSignalsTable] {
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
                if sqlite3_step(statement) != SQLITE_DONE {
                    sqlite3_finalize(statement)
                    throw LearningError.tableCreationFailed
                }
                sqlite3_finalize(statement)
            } else {
                throw LearningError.tableCreationFailed
            }
        }
    }

    // MARK: - Feedback Recording

    func recordFeedback(_ feedback: UserFeedback) async throws {
        let query = """
        INSERT INTO feedback (id, decision_id, feedback_type, was_approved, was_successful, user_comment, context, timestamp)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, feedback.id.uuidString, -1, nil)
            sqlite3_bind_text(statement, 2, feedback.decisionId.uuidString, -1, nil)
            sqlite3_bind_text(statement, 3, feedback.feedbackType.rawValue, -1, nil)
            sqlite3_bind_int(statement, 4, feedback.wasApproved ? 1 : 0)
            sqlite3_bind_int(statement, 5, feedback.wasSuccessful ? 1 : 0)
            sqlite3_bind_text(statement, 6, feedback.userComment, -1, nil)
            sqlite3_bind_text(statement, 7, feedback.context, -1, nil)
            sqlite3_bind_text(statement, 8, ISO8601DateFormatter().string(from: feedback.timestamp), -1, nil)

            if sqlite3_step(statement) != SQLITE_DONE {
                throw LearningError.recordingFailed
            }
        } else {
            throw LearningError.recordingFailed
        }

        // Update patterns based on feedback
        try await updatePatterns(from: feedback)
    }

    // MARK: - Pattern Learning

    private func updatePatterns(from feedback: UserFeedback) async throws {
        let contextHash = hashContext(feedback.context)

        // Find or create pattern
        let pattern = try findOrCreatePattern(contextHash: contextHash, context: feedback.context)

        // Update pattern statistics
        var approvalCount = pattern.approvalCount
        var rejectionCount = pattern.rejectionCount
        var successCount = pattern.successCount
        var failureCount = pattern.failureCount

        if feedback.wasApproved {
            approvalCount += 1
        } else {
            rejectionCount += 1
        }

        if feedback.wasSuccessful {
            successCount += 1
        } else {
            failureCount += 1
        }

        // Calculate new confidence
        let totalFeedback = approvalCount + rejectionCount
        let approvalRate = Double(approvalCount) / Double(totalFeedback)
        let successRate = Double(successCount) / Double(max(1, successCount + failureCount))

        let newConfidence = (approvalRate * config.learningMode.explicitWeight) +
                           (successRate * config.learningMode.implicitWeight)

        // Update pattern in database
        let query = """
        UPDATE patterns
        SET confidence = ?, approval_count = ?, rejection_count = ?, success_count = ?, failure_count = ?, last_updated = ?
        WHERE id = ?;
        """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_double(statement, 1, newConfidence)
            sqlite3_bind_int(statement, 2, Int32(approvalCount))
            sqlite3_bind_int(statement, 3, Int32(rejectionCount))
            sqlite3_bind_int(statement, 4, Int32(successCount))
            sqlite3_bind_int(statement, 5, Int32(failureCount))
            sqlite3_bind_text(statement, 6, ISO8601DateFormatter().string(from: Date()), -1, nil)
            sqlite3_bind_text(statement, 7, pattern.id, -1, nil)

            if sqlite3_step(statement) != SQLITE_DONE {
                throw LearningError.updateFailed
            }
        } else {
            throw LearningError.updateFailed
        }
    }

    func getPatternConfidence(for context: String, agentType: AgentType, actionType: String) async throws -> Double {
        let contextHash = hashContext(context)

        let query = """
        SELECT confidence
        FROM patterns
        WHERE agent_type = ? AND action_type = ? AND context_hash = ?
        LIMIT 1;
        """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, agentType.rawValue, -1, nil)
            sqlite3_bind_text(statement, 2, actionType, -1, nil)
            sqlite3_bind_text(statement, 3, contextHash, -1, nil)

            if sqlite3_step(statement) == SQLITE_ROW {
                let confidence = sqlite3_column_double(statement, 0)
                return confidence
            }
        }

        // Default confidence for new patterns
        return 0.5
    }

    // MARK: - Insights

    func getInsights() async throws -> LearningInsights {
        // Calculate total decisions from feedback
        let totalDecisions = try await getTotalDecisions()
        let approvalRate = try await getApprovalRate()
        let successRate = try await getSuccessRate()
        let averageConfidence = try await getAverageConfidence()
        let improvementRate = try await getImprovementRate()
        let topPatterns = try await getTopPatterns()

        return LearningInsights(
            totalDecisions: totalDecisions,
            approvalRate: approvalRate,
            successRate: successRate,
            averageConfidence: averageConfidence,
            improvementRate: improvementRate,
            topPatterns: topPatterns
        )
    }

    private func getTotalDecisions() async throws -> Int {
        let query = "SELECT COUNT(*) FROM feedback;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_ROW {
                return Int(sqlite3_column_int(statement, 0))
            }
        }
        return 0
    }

    private func getApprovalRate() async throws -> Double {
        let query = "SELECT AVG(was_approved) FROM feedback;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_ROW {
                return sqlite3_column_double(statement, 0)
            }
        }
        return 0.0
    }

    private func getSuccessRate() async throws -> Double {
        let query = "SELECT AVG(was_successful) FROM feedback;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_ROW {
                return sqlite3_column_double(statement, 0)
            }
        }
        return 0.0
    }

    private func getAverageConfidence() async throws -> Double {
        let query = "SELECT AVG(confidence) FROM patterns;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_ROW {
                return sqlite3_column_double(statement, 0)
            }
        }
        return 0.5
    }

    private func getImprovementRate() async throws -> Double {
        // Compare approval rate from last 7 days vs previous 7 days
        // Simplified for now
        return 0.0
    }

    private func getTopPatterns() async throws -> [LearningInsights.PatternInsight] {
        let query = """
        SELECT context_hash, (approval_count + rejection_count) as occurrences,
               CAST(approval_count AS REAL) / (approval_count + rejection_count) as approval_rate
        FROM patterns
        WHERE (approval_count + rejection_count) >= 3
        ORDER BY occurrences DESC
        LIMIT 5;
        """

        var patterns: [LearningInsights.PatternInsight] = []
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let contextHash = sqlite3_column_text(statement, 0) {
                    let pattern = LearningInsights.PatternInsight(
                        pattern: String(cString: contextHash),
                        occurrences: Int(sqlite3_column_int(statement, 1)),
                        approvalRate: sqlite3_column_double(statement, 2)
                    )
                    patterns.append(pattern)
                }
            }
        }

        return patterns
    }

    // MARK: - Helpers

    private func findOrCreatePattern(contextHash: String, context: String) throws -> (id: String, approvalCount: Int, rejectionCount: Int, successCount: Int, failureCount: Int) {
        // Try to find existing pattern
        let findQuery = """
        SELECT id, approval_count, rejection_count, success_count, failure_count
        FROM patterns
        WHERE context_hash = ?
        LIMIT 1;
        """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        if sqlite3_prepare_v2(db, findQuery, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, contextHash, -1, nil)

            if sqlite3_step(statement) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(statement, 0))
                let approvalCount = Int(sqlite3_column_int(statement, 1))
                let rejectionCount = Int(sqlite3_column_int(statement, 2))
                let successCount = Int(sqlite3_column_int(statement, 3))
                let failureCount = Int(sqlite3_column_int(statement, 4))

                return (id, approvalCount, rejectionCount, successCount, failureCount)
            }
        }

        // Create new pattern
        let id = UUID().uuidString
        let createQuery = """
        INSERT INTO patterns (id, agent_type, action_type, context_hash, confidence, approval_count, rejection_count, success_count, failure_count, last_updated)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """

        var createStatement: OpaquePointer?
        defer { sqlite3_finalize(createStatement) }

        if sqlite3_prepare_v2(db, createQuery, -1, &createStatement, nil) == SQLITE_OK {
            sqlite3_bind_text(createStatement, 1, id, -1, nil)
            sqlite3_bind_text(createStatement, 2, "unknown", -1, nil)
            sqlite3_bind_text(createStatement, 3, "unknown", -1, nil)
            sqlite3_bind_text(createStatement, 4, contextHash, -1, nil)
            sqlite3_bind_double(createStatement, 5, 0.5)
            sqlite3_bind_int(createStatement, 6, 0)
            sqlite3_bind_int(createStatement, 7, 0)
            sqlite3_bind_int(createStatement, 8, 0)
            sqlite3_bind_int(createStatement, 9, 0)
            sqlite3_bind_text(createStatement, 10, ISO8601DateFormatter().string(from: Date()), -1, nil)

            if sqlite3_step(createStatement) == SQLITE_DONE {
                return (id, 0, 0, 0, 0)
            }
        }

        throw LearningError.patternCreationFailed
    }

    private func hashContext(_ context: String) -> String {
        // Simple hash for context matching
        // In production, use more sophisticated similarity matching
        return String(context.prefix(50).hash)
    }
}

// MARK: - Errors

enum LearningError: Error, LocalizedError {
    case databaseOpenFailed
    case tableCreationFailed
    case recordingFailed
    case updateFailed
    case patternCreationFailed

    var errorDescription: String? {
        switch self {
        case .databaseOpenFailed:
            return "Failed to open learning database"
        case .tableCreationFailed:
            return "Failed to create database tables"
        case .recordingFailed:
            return "Failed to record feedback"
        case .updateFailed:
            return "Failed to update pattern"
        case .patternCreationFailed:
            return "Failed to create pattern"
        }
    }
}
