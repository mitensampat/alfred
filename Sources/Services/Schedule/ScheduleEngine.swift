import Foundation

/// The pure scheduling state machine — faithful port of Commit's schedule/engine.go.
/// It never performs side effects: it mutates the session in place (state transitions) and
/// returns a `ScheduleDecision` telling the wiring what to do next. The consent contract lives
/// here — a soft yes never books, out-of-scope self-chat text never moves a session, and a
/// changed thread surfaces the change instead of booking a stale answer.
enum ScheduleEngine {

    // MARK: - Consent parsing

    private struct ConsentCmd {
        var kind: String            // "propose" | "yes" | "yes_silent" | "edit" | "leave_it"
        var indices: [Int] = []
        var firstIndex: Int { indices.first ?? 0 }
    }

    /// Recognizes the consent vocabulary. Anything else is not consent.
    private static func parseConsent(_ text: String) -> (ConsentCmd, Bool) {
        var t = text.lowercased().trimmingCharacters(in: .whitespaces)
        if t.hasSuffix(".") { t.removeLast() }
        let fields = t.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let head = fields.first else { return (ConsentCmd(kind: ""), false) }
        switch head {
        case "propose":
            var cmd = ConsentCmd(kind: "propose")
            for f in fields.dropFirst() {
                guard let n = Int(f) else { return (ConsentCmd(kind: ""), false) }
                cmd.indices.append(n)
            }
            return (cmd, true)
        case "yes":
            if fields.count == 2 && fields[1] == "silent" { return (ConsentCmd(kind: "yes_silent"), true) }
            if fields.count == 2 {
                if let n = Int(fields[1]) { return (ConsentCmd(kind: "yes", indices: [n]), true) }
                return (ConsentCmd(kind: ""), false)
            }
            if fields.count > 2 { return (ConsentCmd(kind: ""), false) }
            return (ConsentCmd(kind: "yes"), true)
        case "edit":
            if fields.count == 1 { return (ConsentCmd(kind: "edit"), true) }
            return (ConsentCmd(kind: ""), false)
        case "leave":
            if fields.count == 2 && fields[1] == "it" { return (ConsentCmd(kind: "leave_it"), true) }
            return (ConsentCmd(kind: ""), false)
        default:
            return (ConsentCmd(kind: ""), false)
        }
    }

    /// Whether a self-chat message may carry consent semantics: the next message after our prompt,
    /// within the consent window of it, or carrying the @schedule prefix.
    private static func scoped(_ s: ScheduleSession, _ input: ScheduleSelfChatInput) -> Bool {
        if input.forceScoped || input.isNextAfterPrompt { return true }
        guard let last = s.lastPromptAt else { return false }
        return input.now.timeIntervalSince(last) <= ScheduleConst.consentWindow && input.now > last
    }

    // MARK: - Self-chat

