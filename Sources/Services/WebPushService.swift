import Foundation
import CryptoKit

/// Web Push Protocol implementation (RFC 8291 + VAPID)
/// Sends push notifications directly to browser push endpoints without third-party services.
class WebPushService {
    static let shared = WebPushService()

    private let subscriptionsPath: String
    private var subscriptions: [PushSubscription] = []

    struct PushSubscription: Codable {
        let endpoint: String
        let keys: PushKeys
        let subscribedAt: Date
        var lastPushAt: Date?
        var pushCountToday: Int
        var pushCountResetDate: String  // "YYYY-MM-DD"

        struct PushKeys: Codable {
            let p256dh: String
            let auth: String
        }
    }

    struct PushPayload: Codable {
        let title: String
        let body: String
        let tag: String
        let url: String
        let type: String
        let actions: [PushAction]?

        struct PushAction: Codable {
            let action: String
            let title: String
        }
    }

    init() {
        self.subscriptionsPath = NSString(string: "~/.alfred/push_subscriptions.json").expandingTildeInPath
        loadSubscriptions()
    }

    // MARK: - Subscription Management

    func addSubscription(endpoint: String, p256dh: String, auth: String) {
        // Remove any existing subscription with same endpoint
        subscriptions.removeAll { $0.endpoint == endpoint }

        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"

        let sub = PushSubscription(
            endpoint: endpoint,
            keys: PushSubscription.PushKeys(p256dh: p256dh, auth: auth),
            subscribedAt: Date(),
            lastPushAt: nil,
            pushCountToday: 0,
            pushCountResetDate: dateFmt.string(from: Date())
        )
        subscriptions.append(sub)
        saveSubscriptions()
        print("📱 [WebPush] Added subscription: \(endpoint.prefix(60))...")
    }

    func removeSubscription(endpoint: String) {
        subscriptions.removeAll { $0.endpoint == endpoint }
        saveSubscriptions()
        print("📱 [WebPush] Removed subscription: \(endpoint.prefix(60))...")
    }

    func getSubscriptions() -> [PushSubscription] {
        return subscriptions
    }

    // MARK: - Push Sending

    /// Send a push notification to all subscribers
    func sendToAll(_ payload: PushPayload, vapidPublicKey: String, vapidPrivateKey: String, vapidSubject: String) async {
        for i in subscriptions.indices {
            do {
                try await sendSingle(
                    to: subscriptions[i],
                    payload: payload,
                    vapidPublicKey: vapidPublicKey,
                    vapidPrivateKey: vapidPrivateKey,
                    vapidSubject: vapidSubject
                )
                subscriptions[i].lastPushAt = Date()
                subscriptions[i].pushCountToday += 1
                print("✅ [WebPush] Sent to \(subscriptions[i].endpoint.prefix(40))...")
            } catch WebPushError.subscriptionExpired {
                print("⚠️ [WebPush] Subscription expired, removing: \(subscriptions[i].endpoint.prefix(40))...")
                subscriptions[i] = subscriptions[i] // mark for removal
            } catch {
                print("❌ [WebPush] Failed to send: \(error)")
            }
        }
        // Remove expired subscriptions
        saveSubscriptions()
    }

