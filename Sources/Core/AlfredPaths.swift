import Foundation

/// Where Alfred keeps its data and its configuration — in one place, and overridable.
///
/// Every store used to resolve `~/.alfred` for itself, 99 times across 43 files. That is fine
/// until you want to run the same build against a copy of the data: an eval that scores a build
/// has to read a corpus that does not change underneath it, and has to be free to exercise write
/// paths without touching anything real. With the paths scattered, neither is possible, and two
/// runs of identical code produce different scores — which destroys the only number an eval
/// exists to produce.
///
/// So: one resolver, two environment variables, and a safety flag.
///
/// - `ALFRED_DIR` — the data directory (databases, agent memory, caches). Default `~/.alfred`.
/// - `ALFRED_CONFIG_DIR` — the configuration directory. Default `~/.config/alfred`.
/// - `ALFRED_EVAL` — "1" puts the process in eval mode: the scheduler does not run and nothing
///   is sent to the outside world. A sandbox instance must never be able to email, message or
///   write to Notion on the user's behalf just because it was pointed at a copy of their data.
///
/// The LaunchAgent plist and `launchctl` paths are deliberately NOT routed through here: they
/// describe the installed service on this machine, and an eval instance has no business
/// rewriting them.
enum AlfredPaths {

    // MARK: - Data

    /// The data directory, without a trailing slash.
    static let dataDir: String = {
        if let override = ProcessInfo.processInfo.environment["ALFRED_DIR"],
           !override.trimmingCharacters(in: .whitespaces).isEmpty {
            return (override as NSString).expandingTildeInPath
                .trimmingTrailingSlash()
        }
        return NSHomeDirectory() + "/.alfred"
    }()

    static var dataURL: URL { URL(fileURLWithPath: dataDir, isDirectory: true) }

    /// A path inside the data directory: `AlfredPaths.data("todos.db")`.
    static func data(_ relative: String) -> String {
        let rel = relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
        return rel.isEmpty ? dataDir : dataDir + "/" + rel
    }

    static func dataURL(_ relative: String) -> URL {
        URL(fileURLWithPath: data(relative))
    }

    // MARK: - Config

    /// The configuration directory, without a trailing slash.
    static let configDir: String = {
        if let override = ProcessInfo.processInfo.environment["ALFRED_CONFIG_DIR"],
           !override.trimmingCharacters(in: .whitespaces).isEmpty {
            return (override as NSString).expandingTildeInPath
                .trimmingTrailingSlash()
        }
        return NSHomeDirectory() + "/.config/alfred"
    }()

    static var configURL: URL { URL(fileURLWithPath: configDir, isDirectory: true) }

    static func config(_ relative: String) -> String {
        let rel = relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
        return rel.isEmpty ? configDir : configDir + "/" + rel
    }

    // MARK: - Eval mode

    /// True when this process is a sandbox instance scoring a build.
    ///
    /// Read once: a flag that can change under a running process is a flag that will be true in
    /// one branch and false in the next, which is exactly the kind of thing that sends an email
    /// from an eval run.
    static let isEval: Bool = {
        let v = (ProcessInfo.processInfo.environment["ALFRED_EVAL"] ?? "").lowercased()
        return v == "1" || v == "true" || v == "yes"
    }()

    /// One line for the log at startup, so a sandbox instance is never mistaken for the real one.
    static var describe: String {
        "data=\(dataDir) config=\(configDir)" + (isEval ? " [EVAL: scheduler off, sends blocked]" : "")
    }

    /// Create the data directory if it is missing. Safe to call repeatedly.
    @discardableResult
    static func ensureDataDir() -> Bool {
        (try? FileManager.default.createDirectory(at: dataURL, withIntermediateDirectories: true)) != nil
    }
}

private extension String {
    func trimmingTrailingSlash() -> String {
        var s = self
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