    /// Process a self-chat message against an open session. `.none` means "personal note — pretend
    /// we never saw it".
    static func handleSelfChat(_ s: inout ScheduleSession, _ input: ScheduleSelfChatInput) -> ScheduleDecision {
        if s.state == .closed { return ScheduleDecision(.none) }
        // The self-chat doubles as a notepad. Out-of-scope text — including a stray "yes" — must
        // never move a session.
        if !scoped(s, input) { return ScheduleDecision(.none) }

        let text = input.text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Contact disambiguation: a bare number or letter.
        if s.state == .resolving {
            let n = parsePick(text)
            if n > 0 { touch(&s, input.now); return ScheduleDecision(.pickContact, index: n) }
            return ScheduleDecision(.ask, reply: "Reply with the number of the person you meant, or 'leave it' to drop this.")
        }

        let (cmd, isConsent) = parseConsent(text)
        if !isConsent {
            // After an explicit "edit" we asked for the draft text, so the next message is
            // unambiguously the draft — no classification needed.
            if s.awaitingDraftEdit {
                s.draft = text
                s.awaitingDraftEdit = false
                touch(&s, input.now)
                return ScheduleDecision(.replaceDraft, reply: "Draft updated. It'll go out on your next 'propose' or 'yes'.", text: text)
            }
            // Unprompted free text over a pending draft is the foot-gun. Hand it to the classifier;
            // the engine arms nothing on its own.
            if s.state == .slotsProposed || s.state == .replySurfaced || s.state == .held {
                touch(&s, input.now)
                return ScheduleDecision(.classifyText, text: text)
            }
            return ScheduleDecision(.none)
        }

        switch cmd.kind {
        case "leave_it":
            close(&s, input.now, "leave_it")
            return ScheduleDecision(.close, reply: "Left it. Session closed.", reason: "leave_it")

        case "edit":
            s.awaitingDraftEdit = true
            touch(&s, input.now)
            return ScheduleDecision(.editPrompt, reply: "Send me the new message text and I'll use that instead.")

        case "propose":
            if s.state != .slotsProposed && s.state != .awaitingReply && s.state != .replySurfaced {
                return ScheduleDecision(.ask, reply: "Nothing to propose yet.")
            }
            if s.slots.isEmpty { return ScheduleDecision(.ask, reply: "No slots on the table yet.") }
            // Idempotent propose.
            if let pAt = s.proposedAt, input.now.timeIntervalSince(pAt) < ScheduleConst.proposeDedupWindow,
               sameInts(cmd.indices, s.proposedSlots) {
                return ScheduleDecision(.alreadyProposed, reply: "Already sent that a moment ago — not sending it twice.")
            }
            for idx in cmd.indices where idx < 1 || idx > s.slots.count {
                return ScheduleDecision(.ask, reply: "I only have \(s.slots.count) slots — pick from those.")
            }
            s.proposedAt = input.now
            s.proposedSlots = cmd.indices
            s.state = .awaitingReply
            touch(&s, input.now)
            return ScheduleDecision(.propose, indices: cmd.indices)

        case "yes":
            switch s.state {
            case .confirmCancel:
                touch(&s, input.now)
                return ScheduleDecision(.cancelMeeting)
            case .replySurfaced:
                touch(&s, input.now)
                // Wiring re-reads + re-verifies before booking; DecideBooking makes the final call.
                return ScheduleDecision(.requestBooking, index: cmd.firstIndex)
            case .held:
                // The user saw "this is a soft yes" and said book it anyway — their call.
                var idx = cmd.firstIndex
                if idx == 0, let surf = s.surfaced { idx = surf.slotIndex }
                if idx < 1 || idx > s.slots.count { return ScheduleDecision(.ask, reply: "Which slot? Reply 'yes N'.") }
                touch(&s, input.now)
                return ScheduleDecision(.requestBooking, index: idx)
            case .slotsProposed:
                // Direct booking only with an explicit slot number; a bare "yes" over three options
                // is not consent to any particular one.
                let idx = cmd.firstIndex
                if idx > 0 {
                    if idx > s.slots.count { return ScheduleDecision(.ask, reply: "I only have \(s.slots.count) slots — pick from those.") }
                    touch(&s, input.now)
                    return ScheduleDecision(.requestBooking, index: idx)
                }
                return ScheduleDecision(.ask, reply: "Which slot? Reply 'yes 2' to book one directly, or 'propose' to send the options to \(s.contactName) first.")
            case .awaitingReply:
                return ScheduleDecision(.ask, reply: "Still waiting on \(s.contactName) — I'll ping you here when they reply.")
            default:
                return ScheduleDecision(.none)
            }

        case "yes_silent":
            if s.state == .confirmCancel { touch(&s, input.now); return ScheduleDecision(.cancelSilent) }
            return ScheduleDecision(.ask, reply: "'yes silent' only applies to a cancel.")

        default:
            return ScheduleDecision(.none)
        }
    }

    // MARK: - Counterpart thread

    private static func watching(_ s: ScheduleSession) -> Bool {
        s.state == .awaitingReply || s.state == .replySurfaced || s.state == .held
    }

    private static func slotPassed(_ sl: ScheduleSlot, _ now: Date) -> Bool { !(sl.start > now) }

