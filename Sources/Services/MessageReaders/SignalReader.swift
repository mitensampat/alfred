import Foundation
import SQLite3
import Security
import CommonCrypto

/// Reads Signal Desktop messages — the FDA-free message source.
///
/// Signal's DB lives in `~/Library/Application Support/Signal` (NOT a TCC-protected
/// location, so no Full Disk Access), but it is SQLCipher-encrypted. The key is protected
/// by the macOS Keychain via Chromium's OSCrypt: config.json holds an `encryptedKey`
/// (`v10` + AES-128-CBC ciphertext) whose AES key is PBKDF2(keychain "Signal Safe Storage"
/// password, "saltysalt", 1003). We derive the real SQLCipher key here (CommonCrypto), then
/// hand it to the isolated `signal-decrypt` helper (the only thing that links SQLCipher) to
/// produce a temporary PLAINTEXT copy this class reads with the app's normal sqlite.
///
/// Net permission cost: one Keychain grant, no Full Disk Access.
class SignalReader {
    private let dbPath: String        // the ENCRYPTED source db
    private var db: OpaquePointer?    // open handle to the decrypted TEMP copy
    private var tempPath: String?

    init(dbPath: String) {
        self.dbPath = (dbPath as NSString).expandingTildeInPath
    }

    func connect() throws {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw MessageReaderError.databaseNotFound(dbPath)
        }
        guard let key = deriveSQLCipherKey() else {
            throw MessageReaderError.connectionFailed("Signal (could not derive key — is the Keychain grant allowed?)")
        }
        guard let helper = helperPath() else {
            throw MessageReaderError.connectionFailed("Signal (signal-decrypt helper not found next to Alfred)")
        }

        let out = (NSTemporaryDirectory() as NSString).appendingPathComponent("alfred-signal-\(ProcessInfo.processInfo.globallyUniqueString).sqlite")
        try runHelper(helper, src: dbPath, out: out, key: key)

