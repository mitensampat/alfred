import Foundation
import ApplicationServices
import Cocoa

// ⚠️ WARNING: This is for EDUCATIONAL PURPOSES ONLY
//
// DO NOT USE THIS IN PRODUCTION:
// - Against WhatsApp Terms of Service
// - Risk of account ban
// - Extremely fragile (breaks with UI changes)
// - Requires full Accessibility permissions
// - Security risk (could be hijacked)
// - Not reliable (timing issues, focus issues)
//
// This code demonstrates WHY we don't use GUI automation for WhatsApp.

class WhatsAppGUIAutomation {

    enum AutomationError: Error, CustomStringConvertible {
        case whatsAppNotRunning
        case accessibilityNotEnabled
        case elementNotFound(String)
        case sendFailed(String)
        case timeout

        var description: String {
            switch self {
            case .whatsAppNotRunning:
                return "WhatsApp Desktop is not running"
            case .accessibilityNotEnabled:
                return "Accessibility permissions not granted"
            case .elementNotFound(let element):
                return "UI element not found: \(element)"
            case .sendFailed(let reason):
                return "Failed to send: \(reason)"
            case .timeout:
                return "Operation timed out"
            }
        }
    }

    // MARK: - Main Send Function

    /// Attempts to send a WhatsApp message via GUI automation
    /// ⚠️ FRAGILE: Breaks with any UI changes
    /// ⚠️ RISKY: Against Terms of Service
    func sendMessage(to contact: String, message: String) async throws {
        print("⚠️  WARNING: Using GUI automation (not recommended)")
        print("   This method is fragile and against WhatsApp ToS\n")

        // 1. Check if WhatsApp is running
        guard isWhatsAppRunning() else {
            throw AutomationError.whatsAppNotRunning
        }

        // 2. Check Accessibility permissions
        guard hasAccessibilityPermissions() else {
            throw AutomationError.accessibilityNotEnabled
        }

        // 3. Activate WhatsApp
        try activateWhatsApp()
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5s wait

        // 4. Find and click search field
        print("🔍 Looking for search field...")
        try focusSearchField()
        try await Task.sleep(nanoseconds: 300_000_000) // 0.3s wait

        // 5. Type contact name
        print("⌨️  Typing contact: \(contact)")
        try typeText(contact)
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5s wait

        // 6. Press Enter to select first result
        print("⏎  Selecting conversation...")
        try pressEnter()
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5s wait

        // 7. Type message
        print("⌨️  Typing message...")
        try typeText(message)
        try await Task.sleep(nanoseconds: 300_000_000) // 0.3s wait

        // 8. Press Enter to send
        print("📤 Sending...")
        try pressEnter()

        print("✓ Message sent (hopefully - no reliable confirmation)")
    }

    // MARK: - Helper Functions

    private func isWhatsAppRunning() -> Bool {
        let runningApps = NSWorkspace.shared.runningApplications
        return runningApps.contains { app in
            app.bundleIdentifier == "net.whatsapp.WhatsApp" ||
            app.localizedName?.lowercased().contains("whatsapp") == true
        }
    }

