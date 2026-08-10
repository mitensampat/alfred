import Foundation

/// What we read from the recent thread to fill fields the command left blank.
struct ScheduleInferredContext: Codable {
    var topic: String = "catch-up"
    var durationMin: Int = 30
    var format: String = ""
    var window: String = ""
    enum CodingKeys: String, CodingKey { case topic, durationMin = "duration_min", format, window }
    init(topic: String = "catch-up", durationMin: Int = 30, format: String = "", window: String = "") {
        self.topic = topic; self.durationMin = durationMin; self.format = format; self.window = window
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        topic = (try? c.decode(String.self, forKey: .topic)) ?? "catch-up"
        durationMin = (try? c.decode(Int.self, forKey: .durationMin)) ?? 30
        format = (try? c.decode(String.self, forKey: .format)) ?? ""
        window = (try? c.decode(String.self, forKey: .window)) ?? ""
    }
}

/// Everything needed to write the proposal message.
struct ScheduleDraftRequest {
    var contactName: String
    var topic: String = ""
    var format: String = ""
    var slots: [ScheduleSlot] = []
    var myStyle: String = ""
    var timezone: TimeZone = .current
    var contactTZ: String = ""
    var contactTZNote: String = ""
    var styleSamples: [String] = []
    var cancel: Bool = false
    var bookedWhen: String = ""
    var requestedDays: String = ""
    var preferenceMet: Bool = true
    var toneNote: String = ""
}

/// The drafting surface — LLM in production, canned in the dry-run harness.
protocol ScheduleDrafting {
    func inferContext(contactName: String, thread: [ScheduleThreadMsg], cmd: ScheduleCommand?) async -> ScheduleInferredContext
    func generateDraft(_ req: ScheduleDraftRequest) async -> String
}

/// Claude-backed drafter — writes the proposal in the user's texting style; timezone assumptions
/// are stated, not hidden. Faithful port of Commit's schedule/draft.go prompts.
final class LLMDrafter: ScheduleDrafting {
    private let ai: ClaudeAIService
    private let model: String?
    init(ai: ClaudeAIService, model: String? = nil) { self.ai = ai; self.model = model }

    func inferContext(contactName: String, thread: [ScheduleThreadMsg], cmd: ScheduleCommand?) async -> ScheduleInferredContext {
        var sb = """
        You help a scheduling assistant infer meeting context from a WhatsApp thread. The user wants to schedule a meeting with the contact below. From the recent messages, infer:
        - topic: a short phrase for what the meeting is about (e.g. "CRED partnership follow-up"). If the thread gives no clue, use "catch-up".
        - duration_min: sensible duration in minutes (30 default; 60 if it's clearly a deep work session or meal).
        - format: "call", "video", or "in-person" if the thread suggests one, else "".
        - window: a time window if the thread suggests one (e.g. "this week", "after the 20th"), else "".

        Return STRICT JSON: {"topic": "", "duration_min": 30, "format": "", "window": ""}


        """
        sb += "Contact: \(contactName)\n\nRECENT MESSAGES (oldest first):\n"
        for m in thread { sb += "\(m.fromMe ? "ME" : "THEM"): \(m.text)\n" }
        sb += "\nJSON:"
        var ic = ScheduleInferredContext()
        if let raw = try? await ai.generateText(prompt: sb, maxTokens: 256, useModel: model),
           let data = ScheduleInterpreter.extractJSON(raw).data(using: .utf8),
           let parsed = try? JSONDecoder().decode(ScheduleInferredContext.self, from: data) {
            ic = parsed
        }
        if let cmd = cmd {
            if cmd.durationMin > 0 { ic.durationMin = cmd.durationMin }
            if !cmd.format.isEmpty { ic.format = cmd.format }
            if !cmd.window.isEmpty { ic.window = cmd.window }
        }
        if ic.durationMin <= 0 { ic.durationMin = 30 }
        return ic
    }

    func generateDraft(_ req: ScheduleDraftRequest) async -> String {
        let out = (try? await ai.generateText(prompt: Self.buildDraftPrompt(req), maxTokens: 512, useModel: model)) ?? ""
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func buildDraftPrompt(_ dr: ScheduleDraftRequest) -> String {
        let tz = dr.timezone
        var sb = """
        Write a short WhatsApp message from the user to the contact below. Match the user's texting style (see style notes and samples). No signatures, no "Dear". Keep it natural and brief.

        CRITICAL: this message CONTINUES an ongoing conversation — the contact just asked to meet. Do NOT greet, do NOT reintroduce the idea of meeting ("hey X!", "wanna catch up sometime?"). Reply like the last message in the thread was seconds ago. The shape is simply: a casual lead-in like "here are some slots that could work:", then the times as a numbered list (1., 2., ...) so they can reply with just a number, then a short closer like "let me know which one suits you".


        """
        if dr.cancel {
            sb += "Exception for this message: it must gracefully cancel their planned meeting"
            if !dr.bookedWhen.isEmpty { sb += " (" + dr.bookedWhen + ")" }
            sb += ", apologize briefly, and offer to rebook.\n"
        } else {
            sb += "Only mention what the meeting is about if the thread left it ambiguous — usually they already know.\n"
            if !dr.preferenceMet && !dr.requestedDays.isEmpty {
                sb += "IMPORTANT: they asked for \(dr.requestedDays), but the user is fully booked on those days. The message MUST acknowledge what they asked for, say plainly that those days don't work, and offer the times below as the alternative — apologetic but not grovelling. Do not pretend these are the days they wanted.\n"
            }
            if !dr.contactTZ.isEmpty && !dr.contactTZNote.isEmpty {
                sb += "IMPORTANT — the contact is likely in a different timezone (\(dr.contactTZNote)). Every time you mention MUST show BOTH clocks: lead with the user's own time, then the contact's in parentheses. Two lists are given below — pair them. Do NOT show only the contact's time.\n"
            }
        }
        sb += "\nContact: \(dr.contactName)\nTopic: \(dr.topic)\n"
        if !dr.format.isEmpty { sb += "Format: \(dr.format)\n" }
        if !dr.cancel {
            sb += "Times in the USER's timezone (\(tz.identifier)) — lead with these:\n"
            for (i, s) in dr.slots.enumerated() { sb += ScheduleFmt.slotLine(i, s, tz) + "\n" }
            if !dr.contactTZ.isEmpty, let cloc = TimeZone(identifier: dr.contactTZ) {
                sb += "The SAME times in the CONTACT's timezone (\(dr.contactTZ)) — show these in parentheses alongside, never instead:\n"
                for (i, s) in dr.slots.enumerated() { sb += ScheduleFmt.slotLine(i, s, cloc) + "\n" }
            }
        }
        if !dr.toneNote.isEmpty {
            sb += "\nIMPORTANT — the user asked for this message specifically to be: \(dr.toneNote)\nHonor that over the general style notes below.\n"
        }
        if !dr.myStyle.isEmpty { sb += "\nUser's style notes: \(dr.myStyle)\n" }
        if !dr.styleSamples.isEmpty {
            sb += "\nRecent messages the user sent (style reference):\n"
            for s in dr.styleSamples { sb += "- " + s + "\n" }
        }
        sb += "\nReturn ONLY the message text, nothing else."
        return sb
    }
}
