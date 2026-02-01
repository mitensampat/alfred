import Foundation

// Alfred Launcher - Simple compiled executable that launches the alfred binary
// This is needed because macOS doesn't like bash script executables in app bundles
//
// IMPORTANT: We use a stable binary location (~/.alfred/bin/alfred) to avoid
// repeated macOS permission prompts. TCC permissions are tied to binary identity,
// so using a stable path means permissions persist across rebuilds.

let fileManager = FileManager.default
let home = fileManager.homeDirectoryForCurrentUser.path
let alfredDir = "\(home)/Documents/Claude apps/Alfred"
let buildBinary = "\(alfredDir)/.build/debug/alfred"

// Stable binary location - permissions will persist here
let stableBinDir = "\(home)/.alfred/bin"
let stableBinary = "\(stableBinDir)/alfred"

// Ensure stable bin directory exists
try? fileManager.createDirectory(atPath: stableBinDir, withIntermediateDirectories: true)

// Check if Alfred is already running - prevent duplicate instances
func isAlreadyRunning() -> Bool {
    let pgrep = Process()
    pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    pgrep.arguments = ["-f", "alfred menubar"]

    let pipe = Pipe()
    pgrep.standardOutput = pipe

    try? pgrep.run()
    pgrep.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""

    // If pgrep found processes, Alfred is already running
    return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

if isAlreadyRunning() {
    fputs("Alfred is already running. Bringing to front...\n", stderr)
    // Open the web UI instead of launching a duplicate
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["http://localhost:8080"]
    try? open.run()
    exit(0)
}

// Check if build binary exists
guard fileManager.fileExists(atPath: buildBinary) else {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", """
        display dialog "Alfred binary not found. Please run:\\ncd ~/Documents/Claude\\\\ apps/Alfred && swift build" buttons {"OK"} default button 1 with title "Alfred"
        """]
    try? process.run()
    process.waitUntilExit()
    exit(1)
}

// Copy/update binary to stable location if build is newer
func shouldUpdate() -> Bool {
    guard fileManager.fileExists(atPath: stableBinary) else { return true }
    guard let buildAttrs = try? fileManager.attributesOfItem(atPath: buildBinary),
          let stableAttrs = try? fileManager.attributesOfItem(atPath: stableBinary),
          let buildDate = buildAttrs[.modificationDate] as? Date,
          let stableDate = stableAttrs[.modificationDate] as? Date else {
        return true
    }
    return buildDate > stableDate
}

if shouldUpdate() {
    try? fileManager.removeItem(atPath: stableBinary)
    do {
        try fileManager.copyItem(atPath: buildBinary, toPath: stableBinary)
        // Make executable
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stableBinary)

        // Re-sign with a stable identifier so macOS TCC permissions persist across rebuilds
        // Without this, each rebuild creates a new binary hash and macOS asks for permissions again
        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = [
            "--force",
            "--sign", "-",  // Ad-hoc sign
            "--identifier", "com.msfoundry.alfred",  // Stable identifier
            stableBinary
        ]
        try codesign.run()
        codesign.waitUntilExit()

        if codesign.terminationStatus == 0 {
            fputs("✓ Binary signed with stable identifier\n", stderr)
        }
    } catch {
        fputs("Failed to copy binary: \(error)\n", stderr)
        // Fall back to build binary
    }
}

// Use stable binary if it exists, otherwise fall back to build binary
let binaryToRun = fileManager.fileExists(atPath: stableBinary) ? stableBinary : buildBinary

// Launch alfred in menubar mode
let process = Process()
process.executableURL = URL(fileURLWithPath: binaryToRun)
process.arguments = ["menubar"] + Array(CommandLine.arguments.dropFirst())
process.currentDirectoryURL = URL(fileURLWithPath: alfredDir)

do {
    try process.run()
    process.waitUntilExit()
    exit(process.terminationStatus)
} catch {
    fputs("Failed to launch Alfred: \(error)\n", stderr)
    exit(1)
}
