import Foundation

/// Meeting preferences, written by the user as plain prose and compiled into something the slot
/// finder can score against.
///
/// The structured form below is deliberately not the interface. Nobody wants to hand-edit weighted
/// time windows in JSON, and a schema that is tedious to edit is a schema that stays at its
/// defaults — which is how @schedule ended up proposing 9am Monday slots to someone who is at the
/// gym. The user writes a paragraph; Claude compiles it; the compiled result is always shown back,
/// so the reading can be corrected rather than guessed at.
///
/// Compilation is cached against a hash of the prose: the same text never recompiles, and edited
/// text always does. A failed or malformed compile falls back to `.fallback` (today's behaviour)
/// rather than to nothing — a bad preference sentence must not take scheduling down with it.
struct SchedulePrefSpec: Codable, Equatable {

    /// A weighted time band. Positive weight = prefer, negative = avoid. Weights are added to the
    /// slot score alongside the adjacency bonus, so they tilt the ranking rather than veto times —
    /// except `hard`, which removes the window from consideration entirely.
    struct Window: Codable, Equatable {
        var days: [Int] = []          // Go weekdays, Sun=0…Sat=6; empty = every day
        var startMin: Int = 0         // minutes from local midnight
        var endMin: Int = 0
        var weight: Double = 0        // + prefer, − avoid
        var hard: Bool = false        // true = never schedule here at all
        var label: String = ""        // how this read back to the user, e.g. "externals after 4pm"

        enum CodingKeys: String, CodingKey {
            case days, weight, hard, label
            case startMin = "start_min"
            case endMin = "end_min"
        }

        init() {}

