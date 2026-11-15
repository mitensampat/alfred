import Foundation

/// What the text after "@schedule" was read as.
enum ScheduleCommandReading {
    /// A request to act on. `viaModel` says which reader produced it (reported by the dry-run).
    case command(ScheduleCommand, viaModel: Bool)
    /// It could not be turned into a request; the string is the one question to send back.
    case ask(String)
}

/// Reads the text after the "@schedule" prefix.
///
/// The exact form — "<name> [duration] [format] [window]" — is parsed in place by
/// ScheduleCommandParser, at no cost and exactly as before. Anything looser ("can you find 45
/// mins with Rohini Thursday afternoon about the Kuvera review") goes to the model, which the
/// exact parser used to mangle: it took every word before the first duration as the name.
///
/// What this does NOT change: the line still has to start with "@schedule" (the watcher reads
/// every note the user writes to themself), and the reading only opens a request. Nothing is
/// sent to the other person or booked until the user answers Alfred's prompt with 'propose',
/// 'yes N', 'edit' or 'leave it' — the consent words stay exact.
///
/// It runs once per command: the watcher hands each self-chat message over once, so this is one
/// model call per loosely phrased line, never one per poll.
enum ScheduleCommandReader {

    /// Words that never belong to a person's name. One of them in the parsed name means the line
    /// was a sentence, not the exact form.
    private static let sentenceWords: Set<String> = [
        "a", "an", "the", "with", "for", "about", "re", "on", "at", "in", "to", "of", "and", "or",
        "can", "could", "would", "will", "you", "please", "pls", "find", "get", "set", "setup", "up",
        "book", "fix", "arrange", "plan", "put", "need", "want", "like", "lets", "let's", "i", "me",
        "my", "we", "us", "our", "time", "slot", "meeting", "meet", "catchup", "catch-up", "sync",
        "chat", "some", "sometime", "is", "are", "be", "do", "have", "from", "after", "before",
        "between", "by", "until", "till", "around", "any", "when", "if", "it", "that", "his", "her", "their"
    ]

    /// True when `rest` is the exact form and the parser's reading of it can be trusted.
    static func isExactForm(_ rest: String, _ cmd: ScheduleCommand) -> Bool {
        if rest.contains("?") || rest.contains(",") { return false }
        let name = cmd.name.lowercased().split(separator: " ").map(String.init)
        guard (1...3).contains(name.count) else { return false }
        for w in name where sentenceWords.contains(w) || w.contains(where: { $0.isNumber }) { return false }
        // Tail tokens the parser did not recognise are swept into the window. If any are there,
        // the line said more than the exact form can hold.
        for w in cmd.window.split(separator: " ") where !ScheduleCommandParser.windowWords.contains(String(w)) { return false }
        return true
    }

    static func read(_ rest: String, drafter: ScheduleDrafting, now: Date, tz: TimeZone) async -> ScheduleCommandReading {
        let parsed = try? ScheduleCommandParser.parse(rest)
        if let p = parsed, isExactForm(rest, p) { return .command(p, viaModel: false) }
        if let r = await drafter.interpretCommand(rest, now: now, tz: tz) { return r }
        // No model answer: fall back to the exact parser, which is what happened before.
        if let p = parsed { return .command(p, viaModel: false) }
        return .ask("Who should I schedule with? Send: @schedule <name> [duration] [format] [when]")
    }

    // MARK: - Model

