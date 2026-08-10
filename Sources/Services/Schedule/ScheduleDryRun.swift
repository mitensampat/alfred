import Foundation

/// A no-network harness that drives the ScheduleManager through a full @schedule → propose → reply
/// → book flow with fakes, mirroring Commit's manager tests. Proves the whole orchestration wires
/// up without a paired WhatsApp, Google Calendar, or the Claude API.
enum ScheduleDryRun {

    final class FakeCal: ScheduleCalendaring {
        var connected = true
        var bookings: [(String, Date)] = []
        func computeSlots(from: Date, to: Date, durationMin: Int, inPerson: Bool, requestedDays: [Int]) async throws -> [ScheduleSlot] {
            let base = Date().addingTimeInterval(86400)   // tomorrow
            return [10, 14, 16].map { h in
                let s = base.addingTimeInterval(Double(h) * 3600)
                return ScheduleSlot(start: s, end: s.addingTimeInterval(Double(durationMin) * 60), origin: "computed")
            }
        }
        func verifyFree(start: Date, end: Date) async throws -> Bool { true }
        func book(summary: String, description: String, start: Date, end: Date, withMeet: Bool) async throws -> (eventID: String, htmlLink: String, meetLink: String?) {
            bookings.append((summary, start)); return ("evt_1", "https://calendar.google.com/evt_1", withMeet ? "https://meet.google.com/abc-defg-hij" : nil)
        }
        func cancel(eventID: String) async throws {}
    }

    final class FakeSender: ScheduleSender {
        var toSelf: [String] = []
        var toContact: [String] = []
        func sendSelf(text: String) async -> (ok: Bool, msgID: String) { toSelf.append(text); return (true, "self_\(toSelf.count)") }
        func sendTo(jid: String, text: String) async -> (ok: Bool, msgID: String) { toContact.append(text); return (true, "to_\(toContact.count)") }
    }

    final class FakeInterp: ScheduleInterpreting {
        var reply = ScheduleInterpretation(intent: .accept, slotIndex: 2, confidence: "high")
        func interpretReply(_ rc: ScheduleReplyContext) async throws -> ScheduleInterpretation { reply }
        func interpretOwnMessage(_ rc: ScheduleReplyContext) async throws -> Bool { false }
        func classifySelfText(_ sc: ScheduleSelfTextContext) async throws -> ScheduleSelfTextClass { ScheduleSelfTextClass(kind: .unclear, confidence: "low") }
    }

    final class FakeDrafter: ScheduleDrafting {
        func inferContext(contactName: String, thread: [ScheduleThreadMsg], cmd: ScheduleCommand?) async -> ScheduleInferredContext {
            ScheduleInferredContext(topic: "quick sync", durationMin: cmd?.durationMin ?? 30, format: cmd?.format ?? "", window: cmd?.window ?? "")
        }
        func generateDraft(_ req: ScheduleDraftRequest) async -> String {
            "here are a few slots that could work:\n" + ScheduleFmt.slotList(req.slots, req.timezone) + "\nlet me know which suits you"
        }
    }

    static func run() async -> [[String: Any]] {
        let cal = FakeCal(), sender = FakeSender(), interp = FakeInterp(), drafter = FakeDrafter()
        let store = ScheduleStore(path: NSTemporaryDirectory() + "sched_dryrun_\(UUID().uuidString).db")
        let jid = "919820000000@s.whatsapp.net"
        let deps = ScheduleManager.Deps(
            cal: cal, interp: interp, drafter: drafter, sender: sender, store: store,
            timezone: .current, myStyle: { "" },
            directChats: { [(jid: jid, names: ["Kunal Shah", "Kunal"])] },
            thread: { _, _, _ in [] }, contactTZOverride: { _ in "" })
        let m = ScheduleManager(deps)

        var results: [[String: Any]] = []
        func add(_ n: String, _ p: Bool, _ note: String = "") { results.append(["case": n, "pass": p, "note": note]) }
        var t = Date()
        func tick() -> Date { t = t.addingTimeInterval(5); return t }

        // 1) @schedule kunal 30m tomorrow → resolves + proposes options in self-chat.
        _ = await m.handleSelfChat(text: "@schedule kunal 30m tomorrow", msgID: "m1", ts: tick())
        let proposed = sender.toSelf.last ?? ""
        add("@schedule resolves + surfaces options + draft", proposed.contains("Free options:") && proposed.contains("Draft to send:"))
        let s1 = store.openSession(contactJID: jid)
        add("session opened in slots_proposed", s1?.state == .slotsProposed && (s1?.slots.count ?? 0) == 3)

        // 2) propose → sends the draft to the counterpart.
        _ = await m.handleSelfChat(text: "propose", msgID: "m2", ts: tick())
        add("'propose' sends the draft to the counterpart", sender.toContact.count == 1 && sender.toContact[0].contains("slots that could work"))
        add("session now awaiting_reply", store.openSession(contactJID: jid)?.state == .awaitingReply)

        // 3) counterpart accepts option 2 → surfaced to self-chat, nothing booked yet.
        await m.onContactMessage(jid: jid, isFromMe: false, text: "the second one works", ts: tick())
        add("counterpart accept surfaced (not booked)", (sender.toSelf.last ?? "").contains("is good with") && cal.bookings.isEmpty)
        add("session reply_surfaced", store.openSession(contactJID: jid)?.state == .replySurfaced)

        // 4) yes → re-reads, re-verifies, books, confirms to the counterpart, closes.
        _ = await m.handleSelfChat(text: "yes", msgID: "m3", ts: tick())
        add("'yes' books the event", cal.bookings.count == 1)
        add("confirmation sent to the counterpart", sender.toContact.count == 2 && sender.toContact[1].lowercased().contains("it is"))
        add("self-chat gets a Booked receipt with the Meet link", (sender.toSelf.last ?? "").contains("Booked:") && (sender.toSelf.last ?? "").contains("Meet:"))
        add("session closed", store.openSession(contactJID: jid) == nil)

        return results
    }
}
