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
        var ok = true                    // false simulates a down wa-bridge
        func sendSelf(text: String) async -> (ok: Bool, msgID: String) { toSelf.append(text); return (ok, ok ? "self_\(toSelf.count)" : "") }
        func sendTo(jid: String, text: String) async -> (ok: Bool, msgID: String) { toContact.append(text); return (ok, ok ? "to_\(toContact.count)" : "") }
    }

    final class FakeInterp: ScheduleInterpreting {
        var reply = ScheduleInterpretation(intent: .accept, slotIndex: 2, confidence: "high")
        var replyCalls = 0
        func interpretReply(_ rc: ScheduleReplyContext) async throws -> ScheduleInterpretation { replyCalls += 1; return reply }
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

        // A fresh manager over its own store, so each case below starts clean.
        func build(_ sender: FakeSender, _ interp: FakeInterp,
                   _ chats: [(jid: String, names: [String])]) -> (ScheduleManager, ScheduleStore) {
            let st = ScheduleStore(path: NSTemporaryDirectory() + "sched_dryrun_\(UUID().uuidString).db")
            let m = ScheduleManager(ScheduleManager.Deps(
                cal: FakeCal(), interp: interp, drafter: FakeDrafter(), sender: sender, store: st,
                timezone: .current, myStyle: { "" }, directChats: { chats },
                thread: { _, _, _ in [] }, contactTZOverride: { _ in "" }))
            return (m, st)
        }

        // 5) A failed self-chat send must not take the session with it. The Desk runs the same flow
        //    off the stored prompt; losing the state left the user clicking buttons against nothing.
        let deadSender = FakeSender(); deadSender.ok = false
        let (m2, store2) = build(deadSender, FakeInterp(), [(jid: jid, names: ["Kunal Shah", "Kunal"])])
        _ = await m2.handleSelfChat(text: "@schedule kunal 30m tomorrow", msgID: "d1", ts: tick())
        let survivor = store2.openSession(contactJID: jid)
        add("session survives a failed self-chat send",
            survivor?.state == .slotsProposed && !(survivor?.lastPromptText.isEmpty ?? true) && survivor?.lastPromptAt != nil)

        // 6) Two live sessions: a line naming one acts on THAT one. The Desk's cards are
        //    per-session, so "leave it" on Kunal's card must not close Priya's.
        let jidB = "919820000001@s.whatsapp.net"
        let (m3, store3) = build(FakeSender(), FakeInterp(),
                                 [(jid: jid, names: ["Kunal Shah"]), (jid: jidB, names: ["Priya Nair"])])
        _ = await m3.handleSelfChat(text: "@schedule kunal 30m tomorrow", msgID: "t1", ts: tick())
        _ = await m3.handleSelfChat(text: "@schedule priya 30m tomorrow", msgID: "t2", ts: tick())
        let kunalID = store3.openSession(contactJID: jid)?.id ?? ""
        _ = await m3.handleSelfChat(text: "leave it", msgID: "t3", ts: tick(), sessionID: kunalID)
        add("a targeted line acts on the session it names",
            !kunalID.isEmpty && store3.openSession(contactJID: jid) == nil
                && store3.openSession(contactJID: jidB)?.state == .slotsProposed)

        // 7) The poller re-feeds the thread from the proposal on every tick. The same message must
        //    be read once — re-reading meant an LLM call a minute and a repeat of a prompt the user
        //    had already answered.
        let counting = FakeInterp()
        let (m4, _) = build(FakeSender(), counting, [(jid: jid, names: ["Kunal Shah", "Kunal"])])
        _ = await m4.handleSelfChat(text: "@schedule kunal 30m tomorrow", msgID: "w1", ts: tick())
        _ = await m4.handleSelfChat(text: "propose", msgID: "w2", ts: tick())
        let replyTS = tick()
        await m4.onContactMessage(jid: jid, isFromMe: false, text: "the second one works", ts: replyTS)
        let afterFirst = counting.replyCalls
        await m4.onContactMessage(jid: jid, isFromMe: false, text: "the second one works", ts: replyTS)
        add("a re-fed counterpart message is read once", afterFirst == 1 && counting.replyCalls == 1)

        // 8) A name that matches nobody outright offers the closest saved names to pick from,
        //    instead of ending the command in silence. A guess is never auto-started.
        let (m5, store5) = build(FakeSender(), FakeInterp(),
                                 [(jid: jid, names: ["Arundhati Sampat"]), (jid: jidB, names: ["Priya Nair"])])
        _ = await m5.handleSelfChat(text: "@schedule arundati", msgID: "n1", ts: tick())
        let guessed = store5.allOpenSessions().first
        add("a misspelled name offers the closest match",
            guessed?.state == .resolving && guessed?.candidates.first?.name == "Arundhati Sampat")

        // 9) A doubled prefix (the palette and the self-chat both let one through) must not land
        //    inside the name.
        add("a doubled @schedule prefix parses to the bare name",
            (try? ScheduleCommandParser.parse("@schedule arundhati 30m").name) == "arundhati")

        return results
    }
}
