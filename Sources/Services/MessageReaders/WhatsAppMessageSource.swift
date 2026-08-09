import Foundation

/// Common surface for WhatsApp message reading, so the app can swap between the local
/// WhatsApp Desktop DB (Full Disk Access) and the whatsmeow bridge (FDA-free) transparently.
/// Both `WhatsAppReader` and `WhatsAppBridgeReader` conform; callers go through
/// `WhatsAppSource.reader(config:)` and never care which one they got.
protocol WhatsAppMessageSource: AnyObject {
    func connect() throws
    func disconnect()
    func fetchMessages(since: Date) throws -> [Message]
    func fetchThreads(since: Date) throws -> [MessageThread]
    func fetchThreadByName(_ searchName: String, since: Date) throws -> MessageThread?
    func fuzzySearchThreadNames(_ searchName: String, limit: Int) throws -> [(name: String, score: Double)]
}

/// Picks the active WhatsApp source from config. `auto` (default) uses the bridge when it's
/// reachable AND paired, otherwise falls back to the local DB — so pairing the bridge takes
/// over seamlessly and an unpaired/absent bridge never breaks reading.
enum WhatsAppSource {
    private static var _bridgePaired = false
    private static var _lastCheck = Date.distantPast
    private static let lock = NSLock()

    static var bridgeAddr: String {
        ProcessInfo.processInfo.environment["WA_BRIDGE_ADDR"] ?? "127.0.0.1:8790"
    }

    static func reader(config: AppConfig) -> WhatsAppMessageSource {
        switch config.messaging.whatsapp.readSource {
        case "bridge":
            return WhatsAppBridgeReader.shared
        case "local_db":
            return WhatsAppReader.shared(dbPath: config.messaging.whatsapp.dbPath)
        default: // auto
            if bridgePaired() { return WhatsAppBridgeReader.shared }
            return WhatsAppReader.shared(dbPath: config.messaging.whatsapp.dbPath)
        }
    }

    /// Which source is effectively active right now — for diagnostics / health.
    static func activeSourceName(config: AppConfig) -> String {
        switch config.messaging.whatsapp.readSource {
        case "bridge": return "bridge"
        case "local_db": return "local_db"
        default: return bridgePaired() ? "bridge" : "local_db"
        }
    }

    /// Cached (60s) check of whether the bridge is reachable AND paired.
    static func bridgePaired() -> Bool {
        lock.lock()
        let fresh = Date().timeIntervalSince(_lastCheck) < 60
        let cached = _bridgePaired
        lock.unlock()
        if fresh { return cached }
        let ok = probeBridgePaired()
        lock.lock(); _bridgePaired = ok; _lastCheck = Date(); lock.unlock()
        return ok
    }

    private static func probeBridgePaired() -> Bool {
        guard let url = URL(string: "http://\(bridgeAddr)/status") else { return false }
        var paired = false
        let sem = DispatchSemaphore(value: 0)
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        URLSession.shared.dataTask(with: req) { data, _, _ in
            defer { sem.signal() }
            if let data = data,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                paired = (obj["paired"] as? Bool) == true
            }
        }.resume()
        _ = sem.wait(timeout: .now() + 3)
        return paired
    }
}

/// Reads WhatsApp messages from the local whatsmeow bridge (tools/wa-bridge) over HTTP,
/// mapping its message store into the same `Message` / `MessageThread` models the local DB
/// reader produces — a drop-in for `WhatsAppReader`. Synchronous like its sibling (callers
/// already treat WhatsApp reads as blocking); the HTTP is localhost + fast.
final class WhatsAppBridgeReader: WhatsAppMessageSource {
    static let shared = WhatsAppBridgeReader()

    private var addr: String { WhatsAppSource.bridgeAddr }

    private struct BridgeMsg: Decodable {
        let id, chat_jid, sender_jid, sender_name, chat_name, content: String
        let timestamp: Int64
        let is_from_me, is_group: Bool
    }
    private struct BridgeContact: Decodable {
        let jid, full_name, first_name, push_name: String
    }

    func connect() throws { /* bridge is a network service — nothing to open */ }
    func disconnect() { }

