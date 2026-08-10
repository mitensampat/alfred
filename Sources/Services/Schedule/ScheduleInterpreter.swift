import Foundation

/// One message in the counterpart chat, for interpretation.
struct ScheduleThreadMsg { var fromMe: Bool; var text: String; var time: Date? }

/// Everything the reply interpreter sees.
struct ScheduleReplyContext {
    var contactName: String
    var slots: [ScheduleSlot]      // options offered (1-based in the draft)
    var draft: String              // the message we sent
    var thread: [ScheduleThreadMsg]
    var now: Date
    var timezone: TimeZone
}

/// Everything the self-text classifier sees.
struct ScheduleSelfTextContext {
    var contactName: String
    var text: String
    var draft: String
    var slots: [ScheduleSlot]
    var topic: String
    var durationMin: Int
    var format: String
    var now: Date
    var timezone: TimeZone
}

/// Reads the counterpart thread + the user's self-text with Claude. Faithful port of Commit's
/// schedule/interpreter.go + selftext.go: the eval-tuned prompts plus all the defensive
/// normalization, so any malformed model output degrades to ambiguous/unclear — never to a booking
/// or a silently-armed draft.
final class ScheduleInterpreter {
    private let ai: ClaudeAIService
    private let model: String?

    init(ai: ClaudeAIService, model: String? = nil) { self.ai = ai; self.model = model }

    // MARK: - Reply interpretation

    func interpretReply(_ rc: ScheduleReplyContext) async throws -> ScheduleInterpretation {
        let raw = try await ai.generateText(prompt: Self.buildReplyPrompt(rc), maxTokens: 512, useModel: model)
        guard let data = Self.extractJSON(raw).data(using: .utf8),
              var interp = try? JSONDecoder().decode(ScheduleInterpretation.self, from: data) else {
            return ScheduleInterpretation(intent: .ambiguous, confidence: "low")
        }
        // Defensive normalization — anything malformed degrades to ambiguous/low, never a booking.
        if interp.confidence != "high" { interp.confidence = "low" }
        if interp.slotIndex < 0 || interp.slotIndex > rc.slots.count {
            interp.intent = .ambiguous; interp.slotIndex = 0; interp.confidence = "low"
        }
        // Normalize the timestamp to real RFC3339 (models drop the zone offset); a naive time means
        // the user's timezone. A time we can't pin down is not something to act on.
        if !interp.counterTime.isEmpty {
            if let t = Self.parseFlexibleTime(interp.counterTime, rc.timezone) {
                interp.counterTime = Self.rfc3339(t)
            } else {
                if interp.intent == .counter || interp.intent == .directive {
                    interp.intent = .ambiguous; interp.confidence = "low"
                }
                interp.counterTime = ""
            }
        }
        if interp.intent == .scopeChange && interp.newDurationMin == 0 && interp.newFormat.isEmpty && !interp.needsVenue {
            interp.intent = .ambiguous; interp.confidence = "low"
        }
        if interp.intent == .directive && interp.counterTime.isEmpty {
            interp.intent = .ambiguous; interp.confidence = "low"
        }
        // A "counter"/"directive" naming a time we ALREADY offered is an acceptance of that option.
        if interp.intent == .counter || interp.intent == .directive, !interp.counterTime.isEmpty,
           let t = Self.parseRFC3339(interp.counterTime) {
            for (i, sl) in rc.slots.enumerated() where sl.start == t {
                interp.intent = .accept; interp.slotIndex = i + 1; interp.counterTime = ""; break
            }
        }
        // Per-intent field hygiene: stray fields would make two equal readings look different to
        // sameOutcome and wedge the correction-race gate.
        switch interp.intent {
        case .accept, .softYes:
            interp.counterTime = ""
        case .counter, .directive:
            interp.slotIndex = 0
        case .deference:
            interp.slotIndex = 0; interp.counterTime = ""
            interp.deferSlots = interp.deferSlots.filter { $0 >= 1 && $0 <= rc.slots.count }.sorted()
        case .scopeChange:
            interp.slotIndex = 0; interp.counterTime = ""
        default:
            interp.slotIndex = 0; interp.counterTime = ""
        }
        if interp.intent != .scopeChange {
            interp.newDurationMin = 0; interp.newFormat = ""; interp.needsVenue = false; interp.requestedPlatform = ""
        }
        if interp.intent != .notScheduling { interp.wrongPerson = false }
        if interp.intent != .deference { interp.deferSlots = [] }
        return interp
    }