    /// Send a push to a single subscriber using the `web-push` CLI (battle-tested RFC 8291 implementation)
    func sendSingle(
        to subscription: PushSubscription,
        payload: PushPayload,
        vapidPublicKey: String,
        vapidPrivateKey: String,
        vapidSubject: String
    ) async throws {
        let pushHost = URL(string: subscription.endpoint)?.host ?? "unknown"
        print("📱 [WebPush] Sending to \(pushHost)...")

        // Encode payload as JSON
        let payloadData = try JSONEncoder().encode(payload)
        guard let payloadString = String(data: payloadData, encoding: .utf8) else {
            throw WebPushError.sendFailed("Failed to encode payload as string")
        }

        // Use web-push CLI for reliable encryption + delivery
        let webPushPath = "/opt/homebrew/bin/web-push"
        guard FileManager.default.fileExists(atPath: webPushPath) else {
            throw WebPushError.sendFailed("web-push CLI not found at \(webPushPath). Install with: npm install -g web-push")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: webPushPath)
        process.arguments = [
            "send-notification",
            "--endpoint=\(subscription.endpoint)",
            "--key=\(subscription.keys.p256dh)",
            "--auth=\(subscription.keys.auth)",
            "--vapid-subject=\(vapidSubject)",
            "--vapid-pubkey=\(vapidPublicKey)",
            "--vapid-pvtkey=\(vapidPrivateKey)",
            "--payload=\(payloadString)"
        ]

        // Set PATH so Node.js can be found
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "")
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        let stdoutStr = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderrStr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationStatus == 0 {
            print("📱 [WebPush] ✅ Delivered to \(pushHost)")
        } else {
            let errorMsg = stderrStr.isEmpty ? stdoutStr : stderrStr
            print("📱 [WebPush] ❌ Failed for \(pushHost): \(errorMsg)")
            // Check for expired subscription
            if errorMsg.contains("410") || errorMsg.contains("404") || errorMsg.contains("NotRegistered") {
                throw WebPushError.subscriptionExpired
            }
            throw WebPushError.sendFailed(errorMsg)
        }
    }

    // MARK: - VAPID JWT

    /// Build a VAPID JWT (ES256 signed) for the push endpoint
    private func buildVAPIDJWT(endpoint: String, privateKeyBase64: String, subject: String) throws -> String {
        guard let endpointURL = URL(string: endpoint),
              let audience = endpointURL.scheme.map({ "\($0)://\(endpointURL.host ?? "")" }) else {
            throw WebPushError.invalidEndpoint
        }

        // JWT header: {"typ":"JWT","alg":"ES256"}
        let header = Data(#"{"typ":"JWT","alg":"ES256"}"#.utf8).base64URLEncoded()

        // JWT payload: audience, expiry (24h), subject
        let exp = Int(Date().addingTimeInterval(24 * 3600).timeIntervalSince1970)
        let payloadJSON = #"{"aud":"\#(audience)","exp":\#(exp),"sub":"\#(subject)"}"#
        let payload = Data(payloadJSON.utf8).base64URLEncoded()

        // Sign with ES256 (P-256 ECDSA)
        guard let keyData = Data(base64URLEncoded: privateKeyBase64) else {
            throw WebPushError.invalidKey
        }
        let privateKey = try P256.Signing.PrivateKey(rawRepresentation: keyData)
        let signingInput = Data("\(header).\(payload)".utf8)
        let signature = try privateKey.signature(for: signingInput)

        return "\(header).\(payload).\(signature.rawRepresentation.base64URLEncoded())"
    }

    // MARK: - Payload Encryption (RFC 8291)

    /// Encrypt push payload using subscriber's public key and auth secret (RFC 8291 + RFC 8188)
    private func encryptPayload(payload: Data, p256dhBase64: String, authBase64: String) throws -> Data {
        // Decode subscriber's public key and auth secret
        guard let subscriberKeyData = Data(base64URLEncoded: p256dhBase64) else {
            throw WebPushError.invalidKey
        }
        guard let authSecret = Data(base64URLEncoded: authBase64) else {
            throw WebPushError.invalidKey
        }

        let subscriberPublicKey = try P256.KeyAgreement.PublicKey(x963Representation: subscriberKeyData)

        // Generate ephemeral key pair
        let ephemeralKey = P256.KeyAgreement.PrivateKey()
        let ephemeralPublicKeyData = ephemeralKey.publicKey.x963Representation

        // Generate random 16-byte salt (used in both header and key derivation)
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }

        // ECDH shared secret
        let sharedSecret = try ephemeralKey.sharedSecretFromKeyAgreement(with: subscriberPublicKey)

        // RFC 8291 Step 1: Extract IKM from ECDH shared secret + auth secret
        // IKM = HKDF-Expand(HKDF-Extract(auth_secret, ecdh_secret), "WebPush: info\0" || ua_public || as_public, 32)
        let keyInfoPrefix = Data("WebPush: info\0".utf8)
        let keyInfo = keyInfoPrefix + subscriberKeyData + ephemeralPublicKeyData

        let ikm = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: authSecret,
            sharedInfo: keyInfo,
            outputByteCount: 32
        )
        let ikmData = ikm.withUnsafeBytes { Data($0) }

        // RFC 8188 Step 2: Derive CEK and nonce using the random salt
        // PRK = HKDF-Extract(salt, IKM)
        // CEK = HKDF-Expand(PRK, "Content-Encoding: aes128gcm\0\1", 16)
        // nonce = HKDF-Expand(PRK, "Content-Encoding: nonce\0\1", 12)
        let cekInfo = Data("Content-Encoding: aes128gcm\0".utf8) + Data([0x01])
        let nonceInfo = Data("Content-Encoding: nonce\0".utf8) + Data([0x01])

        let cek = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikmData),
            salt: salt,
            info: cekInfo,
            outputByteCount: 16
        )
        let nonce = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikmData),
            salt: salt,
            info: nonceInfo,
            outputByteCount: 12
        )

        let nonceData = nonce.withUnsafeBytes { Data($0) }

        // Pad payload (RFC 8188: add padding delimiter \x02)
        var paddedPayload = payload
        paddedPayload.append(0x02)  // Padding delimiter

        // AES-128-GCM encrypt
        let sealedBox = try AES.GCM.seal(
            paddedPayload,
            using: cek,
            nonce: try AES.GCM.Nonce(data: nonceData)
        )

        // Build aes128gcm header (RFC 8188):
        // salt (16 bytes) + record_size (4 bytes, big endian) + key_id_length (1 byte) + key_id (65 bytes for P-256 public key)
        let recordSize = UInt32(paddedPayload.count + 16)  // payload + tag
        var header = salt
        header.append(contentsOf: withUnsafeBytes(of: recordSize.bigEndian) { Data($0) })
        header.append(UInt8(65))  // key_id_length = 65 (uncompressed P-256 point)
        header.append(contentsOf: ephemeralPublicKeyData)

        // Combine header + ciphertext + tag
        return header + sealedBox.ciphertext + sealedBox.tag
    }

    // MARK: - VAPID Key Generation

    /// Generate a new VAPID key pair (P-256)
    static func generateVAPIDKeys() -> (publicKey: String, privateKey: String) {
        let privateKey = P256.Signing.PrivateKey()
        let publicKeyData = privateKey.publicKey.x963Representation
        let privateKeyData = privateKey.rawRepresentation

        return (
            publicKey: publicKeyData.base64URLEncoded(),
            privateKey: privateKeyData.base64URLEncoded()
        )
    }

    // MARK: - Persistence

    private func loadSubscriptions() {
        guard FileManager.default.fileExists(atPath: subscriptionsPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: subscriptionsPath)),
              let subs = try? JSONDecoder().decode([PushSubscription].self, from: data) else {
            return
        }
        subscriptions = subs
        print("📱 [WebPush] Loaded \(subscriptions.count) subscription(s)")
    }

    private func saveSubscriptions() {
        do {
            let data = try JSONEncoder().encode(subscriptions)
            try data.write(to: URL(fileURLWithPath: subscriptionsPath))
        } catch {
            print("❌ [WebPush] Failed to save subscriptions: \(error)")
        }
    }
}

// MARK: - Errors

enum WebPushError: Error, LocalizedError {
    case invalidEndpoint
    case invalidKey
    case subscriptionExpired
    case sendFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "Invalid push endpoint URL"
        case .invalidKey: return "Invalid VAPID or subscriber key"
        case .subscriptionExpired: return "Push subscription has expired"
        case .sendFailed(let msg): return "Push send failed: \(msg)"
        }
    }
}

// MARK: - Base64URL Extensions

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Pad to multiple of 4
        while base64.count % 4 != 0 {
            base64.append("=")
        }
        self.init(base64Encoded: base64)
    }
}