        var handle: OpaquePointer?
        guard sqlite3_open_v2(out, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            try? FileManager.default.removeItem(atPath: out)
            throw MessageReaderError.connectionFailed("Signal (decrypted copy unreadable)")
        }
        self.db = handle
        self.tempPath = out
    }

    func disconnect() {
        if let db = db { sqlite3_close(db); self.db = nil }
        if let t = tempPath { try? FileManager.default.removeItem(atPath: t); tempPath = nil }
    }

    // MARK: - Key derivation (Keychain → OSCrypt → SQLCipher key)

    private func deriveSQLCipherKey() -> String? {
        // 1. "Signal Safe Storage" password from Keychain (triggers the Allow prompt).
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Signal Safe Storage",
            kSecAttrAccount as String: "Signal",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let pw = result as? Data else { return nil }

        // 2. encryptedKey from config.json (Signal dir is db's grandparent: …/Signal/sql/db.sqlite).
        let signalDir = ((dbPath as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        let cfgPath = (signalDir as NSString).appendingPathComponent("config.json")
        guard let cfgData = FileManager.default.contents(atPath: cfgPath),
              let json = try? JSONSerialization.jsonObject(with: cfgData) as? [String: Any],
              let encHex = json["encryptedKey"] as? String,
              let enc = Data(hexString: encHex),
              enc.count > 3, enc.prefix(3) == Data("v10".utf8) else { return nil }
        let ciphertext = enc.subdata(in: 3..<enc.count)

        // 3. AES key = PBKDF2-HMAC-SHA1(pw, "saltysalt", 1003, 16).
        let salt = Data("saltysalt".utf8)
        var aesKey = [UInt8](repeating: 0, count: 16)
        let kdf = pw.withUnsafeBytes { pwPtr in
            salt.withUnsafeBytes { saltPtr in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pwPtr.bindMemory(to: Int8.self).baseAddress, pw.count,
                    saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                    &aesKey, aesKey.count)
            }
        }
        guard kdf == kCCSuccess else { return nil }

        // 4. AES-128-CBC decrypt (IV = 16 × 0x20), no padding, strip PKCS7 → the SQLCipher key.
        let iv = [UInt8](repeating: 0x20, count: 16)
        var outBuf = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        var moved = 0
        let cs = ciphertext.withUnsafeBytes { ctPtr in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(0),
                    aesKey, aesKey.count, iv,
                    ctPtr.baseAddress, ciphertext.count,
                    &outBuf, outBuf.count, &moved)
        }
        guard cs == kCCSuccess, moved > 0 else { return nil }
        var out = Array(outBuf.prefix(moved))
        if let pad = out.last, pad >= 1, pad <= 16, out.count >= Int(pad) { out.removeLast(Int(pad)) }  // strip PKCS7
        let keyStr = String(bytes: out, encoding: .ascii)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (keyStr?.count == 64) ? keyStr : nil
    }

    // MARK: - Helper invocation

    private func helperPath() -> String? {
        // Bundled next to the main binary (Contents/MacOS/signal-decrypt) …
        if let exe = Bundle.main.executablePath {
            let p = ((exe as NSString).deletingLastPathComponent as NSString).appendingPathComponent("signal-decrypt")
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        // … or the dev build output.
        let dev = FileManager.default.currentDirectoryPath + "/.build/release/signal-decrypt"
        if FileManager.default.isExecutableFile(atPath: dev) { return dev }
        return nil
    }

    private func runHelper(_ helper: String, src: String, out: String, key: String) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: helper)
        proc.arguments = [src, out]
        let stdinPipe = Pipe(), errPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardError = errPipe
        try proc.run()
        stdinPipe.fileHandleForWriting.write(Data((key + "\n").utf8))
        stdinPipe.fileHandleForWriting.closeFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw MessageReaderError.connectionFailed("Signal decrypt failed: \(err.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    // MARK: - Reading (from the plaintext temp copy)

    func fetchMessages(since: Date) throws -> [Message] {
        guard let db = db else { throw MessageReaderError.notConnected }
        var messages: [Message] = []
        let sinceTs = Int64(since.timeIntervalSince1970 * 1000)

        // Only real conversation messages (incoming/outgoing); skip call/group-change rows.
        let sql = """
        SELECT m.id, m.body, m.sent_at, m.type, m.conversationId,
               c.name, c.profileFullName, c.e164
        FROM messages m
        LEFT JOIN conversations c ON m.conversationId = c.id
        WHERE m.sent_at > ? AND m.type IN ('incoming','outgoing') AND m.body IS NOT NULL AND m.body != ''
        ORDER BY m.sent_at DESC
        LIMIT 5000
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MessageReaderError.queryFailed("Signal")
        }
        sqlite3_bind_int64(stmt, 1, sinceTs)
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? UUID().uuidString
            let body = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let sentAt = sqlite3_column_int64(stmt, 2)
            let type = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "incoming"
            let convId = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
            let name = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
            let profile = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
            let e164 = sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? convId
            let display = name ?? profile
            let fromMe = (type == "outgoing")
            messages.append(Message(
                id: "signal_\(id)", platform: .signal,
                sender: fromMe ? "me" : e164, senderName: fromMe ? nil : display,
                recipient: fromMe ? e164 : "me", content: body,
                timestamp: Date(timeIntervalSince1970: Double(sentAt) / 1000),
                direction: fromMe ? .outgoing : .incoming,
                chatId: convId, isRead: true, hasAttachment: false))
        }
        return messages
    }

    func fetchThreads(since: Date) throws -> [MessageThread] {
        let grouped = Dictionary(grouping: try fetchMessages(since: since), by: { $0.chatId })
        return grouped.compactMap { convId, msgs -> MessageThread? in
            let sorted = msgs.sorted { $0.timestamp > $1.timestamp }
            guard let last = sorted.first else { return nil }
            let name = sorted.compactMap { $0.senderName }.first
            return MessageThread(
                contactIdentifier: convId, contactName: name, platform: .signal,
                messages: sorted,
                unreadCount: 0,
                lastMessageDate: last.timestamp)
        }.sorted { $0.lastMessageDate > $1.lastMessageDate }
    }
}

private extension Data {
    init?(hexString: String) {
        let s = hexString.count % 2 == 0 ? hexString : "0" + hexString
        var d = Data(capacity: s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            guard let b = UInt8(s[idx..<next], radix: 16) else { return nil }
            d.append(b)
            idx = next
        }
        self = d
    }
}