    func interpretOwnMessage(_ rc: ScheduleReplyContext) async throws -> Bool {
        let raw = try await ai.generateText(prompt: Self.buildOwnMessagePrompt(rc), maxTokens: 256, useModel: model)
        guard let data = Self.extractJSON(raw).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return (obj["finalized"] as? Bool) ?? false
    }

    // MARK: - Self-text classification

    func classifySelfText(_ sc: ScheduleSelfTextContext) async throws -> ScheduleSelfTextClass {
        let raw = try await ai.generateText(prompt: Self.buildSelfTextPrompt(sc), maxTokens: 512, useModel: model)
        guard let data = Self.extractJSON(raw).data(using: .utf8),
              var out = try? JSONDecoder().decode(ScheduleSelfTextClass.self, from: data) else {
            return ScheduleSelfTextClass(kind: .unclear, confidence: "low")
        }
        // Every failure mode lands on "unclear" (which asks), never "draft" (which arms).
        if out.confidence != "high" { out.confidence = "low" }
        if out.kind == .instruction && !out.needsRecompute() && out.toneNote.isEmpty {
            out.kind = .unclear; out.confidence = "low"
        }
        if out.kind != .instruction { out.window = ""; out.durationMin = 0; out.format = ""; out.toneNote = "" }
        if out.durationMin < 0 || out.durationMin > 24 * 60 { out.durationMin = 0 }
        if !["call", "video", "in-person", ""].contains(out.format) { out.format = "" }
        return out
    }

    // MARK: - JSON + time helpers

