import Foundation

/// Manages the user's trust level with Alfred.
/// Persists to ~/.alfred/trust_state.json.
/// Trust can only advance, never demote — except for the recency decay cap.
struct TrustStateService {

    static let shared = TrustStateService()

    private let filePath: String

    init() {
        self.filePath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".alfred/trust_state.json").path
    }

    // MARK: - Load / Save

    func loadState() -> TrustState {
        guard let data = FileManager.default.contents(atPath: filePath) else {
            return TrustState.defaultState
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(TrustState.self, from: data)) ?? TrustState.defaultState
    }

    func saveState(_ state: TrustState) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return }

        // Ensure the directory exists
        let dir = (filePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: filePath, contents: data)
    }

    // MARK: - Recompute

    /// Evaluate metrics, advance trust level if warranted (never demotes), persist.
    @discardableResult
    func recompute(
        sessions: Int,
        turns: Int,
        resolvedThemes: Int,
        oldestSessionDate: Date?
    ) -> TrustState {
        var state = loadState()

        let newLevel = TrustState.computeLevel(
            sessions: sessions,
            turns: turns,
            resolvedThemes: resolvedThemes,
            oldestSessionDate: oldestSessionDate,
            currentLevel: state.level
        )

        if newLevel > state.level {
            state.level = newLevel
            state.levelSince = Date()
            print("[TrustState] Level advanced to \(newLevel.displayName)")
        }

        state.totalSessions = sessions
        state.totalTurns = turns
        state.resolvedThemes = resolvedThemes
        state.oldestSessionDate = oldestSessionDate
        state.lastComputedAt = Date()

        saveState(state)
        return state
    }

    // MARK: - Increment Turns

    /// Increment the turn count by 1 (called on every user↔assistant exchange).
    /// Persists immediately so turns survive restarts.
    func incrementTurns() {
        var state = loadState()
        state.totalTurns += 1
        saveState(state)
    }

    // MARK: - Current Level (with recency decay)

    /// Returns the effective trust level for prompt calibration.
    /// Applies recency decay: if daysSinceLastSession > 60, cap at .established.
    func getCurrentLevel() -> TrustLevel {
        let state = loadState()

        // Recency decay: cap at .established if inactive for 60+ days
        if state.oldestSessionDate != nil {
            // Use lastComputedAt as proxy for last activity (updated on every recompute)
            let daysSinceActivity = Calendar.current.dateComponents(
                [.day], from: state.lastComputedAt, to: Date()
            ).day ?? 0

            if daysSinceActivity > 60 && state.level == .deep {
                return .established
            }
        }

        return state.level
    }
}