        /// Every field optional with a default. Swift's synthesized Decodable ignores default
        /// property values and throws on a missing key, which is incompatible with a compiler
        /// prompt that says "omit what they did not mention" — the model omits, the decode fails,
        /// and the user's whole preference text is rejected over an absent field.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            days = (try? c.decodeIfPresent([Int].self, forKey: .days)) as? [Int] ?? []
            startMin = (try? c.decodeIfPresent(Int.self, forKey: .startMin)) as? Int ?? 0
            endMin = (try? c.decodeIfPresent(Int.self, forKey: .endMin)) as? Int ?? 0
            weight = (try? c.decodeIfPresent(Double.self, forKey: .weight)) as? Double ?? 0
            hard = (try? c.decodeIfPresent(Bool.self, forKey: .hard)) as? Bool ?? false
            label = (try? c.decodeIfPresent(String.self, forKey: .label)) as? String ?? ""
        }
    }

    var meetingStartMin: Int = 9 * 60
    var meetingEndMin: Int = 18 * 60
    var workdays: [Int] = [1, 2, 3, 4, 5]
    var windows: [Window] = []

    /// Titles Alfred may schedule straight over (soft holds), matched on whole words.
    var ignoreTitles: [String] = ["block", "hold", "focus", "ooo", "lunch"]

    /// Long free stretches are worth keeping whole. A slot that consumes a block at least this long
    /// takes `deepWorkPenalty` off its score, which pushes meetings into the small gaps beside
    /// existing meetings and leaves the big runs intact. It is a penalty, not a veto: if the only
    /// room is a long block, Alfred still proposes it.
    var protectDeepWork: Bool = false
    var deepWorkMinBlockMin: Int = 120
    var deepWorkPenalty: Double = 6

    var travelBufferMin: Int = 30
    /// Nothing sooner than this from now — a slot an hour out is technically free and socially useless.
    var minNoticeMin: Int = 0

    /// Which calendar a booking is written to, by time of day. Availability is always read from
    /// every calendar; only the write target is chosen.
    var workCalendar: String = ""
    var personalCalendar: String = ""
    var workHoursStartMin: Int = 10 * 60
    var workHoursEndMin: Int = 19 * 60

    /// Anything the compiler understood but could not encode, surfaced to the user verbatim so a
    /// silently-dropped preference is visible rather than mysterious.
    var notes: [String] = []

    enum CodingKeys: String, CodingKey {
        case windows, workdays, notes
        case meetingStartMin = "meeting_start_min"
        case meetingEndMin = "meeting_end_min"
        case ignoreTitles = "ignore_titles"
        case protectDeepWork = "protect_deep_work"
        case deepWorkMinBlockMin = "deep_work_min_block_min"
        case deepWorkPenalty = "deep_work_penalty"
        case travelBufferMin = "travel_buffer_min"
        case minNoticeMin = "min_notice_min"
        case workCalendar = "work_calendar"
        case personalCalendar = "personal_calendar"
        case workHoursStartMin = "work_hours_start_min"
        case workHoursEndMin = "work_hours_end_min"
    }

    init() {}

    /// As with `Window`: absent keys take their defaults rather than failing the decode, so the
    /// compiler can legitimately return only the fields the user actually described.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func i(_ k: CodingKeys, _ d: Int) -> Int { ((try? c.decodeIfPresent(Int.self, forKey: k)) as? Int) ?? d }
        func s(_ k: CodingKeys, _ d: String) -> String { ((try? c.decodeIfPresent(String.self, forKey: k)) as? String) ?? d }
        func b(_ k: CodingKeys, _ d: Bool) -> Bool { ((try? c.decodeIfPresent(Bool.self, forKey: k)) as? Bool) ?? d }

        meetingStartMin = i(.meetingStartMin, 9 * 60)
        meetingEndMin = i(.meetingEndMin, 18 * 60)
        workdays = ((try? c.decodeIfPresent([Int].self, forKey: .workdays)) as? [Int]) ?? [1, 2, 3, 4, 5]
        windows = ((try? c.decodeIfPresent([Window].self, forKey: .windows)) as? [Window]) ?? []
        ignoreTitles = ((try? c.decodeIfPresent([String].self, forKey: .ignoreTitles)) as? [String])
            ?? ["block", "hold", "focus", "ooo", "lunch"]
        protectDeepWork = b(.protectDeepWork, false)
        deepWorkMinBlockMin = i(.deepWorkMinBlockMin, 120)
        deepWorkPenalty = ((try? c.decodeIfPresent(Double.self, forKey: .deepWorkPenalty)) as? Double) ?? 6
        travelBufferMin = i(.travelBufferMin, 30)
        minNoticeMin = i(.minNoticeMin, 0)
        workCalendar = s(.workCalendar, "")
        personalCalendar = s(.personalCalendar, "")
        workHoursStartMin = i(.workHoursStartMin, 10 * 60)
        workHoursEndMin = i(.workHoursEndMin, 19 * 60)
        notes = ((try? c.decodeIfPresent([String].self, forKey: .notes)) as? [String]) ?? []
    }

    /// Today's behaviour, used whenever there is no prose or the compile fails.
    static let fallback = SchedulePrefSpec()

    /// Shown in the UI as placeholder text and returned by the API when nothing is set yet. It is
    /// deliberately written the way someone actually talks about their week, not as a form — the
    /// point is that a user can edit a sentence of it and be done.
    static let suggestedText = """
    I take external meetings late morning and late afternoon — roughly 11am to 1pm, \
    and 4pm to 6:30pm. Before 10am is mine; don't put anything there. \
    I'm at the gym most mornings until 9:30 and that's immovable.

    Fridays I keep clear for thinking — only schedule there if there's genuinely nothing else. \
    No meetings at weekends.

    Lunch around 1:45 is a soft hold, you can book over it if you have to. \
    Anything titled 'focus' or 'block' is also soft.

    Leave me 30 minutes either side of anything in person, and don't propose \
    something less than a day away.

    Work meetings go on my work calendar, personal ones on my personal calendar.
    """

    // MARK: - Derived

    /// Whether a slot at this time is inside a hard-excluded window.
    func isHardBlocked(_ start: Date, _ end: Date, _ cal: Calendar) -> Bool {
        for w in windows where w.hard {
            if Self.overlapsWindow(w, start, end, cal) { return true }
        }
        return false
    }

    /// Total weight of every soft window this slot touches.
    func windowScore(_ start: Date, _ end: Date, _ cal: Calendar) -> (score: Double, labels: [String]) {
        var total = 0.0
        var hits: [String] = []
        for w in windows where !w.hard {
            if Self.overlapsWindow(w, start, end, cal) {
                total += w.weight
                if !w.label.isEmpty { hits.append(w.label) }
            }
        }
        return (total, hits)
    }

    private static func overlapsWindow(_ w: Window, _ start: Date, _ end: Date, _ cal: Calendar) -> Bool {
        let goWeekday = cal.component(.weekday, from: start) - 1
        if !w.days.isEmpty && !w.days.contains(goWeekday) { return false }
        let day = cal.startOfDay(for: start)
        let wStart = day.addingTimeInterval(Double(w.startMin) * 60)
        let wEnd = day.addingTimeInterval(Double(w.endMin) * 60)
        return start < wEnd && wStart < end
    }

    /// Clamp anything a model might have produced into a usable shape. Invalid pieces are dropped
    /// with a note rather than failing the whole compile — one nonsensical window should not cost
    /// the user every other preference they wrote.
    func validated() -> SchedulePrefSpec {
        var s = self
        var notes = s.notes

        func clampMin(_ v: Int, _ dflt: Int) -> Int { (v >= 0 && v <= 24 * 60) ? v : dflt }
        s.meetingStartMin = clampMin(s.meetingStartMin, 9 * 60)
        s.meetingEndMin = clampMin(s.meetingEndMin, 18 * 60)
        if s.meetingEndMin <= s.meetingStartMin {
            notes.append("Meeting hours were inverted or empty; using 09:00–18:00.")
            s.meetingStartMin = 9 * 60; s.meetingEndMin = 18 * 60
        }

        s.workdays = Array(Set(s.workdays.filter { $0 >= 0 && $0 <= 6 })).sorted()
        if s.workdays.isEmpty {
            notes.append("No workdays survived validation; using Mon–Fri.")
            s.workdays = [1, 2, 3, 4, 5]
        }

        let before = s.windows.count
        s.windows = s.windows.compactMap { w in
            var w = w
            w.days = Array(Set(w.days.filter { $0 >= 0 && $0 <= 6 })).sorted()
            guard w.startMin >= 0, w.endMin <= 24 * 60, w.endMin > w.startMin else { return nil }
            if !w.weight.isFinite { w.weight = 0 }
            w.weight = max(-50, min(50, w.weight))
            return w
        }
        if s.windows.count != before {
            notes.append("Dropped \(before - s.windows.count) time window(s) that did not describe a real span.")
        }

        s.deepWorkMinBlockMin = max(30, min(8 * 60, s.deepWorkMinBlockMin))
        if !s.deepWorkPenalty.isFinite { s.deepWorkPenalty = 6 }
        s.deepWorkPenalty = max(0, min(50, s.deepWorkPenalty))
        s.travelBufferMin = max(0, min(180, s.travelBufferMin))
        s.minNoticeMin = max(0, min(14 * 24 * 60, s.minNoticeMin))
        s.ignoreTitles = s.ignoreTitles.map { $0.lowercased() }.filter { !$0.isEmpty }
        s.notes = notes
        return s
    }
}

