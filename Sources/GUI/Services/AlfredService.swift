import Foundation

/// Main service interface for the GUI app to interact with Alfred's core functionality
@MainActor
class AlfredService: ObservableObject {
    private var orchestrator: BriefingOrchestrator?
    private var config: AppConfig?

    @Published var isInitialized = false
    @Published var error: String?

    init() {
        Task {
            await initialize()
        }
    }

    func initialize() async {
        // Try to load config
        guard let loadedConfig = AppConfig.load() else {
            self.error = "Failed to load config. Please ensure config file exists at ~/.config/alfred/config.json"
            return
        }

        self.config = loadedConfig
        self.orchestrator = BriefingOrchestrator(config: loadedConfig)
        self.isInitialized = true
        self.error = nil
    }

    // MARK: - Messages

    func fetchMessagesSummary(platform: String = "all", timeframe: String = "24h") async throws -> [MessageSummary] {
        guard let orchestrator = orchestrator else {
            throw ServiceError.notInitialized
        }
        return try await orchestrator.getMessagesSummary(platform: platform, timeframe: timeframe)
    }

    func fetchFocusedThread(contactName: String, timeframe: String = "7d") async throws -> FocusedThreadAnalysis {
        guard let orchestrator = orchestrator else {
            throw ServiceError.notInitialized
        }
        return try await orchestrator.getFocusedWhatsAppThread(contactName: contactName, timeframe: timeframe)
    }

    // MARK: - Calendar

    func fetchCalendarBriefing(for date: Date = Date(), calendar: String = "all") async throws -> CalendarBriefing {
        guard let orchestrator = orchestrator else {
            throw ServiceError.notInitialized
        }
        return try await orchestrator.getCalendarBriefing(for: date, calendar: calendar)
    }

    // MARK: - Briefing

    func generateDailyBriefing(for date: Date = Date()) async throws -> DailyBriefing {
        guard let orchestrator = orchestrator else {
            throw ServiceError.notInitialized
        }
        return try await orchestrator.generateBriefing(for: date, sendEmail: false)
    }

    // MARK: - Attention Check

    func generateAttentionCheck() async throws -> AttentionDefenseReport {
        guard let orchestrator = orchestrator else {
            throw ServiceError.notInitialized
        }
        return try await orchestrator.generateAttentionDefenseAlert(sendEmail: false)
    }

    // MARK: - Notion Todos

    func scanWhatsAppForTodos() async throws -> [TodoItem] {
        guard let orchestrator = orchestrator else {
            throw ServiceError.notInitialized
        }
        return try await orchestrator.processWhatsAppTodos()
    }
}

enum ServiceError: Error, LocalizedError {
    case notInitialized
    case configMissing

    var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "Service not initialized. Please check your configuration."
        case .configMissing:
            return "Configuration file not found."
        }
    }
}
