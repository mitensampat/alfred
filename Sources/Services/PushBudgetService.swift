import Foundation

/// Tracks push notification budget and suppression rules.
/// Ensures Alfred sends at most N pushes per day and respects quiet hours + user activity.
class PushBudgetService {
    static let shared = PushBudgetService()

    private var pushCountToday: Int = 0
    private var pushCountDate: String = ""  // "YYYY-MM-DD"
    private var lastUserActivity: Date = Date.distantPast

    private let statePath: String

    // Defaults (overridden by config)
    var maxPerDay: Int = 5
    var quietHoursStart: Int = 22  // 10pm
    var quietHoursEnd: Int = 7     // 7am
    var suppressionWindowSeconds: TimeInterval = 600  // 10 min

    init() {
        self.statePath = NSString(string: "~/.alfred/push_budget_state.json").expandingTildeInPath
        loadState()
    }

    /// Configure from app config
    func configure(from config: NotificationConfig.PushConfig) {
        if let max = config.maxPerDay { maxPerDay = max }
        if let start = config.quietHoursStart { quietHoursStart = start }
        if let end = config.quietHoursEnd { quietHoursEnd = end }
    }

    // MARK: - Budget

    /// Check if we can send a push right now
    func canPush() -> Bool {
        resetIfNewDay()
        return !shouldSuppress() && remainingBudget() > 0
    }

    /// Record that a push was sent
    func recordPush() {
        resetIfNewDay()
        pushCountToday += 1
        saveState()
        print("📊 [PushBudget] Push sent (\(pushCountToday)/\(maxPerDay) today)")
    }

    /// How many pushes remain today
    func remainingBudget() -> Int {
        resetIfNewDay()
        return max(0, maxPerDay - pushCountToday)
    }

    /// Get stats for UI/debugging
    func getStats() -> [String: Any] {
        resetIfNewDay()
        return [
            "pushCountToday": pushCountToday,
            "maxPerDay": maxPerDay,
            "remaining": remainingBudget(),
            "quietHours": "\(quietHoursStart):00-\(quietHoursEnd):00",
            "isQuietHours": isQuietHours(),
            "lastUserActivity": ISO8601DateFormatter().string(from: lastUserActivity),
            "isUserActive": isUserRecentlyActive()
        ]
    }

    // MARK: - User Activity Tracking

    /// Call this on every authenticated API request to track user activity
    func recordUserActivity() {
        lastUserActivity = Date()
    }

    // MARK: - Suppression Logic

    /// Should we suppress this push?
    func shouldSuppress() -> Bool {
        // Quiet hours
        if isQuietHours() {
            print("🔇 [PushBudget] Suppressed: quiet hours")
            return true
        }

        // User recently active (they're already looking at Alfred)
        if isUserRecentlyActive() {
            print("🔇 [PushBudget] Suppressed: user active within \(Int(suppressionWindowSeconds/60)) min")
            return true
        }

        // Budget exhausted
        if remainingBudget() <= 0 {
            print("🔇 [PushBudget] Suppressed: daily budget exhausted (\(pushCountToday)/\(maxPerDay))")
            return true
        }

        return false
    }

    private func isQuietHours() -> Bool {
        let hour = Calendar.current.component(.hour, from: Date())
        if quietHoursStart > quietHoursEnd {
            // Wraps midnight: e.g., 22-7 means 22,23,0,1,2,3,4,5,6
            return hour >= quietHoursStart || hour < quietHoursEnd
        } else {
            return hour >= quietHoursStart && hour < quietHoursEnd
        }
    }

    private func isUserRecentlyActive() -> Bool {
        return Date().timeIntervalSince(lastUserActivity) < suppressionWindowSeconds
    }

    private func resetIfNewDay() {
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        let today = dateFmt.string(from: Date())
        if pushCountDate != today {
            pushCountToday = 0
            pushCountDate = today
            saveState()
        }
    }

    // MARK: - Persistence

    private struct BudgetState: Codable {
        let pushCountToday: Int
        let pushCountDate: String
    }

    private func loadState() {
        guard FileManager.default.fileExists(atPath: statePath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
              let state = try? JSONDecoder().decode(BudgetState.self, from: data) else {
            return
        }
        pushCountToday = state.pushCountToday
        pushCountDate = state.pushCountDate
    }

    private func saveState() {
        let state = BudgetState(pushCountToday: pushCountToday, pushCountDate: pushCountDate)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: URL(fileURLWithPath: statePath))
        }
    }
}
