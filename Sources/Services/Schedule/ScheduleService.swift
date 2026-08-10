import Foundation

/// Live wiring for @schedule: builds the real ScheduleManager over Alfred's Google Calendar,
/// Claude, the wa-bridge, and the session store, and drives it. Entry points:
///   handle(_:)  — feed a self-chat line ("@schedule kunal 30m tomorrow", "propose", "yes", …)
///   tick()      — poll open sessions' counterpart threads for replies + run the 48h expiry sweep
///
/// Live activation needs a paired wa-bridge, Google Calendar connected, and the user's own JID in
/// WA_SELF_JID (for the self-chat prompts). The orchestration itself is verified by the dry-run.
final class ScheduleService {
    static let shared = ScheduleService()
    private var built: ScheduleManager?
    private let lock = NSLock()

    private func bridgeBase() -> String { "http://" + (ProcessInfo.processInfo.environment["WA_BRIDGE_ADDR"] ?? "127.0.0.1:8790") }
    private func selfJID() -> String { ProcessInfo.processInfo.environment["WA_SELF_JID"] ?? "" }

    /// Whether the feature can run live (config present).
    var configured: Bool { AppConfig.load()?.calendar.google.first != nil }

    func manager() -> ScheduleManager? {
        lock.lock(); defer { lock.unlock() }
        if let m = built { return m }
        guard let config = AppConfig.load(), let googleConfig = config.calendar.google.first else { return nil }
        let gcal = GoogleCalendarService(config: googleConfig, accountName: "primary")
        let prefs = ScheduleSlots.Prefs()
        let ai = ClaudeAIService(config: config.ai)
        let base = bridgeBase()
        let deps = ScheduleManager.Deps(
            cal: ScheduleCalendar(cal: gcal, prefs: prefs),
            interp: ScheduleInterpreter(ai: ai),
            drafter: LLMDrafter(ai: ai),
            sender: WABridgeSender(selfJID: selfJID()),
            store: ScheduleStore.shared,
            timezone: prefs.timezone,
            myStyle: { "" },
            directChats: { await ScheduleService.fetchContacts(base) },
            thread: { jid, since, limit in await ScheduleService.fetchThread(base, jid, since, limit) },
            contactTZOverride: { _ in "" })
        let m = ScheduleManager(deps)
        built = m
        return m
    }

    /// Feed one self-chat line to the manager.
    func handle(_ text: String) async {
        guard let m = manager() else { return }
        _ = await m.handleSelfChat(text: text, msgID: "api_\(Int(Date().timeIntervalSince1970))", ts: Date())
    }

    /// Poll each open session's counterpart thread for new replies, then run the expiry sweep.
    func tick() async {
        guard let m = manager() else { return }
        let base = bridgeBase()
        for s in ScheduleStore.shared.allOpenSessions() where s.state != .closed {
            let since = s.proposedAt ?? s.lastActivity
            let msgs = await ScheduleService.fetchThread(base, s.contactJID, since, 20)
            for msg in msgs where !msg.fromMe {
                await m.onContactMessage(jid: s.contactJID, isFromMe: false, text: msg.text, ts: msg.time ?? Date())
            }
        }
        await m.runExpirySweep(Date())
    }

    // MARK: - Bridge adapters

    static func fetchContacts(_ base: String) async -> [(jid: String, names: [String])] {
        guard let url = URL(string: base + "/contacts"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.compactMap { o in
            guard let jid = o["jid"] as? String else { return nil }
            var names: [String] = []
            for k in ["full_name", "push_name", "first_name"] { if let n = o[k] as? String, !n.isEmpty, !names.contains(n) { names.append(n) } }
            return names.isEmpty ? nil : (jid, names)
        }
    }

    static func fetchThread(_ base: String, _ jid: String, _ since: Date?, _ limit: Int) async -> [ScheduleThreadMsg] {
        guard var comps = URLComponents(string: base + "/messages") else { return [] }
        var q = [URLQueryItem(name: "chat", value: jid), URLQueryItem(name: "limit", value: String(limit))]
        if let since = since { q.append(URLQueryItem(name: "since", value: String(Int(since.timeIntervalSince1970)))) }
        comps.queryItems = q
        guard let url = comps.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.compactMap { o in
            guard let text = o["content"] as? String, !text.isEmpty else { return nil }
            let fromMe = (o["is_from_me"] as? Bool) ?? false
            let ts: Date? = (o["timestamp"] as? Int).map { Date(timeIntervalSince1970: Double($0)) }
                ?? (o["timestamp"] as? Double).map { Date(timeIntervalSince1970: $0) }
            return ScheduleThreadMsg(fromMe: fromMe, text: text, time: ts)
        }
    }
}
