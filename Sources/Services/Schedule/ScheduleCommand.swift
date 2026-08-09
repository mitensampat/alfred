import Foundation

/// A parsed "@schedule <name> [duration] [format] [window]" line. Brackets are optional and
/// order-insensitive after the name. Faithful port of Commit's schedule/command.go.
struct ScheduleCommand: Equatable, Codable {
    var verb: ScheduleIntent = .schedule
    var name: String = ""
    var durationMin: Int = 0        // 0 = infer
    var format: String = ""         // "", "call", "video", "in-person"
    var window: String = ""         // freeform ("this week", "tomorrow", "mon"…)
}

enum ScheduleParseError: Error, CustomStringConvertible {
    case usage(String)
    var description: String { switch self { case .usage(let s): return s } }
}

enum ScheduleCommandParser {
    static let formatWords: [String: String] = [
        "call": "call", "phone": "call",
        "video": "video", "zoom": "video", "meet": "video", "gmeet": "video", "online": "video",
        "in-person": "in-person", "inperson": "in-person", "irl": "in-person",
        "coffee": "in-person", "lunch": "in-person", "dinner": "in-person",
        "breakfast": "in-person", "walk": "in-person"
    ]

    static let windowWords: Set<String> = [
        "today", "tomorrow", "tmrw",
        "mon", "monday", "tue", "tues", "tuesday",
        "wed", "wednesday", "thu", "thurs", "thursday",
        "fri", "friday", "sat", "saturday", "sun", "sunday",
        "morning", "afternoon", "evening",
        "week", "month", "weekend",
        "this", "next", "early", "late"
    ]

    private static let durationRe = try! NSRegularExpression(
        pattern: "^(\\d+)\\s*(m|min|mins|minutes|h|hr|hrs|hour|hours)$")

    /// Minutes if `tok` is a lone duration ("30m", "1h", "45min"), else nil. Hours ×60.
    static func matchDuration(_ tok: String) -> Int? {
        let range = NSRange(tok.startIndex..., in: tok)
        guard let m = durationRe.firstMatch(in: tok, range: range),
              let nR = Range(m.range(at: 1), in: tok), let uR = Range(m.range(at: 2), in: tok),
              var n = Int(tok[nR]) else { return nil }
        if tok[uR].hasPrefix("h") { n *= 60 }
        return n
    }

    private static func clean(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",."))
    }

    /// Parse the text AFTER the "@schedule" prefix.
    static func parse(_ rest0: String) throws -> ScheduleCommand {
        let rest = rest0.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else {
            throw ScheduleParseError.usage("usage: @schedule <name> [duration] [format] [window]")
        }
        var cmd = ScheduleCommand()
        var fields = rest.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
        if let f0 = fields.first?.lowercased() {
            if f0 == "move" { cmd.verb = .move; fields.removeFirst() }
            else if f0 == "cancel" { cmd.verb = .cancel; fields.removeFirst() }
        }
        guard !fields.isEmpty else {
            throw ScheduleParseError.usage("who? usage: @schedule \(cmd.verb.rawValue) <name>")
        }

        // The name runs until the first token recognizable as duration, format, or window.
        // Everything recognized afterward fills those fields; leftover unrecognized tail tokens
        // extend the window text.
        var nameParts: [String] = [], windowParts: [String] = []
        var inName = true
        var i = 0
        while i < fields.count {
            let tok = clean(fields[i])

            // duration: "30m", "1h", or "30 min"
            if let n = matchDuration(tok) {
                cmd.durationMin = n; inName = false; i += 1; continue
            }
            if let n = Int(tok), i + 1 < fields.count {
                let next = clean(fields[i + 1])
                let isDurWord = matchDuration("1" + next) != nil
                    || ["min", "mins", "minutes", "hours", "hour"].contains(next)
                if isDurWord {
                    cmd.durationMin = next.hasPrefix("h") ? n * 60 : n
                    inName = false; i += 2; continue
                }
            }
            if let f = formatWords[tok] { cmd.format = f; inName = false; i += 1; continue }
            if windowWords.contains(tok) { windowParts.append(tok); inName = false; i += 1; continue }

            if inName { nameParts.append(fields[i]) } else { windowParts.append(tok) }
            i += 1
        }

        cmd.name = nameParts.joined(separator: " ")
        if cmd.name.hasPrefix("@") { cmd.name.removeFirst() }
        cmd.window = windowParts.joined(separator: " ")
        guard !cmd.name.isEmpty else {
            throw ScheduleParseError.usage("who? usage: @schedule <name> [duration] [format] [window]")
        }
        return cmd
    }
}
