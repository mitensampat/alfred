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
    var createdAt: Date?
    var updatedAt: Date?
}
