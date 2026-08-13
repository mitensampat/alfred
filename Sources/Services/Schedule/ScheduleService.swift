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
        if let body = directBlockBody(text) { await runDirectBlock(body); return }   // "@schedule block …" → immediate create + invite
        guard let m = manager() else { return }
        _ = await m.handleSelfChat(text: text, msgID: "api_\(Int(Date().timeIntervalSince1970))", ts: Date())
    }

    // MARK: - Direct block ("@schedule block <dur> with <person> at <time> topic <t> <email>")

    /// The instruction body if `text` is a direct-block ("@schedule block …" or bare "block …"), else nil.
    private func directBlockBody(_ text: String) -> String? {
        var t = text.trimmingCharacters(in: .whitespaces)
        if t.lowercased().hasPrefix("@schedule") { t = String(t.dropFirst("@schedule".count)).trimmingCharacters(in: .whitespaces) }
        return t.lowercased().hasPrefix("block") ? t : nil
    }

    struct DirectBlockPlan { let title: String; let start: Date; let end: Date; let email: String?; let name: String? }

    /// LLM-parse the instruction into a concrete plan (no side effects). Used by both the live
    /// booking and the /api/schedule/parse-block dry-run.
    func parseDirectBlock(_ instruction: String) async -> DirectBlockPlan? {
        guard let config = AppConfig.load() else { return nil }
        let ai = ClaudeAIService(config: config.ai)
        let tz = ScheduleSlots.Prefs().timezone
        let iso = ISO8601DateFormatter(); iso.timeZone = tz
        let prompt = """
        Extract a single calendar event from this instruction. "Now" is \(iso.string(from: Date())) (timezone \(tz.identifier)).
        Instruction: "\(instruction)"
        Return ONLY JSON: {"title":"<topic/title>","start":"<RFC3339 datetime>","duration_min":<int>,"attendee_name":"<name or empty>","attendee_email":"<email or empty>"}
        Resolve relative dates/times (tomorrow, 4pm) to absolute RFC3339 in that timezone. duration_min default 30. Use "" for unknown fields; if no clear start time set start to "".
        """
        guard let raw = try? await ai.generateText(prompt: prompt, maxTokens: 300),
              let jd = ScheduleInterpreter.extractJSON(raw).data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: jd) as? [String: Any],
              let startStr = o["start"] as? String, !startStr.isEmpty,
              let start = ScheduleInterpreter.parseRFC3339(startStr) else { return nil }
        let dur = (o["duration_min"] as? Int) ?? Int("\(o["duration_min"] ?? "30")") ?? 30
        let title = (o["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Meeting"
        let email = (o["attendee_email"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let name = (o["attendee_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return DirectBlockPlan(title: title, start: start, end: start.addingTimeInterval(Double(max(5, dur)) * 60), email: email, name: name)
    }

    /// Parse the instruction with the LLM and create the event + invite immediately — no negotiation.
    func runDirectBlock(_ instruction: String) async {
        guard let config = AppConfig.load(), let gc = config.calendar.google.first else { return }
        let selfJID = await resolveSelfJID()
        func say(_ s: String) async { recordPrompt(s); await sendBridge(selfJID, s) }
        await say("on it — blocking that time…")

        guard let plan = await parseDirectBlock(instruction) else {
            await say("I couldn't read a specific time. Try: @schedule block 30m with Priya at 4pm tomorrow topic Sync priya@x.com")
            return
        }
        let title = plan.title, start = plan.start, end = plan.end, email = plan.email, name = plan.name
        let tz = ScheduleSlots.Prefs().timezone

        let gcal = GoogleCalendarService(config: gc, accountName: "primary")
        do {
            let ev = try await gcal.createEvent(title: title, startTime: start, endTime: end,
                                                location: nil, description: name.map { "With \($0)" } ?? "",
                                                attendees: email.map { [$0] }, withMeet: true)
            let f = DateFormatter(); f.timeZone = tz; f.dateFormat = "EEE d MMM, h:mm a"
            var msg = "✅ Booked: \(title) — \(f.string(from: start))."
            if let email = email { msg += "\nInvite sent to \(email)." }
            if let meet = ev.meetLink { msg += "\n\(meet)" }
            await say(msg)
        } catch {
            await say("Couldn't book that: \(error.localizedDescription)")
        }
    }

    private func sendBridge(_ jid: String, _ text: String) async {
        guard !jid.isEmpty, let url = URL(string: bridgeBase() + "/send") else { return }
        var req = URLRequest(url: url); req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["jid": jid, "message": text])
        _ = try? await URLSession.shared.data(for: req)
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
                    if let body = directBlockBody(msg.text) { await runDirectBlock(body); continue }   // "@schedule block …"
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

    /// Open sessions for the Desk surface: contact, state, the current prompt, options — plus a
    /// human stage label, the disambiguation candidates, and the booked link, so the rail can run
    /// the whole flow without the WhatsApp self-chat.
    func openSessionsForDesk() -> [[String: Any]] {
        ScheduleStore.shared.allOpenSessions().map { s in
            var d: [String: Any] = [
                "id": s.id, "contact_jid": s.contactJID, "contact_name": s.contactName,
                "state": s.state.rawValue, "stage_label": Self.stageLabel(s.state, s.contactName),
                "prompt": s.lastPromptText, "draft": s.draft,
                "options": ScheduleFmt.slotList(s.slots, .current)
            ]
            if !s.bookedLink.isEmpty { d["booked_link"] = s.bookedLink }
            if s.state == .resolving && !s.candidates.isEmpty { d["candidates"] = s.candidates.map { $0.name } }
            return d
        }
    }

    static func stageLabel(_ st: ScheduleState, _ name: String) -> String {
        switch st {
        case .resolving:      return "Who did you mean?"
        case .slotsProposed:  return "Draft ready — review, then send"
        case .awaitingReply:  return "Sent — waiting on \(name)"
        case .replySurfaced:  return "\(name) replied — confirm to book"
        case .held:           return "Soft yes from \(name) — confirm to lock it"
        case .confirmCancel:  return "Confirm the cancellation"
        case .closed:         return "Done"
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