    /// Choose on the user's behalf when the counterpart defers ("you pick"). Adjacent slots (butt
    /// against an existing meeting, keeping big free blocks intact) win outright; else the earliest.
    /// Past slots are never candidates. Returns a 1-based index + one-clause reason, or 0.
    static func pickDeferredSlot(_ slots: [ScheduleSlot], _ subset: [Int], _ now: Date) -> (Int, String) {
        var allowed = Set<Int>()
        for i in subset where i >= 1 && i <= slots.count { allowed.insert(i) }
        var best = 0, bestAdj = false
        for (i, sl) in slots.enumerated() {
            let idx = i + 1
            if !allowed.isEmpty && !allowed.contains(idx) { continue }
            if slotPassed(sl, now) { continue }
            if best == 0 {
                best = idx; bestAdj = sl.adjacent
            } else if sl.adjacent && !bestAdj {
                best = idx; bestAdj = true
            } else if sl.adjacent == bestAdj && sl.start < slots[best - 1].start {
                best = idx
            }
        }
        if best == 0 { return (0, "") }
        return bestAdj ? (best, "it sits right next to what you already have that day")
                       : (best, "it's the earliest of the ones on the table")
    }

    /// Process a fresh interpretation of the counterpart thread while the watcher is active.
    static func handleCounterpartReply(_ s: inout ScheduleSession, _ interp: ScheduleInterpretation?,
                                       _ msgTime: Date, _ now: Date) -> ScheduleDecision {
        guard watching(s), let interp = interp else { return ScheduleDecision(.none) }

        switch interp.intent {
        case .unrelated:
            return ScheduleDecision(.none)   // keep watching; don't extend the session over small talk

        case .notScheduling:
            let reason = interp.wrongPerson ? "wrong_person" : "not_scheduling"
            s.surfaced = interp
            s.surfacedAtMsgTime = msgTime
            close(&s, now, reason)
            return ScheduleDecision(.notScheduling, interp: interp, reason: reason)

        case .softYes:
            // SAFETY-CRITICAL: a hedge is not consent. Nothing books off this.
            if interp.slotIndex < 1 || interp.slotIndex > s.slots.count {
                return surfaceReply(&s, ScheduleInterpretation(intent: .ambiguous, sideNote: interp.sideNote, confidence: "low"), msgTime, now)
            }
            if slotPassed(s.slots[interp.slotIndex - 1], now) {
                return ScheduleDecision(.slotPast, index: interp.slotIndex, interp: interp, reason: "held_slot_passed")
            }
            s.surfaced = interp
            s.surfacedAtMsgTime = msgTime
            s.state = .held
            touch(&s, now)
            return ScheduleDecision(.hold, index: interp.slotIndex, interp: interp)

        case .deference:
            let (idx, why) = pickDeferredSlot(s.slots, interp.deferSlots, now)
            if idx == 0 { return ScheduleDecision(.slotPast, interp: interp, reason: "all_slots_passed") }
            s.surfaced = interp
            s.surfacedAtMsgTime = msgTime
            s.pickedIndex = idx
            s.state = .replySurfaced
            touch(&s, now)
            return ScheduleDecision(.surfacePick, index: idx, interp: interp, reason: why)

        case .scopeChange:
            if interp.newDurationMin > 0 { s.durationMin = interp.newDurationMin }
            if !interp.newFormat.isEmpty { s.format = interp.newFormat }
            s.surfaced = interp
            s.surfacedAtMsgTime = msgTime
            s.state = .slotsProposed
            touch(&s, now)
            return ScheduleDecision(.scopeChange, interp: interp)

        case .directive:
            if interp.counterTime.isEmpty {
                return surfaceReply(&s, ScheduleInterpretation(intent: .ambiguous, sideNote: interp.sideNote, confidence: "low"), msgTime, now)
            }
            s.surfaced = interp
            s.surfacedAtMsgTime = msgTime
            s.state = .replySurfaced
            touch(&s, now)
            return ScheduleDecision(.verifyCounter, interp: interp)

        case .counter:
            if interp.counterTime.isEmpty {
                return surfaceReply(&s, ScheduleInterpretation(intent: .ambiguous, sideNote: interp.sideNote, confidence: interp.confidence), msgTime, now)
            }
            s.surfaced = interp
            s.surfacedAtMsgTime = msgTime
            s.state = .replySurfaced
            touch(&s, now)
            return ScheduleDecision(.verifyCounter, interp: interp)

        case .accept:
            if interp.slotIndex < 1 || interp.slotIndex > s.slots.count {
                return surfaceReply(&s, ScheduleInterpretation(intent: .ambiguous, sideNote: interp.sideNote, confidence: "low"), msgTime, now)
            }
            if slotPassed(s.slots[interp.slotIndex - 1], now) {
                return ScheduleDecision(.slotPast, index: interp.slotIndex, interp: interp, reason: "accepted_slot_passed")
            }
            return surfaceReply(&s, interp, msgTime, now)

        case .reject, .ambiguous:
            return surfaceReply(&s, interp, msgTime, now)
        }
    }

