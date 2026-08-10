import Foundation

// Alfred's @schedule feature — a self-chat / Desk-driven meeting scheduler with an explicit
// consent contract, ported faithfully from the Commit app (github.com/mitensampat/commit,
// schedule/). The core is a pure state machine (ScheduleEngine, later phase) + an LLM reply
// interpreter behind an interface, so the whole session lifecycle is testable without WhatsApp,
// Google Calendar, or the Claude API.
//
// Phase 1 (this file): the vocabulary — lifecycle states, intents, engine actions, the Slot and
// Session value types, and the "@schedule …" command parser. No side effects.

/// Lifecycle position of a scheduling session.
enum ScheduleState: String, Codable {
    case resolving          // contact match ambiguous; waiting for the user to pick
    case slotsProposed = "slots_proposed"   // slots + draft shown in self-chat; awaiting propose/edit/leave
    case awaitingReply = "awaiting_reply"   // draft sent to the counterpart; watcher active
    case replySurfaced = "reply_surfaced"   // counterpart reply surfaced with yes/edit/leave prompt
    case held               // SOFT yes — nothing booked, watcher stays live; user can force with explicit yes
    case confirmCancel = "confirm_cancel"   // @schedule cancel asked yes/yes-silent/leave-it
    case closed
}

/// What the user asked for.
enum ScheduleIntent: String, Codable {
    case schedule, move, cancel
}

/// What the wiring layer must do next. The engine never performs side effects itself.
enum ScheduleAction: String, Codable {
    case none
    case ask                                    // send Decision.reply to self-chat and wait
    case pickContact = "pick_contact"           // user answered a disambiguation; Decision.index is the 1-based choice
    case propose                                // send the draft to the counterpart (Decision.indices = subset, empty = all)
    case alreadyProposed = "already_proposed"   // duplicate propose within the dedup window
    case requestBooking = "request_booking"     // user consented; wiring re-reads thread, re-verifies slot, then DecideBooking
    case replaceDraft = "replace_draft"         // Decision.text is the new draft
    case editPrompt = "edit_prompt"             // ask the user for the new draft text
    case close                                  // end the session quietly (leave it); Decision.reason set
    case cancelMeeting = "cancel_meeting"       // delete the booked event + send a graceful note
    case cancelSilent = "cancel_silent"         // delete the booked event, send nothing
    case surfaceReply = "surface_reply"         // show the counterpart's reply with yes/edit/leave-it
    case surfaceChange = "surface_change"       // correction race: thread changed since prompt; show the change
    case standDown = "stand_down"               // user resolved it manually in the counterpart chat; close silently
    case book                                   // verified + consented: create the event and confirm
    case slotTaken = "slot_taken"               // the slot filled between proposal and yes
    case verifyCounter = "verify_counter"       // counterpart proposed an unoffered time; verify + surface it
    case expire                                 // 48h of silence; close silently
    case classifyText = "classify_text"         // scoped self-chat free text over a pending draft; wiring classifies
    case hold                                   // soft yes: tell the user which slot, book nothing, keep watching
    case surfacePick = "surface_pick"           // they deferred the choice to us; we picked (does NOT book)
    case scopeChange = "scope_change"           // meeting shape changed; recompute slots, redraft, re-surface
    case notScheduling = "not_scheduling"       // it stopped being scheduling; close with a reason
    case slotPast = "slot_past"                 // picked slot is in the past; recompute fresh options
    case surfaceMedia = "surface_media"         // an unreadable message arrived while awaiting a reply
    case applyInstruction = "apply_instruction" // the user told Alfred what to change; session already mutated
}

/// A concrete proposable meeting time, in the user's timezone.
struct ScheduleSlot: Codable, Equatable {
    var start: Date
    var end: Date
    /// "computed" (our calendar) or "counterpart" (they proposed it and we verified it free).
    var origin: String?
    /// Butts up against an existing meeting — keeps large free blocks intact, so it's the one to
    /// pick when the counterpart defers the choice to us.
    var adjacent: Bool = false
}

/// The full engine-level session state, serialized to the store as JSON.
struct ScheduleSession: Codable {
    var id: String
    var contactJID: String
    var contactName: String
    var state: ScheduleState
    var intent: ScheduleIntent

    var topic: String = ""
    var durationMin: Int = 0
    var format: String = ""          // "call", "video", "in-person"
    var window: String = ""          // freeform, e.g. "this week"
    var requestedDays: String = ""   // weekdays the counterpart asked for ("Tue/Wed")
    var preferenceMet: Bool = true   // false when nothing was free on the requested days