/// Compiles the user's prose into a `SchedulePrefSpec`.
final class SchedulePrefCompiler {
    private let ai: ClaudeAIService
    private let model: String?

    /// Bumped whenever the prompt below changes in a way that would read existing prose
    /// differently. A stored spec compiled by an older version is recompiled on next access —
    /// otherwise a fix to the compiler never reaches anyone who already saved their preferences,
    /// and their settings stay frozen at whatever the compiler understood the day they wrote them.
    static let version = 2

    init(ai: ClaudeAIService, model: String? = nil) { self.ai = ai; self.model = model }

    /// Returns the compiled spec, or nil if the model could not be reached or produced nothing
    /// usable. The caller falls back to the previous spec (or `.fallback`) — never to no preferences.
    func compile(_ text: String, calendarNames: [String]) async -> SchedulePrefSpec? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let raw = try? await ai.generateText(prompt: Self.prompt(trimmed, calendarNames),
                                                   maxTokens: 2048, useModel: model) else { return nil }
        guard let data = Self.extractJSON(raw).data(using: .utf8),
              let spec = try? JSONDecoder().decode(SchedulePrefSpec.self, from: data) else { return nil }
        return spec.validated()
    }

    private static func prompt(_ text: String, _ calendarNames: [String]) -> String {
        """
        Turn this person's description of how they like to be scheduled into JSON.

        THEIR DESCRIPTION:
        \(text)

        Their calendars are named: \(calendarNames.isEmpty ? "(none configured)" : calendarNames.joined(separator: ", "))

        Return ONLY a JSON object, no prose, with these fields (all optional — omit what they did
        not mention rather than inventing it):

        {
          "meeting_start_min": int,   // earliest they'll meet, minutes from midnight (9am = 540)
          "meeting_end_min": int,     // latest
          "workdays": [int],          // 0=Sun, 1=Mon … 6=Sat. Days they'll meet at all.
          "windows": [                // weighted bands that tilt the ranking
            {
              "days": [int],          // empty = every day
              "start_min": int,
              "end_min": int,
              "weight": number,       // +5..+15 strongly prefer, +1..+4 mild, negative = avoid
              "hard": bool,           // true ONLY if they said never/immovable/don't ever
              "label": "short phrase quoting their intent, e.g. 'externals late afternoon'"
            }
          ],
          "ignore_titles": [string],  // calendar titles they said are SOFT and may be booked over
          "protect_deep_work": bool,  // true if they want long free stretches kept whole
          "deep_work_min_block_min": int,
          "travel_buffer_min": int,   // gap either side of in-person meetings
          "min_notice_min": int,      // nothing sooner than this from now
          "work_calendar": string,    // one of their calendar names, or ""
          "personal_calendar": string,
          "work_hours_start_min": int,  // when work-calendar bookings apply
          "work_hours_end_min": int,
          "notes": [string]           // anything you understood but could NOT encode above
        }

        RULES
        - "hard": true means the time is removed from consideration entirely. Use it only for
          genuinely immovable things ("never", "don't ever", "immovable", "that's mine"). A mere
          preference ("I'd rather not", "ideally") is a negative weight, not hard.
        - A day they want to keep clear but not forbid (e.g. "Fridays are for thinking, only if
          there's nothing else") is a strong NEGATIVE weight on that day, not a removed workday and
          not hard.

        TIMES — convert carefully, this is the most common mistake:
          Minutes from local midnight. For a PM time, add 12 to the hour before multiplying by 60.
            9:30am = 9*60+30 = 570        11am = 11*60 = 660
            1pm   = 13*60 = 780           1:45pm = 13*60+45 = 825
            4pm   = 16*60 = 960           6:30pm = 18*60+30 = 1110   (NOT 1170)
            7:30pm = 19*60+30 = 1170
          Re-read each time you output and check the hour is what they actually said.

        - meeting_start_min / meeting_end_min are the OUTER ENVELOPE — the absolute earliest and
          latest they would ever meet. Do NOT narrow them to a preferred window. If they say
          "externals 11–1 and 4–6:30, nothing before 10", the envelope is 10:00–18:30 and the two
          preferred bands are windows inside it. Narrowing the envelope silently forbids times
          they never objected to.
        - A named calendar title they call soft, optional, or bookable-over ("lunch is a soft hold",
          "anything marked focus") belongs in ignore_titles. Keep the existing defaults
          (block, hold, focus, ooo, lunch) unless they explicitly say one of those is NOT soft, and
          add whatever else they name. A soft TITLE is not an avoid window — the whole point is that
          the event may be scheduled over wherever it happens to sit.
        - A recurring commitment named with a TIME and no title ("gym until 9:30") is a hard window.
          A commitment named by its calendar TITLE is an ignore_title. Some things are both.
        - Do not emit windows that another window already covers. If "nothing before 10am" is hard,
          you do not also need a hard window for the gym at 9:30.
        - Put anything you could not express — conditional rules, per-person rules, anything about
          people rather than times — into "notes" verbatim. Do not silently drop it. Do not put
          things in notes that you DID encode; notes are for what was lost.
        - Output the JSON object alone.
        """
    }

    /// Pull the first JSON object out of a model reply that may be fenced or prefaced.
    static func extractJSON(_ s: String) -> String {
        if let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}"), start < end {
            return String(s[start...end])
        }
        return s
    }
}