    private static func surfaceReply(_ s: inout ScheduleSession, _ interp: ScheduleInterpretation,
                                     _ msgTime: Date, _ now: Date) -> ScheduleDecision {
        s.surfaced = interp
        s.surfacedAtMsgTime = msgTime
        s.state = .replySurfaced
        touch(&s, now)
        return ScheduleDecision(.surfaceReply, interp: interp)
    }

    /// The user themselves texted in the counterpart chat mid-session. If they finalized a time on
    /// their own, stand down silently.
    static func handleOwnMessage(_ s: inout ScheduleSession, _ finalizedManually: Bool, _ now: Date) -> ScheduleDecision {
        guard watching(s), finalizedManually else { return ScheduleDecision(.none) }
        close(&s, now, "manual_resolution")
        return ScheduleDecision(.standDown)
    }

    /// The final call after the user's "yes": `fresh` is a just-computed interpretation of the
    /// LATEST thread (nil if there was never a proposal round), `slotFree` the re-verified check.
    static func decideBooking(_ s: inout ScheduleSession, _ fresh: ScheduleInterpretation?,
                              _ slotFree: Bool, _ now: Date) -> ScheduleDecision {
        if s.state == .closed { return ScheduleDecision(.none) }

        // Correction race: booking on a stale answer is the worst failure — surface the change.
        if let surf = s.surfaced {
            guard let fresh = fresh else {
                return ScheduleDecision(.surfaceChange,
                    reply: "I couldn't re-read the thread to confirm nothing changed — not booking. Take a look and say 'yes' again.",
                    reason: "could_not_reverify")
            }
            if !fresh.sameOutcome(surf) {
                s.surfaced = fresh
                touch(&s, now)
                return ScheduleDecision(.surfaceChange, interp: fresh, reason: "thread_changed")
            }
            // Which readings are a mandate to book once the user said yes? Accept + counter name a
            // time; deference names none but "you pick" is a clear answer the user consented to.
            if fresh.confidence == "low"
                || (fresh.intent != .accept && fresh.intent != .counter && fresh.intent != .deference) {
                return ScheduleDecision(.surfaceChange, interp: fresh, reason: "not_a_clear_yes")
            }
        }

        // A slot fine when proposed may simply have gone by. Booking into the past is never right.
        if let start = targetStart(s), !(start > now) {
            touch(&s, now)
            return ScheduleDecision(.slotPast, reason: "target_passed")
        }

        if !slotFree {
            touch(&s, now)
            return ScheduleDecision(.slotTaken, reply: "That slot got taken on your calendar since I proposed it. Want fresh options?")
        }

        touch(&s, now)
        return ScheduleDecision(.book)
    }

    /// The start time the surfaced outcome would book, so the past-slot guard can run.
    private static func targetStart(_ s: ScheduleSession) -> Date? {
        guard let surf = s.surfaced else { return nil }
        switch surf.intent {
        case .accept, .softYes:
            let i = surf.slotIndex
            if i >= 1 && i <= s.slots.count { return s.slots[i - 1].start }
        case .deference:
            let i = s.pickedIndex
            if i >= 1 && i <= s.slots.count { return s.slots[i - 1].start }
        case .counter, .directive:
            let f = ISO8601DateFormatter()
            if let t = f.date(from: surf.counterTime) { return t }
        default:
            return nil
        }
        return nil
    }

