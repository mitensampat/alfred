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
///                 threads for replies, then run the 48h expiry sweep.
///   startWatcher() — runs tick() every 20s. Every entry point (server, menu bar, `alfred
///                 schedule`) calls it; the guard keeps exactly one loop per process.
final class ScheduleService {
    static let shared = ScheduleService()
    private var built: ScheduleManager?
    private let lock = NSLock()

    // Self-chat poll state.
    private var selfWatermark: Date?          // process self-chat messages after this; nil = not yet armed
    private var sentPrompts: [(text: String, at: Date)] = []   // Alfred's own self-chat sends, to skip
    private var cachedSelfJID: String?
    // What Alfred said while a synchronous handle() ran, so the caller (the Desk) can show it
    // instead of guessing from a bare 200. A tick running concurrently can land a line in here too;
    // both are Alfred's own words to the user, so the worst case is one extra line in a toast.
    private var captures: [Int: [String]] = [:]
    private var captureSeq = 0
    private var selfChatExactWorks = false    // the exact self-chat JID has returned rows at least once
    private var watcherRunning = false        // one 60s watcher per process
    private var isWatcherOwner = false        // and one polling process per machine (see claimWatcherTurn)
    private var lastTickAt: Date?             // when this process last polled; nil = it has never run

    private func bridgeBase() -> String { "http://" + (ProcessInfo.processInfo.environment["WA_BRIDGE_ADDR"] ?? "127.0.0.1:8790") }

    var configured: Bool { AppConfig.load()?.calendar.google.first != nil }

    /// Slot preferences for this user. The configured timezone (config.app.timezone) decides what
    /// "4pm" means everywhere in the flow — the slots we compute, the draft the counterpart reads,
    /// the event we book, and the Desk rail — so it must not fall back to the host's zone unless
    /// nothing is configured.
    static func prefs() -> ScheduleSlots.Prefs {
        var p = ScheduleSlots.Prefs()
        if let name = AppConfig.load()?.app.timezone, let tz = TimeZone(identifier: name) { p.timezone = tz }
        return p
    }

    /// Everything @schedule needs, and which of it is actually there. The whole command path runs
    /// through Google Calendar, the wa-bridge (it is the only directory Alfred has for "who is
    /// Arundhati", and the only way to send the ask) and Claude; when one is missing the command
    /// used to end in silence. The Desk shows this, so a dead scheduler names its own cause.
    func readiness() async -> [String: Any] {
        let config = AppConfig.load()
        let gc = config?.calendar.google.first
        let calConnected = gc.map { GoogleCalendarService(config: $0, accountName: "primary").isConnected } ?? false
        let aiOK = !(config?.ai.anthropicApiKey.isEmpty ?? true)
        let selfJID = await resolveSelfJID()
        let base = bridgeBase()
        let bridgeUp = await ScheduleService.bridgeReachable(base)
        let contacts = bridgeUp ? await ScheduleService.fetchContacts(base).count : 0

        let addr = base.replacingOccurrences(of: "http://", with: "")
        var blockers: [String] = []
        if gc == nil { blockers.append("Google Calendar is not configured — add it in Settings.") }
        else if !calConnected { blockers.append("Google Calendar is configured but not connected — reconnect it in Settings.") }
        if !bridgeUp { blockers.append("The WhatsApp bridge at \(addr) is not answering. Scheduling needs it to find who someone is and to send the ask — start it with scripts/wa-bridge.sh run (or install it to keep it up).") }
        else if contacts == 0 { blockers.append("The WhatsApp bridge is up but returned no chats — it is probably not paired. Run scripts/wa-bridge.sh pair and scan the QR once.") }
        else if selfJID.isEmpty { blockers.append("The bridge is up but did not report your own number, so Alfred cannot write to your self-chat.") }
        if !aiOK { blockers.append("No Anthropic API key configured — Alfred cannot read the thread or write the draft.") }
        lock.lock(); let running = watcherRunning; let owner = isWatcherOwner; let lastTick = lastTickAt; lock.unlock()
        // Someone has to be polling: the self-chat is read by nobody otherwise, which is silent by
        // its nature. It may legitimately be another Alfred process — the heartbeat says so.
        let held = readWatcherLock()
        let me = Int(ProcessInfo.processInfo.processIdentifier)
        // `running` only says this process built the loop — it stays true while the loop stands
        // down every tick because another heartbeat holds the turn. Asking it alone let a dead
        // process's lock read as "somebody is polling", which is precisely the silence this
        // endpoint exists to catch. Count only a turn actually being taken: either this process
        // owns it and has ticked, or a *live* other process says so.
        let heldByLiveOther = held.map {
            $0.pid != me && pidAlive($0.pid) && Date().timeIntervalSince1970 - $0.at < 180
        } ?? false
        let iAmPolling = running && owner && (lastTick.map { Date().timeIntervalSince($0) < 300 } ?? false)
        if !iAmPolling && !heldByLiveOther {
            blockers.append("Nothing is polling your WhatsApp self-chat, so anything you type there — \"@schedule <name>\", \"propose\", \"yes\" — is read by nobody. Restart Alfred; the watcher starts with the server.")
        } else if owner, let t = lastTick, Date().timeIntervalSince(t) > 300 {
            blockers.append("The scheduling watcher last polled \(Int(Date().timeIntervalSince(t) / 60)) minutes ago — it should run every 20 seconds.")
        }

        var out: [String: Any] = ["ready": blockers.isEmpty, "blockers": blockers,
                "watcher_running": running, "watcher_owner": owner,
                "calendar_configured": gc != nil, "calendar_connected": calConnected,
                "bridge_reachable": bridgeUp, "bridge_addr": base, "contacts": contacts,
                "self_jid": selfJID, "ai_configured": aiOK]
        if let t = lastTick { out["last_tick_at"] = ISO8601DateFormatter().string(from: t) }
        if let held = held { out["watcher_pid"] = held.pid }   // never nil-as-Any: it would break JSON encoding
        return out
    }

