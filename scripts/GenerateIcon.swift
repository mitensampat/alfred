#!/usr/bin/env swift
//
// GenerateIcon.swift
// Creates Alfred app icon (bowler hat with gold band) as .icns file
//

import AppKit
import Foundation

func createHatImage(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))

    image.lockFocus()

    // Clear background (transparent)
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()

    // Scale factor
    let s = size / 512.0

    // Colors
    let hatColor = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)
    let hatHighlight = NSColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1.0)
    let goldColor = NSColor(red: 0.83, green: 0.69, blue: 0.22, alpha: 1.0)
    let goldHighlight = NSColor(red: 0.96, green: 0.81, blue: 0.34, alpha: 1.0)

    // Draw hat brim (ellipse at bottom)
    hatColor.setFill()
    let brimRect = NSRect(x: 56 * s, y: 92 * s, width: 400 * s, height: 80 * s)
    let brimPath = NSBezierPath(ovalIn: brimRect)
    brimPath.fill()

    // Draw hat crown (rounded rectangle)
    let crownRect = NSRect(x: 120 * s, y: 132 * s, width: 272 * s, height: 280 * s)
    let crownPath = NSBezierPath(roundedRect: crownRect, xRadius: 50 * s, yRadius: 50 * s)
    crownPath.fill()

    // Draw crown top (ellipse)
    let topRect = NSRect(x: 126 * s, y: 372 * s, width: 260 * s, height: 60 * s)
    let topPath = NSBezierPath(ovalIn: topRect)
    topPath.fill()

    // Draw gold band
    goldColor.setFill()
    let bandRect = NSRect(x: 120 * s, y: 177 * s, width: 272 * s, height: 40 * s)
    NSBezierPath(rect: bandRect).fill()

    // Draw band highlight
    goldHighlight.setFill()
    let highlightRect = NSRect(x: 120 * s, y: 207 * s, width: 272 * s, height: 10 * s)
    NSBezierPath(rect: highlightRect).fill()

    // Add subtle crown highlight
    hatHighlight.setFill()
    let shineRect = NSRect(x: 160 * s, y: 280 * s, width: 120 * s, height: 80 * s)
    let shinePath = NSBezierPath(ovalIn: shineRect)
    shinePath.fill()

    image.unlockFocus()

    return image
}

func main() {
    let fileManager = FileManager.default

    // Get script directory and project paths
    let scriptPath = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    let projectPath = scriptPath.deletingLastPathComponent()
    let iconsetPath = projectPath.appendingPathComponent("Alfred.app/Contents/Resources/AppIcon.iconset")
    let resourcesPath = projectPath.appendingPathComponent("Alfred.app/Contents/Resources")
    let icnsPath = resourcesPath.appendingPathComponent("AppIcon.icns")

    // Create iconset directory
    try? fileManager.createDirectory(at: iconsetPath, withIntermediateDirectories: true)

    // Required sizes for macOS iconset
    let sizes: [(size: CGFloat, filename: String)] = [
        (16, "icon_16x16.png"),
        (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"),
        (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"),
        (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"),
        (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"),
        (1024, "icon_512x512@2x.png"),
    ]

    print("Generating Alfred app icon...")

    for (size, filename) in sizes {
        let image = createHatImage(size: size)

        // Convert to PNG data
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            print("  Error creating \(filename)")
            continue
        }

        // Write to file
        let filePath = iconsetPath.appendingPathComponent(filename)
        do {
            try pngData.write(to: filePath)
            print("  Created \(filename)")
        } catch {
            print("  Error writing \(filename): \(error)")
        }
    }

    // Convert iconset to icns using iconutil
    print("\nConverting to .icns...")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", "-o", icnsPath.path, iconsetPath.path]

    do {
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus == 0 {
            print("Created AppIcon.icns")

            // Clean up iconset
            try? fileManager.removeItem(at: iconsetPath)
            print("Cleaned up iconset directory")
        } else {
            print("Error: iconutil failed with status \(process.terminationStatus)")
        }
    } catch {
        print("Error running iconutil: \(error)")
    }

    // Also remove any leftover SVG files
    if let contents = try? fileManager.contentsOfDirectory(at: iconsetPath, includingPropertiesForKeys: nil) {
        for file in contents where file.pathExtension == "svg" {
            try? fileManager.removeItem(at: file)
        }
    }

    print("\nDone!")
}

main()