    private func hasAccessibilityPermissions() -> Bool {
        // Check if we have accessibility permissions
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    private func activateWhatsApp() throws {
        let runningApps = NSWorkspace.shared.runningApplications
        guard let whatsApp = runningApps.first(where: { app in
            app.bundleIdentifier == "net.whatsapp.WhatsApp" ||
            app.localizedName?.lowercased().contains("whatsapp") == true
        }) else {
            throw AutomationError.whatsAppNotRunning
        }

        whatsApp.activate(options: [.activateIgnoringOtherApps])
    }

    private func focusSearchField() throws {
        // PROBLEM 1: This assumes specific UI structure
        // If WhatsApp updates their UI, this breaks

        // Try keyboard shortcut: Cmd+F (search)
        try pressKey(keyCode: 3, modifiers: .maskCommand) // 'F' key
    }

    private func typeText(_ text: String) throws {
        // PROBLEM 2: Character encoding issues
        // PROBLEM 3: Special characters may not work
        // PROBLEM 4: No way to verify text was actually typed

        let source = CGEventSource(stateID: .hidSystemState)

        for char in text {
            guard let keyCode = keyCodeForCharacter(char) else {
                print("⚠️  Warning: Cannot type character '\(char)'")
                continue
            }

            // Key down
            if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) {
                keyDown.post(tap: .cghidEventTap)
            }

            // Small delay
            Thread.sleep(forTimeInterval: 0.05)

            // Key up
            if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) {
                keyUp.post(tap: .cghidEventTap)
            }

            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private func pressEnter() throws {
        try pressKey(keyCode: 36, modifiers: []) // Enter key
    }

    private func pressKey(keyCode: CGKeyCode, modifiers: CGEventFlags) throws {
        let source = CGEventSource(stateID: .hidSystemState)

        // Key down
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) {
            keyDown.flags = modifiers
            keyDown.post(tap: .cghidEventTap)
        }

        Thread.sleep(forTimeInterval: 0.1)

        // Key up
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) {
            keyUp.flags = modifiers
            keyUp.post(tap: .cghidEventTap)
        }
    }

    private func keyCodeForCharacter(_ char: Character) -> CGKeyCode? {
        // PROBLEM 5: Incomplete mapping, doesn't handle all characters
        // PROBLEM 6: Only works for US keyboard layout

        let charToKeyCode: [Character: CGKeyCode] = [
            "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5,
            "h": 4, "i": 34, "j": 38, "k": 40, "l": 37, "m": 46,
            "n": 45, "o": 31, "p": 35, "q": 12, "r": 15, "s": 1,
            "t": 17, "u": 32, "v": 9, "w": 13, "x": 7, "y": 16, "z": 6,
            " ": 49, "!": 18, "@": 19, "#": 20, "$": 21, "%": 23,
            "^": 22, "&": 26, "*": 28, "(": 25, ")": 29,
            "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23,
            "6": 22, "7": 26, "8": 28, "9": 25
        ]

        return charToKeyCode[char.lowercased().first ?? char]
    }

    // MARK: - Alternative: Using Accessibility API directly

    /// More sophisticated approach using AX API
    /// Still fragile, still against ToS
    func sendMessageViaAccessibility(to contact: String, message: String) throws {
        // PROBLEM 7: Requires knowing exact UI hierarchy
        // PROBLEM 8: Hierarchy changes with each WhatsApp update
        // PROBLEM 9: No reliable way to find elements

        guard let whatsApp = getWhatsAppApp() else {
            throw AutomationError.whatsAppNotRunning
        }

        // Try to get the main window
        var windows: CFTypeRef?

        let result = AXUIElementCopyAttributeValue(
            whatsApp,
            kAXWindowsAttribute as CFString,
            &windows
        )

        guard result == .success, let windowArray = windows as? [AXUIElement] else {
            throw AutomationError.elementNotFound("main window")
        }

        guard windowArray.first != nil else {
            throw AutomationError.elementNotFound("main window")
        }

        // PROBLEM 10: From here, we'd need to:
        // - Find search field (no reliable identifier)
        // - Click it (may not work if covered)
        // - Type text (keyboard layout issues)
        // - Find chat (position changes)
        // - Find message field (UI structure changes)
        // - Type message (encoding issues)
        // - Find send button (may not have accessible label)
        // - Click it (may fail silently)

        throw AutomationError.sendFailed("Accessibility approach too unreliable")
    }

    private func getWhatsAppApp() -> AXUIElement? {
        let runningApps = NSWorkspace.shared.runningApplications
        guard let whatsApp = runningApps.first(where: { app in
            app.bundleIdentifier == "net.whatsapp.WhatsApp"
        }) else {
            return nil
        }

        return AXUIElementCreateApplication(whatsApp.processIdentifier)
    }
}

// MARK: - Problems Summary