    /// Pull the first JSON object out of a response that may have prose/fences around it.
    static func extractJSON(_ s0: String) -> String {
        var s = s0.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: "```") {
            s = String(s[r.upperBound...])
            if s.hasPrefix("json") { s = String(s.dropFirst(4)) }
            if let e = s.range(of: "```") { s = String(s[..<e.lowerBound]) }
        }
        guard let start = s.firstIndex(of: "{") else { return s }
        var depth = 0
        var i = start
        while i < s.endIndex {
            if s[i] == "{" { depth += 1 }
            else if s[i] == "}" { depth -= 1; if depth == 0 { return String(s[start...i]) } }
            i = s.index(after: i)
        }
        return String(s[start...])
    }

    static func parseRFC3339(_ s: String) -> Date? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
    static func rfc3339(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }
    /// RFC3339 preferred; a zone-less timestamp means the user's timezone; else unparseable.
    static func parseFlexibleTime(_ s0: String, _ tz: TimeZone) -> Date? {
        let s = s0.trimmingCharacters(in: .whitespaces)
        if let t = parseRFC3339(s) { return t }
        for pattern in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = tz; f.dateFormat = pattern
            if let t = f.date(from: s) { return t }
        }
        return nil
    }

    private static func df(_ pattern: String, _ tz: TimeZone) -> DateFormatter {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = tz; f.dateFormat = pattern
        return f
    }
    private static func formatSlotLine(_ i: Int, _ s: ScheduleSlot, _ tz: TimeZone) -> String {
        let day = df("EEE MMM d", tz), clock = df("h:mm a", tz)
        return "\(i + 1). \(day.string(from: s.start)), \(clock.string(from: s.start)) – \(clock.string(from: s.end))"
    }

    // MARK: - Prompts (verbatim from Commit's eval-tuned interpreter)

    static func buildReplyPrompt(_ rc: ScheduleReplyContext) -> String {
        let tz = rc.timezone
        var sb = """
        You are the reply-interpretation module of a careful scheduling assistant. The user (ME) sent a message to a contact (THEM) proposing meeting times. Your ONLY job: classify the CURRENT scheduling position of THEM from the thread below.

        Return STRICT JSON, nothing else:
        {"intent": "accept|soft_yes|deference|reject|counter_propose|scope_change|directive|not_scheduling|ambiguous|unrelated", "slot_index": 0, "counter_time": "", "side_note": "", "confidence": "high|low", "defer_slots": [], "new_duration_min": 0, "new_format": "", "needs_venue": false, "requested_platform": "", "wrong_person": false}

        Governing principle: never guess what they meant, but don't be fussy about what's obvious.

        Rules, in priority order:
        1. The LATEST position wins. If they accepted and then changed their mind ("actually Tuesday is bad"), report the later position, not the acceptance.

        2. "accept": they FIRMLY agreed to one of the OFFERED OPTIONS, with no hedge. slot_index = which one (1-based). Informal acceptance counts ("👍", "works for me", "the second one", "tue is good") as long as the referent is unmistakable. If exactly ONE option was offered, a plain agreement means slot_index 1.

        3. "soft_yes": they pointed at ONE specific option but HEDGED — the commitment isn't firm yet. slot_index = the option they pointed at. THIS IS NOT ACCEPT — the difference is the hedge, not the topic. Booking a soft yes is a serious error: they have not committed.
           Hedge markers, ANY of which forces soft_yes over accept: "should work", "would work", "could work", "might work", "probably", "likely", "I think", "pretty sure", "tentatively", "pencil me in", "provisionally", "for now", "let me confirm", "I'll confirm", "need to check with X first", "don't lock it yet", "subject to X", "as long as X", "if nothing comes up".
           "wed works" is ACCEPT (firm). "wed should work" is SOFT_YES. "wed works, let me just confirm tomorrow" is SOFT_YES. Read the single word precisely.
           A hedge that points at NO single option ("maybe", "probably tue or thu", "let me check and get back") is "ambiguous", NOT soft_yes.

        4. "deference": they explicitly hand the choice to ME, or say every option works ("you pick", "any of these work", "whatever suits you", "I'm flexible", "dealer's choice"). Set defer_slots to the 1-based options they limited it to ("Tue or Wed both fine, you choose" → [1,2]); leave empty when any offered option is fine.
           "sounds good" / "ok" / "👍" over MULTIPLE options is NOT deference — use "ambiguous".

        5. THE COUNT OF OFFERED OPTIONS DECIDES WHAT "sounds good" MEANS:
           - Exactly ONE option offered → a plain, unhedged agreement ("sounds good", "👍", "ok", "works", "perfect") is "accept", slot_index 1, confidence "high". Nothing to guess; "ambiguous" is WRONG.
           - MORE THAN ONE option offered → the same words are "ambiguous". NEVER guess a slot.
           A hedge is still soft_yes under rule 3 regardless of the option count.

        6. If they suggest an alternative that MATCHES one of the OFFERED OPTIONS (day matches AND the clock time is the option's time or unspecified) → that is "accept" of that option. If they name a time that DIFFERS on that day → "counter_propose".

        7. "counter_propose": they NEGOTIATE a specific alternative day+time that was NOT offered ("can we do Tue 5 instead?", "how about friday 10am?"). Set counter_time to RFC3339 in the user's timezone (use the offered duration; the NEXT future occurrence). No concrete day+time → "ambiguous" with counter_time "".

        8. "directive": they INSTRUCT rather than negotiate — an IMPERATIVE naming a time, no asking. Set counter_time like counter_propose. Imperative openers ("call me…", "ring me…", "come by…", "meet me…") are directives even with a friendly word or weekday. Request frames ("can we…", "could we…", "how about…", "would … work", "…instead?") are counter_propose. "can we do 5?" ASKS → counter_propose. "call me at 5" TELLS → directive. A trailing "?" does not make an imperative a request.

        9. "scope_change": they change the SHAPE (duration, format, venue), not the time. A bare statement counts ("15 mins is plenty", "coffee works better than a call").
           - new_duration_min: minutes if a different length ("make it an hour" → 60; "15 mins is plenty" → 15), else 0.
           - new_format: "call" | "video" | "in-person" if changed, else "".
           - needs_venue: true when the new shape needs a place and none is named.
           - requested_platform: a named video tool ("zoom", "teams", "meet"), else "".
           "just call me, no need for a meeting" is a scope_change to a call — NOT not_scheduling.

        10. "not_scheduling": it stopped being schedulable ("let's just do this on email", "my assistant will set it up") OR wrong person ("who is this?", "wrong number" → wrong_person true). Not for banter/silence.

        11. "reject": they declined with no alternative.
        12. "ambiguous": unclear, conditional, vague, or mixed signals.
        13. "unrelated": banter, reactions, social chatter, or media markers that don't engage the scheduling question — they simply haven't answered yet.
        14. side_note: any non-scheduling info worth relaying ("also send the deck"), else "". Coexists with any intent.
        15. confidence: "high" only when a careful assistant would act without double-checking; else "low". When torn between "accept" and "soft_yes", ALWAYS choose "soft_yes". The exception: exactly ONE option offered + plain agreement is a high-confidence "accept".
        16. Ignore messages from ME when judging THEIR position.


        """
        let full = df("EEEE, MMM d yyyy, h:mm a zzz", tz)
        sb += "Current date/time: \(full.string(from: rc.now))\nUser timezone: \(tz.identifier)\nContact: \(rc.contactName)\n"
        sb += "Upcoming days: "
        let dayEq = df("EEE'='MMM d", tz)
        for i in 0..<14 {
            if i > 0 { sb += ", " }
            sb += dayEq.string(from: rc.now.addingTimeInterval(Double(i) * 86400))
        }
        sb += "\n\nOFFERED OPTIONS:\n"
        for (i, s) in rc.slots.enumerated() { sb += formatSlotLine(i, s, tz) + "\n" }
        sb += "\nMESSAGE ME SENT:\n" + rc.draft + "\n\nTHREAD SINCE THEN (oldest first):\n"
        let msgTime = df("MMM d h:mm a", tz)
        for m in rc.thread {
            let who = m.fromMe ? "ME" : "THEM"
            let ts = m.time.map { " [" + msgTime.string(from: $0) + "]" } ?? ""
            sb += "\(who)\(ts): \(m.text)\n"
        }
        sb += "\nJSON:"
        return sb
    }

    static func buildOwnMessagePrompt(_ rc: ScheduleReplyContext) -> String {
        var sb = """
        You watch a chat thread for a scheduling assistant. The user (ME) had asked the assistant to schedule a meeting with a contact (THEM), but may have just settled it MANUALLY by texting the contact directly.

        Question: judging by ME's latest messages, have ME and THEM already finalized a meeting time between themselves (e.g. "ok see you tuesday 3pm", "locked, sending an invite")? Merely discussing or proposing does NOT count. But if ME unilaterally DECLARES a specific settled time and commits to it ("locking tomorrow 5pm", "sending you an invite for wed 11", "see you tuesday at 3"), that DOES count as finalized even without an explicit ack from THEM.

        Return STRICT JSON: {"finalized": true|false}


        """
        sb += "Contact: \(rc.contactName)\n\nTHREAD (oldest first):\n"
        for m in rc.thread { sb += "\(m.fromMe ? "ME" : "THEM"): \(m.text)\n" }
        sb += "\nJSON:"
        return sb
    }

    static func buildSelfTextPrompt(_ sc: ScheduleSelfTextContext) -> String {
        let tz = sc.timezone
        var sb = """
        You are part of a scheduling assistant. The user has a DRAFT message on the table, waiting to be sent to a contact. The user just typed something in their OWN private self-chat (a notes-to-self chat only they can see).

        Decide what that text IS:
        - "instruction": they are telling YOU what to change — days, window, duration, format, or how the message reads. Instructions usually talk ABOUT the contact in the third person, or address you directly ("make it", "change it", "actually...").
        - "draft": they wrote the actual message to SEND. Drafts talk TO the contact ("you"), or read as a complete WhatsApp message.
        - "note": a personal note with NOTHING to do with this meeting ("buy milk", "call the plumber"). Ignore in silence.
        - "unclear": it IS about this meeting, but you cannot tell whether it's an instruction or the message. A fine answer — we will ask.

        Return STRICT JSON, nothing else:
        {"kind": "instruction|draft|note|unclear", "window": "", "duration_min": 0, "format": "", "tone_note": "", "confidence": "high|low"}

        For "instruction", fill ONLY the fields they actually changed: window (a day/date phrase), duration_min (minutes), format ("call"|"video"|"in-person"), tone_note (how it should read differently). An instruction that changes nothing nameable is "unclear".

        DECISION PROCEDURE, IN ORDER:
        STEP 0 — IS THIS ABOUT THIS MEETING AT ALL? Errands, reminders, shopping lists, stray thoughts → "note" at high confidence, STOP.
        STEP 1 — WHO IS BEING SPOKEN TO? Addressed to the CONTACT → "draft", STOP. Signals: a greeting/vocative ("hey", "hi <name>", "mate"), an apology aimed at a person ("sorry mate", "sorry for the delay"), second person ("you", "does ... work for you"), a first-person statement of the USER's availability offered TO someone ("I'm free tue or wed"), or it reads end-to-end as a sendable message. Addressed to ME → step 2. Signals: the contact in third person ("he", "she", their name as subject), a command to the assistant ("make it", "change it", "actually..."), or a bare fragment no one would send ("45 mins", "warmer").
        STEP 2 — addressed to ME and names something concrete to change → "instruction". Extract fields.
        STEP 3 — addressee genuinely unclear, or nothing concrete named → "unclear".

        THE TRAP: a message addressed to the contact will often MENTION days/durations/formats — that does NOT make it an instruction. "sorry mate, can we do next week instead? I'm free tue or wed" is a DRAFT (apology + "can we" + "I'm free"), even though "next week" looks extractable. Step 1 outranks step 2. Mirror image: "he asked for Tue or Wed" talks ABOUT him → instruction. Same days; the ADDRESSEE differs.
        Calling an instruction a "draft" SENDS the user's private note to the contact — the worst outcome; never on a guess. But calling a plainly-addressed message "unclear" is also a failure. If you would be comfortable sending the text as-is to the contact, it is a draft.


        """
        let full = df("EEEE, MMM d yyyy, h:mm a zzz", tz)
        sb += "Current date/time: \(full.string(from: sc.now))\nContact the draft is addressed to: \(sc.contactName)\n"
        sb += "Meeting so far: \(sc.topic), \(sc.durationMin) min"
        if !sc.format.isEmpty { sb += ", " + sc.format }
        sb += "\n\nOPTIONS CURRENTLY ON THE TABLE:\n"
        for (i, s) in sc.slots.enumerated() { sb += formatSlotLine(i, s, tz) + "\n" }
        sb += "\nDRAFT CURRENTLY ON THE TABLE (this is what would be sent):\n" + sc.draft + "\n"
        sb += "\nWHAT THE USER JUST TYPED IN THEIR SELF-CHAT:\n" + sc.text + "\n"
        sb += "\nJSON:"
        return sb
    }
}