    var slots: [ScheduleSlot] = []   // currently pickable options, 1-based in user-facing text
    var draft: String = ""           // message to send to the counterpart
    var sentDraft: String = ""       // draft as actually sent; thread interpretation uses THIS, not draft

    var contactTZ: String = ""       // IANA name, best inference or override
    var contactTZNote: String = ""   // e.g. "assuming SF from +1 number"

    /// Consent scoping: bare consent words only count as the next self-chat message after our
    /// prompt, or within the consent window of it.
    var lastPromptAt: Date?
    var bookedEventID: String = ""
    var bookedLink: String = ""
    var bookedSlot: ScheduleSlot?
    var createdAt: Date?
    var updatedAt: Date?

    // Idempotent propose: a second propose within proposeDedupWindow is a no-op.
    var proposedAt: Date?
    var proposedSlots: [Int] = []       // 1-based indices actually sent
    // AwaitingDraftEdit — the user said "edit"; the next scoped self-chat msg replaces the draft.
    var awaitingDraftEdit: Bool = false
    // PickedIndex — the 1-based slot Alfred chose when the counterpart handed the choice back.
    var pickedIndex: Int = 0
    // Surfaced — the interpretation we showed the user in the yes/edit/leave-it prompt. At "yes"
    // time the thread is re-read; a materially different fresh reading surfaces the change instead.
    var surfaced: ScheduleInterpretation?
    var surfacedAtMsgTime: Date?
    var lastActivity: Date?             // drives silent expiry (48h)
    var lastMediaSurfacedAt: Date?      // rate-limits "they sent a voice note" nudges
    var toneNote: String = ""           // standing "make it warmer" applied on every redraft
    var candidates: [ScheduleContactCandidate] = []   // pending disambiguation (resolving)
    var cmd: ScheduleCommand?           // original parsed command, kept while resolving
    var lastPromptID: String = ""       // WhatsApp message ID of our last self-chat prompt
    var oldEventID: String = ""         // @schedule move: event to delete once rebooked
}

// MARK: - Consent scoping + idempotency windows (Commit hardening reqs 3 & 6)

enum ScheduleConst {
    static let consentWindow: TimeInterval = 2 * 3600
    static let proposeDedupWindow: TimeInterval = 5 * 60
    static let sessionExpiry: TimeInterval = 48 * 3600
    static let mediaBurstWindow: TimeInterval = 15 * 60
}

// MARK: - Interpreter vocabulary

/// A non-text message we received but can't read (voice notes are common on WhatsApp).
enum ScheduleMediaKind: String, Codable {
    case voice = "voice note", audio = "audio message", image = "photo"
    case video, document, sticker
}

/// The interpreter's classification of the latest counterpart thread state.
enum ScheduleReplyIntent: String, Codable {
    case accept, reject
    case counter = "counter_propose"
    case ambiguous, unrelated
    case softYes = "soft_yes"           // SAFETY-CRITICAL: a hedge; never books
    case deference                       // "you pick" — we choose, then still need the user's yes
    case scopeChange = "scope_change"    // shape changed, not time
    case directive                       // "call me at 5" — an instruction, not a negotiation
    case notScheduling = "not_scheduling"
}

/// Structured reading of the counterpart thread — always the LATEST state.
struct ScheduleInterpretation: Codable {
    var intent: ScheduleReplyIntent
    var slotIndex: Int = 0              // 1-based accepted slot; 0 if none
    var counterTime: String = ""        // RFC3339 in the user's tz for an unoffered concrete time
    var sideNote: String = ""           // non-scheduling content worth relaying
    var confidence: String = ""         // "high" | "low"; the engine never books on low
    var deferSlots: [Int] = []          // deference subset ("Tue or Wed, you choose" → [1,2])
    var newDurationMin: Int = 0          // scope_change
    var newFormat: String = ""           // scope_change: call | video | in-person
    var needsVenue: Bool = false         // scope_change: a place must be decided
    var requestedPlatform: String = ""   // scope_change: a named video tool (we only do Meet)
    var wrongPerson: Bool = false        // not_scheduling: "who is this?" — close loudly

    /// Whether two interpretations would book the same thing (scope + defer participate, so a
    /// stale scope/narrowing can't slip through the correction-race gate).
    func sameOutcome(_ b: ScheduleInterpretation?) -> Bool {
        guard let b = b else { return false }
        return intent == b.intent && slotIndex == b.slotIndex && counterTime == b.counterTime
            && newDurationMin == b.newDurationMin && newFormat == b.newFormat
            && ScheduleEngine.sameInts(deferSlots, b.deferSlots)
    }
}