/// Where the prose and its compiled form live.
///
/// Deliberately its own file under ~/.alfred rather than a section of config.json: Alfred writes
/// this one (on every preference edit), config.json is hand-edited, and a programmatic write that
/// malforms config.json takes down far more than scheduling — `AppConfig.load()` returns nil and
/// every cadence silently no-ops. Keeping the two apart means a bad preferences file costs
/// preferences and nothing else.
final class SchedulePrefStore {
    static let shared = SchedulePrefStore()

    struct Stored: Codable {
        var text: String = ""
        var textHash: String = ""
        var spec: SchedulePrefSpec = .fallback
        var compiledAt: Date?
        var compileFailed: Bool = false
        var compilerVersion: Int = 0

        enum CodingKeys: String, CodingKey {
            case text, spec
            case textHash = "text_hash"
            case compiledAt = "compiled_at"
            case compileFailed = "compile_failed"
            case compilerVersion = "compiler_version"
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text = ((try? c.decodeIfPresent(String.self, forKey: .text)) as? String) ?? ""
            textHash = ((try? c.decodeIfPresent(String.self, forKey: .textHash)) as? String) ?? ""
            spec = ((try? c.decodeIfPresent(SchedulePrefSpec.self, forKey: .spec)) as? SchedulePrefSpec) ?? .fallback
            compiledAt = (try? c.decodeIfPresent(Date.self, forKey: .compiledAt)) as? Date
            compileFailed = ((try? c.decodeIfPresent(Bool.self, forKey: .compileFailed)) as? Bool) ?? false
            compilerVersion = ((try? c.decodeIfPresent(Int.self, forKey: .compilerVersion)) as? Int) ?? 0
        }
    }