    /// Resolve the user's classified free text. Anything short of a confident "this is a draft"
    /// must never become the outbound message.
    static func applySelfText(_ s: inout ScheduleSession, _ text: String,
                              _ cls: ScheduleSelfTextClass?, _ now: Date) -> ScheduleDecision {
        if s.state == .closed { return ScheduleDecision(.none) }
        // A confident personal note is none of our business — not armed, not asked about.
        if let cls = cls, cls.kind == .note, cls.confidence == "high" {
            return ScheduleDecision(.none, reason: "personal_note")
        }
        // Unclear / unconfident / unclassifiable → ask. Never arm.
        if cls == nil || cls!.confidence != "high" || (cls!.kind != .draft && cls!.kind != .instruction) {
            touch(&s, now)
            return ScheduleDecision(.ask,
                reply: "Not sure if that's a note for me or the message you want sent. Say 'edit' first if it's the message, or tell me what to change.",
                reason: "unclear_self_text")
        }
        let cls2 = cls!
        if cls2.kind == .draft {
            s.draft = text
            s.awaitingDraftEdit = false
            touch(&s, now)
            return ScheduleDecision(.replaceDraft, reply: "Draft updated. It'll go out on your next 'propose' or 'yes'.", text: text)
        }
        // Instruction: act on it.
        if !cls2.window.isEmpty { s.window = cls2.window }
        if cls2.durationMin > 0 { s.durationMin = cls2.durationMin }
        if !cls2.format.isEmpty { s.format = cls2.format }
        if !cls2.toneNote.isEmpty { s.toneNote = cls2.toneNote }
        touch(&s, now)
        return ScheduleDecision(.applyInstruction, text: text, selfClass: cls2)
    }

    /// The counterpart replied with something we can't read. Say so once — five photos must not
    /// produce five nudges.
    static func handleMediaMessage(_ s: inout ScheduleSession, _ kind: ScheduleMediaKind, _ now: Date) -> ScheduleDecision {
        guard s.state == .awaitingReply else { return ScheduleDecision(.none) }
        if let last = s.lastMediaSurfacedAt, now.timeIntervalSince(last) < ScheduleConst.mediaBurstWindow {
            return ScheduleDecision(.none)
        }
        s.lastMediaSurfacedAt = now
        touch(&s, now)
        return ScheduleDecision(.surfaceMedia, reason: kind.rawValue)
    }

    /// Close sessions silent too long.
    static func checkExpiry(_ s: inout ScheduleSession, _ now: Date) -> ScheduleDecision {
        if s.state == .closed { return ScheduleDecision(.none) }
        if let last = s.lastActivity, now.timeIntervalSince(last) > ScheduleConst.sessionExpiry {
            close(&s, now, "expired")
            return ScheduleDecision(.expire)
        }
        return ScheduleDecision(.none)
    }

    /// Record that Alfred just prompted the user — opens the consent window.
    static func markPrompted(_ s: inout ScheduleSession, _ now: Date) {
        s.lastPromptAt = now
        touch(&s, now)
    }

    // MARK: - Helpers

    private static func touch(_ s: inout ScheduleSession, _ now: Date) { s.lastActivity = now }
    private static func close(_ s: inout ScheduleSession, _ now: Date, _ reason: String) {
        s.state = .closed; touch(&s, now)
    }

    private static func parsePick(_ text: String) -> Int {
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        if let n = Int(t), n > 0, n < 100 { return n }
        if t.count == 1, let c = t.unicodeScalars.first, c.value >= 97, c.value <= 122 {
            return Int(c.value - 97) + 1
        }
        return 0
    }

    static func sameInts(_ a: [Int], _ b: [Int]) -> Bool {
        a == b
    }
}