    private func fetch<T: Decodable>(_ path: String, timeout: TimeInterval = 20) throws -> T {
        guard let url = URL(string: "http://\(addr)\(path)") else {
            throw MessageReaderError.connectionFailed("WhatsApp bridge URL")
        }
        var outcome: Result<T, Error> = .failure(MessageReaderError.connectionFailed("WhatsApp bridge"))
        let sem = DispatchSemaphore(value: 0)
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        URLSession.shared.dataTask(with: req) { data, _, err in
            defer { sem.signal() }
            if let err = err { outcome = .failure(err); return }
            guard let data = data else {
                outcome = .failure(MessageReaderError.connectionFailed("WhatsApp bridge: no data"))
                return
            }
            do { outcome = .success(try JSONDecoder().decode(T.self, from: data)) }
            catch { outcome = .failure(error) }
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 2)
        return try outcome.get()
    }

    private func toMessages(_ bs: [BridgeMsg]) -> [Message] {
        bs.map { b in
            Message(
                id: "whatsapp_\(b.id)",
                platform: .whatsapp,
                sender: b.is_from_me ? "me" : (b.sender_jid.isEmpty ? b.chat_jid : b.sender_jid),
                senderName: b.is_from_me ? nil : (b.sender_name.isEmpty ? nil : b.sender_name),
                recipient: b.is_from_me ? b.chat_jid : "me",
                content: b.content,
                timestamp: Date(timeIntervalSince1970: TimeInterval(b.timestamp)),
                direction: b.is_from_me ? .outgoing : .incoming,
                chatId: b.chat_jid,
                isRead: true,
                hasAttachment: false
            )
        }
    }

    func fetchMessages(since: Date) throws -> [Message] {
        let bs: [BridgeMsg] = try fetch("/messages?since=\(Int(since.timeIntervalSince1970))")
        return toMessages(bs)
    }

    func fetchThreads(since: Date) throws -> [MessageThread] {
        let bs: [BridgeMsg] = try fetch("/messages?since=\(Int(since.timeIntervalSince1970))")
        var names: [String: String] = [:]
        for b in bs where !b.chat_name.isEmpty { names[b.chat_jid] = b.chat_name }
        let msgs = toMessages(bs)
        let grouped = Dictionary(grouping: msgs, by: { $0.chatId })
        return grouped.map { chatId, m in
            let sorted = m.sorted { $0.timestamp > $1.timestamp }
            return MessageThread(
                contactIdentifier: chatId,
                contactName: names[chatId],
                platform: .whatsapp,
                messages: sorted,
                unreadCount: 0,
                lastMessageDate: sorted.first?.timestamp ?? since
            )
        }.sorted { $0.lastMessageDate > $1.lastMessageDate }
    }

    func fetchThreadByName(_ searchName: String, since: Date) throws -> MessageThread? {
        let threads = try fetchThreads(since: since)
        let q = searchName.lowercased()
        return threads.first { ($0.contactName ?? "").lowercased() == q }
            ?? threads.first { ($0.contactName ?? "").lowercased().contains(q) && !$0.messages.isEmpty }
    }

    func fuzzySearchThreadNames(_ searchName: String, limit: Int) throws -> [(name: String, score: Double)] {
        let contacts: [BridgeContact] = (try? fetch("/contacts")) ?? []
        var names = Set(contacts.flatMap { [$0.full_name, $0.push_name, $0.first_name] }.filter { !$0.isEmpty })
        // also fold in recent thread names (groups etc.) from the last ~30 days
        if let bs: [BridgeMsg] = try? fetch("/messages?since=\(Int(Date().addingTimeInterval(-30*86400).timeIntervalSince1970))") {
            for b in bs where !b.chat_name.isEmpty { names.insert(b.chat_name) }
        }
        let words = searchName.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        var cands: [(name: String, score: Double)] = []
        for name in names {
            let nl = name.lowercased()
            let matched = words.filter { nl.contains($0) }.count
            let score = Double(matched) / Double(words.count)
            if score >= 0.5 { cands.append((name: name, score: score)) }
        }
        cands.sort { a, b in
            if abs(a.score - b.score) > 0.01 { return a.score > b.score }
            return a.name.count < b.name.count
        }
        return Array(cands.prefix(limit))
    }
}