    private let lock = NSLock()
    private var cache: Stored?

    private var path: String {
        let dir = AlfredPaths.dataDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "/schedule_prefs.json"
    }

    func load() -> Stored {
        lock.lock(); defer { lock.unlock() }
        if let c = cache { return c }
        guard let data = FileManager.default.contents(atPath: path) else { return Stored() }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let s = (try? dec.decode(Stored.self, from: data)) ?? Stored()
        cache = s
        return s
    }

    @discardableResult
    func save(_ s: Stored) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(s) else { return false }
        // Write through a temp file so an interrupted write cannot leave a half-parsed preferences
        // file behind — that would read as "no preferences" and silently revert the user's setup.
        let tmp = path + ".tmp"
        guard (try? data.write(to: URL(fileURLWithPath: tmp))) != nil else { return false }
        _ = try? FileManager.default.removeItem(atPath: path)
        guard (try? FileManager.default.moveItem(atPath: tmp, toPath: path)) != nil else { return false }
        cache = s
        return true
    }

    /// The spec in force: the compiled prose if there is any, otherwise today's defaults.
    func spec() -> SchedulePrefSpec { load().spec }

    static func hash(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        var h: UInt64 = 5381
        for b in t.utf8 { h = (h &* 33) &+ UInt64(b) }
        return String(h, radix: 16)
    }
}