    static func prompt(_ rest: String, now: Date, tz: TimeZone) -> String {
        let iso = ISO8601DateFormatter(); iso.timeZone = tz
        let day = DateFormatter(); day.timeZone = tz; day.locale = Locale(identifier: "en_US_POSIX"); day.dateFormat = "EEEE"
        // The model reads language well and counts days badly ("next week" came back Tuesday to
        // Monday), so the dates it needs are worked out here and handed over.
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let ymd = DateFormatter(); ymd.timeZone = tz; ymd.locale = Locale(identifier: "en_US_POSIX"); ymd.dateFormat = "EEE yyyy-MM-dd"
        let today = cal.startOfDay(for: now)
        func plus(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: today) ?? today.addingTimeInterval(Double(n) * 86400) }
        let weekday = cal.component(.weekday, from: today)            // Sun=1 … Sat=7
        let toSunday = (8 - weekday) % 7                              // 0 when today is Sunday
        // "next week" is the Monday after today through its Sunday — the same week the exact-form
        // parser means (ScheduleWindow.range). On a Sunday "this week" has only today left in it,
        // so it runs on through that coming week as well.
        let nextMonday = plus(toSunday + 1)
        let nextWeek = (nextMonday, cal.date(byAdding: .day, value: 6, to: nextMonday) ?? nextMonday)
        let thisWeek = toSunday == 0 ? (today, nextWeek.1) : (today, plus(toSunday))
        let table = (0..<21).map { ymd.string(from: plus($0)) }.joined(separator: ", ")
        let dates = """
        Calendar (use these, do not count days yourself):
        - today is \(ymd.string(from: today)); tomorrow is \(ymd.string(from: plus(1)))
        - "this week" = \(ymd.string(from: thisWeek.0)) to \(ymd.string(from: thisWeek.1))
        - "next week" = \(ymd.string(from: nextWeek.0)) to \(ymd.string(from: nextWeek.1))
        - a bare weekday means its next occurrence after today
        - the next 21 days: \(table)
        """
        return """
        You read one line a person typed to their scheduling assistant, and turn it into a structured request. The assistant then checks the calendar and shows free options for the person to approve. You do not pick a time and you do not decide anything.

        Now: \(iso.string(from: now)) (\(day.string(from: now))), timezone \(tz.identifier).
        Line: "\(rest.replacingOccurrences(of: "\"", with: "'"))"

        \(dates)

        Return ONLY JSON:
        {"action":"schedule|move|cancel|unclear","person":"","duration_min":0,"format":"","window":"","from":"","to":"","earliest":"","latest":"","topic":"","question":""}

        - action: "schedule" to set up a meeting with someone; "move" to reschedule an existing meeting with them; "cancel" to cancel one; "unclear" if no other person is named, more than one person is named, or the line is not about arranging a meeting.
        - person: the other person's name exactly as typed, nothing added and no "with". Empty when unclear.
        - duration_min: minutes if stated ("an hour" = 60, "half an hour" = 30, "quick" = 15), else 0.
        - format: "call", "video" or "in-person" if stated or plainly implied (coffee, lunch, dinner, a walk, a named office or place = in-person; zoom, meet, online = video; phone = call), else "".
        - window: the time constraint in the person's own words, kept short ("thursday afternoon", "next week", "after the 20th"). Empty if none.
        - from / to: the first and last calendar day (YYYY-MM-DD, both inclusive) the meeting may fall on, worked out from the line against Now. One day: from = to. "this week" and "next week": exactly the ranges given above. "after the 20th": from the 21st, to two weeks later. Both empty when the line gives no day.
        - earliest / latest: 24-hour "HH:MM" bounds on the time of day, when stated: "after 3pm" = earliest 15:00; "before noon" = latest 12:00; "morning" = latest 12:00; "afternoon" = earliest 12:00, latest 17:00; "evening" = earliest 17:00; "at 4pm" = earliest 16:00. Empty otherwise.
        - topic: what the meeting is about, only if the line says; else "".
        - question: only when action is "unclear": one short question that would let the person fix the request. Otherwise "".
        """
    }

    /// The model's JSON as a reading. nil when it is not usable JSON.
    static func reading(fromModel raw: String, now: Date, tz: TimeZone) -> ScheduleCommandReading? {
        guard let data = ScheduleInterpreter.extractJSON(raw).data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func str(_ k: String) -> String { ((o[k] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

        let action = str("action").lowercased()
        var person = str("person")
        if person.hasPrefix("@") { person.removeFirst() }
        if action == "unclear" || person.isEmpty || !["schedule", "move", "cancel"].contains(action) {
            let q = str("question")
            return .ask((q.isEmpty ? "I couldn't tell who that's with." : q)
                        + "\nSend it again starting with @schedule, e.g. \"@schedule 30 mins with Rohini on Thursday afternoon\".")
        }

        var cmd = ScheduleCommand()
        cmd.verb = ScheduleIntent(rawValue: action) ?? .schedule
        cmd.name = person
        let dur = (o["duration_min"] as? Int) ?? Int(str("duration_min")) ?? 0
        cmd.durationMin = (5...480).contains(dur) ? dur : 0
        let format = str("format").lowercased()
        cmd.format = ["call", "video", "in-person"].contains(format) ? format : ""
        cmd.window = str("window").lowercased()
        let topic = str("topic")
        cmd.topic = topic.isEmpty ? nil : topic

        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let df = DateFormatter(); df.timeZone = tz; df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "yyyy-MM-dd"
        let from = df.date(from: str("from")), to = df.date(from: str("to"))
        if from != nil || to != nil {
            let start = from ?? cal.startOfDay(for: now)
            let lastDay = to ?? cal.date(byAdding: .day, value: 6, to: start) ?? start
            let end = cal.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay.addingTimeInterval(86400)
            // A range that is already over, runs backwards, or reaches implausibly far is a
            // misreading; drop it and let the phrase decide, as it did before.
            if end > now, end > start, start < now.addingTimeInterval(120 * 86400) {
                cmd.windowFrom = start; cmd.windowTo = end
            }
        }
        cmd.earliestMin = minutes(str("earliest"))
        cmd.latestMin = minutes(str("latest"))
        if let e = cmd.earliestMin, let l = cmd.latestMin, l <= e { cmd.latestMin = nil }
        return .command(cmd, viaModel: true)
    }

    /// "15:30" → 930. nil for anything else.
    static func minutes(_ hhmm: String) -> Int? {
        let p = hhmm.split(separator: ":")
        guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]), (0...23).contains(h), (0...59).contains(m) else { return nil }
        return h * 60 + m
    }

    /// The reading as plain values, for the dry-run endpoint. No side effects.
    static func describe(_ r: ScheduleCommandReading, tz: TimeZone) -> [String: Any] {
        switch r {
        case .ask(let q): return ["ok": false, "ask": q]
        case .command(let c, let viaModel):
            let df = DateFormatter(); df.timeZone = tz; df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "EEE yyyy-MM-dd HH:mm"
            func clock(_ m: Int?) -> String { m.map { String(format: "%02d:%02d", $0 / 60, $0 % 60) } ?? "" }
            return ["ok": true, "read_by": viaModel ? "model" : "exact-form parser",
                    "verb": c.verb.rawValue, "name": c.name, "duration_min": c.durationMin, "format": c.format,
                    "window": c.window, "topic": c.topic ?? "",
                    "from": c.windowFrom.map { df.string(from: $0) } ?? "",
                    "to_exclusive": c.windowTo.map { df.string(from: $0) } ?? "",
                    "earliest": clock(c.earliestMin), "latest": clock(c.latestMin)]
        }
    }
}