/// Classifies the user's own self-chat free text while a draft is pending — the foot-gun an
/// instruction silently armed as the outbound draft would be.
enum ScheduleSelfTextKind: String, Codable {
    case instruction, draft, note, unclear
}

struct ScheduleSelfTextClass: Codable {
    var kind: ScheduleSelfTextKind
    var window: String = ""
    var durationMin: Int = 0
    var format: String = ""
    var toneNote: String = ""
    var confidence: String = ""         // "high" | "low"; low degrades to unclear
    func needsRecompute() -> Bool { !window.isEmpty || durationMin > 0 || !format.isEmpty }
}

struct ScheduleContactCandidate: Codable {
    var jid: String
    var name: String
}

// Model output is snake_case and often omits fields; decode leniently so any missing/malformed key
// falls to a safe default (never a spurious booking), matching Commit's defensive parse.
extension ScheduleInterpretation {
    enum CodingKeys: String, CodingKey {
        case intent, slotIndex = "slot_index", counterTime = "counter_time", sideNote = "side_note",
             confidence, deferSlots = "defer_slots", newDurationMin = "new_duration_min",
             newFormat = "new_format", needsVenue = "needs_venue", requestedPlatform = "requested_platform",
             wrongPerson = "wrong_person"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            intent: (try? c.decode(ScheduleReplyIntent.self, forKey: .intent)) ?? .ambiguous,
            slotIndex: (try? c.decode(Int.self, forKey: .slotIndex)) ?? 0,
            counterTime: (try? c.decode(String.self, forKey: .counterTime)) ?? "",
            sideNote: (try? c.decode(String.self, forKey: .sideNote)) ?? "",
            confidence: (try? c.decode(String.self, forKey: .confidence)) ?? "",
            deferSlots: (try? c.decode([Int].self, forKey: .deferSlots)) ?? [],
            newDurationMin: (try? c.decode(Int.self, forKey: .newDurationMin)) ?? 0,
            newFormat: (try? c.decode(String.self, forKey: .newFormat)) ?? "",
            needsVenue: (try? c.decode(Bool.self, forKey: .needsVenue)) ?? false,
            requestedPlatform: (try? c.decode(String.self, forKey: .requestedPlatform)) ?? "",
            wrongPerson: (try? c.decode(Bool.self, forKey: .wrongPerson)) ?? false)
    }
}

extension ScheduleSelfTextClass {
    enum CodingKeys: String, CodingKey {
        case kind, window, durationMin = "duration_min", format, toneNote = "tone_note", confidence
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kind: (try? c.decode(ScheduleSelfTextKind.self, forKey: .kind)) ?? .unclear,
            window: (try? c.decode(String.self, forKey: .window)) ?? "",
            durationMin: (try? c.decode(Int.self, forKey: .durationMin)) ?? 0,
            format: (try? c.decode(String.self, forKey: .format)) ?? "",
            toneNote: (try? c.decode(String.self, forKey: .toneNote)) ?? "",
            confidence: (try? c.decode(String.self, forKey: .confidence)) ?? "")
    }
}

// MARK: - Engine I/O

/// A self-chat message the user typed, with the scoping facts the engine needs.
struct ScheduleSelfChatInput {
    var text: String
    var now: Date
    /// First self-chat message after Alfred's last prompt (nothing else in between).
    var isNextAfterPrompt: Bool = false
    /// The text carried the @schedule prefix, which always counts.
    var forceScoped: Bool = false
}

/// The engine's output. The engine mutates the session in place and returns what the wiring does.
struct ScheduleDecision {
    var action: ScheduleAction
    var reply: String = ""              // suggested self-chat text
    var index: Int = 0                  // 1-based slot/contact index, when relevant
    var indices: [Int] = []             // propose subset
    var text: String = ""               // replacement draft text
    var interp: ScheduleInterpretation? // for surface actions
    var selfClass: ScheduleSelfTextClass?   // for applyInstruction
    var reason: String = ""

    init(_ action: ScheduleAction, reply: String = "", index: Int = 0, indices: [Int] = [],
         text: String = "", interp: ScheduleInterpretation? = nil,
         selfClass: ScheduleSelfTextClass? = nil, reason: String = "") {
        self.action = action; self.reply = reply; self.index = index; self.indices = indices
        self.text = text; self.interp = interp; self.selfClass = selfClass; self.reason = reason
    }
}