    static func bridgeReachable(_ base: String) async -> Bool {
        guard let url = URL(string: base + "/status") else { return false }
        var req = URLRequest(url: url); req.timeoutInterval = 5
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return false }
        return (200...299).contains(http.statusCode)
    }

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
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        sentPrompts.append((t, Date()))
        if sentPrompts.count > 40 { sentPrompts.removeFirst(sentPrompts.count - 40) }
        for k in Array(captures.keys) { captures[k]?.append(t) }
    }

    private func beginCapture() -> Int {
        lock.lock(); defer { lock.unlock() }
        captureSeq += 1; captures[captureSeq] = []
        return captureSeq
    }
    private func endCapture(_ token: Int) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return captures.removeValue(forKey: token) ?? []
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
        let prefs = Self.prefs()
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

    /// Feed one self-chat line to the manager (used by the Desk / API trigger). Returns what Alfred
    /// said back, so a caller with no WhatsApp self-chat in front of it can show the outcome rather
    /// than a silent 200. `sessionID` targets one session — the Desk's cards are per-session.
    @discardableResult
    func handle(_ text: String, sessionID: String = "") async -> [String: Any] {
        if let body = directBlockBody(text) { return await runDirectBlockReturning(body, announce: true) }   // "@schedule block …" → immediate create + invite
        guard let m = manager() else {
            return ["ok": false, "error": "Google Calendar not configured"]
        }
        // A command that opens a session needs the calendar, the bridge and Claude. If one of them
        // is missing the command cannot do anything useful, and every message explaining that would
        // go to a self-chat that is itself unreachable. Say it here, where it was typed.
        if Self.opensNewSession(text) {
            let r = await readiness()
            if (r["ready"] as? Bool) != true {
                let blockers = (r["blockers"] as? [String]) ?? []
                return ["ok": false, "error": blockers.first ?? "Scheduling isn't set up yet.",
                        "blockers": blockers, "readiness": r]
            }
        }
        let token = beginCapture()
        let consumed = await m.handleSelfChat(text: text, msgID: "api_\(Int(Date().timeIntervalSince1970))", ts: Date(), sessionID: sessionID)
        let said = endCapture(token)
        var out: [String: Any] = ["ok": true, "consumed": consumed]
        if !said.isEmpty { out["messages"] = said; out["message"] = said[said.count - 1] }
        else if !consumed { out["message"] = "Nothing to act on — that didn't match an open scheduling session." }
        return out
    }

    // MARK: - Direct block ("@schedule block <dur> with <person> at <time> topic <t> <email>")

    /// Whether the line is an "@schedule <someone> …" that would open a new session (as opposed to
    /// consent — "propose" / "yes" / "leave it" — on one that already exists).
    static func opensNewSession(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.lowercased().hasPrefix("@schedule") else { return false }
        let rest = String(t.dropFirst("@schedule".count)).trimmingCharacters(in: .whitespaces)
        return !rest.isEmpty && !ScheduleEngine.isConsentText(rest)
    }

    /// The instruction body if `text` is a direct-block ("@schedule block …" or bare "block …"), else nil.
    private func directBlockBody(_ text: String) -> String? {
        var t = text.trimmingCharacters(in: .whitespaces)
        if t.lowercased().hasPrefix("@schedule") { t = String(t.dropFirst("@schedule".count)).trimmingCharacters(in: .whitespaces) }
        return t.lowercased().hasPrefix("block") ? t : nil
    }

    struct DirectBlockPlan { let title: String; let start: Date; let end: Date; let email: String?; let name: String?; let location: String? }

    /// LLM-parse the instruction into a concrete plan (no side effects). Used by both the live
    /// booking and the /api/schedule/parse-block dry-run.
    func parseDirectBlock(_ instruction: String) async -> DirectBlockPlan? {
        guard let config = AppConfig.load() else { return nil }
        let ai = ClaudeAIService(config: config.ai)
        let tz = Self.prefs().timezone
        let iso = ISO8601DateFormatter(); iso.timeZone = tz
        // The instruction is a "block" command: block <duration> with <person> at <time>
        // [topic <topic>] [location <place>] [<email>]. The command scaffolding ("block", the
        // duration, "with <person>") must NEVER become the title — only an explicit topic does.
        let prompt = """
        Extract a single calendar event from this scheduling instruction. "Now" is \(iso.string(from: Date())) (timezone \(tz.identifier)).
        Instruction: "\(instruction)"

        The instruction has the shape: block <duration> with <person> at <time> [topic <topic>] [location/at <place>] [<email>]

        Rules:
        - topic: ONLY the explicit subject, given after "topic", "about", "re", or "on". If none is stated, return "" — do NOT invent one and do NOT use the words "block", the duration, or "with <person>".
        - location: a physical place or room, given after "location", "in", "at <place>", or "@". A clock time (e.g. "4pm", "11:30") is NOT a location. If none, return "".
        - start: resolve relative dates/times (tomorrow, 4pm) to absolute RFC3339 in that timezone; if no clear start time, return "".

        Return ONLY JSON: {"topic":"<explicit topic or empty>","start":"<RFC3339 or empty>","duration_min":<int, default 30>,"attendee_name":"<name or empty>","attendee_email":"<email or empty>","location":"<place or empty>"}
        """
        guard let raw = try? await ai.generateText(prompt: prompt, maxTokens: 300),
              let jd = ScheduleInterpreter.extractJSON(raw).data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: jd) as? [String: Any],
              let startStr = o["start"] as? String, !startStr.isEmpty,
              let start = ScheduleInterpreter.parseRFC3339(startStr) else { return nil }
        let dur = (o["duration_min"] as? Int) ?? Int("\(o["duration_min"] ?? "30")") ?? 30
        let email = (o["attendee_email"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let name = (o["attendee_name"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0.trimmingCharacters(in: .whitespaces) }
        let location = (o["location"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0.trimmingCharacters(in: .whitespaces) }
        // Title = explicit topic; otherwise a clean default ("<Person> <> <Me>"), never the raw command.
        var topic = (o["topic"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        if topic.lowercased().hasPrefix("block ") || topic.lowercased().contains(" with ") { topic = "" }  // guard against echo
        let title: String
        if !topic.isEmpty {
            title = topic
        } else if let n = name {
            let me = (config.user.name.split(separator: " ").first).map(String.init) ?? ""
            title = me.isEmpty ? n : "\(n) <> \(me)"
        } else {
            title = "Hold"
        }
        return DirectBlockPlan(title: title, start: start, end: start.addingTimeInterval(Double(max(5, dur)) * 60), email: email, name: name, location: location)
    }

    /// Parse the instruction with the LLM and create the event + invite immediately — no negotiation.
    /// The WhatsApp-initiated path announces progress + result to the self-chat.
    func runDirectBlock(_ instruction: String) async {
        _ = await runDirectBlockReturning(instruction, announce: true)
    }

    /// The bookable core. Returns a result dict the UI can render synchronously
    /// ({booked,title,when,location,attendee,meet} or {booked:false,error}). When `announce` is
    /// true it also narrates progress + confirmation to the WhatsApp self-chat.
    @discardableResult
    func runDirectBlockReturning(_ instruction: String, announce: Bool) async -> [String: Any] {
        guard let config = AppConfig.load(), let gc = config.calendar.google.first else {
            return ["booked": false, "error": "Google Calendar not configured"]
        }
        let selfJID = announce ? await resolveSelfJID() : ""
        func say(_ s: String) async { if announce { recordPrompt(s); await sendBridge(selfJID, s) } }
        await say("on it — blocking that time…")

        guard let plan = await parseDirectBlock(instruction) else {
            let hint = "I couldn't read a specific time. Try: block 30m with Priya at 4pm tomorrow topic Sync location CRED One priya@x.com"
            await say(hint)
            return ["booked": false, "error": "no concrete time found", "hint": hint]
        }
        let title = plan.title, start = plan.start, end = plan.end, email = plan.email, name = plan.name, location = plan.location
        let tz = Self.prefs().timezone

        let gcal = GoogleCalendarService(config: gc, accountName: "primary")
        do {
            let ev = try await gcal.createEvent(title: title, startTime: start, endTime: end,
                                                location: location, description: name.map { "With \($0)" } ?? "",
                                                attendees: email.map { [$0] }, withMeet: true)
            let f = DateFormatter(); f.timeZone = tz; f.dateFormat = "EEE d MMM, h:mm a"
            let when = f.string(from: start)
            var msg = "✅ Booked: \(title) — \(when)."
            if let location = location { msg += "\n📍 \(location)" }
            if let email = email { msg += "\nInvite sent to \(email)." }
            if let meet = ev.meetLink { msg += "\n\(meet)" }
            await say(msg)
            var out: [String: Any] = ["booked": true, "title": title, "when": when, "start": ISO8601DateFormatter().string(from: start)]
            if let location = location { out["location"] = location }
            if let email = email { out["attendee"] = email }
            if let meet = ev.meetLink { out["meet"] = meet }
            return out
        } catch {
            await say("Couldn't book that: \(error.localizedDescription)")
            return ["booked": false, "error": error.localizedDescription]
        }
    }

    private func sendBridge(_ jid: String, _ text: String) async {
        guard !jid.isEmpty, let url = URL(string: bridgeBase() + "/send") else { return }
        var req = URLRequest(url: url); req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["jid": jid, "message": text])
        _ = try? await URLSession.shared.data(for: req)
    }

    /// Start the 60s watcher, once per process. Everything typed into the WhatsApp self-chat
    /// ("@schedule Arundhati", "propose", "yes") is only ever read by this loop, and so is every
    /// counterpart reply — it used to hang off the `alfred schedule` Scheduler's timer alone, which
    /// neither `alfred server` nor the menu bar starts, so in the mode Alfred actually runs in the
    /// self-chat was polled by nobody. Safe to call from every entry point: the guard keeps one loop.
    func startWatcher(intervalSeconds: UInt64 = 20) {
        lock.lock()
        if watcherRunning { lock.unlock(); return }
        watcherRunning = true
        lock.unlock()
        Task.detached(priority: .utility) {
            while true {
                let startedAt = Date()
                await ScheduleService.shared.tick()
                // Sleep to a deadline, not for a duration. Sleeping *after* the work made the real
                // cadence `interval + tick`, so a tick that did LLM work stretched the gap and the
                // drift compounded across ticks. A tick that overruns the interval starts the next
                // one immediately rather than falling further behind.
                let remaining = Double(intervalSeconds) - Date().timeIntervalSince(startedAt)
                if remaining > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                }
            }
        }
    }

    private func watcherLockPath() -> String {
        let dir = ProcessInfo.processInfo.environment["ALFRED_DIR"] ?? (NSHomeDirectory() + "/.alfred")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "/schedule-watcher.lock"
    }

    private func readWatcherLock() -> (pid: Int, at: Double)? {
        guard let data = FileManager.default.contents(atPath: watcherLockPath()),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = o["pid"] as? Int, let at = o["at"] as? Double else { return nil }
        return (pid, at)
    }

    /// Whether this process should be the one polling. `alfred server` and the menu bar can both be
    /// up, and two watchers would answer the same self-chat line twice. Ownership is a heartbeat
    /// file: whoever has written it in the last three minutes owns it, and a stale one is taken over
    /// by whichever process ticks next — so no process is special and a crash heals itself.
    /// Whether a pid names a live process. A heartbeat only means something while its holder is
    /// running: a restart leaves the previous Alfred's heartbeat on disk and still fresh, so an
    /// age check alone made the new process stand down and wait out the full staleness window —
    /// @schedule silently dead for up to three minutes after every deploy, while health still
    /// reported ready. EPERM means it exists and belongs to somebody else, which still counts.
    private func pidAlive(_ pid: Int) -> Bool {
        if pid <= 0 { return false }
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }

    private func claimWatcherTurn() -> Bool {
        let me = Int(ProcessInfo.processInfo.processIdentifier)
        let now = Date().timeIntervalSince1970
        if let held = readWatcherLock(), held.pid != me, now - held.at < 180, pidAlive(held.pid) {
            lock.lock(); isWatcherOwner = false; lock.unlock()
            return false
        }
        if let data = try? JSONSerialization.data(withJSONObject: ["pid": me, "at": now]) {
            try? data.write(to: URL(fileURLWithPath: watcherLockPath()))
        }
        lock.lock(); isWatcherOwner = true; lock.unlock()
        return true
    }

    /// Poll the self-chat for typed follow-ups + open sessions' counterpart threads, then expire.
    func tick() async {
        guard claimWatcherTurn() else { return }   // another Alfred process is driving it
        lock.lock(); lastTickAt = Date(); lock.unlock()
        guard let m = manager() else { return }
        let base = bridgeBase()

        // 1) The user's own self-chat: @schedule commands + typed consent ("propose"/"yes"/…).
        let selfJID = await resolveSelfJID()
        if !selfJID.isEmpty {
            if let wm = selfWatermark {
                let msgs = await fetchSelfChat(base, selfJID, wm, 30)
                var newWM = wm
                // Every message in your own self-chat is yours, so the is_from_me flag adds nothing
                // here but a way to drop a command silently if the bridge ever records it as false
                // (history-sync rows do). Alfred's own lines are skipped by text below.
                for msg in msgs {
                    // A line we can't place in time can't be watermarked, so acting on it would mean
                    // acting on it again on every tick — a command re-run once a minute, forever.
                    guard let t = msg.time else { continue }
                    if t <= wm { continue }
                    if t > newWM { newWM = t }
                    if isOwnPrompt(msg.text) { continue }   // skip Alfred's own prompts
                    if let body = directBlockBody(msg.text) { await runDirectBlock(body); continue }   // "@schedule block …"
                    _ = await m.handleSelfChat(text: msg.text, msgID: "poll_\(Int(t.timeIntervalSince1970))", ts: t)
                }
                selfWatermark = newWM
            } else {
                // First tick: arm from just before now. Two minutes of grace catches the command
                // typed in the moment before Alfred came up, without replaying the history.
                selfWatermark = Date().addingTimeInterval(-120)
            }
        }

        // 2) Counterpart replies on open sessions — and the user's own messages in that chat, so a
        //    meeting they settle by hand makes Alfred stand down instead of booking over them.
        //    The manager drops anything at or behind the session's watermark, so a message is only
        //    read once however often we poll.
        for s in ScheduleStore.shared.allOpenSessions() where s.state != .closed {
            let since = s.proposedAt ?? s.lastActivity
            let msgs = await ScheduleService.fetchThread(base, s.contactJID, since, 20)
            for msg in msgs {
                guard let t = msg.time else { continue }   // unplaceable in time → can't be watermarked
                await m.onContactMessage(jid: s.contactJID, isFromMe: msg.fromMe, text: msg.text, ts: t)
            }
        }
        await m.runExpirySweep(Date())
    }

    /// Open sessions for the Desk surface: contact, state, the current prompt, options — plus a
    /// human stage label, the disambiguation candidates, and the booked link, so the rail can run
    /// the whole flow without the WhatsApp self-chat.
    func openSessionsForDesk() -> [[String: Any]] {
        let tz = Self.prefs().timezone
        return ScheduleStore.shared.allOpenSessions().map { s in
            var d: [String: Any] = [
                "id": s.id, "contact_jid": s.contactJID, "contact_name": s.contactName,
                "state": s.state.rawValue, "stage_label": Self.stageLabel(s.state, s.contactName),
                "prompt": s.lastPromptText, "draft": s.draft,
                "options": ScheduleFmt.slotList(s.slots, tz)
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

    /// Raw rows from the bridge's /messages. `chat` nil or empty means every chat.
    private static func fetchRaw(_ base: String, _ chat: String?, _ since: Date?, _ limit: Int) async -> [[String: Any]] {
        guard var comps = URLComponents(string: base + "/messages") else { return [] }
        var q = [URLQueryItem(name: "limit", value: String(limit))]
        if let chat = chat, !chat.isEmpty { q.append(URLQueryItem(name: "chat", value: chat)) }
        if let since = since { q.append(URLQueryItem(name: "since", value: String(Int(since.timeIntervalSince1970)))) }
        comps.queryItems = q
        guard let url = comps.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr
    }

    private static func toMsg(_ o: [String: Any]) -> ScheduleThreadMsg? {
        guard let text = o["content"] as? String, !text.isEmpty else { return nil }
        let fromMe = (o["is_from_me"] as? Bool) ?? false
        let ts: Date? = (o["timestamp"] as? Int).map { Date(timeIntervalSince1970: Double($0)) }
            ?? (o["timestamp"] as? Double).map { Date(timeIntervalSince1970: $0) }
        return ScheduleThreadMsg(fromMe: fromMe, text: text, time: ts.map(ScheduleTime.wholeSecond))
    }

    /// The bridge returns the newest first (it selects the latest N). Every prompt that reads a
    /// thread is told "oldest first" and decides on the LAST position it sees, so handing it the
    /// newest first made Alfred act on the message they had already changed their mind about.
    private static func chronological(_ msgs: [ScheduleThreadMsg]) -> [ScheduleThreadMsg] {
        msgs.sorted { ($0.time ?? .distantPast) < ($1.time ?? .distantPast) }
    }

    /// The identifying part of a JID: 919820000000@s.whatsapp.net and 919820000000:12@s.whatsapp.net
    /// both reduce to 919820000000.
    static func jidUser(_ jid: String) -> String {
        let head = jid.split(separator: "@").first.map(String.init) ?? jid
        return head.split(separator: ":").first.map(String.init) ?? head
    }

    static func fetchThread(_ base: String, _ jid: String, _ since: Date?, _ limit: Int) async -> [ScheduleThreadMsg] {
        chronological(await fetchRaw(base, jid, since, limit).compactMap(toMsg))
    }

    /// Messages in the user's own self-chat — the surface @schedule is actually typed into.
    ///
    /// Matching it by an exact chat JID is fragile: the bridge stores whatever form WhatsApp used
    /// for that chat, which need not be the <number>@s.whatsapp.net that /status reports (a device
    /// suffix, or a LID-addressed account). A mismatch returns zero rows, forever, and reads exactly
    /// like the feature being dead. So: try the exact chat, and if it yields nothing, take the
    /// recent window unfiltered and keep what is genuinely a note to self — the chat is you, or the
    /// sender and the chat are the same person and it is not a group.
    func fetchSelfChat(_ base: String, _ selfJID: String, _ since: Date?, _ limit: Int) async -> [ScheduleThreadMsg] {
        let exact = await ScheduleService.fetchRaw(base, selfJID, since, limit)
        if !exact.isEmpty {
            lock.lock(); selfChatExactWorks = true; lock.unlock()
            return ScheduleService.chronological(exact.compactMap(ScheduleService.toMsg))
        }
        lock.lock(); let exactKnownGood = selfChatExactWorks; lock.unlock()
        if exactKnownGood { return [] }   // the exact form works and there is simply nothing new

        let me = ScheduleService.jidUser(selfJID)
        let wide = await ScheduleService.fetchRaw(base, nil, since, max(limit, 100)).filter { o in
            if (o["is_group"] as? Bool) == true { return false }
            let chat = ScheduleService.jidUser((o["chat_jid"] as? String) ?? "")
            if chat.isEmpty { return false }
            if !me.isEmpty && chat == me { return true }
            let sender = ScheduleService.jidUser((o["sender_jid"] as? String) ?? "")
            return (o["is_from_me"] as? Bool) == true && chat == sender
        }
        return ScheduleService.chronological(wide.compactMap(ScheduleService.toMsg))
    }
}