/*
 WHY THIS DOESN'T WORK IN PRACTICE:

 1. FRAGILITY
    - UI changes break everything
    - WhatsApp updates frequently
    - Different screen sizes = different layouts
    - Different languages = different labels

 2. TIMING ISSUES
    - Network delays cause failures
    - Animation timing varies
    - Background processes affect speed
    - No reliable way to wait for UI updates

 3. RELIABILITY
    - Can't verify message actually sent
    - No error handling from WhatsApp
    - Silent failures common
    - May send duplicate messages

 4. FOCUS ISSUES
    - User switching apps breaks it
    - Notifications steal focus
    - Other windows covering WhatsApp
    - Screen savers, lock screens

 5. SECURITY RISKS
    - Accessibility access is very powerful
    - Could be hijacked by malware
    - No sandboxing
    - Keys/events visible system-wide

 6. TERMS OF SERVICE
    - Against WhatsApp ToS
    - Risk of account ban
    - No support if issues occur
    - Legal liability

 7. EDGE CASES
    - Contact not found → sends to wrong person
    - Chat archived → won't open
    - Blocked contact → fails silently
    - Group vs individual → different UI
    - Message too long → gets cut off
    - Special characters → encoding issues

 8. MAINTENANCE BURDEN
    - Must update with every WhatsApp release
    - Different macOS versions behave differently
    - Keyboard layouts vary by region
    - Localization issues (different languages)

 COMPARISON WITH iMessage:

 iMessage (AppleScript):
 ✅ Official Apple-supported API
 ✅ Stable interface (rarely changes)
 ✅ Reliable error handling
 ✅ Works across macOS versions
 ✅ Documented behavior
 ✅ No ToS violations

 WhatsApp (GUI Automation):
 ❌ Unofficial hack
 ❌ Breaks frequently
 ❌ No error handling
 ❌ Fragile across updates
 ❌ Undocumented
 ❌ Violates ToS

 BETTER ALTERNATIVES:

 1. WhatsApp Business API (official)
    - Reliable, supported, legal
    - Costs money, requires business account

 2. Manual sending (current approach)
    - 100% reliable
    - Takes 5 seconds
    - No risk

 3. Wait for official API
    - WhatsApp may release personal account API
    - Currently only business accounts supported
 */

// MARK: - Demo/Test Function

extension WhatsAppGUIAutomation {
    /// Demo function showing the issues
    func demonstrateProblems() {
        print("\n⚠️  WHATSAPP GUI AUTOMATION PROBLEMS DEMO\n")
        print(String(repeating: "=", count: 60))

        print("\n1️⃣ FRAGILITY ISSUES:")
        print("   • UI structure can change at any time")
        print("   • Search field location varies")
        print("   • Chat list order changes")
        print("   • Different screen sizes = different layouts")

        print("\n2️⃣ TIMING ISSUES:")
        print("   • Network delays are unpredictable")
        print("   • Animations vary in duration")
        print("   • Background processes affect timing")
        print("   • No reliable 'ready' state detection")

        print("\n3️⃣ RELIABILITY ISSUES:")
        print("   • Can't confirm message was sent")
        print("   • May send duplicate messages")
        print("   • Silent failures common")
        print("   • No delivery confirmation")

        print("\n4️⃣ SECURITY RISKS:")
        print("   • Requires full Accessibility access")
        print("   • Can be hijacked by malware")
        print("   • Keys visible system-wide")
        print("   • No sandboxing")

        print("\n5️⃣ EDGE CASES:")
        print("   • Contact not found → wrong recipient!")
        print("   • Chat archived → fails to open")
        print("   • Group vs individual → different UI")
        print("   • Special characters → encoding errors")

        print("\n6️⃣ MAINTENANCE BURDEN:")
        print("   • Must update with each WhatsApp release")
        print("   • macOS version differences")
        print("   • Keyboard layout variations")
        print("   • Localization issues")

        print("\n" + String(repeating: "=", count: 60))
        print("\n💡 RECOMMENDATION: Use manual sending or Business API")
        print("   Current draft approach is safer and more reliable\n")
    }
}
