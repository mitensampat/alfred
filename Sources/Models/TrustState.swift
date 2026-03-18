import Foundation

// MARK: - TrustLevel

enum TrustLevel: String, Codable, Comparable {
    case new = "new"
    case developing = "developing"
    case established = "established"
    case deep = "deep"

    // Ordered for Comparable conformance
    private var order: Int {
        switch self {
        case .new: return 0
        case .developing: return 1
        case .established: return 2
        case .deep: return 3
        }
    }

    static func < (lhs: TrustLevel, rhs: TrustLevel) -> Bool {
        lhs.order < rhs.order
    }

    var displayName: String {
        switch self {
        case .new: return "New"
        case .developing: return "Developing"
        case .established: return "Established"
        case .deep: return "Deep"
        }
    }
}

// MARK: - TrustState

struct TrustState: Codable {
    var level: TrustLevel
    var levelSince: Date
    var totalSessions: Int
    var totalTurns: Int
    var oldestSessionDate: Date?
    var resolvedThemes: Int
    var lastComputedAt: Date

    // MARK: - Thresholds

    /// Evaluates which trust level the given metrics warrant.
    /// Never demotes — pass the current level to enforce the floor.
    static func computeLevel(
        sessions: Int,
        turns: Int,
        resolvedThemes: Int,
        oldestSessionDate: Date?,
        currentLevel: TrustLevel = .new
    ) -> TrustLevel {
        let daysSinceFirst: Int
        if let oldest = oldestSessionDate {
            daysSinceFirst = Calendar.current.dateComponents([.day], from: oldest, to: Date()).day ?? 0
        } else {
            daysSinceFirst = 0
        }

        // Evaluate from highest to lowest, return first that qualifies
        let earned: TrustLevel
        if sessions >= 50 && daysSinceFirst >= 90 && resolvedThemes >= 5 && turns >= 150 {
            earned = .deep
        } else if sessions >= 20 && daysSinceFirst >= 30 && resolvedThemes >= 3 && turns >= 50 {
            earned = .established
        } else if sessions >= 5 && daysSinceFirst >= 7 && resolvedThemes >= 1 {
            earned = .developing
        } else {
            earned = .new
        }

        // Never demote
        return max(earned, currentLevel)
    }

    /// Default state for a brand-new user
    static var defaultState: TrustState {
        TrustState(
            level: .new,
            levelSince: Date(),
            totalSessions: 0,
            totalTurns: 0,
            oldestSessionDate: nil,
            resolvedThemes: 0,
            lastComputedAt: Date()
        )
    }
}
