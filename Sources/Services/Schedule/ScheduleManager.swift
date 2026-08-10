import Foundation

// Injectable surfaces so the dry-run harness can swap in fakes (as Commit's manager tests do).
protocol ScheduleCalendaring {
    var connected: Bool { get }
    func computeSlots(from: Date, to: Date, durationMin: Int, inPerson: Bool, requestedDays: [Int]) async throws -> [ScheduleSlot]
    func verifyFree(start: Date, end: Date) async throws -> Bool
    func book(summary: String, description: String, start: Date, end: Date, withMeet: Bool) async throws -> (eventID: String, htmlLink: String, meetLink: String?)
    func cancel(eventID: String) async throws
}
protocol ScheduleInterpreting {
    func interpretReply(_ rc: ScheduleReplyContext) async throws -> ScheduleInterpretation
    func interpretOwnMessage(_ rc: ScheduleReplyContext) async throws -> Bool
    func classifySelfText(_ sc: ScheduleSelfTextContext) async throws -> ScheduleSelfTextClass
}
extension ScheduleCalendar: ScheduleCalendaring {}
extension ScheduleInterpreter: ScheduleInterpreting {}

/// Orchestrates scheduling sessions: owns persistence + side effects, delegates every decision to
/// the pure engine. Faithful port of Commit's schedule/manager.go + manager_exec.go. Driven through
/// three entry points: handleSelfChat, onContactMessage, runExpirySweep.
actor ScheduleManager {
    struct Deps {
        var cal: ScheduleCalendaring
        var interp: ScheduleInterpreting
        var drafter: ScheduleDrafting
        var sender: ScheduleSender
        var store: ScheduleStore
        var timezone: TimeZone
        var myStyle: () -> String
        var directChats: () async -> [(jid: String, names: [String])]
        var thread: (_ jid: String, _ since: Date?, _ limit: Int) async -> [ScheduleThreadMsg]
        var contactTZOverride: (String) -> String
    }
    private let d: Deps
    private var tz: TimeZone { d.timezone }
    init(_ deps: Deps) { self.d = deps }

    // MARK: - Persistence + prompts

    private func openSessionFor(_ jid: String) -> ScheduleSession? { d.store.openSession(contactJID: jid) }
    private func allOpen() -> [ScheduleSession] { d.store.allOpenSessions() }
    private func save(_ s: ScheduleSession) { d.store.save(s) }

    private func sendSelfPlain(_ text: String) async { _ = await d.sender.sendSelf(text: text) }

    /// A self-chat message that opens/renews the consent window.
    private func prompt(_ s: inout ScheduleSession, _ text: String) async {
        let (ok, id) = await d.sender.sendSelf(text: text)
        guard ok else { return }
        ScheduleEngine.markPrompted(&s, Date())
        s.lastPromptID = id
        s.lastPromptText = text
        save(s)
    }

    private func latestPromptedSession() -> ScheduleSession? {
        allOpen().sorted { ($0.lastPromptAt ?? .distantPast) > ($1.lastPromptAt ?? .distantPast) }.first
    }

    // MARK: - Thread + style

    private func recentThread(_ jid: String, _ n: Int) async -> [ScheduleThreadMsg] { await d.thread(jid, nil, n) }
    private func threadSince(_ jid: String, _ t: Date?) async -> [ScheduleThreadMsg] { await d.thread(jid, t, 50) }
    private func styleSamples(_ jid: String) async -> [String] {
        let msgs = await d.thread(jid, nil, 30)
        var out: [String] = []
        for m in msgs.reversed() where out.count < 5 {
            if m.fromMe && m.text.count > 10 && !m.text.hasPrefix("@") { out.append(m.text) }
        }
        return out
    }

    // MARK: - Slots + draft

    private func computeSlotsFor(_ s: inout ScheduleSession) async throws -> [ScheduleSlot] {
        let now = Date()
        var (from, to) = ScheduleWindow.range(s.window, now: now, tz: tz)
        if from < now { from = now }
        if !(to > from) { from = now; to = Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now.addingTimeInterval(7 * 86400) }
        let dur = s.durationMin == 0 ? 30 : s.durationMin
        let prefDays = ScheduleWindow.preferredDays(s.window)
        let inPerson = s.format == "in-person"
        var slots = try await d.cal.computeSlots(from: from, to: to, durationMin: dur, inPerson: inPerson, requestedDays: prefDays)
        s.requestedDays = ScheduleWindow.formatDays(prefDays)
        s.preferenceMet = true
        if slots.isEmpty && !prefDays.isEmpty {
            s.preferenceMet = false
            slots = try await d.cal.computeSlots(from: from, to: to, durationMin: dur, inPerson: inPerson, requestedDays: [])
        }
        return slots.filter { $0.start > now }
    }

    private func differentTZOnly(_ tzName: String) -> String {
        guard !tzName.isEmpty, tzName != tz.identifier, let ctz = TimeZone(identifier: tzName) else { return "" }
        let now = Date()
        if ctz.secondsFromGMT(for: now) == tz.secondsFromGMT(for: now) { return "" }
        return tzName
    }

    private func redraft(_ s: inout ScheduleSession) async -> String {
        let samples = await styleSamples(s.contactJID)
        return await d.drafter.generateDraft(ScheduleDraftRequest(
            contactName: s.contactName, topic: s.topic, format: s.format, slots: s.slots,
            myStyle: d.myStyle(), timezone: tz, contactTZ: differentTZOnly(s.contactTZ),
            contactTZNote: s.contactTZNote, styleSamples: samples,
            requestedDays: s.requestedDays, preferenceMet: s.preferenceMet, toneNote: s.toneNote))
    }

    private func resurfaceOptions(_ s: inout ScheduleSession, _ header: String) async {
        let slots: [ScheduleSlot]
        do { slots = try await computeSlotsFor(&s) } catch { await prompt(&s, "Calendar error: \(error)"); return }
        if slots.isEmpty {
            await prompt(&s, header + "\n\nBut you have nothing free for a \(s.durationMin)-min \(s.format.isEmpty ? "meeting" : s.format) with \(s.contactName) in that window. Try another window.")
            return
        }
        s.slots = slots
        s.draft = await redraft(&s)
        s.proposedAt = nil; s.proposedSlots = []; s.surfaced = nil
        s.state = .slotsProposed
        var text = header
        if !s.preferenceMet && !s.requestedDays.isEmpty {
            text += "\n\n⚠️ \(s.contactName) asked for \(s.requestedDays) — you have nothing free on those days. Closest alternatives below; the draft says so."
        }
        text += "\n\nFree options:\n" + ScheduleFmt.slotList(s.slots, tz)
        text += "\n\nDraft to send:\n———\n\(s.draft)\n———\n\n'propose' to send it · 'propose 1 3' for a subset · 'yes N' to book directly · 'edit' · 'leave it'"
        await prompt(&s, text)
    }

    // MARK: - Self-chat entry point

    /// Returns true if the scheduler consumed the message.
    func handleSelfChat(text: String, msgID: String, ts: Date) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        if lower.hasPrefix("@schedule") {
            let rest = String(trimmed.dropFirst("@schedule".count)).trimmingCharacters(in: .whitespaces)
            if ScheduleEngine.isConsentText(rest) {
                if var s = latestPromptedSession() {
                    let dec = ScheduleEngine.handleSelfChat(&s, .init(text: rest, now: ts, forceScoped: true))
                    await executeSelfDecision(&s, dec)
                    return true
                }
                await sendSelfPlain("No active scheduling session.")
                return true
            }
            await handleCommand(rest, ts)
            return true
        }

        guard var s = latestPromptedSession() else { return false }
        let before = s.state
        let dec = ScheduleEngine.handleSelfChat(&s, .init(text: trimmed, now: ts, isNextAfterPrompt: false))
        if dec.action == .none && before == s.state { return false }
        await executeSelfDecision(&s, dec)
        return true
    }

    // MARK: - @schedule command

    private func handleCommand(_ rest: String, _ ts: Date) async {
        let cmd: ScheduleCommand
        do { cmd = try ScheduleCommandParser.parse(rest) } catch { await sendSelfPlain("\(error)"); return }

        await sendSelfPlain("on it — checking your calendar…")
        let cands = await resolveContacts(cmd.name)
        switch cands.count {
        case 0:
            await sendSelfPlain("I couldn't find anyone matching \"\(cmd.name)\" in your chats.")
        case 1:
            await startSession(cmd, cands[0], ts)
        default:
            var s = ScheduleSession(id: ScheduleStore.newID(), contactJID: "pending:" + cmd.name.lowercased(),
                                    contactName: cmd.name, state: .resolving, intent: cmd.verb)
            s.cmd = cmd; s.candidates = cands; s.createdAt = ts; s.lastActivity = ts
            var text = "A few people match \"\(cmd.name)\" — who did you mean?\n"
            for (i, c) in cands.enumerated() { text += "\(i + 1). \(c.name)\n" }
            text += "Reply with a number, or 'leave it'."
            await prompt(&s, text)
        }
    }

    private func normalizeQuery(_ s: String) -> String { s.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ") }

    private func nameMatchScore(_ query: String, _ target: String) -> Int {
        let t = target.lowercased().trimmingCharacters(in: .whitespaces)
        if query.isEmpty || t.isEmpty { return 0 }
        if t == query { return 100 }
        if t.contains(query) || query.contains(t) { return 90 }
        let qWords = query.split(separator: " ").map(String.init), tWords = t.split(separator: " ").map(String.init)
        var matched = 0
        for qw in qWords { for tw in tWords where tw.hasPrefix(qw) || qw.hasPrefix(tw) { matched += 1; break } }
        if matched == 0 { return 0 }
        if matched == qWords.count { return 70 }
        return 40 + matched
    }

    private func resolveContacts(_ name: String) async -> [ScheduleContactCandidate] {
        let chats = await d.directChats()
        let q = normalizeQuery(name); if q.isEmpty { return [] }
        struct Scored { var cand: ScheduleContactCandidate; var score: Int }
        var all: [Scored] = []; var seen = Set<String>()
        for c in chats {
            if c.jid.hasSuffix("@g.us") || c.jid.contains("@broadcast") { continue }
            var best = 0; var bestName = c.names.first ?? c.jid
            for cand in c.names { let s = nameMatchScore(q, cand); if s > best { best = s; bestName = cand } }
            if best == 0 { continue }
            if let full = c.names.max(by: { $0.count < $1.count }), full.count > bestName.count { bestName = full }
            if seen.contains(c.jid) { continue }; seen.insert(c.jid)
            all.append(Scored(cand: ScheduleContactCandidate(jid: c.jid, name: bestName), score: best))
        }
        guard let top = all.map({ $0.score }).max() else { return [] }
        var dedup = Set<String>(); var out: [ScheduleContactCandidate] = []
        for s in all where s.score == top { let k = s.cand.name.lowercased(); if !dedup.contains(k) { dedup.insert(k); out.append(s.cand) } }
        return out.sorted { $0.name < $1.name }
    }

    private func startSession(_ cmd: ScheduleCommand, _ contact: ScheduleContactCandidate, _ ts: Date) async {
        if var existing = openSessionFor(contact.jid) { existing.state = .closed; save(existing) }

        if cmd.verb == .cancel { await startCancel(contact, ts); return }
        guard d.cal.connected else {
            await sendSelfPlain("Google Calendar isn't connected — connect it in Settings, then try again."); return
        }

        var s = ScheduleSession(id: ScheduleStore.newID(), contactJID: contact.jid, contactName: contact.name,
                                state: .slotsProposed, intent: cmd.verb)
        s.cmd = cmd; s.createdAt = ts; s.lastActivity = ts
        if cmd.verb == .move {
            if let old = d.store.lastBooked(contactJID: contact.jid) { s.oldEventID = old.bookedEventID }
            else { await sendSelfPlain("I don't have a meeting on record with \(contact.name) to move — scheduling a fresh one instead.") }
        }

        let thread = await recentThread(contact.jid, 10)
        let ic = await d.drafter.inferContext(contactName: contact.name, thread: thread, cmd: cmd)
        s.topic = ic.topic; s.durationMin = ic.durationMin; s.format = ic.format; s.window = ic.window

        let override = d.contactTZOverride(contact.jid)
        if !override.isEmpty { s.contactTZ = override; s.contactTZNote = "you told me they're in " + override }
        else { let g = ScheduleTZGuess.infer(contact.jid); s.contactTZ = g.tz; s.contactTZNote = g.note }

        let slots: [ScheduleSlot]
        do { slots = try await computeSlotsFor(&s) } catch { await sendSelfPlain("Calendar error: \(error)"); return }
        if slots.isEmpty {
            await sendSelfPlain("No free slots for \(contact.name) in that window (\(s.window.isEmpty ? "the next week" : s.window)). Try a different window?"); return
        }
        s.slots = slots
        s.draft = await redraft(&s)

        var text = "Scheduling with *\(s.contactName)* — \(s.topic), \(s.durationMin) min"
        if !s.format.isEmpty { text += ", " + s.format }
        if !s.window.isEmpty { text += ", " + s.window }
        if !s.contactTZ.isEmpty && s.contactTZ != tz.identifier { text += "\n(their timezone: \(s.contactTZ) — \(s.contactTZNote))" }
        if !s.preferenceMet && !s.requestedDays.isEmpty {
            text += "\n\n⚠️ \(s.contactName) asked for \(s.requestedDays) — you have nothing free on those days. Closest alternatives below; the draft says so."
        }
        text += "\n\nFree options:\n" + ScheduleFmt.slotList(s.slots, tz)
        text += "\n\nDraft to send:\n———\n\(s.draft)\n———\n\n'propose' to send it · 'propose 1 3' for a subset · 'yes N' to book directly · 'edit' · 'leave it'"
        await prompt(&s, text)
    }

    private func startCancel(_ contact: ScheduleContactCandidate, _ ts: Date) async {
        guard let booked = d.store.lastBooked(contactJID: contact.jid), !booked.bookedEventID.isEmpty else {
            await sendSelfPlain("I don't have a meeting on record with \(contact.name) to cancel."); return
        }
        let when = booked.bookedSlot.map { ScheduleFmt.slotShort($0, tz) } ?? ""
        var s = ScheduleSession(id: ScheduleStore.newID(), contactJID: contact.jid, contactName: contact.name,
                                state: .confirmCancel, intent: .cancel)
        s.topic = booked.topic; s.bookedEventID = booked.bookedEventID; s.bookedSlot = booked.bookedSlot
        s.createdAt = ts; s.lastActivity = ts
        await prompt(&s, "Cancel your meeting with *\(contact.name)*\(when.isEmpty ? "" : " (\(when))")?\n\n'yes' sends them a graceful note · 'yes silent' just deletes the event · 'leave it'")
    }

    // MARK: - Executor (self decisions)

    private func executeSelfDecision(_ s: inout ScheduleSession, _ dec: ScheduleDecision) async {
        switch dec.action {
        case .none:
            save(s)
        case .ask, .alreadyProposed, .editPrompt, .replaceDraft:
            await prompt(&s, dec.reply)
        case .classifyText:
            await classifyAndApply(&s, dec.text)
        case .applyInstruction:
            await applyInstruction(&s, dec.selfClass)
        case .close:
            save(s); await sendSelfPlain(dec.reply)
        case .pickContact:
            guard dec.index >= 1 && dec.index <= s.candidates.count else {
                await prompt(&s, "Pick a number between 1 and \(s.candidates.count)."); return
            }
            let chosen = s.candidates[dec.index - 1]
            let cmd = s.cmd ?? ScheduleCommand(verb: s.intent, name: chosen.name)
            s.state = .closed; save(s)
            await startSession(cmd, chosen, Date())
        case .propose:
            if !dec.indices.isEmpty {
                s.slots = dec.indices.compactMap { $0 >= 1 && $0 <= s.slots.count ? s.slots[$0 - 1] : nil }
                s.proposedSlots = []
                s.draft = await redraft(&s)
            }
            s.sentDraft = s.draft
            let (ok, _) = await d.sender.sendTo(jid: s.contactJID, text: s.draft)
            if !ok {
                s.state = .slotsProposed; s.proposedAt = nil
                await prompt(&s, "Couldn't send the message to \(s.contactName) (WhatsApp error). Nothing went out — try 'propose' again.")
                return
            }
            save(s)
            await sendSelfPlain("Sent to \(s.contactName). I'll ping you here when they reply.")
        case .requestBooking:
            await finalizeBooking(&s, dec.index)
        case .cancelMeeting:
            await doCancel(&s, silent: false)
        case .cancelSilent:
            await doCancel(&s, silent: true)
        default:
            save(s)
        }
    }

    private func doCancel(_ s: inout ScheduleSession, silent: Bool) async {
        if !silent {
            let when = s.bookedSlot.map { ScheduleFmt.slotShort($0, tz) } ?? ""
            let note = await d.drafter.generateDraft(ScheduleDraftRequest(contactName: s.contactName, topic: s.topic, myStyle: d.myStyle(), timezone: tz, cancel: true, bookedWhen: when))
            do { try await d.cal.cancel(eventID: s.bookedEventID) } catch { await prompt(&s, "Couldn't delete the calendar event: \(error)"); return }
            let (ok, _) = await d.sender.sendTo(jid: s.contactJID, text: note)
            s.state = .closed; save(s)
            if ok { await sendSelfPlain("Cancelled — event deleted and \(s.contactName) got a graceful note.") }
            else { await sendSelfPlain("Event deleted, but the note to \(s.contactName) failed to send. You may want to tell them yourself.") }
        } else {
            do { try await d.cal.cancel(eventID: s.bookedEventID) } catch { await prompt(&s, "Couldn't delete the calendar event: \(error)"); return }
            s.state = .closed; save(s)
            await sendSelfPlain("Deleted the event. Said nothing.")
        }
    }

    private func classifyAndApply(_ s: inout ScheduleSession, _ text: String) async {
        let cls = try? await d.interp.classifySelfText(ScheduleSelfTextContext(
            contactName: s.contactName, text: text, draft: s.draft, slots: s.slots,
            topic: s.topic, durationMin: s.durationMin, format: s.format, now: Date(), timezone: tz))
        if cls == nil {
            await prompt(&s, "I couldn't tell whether that was an instruction or the message text. Say 'edit' first if it's the message you want sent, or tell me what to change.")
            return
        }
        let dec = ScheduleEngine.applySelfText(&s, text, cls, Date())
        await executeSelfDecision(&s, dec)
    }

    private func applyInstruction(_ s: inout ScheduleSession, _ cls: ScheduleSelfTextClass?) async {
        guard let cls = cls else { save(s); return }
        var changed: [String] = []
        if !cls.window.isEmpty { changed.append("window → " + cls.window) }
        if cls.durationMin > 0 { changed.append("duration → \(cls.durationMin) min") }
        if !cls.format.isEmpty { changed.append("format → " + cls.format) }
        if !cls.toneNote.isEmpty { changed.append("tone → " + cls.toneNote) }
        let header = "Got it — " + changed.joined(separator: ", ") + "."
        if cls.needsRecompute() { await resurfaceOptions(&s, header); return }
        s.draft = await redraft(&s)
        s.state = .slotsProposed
        await prompt(&s, header + "\n\nFree options:\n" + ScheduleFmt.slotList(s.slots, tz) + "\n\nDraft to send:\n———\n\(s.draft)\n———\n\n'propose' to send it · 'yes N' to book directly · 'edit' · 'leave it'")
    }

    // MARK: - Booking

    private func finalizeBooking(_ s: inout ScheduleSession, _ directIndex: Int) async {
        let explicit = directIndex >= 1 && directIndex <= s.slots.count
        var fresh: ScheduleInterpretation? = nil
        if s.surfaced != nil && !explicit {
            let rc = ScheduleReplyContext(contactName: s.contactName, slots: s.slots, draft: s.sentDraftOrDraft(),
                                          thread: await threadSince(s.contactJID, s.proposedAt), now: Date(), timezone: tz)
            do { fresh = try await d.interp.interpretReply(rc) }
            catch { await prompt(&s, "Couldn't re-read the thread before booking — not booking. Say 'yes' again to retry."); return }
        }
        guard let target = bookingTarget(&s, fresh, directIndex, explicit) else {
            let dec = ScheduleEngine.decideBooking(&s, fresh, true, Date())
            await surfaceBookingDecision(&s, dec); return
        }
        let free: Bool
        do { free = try await d.cal.verifyFree(start: target.start, end: target.end) }
        catch { await prompt(&s, "Calendar check failed: \(error)"); return }

        let dec: ScheduleDecision
        if explicit {
            if !(target.start > Date()) { dec = ScheduleDecision(.slotPast, index: directIndex, reason: "target_passed") }
            else if free { dec = ScheduleDecision(.book) }
            else { dec = ScheduleDecision(.slotTaken, reply: "That slot got taken on your calendar since I proposed it. Want fresh options?") }
        } else {
            dec = ScheduleEngine.decideBooking(&s, fresh, free, Date())
        }
        if dec.action != .book { await surfaceBookingDecision(&s, dec); return }
        await bookSlot(&s, ScheduleSlot(start: target.start, end: target.end), target.desc)
    }

    private func bookingTarget(_ s: inout ScheduleSession, _ fresh: ScheduleInterpretation?, _ directIndex: Int, _ explicit: Bool) -> (start: Date, end: Date, desc: String)? {
        let dur = TimeInterval((s.durationMin == 0 ? 30 : s.durationMin) * 60)
        if explicit { let sl = s.slots[directIndex - 1]; return (sl.start, sl.end, "Picked explicitly by the user.") }
        guard let surf = s.surfaced else { return nil }
        if fresh == nil || !fresh!.sameOutcome(surf) { return nil }
        switch surf.intent {
        case .accept:
            if surf.slotIndex >= 1 && surf.slotIndex <= s.slots.count { let sl = s.slots[surf.slotIndex - 1]; return (sl.start, sl.end, "\(s.contactName) accepted option \(surf.slotIndex).") }
        case .deference:
            if s.pickedIndex >= 1 && s.pickedIndex <= s.slots.count { let sl = s.slots[s.pickedIndex - 1]; return (sl.start, sl.end, "\(s.contactName) left the choice to the user; Alfred proposed option \(s.pickedIndex) and the user confirmed.") }
        case .counter:
            if let t = ScheduleInterpreter.parseRFC3339(surf.counterTime) { return (t, t.addingTimeInterval(dur), "\(s.contactName) proposed this time.") }
        default: break
        }
        return nil
    }

    private func bookSlot(_ s: inout ScheduleSession, _ slot: ScheduleSlot, _ desc: String) async {
        var summary = s.contactName
        if !s.topic.isEmpty { summary += " — " + s.topic }
        let withMeet = s.format != "in-person" && s.format != "call"
        let booked: (eventID: String, htmlLink: String, meetLink: String?)
        do { booked = try await d.cal.book(summary: summary, description: "Scheduled via Alfred. " + desc, start: slot.start, end: slot.end, withMeet: withMeet) }
        catch { await prompt(&s, "Couldn't create the event: \(error)"); return }
        s.bookedEventID = booked.eventID; s.bookedSlot = slot
        if !s.oldEventID.isEmpty { try? await d.cal.cancel(eventID: s.oldEventID) }

        var confirm = "sounds good — \(ScheduleFmt.slotShort(slot, tz)) it is."
        if let meet = booked.meetLink, !meet.isEmpty { confirm += " here's the meet link: \(meet) — it's on the invite too. look forward!" }
        else if !booked.htmlLink.isEmpty { confirm += " here's the calendar invite: \(booked.htmlLink) — click to add it. look forward!" }
        else { confirm += " look forward!" }
        if s.surfaced != nil {
            let (ok, _) = await d.sender.sendTo(jid: s.contactJID, text: confirm)
            if !ok {
                s.state = .closed; save(s)
                await sendSelfPlain("Event booked (\(ScheduleFmt.slotShort(slot, tz))), but the confirmation to \(s.contactName) failed to send — you may want to confirm with them yourself.")
                return
            }
        }
        s.state = .closed; save(s)
        var done = "Booked: \(ScheduleFmt.slotShort(slot, tz)) with \(s.contactName)."
        if let meet = booked.meetLink, !meet.isEmpty { done += "\nMeet: " + meet }
        if !booked.htmlLink.isEmpty { done += "\nCalendar: " + booked.htmlLink }
        await sendSelfPlain(done)
    }

    private func surfaceBookingDecision(_ s: inout ScheduleSession, _ dec: ScheduleDecision) async {
        switch dec.action {
        case .surfaceChange:
            var text = "Hold on — the thread moved since I pinged you:\n" + renderInterp(s, dec.interp)
            if !dec.reply.isEmpty && dec.interp == nil { text = dec.reply }
            text += "\n\n'yes' if that's right · 'yes N' to lock option N anyway · 'leave it'"
            await prompt(&s, text)
        case .slotTaken:
            await prompt(&s, dec.reply)
        case .slotPast:
            await resurfaceOptions(&s, pastSlotHeader(s, dec))
        default:
            await prompt(&s, dec.reply.isEmpty ? "Something didn't line up — take a look at the thread and tell me what to do." : dec.reply)
        }
    }

    private func pastSlotHeader(_ s: ScheduleSession, _ dec: ScheduleDecision) -> String {
        switch dec.reason {
        case "accepted_slot_passed", "held_slot_passed":
            if dec.index >= 1 && dec.index <= s.slots.count { return "\(s.contactName) picked *\(ScheduleFmt.slotShort(s.slots[dec.index - 1], tz))* — but that's already been and gone. Not booking it. Fresh options:" }
            return "\(s.contactName) picked a slot that's already passed. Not booking it. Fresh options:"
        case "all_slots_passed": return "\(s.contactName) left it to me to pick, but every option I offered has already passed. Fresh options:"
        case "target_passed": return "That time has already passed — not booking it. Fresh options:"
        default: return "Those options have expired. Fresh options:"
        }
    }

    private func renderInterp(_ s: ScheduleSession, _ interp: ScheduleInterpretation?) -> String {
        guard let interp = interp else { return "(couldn't read the thread)" }
        func slot(_ i: Int) -> String { (i >= 1 && i <= s.slots.count) ? ScheduleFmt.slotShort(s.slots[i - 1], tz) : "" }
        var b = ""
        switch interp.intent {
        case .accept: b = interp.slotIndex >= 1 ? "\(s.contactName) is good with *\(slot(interp.slotIndex))*." : "\(s.contactName) agreed, but I'm not sure to which option."
        case .counter: if let t = ScheduleInterpreter.parseRFC3339(interp.counterTime) { b = "\(s.contactName) proposed *\(ScheduleFmt.slotShort(ScheduleSlot(start: t, end: t), tz))* instead." } else { b = "\(s.contactName) proposed a different time." }
        case .reject: b = "\(s.contactName) can't make any of these."
        case .ambiguous: b = "\(s.contactName) replied but it's not a clear yes — take a look at the chat."
        case .unrelated: b = "\(s.contactName) messaged, but not about the meeting."
        case .softYes: b = interp.slotIndex >= 1 ? "\(s.contactName) is leaning *\(slot(interp.slotIndex))* — but it's a soft yes, not a commitment. I haven't booked it, and I'm still watching." : "\(s.contactName) hedged — nothing booked."
        case .deference: b = s.pickedIndex >= 1 ? "\(s.contactName) left the pick to me — I'd take *\(slot(s.pickedIndex))*." : "\(s.contactName) left the pick to me."
        case .scopeChange: b = "\(s.contactName) wants to change the shape of this."
        case .directive: if let t = ScheduleInterpreter.parseRFC3339(interp.counterTime) { b = "\(s.contactName) told you to make it *\(ScheduleFmt.slotShort(ScheduleSlot(start: t, end: t), tz))*." } else { b = "\(s.contactName) named a time." }
        case .notScheduling: b = "\(s.contactName) isn't scheduling this here."
        }
        if !interp.sideNote.isEmpty { b += "\nAlso: " + interp.sideNote }
        return b
    }

    // MARK: - Watcher entry point

    func onContactMessage(jid: String, isFromMe: Bool, text: String, ts: Date) async {
        guard var s = openSessionFor(jid), s.state == .awaitingReply || s.state == .replySurfaced || s.state == .held else { return }
        if isFromMe && text.trimmingCharacters(in: .whitespaces) == s.sentDraftOrDraft().trimmingCharacters(in: .whitespaces) { return }

        let rc = ScheduleReplyContext(contactName: s.contactName, slots: s.slots, draft: s.sentDraftOrDraft(),
                                      thread: await threadSince(s.contactJID, s.proposedAt), now: Date(), timezone: tz)
        if isFromMe {
            let finalized = (try? await d.interp.interpretOwnMessage(rc)) ?? false
            let dec = ScheduleEngine.handleOwnMessage(&s, finalized, Date())
            if dec.action == .standDown { save(s) }
            return
        }
        let interp: ScheduleInterpretation
        do { interp = try await d.interp.interpretReply(rc) }
        catch { await prompt(&s, "\(s.contactName) replied but I couldn't read the thread — take a look."); return }

        if (s.state == .replySurfaced || s.state == .held) && interp.sameOutcome(s.surfaced) { return }

        let dec = ScheduleEngine.handleCounterpartReply(&s, interp, ts, Date())
        switch dec.action {
        case .none: save(s)
        case .surfaceReply:
            var text = renderInterp(s, dec.interp)
            switch dec.interp?.intent {
            case .accept?: text += "\n\n'yes' to book · 'edit' · 'leave it'"
            case .reject?: text += "\n\n'leave it' to drop, or '@schedule \(firstWord(s.contactName).lowercased()) next week' to try a new window"
            default: text += "\n\n'yes' if it's actually settled · 'edit' · 'leave it'"
            }
            await prompt(&s, text)
        case .verifyCounter: await handleCounterVerification(&s, dec.interp)
        case .hold:
            await prompt(&s, renderInterp(s, dec.interp) + "\n\n'yes' to lock it anyway · 'leave it' to drop · otherwise I'll wait for them.")
        case .surfacePick: await handleDeferencePick(&s, dec)
        case .scopeChange: await handleScopeChange(&s, dec.interp)
        case .notScheduling: await handleNotScheduling(&s, dec)
        case .slotPast: await resurfaceOptions(&s, pastSlotHeader(s, dec))
        default: save(s)
        }
    }

    private func handleDeferencePick(_ s: inout ScheduleSession, _ dec: ScheduleDecision) async {
        guard dec.index >= 1 && dec.index <= s.slots.count else {
            await prompt(&s, "\(s.contactName) left the pick to me but I've lost track of the options — say 'yes N' to lock one."); return
        }
        let sl = s.slots[dec.index - 1]
        let free: Bool
        do { free = try await d.cal.verifyFree(start: sl.start, end: sl.end) } catch { await prompt(&s, "Calendar check failed while picking for you: \(error)"); return }
        if !free { await prompt(&s, "\(s.contactName) left the pick to me, but *\(ScheduleFmt.slotShort(sl, tz))* just got taken. Say 'yes N' for another, or 'leave it'."); return }
        var text = "\(s.contactName) left the pick to me — I'd take *\(ScheduleFmt.slotShort(sl, tz))* (\(dec.reason))."
        if let sn = dec.interp?.sideNote, !sn.isEmpty { text += "\nAlso: " + sn }
        text += "\n\n'yes' to book it and confirm to them · 'yes N' for another · 'leave it'"
        await prompt(&s, text)
    }

    private func handleScopeChange(_ s: inout ScheduleSession, _ interp: ScheduleInterpretation?) async {
        guard let interp = interp else { save(s); return }
        var parts: [String] = []
        if interp.newDurationMin > 0 { parts.append("\(interp.newDurationMin) min") }
        if !interp.newFormat.isEmpty { parts.append(interp.newFormat) }
        var header = "\(s.contactName) wants to change the shape: now \(parts.isEmpty ? "a different setup" : parts.joined(separator: ", ")). Recomputed for that:"
        var extra: [String] = []
        let p = interp.requestedPlatform.lowercased()
        if !p.isEmpty && p != "meet" && p != "google meet" {
            extra.append("⚠️ They asked for \(interp.requestedPlatform). I can only create Google Meet links. Either 'propose' and I'll send a Meet link instead, or paste me the \(interp.requestedPlatform) link.")
        }
        if interp.needsVenue { extra.append("📍 Nobody's named a place yet — say 'edit' to write the message with one in.") }
        if !interp.sideNote.isEmpty { extra.append("Also: " + interp.sideNote) }
        if !extra.isEmpty { header += "\n\n" + extra.joined(separator: "\n") }
        await resurfaceOptions(&s, header)
    }

    private func handleNotScheduling(_ s: inout ScheduleSession, _ dec: ScheduleDecision) async {
        save(s)
        if dec.reason == "wrong_person" {
            await sendSelfPlain("🛑 STOP — \(s.contactName) doesn't know who you are (\"who is this?\" / wrong number). You may have messaged the wrong person. I've dropped this session and sent nothing further. Check the chat.")
            return
        }
        let reason = dec.interp?.sideNote.isEmpty == false ? dec.interp!.sideNote : "they're not settling this over WhatsApp"
        await sendSelfPlain("Dropped the \(s.contactName) session — \(reason).")
    }

    private func handleCounterVerification(_ s: inout ScheduleSession, _ interp: ScheduleInterpretation?) async {
        guard let interp = interp, let t = ScheduleInterpreter.parseRFC3339(interp.counterTime) else {
            await prompt(&s, "\(s.contactName) proposed a different time but I couldn't pin it down — take a look at the chat."); return
        }
        let dur = TimeInterval((s.durationMin == 0 ? 30 : s.durationMin) * 60)
        let free: Bool
        do { free = try await d.cal.verifyFree(start: t, end: t.addingTimeInterval(dur)) } catch { await prompt(&s, "Calendar check failed while verifying their proposal: \(error)"); return }
        let when = ScheduleFmt.slotShort(ScheduleSlot(start: t, end: t), tz)
        if free { await prompt(&s, "\(s.contactName) proposed *\(when)* — that's free on your side.\n\n'yes' to book it · 'edit' · 'leave it'") }
        else { await prompt(&s, "\(s.contactName) proposed *\(when)* but you're busy then. Reply with what to do — 'edit' to counter, or 'leave it'.") }
    }

    func onContactMedia(jid: String, isFromMe: Bool, kind: ScheduleMediaKind, ts: Date) async {
        if isFromMe { return }
        guard var s = openSessionFor(jid) else { return }
        let dec = ScheduleEngine.handleMediaMessage(&s, kind, ts)
        if dec.action != .surfaceMedia { save(s); return }
        await prompt(&s, "\(s.contactName) replied with a \(dec.reason) — I can't read that. Tell me what they said and I'll take it from there, or say 'leave it'.")
    }

    func runExpirySweep(_ now: Date) {
        for var s in allOpen() { if ScheduleEngine.checkExpiry(&s, now).action == .expire { save(s) } }
    }

    private func firstWord(_ s: String) -> String { s.split(separator: " ").first.map(String.init) ?? s }
}

extension ScheduleSession {
    func sentDraftOrDraft() -> String { sentDraft.isEmpty ? draft : sentDraft }
}
