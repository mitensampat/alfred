import Foundation

/// The outbound message path the manager needs. `sendSelf` writes to the user's own WhatsApp
/// self-chat (where @schedule prompts appear); `sendTo` messages the counterpart.
protocol ScheduleSender {
    func sendTo(jid: String, text: String) async -> (ok: Bool, msgID: String)
    func sendSelf(text: String) async -> (ok: Bool, msgID: String)
}

/// Sends over the local whatsmeow bridge (tools/wa-bridge on 127.0.0.1:8790) — the same transport
/// the Desk's People replies use. The user's own JID (their self-chat) is resolved lazily so the
/// bridge's /status can supply it.
final class WABridgeSender: ScheduleSender {
    private let selfJIDProvider: () async -> String

    init(selfJIDProvider: @escaping () async -> String) { self.selfJIDProvider = selfJIDProvider }

    func sendSelf(text: String) async -> (ok: Bool, msgID: String) {
        let jid = await selfJIDProvider()
        return await sendTo(jid: jid, text: text)
    }

    func sendTo(jid: String, text: String) async -> (ok: Bool, msgID: String) {
        let addr = ProcessInfo.processInfo.environment["WA_BRIDGE_ADDR"] ?? "127.0.0.1:8790"
        guard !jid.isEmpty, let url = URL(string: "http://\(addr)/send") else { return (false, "") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["jid": jid, "message": text])
        req.timeoutInterval = 20
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return (false, "") }
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let msgID = (obj?["id"] as? String) ?? (obj?["msgID"] as? String) ?? ""
            return (true, msgID)
        } catch {
            return (false, "")
        }
    }
}
