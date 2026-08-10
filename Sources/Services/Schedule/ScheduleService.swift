import Foundation

/// Records the prompts Alfred sends to the self-chat, so the self-chat poll can tell the user's own
/// typed lines apart from Alfred's own (both are `is_from_me` in a self-chat).
private final class RecordingSelfSender: ScheduleSender {
    let inner: ScheduleSender
    let onSelf: (String) -> Void
    init(_ inner: ScheduleSender, _ onSelf: @escaping (String) -> Void) { self.inner = inner; self.onSelf = onSelf }
    func sendSelf(text: String) async -> (ok: Bool, msgID: String) { onSelf(text); return await inner.sendSelf(text: text) }
    func sendTo(jid: String, text: String) async -> (ok: Bool, msgID: String) { await inner.sendTo(jid: jid, text: text) }
}

/// Live wiring for @schedule: builds the real ScheduleManager over Alfred's Google Calendar,
/// Claude, the wa-bridge, and the session store, and drives it. Entry points:
///   handle(_:)  — feed a self-chat line ("@schedule kunal 30m tomorrow", "propose", "yes", …)
///   tick()      — poll the user's self-chat for typed follow-ups AND open sessions' counterpart
///                 threads for replies, then run the 48h expiry sweep. Wired to the 60s timer.
final class ScheduleService {
    static let shared = ScheduleService()
    private var built: ScheduleManager?
    private let lock = NSLock()

    // Self-chat poll state.
    private var selfWatermark: Date?          // process self-chat messages after this; nil = not yet armed
    private var sentPrompts: [(text: String, at: Date)] = []   // Alfred's own self-chat sends, to skip
    private var cachedSelfJID: String?

    private func bridgeBase() -> String { "http://" + (ProcessInfo.processInfo.environment["WA_BRIDGE_ADDR"] ?? "127.0.0.1:8790") }

    var configured: Bool { AppConfig.load()?.calendar.google.first != nil }

    /// The user's own JID — from the bridge /status (canonical <number>@s.whatsapp.net), env override, else "".
    private func resolveSelfJID() async -> String {
        if let j = ProcessInfo.processInfo.environment["WA_SELF_JID"], !j.isEmpty { return j }
        if let c = cachedSelfJID { return c }
        guard let url = URL(string: bridgeBase() + "/status"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let jid = obj["jid"] as? String, !jid.isEmpty else { return "" }
        cachedSelfJID = jid
        return jid
    }

    private func recordPrompt(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        sentPrompts.append((text.trimmingCharacters(in: .whitespacesAndNewlines), Date()))
        if sentPrompts.count > 40 { sentPrompts.removeFirst(sentPrompts.count - 40) }
    }
    /// Whether a self-chat line is one Alfred sent recently (so the poll doesn't feed it back).
    private func isOwnPrompt(_ text: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let cutoff = Date().addingTimeInterval(-30 * 60)
        return sentPrompts.contains { $0.at > cutoff && $0.text == t }
    }

    func manager() -> ScheduleManager? {
        lock.lock(); defer { lock.unlock() }
        if let m = built { return m }
        guard let config = AppConfig.load(), let googleConfig = config.calendar.google.first else { return nil }
        let gcal = GoogleCalendarService(config: googleConfig, accountName: "primary")
        let prefs = ScheduleSlots.Prefs()
        let ai = ClaudeAIService(config: config.ai)
        let base = bridgeBase()
        let bridgeSender = WABridgeSender(selfJIDProvider: { [weak self] in await self?.resolveSelfJID() ?? "" })
        let sender = RecordingSelfSender(bridgeSender) { [weak self] in self?.recordPrompt($0) }
        let deps = ScheduleManager.Deps(
            cal: ScheduleCalendar(cal: gcal, prefs: prefs),
            interp: ScheduleInterpreter(ai: ai),
            drafter: LLMDrafter(ai: ai),
            sender: sender,
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

    /// Feed one self-chat line to the manager (used by the Desk / API trigger).
    func handle(_ text: String) async {
        guard let m = manager() else { return }
        _ = await m.handleSelfChat(text: text, msgID: "api_\(Int(Date().timeIntervalSince1970))", ts: Date())
    }

    /// Poll the self-chat for typed follow-ups + open sessions' counterpart threads, then expire.
    func tick() async {
        guard let m = manager() else { return }
        let base = bridgeBase()

        // 1) The user's own self-chat: @schedule commands + typed consent ("propose"/"yes"/…).
        let selfJID = await resolveSelfJID()
        if !selfJID.isEmpty {
            if let wm = selfWatermark {
                let msgs = await ScheduleService.fetchThread(base, selfJID, wm, 30)
                var newWM = wm
                for msg in msgs where msg.fromMe {
                    if let t = msg.time { if t <= wm { continue }; if t > newWM { newWM = t } }
                    if isOwnPrompt(msg.text) { continue }   // skip Alfred's own prompts
                    _ = await m.handleSelfChat(text: msg.text, msgID: "poll_\(Int((msg.time ?? Date()).timeIntervalSince1970))", ts: msg.time ?? Date())
                }
                selfWatermark = newWM
            } else {
                selfWatermark = Date()   // first tick: arm from now, don't replay history
            }
        }

        // 2) Counterpart replies on open sessions.
        for s in ScheduleStore.shared.allOpenSessions() where s.state != .closed {
            let since = s.proposedAt ?? s.lastActivity
            let msgs = await ScheduleService.fetchThread(base, s.contactJID, since, 20)
            for msg in msgs where !msg.fromMe {
                await m.onContactMessage(jid: s.contactJID, isFromMe: false, text: msg.text, ts: msg.time ?? Date())
            }
        }
        await m.runExpirySweep(Date())
    }

    /// Open sessions for the Desk surface: contact, state, the current prompt, options.
    func openSessionsForDesk() -> [[String: Any]] {
        ScheduleStore.shared.allOpenSessions().map { s in
            [
                "id": s.id, "contact_jid": s.contactJID, "contact_name": s.contactName,
                "state": s.state.rawValue, "prompt": s.lastPromptText, "draft": s.draft,
                "options": ScheduleFmt.slotList(s.slots, .current)
            ]
        }
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
