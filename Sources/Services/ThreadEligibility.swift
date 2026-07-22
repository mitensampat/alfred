import Foundation

/// Decides which message threads are worth feeding to reflection extraction.
///
/// Ingestion used to be gated on a hand-maintained favourites list, which capped the
/// decision corpus at ten people. The replacement is behavioural: **a thread earns its
/// place by how much you write in it.** A thread you send thirty messages to is where
/// you are deciding things; 118-in / 4-out is a broadcast you happen to receive.
///
/// That inverts the usual filter. Inbound volume — the thing that makes a thread feel
/// busy — is deliberately ignored, because it measures other people's behaviour, not
/// yours. Only your own contribution counts toward eligibility.
struct ThreadEligibility {

    /// Messages you sent in the window. Below this, there's no judgement to extract.
    var minOutbound: Int = 12
    /// Characters *you* wrote. Filters threads that are real but transactional —
    /// thirty messages of "ok", "done", "👍" clear the count but carry no reasoning.
    var minOutboundChars: Int = 700
    /// Threads never ingested regardless of participation (personal, family, private).
    var excluded: Set<String> = []
    /// Ceiling per run — each eligible thread costs one extraction call.
    var maxPerRun: Int = 25

    struct Verdict {
        let name: String
        let identifier: String
        let isGroup: Bool
        let outbound: Int
        let inbound: Int
        let outboundChars: Int
        let isFavorite: Bool
        let eligible: Bool
        let reason: String

        /// Your share of the conversation — diagnostic only, never a gate. A thread can
        /// be 5% yours and still be where you made the call.
        var yourShare: Double {
            let total = outbound + inbound
            return total > 0 ? Double(outbound) / Double(total) : 0
        }
    }

    func evaluate(_ thread: MessageThread, isFavorite: Bool) -> Verdict {
        let name = thread.contactName ?? thread.contactIdentifier
        let isGroup = thread.contactIdentifier.contains("@g.us")

        var outbound = 0, inbound = 0, outboundChars = 0
        for m in thread.messages {
            if m.direction == .outgoing {
                outbound += 1
                outboundChars += m.content.trimmingCharacters(in: .whitespacesAndNewlines).count
            } else {
                inbound += 1
            }
        }

        func verdict(_ ok: Bool, _ why: String) -> Verdict {
            Verdict(name: name, identifier: thread.contactIdentifier, isGroup: isGroup,
                    outbound: outbound, inbound: inbound, outboundChars: outboundChars,
                    isFavorite: isFavorite, eligible: ok, reason: why)
        }

        // Exclusion always wins — an opt-out has to be absolute to be trustworthy.
        if excluded.contains(name) || excluded.contains(thread.contactIdentifier) {
            return verdict(false, "excluded")
        }
        // Favourites are grandfathered so widening never loses existing coverage.
        if isFavorite { return verdict(true, "favourite") }

        if outbound < minOutbound {
            return verdict(false, "you sent \(outbound), need \(minOutbound)")
        }
        if outboundChars < minOutboundChars {
            return verdict(false, "you wrote \(outboundChars) chars, need \(minOutboundChars)")
        }
        return verdict(true, "you sent \(outbound) messages, \(outboundChars) chars")
    }

    /// Rank eligible threads by how much you put into them, then cap.
    /// Favourites sort first so they're never crowded out by the cap.
    func select(_ verdicts: [Verdict]) -> [Verdict] {
        verdicts.filter { $0.eligible }
            .sorted {
                if $0.isFavorite != $1.isFavorite { return $0.isFavorite }
                return $0.outboundChars > $1.outboundChars
            }
            .prefix(maxPerRun)
            .map { $0 }
    }

    /// Load thresholds and exclusions from config without touching the typed model.
    static func fromConfig() -> ThreadEligibility {
        var e = ThreadEligibility()
        let path = NSString(string: "~/.config/alfred/config.json").expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let r = root["reflection"] as? [String: Any] else { return e }
        if let v = r["min_outbound"] as? Int { e.minOutbound = v }
        if let v = r["min_outbound_chars"] as? Int { e.minOutboundChars = v }
        if let v = r["max_threads_per_run"] as? Int { e.maxPerRun = v }
        if let v = r["exclude_threads"] as? [String] { e.excluded = Set(v) }
        return e
    }
}
